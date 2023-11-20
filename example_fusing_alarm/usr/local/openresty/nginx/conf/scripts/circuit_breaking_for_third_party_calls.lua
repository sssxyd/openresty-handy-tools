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
8. global_biz_fail_count: All interface business failure count
9. global_biz_fail_percent: All interface business failure percentage
10: global_sys_fail_count: All interface system failure count
11: global_sys_fail_percent: All interface system failure percentage
12: global_fail_count: All interface business failure count
13: global_fail_percent: All interface business failure percentage
Please note: For circuit breaking rules, a breaking probability can be set. When a request is deemed to require circuit breaking, a random percentage is calculated. If this percentage is less than the set probability, the request will be blocked; otherwise, it will be allowed through.
If a probability is not set for a circuit breaking rule, it defaults to 100, meaning any trigger of the circuit breaking rule will definitely result in a block.
]]

local _M = {}
_M.alarm_http_url = nil
_M.expired_seconds = 600

local restybase = require("restybase")
local cjson = require("cjson")
local http = require("resty.http")

local function get_expired_seconds()
  return _M.expired_seconds
end


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
  
  client:zrangebyscore("resty_apistatus_exec_time_" .. command_redis_key, start_time, end_time)
  client:zrangebyscore("resty_apistatus_exec_status_" .. command_redis_key, start_time, end_time)
  
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

local function calc_global_exec_features(current_seconds, duration)
  local client = restybase.get_redis_client()
  if client == nil then
    return {global_exec_count = 1, global_biz_fail_count = 0, global_sys_fail_count = 0}
  end
  local end_seconds = current_seconds
  local start_seconds = current_seconds - duration
  local seconds_count = end_seconds - start_seconds + 1
  local global_exec_count_prefix = "resty_apistatus_global_exec_count_"
  local global_biz_fail_prefix = "resty_apistatus_global_bizfail_count_"
  local global_sys_fail_prefix = "resty_apistatus_global_sysfail_count_"
  
  client:init_pipeline(seconds_count * 3)
  
  for i = start_seconds, end_seconds do
    client:get(global_exec_count_prefix .. i)
  end
  
  for i = start_seconds, end_seconds do
    client:get(global_biz_fail_prefix .. i)
  end
  
  for i = start_seconds, end_seconds do
    client:get(global_sys_fail_prefix .. i)
  end
  
  local responses, errors = client:commit_pipeline()
  restybase.close_redis_client(client)  
  
  if not responses then
    ngx.log(ngx.ERR, "Failed to commit Redis pipeline: ", errors)
    return {global_exec_count = 1, global_biz_fail_count = 0, global_sys_fail_count = 0}
  end

  local idx = 0
  local global_exec_count = 0
  local global_biz_fail_count = 0
  local global_sys_fail_count = 0
  
  for i, res in ipairs(responses) do
    local value = 0
    if res ~= ngx.null then
      value = (tonumber(res) or 0)
    end
    
    if idx < seconds_count then
      global_exec_count = global_exec_count + value
    elseif idx < seconds_count * 2 then
      global_biz_fail_count = global_biz_fail_count + value
    else
      global_sys_fail_count = global_sys_fail_count + value
    end
    
    idx = idx + 1
  end  
  
  ngx.log(ngx.ERR, "global_exec_count:", global_exec_count, " global_biz_fail_count:", global_biz_fail_count, " global_sys_fail_count:", global_sys_fail_count)
  
  return {global_exec_count = global_exec_count, global_biz_fail_count = global_biz_fail_count, global_sys_fail_count = global_sys_fail_count}
end

-- Calculate the actual values of various metrics within the time interval of duration (in seconds).
local function calc_command_exec_features(command_redis_key, duration)
  local duration_exec_times, duration_exec_status = get_command_exec_status(command_redis_key, duration)
  local avg_exec_time = 0
  local biz_fail_count = 0
  local sys_fail_count = 0
  local total_exec_count = 0
  if duration_exec_times == nil or duration_exec_status == nil then
    return {avg_exec_time = avg_exec_time, biz_fail_count = biz_fail_count, sys_fail_count = sys_fail_count, total_exec_count = 1 }
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

