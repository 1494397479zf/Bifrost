#!/bin/bash
# Bifrost 全量+增量同步配置脚本 - 纯 curl 实现
# 使用方法: bash setup_bifrost.sh [配置文件路径]
# 示例: bash setup_bifrost.sh configs/default.env

set -e  # 遇到错误立即退出

# 加载配置文件（如果提供）
if [ -n "$1" ] && [ -f "$1" ]; then
    echo "==> 加载配置文件: $1"
    source "$1"
    echo "✓ 配置文件加载完成"
    echo ""
fi

# ==================== 配置区域 ====================
# Bifrost服务地址（IDC环境需修改为实际IP）
BIFROST_URL="${BIFROST_URL:-https://127.0.0.1:21036}"
BIFROST_USER="${BIFROST_USER:-Bifrost}"
BIFROST_PASS="${BIFROST_PASS:-Bifrost123}"

# 源数据库配置
SOURCE_HOST="${SOURCE_HOST:-127.0.0.1}"
SOURCE_PORT="${SOURCE_PORT:-33063}"
SOURCE_USER="${SOURCE_USER:-root}"
SOURCE_PASS="${SOURCE_PASS:-root}"
SOURCE_DB="${SOURCE_DB:-sysbench}"

# 目标数据库配置
TARGET_HOST="${TARGET_HOST:-127.0.0.1}"
TARGET_PORT="${TARGET_PORT:-33064}"
TARGET_USER="${TARGET_USER:-root}"
TARGET_PASS="${TARGET_PASS:-root}"
TARGET_DB="${TARGET_DB:-sysbench}"

# Binlog配置（需要先查询源库的SHOW MASTER STATUS获取）
BINLOG_FILE="${BINLOG_FILE:-mysql-bin.000041}"
BINLOG_POS="${BINLOG_POS:-381835678}"

# 同步表列表（用空格分隔）
TABLES="${TABLES:-sbtest1 sbtest2 sbtest3 sbtest4 sbtest5 sbtest6 sbtest7 sbtest8 sbtest9 sbtest10}"

# 全量同步性能参数（可通过环境变量调整）
HISTORY_THREAD_NUM="${HISTORY_THREAD_NUM:-4}"              # 读取线程数
HISTORY_THREAD_COUNT_PER="${HISTORY_THREAD_COUNT_PER:-5000}"   # 每次读取行数
HISTORY_SYNC_THREAD_NUM="${HISTORY_SYNC_THREAD_NUM:-8}"    # 写入线程数
HISTORY_LIMIT_OPTIMIZE="${HISTORY_LIMIT_OPTIMIZE:-1}"      # LIMIT优化开关

# ==================== 以下无需修改 ====================
# Cookie文件（支持从环境变量传入，用于多实例隔离）
COOKIE_FILE="${COOKIE_FILE:-/tmp/bifrost_cookie.txt}"

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Bifrost 同步配置脚本${NC}"
echo -e "${GREEN}========================================${NC}\n"

# 步骤1: 登录
echo -e "${YELLOW}==> 步骤1: 登录 Bifrost...${NC}"
curl -k -s -c $COOKIE_FILE \
  -X POST "${BIFROST_URL}/dologin" \
  -H "Content-Type: application/json" \
  -d "{\"UserName\":\"${BIFROST_USER}\",\"Password\":\"${BIFROST_PASS}\"}" > /dev/null
echo -e "${GREEN}✓ 登录成功${NC}\n"

# 步骤2: 添加源数据库
echo -e "${YELLOW}==> 步骤2: 添加源数据库...${NC}"
SOURCE_URI="${SOURCE_USER}:${SOURCE_PASS}@tcp(${SOURCE_HOST}:${SOURCE_PORT})/${SOURCE_DB}"

curl -k -s -b $COOKIE_FILE \
  -X POST "${BIFROST_URL}/db/add" \
  -H "Content-Type: application/json" \
  -d "{
    \"DbName\": \"source\",
    \"InputType\": \"mysql\",
    \"Uri\": \"${SOURCE_URI}\",
    \"BinlogFileName\": \"${BINLOG_FILE}\",
    \"BinlogPosition\": ${BINLOG_POS},
    \"ServerId\": 1001,
    \"MaxBinlogFileName\": \"\",
    \"MaxBinlogPosition\": 0,
    \"Gtid\": \"\"
  }" 

echo -e "${GREEN}✓ 数据库添加完成${NC}\n"

# 步骤3: 准备目标URI（将在每张表配置时创建独立ToServer）
echo -e "${YELLOW}==> 步骤3: 准备目标服务器配置...${NC}"
TARGET_URI="${TARGET_USER}:${TARGET_PASS}@tcp(${TARGET_HOST}:${TARGET_PORT})/${TARGET_DB}"
echo -e "${GREEN}✓ 目标URI准备完成: ${TARGET_URI}${NC}\n"

# 步骤4: 不启动数据库连接（等全量完成后再启动）
echo -e "${YELLOW}==> 步骤4: 配置表和任务（暂不启动DB连接）...${NC}\n"

