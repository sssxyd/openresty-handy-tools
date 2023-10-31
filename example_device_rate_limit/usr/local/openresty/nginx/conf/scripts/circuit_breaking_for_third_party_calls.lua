--[[
Add circuit breaking and alerting mechanisms for third-party service calls
Author: xuyd
Date: 2023/10/17
Usage: Provides the following circuit breaking/alerting rules:
1. avg_exec_time: Average execution time in milliseconds
2. biz_fail_count: Number of business logic failures
3. biz_fail_percent: Percentage of business logic failures
4. sys_fail_count: Number of system failures
5. sys_fail_percent: Percentage of system failures
6. fail_count: Number of request failures
7. fail_percent: Percentage of request failures
Please note: For circuit breaking rules, a breaking probability can be set. When a request is deemed to require circuit breaking, a random percentage is calculated. If this percentage is less than the set probability, the request will be blocked; otherwise, it will be allowed through.
If a probability is not set for a circuit breaking rule, it defaults to 100, meaning any trigger of the circuit breaking rule will definitely result in a block.
]]

local _M = {}
_M.alarm_http_url = nil

local restybase = require("restybase")
local cjson = require("cjson")
local http = require("resty.http")

-- Retrieve the business-level success status of an API call from the response header.
local function get_response_business_code()
  local headers = ngx.resp.get_headers()
  local x_response_code = headers["x-response-code"]
  if x_response_code ~= nil then
    return tonumber(x_response_code)
  end
  return 1
end

-- Retrieve the execution status of a specific command within the last XX seconds.
local function get_command_exec_status(command_redis_key, duration)
  local client = restybase.get_redis_client()
  if client == nil then
    return nil, nil
  end
  local end_time = restybase.microseconds_offset()
  local start_time = end_time - duration * 1000000
  
  client:init_pipeline(2)
  
  client:zrangebyscore("resty_aesm_exec_time_" .. command_redis_key, start_time, end_time)
  client:zrangebyscore("resty_aesm_exec_status_" .. command_redis_key, start_time, end_time)
  
  local responses, errors = client:commit_pipeline()
  restybase.close_redis_client(client)
  
  if not responses then
    ngx.log(ngx.ERR, "Failed to commit Redis pipeline: ", errors)
    return nil, nil
  end

  local duration_exec_times = responses[1]
  local duration_exec_status = responses[2]
  
  return duration_exec_times, duration_exec_status
end

-- Calculate the actual values of various metrics within the time interval of duration (in seconds).
local function calc_command_exec_features(command_redis_key, duration)
  local duration_exec_times, duration_exec_status = get_command_exec_status(command_redis_key, duration)
  local avg_exec_time = 0
  local biz_fail_count = 0
  local sys_fail_count = 0
  local total_exec_count = 0
  if duration_exec_times == nil or duration_exec_status == nil then
    return {avg_exec_time = avg_exec_time, biz_fail_count = biz_fail_count, sys_fail_count = sys_fail_count, total_exec_count = 1}
  end
  
  -- Iterate through execution times to calculate the average execution time (in millisenconds)
  local total_exec_time = 0
  local count = 0
  local idx, exec_time
  for index, member in ipairs(duration_exec_times) do
    idx = member:find('_')
    if idx then
      exec_time = tonumber(member:sub(idx+1))
    else
      exec_time = tonumber(member)
    end
    if exec_time then
      total_exec_time = total_exec_time + exec_time
      count = count + 1
    end
  end
  --calculate the average execution time (in millisenconds)
  if count > 0 then
    avg_exec_time = math.floor(total_exec_time/count)
  end
  
  -- Iterate through execution statuses to calculate the number of executions, business failures, and system failures.
  local exec_status
  for index, member in ipairs(duration_exec_status) do
    idx = member:find('_')
    if idx then
      exec_status = tonumber(member:sub(idx+1))
    else
      exec_status = tonumber(member)
    end
    if exec_status then
      total_exec_count = total_exec_count + 1
      if exec_status == 2 then
        biz_fail_count = biz_fail_count + 1
      elseif exec_status == 3 then
        sys_fail_count = sys_fail_count + 1
      end
    end
  end
  if total_exec_count == 0 then
    total_exec_count = 1
  end
  return {avg_exec_time = avg_exec_time, biz_fail_count = biz_fail_count, sys_fail_count = sys_fail_count, total_exec_count = total_exec_count}
end