local function calc_feature_actual_value(feature, status)
  local actual_value = 0
  if feature:startsWith("global_") then
    local global_exec_count, global_biz_fail_count, global_sys_fail_count = status.global_all_exec_count, status.global_biz_fail_count, status.global_sys_fail_count
    if feature == "global_biz_fail_count" then
      actual_value = global_biz_fail_count
    elseif feature == "global_biz_fail_percent" then
      actual_value = global_biz_fail_count/global_exec_count * 100
    elseif feature == "global_sys_fail_count" then
      actual_value = global_sys_fail_count
    elseif feature == "global_sys_fail_percent" then
      actual_value = global_sys_fail_count/global_exec_count * 100
    elseif feature == "global_fail_count" then
      actual_value = global_biz_fail_count + global_sys_fail_count
    elseif feature == "global_fail_percent" then
      actual_value = (global_biz_fail_count + global_sys_fail_count)/global_exec_count * 100 
    else
      actual_value = 0
    end       
  else
    local avg_exec_time, biz_fail_count, sys_fail_count, total_exec_count = status.avg_exec_time, status.biz_fail_count, status.sys_fail_count, status.total_exec_count
    if feature == "avg_exec_time" then
      actual_value = avg_exec_time
    elseif feature == "biz_fail_count" then
      actual_value = biz_fail_count
    elseif feature == "biz_fail_percent" then
      actual_value = biz_fail_count/total_exec_count * 100
    elseif feature == "sys_fail_count" then
      actual_value = sys_fail_count
    elseif feature == "sys_fail_percent" then
      actual_value = sys_fail_count/total_exec_count * 100
    elseif feature == "fail_count" then
      actual_value = sys_fail_count + biz_fail_count
    elseif feature == "fail_percent" then
      actual_value = (sys_fail_count + biz_fail_count)/total_exec_count * 100 
    else
      actual_value = 0
    end    
  end
  return actual_value
end

local function do_alarm_and_fuse(alarm_rules_name, fuse_rules_name, command)
  local current_seconds = ngx.time()
  local command_redis_key = restybase.get_command_redis_key(command)
  local alarm_rules = restybase.get_request_command_rules(command, 'x-alarm-rules', alarm_rules_name)
  local fuse_rules = restybase.get_request_command_rules(command, 'x-fuse-rules', fuse_rules_name)
  
  if alarm_rules == nil and fuse_rules == nil then
    ngx.ctx.request_ignorable = true
    return false
  end
  
  local duration_command_exec_status = {}
  local duration_global_exec_status = {}
  local status, duration_key, actual_value
  if alarm_rules ~= nil and next(alarm_rules) ~= nil then
    for _, rule in ipairs(alarm_rules) do
      duration_key = tostring(rule.duration)
      if rule.feature:startsWith("global_") then
        if duration_global_exec_status[duration_key] == nil then
          duration_global_exec_status[duration_key] = calc_global_exec_features(current_seconds, rule.duration)
        end     
        status = duration_global_exec_status[duration_key] 
      else
        if duration_command_exec_status[duration_key] == nil then
          duration_command_exec_status[duration_key] = calc_command_exec_features(command_redis_key, rule.duration)
        end     
        status = duration_command_exec_status[duration_key]        
      end
      actual_value = calc_feature_actual_value(rule.feature, status)
      if actual_value >= rule.threshold then
        -- Perform the alerting operation asynchronously
        if restybase.check_probability(rule.probability) then
          local msg = {
            feature = rule.feature,
            duration = rule.duration,
            threshold = rule.threshold,
            probability = rule.probability or 100,
            command = command,
            actual_value = actual_value,
            client_ip = ngx.var.remote_addr,
            trigger_time = ngx.time()
          }
          local ok, err = ngx.timer.at(0, timer_send_alarm, cjson.encode(msg))
          if not ok then
              ngx.log(ngx.ERR, "failed to create timer: ", err)
          end
        end
      end
    end
  end
  
  if fuse_rules == nil or next(fuse_rules) == nil then
    return false
  end
  
  for _, rule in ipairs(fuse_rules) do
    duration_key = tostring(rule.duration)
    if rule.feature:startsWith("global_") then
      if duration_global_exec_status[duration_key] == nil then
        duration_global_exec_status[duration_key] = calc_global_exec_features(current_seconds, rule.duration)
      end     
      status = duration_global_exec_status[duration_key] 
    else
      if duration_command_exec_status[duration_key] == nil then
        duration_command_exec_status[duration_key] = calc_command_exec_features(command_redis_key, rule.duration)
      end     
      status = duration_command_exec_status[duration_key]        
    end
    actual_value = calc_feature_actual_value(rule.feature, status)
    
    if actual_value >= rule.threshold then
      -- Attempt to trigger circuit breaking; if circuit breaking is confirmed, return immediately; otherwise, continue to evaluate other rules.
      if restybase.check_probability(rule.probability) then
        local actual_value_str = tostring(actual_value)
        local threshold_str = tostring(rule.threshold)
        if string.endsWith(rule.feature, "_percent") then
          actual_value_str = string.format("%.2f", actual_value) .. "%"
          threshold_str = string.format("%.2f", rule.threshold) .. "%"
        end
        
        ngx.log(ngx.ERR, "[FUSING] The feature [", rule.feature, "] for the command [", command, "] is ", actual_value_str, " in the last ", rule.duration, " seconds, exceeding the threshold of ", threshold_str)        
        return true
      end
    end
  end
  return false