# 步骤5: 为每张表配置同步
CHANNEL_ID=1
declare -a TOSERVER_IDS
declare -a HISTORY_IDS

for TABLE in $TABLES; do
  echo -e "${YELLOW}==> 配置表: ${TABLE}${NC}"
  
  # 5.1 为该表创建独立的 ToServer
  TOSERVER_KEY="target_mysql_${SOURCE_DB}_${TABLE}"
  echo -e "   创建独立 ToServer: ${TOSERVER_KEY}"
  
  curl -k -s -b $COOKIE_FILE \
    -X POST "${BIFROST_URL}/toserver/add" \
    -H "Content-Type: application/json" \
    -d "{
      \"ToServerKey\": \"${TOSERVER_KEY}\",
      \"PluginName\": \"mysql\",
      \"ConnUri\": \"${TARGET_URI}\",
      \"Notes\": \"目标MySQL - ${SOURCE_DB}.${TABLE}专用\"
    }" > /dev/null
  
  # 5.2 添加表到 Channel (增量同步准备)
  curl -k -s -b $COOKIE_FILE \
    -X POST "${BIFROST_URL}/table/add" \
    -H "Content-Type: application/json" \
    -d "{
      \"DbName\": \"source\",
      \"SchemaName\": \"${SOURCE_DB}\",
      \"TableName\": \"${TABLE}\",
      \"ChannelId\": ${CHANNEL_ID}
    }" > /dev/null
  
  # 5.3 绑定表到该表专用的 ToServer (配置增量但不启动)
  RESP=$(curl -k -s -b $COOKIE_FILE \
    -X POST "${BIFROST_URL}/table/toserver/add" \
    -H "Content-Type: application/json" \
    -d "{
      \"DbName\": \"source\",
      \"SchemaName\": \"${SOURCE_DB}\",
      \"TableName\": \"${TABLE}\",
      \"ToServerKey\": \"${TOSERVER_KEY}\",
      \"PluginName\": \"mysql\",
      \"MustBeSuccess\": true,
      \"FilterQuery\": false,
      \"FilterUpdate\": false,
      \"FieldList\": [],
      \"PluginParam\": {
        \"SyncMode\": \"Normal\"
      }
    }")
  TOSERVER_ID=$(echo $RESP | sed 's/.*"data":\([0-9]*\).*/\1/')
  TOSERVER_IDS+=($TOSERVER_ID)
  
  # 5.4 添加全量同步任务 (History)
  RESP=$(curl -k -s -b $COOKIE_FILE \
    -X POST "${BIFROST_URL}/history/add" \
    -H "Content-Type: application/json" \
    -d "{
      \"DbName\": \"source\",
      \"SchemaName\": \"${SOURCE_DB}\",
      \"TableName\": \"${TABLE}\",
      \"TableNames\": \"${TABLE}\",
      \"ToserverIds\": [${TOSERVER_ID}],
      \"Property\": {
        \"ThreadNum\": ${HISTORY_THREAD_NUM},
        \"ThreadCountPer\": ${HISTORY_THREAD_COUNT_PER},
        \"SyncThreadNum\": ${HISTORY_SYNC_THREAD_NUM},
        \"LimitOptimize\": ${HISTORY_LIMIT_OPTIMIZE},
        \"Where\": \"\"
      }
    }")
  HISTORY_ID=$(echo $RESP | sed 's/.*"data":\([0-9]*\).*/\1/')
  HISTORY_IDS+=($HISTORY_ID)
  
  # 5.5 启动全量同步任务
  curl -k -s -b $COOKIE_FILE \
    -X POST "${BIFROST_URL}/history/start" \
    -H "Content-Type: application/json" \
    -d "{\"DbName\": \"source\", \"Id\": ${HISTORY_ID}}" > /dev/null
  
  echo -e "${GREEN}   ✓ ${TABLE} 配置完成 (ToServerKey=${TOSERVER_KEY}, ToServerID=${TOSERVER_ID}, HistoryID=${HISTORY_ID})${NC}"
done

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}✓ 全量同步任务已启动！${NC}"
echo -e "${GREEN}========================================${NC}\n"

echo "提示："
echo "- 全量同步已启动，增量同步配置完成但未启动（避免主键冲突）"
echo "- 监控全量进度: mysql -h${TARGET_HOST} -P${TARGET_PORT} -u${TARGET_USER} -p${TARGET_PASS} ${TARGET_DB} -e \"SELECT COUNT(*) FROM ${TABLES%% *}\""
echo "- 查看 History 状态: curl -k -c /tmp/cookie.txt -X POST '${BIFROST_URL}/dologin' -H 'Content-Type: application/json' -d '{\"UserName\":\"${BIFROST_USER}\",\"Password\":\"${BIFROST_PASS}\"}' && curl -k -b /tmp/cookie.txt '${BIFROST_URL}/history/list?DbName=source&SchemaName=${SOURCE_DB}&Status=all'"
echo "- 全量完成后，会自动启动DB连接和增量同步"
echo ""

# 不删除cookie，留给父脚本使用
# rm -f $COOKIE_FILE
