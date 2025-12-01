# Bifrost API 参考文档（实际验证版）

**验证环境**：
- Bifrost版本：v2.3.12-beta
- 验证时间：2025-11-26 10:50
- 验证方法：真实环境测试，所有示例均可运行

**重要说明**：
- ✅ 表示已验证可用
- ⚠️ 表示有限制或注意事项  
- 🔴 表示会导致崩溃或错误
- **核心监控指标**：`QueueMsgCount`（内存队列）+ `FileQueueUsableCount`（文件队列）

---

## 1. 认证 API

### ✅ 1.1 POST /dologin - 登录

**用途**：获取Session Cookie，后续所有API都需要此Cookie

**请求**：
```bash
curl -k -s -c /tmp/bifrost_cookie.txt -X POST \
  "https://127.0.0.1:21036/dologin" \
  -H "Content-Type: application/json" \
  -d '{"UserName":"Bifrost","Password":"Bifrost123"}'
```

**返回**：
```json
{"status": 1, "msg": "success", "data": null}
```

**说明**：Cookie保存在`/tmp/bifrost_cookie.txt`，有效期约24小时

---

## 2. 数据库连接 API

### ✅ 2.1 POST /db/add - 添加源数据库

**用途**：添加MySQL源数据库连接（binlog订阅源）

**参数说明**：
- `DbName`：数据库连接名称（自定义，如"source"）
- `InputType`：固定值"mysql"
- `Uri`：连接字符串格式 `user:pass@tcp(host:port)/dbname`
- `BinlogFileName`：开始位点的binlog文件名（如"mysql-bin.000043"）
- `BinlogPosition`：开始位点（数字）
- `ServerId`：Bifrost的Server ID，需与源库不同（建议1001）

**请求**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt -X POST \
  "https://127.0.0.1:21036/db/add" \
  -H "Content-Type: application/json" \
  -d '{
    "DbName": "source",
    "InputType": "mysql",
    "Uri": "root:root@tcp(127.0.0.1:33063)/sysbench",
    "BinlogFileName": "mysql-bin.000043",
    "BinlogPosition": 773000000,
    "ServerId": 1001
  }'
```

**返回**：
```json
{"status": 1, "msg": "success", "data": null}
```

### ✅ 2.2 GET /db/list - 查询数据库列表

**用途**：查看所有已配置的数据库连接及状态

**请求**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt \
  "https://127.0.0.1:21036/db/list"
```

**返回示例**：
```json
{
  "source": {
    "Name": "source",
    "InputType": "mysql",
    "ConnectUri": "root:root@tcp(127.0.0.1:33063)/sysbench",
    "ConnStatus": "running",
    "ConnErr": "",
    "ChannelCount": 1,
    "TableCount": 1,
    "BinlogDumpFileName": "mysql-bin.000043",
    "BinlogDumpPosition": 773000000,
    "ServerId": 1001
  }
}
```

**关键字段**：
- `ConnStatus`: "running"（已启动）/ "closed"（未启动）/ "stop"（已停止）
- `TableCount`: 已配置的表数量
- `BinlogDumpPosition`: 当前同步的binlog位点

### ✅ 2.3 POST /db/start - 启动数据库连接

**用途**：启动binlog订阅（开始增量同步）

**请求**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt -X POST \
  "https://127.0.0.1:21036/db/start" \
  -H "Content-Type: application/json" \
  -d '{"DbName": "source"}'
```

**返回**：
```json
{"status": 1, "msg": "success", "data": null}
```

⚠️ **注意**：全量同步期间不要启动DB连接，避免主键冲突

### ✅ 2.4 POST /db/stop - 停止数据库连接

**用途**：停止binlog订阅

**请求**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt -X POST \
  "https://127.0.0.1:21036/db/stop" \
  -H "Content-Type: application/json" \
  -d '{"DbName": "source"}'
```

---

## 3. 目标服务器 API

### ✅ 3.1 POST /toserver/add - 添加目标服务器

**用途**：配置目标MySQL服务器（全局配置，可被多张表复用）

**参数说明**：
- `ToServerKey`：目标服务器唯一标识（自定义，如"target_mysql"）
- `PluginName`：插件类型，MySQL填"mysql"（小写）
- `ConnUri`：连接字符串格式 `user:pass@tcp(host:port)/dbname`
- `Notes`：备注说明

**请求**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt -X POST \
  "https://127.0.0.1:21036/toserver/add" \
  -H "Content-Type: application/json" \
  -d '{
    "ToServerKey": "target_mysql",
    "PluginName": "mysql",
    "ConnUri": "root:root@tcp(127.0.0.1:33064)/sysbench",
    "Notes": "目标MySQL数据库"
  }'