-- Parse the rules in x-fuse-rules and x-alarm-rules from the HTTP request header.
local function split_rules(rule_str)
  if rule_str == nil or rule_str == "" then
    return nil
  end
  
  local result = {}
  local feature, duration, threshold, probability
  local rules = rule_str:trim():split(",")
  for _, rule in ipairs(rules) do
    local items = rule:trim():split(":")
    local len = #items
    if len == 3 then
      table.insert(result, {feature = items[1]:trim(), duration = tonumber(items[2]:trim()), threshold = tonumber(items[3]:trim()), probability = 100 })
    else
      table.insert(result, {feature = items[1]:trim(), duration = tonumber(items[2]:trim()), threshold = tonumber(items[3]:trim()), probability = tonumber(items[4]:trim()) })
    end 
  end
  
  if next(result) == nil then
    return nil
  end
  
  return result
end

local function get_fuse_rules(fuse_rules_name, command)
  -- First, retrieve the circuit-breaking rules declared by the caller.
  local fuse_rules = split_rules(ngx.req.get_headers()["x-fuse-rules"])
  if fuse_rules ~= nil then
    return fuse_rules
  end
  
  return restybase.get_command_rules(fuse_rules_name, command)
end

local function get_alarm_rules(alarm_rules_name, command)
  -- First, retrieve the alerting rules declared by the caller.
  local alarm_rules = split_rules(ngx.req.get_headers()["x-alarm-rules"])
  if alarm_rules ~= nil then
    return alarm_rules
  end
  
  return restybase.get_command_rules(alarm_rules_name, command)
end

local function timer_send_alarm(premature, msg)
  if premature then
    return
  end
  
  ngx.log(ngx.ERR, "sent to " .. _M.alarm_http_url .. " msg = " .. msg)
  
  if msg == nil or msg == "" then
    return
  end

  if _M.alarm_http_url == nil or _M.alarm_http_url == "" then
    return
  end
  
  local httpc = http.new()
  -- Set the timeout duration (in milliseconds).
  httpc:set_timeout(500)

  local data = {
      msg = msg
  }

  -- Convert a Lua table to a string in x-www-form-urlencoded format.
  local body_data = ngx.encode_args(data)

  local res, err = httpc:request_uri(_M.alarm_http_url, {
      method = "POST",
      body = body_data,
      headers = {
          ["Content-Type"] = "application/x-www-form-urlencoded",
      }
  })

  if not res then
      ngx.log(ngx.ERR, "failed to alarm: " .. err)
      return
  end

end

local function check_fuse_probability(command, rule, actual_value)
  -- Circuit-breaking probability, up to a maximum of 100%
  local probability = rule.probability * 0.01
  
  if probability <= 0 then
    return false
  end
  
  -- Generate a random probability; if it is greater than the circuit-breaking probability, do not trigger the circuit breaker
  local probability_str = ""
  if probability < 1 then
    local prob = math.random()
    probability_str = string.format(", and the random probability for this request is %.2f%%, which is less than or equal to the set circuit-breaking probability of %.2f%%, triggering the circuit breaker.", prob*100, probability*100)
    if prob > probability then
      return false
    end
  end
  
  local actual_value_str = tostring(actual_value)
  local threshold_str = tostring(rule.threshold)
  if string.endsWith(rule.feature, "_percent") then
    actual_value_str = string.format("%.2f", actual_value) .. "%"
    threshold_str = string.format("%.2f", rule.threshold) .. "%"
  end
  
  ngx.log(ngx.ERR, "[FUSING] The feature [", rule.feature, "] for the command [", command, "] is ", actual_value_str, " in the last ", rule.duration, " seconds, exceeding the threshold of ", threshold_str, probability_str)
  return true
end

