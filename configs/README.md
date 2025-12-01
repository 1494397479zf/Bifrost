# Bifrost同步任务配置文件说明

## 使用方法

### 1. 使用配置文件运行

```bash
# 使用指定配置文件
bash setup_bifrost_example.sh configs/task_example.env

# 使用默认配置
bash setup_bifrost_example.sh configs/default.env
```

### 2. 并行运行多个任务

```bash
# 终端1: 运行任务1
bash setup_bifrost_example.sh configs/task1.env &

# 终端2: 运行任务2
bash setup_bifrost_example.sh configs/task2.env &
```

**注意**: 不同终端的环境变量互不干扰，Cookie文件使用进程ID隔离（`/tmp/bifrost_cookie_$$.txt`），可以安全并行。

### 3. 不使用配置文件（兼容旧方式）

```bash
# 直接运行（使用脚本内默认配置）
bash setup_bifrost_example.sh
```

## 配置文件参数说明

### Bifrost服务配置

- `BIFROST_URL`: Bifrost服务地址（如 `https://127.0.0.1:21036`）
- `BIFROST_USER`: Bifrost用户名
- `BIFROST_PASS`: Bifrost密码

### 源MySQL配置

- `SOURCE_HOST`: 源MySQL地址
- `SOURCE_PORT`: 源MySQL端口
- `SOURCE_USER`: 源MySQL用户
- `SOURCE_PASS`: 源MySQL密码
- `SOURCE_DB`: 源数据库名

### 目标MySQL配置

- `TARGET_HOST`: 目标MySQL地址
- `TARGET_PORT`: 目标MySQL端口
- `TARGET_USER`: 目标MySQL用户
- `TARGET_PASS`: 目标MySQL密码
- `TARGET_DB`: 目标数据库名

### 同步表配置

- `TABLES`: 要同步的表列表（空格分隔）
  - 示例: `TABLES="sbtest1 sbtest2 sbtest3"`

### 压测配置

- `ENABLE_SYSBENCH`: 是否启用sysbench增量压测（`true`/`false`）
- `SYSBENCH_THREADS`: 压测线程数（默认10）
- `SYSBENCH_TIME`: 压测时长，单位秒（默认30）
- `SYSBENCH_TABLES`: 压测表数量（默认10）
- `SYSBENCH_TABLE_SIZE`: 每张表的数据量（默认200000）

## 配置文件示例

### default.env - 本地测试环境

```bash
BIFROST_URL="https://127.0.0.1:21036"
SOURCE_HOST="127.0.0.1"
SOURCE_PORT="33063"
TARGET_HOST="127.0.0.1"
TARGET_PORT="33064"
TABLES="sbtest1 sbtest2 sbtest3"
ENABLE_SYSBENCH=true
```

### task_example.env - IDC环境

```bash
BIFROST_URL="https://127.0.0.1:21036"
SOURCE_HOST="11.150.106.237"
SOURCE_PORT="20000"
TARGET_HOST="127.0.0.1"
TARGET_PORT="33064"
TABLES="sbtest1 sbtest2 sbtest3"
ENABLE_SYSBENCH=false  # IDC环境不需要本地压测
```

## 关键特性

### 1. 进程隔离

- **Cookie文件**: 使用 `/tmp/bifrost_cookie_$$.txt`（`$$`是进程ID）
- **多实例支持**: 可以同时运行多个脚本实例而不冲突

### 2. 压测开关

- **启用压测**: `ENABLE_SYSBENCH=true`
  - 在全量同步完成后，自动执行sysbench压测
  - 压测前会检查目标库表是否已创建
  
- **禁用压测**: `ENABLE_SYSBENCH=false`
  - 跳过sysbench压测
  - 适用于IDC环境或不需要自动压测的场景

### 3. 安全检查

- **表存在性检查**: 压测前检查目标库第一张表是否存在
  - 如果表不存在，跳过压测并输出警告
  - 避免 `Table doesn't exist` 错误

## 常见问题

### Q1: 如何同时运行多个同步任务？

创建多个配置文件（如 `task1.env`, `task2.env`），在不同终端运行：

```bash
# 终端1
bash setup_bifrost_example.sh configs/task1.env

# 终端2
bash setup_bifrost_example.sh configs/task2.env
```

### Q2: 为什么压测被跳过？

检查以下几点：
1. `ENABLE_SYSBENCH` 是否设置为 `true`
2. 目标库表是否已创建（脚本会自动检查）
3. 查看日志中的警告信息

### Q3: 如何只做全量同步，不压测？

在配置文件中设置 `ENABLE_SYSBENCH=false`。

### Q4: 配置文件路径可以是相对路径吗？

可以，支持相对路径和绝对路径：

```bash
# 相对路径
bash setup_bifrost_example.sh configs/task1.env

# 绝对路径
bash setup_bifrost_example.sh /data/configs/task1.env
```