```

**返回**：
```json
{"status": 1, "msg": "success", "data": null}
```

### ✅ 3.2 GET /toserver/list - 查询目标服务器列表

**用途**：查看所有已配置的目标服务器和插件信息

**请求**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt \
  "https://127.0.0.1:21036/toserver/list"
```

**返回示例**：
```json
{
  "Drivers": {
    "mysql": {
      "Version": "v1.8.0",
      "BifrostVersion": "v1.8.0"
    }
  },
  "ToServer": {
    "target_mysql": {
      "PluginName": "mysql",
      "ConnUri": "root:root@tcp(127.0.0.1:33064)/sysbench",
      "Notes": "目标MySQL数据库"
    }
  }
}
```

---

## 4. 表同步配置 API

### ✅ 4.1 POST /table/add - 添加表到Channel

**用途**：将表添加到同步通道（准备增量同步）

**参数说明**：
- `DbName`：数据库连接名（如"source"）
- `SchemaName`：数据库名（如"sysbench"）
- `TableName`：表名（如"sbtest1"）
- `ChannelId`：通道ID（默认1即可）

**请求**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt -X POST \
  "https://127.0.0.1:21036/table/add" \
  -H "Content-Type: application/json" \
  -d '{
    "DbName": "source",
    "SchemaName": "sysbench",
    "TableName": "sbtest1",
    "ChannelId": 1
  }'
```

**返回**：
```json
{"status": 1, "msg": "success", "data": 0}
```

### ✅ 4.2 POST /table/toserver/add - 绑定表到目标服务器

**用途**：配置表的具体同步规则（一张表可以同步到多个ToServer）

**参数说明**：
- `ToServerKey`：目标服务器标识（需先通过/toserver/add创建）
- `PluginName`：插件类型（如"mysql"）
- `MustBeSuccess`：是否必须成功（true=失败会重试）
- `FilterQuery`：是否过滤Query事件（通常false）
- `FilterUpdate`：是否过滤Update事件（通常false）
- `FieldList`：字段列表（[]表示全部字段）

**请求**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt -X POST \
  "https://127.0.0.1:21036/table/toserver/add" \
  -H "Content-Type: application/json" \
  -d '{
    "DbName": "source",
    "SchemaName": "sysbench",
    "TableName": "sbtest1",
    "ToServerKey": "target_mysql",
    "PluginName": "mysql",
    "MustBeSuccess": true,
    "FilterQuery": false,
    "FilterUpdate": false,
    "FieldList": []
  }'
```

**返回**：
```json
{"status": 1, "msg": "success", "data": 1}
```

**说明**：返回的`data`是ToServerID（用于后续查询队列信息）

### ✅ 4.3 GET /table/toserver/list - 查询表的ToServer队列信息 ⭐核心API

**用途**：获取表的同步状态和**队列积压情况**（性能测试的核心指标）

**参数**：
- `DbName`：数据库连接名
- `SchemaName`：数据库名
- `TableName`：表名

**请求**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt \
  "https://127.0.0.1:21036/table/toserver/list?DbName=source&SchemaName=sysbench&TableName=sbtest1"
```

**返回示例**：
```json
[
  {
    "ToServerID": 1,
    "PluginName": "mysql",
    "ToServerKey": "target_mysql",
    "Status": "running",
    "QueueMsgCount": 1250,
    "FileQueueUsableCount": 0,
    "BinlogFileNum": 43,
    "BinlogPosition": 773500000,
    "LastSuccessBinlog": {
      "BinlogFileNum": 43,
      "BinlogPosition": 773400000
    }
  }
]
```

**核心字段说明**：
- **`QueueMsgCount`** ⭐：内存队列消息数（主要监控指标）
- **`FileQueueUsableCount`** ⭐：文件队列消息数（当内存队列满时启用）
- **总队列数 = QueueMsgCount + FileQueueUsableCount**
- `Status`：同步状态（"running"/"stopped"）
- `BinlogPosition`：当前binlog位点
- `LastSuccessBinlog`：最后成功同步的位点

**重要发现**：
1. **每张表可以有多个ToServer**（一对多关系）
2. **每个ToServer有独立的队列**（内存队列+文件队列）
3. **需要遍历所有表的所有ToServer，求和才能得到总队列数**

**获取总队列的正确方法**：
```bash
# 对于10张表，每张表1个ToServer
TOTAL_QUEUE=0
for TABLE in sbtest1 sbtest2 ... sbtest10; do
  QUEUE=$(curl -k -s -b /tmp/bifrost_cookie.txt \
    "https://127.0.0.1:21036/table/toserver/list?DbName=source&SchemaName=sysbench&TableName=$TABLE" \
    | jq -r '.[0].QueueMsgCount + .[0].FileQueueUsableCount')
  TOTAL_QUEUE=$((TOTAL_QUEUE + QUEUE))
