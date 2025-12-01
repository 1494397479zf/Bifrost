#!/bin/bash
# IDC环境使用示例 - 自动获取binlog位点

# 使用pipefail：管道中任一命令失败都会导致整个管道失败
# 但不使用-e，避免意外退出
set -o pipefail

# 添加MySQL路径到PATH（避免command not found）
export PATH="/home/ventuszhou/mysql/bin:$PATH"

# Cookie文件路径（用于Bifrost API认证）
# 使用进程ID隔离，支持多个脚本实例并行运行
COOKIE_FILE="/tmp/bifrost_cookie_$$.txt"
# 导出供子脚本使用
export COOKIE_FILE

# ==================== 加载配置文件 ====================
if [ -n "$1" ] && [ -f "$1" ]; then
    echo "正在加载配置文件: $1"
    source "$1"
    echo "✓ 配置文件加载完成"
    echo ""
else
    # 如果没有提供配置文件，使用默认配置
    echo "未提供配置文件，使用脚本内默认配置"
    echo "用法: bash $0 configs/your_config.env"
    echo ""
    
    # ==================== 默认配置区域 ====================
    # Bifrost服务配置
    export BIFROST_URL="https://127.0.0.1:21036"        # Bifrost服务地址
    export BIFROST_USER="Bifrost"                        # Bifrost用户名
    export BIFROST_PASS="Bifrost123"                     # Bifrost密码
    
    # 源MySQL配置
    export SOURCE_HOST="127.0.0.1"                      # 源MySQL地址
    export SOURCE_PORT="33063"                            # 源MySQL端口
    export SOURCE_USER="root"                            # 源MySQL用户
    export SOURCE_PASS="root"                   # 源MySQL密码
    export SOURCE_DB="sysbench"                     # 源数据库名
    
    # 目标MySQL配置
    export TARGET_HOST="127.0.0.1"                      # 目标MySQL地址
    export TARGET_PORT="33064"                            # 目标MySQL端口
    export TARGET_USER="root"                            # 目标MySQL用户
    export TARGET_PASS="root"                   # 目标MySQL密码
    export TARGET_DB="sysbench"                     # 目标数据库名
    
    # 要同步的表列表（空格分隔）
    export TABLES="sbtest1"
    
    # 压测配置
    export ENABLE_SYSBENCH=true
    export SYSBENCH_THREADS=10
    export SYSBENCH_TIME=30
    export SYSBENCH_TABLES=10
    export SYSBENCH_TABLE_SIZE=200000
    
    # 校验配置
    export CHECKSUM_WAIT_TIME=10  # 全量同步完成后等待多少秒再执行checksum（默认10秒）
fi
# ==================== 自动获取binlog位点 ====================
echo "正在获取源库binlog位点..."

# 执行SHOW MASTER STATUS并解析结果
echo "尝试连接源库: mysql -h${SOURCE_HOST} -P${SOURCE_PORT} -u${SOURCE_USER}"
BINLOG_INFO=$(mysql -h${SOURCE_HOST} -P${SOURCE_PORT} -u${SOURCE_USER} -p${SOURCE_PASS} -e "SHOW MASTER STATUS\G" 2>&1)
MYSQL_EXIT_CODE=$?

if [ $MYSQL_EXIT_CODE -ne 0 ]; then
    echo "错误: MySQL命令执行失败（退出码: $MYSQL_EXIT_CODE）"
    echo "$BINLOG_INFO"
    exit 1
fi

if [ -z "$BINLOG_INFO" ]; then
    echo "错误: 无法连接到源数据库或获取binlog信息"
    echo "请检查SOURCE_HOST, SOURCE_PORT, SOURCE_USER, SOURCE_PASS配置"
    exit 1
fi

# 检查是否有错误信息（排除Warning）
if echo "$BINLOG_INFO" | grep -qi "ERROR"; then
    echo "错误: MySQL执行失败"
    echo "$BINLOG_INFO"
    exit 1
fi

# 提取binlog文件名和位置
export BINLOG_FILE=$(echo "$BINLOG_INFO" | grep -i "File:" | awk '{print $NF}')
export BINLOG_POS=$(echo "$BINLOG_INFO" | grep -i "Position:" | awk '{print $NF}')

