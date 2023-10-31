# openresty-handy-tools
升级你的Nginx，通过编辑规则文件，实现灵活配置的客户端访问频次限制，为第三方接口调用增加熔断报警功能。

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
1. 接口调用失败: 即第三方返回的HTTP Status Code不是200
2. 接口调用成功但发生业务异常：第三方返回HTTP Status Code是200，但同时返回header: x-response-code 的值不是1