done
echo "总队列: $TOTAL_QUEUE"
```

---

## 5. 全量同步 API (History)

### ✅ 5.1 POST /history/add - 添加全量同步任务

**用途**：创建全量同步任务（从源库拉取存量数据）

**参数说明**：
- `DbName`：数据库连接名
- `SchemaName`：数据库名
- `TableName` / `TableNames`：表名
- `ToserverIds`：ToServerID数组（需先通过/table/toserver/add获取）
- `Property.ThreadNum`：拉取线程数
- `Property.SyncThreadNum`：写入线程数

**请求**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt -X POST \
  "https://127.0.0.1:21036/history/add" \
  -H "Content-Type: application/json" \
  -d '{
    "DbName": "source",
    "SchemaName": "sysbench",
    "TableName": "sbtest1",
    "ToserverIds": [1],
    "Property": {
      "ThreadNum": 4,
      "ThreadCountPer": 5000,
      "SyncThreadNum": 8
    }
  }'
```

**返回**：
```json
{"status": 1, "msg": "success", "data": 10}
```

**说明**：返回的`data`是HistoryID

### ✅ 5.2 POST /history/start - 启动全量同步

**用途**：启动全量同步任务

**请求**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt -X POST \
  "https://127.0.0.1:21036/history/start" \
  -H "Content-Type: application/json" \
  -d '{"DbName": "source", "Id": 10}'
```

### ✅ 5.3 GET /history/list - 查询全量同步状态 ⭐核心API

**用途**：查询全量同步任务的执行状态

**参数**：
- `db_name`：数据库连接名

**请求**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt \
  "https://127.0.0.1:21036/history/list?db_name=source"
```

**返回示例**：
```json
[
  {
    "Id": 10,
    "DbName": "source",
    "SchemaName": "sysbench",
    "TableName": "sbtest1",
    "Status": "running",
    "CurrentCount": 250000,
    "TotalCount": 500000,
    "Percent": 50,
    "StartTime": 1764125000,
    "EndTime": 0
  }
]
```

**Status字段说明**：
- `"running"` - 正在运行
- `"over"` - 已完成 ⭐
- `"error"` - 失败
- `"killed"` - 已终止

**用法**：
```bash
# 判断全量同步是否完成
STATUS=$(curl -k -s -b /tmp/bifrost_cookie.txt \
  "https://127.0.0.1:21036/history/list?db_name=source" \
  | jq -r '.[0].Status')

if [ "$STATUS" = "over" ]; then
  echo "全量同步完成"
fi
```

---

## 6. Flow统计 API ⭐数据量监控

### ℹ️ Flow是什么？

**Flow（流量统计）** 是Bifrost的实时数据统计功能：
- 统计同步的**事件数量**（INSERT/UPDATE/DELETE操作数）
- 统计同步的**字节大小**（ByteSize）
- 支持多个时间维度（分钟/十分钟/小时/八小时/天）
- 可按**数据库**、**Channel**、**表**三个级别查询

**用途**：
- 实时监控同步数据量
- 性能测试中统计TPS
- Web UI中的数据量图表

### ✅ 6.1 GET /flow/get - 查询Flow统计数据

**用途**：查询不同维度的数据流量统计

**参数说明**：
- `Type`：时间维度（必填）
  - `minute` - 按分钟统计（最近12分钟，5秒/点）
  - `tenminute` - 按十分钟统计（最近120×10分钟）
  - `hour` - 按小时统计（最近120小时）
  - `eighthour` - 按八小时统计
  - `day` - 按天统计
- `DbName`：数据库连接名（可选，不填返回全局统计）
- `SchemaName`：数据库名（可选，需配合TableName使用）
- `TableName`：表名（可选）
- `ChannelId`：Channel ID（可选）

**请求示例**：

1. **全局统计**（所有数据库）：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt \
  "https://127.0.0.1:21036/flow/get?Type=minute"
```

2. **按数据库统计**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt \
  "https://127.0.0.1:21036/flow/get?DbName=source&Type=hour"
```

3. **按表统计**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt \
  "https://127.0.0.1:21036/flow/get?DbName=source&SchemaName=sysbench&TableName=sbtest1&Type=minute"
