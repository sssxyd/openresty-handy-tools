# openresty-handy-tools
升级你的Nginx，通过编辑规则文件，实现灵活配置的客户端访问频次限制，为第三方接口调用增加熔断报警功能。

## 安装Openresty及module
请参照官方文档安装[Openresty](https://openresty.org/cn/linux-packages.html) 
然后安装以下module 
openresty/lua-resty-redis 
openresty/lua-resty-upstream-healthcheck 
pintsized/lua-resty-http 

CentOS可以如下方式安装 
<pre lang="no-highlight"><code>
yum install -y yum-utils

# CentOS 8 or older
yum-config-manager --add-repo https://openresty.org/package/centos/openresty.repo
# CentOS 9 or later
yum-config-manager --add-repo https://openresty.org/package/centos/openresty2.repo

yum install -y openresty
yum install -y openresty-opm openresty-resty

opm get openresty/lua-resty-redis
opm get openresty/lua-resty-upstream-healthcheck
opm get pintsized/lua-resty-http

systemctl enable openresty

</code></pre>

## 配置速率限制
1. 将example_device_rate_limit目录中的内容覆盖到本地相同目录
2. 编辑nginx.conf，配置redis连接、缓存数据过期时间、健康检查地址
<pre lang="no-highlight"><code>
    init_by_lua_block {
        local restybase = require("restybase")
        restybase.init_by_lua_block({
            redis = {
                host = "127.0.0.1",     --redis host
                port = 6379,            --redis port
                auth = "password",      --redis requirepass
                pool_size = 32,         --client connection pool size
                idle_millis = 10000     --max milliseconds of a connection stays idle in the connection pool
            }, 
            rule_path = "/usr/local/openresty/nginx/conf/rules"
        })
        
        local rate_limit_based_on_device_no = require("rate_limit_based_on_device_no")
        rate_limit_based_on_device_no.init_by_lua_block({
            expired_seconds = 600       --redis key expired seconds
        })
    }
    init_worker_by_lua_block{
        local restybase = require("restybase")
        restybase.init_worker_by_lua_block()
        
        local hc = require("resty.upstream.healthcheck")
        
        local ok, err = hc.spawn_checker{
            shm = "healthcheck",  -- lua_shared_dict
            upstream = "device_rate_limit_backend",  -- upstream name
            type = "http",
            http_req = "GET /guest/healthcheck HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n",  -- http request for checking
            interval = 2000,  -- run the check cycle every 2 sec
            timeout = 1000,   -- 1 sec is the timeout for network operations
            fall = 3,  -- # of successive failures before turning a peer down
            rise = 2,  -- # of successive successes before turning a peer up
            valid_statuses = {200, 302},  -- a list valid HTTP status code
            concurrency = 10,  -- concurrency level for test requests
        }

        if not ok then
            ngx.log(ngx.ERR, "failed to spawn health checker: ", err)
            return
        end
    }	   
</code></pre>
3. 编辑conf.d/device_rate_limit.conf, 配置后端服务器、使用的现在规则JSON文件名称
<pre lang="no-highlight"><code>	   
#The name of this upstream. It has health checks configured in nginx.conf. 
#If you need to change the name, make sure to update it there as well
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
            local restybase = require("restybase")
            restybase.access_by_lua_block()
            
            local rate_limit_based_on_device_no = require("rate_limit_based_on_device_no")
            --set the name of the JSON-Formatted rule file used for validation
            if rate_limit_based_on_device_no.access_by_lua_block({
                rule="example_device_access_limit"
            }) then
                ngx.exit(429)  
            end
        }
        proxy_pass http://device_rate_limit_backend;
    }
} 
   </code></pre>
4. 在rules目录里新建或编辑规则JSON文件，可参加实例规则文件：example_device_access_limit.json

## 配置熔断&报警


## 编辑规则
### 路径
规则json文件默认路径为：/usr/local/openresty/nginx/conf/rules/

### 示例
example_rule_fuse.json
<pre lang="no-highlight"><code>
{
	"global":[
		{"feature": "avg_exec_time","duration": 60,"threshold": 500, "probability": 50},
		{"feature": "biz_fail_percent","duration": 60,"threshold": 10.5, "probability": 65},
		{"feature": "sys_fail_count","duration": 30,"threshold": 20, "probability": 66},
		{"feature": "fail_percent","duration": 60,"threshold": 50}
	],
	"commands":{
		"do_not_fusing/user.login": [],
		"custom_rules/get_orders": [
			{"feature": "avg_exec_time","duration": 60,"threshold": 1000},
			{"feature": "fail_count","duration": 30,"threshold": 1}
		]
	}
}
</code></pre>

### 说明
1. command即去除首个斜杠后的http请求路径
2. 优先采用commands中配置的接口规则，找不到则采用global规则
3. commands中配置了空规则，表示本接口忽略，不受限制

### 规则的结构
1. feature：指标名称，由lua模组提供，不同的模组支持不同的指标
2. duration：计算指标的时间段，单位为秒，表示迄今为止xx秒
3. threshold：阈值，计算出的指标值达到该阈值时，规则触发
4. probability：触发几率，可选，默认100%，表示指标值达到阈值时，以此几率触发规则

### rate_limit_based_on_device_no 支持的指标
1. single_command_hits：单一设备号访问特定接口的次数
2. total_command_hits：单一设备号访问未忽略接口的总次数

### circuit_breaking_for_third_party_calls 支持的指标
1. avg_exec_time: 接口执行的平均时间(毫秒)
2. biz_fail_count: 接口调用成功但发生业务异常的次数
3. biz_fail_percent: 接口调用成功但发生业务异常的次数/该接口总调用次数 * 100%
4. sys_fail_count: 接口调用失败的次数
5. sys_fail_percent: 接口调用失败的次数/该接口总调用次数 * 100%
6. fail_count: 接口调用成功但发生业务异常的次数 + 接口调用失败的次数
7. fail_percent: (接口调用成功但发生业务异常的次数 + 接口调用失败的次数)//该接口总调用次数 * 100%

#### 说明
1. 接口调用失败: 即第三方返回的 HTTP_Status_Code != 200
2. 接口调用成功但发生业务异常：第三方返回 HTTP_Status_Code == 200 && Response_Headers["x-response-code"] != 1
   