if [ -z "$BINLOG_FILE" ] || [ -z "$BINLOG_POS" ]; then
    echo "错误: 无法解析binlog信息"
    echo "完整输出："
    echo "$BINLOG_INFO"
    exit 1
fi

echo "✓ 获取到binlog位点: $BINLOG_FILE @ $BINLOG_POS"
echo ""

# ==================== 辅助函数 ====================
# 停止DB连接
stop_db_connection() {
    echo "停止DB连接..."
    curl -sk -u "${BIFROST_USER}:${BIFROST_PASS}" \
        -X POST "${BIFROST_URL}/db/stop" \
        -H "Content-Type: application/json" \
        -d '{"DbName": "source"}' > /dev/null 2>&1
}

# 启动DB连接
start_db_connection() {
    echo "启动DB连接..."
    curl -sk -u "${BIFROST_USER}:${BIFROST_PASS}" \
        -X POST "${BIFROST_URL}/db/start" \
        -H "Content-Type: application/json" \
        -d '{"DbName": "source"}' > /dev/null 2>&1
}

# ==================== 执行同步配置 ====================
echo "================================"
echo "开始配置Bifrost同步任务..."
echo "================================"
CONFIG_START=$(date +%s)

# 调用setup_bifrost.sh，并传递配置文件参数（如果有）
if [ -n "$1" ] && [ -f "$1" ]; then
    bash setup_bifrost.sh "$1"
else
    bash setup_bifrost.sh
fi

CONFIG_END=$(date +%s)
CONFIG_TIME=$((CONFIG_END - CONFIG_START))

echo ""
echo "================================"
echo "配置完成，耗时: ${CONFIG_TIME} 秒"
echo "================================"
echo ""

# ==================== 全量同步监控 ====================
echo "开始监控全量同步进度 (通过History任务状态)..."
echo "--------------------------------"

SYNC_START=$(date +%s)
CHECK_INTERVAL=5

while true; do
    # 查询History任务状态
    HISTORY_STATUS=$(curl -sk -u "${BIFROST_USER}:${BIFROST_PASS}" \
        "${BIFROST_URL}/history/list?db_name=source" 2>/dev/null | \
        jq -r '.[0].Status' 2>/dev/null)
    
    if [ -z "$HISTORY_STATUS" ]; then
        echo "警告: 无法获取History任务状态"
        sleep $CHECK_INTERVAL
        continue
    fi
    
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - SYNC_START))
    
    echo "[$TIMESTAMP] History任务状态: $HISTORY_STATUS (已运行 ${ELAPSED} 秒)"
    
    # 检查是否完成
    if [ "$HISTORY_STATUS" = "over" ]; then
        SYNC_END=$(date +%s)
        SYNC_TIME=$((SYNC_END - SYNC_START))
        echo ""
        echo "✓ 全量同步完成！"
        echo "  History任务状态: over"
        echo "  全量耗时: ${SYNC_TIME} 秒"
        
        # 全量完成后，启动DB连接
        # 注意：不需要手动启动ToServer，当DB连接启动并开始消费binlog时，
        # ToServer会自动启动（通过sendToServerResult方法）
        echo ""
        echo "开始启动DB连接..."
        start_db_connection
        sleep 5
        
        echo "✓ DB连接已启动，ToServer将在收到binlog数据后自动启动"
        break
    elif [ "$HISTORY_STATUS" = "error" ]; then
        echo ""
        echo "✗ 全量同步出错！"
        echo "  History任务状态: error"
        exit 1
    elif [ "$HISTORY_STATUS" = "killed" ]; then
        echo ""
        echo "⚠ 全量同步已停止"
        echo "  History任务状态: killed"
        exit 1
    fi
    
    sleep $CHECK_INTERVAL
done

echo ""
echo "================================"
echo "开始增量同步测试..."
echo "================================"

# ==================== 增量同步测试 ====================
# DB连接和增量ToServer已在全量完成后启动