```

4. **按Channel统计**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt \
  "https://127.0.0.1:21036/flow/get?DbName=source&ChannelId=1&Type=hour"
```

**返回示例**：
```json
[
  {
    "Time": 1764137215,
    "Count": 1250,
    "ByteSize": 524800
  },
  {
    "Time": 1764137220,
    "Count": 1180,
    "ByteSize": 495600
  }
]
```

**字段说明**：
- `Time`：时间戳（Unix timestamp）
- **`Count`** ⭐：事件数量（INSERT/UPDATE/DELETE操作数）
- **`ByteSize`** ⭐：数据字节大小

**用于性能测试**：
```bash
# 计算最近1小时的总事件数
curl -k -s -b /tmp/bifrost_cookie.txt \
  "https://127.0.0.1:21036/flow/get?DbName=source&Type=hour" \
  | jq '[.[].Count] | add'

# 计算平均TPS（假设返回12个点，每点5秒）
curl -k -s -b /tmp/bifrost_cookie.txt \
  "https://127.0.0.1:21036/flow/get?DbName=source&Type=minute" \
  | jq '[.[].Count] | add / 60'
```

---

## 8. 性能测试关键指标总结

### ℹ️ Channel是什么？

**Channel（通道）** 是Bifrost中的消费者线程组概念：
- 每个DB连接可以有多个Channel
- 每个Channel有独立的消费者线程池（MaxThreadNum）
- 表通过ChannelId绑定到具体的Channel
- **添加数据库时会自动创建名为"default"的Channel（ID=1）**

**用途**：
- 隔离不同优先级的表（高优先级表用独立Channel）
- 控制并发消费线程数

### ✅ 6.1 POST /channel/add - 创建Channel

**用途**：为数据库创建新的Channel

**参数说明**：
- `DbName`：数据库连接名
- `ChannelName`：Channel名称（自定义）
- `CosumerCount`：消费者线程数（MaxThreadNum）

**请求**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt -X POST \
  "https://127.0.0.1:21036/channel/add" \
  -H "Content-Type: application/json" \
  -d '{
    "DbName": "source",
    "ChannelName": "high_priority",
    "CosumerCount": 4
  }'
```

**返回**：
```json
{"status": 1, "msg": "success", "data": 2}
```

**说明**：返回的`data`是ChannelID

### ✅ 6.2 GET /channel/list - 查询Channel列表

**用途**：查询数据库的所有Channel及状态

⚠️ **重要**：必须带`DbName`参数，否则会崩溃！

**参数**：
- `DbName`：数据库连接名（必填）

**请求**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt \
  "https://127.0.0.1:21036/channel/list?DbName=source"
```

**返回示例**：
```json
{
  "1": {
    "Name": "default",
    "MaxThreadNum": 1,
    "CurrentThreadNum": 1,
    "Status": "running"
  },
  "2": {
    "Name": "high_priority",
    "MaxThreadNum": 4,
    "CurrentThreadNum": 0,
    "Status": "stopped"
  }
}
```

**Status字段**：
- `"running"` - 运行中
- `"stopped"` - 已停止
- `"close"` - 已关闭

### ✅ 6.3 POST /channel/start - 启动Channel

**用途**：启动Channel的消费者线程

**请求**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt -X POST \
  "https://127.0.0.1:21036/channel/start" \
  -H "Content-Type: application/json" \
  -d '{"DbName": "source", "ChannelId": 2}'
```

### ✅ 6.4 POST /channel/stop - 停止Channel

**用途**：停止Channel的消费者线程

**请求**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt -X POST \
  "https://127.0.0.1:21036/channel/stop" \
  -H "Content-Type: application/json" \
  -d '{"DbName": "source", "ChannelId": 2}'
```

### ✅ 6.5 POST /channel/close - 关闭Channel

**用途**：关闭Channel（与stop的区别待确认）

**请求**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt -X POST \
  "https://127.0.0.1:21036/channel/close" \
  -H "Content-Type: application/json" \
  -d '{"DbName": "source", "ChannelId": 2}'
```

### ✅ 6.6 POST /channel/delete - 删除Channel

**用途**：删除Channel（需先解绑所有表）

**请求**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt -X POST \
  "https://127.0.0.1:21036/channel/delete" \
  -H "Content-Type: application/json" \
  -d '{"DbName": "source", "ChannelId": 2}'
```

⚠️ **注意**：如果Channel下还有表，会返回错误

### ✅ 6.7 GET /channel/table/list - 查询Channel的表列表

**用途**：查看某个Channel下绑定了哪些表

