# OpenResty Handy Tools
Enhance your Nginx by editing rule files to achieve flexible configuration of client access frequency restrictions, and add circuit breaker alarm functionality for third-party API calls.

## Languages
- [简体中文](./README_zh-CN.md)

## Install OpenResty and Modules
Please follow the official documentation to install OpenResty
Then, install the following modules:

1. openresty/lua-resty-redis
2. openresty/lua-resty-upstream-healthcheck
3. pintsized/lua-resty-http


For CentOS, you can install them using the following commands:

<pre lang="no-highlight"><code>
yum install -y yum-utils

# For CentOS 8 or older
yum-config-manager --add-repo https://openresty.org/package/centos/openresty.repo
# For CentOS 9 or later
yum-config-manager --add-repo https://openresty.org/package/centos/openresty2.repo

yum install -y openresty
yum install -y openresty-opm openresty-resty

opm get openresty/lua-resty-redis
opm get openresty/lua-resty-upstream-healthcheck
opm get pintsized/lua-resty-http

systemctl enable openresty

</code></pre>
## Configure Rate Limiting
1. The client request must carry the http header: **x-device-no**. If this header is missing and the interface is not set to be ignored in the rule file, it will return 429.
2. Overwrite the contents of the local directory with the contents of the example_device_rate_limit directory.
3. Edit nginx.conf to configure the redis connection, cache data expiration time, and health check address:
<pre lang="no-highlight"><code>
    init_by_lua_block {
	...
        restybase.init_by_lua_block({
            redis = {
                host = "127.0.0.1",     -- Redis host
                port = 6379,            -- Redis port
                auth = "password",      -- Redis requirepass
                pool_size = 32,         -- Client connection pool size
                idle_millis = 10000     -- Max milliseconds a connection stays idle in the connection pool
            }, 
            rule_path = "/usr/local/openresty/nginx/conf/rules"
        })
	...
        rate_limit_based_on_device_no.init_by_lua_block({
            expired_seconds = 600       -- Redis key expiration time in seconds
        })
    }
    init_worker_by_lua_block{
	...
        local ok, err = hc.spawn_checker{
            shm = "healthcheck",  -- lua_shared_dict
            upstream = "device_rate_limit_backend",  -- Upstream name
            type = "http",
            http_req = "GET /guest/healthcheck HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n",  -- HTTP request for checking
            interval = 2000,  -- Run the check cycle every 2 seconds
            timeout = 1000,   -- 1 second is the timeout for network operations
            fall = 3,  -- Number of successive failures before turning a peer down
            rise = 2,  -- Number of successive successes before turning a peer up
            valid_statuses = {200, 302},  -- A list of valid HTTP status codes
            concurrency = 10,  -- Concurrency level for test requests
        }
	...
    }	   
</code></pre>
4. Edit conf.d/device_rate_limit.conf to configure the backend server and the name of the JSON rule file being used:
<pre lang="no-highlight"><code>	   
# The name of this upstream. It has health checks configured in nginx.conf. 
# If you need to change the name, make sure to update it there as well.
upstream device_rate_limit_backend {
    least_conn;
    server 192.168.3.108:18080;
    server 192.168.3.207:18080;
}

server {
    listen 10001;
    server_name _;

    location / {
        access_by_lua_block {
	...
	    local rate_limit_based_on_device_no = require("rate_limit_based_on_device_no")
	    -- Set the name of the JSON-Formatted rule file used for validation.
	    if rate_limit_based_on_device_no.access_by_lua_block({
		rule="example_device_access_limit"
	    }) then
		return ngx.exit(429)  
	    end
        }
        ...
    }
} 
   </code></pre>
5. In the rules directory, create or edit the rule JSON file.
You can refer to the example rule file: example_device_access_limit.json.
6. Reload the configuration file:
<pre><code>openresty -s reload</code></pre>

   
## Configure Circuit Breaking & Alarm
1. Overwrite the local directory with the contents from the example_fusing_alarm directory.
2. Edit nginx.conf to configure the Redis connection and the device alarm address:
<pre><code>
init_by_lua_block {
    ...
    restybase.init_by_lua_block({
        redis = {
            host = "127.0.0.1",     -- Redis host
            port = 6379,            -- Redis port
            auth = "password",      -- Redis requirepass
            pool_size = 32,         -- Client connection pool size
            idle_millis = 10000     -- Max milliseconds a connection stays idle in the connection pool
        },  
        rule_path = "/usr/local/openresty/nginx/conf/rules"
    })
    ...
    circuit_breaking_for_third_party_calls.init_by_lua_block({
        alarm_http_url = "http://192.168.3.108:18888/guest/alarm"    -- Set your alarm POST URL
    })
}
</code></pre>
3. Edit conf.d/fusing_and_alarm.conf to configure the rules for circuit breaking and alarms, the third-party service address, and the Redis cache clearing time:
<pre><code>
location / {
    access_by_lua_block {
        ...
        if circuit_breaking_for_third_party_calls.access_by_lua_block({
            alarm_rule = "example_rule_alarms", 
            fuse_rule = "example_rule_fuse"
        }) then
            return ngx.exit(503)
        end
        ...
    }
    
    # Set your third-party URI
    proxy_pass http://192.168.3.108:18080;
    ...
}