# 检查是否启用sysbench压测
if [ "${ENABLE_SYSBENCH}" = "true" ]; then
    echo "DB连接和增量同步已在运行，开始sysbench压测..."
    echo ""
    
    # 在压测前，检查目标库表是否已创建
    echo "检查目标库表是否已创建..."
    FIRST_TABLE=$(echo $TABLES | awk '{print $1}')
    TABLE_EXISTS=$(mysql -h${TARGET_HOST} -P${TARGET_PORT} -u${TARGET_USER} -p${TARGET_PASS} -D${TARGET_DB} \
        -N -e "SHOW TABLES LIKE '${FIRST_TABLE}'" 2>/dev/null)
    
    if [ -z "$TABLE_EXISTS" ]; then
        echo "⚠ 警告: 目标库表 ${FIRST_TABLE} 不存在，跳过sysbench压测"
        echo "  可能原因: 全量同步虽显示完成，但表未实际创建"
        echo "  建议: 检查Bifrost全量同步日志和目标库配置"
        echo ""
        INCR_TIME=0
    else
        echo "✓ 目标库表已存在，继续执行压测"
        echo ""
        
        # 使用sysbench模拟增量写入
        INCR_START=$(date +%s)
        
        echo "使用sysbench模拟增量写入..."
        echo "参数: ${SYSBENCH_THREADS}个线程, 持续${SYSBENCH_TIME}秒, oltp_read_write模式"
        echo ""
        
        sysbench oltp_read_write \
           --mysql-host=${SOURCE_HOST} \
           --mysql-port=${SOURCE_PORT} \
           --mysql-user=${SOURCE_USER} \
           --mysql-password=${SOURCE_PASS} \
           --mysql-db=${SOURCE_DB} \
           --tables=${SYSBENCH_TABLES} \
           --table-size=${SYSBENCH_TABLE_SIZE} \
           --threads=${SYSBENCH_THREADS} \
           --time=${SYSBENCH_TIME} \
           --report-interval=5 \
           run
        
        INCR_END=$(date +%s)
        INCR_TIME=$((INCR_END - INCR_START))
        
        echo ""
        echo "✓ sysbench压测完成，耗时: ${INCR_TIME} 秒"
        echo ""
    fi
else
    echo "ENABLE_SYSBENCH=false，跳过sysbench增量压测"
    echo "DB连接和增量同步已在运行，等待手动数据变更..."
    echo ""
    INCR_TIME=0
fi

# ==================== 等待增量同步完成 ====================
echo "================================"
echo "等待增量数据同步完成..."
echo "================================"

# 重新登录获取cookie（用于后续API调用）
echo "重新登录Bifrost以监控同步状态..."
LOGIN_RESP=$(curl -k -s -c $COOKIE_FILE \
  -X POST "${BIFROST_URL}/dologin" \
  -H "Content-Type: application/json" \
  -d "{\"UserName\":\"${BIFROST_USER}\",\"Password\":\"${BIFROST_PASS}\"}")

# 检查登录是否成功
if [ -z "$LOGIN_RESP" ]; then
    echo "错误: Bifrost登录无响应"
    exit 1
fi

if echo "$LOGIN_RESP" | grep -qi "error\|fail"; then
    echo "错误: Bifrost登录失败"
    echo "$LOGIN_RESP"
    exit 1
fi

echo "✓ 登录成功"
echo ""

SYNC_WAIT_START=$(date +%s)

# 使用Bifrost的ToServer状态来判断同步是否完成
# 判断标准：所有ToServer的队列为空且位点一致
MAX_WAIT=300  # 最大等待5分钟
WAIT_TIME=0
CHECK_INTERVAL=5  # 每5秒检查一次

echo "开始监控Bifrost ToServer同步状态..."
echo "说明: 等待所有表的ToServer队列为空(QueueMsgCount=0)"
echo ""

SYNC_COMPLETED=false