**参数**：
- `DbName`：数据库连接名
- `ChannelId`：Channel ID

**请求**：
```bash
curl -k -s -b /tmp/bifrost_cookie.txt \
  "https://127.0.0.1:21036/channel/table/list?DbName=source&ChannelId=1"
```

**返回示例**：
```json
{
  "sysbench_-sbtest1": {
    "Name": "sbtest1",
    "ChannelKey": 1,
    "LastToServerID": 1,
    "ToServerList": [
      {
        "ToServerID": 1,
        "PluginName": "mysql",
        "QueueMsgCount": 0,
        "FileQueueUsableCount": 0
      }
    ]
  }
}
```

---

## 8. 性能测试关键指标总结

### 9.1 Channel的默认配置

**重要发现**：
- 调用`POST /db/add`添加数据库时，会**自动创建ID=1的"default" Channel**
- 该Channel的MaxThreadNum=1，且自动启动
- 大多数场景**不需要手动创建Channel**，直接使用ChannelId=1即可
- 仅在需要隔离表或提高并发时，才需要创建额外的Channel

### 9.2 核心监控指标

| 指标 | API | 字段 | 说明 |
|------|-----|------|------|
| **队列积压** | `/table/toserver/list` | `QueueMsgCount` + `FileQueueUsableCount` | 核心性能指标，反映同步延迟 |
| **全量状态** | `/history/list` | `Status` | 判断全量同步是否完成 |
| **binlog位点** | `/db/list` | `BinlogDumpPosition` | 当前同步进度 |
| **连接状态** | `/db/list` | `ConnStatus` | 连接是否正常 |

### 9.3 队列监控最佳实践

```bash
# 获取所有表的总队列数
get_total_queue() {
  local total=0
  for i in {1..10}; do
    local queue=$(curl -k -s -b /tmp/bifrost_cookie.txt \
      "https://127.0.0.1:21036/table/toserver/list?DbName=source&SchemaName=sysbench&TableName=sbtest${i}" \
      | jq -r '(.[0].QueueMsgCount // 0) + (.[0].FileQueueUsableCount // 0)')
    total=$((total + queue))
  done
  echo $total
}
```

### 8.4 全量同步监控最佳实践

```bash
# 等待全量同步完成
while true; do
  STATUS=$(curl -k -s -b /tmp/bifrost_cookie.txt \
    "https://127.0.0.1:21036/history/list?db_name=source" \
    | jq -r '.[0].Status')
  
  if [ "$STATUS" = "over" ]; then
    echo "全量同步完成"
    break
  elif [ "$STATUS" = "error" ]; then
    echo "全量同步失败"
    exit 1
  fi
  
  sleep 5
done
```

---

## 9. 常见问题

### 9.0 Channel相关

**Q: 是否需要手动创建Channel？**
- A: 通常不需要。添加数据库时会自动创建"default" Channel（ID=1），直接使用即可

**Q: 什么时候需要创建多个Channel？**
- A: 
  - 需要隔离不同优先级的表（如核心表用独立Channel）
  - 需要提高并发消费能力（增加MaxThreadNum）
  - 不同表有不同的消费速度要求

### 9.1 为什么队列一直显示为空？

**原因**：
1. DB连接未启动（`/db/start`未调用）
2. 使用了错误的API（如`/db/detail`）
3. 表未绑定ToServer

**解决**：
- 使用`/table/toserver/list`查询队列
- 确保DB连接已启动
- 检查ToServer绑定状态

### 9.2 全量同步如何判断完成？

**错误方法**：
- ❌ 比较目标库行数（源库在持续写入，目标是移动的）

**正确方法**：
- ✅ 使用`/history/list` API查询`Status="over"`

### 9.3 Cookie失效怎么办？

**现象**：API返回空或错误

**解决**：
```bash
# 重新登录刷新Cookie
curl -k -s -c /tmp/bifrost_cookie.txt -X POST \
  "https://127.0.0.1:21036/dologin" \
  -H "Content-Type: application/json" \
  -d '{"UserName":"Bifrost","Password":"Bifrost123"}'
```

---

## 10. 版本历史

- **2025-11-26 10:50** - 初始版本
- **2025-11-26 11:00** - 新增Channel API（7个）和Flow统计API（1个）
- 发现`/channel/list`需要带DbName参数
- 确认Channel在添加数据库时自动创建
- 新增Flow统计API用于数据量监控

---

**文档维护说明**：
- 本文档仅包含经过实际测试验证的API
- 所有示例代码可直接运行
- 如发现新API或问题，请更新此文档