local function do_alarm_and_fuse(alarm_rules_name, fuse_rules_name, command)
  local command_redis_key = restybase.get_command_redis_key(command)
  local alarm_rules = get_alarm_rules(alarm_rules_name, command)
  local fuse_rules = get_fuse_rules(fuse_rules_name, command)
  
  local duration_exec_status = {}
  local feature, duration, threshold, status, duration_key, actual_value
  local avg_exec_time, biz_fail_count, sys_fail_count, total_exec_count
  if alarm_rules ~= nil and next(alarm_rules) ~= nil then
    for _, rule in ipairs(alarm_rules) do
      feature, duration, threshold = rule.feature, rule.duration, rule.threshold
      duration_key = tostring(duration)
      if duration_exec_status[duration_key] == nil then
        duration_exec_status[duration_key] = calc_command_exec_features(command_redis_key, duration)
      end
      status = duration_exec_status[duration_key]
      avg_exec_time, biz_fail_count, sys_fail_count, total_exec_count = status.avg_exec_time, status.biz_fail_count, status.sys_fail_count, status.total_exec_count
      if feature == "avg_exec_time" then
        actual_value = avg_exec_time
      elseif feature == "biz_fail_count" then
        actual_value = biz_fail_count
      elseif feature == "biz_fail_percent" then
        actual_value = biz_fail_count/total_exec_count * 100
      elseif feature == "sys_fail_count" then
        actual_value = sys_fail_count
      elseif feature == "sys_fail_percent" then
        actual_value = sys_fail_count
      elseif feature == "fail_count" then
        actual_value = sys_fail_count + biz_fail_count
      elseif feature == "fail_percent" then
        actual_value = (sys_fail_count + biz_fail_count)/total_exec_count * 100 
      else
        actual_value = 0
      end
      if actual_value >= threshold then
        -- Perform the alerting operation asynchronously
        local actual_value_str = tostring(actual_value)
        local threshold_str = tostring(rule.threshold)
        if string.endsWith(rule.feature, "_percent") then
          actual_value_str = string.format("%.2f", actual_value) .. "%"
          threshold_str = string.format("%.2f", rule.threshold) .. "%"
        end        
        local msg = string.format("The feature [%s] for the command [%s] is %s in the last %d seconds, exceeding the threshold of %s", rule.feature, command, actual_value_str, rule.duration, threshold_str)        
        local ok, err = ngx.timer.at(0, timer_send_alarm, msg)
        if not ok then
            ngx.log(ngx.ERR, "failed to create timer: ", err)
        end
      end
    end
  end
  
  if fuse_rules == nil or next(fuse_rules) == nil then
    return false
  end
  
  for _, rule in ipairs(fuse_rules) do
    feature, duration, threshold = rule.feature, rule.duration, rule.threshold
    duration_key = tostring(duration)
    if duration_exec_status[duration_key] == nil then
      duration_exec_status[duration_key] = calc_command_exec_features(command_redis_key, duration)
    end
    status = duration_exec_status[duration_key]
    avg_exec_time, biz_fail_count, sys_fail_count, total_exec_count = status.avg_exec_time, status.biz_fail_count, status.sys_fail_count, status.total_exec_count
    
    if feature == "avg_exec_time" then
      actual_value = avg_exec_time
    elseif feature == "biz_fail_count" then
      actual_value = biz_fail_count
    elseif feature == "biz_fail_percent" then
      actual_value = biz_fail_count/total_exec_count * 100
    elseif feature == "sys_fail_count" then
      actual_value = sys_fail_count
    elseif feature == "sys_fail_percent" then
      actual_value = sys_fail_count
    elseif feature == "fail_count" then
      actual_value = sys_fail_count + biz_fail_count
    elseif feature == "fail_percent" then
      actual_value = (sys_fail_count + biz_fail_count)/total_exec_count * 100 
    else
      actual_value = 0
    end
    
    if actual_value >= threshold then
      -- Attempt to trigger circuit breaking; if circuit breaking is confirmed, return immediately; otherwise, continue to evaluate other rules.
      if check_fuse_probability(command, rule, actual_value) then
        return true
      end
    end
  end
  return false
end

local function get_command_redis_keys(logs, client, expired_seconds, expired_offset)
  client:init_pipeline(2)
  
  client:zrange("resty_aesm_last_exec_time", 0, -1)
  client:zremrangebyscore("resty_aesm_last_exec_time", 0, expired_offset)
  
  local responses, errors = client:commit_pipeline()
  
  if not responses then
    ngx.log(ngx.ERR, "Failed to commit Redis pipeline: ", errors)
    return {}
  end
  
  local keys = responses[1] or {}
  
  if keys == nil then
    keys = {}
  end  
  
  return keys
end

local function clear_command_expired_data(client, expired_seconds, expired_offset, command_redis_keys)
  local count = #command_redis_keys * 2
  
  client:init_pipeline(count)
  
  for _, command_redis_key in ipairs(command_redis_keys) do
    client:zremrangebyscore("resty_aesm_exec_time_" .. command_redis_key, 0, expired_offset)
    client:zremrangebyscore("resty_aesm_exec_status_" .. command_redis_key, 0, expired_offset)
  end

  local responses, errors = client:commit_pipeline()
  if not responses then
    ngx.log(ngx.ERR, "Failed to commit Redis pipeline: ", errors)
    return 0
  end
  
  for i, res in ipairs(responses) do
    if not res then
      count = count - 1
      ngx.log(ngx.ERR, "Failed to execute command in pipeline at index ", i, ": ", errors[i])
    end
  end
  
  return count