while [ "$SYNC_COMPLETED" = false ] && [ $WAIT_TIME -lt $MAX_WAIT ]; do
    sleep $CHECK_INTERVAL
    WAIT_TIME=$((WAIT_TIME + CHECK_INTERVAL))
    
    # 检查所有表的ToServer状态
    ALL_SYNCED=true
    PENDING_INFO=""
    TOTAL_QUEUE=0
    
    for TABLE in $TABLES; do
        # 获取ToServer信息，使用cookie认证，注意参数名大小写
        TOSERVER_RESPONSE=$(curl -sk -b $COOKIE_FILE \
            "${BIFROST_URL}/table/toserver/list?DbName=source&SchemaName=${SOURCE_DB}&TableName=${TABLE}" 2>/dev/null)
        
        # 使用python3解析JSON，处理各种异常情况
        QUEUE_COUNT=$(echo "$TOSERVER_RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if isinstance(data, list) and len(data) > 0:
        print(data[0].get('QueueMsgCount', -1))
    else:
        print(-1)
except:
    print(-1)
" 2>/dev/null)
        
        # 如果没有获取到或解析失败，记录详细信息
        if [ -z "$QUEUE_COUNT" ] || [ "$QUEUE_COUNT" = "-1" ]; then
            ALL_SYNCED=false
            # 判断失败原因
            if [ -z "$TOSERVER_RESPONSE" ]; then
                PENDING_INFO="${PENDING_INFO}${TABLE}(curl失败) "
            elif echo "$TOSERVER_RESPONSE" | grep -q "^\[\]$"; then
                PENDING_INFO="${PENDING_INFO}${TABLE}(ToServer未启动) "
            else
                PENDING_INFO="${PENDING_INFO}${TABLE}(解析失败) "
            fi
            continue
        fi
        
        TOTAL_QUEUE=$((TOTAL_QUEUE + QUEUE_COUNT))
        
        if [ "$QUEUE_COUNT" -gt 0 ]; then
            ALL_SYNCED=false
            PENDING_INFO="${PENDING_INFO}${TABLE}(队列:${QUEUE_COUNT}) "
        fi
    done
    
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [ "$ALL_SYNCED" = true ]; then
        SYNC_COMPLETED=true
        echo "[$TIMESTAMP] ✓ 所有ToServer队列已清空 (总队列消息:0, 等待:${WAIT_TIME}/${MAX_WAIT}秒)"
    else
        echo "[$TIMESTAMP] 同步进行中: $PENDING_INFO (总队列:$TOTAL_QUEUE, 等待:${WAIT_TIME}/${MAX_WAIT}秒)"
    fi
done

SYNC_WAIT_END=$(date +%s)
SYNC_WAIT_TIME=$((SYNC_WAIT_END - SYNC_WAIT_START))

echo ""
if [ "$SYNC_COMPLETED" = true ]; then
    echo "✓ 增量数据同步完成！(所有ToServer队列已清空)"
    echo "  等待耗时: ${SYNC_WAIT_TIME} 秒"
else
    echo "⚠ 等待超时，但继续进行校验"
    echo "  等待耗时: ${SYNC_WAIT_TIME} 秒"
fi
echo ""

# ==================== 等待后再校验 ====================
WAIT_BEFORE_CHECKSUM=${CHECKSUM_WAIT_TIME:-10}

if [ "$WAIT_BEFORE_CHECKSUM" -gt 0 ]; then
    echo "================================"
    echo "等待 ${WAIT_BEFORE_CHECKSUM} 秒后再执行checksum校验..."
    echo "（确保所有数据完全落盘，避免误报）"
    echo "================================"
    
    for i in $(seq $WAIT_BEFORE_CHECKSUM -1 1); do
        printf "\r剩余等待时间: %d 秒..." $i
        sleep 1
    done
    echo ""
    echo "✓ 等待完成"
    echo ""
fi

# ==================== 数据一致性校验 ====================
echo ""
echo "================================"
echo "开始数据一致性校验 (CHECKSUM)"
echo "================================"
CHECKSUM_START=$(date +%s)

# 统计变量
CHECKSUM_PASS=0
CHECKSUM_FAIL=0
CHECKSUM_ERROR=0

# 遍历所有表进行checksum
for TABLE in $TABLES; do
    echo ""
    echo "校验表: $TABLE"
    echo "--------------------------------"
    
    # 源库checksum (EXTENDED模式)
    SOURCE_CHECKSUM=$(mysql -h${SOURCE_HOST} -P${SOURCE_PORT} -u${SOURCE_USER} -p${SOURCE_PASS} -D${SOURCE_DB} \
        -N -e "CHECKSUM TABLE \`$TABLE\` EXTENDED;" 2>/dev/null | awk '{print $2}')
    
    if [ -z "$SOURCE_CHECKSUM" ]; then
        echo "✗ 源库checksum失败"
        CHECKSUM_ERROR=$((CHECKSUM_ERROR + 1))
        continue
    fi
    
    # 目标库checksum (EXTENDED模式)
    TARGET_CHECKSUM=$(mysql -h${TARGET_HOST} -P${TARGET_PORT} -u${TARGET_USER} -p${TARGET_PASS} -D${TARGET_DB} \
        -N -e "CHECKSUM TABLE \`$TABLE\` EXTENDED;" 2>/dev/null | awk '{print $2}')
    
    if [ -z "$TARGET_CHECKSUM" ]; then
        echo "✗ 目标库checksum失败"
        CHECKSUM_ERROR=$((CHECKSUM_ERROR + 1))
        continue
    fi
    
    # 对比checksum
    echo "  源库 checksum: $SOURCE_CHECKSUM"
    echo "  目标库checksum: $TARGET_CHECKSUM"
    
    if [ "$SOURCE_CHECKSUM" = "$TARGET_CHECKSUM" ]; then
        echo "  ✓ 数据一致"
        CHECKSUM_PASS=$((CHECKSUM_PASS + 1))
    else
        echo "  ✗ 数据不一致！"
        CHECKSUM_FAIL=$((CHECKSUM_FAIL + 1))
        
        # 显示行数对比
        SOURCE_ROWS=$(mysql -h${SOURCE_HOST} -P${SOURCE_PORT} -u${SOURCE_USER} -p${SOURCE_PASS} -D${SOURCE_DB} \
            -N -e "SELECT COUNT(*) FROM \`$TABLE\`" 2>/dev/null)
        TARGET_ROWS=$(mysql -h${TARGET_HOST} -P${TARGET_PORT} -u${TARGET_USER} -p${TARGET_PASS} -D${TARGET_DB} \
            -N -e "SELECT COUNT(*) FROM \`$TABLE\`" 2>/dev/null)
        echo "  源库行数: $SOURCE_ROWS, 目标库行数: $TARGET_ROWS"
    fi
done

CHECKSUM_END=$(date +%s)
CHECKSUM_TIME=$((CHECKSUM_END - CHECKSUM_START))

echo ""
echo "================================"
echo "CHECKSUM 校验结果汇总"
echo "================================"
echo "总表数:       $(echo $TABLES | wc -w)"
echo "校验通过:     $CHECKSUM_PASS 张表"
echo "校验失败:     $CHECKSUM_FAIL 张表"
echo "校验错误:     $CHECKSUM_ERROR 张表"
echo "校验耗时:     ${CHECKSUM_TIME} 秒"
echo "================================"

if [ $CHECKSUM_FAIL -gt 0 ]; then
    echo "⚠ 存在数据不一致的表！"
elif [ $CHECKSUM_ERROR -gt 0 ]; then
    echo "⚠ 部分表校验出错"
else
    echo "✓ 所有表数据一致性校验通过！"
fi
echo ""

# ==================== 总结 ====================
TOTAL_TIME=$((CONFIG_TIME + SYNC_TIME + INCR_TIME + SYNC_WAIT_TIME + CHECKSUM_TIME))

echo ""
echo "================================"
echo "测试完成统计"
echo "================================"
echo "配置耗时:     ${CONFIG_TIME} 秒"
echo "全量同步:     ${SYNC_TIME} 秒"
echo "增量压测:     ${INCR_TIME} 秒"
echo "同步等待:     ${SYNC_WAIT_TIME} 秒"
echo "数据校验:     ${CHECKSUM_TIME} 秒 (通过 ${CHECKSUM_PASS}/$(echo $TABLES | wc -w) 张表)"
echo "总耗时:       ${TOTAL_TIME} 秒"
echo "================================"
echo ""
echo "注意: 增量同步会持续运行，除非手动停止"
echo "停止方法: curl -sk -u ${BIFROST_USER}:${BIFROST_PASS} -X POST ${BIFROST_URL}/db/stop -d '{\"DbName\":\"source\"}'"
echo ""

# 清理cookie文件
rm -f "$COOKIE_FILE" 2>/dev/null