end

local function get_command_redis_keys(logs, client, expired_seconds, expired_offset)
  client:init_pipeline(2)
  
  client:zrange("resty_apistatus_last_exec_time", 0, -1)
  client:zremrangebyscore("resty_apistatus_last_exec_time", 0, expired_offset)
  
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
    client:zremrangebyscore("resty_apistatus_exec_time_" .. command_redis_key, 0, expired_offset)
    client:zremrangebyscore("resty_apistatus_exec_status_" .. command_redis_key, 0, expired_offset)
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
local function timer_set_command_exec_status(premature, time_slice, time_offset, command_redis_key, exec_time, exec_status)
  if premature then
    return
  end
  
  local client = restybase.get_redis_client()
  if client == nil then
    return
  end
  
  local current_offset = time_offset
  local current_offset_prefix = tostring(time_offset) .. '_'  
  local expire_time = get_expired_seconds()
  local time_slice_str = tostring(time_slice)
  
  client:init_pipeline(7)

  client:zadd("resty_apistatus_last_exec_time", current_offset, command_redis_key)
  client:zadd("resty_apistatus_exec_time_" .. command_redis_key, current_offset, current_offset_prefix .. tostring(exec_time))
  client:zadd("resty_apistatus_exec_status_" .. command_redis_key, current_offset, current_offset_prefix .. tostring(exec_status))
  
  client:incr("resty_apistatus_global_exec_count_" .. time_slice_str)
  client:expire("resty_apistatus_global_exec_count_" .. time_slice_str, expire_time)
  
  if exec_status == 2 then
    client:incr("resty_apistatus_global_bizfail_count_" .. time_slice_str)
    client:expire("resty_apistatus_global_bizfail_count_" .. time_slice_str, expire_time)
  elseif exec_status == 3 then
    client:incr("resty_apistatus_global_sysfail_count_" .. time_slice_str)
    client:expire("resty_apistatus_global_sysfail_count_" .. time_slice_str, expire_time)    
  end

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

-- Initialize the module; params include: alarm_http_url (the URL of the alerting interface), expired_seconds (the expiration time of the Redis cache, in seconds)
function _M.init_by_lua_block(params)
  if params == nil or next(params) == nil then
    return
  end
  
  if params.alarm_http_url ~= nil and params.alarm_http_url ~= "" then
    _M.alarm_http_url = params.alarm_http_url
  end
  
  if params.expired_seconds ~= nil then
    local expired_seconds = tonumber(params.expired_seconds)
    if expired_seconds ~= nil and expired_seconds > 0 then
      _M.expired_seconds = expired_seconds
    end
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
  
  if ngx.ctx.request_ignorable then
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
  local ok, err = ngx.timer.at(0, timer_set_command_exec_status, ngx.time(), restybase.microseconds_offset(), command_redis_key, exec_time, exec_status)
  if not ok then
      ngx.log(ngx.ERR, "failed to create timer: ", err)
  end
end

function _M.access_by_lua_block_clear()
  local logs = {}
  logs[1] = string.format("[%s], start clear api_exec_status_monitor redis cache expired %d seconds ago", os.date("%Y/%m/%d %H:%M:%S", os.time()), get_expired_seconds())
  
  local client = restybase.get_redis_client()
  if client == nil then
    logs[2] = "get redis cient failed!"
    return
  end
  
  local expired_offset = restybase.microseconds_offset() - get_expired_seconds() * 1000000
  
  local command_redis_keys = get_command_redis_keys(logs, client, get_expired_seconds(), expired_offset)
  
  if next(command_redis_keys) == nil then
    restybase.close_redis_client(client)
    logs[2] = "no commands exec status cached"
    return table.concat(logs, "\n")
  end
  
  local batches = restybase.split_list(command_redis_keys, 25)
  local total = #command_redis_keys * 2
  local count = 0
  for _, sublist in ipairs(batches) do
    count = count + clear_command_expired_data(client, get_expired_seconds(), expired_offset, sublist)
  end
  restybase.close_redis_client(client)
  
  logs[2] = string.format("exec %d redis command, succeed: %d, failed: %d", total, count, (total - count))
  logs[3] = string.format("[%s], complete clear api_exec_status_monitor redis cache", os.date("%Y/%m/%d %H:%M:%S", os.time()))
  return table.concat(logs, "\n")
  
end

return _M