end


-- Log the execution time and status of a single command, where exec_status is defined as: 1 for execution success, 2 for business exception failure, and 3 for system exception failure.
local function timer_set_command_exec_status(premature, command_redis_key, exec_time, exec_status)
  if premature then
    return
  end
  
  local client = restybase.get_redis_client()
  if client == nil then
    return
  end
  
  local current_offset = restybase.microseconds_offset()
  local current_offset_prefix = tostring(current_offset) .. '_'  
  
  client:init_pipeline(3)

  client:zadd("resty_aesm_last_exec_time", current_offset, command_redis_key)
  client:zadd("resty_aesm_exec_time_" .. command_redis_key, current_offset, current_offset_prefix .. tostring(exec_time))
  client:zadd("resty_aesm_exec_status_" .. command_redis_key, current_offset, current_offset_prefix .. tostring(exec_status))
  
  local responses, errors = client:commit_pipeline()
  restybase.close_redis_client(client)
  
  if not responses then
    ngx.log(ngx.ERR, "Failed to commit Redis pipeline: ", errors)
    return
  end
  
  for i, res in ipairs(responses) do
    if not res then
      ngx.log(ngx.ERR, "Failed to execute command in pipeline at index ", i, ": ", errors[i])
    end
  end

end

-- Initialize the module; params include: alarm_http_url (the URL of the alerting interface).
function _M.init_by_lua_block(params)
  if params == nil or next(params) == nil then
    return
  end
  
  if params.alarm_http_url ~= nil and params.alarm_http_url ~= "" then
    _M.alarm_http_url = params.alarm_http_url
  end
  
end

function _M.access_by_lua_block(params)
  if params == nil or next(params) == nil then
    return false
  end
  
  local command = restybase.get_request_command()
  if command == nil then
    return false
  end
  
  local alarm_rules_name = params.alarm_rule
  local fuse_rules_name = params.fuse_rule
  
  return do_alarm_and_fuse(alarm_rules_name, fuse_rules_name, command)
end

function _M.header_filter_by_lua_block()
  local command = restybase.get_request_command()
  if command == nil then
    return
  end
  
  local command_redis_key = restybase.get_command_redis_key(command)
  -- Execution time is measured in milliseconds.
  local exec_time = math.floor((ngx.now() - restybase.get_request_start_time()) * 1000)
  local exec_status = 1
  if ngx.status == 200 then
    if get_response_business_code() == 1 then
      exec_status = 1   --Execution Succeeded
    else
      exec_status = 2   --Business Exception (HTTP status code == 200, but the API call failed at the business level)
    end
  else
    exec_status = 3     --System Exception (HTTP status code != 200)
  end
  
  -- Perform the logging operation asynchronously, as network API usage is not allowed in synchronous operations.
  local ok, err = ngx.timer.at(0, timer_set_command_exec_status, command_redis_key, exec_time, exec_status)
  if not ok then
      ngx.log(ngx.ERR, "failed to create timer: ", err)
  end   
end

function _M.access_by_lua_block_clear(expired_seconds)
  local logs = {}
  logs[1] = string.format("[%s], start clear api_exec_status_monitor redis cache expired %d seconds ago", os.date("%Y/%m/%d %H:%M:%S", os.time()), expired_seconds)
  
  local client = restybase.get_redis_client()
  if client == nil then
    logs[2] = "get redis cient failed!"
    return
  end
  
  local expired_offset = restybase.microseconds_offset() - expired_seconds * 1000000
  
  local command_redis_keys = get_command_redis_keys(logs, client, expired_seconds, expired_offset)
  
  if next(command_redis_keys) == nil then
    restybase.close_redis_client(client)
    logs[2] = "no commands exec status cached"
    return table.concat(logs, "\n")
  end
  
  local batches = restybase.split_list(command_redis_keys, 25)
  local total = #command_redis_keys * 2
  local count = 0
  for _, sublist in ipairs(batches) do
    count = count + clear_command_expired_data(client, expired_seconds, expired_offset, sublist)
  end
  restybase.close_redis_client(client)
  
  logs[2] = string.format("exec %d redis command, succeed: %d, failed: %d", total, count, (total - count))
  logs[3] = string.format("[%s], complete clear api_exec_status_monitor redis cache", os.date("%Y/%m/%d %H:%M:%S", os.time()))
  return table.concat(logs, "\n")
  
end

return _M