location = /circuit_breaking_for_third_party_calls_clear {
    ...
    access_by_lua_block {
        local circuit_breaking_for_third_party_calls = require("circuit_breaking_for_third_party_calls")
        -- Clear command exec status data from x seconds ago
        local logs = circuit_breaking_for_third_party_calls.access_by_lua_block_clear(600)
        ngx.header.content_type = 'text/plain; charset=utf-8'
        ngx.say(logs)
        ngx.exit(ngx.HTTP_OK)
    }
    ...
}
</code></pre>
4. Set up a cron job to clear the Redis cache periodically:
<pre><code>
crontab -e
</code></pre>
Set to clear every 10 minutes:
<pre><code>
*/10 * * * * /usr/bin/curl -s http://localhost:10000/circuit_breaking_for_third_party_calls_clear >> /usr/local/openresty/nginx/logs/clear.log 2>&1
</code></pre>
5. In the rules directory, create or edit the rule JSON files.
You can refer to the example rule files: example_rule_fuse.json, example_rule_alarms.json.
6. Reload the configuration file:
<pre><code>
openresty -s reload
</code></pre>
7. Recovery and Continuous Monitoring of Circuit Breaking<br/>
Metric calculations are real-time, and as time continues, the metrics (such as the failure percentage) of the circuit-broken interface will continue to drop until they are below the threshold, at which point execution will resume.<br/>
It is recommended to set probability < 100 in the circuit breaking rules, allowing some requests to pass through even after the interface triggers circuit breaking, for continuous monitoring.<br/>
8. The determination of business exceptions depends on the response header returned by the third-party service: **x-response-code**. When this value exists and is equal to 1, it indicates that the interface call is successful in business terms; when it is not equal to 1, it indicates a failure. If this header does not exist, the metric for business exceptions becomes invalid.

## Edit Rule File
### Path
The default path for the rule files in JSON format is: /usr/local/openresty/nginx/conf/rules/

### Example
example_rule_fuse.json

<pre lang="no-highlight"><code>
{
    "global": [
        {"feature": "avg_exec_time", "duration": 60, "threshold": 500, "probability": 50},
        {"feature": "biz_fail_percent", "duration": 60, "threshold": 10.5, "probability": 65},
        {"feature": "sys_fail_count", "duration": 30, "threshold": 20, "probability": 66},
        {"feature": "fail_percent", "duration": 60, "threshold": 50}
    ],
    "commands": {
        "do_not_fusing/user.login": [],
        "custom_rules/get_orders": [
            {"feature": "avg_exec_time", "duration": 60, "threshold": 1000},
            {"feature": "fail_count", "duration": 30, "threshold": 1}
        ]
    }
}
</code></pre>
This rule file indicates:

1. Ignore the request: do_not_fusing/user.login, perform no operations.
2. For the request: custom_rules/get_orders, apply its custom rules: trigger the rules 100% if the average execution time exceeds 1000 milliseconds within 60 seconds, or if the number of call failures exceeds 1 within 30 seconds.
3. For other requests: For this single interface, trigger the rules with a 50% probability if the average execution time exceeds 500 milliseconds within 60 seconds, or if business failures exceed 10.5% within 60 seconds trigger with a 65% probability, or if system failures exceed 20 within 30 seconds trigger with a 66% probability, or if call failures exceed 60% within 60 seconds trigger with a 100% probability.

### Explanation
1. 'command' refers to the HTTP request path after removing the first slash.
2. Priority is given to the interface rules configured in 'commands'; if none are found, the global rules are applied.
If empty rules are configured in 'commands', it means that this interface is ignored and no operations are performed on it.

### Structure of the Rules
1. **feature**: Metric name, provided by the Lua module. Different modules support different metrics.
2. **duration**: Time period for calculating the metric, in seconds, representing up to the current time.
3. **threshold**: Threshold value. When the calculated metric value reaches this threshold, the rule is triggered.
4. **probability**: Probability of triggering, optional, defaults to 100%, indicating that the rule will trigger at this probability when the metric value reaches the threshold.

### Metrics Supported by rate_limit_based_on_device_no
1. **single_command_hits**: Number of times a single device number accesses a specific interface.
2. **total_command_hits**: Total number of times a single device number accesses non-ignored interfaces.

### Metrics Supported by circuit_breaking_for_third_party_calls
1. **avg_exec_time**: Average execution time of the interface (in milliseconds).
2. **biz_fail_count**: Number of times the interface call returns an HTTP status code of 200, but the business logic is abnormal (i.e., the response contains a header: **x-response-code**, and its value is not 1).
3. **biz_fail_percent**: Percentage of interface calls that are successful but experience a business exception (biz_fail_count / total_calls * 100%).
4. **sys_fail_count**: Number of times the interface call returns an HTTP status code that is not 200.
5. **sys_fail_percent**: Percentage of failed interface calls (sys_fail_count / total_calls * 100%).
6. **fail_count**: Sum of the number of successful interface calls resulting in business exceptions and the number of failed interface calls.
7. **fail_percent**: Percentage of failed interface calls, including business exceptions ((biz_fail_count + sys_fail_count) / total_calls * 100%).

   

