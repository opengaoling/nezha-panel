#!/usr/bin/env bash
# ==============================================================================
# Nezha Dashboard Watchdog (GHCR Image Auto-Updater)
# 每日定时拉取 GHCR 镜像，对比 SHA256 镜像 ID，若发生变化则平滑重建容器
# ==============================================================================
set -e

export PATH="/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:$PATH"

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
BASE_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
[ ! -f "$BASE_DIR/docker-compose.yaml" ] && [ -d "/opt/nezha-dashboard" ] && BASE_DIR="/opt/nezha-dashboard"
cd "$BASE_DIR"

if docker compose version >/dev/null 2>&1; then
    CMD="docker compose"
else
    CMD="docker-compose"
fi

IMAGE_NAME="ghcr.io/opengaoling/nezha-panel:latest"
CONTAINER_NAME="nezha-dashboard"
LOG_FILE="/var/log/nezha-watchdog.log"
CRON_FILE="/etc/cron.d/nezha-watchdog"
DEFAULT_SCHEDULE="30 4 * * *"

# 确保日志文件不超过 5MB，超出截断保留最新 1000 行
rotate_log_if_needed() {
    if [ -f "$LOG_FILE" ]; then
        local sz
        sz=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$sz" -gt 5242880 ]; then
            tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv -f "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    fi
}

log() {
    rotate_log_if_needed
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" | tee -a "$LOG_FILE" 2>/dev/null || echo "[$ts] $*"
}

# 核心检查与更新逻辑
run_check() {
    log "===================================================================="
    log "🔍 [看门狗] 开始检查哪吒监控面板镜像更新..."

    # 1. 获取当前运行容器对应的镜像 ID (SHA256)
    local current_id=""
    if docker ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}\$"; then
        current_id=$(docker inspect --format='{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)
    fi

    if [ -n "$current_id" ]; then
        log "📌 当前容器正在运行，镜像 ID: ${current_id}"
    else
        log "⚠️  未检测到运行中的 ${CONTAINER_NAME} 容器。"
    fi

    # 2. 拉取远端最新镜像
    log "⬇️ 正在拉取远端最新镜像: ${IMAGE_NAME} ..."
    if ! docker pull "$IMAGE_NAME" 2>&1 | tee -a "$LOG_FILE"; then
        log "❌ 镜像拉取失败，请检查主机网络与 GitHub Container Registry 连接。"
        return 1
    fi

    # 3. 获取拉取后本地最新镜像 ID (SHA256)
    local latest_id=""
    latest_id=$(docker inspect --format='{{.Id}}' "$IMAGE_NAME" 2>/dev/null || true)

    if [ -z "$latest_id" ]; then
        log "❌ 无法获取最新镜像 ID: ${IMAGE_NAME}"
        return 1
    fi

    log "🌐 远端最新镜像 ID: ${latest_id}"

    # 4. 对比 SHA256 镜像哈希
    if [ -n "$current_id" ] && [ "$current_id" = "$latest_id" ]; then
        log "✅ 镜像未发生变化 (SHA256: ${latest_id:0:19}...)，当前运行已是最新版，无需重建。"
        log "===================================================================="
        return 0
    fi

    # 5. SHA256 发生变化或容器尚未运行，执行平滑重建
    log "⚡ 检测到镜像 SHA256 变动!"
    log "   旧镜像: ${current_id:-<无运行实例>}"
    log "   新镜像: ${latest_id}"
    log "🔄 正在平滑重建 ${CONTAINER_NAME} 容器 (保持 nginx/acme 独立运行不受影响)..."

    if $CMD up -d --force-recreate --no-deps "$CONTAINER_NAME" 2>&1 | tee -a "$LOG_FILE"; then
        log "✅ ${CONTAINER_NAME} 容器已平滑重建完成并运行最新镜像！"

        # 6. 清理旧悬空镜像释放磁盘
        log "🧹 清理旧悬空镜像缓存..."
        docker image prune -f 2>&1 | tee -a "$LOG_FILE" || true

        log "🎉 哪吒监控面板看门狗自动更新流程全部完成！"
    else
        log "❌ 重建容器失败，请检查 Docker Compose 配置与环境状态！"
        log "===================================================================="
        return 1
    fi
    log "===================================================================="
}

# 启用每日定时看门狗计划任务 (/etc/cron.d/nezha-watchdog)
enable_cron() {
    local schedule="${1:-$DEFAULT_SCHEDULE}"
    local script_path="${BASE_DIR}/watchdog.sh"

    echo "正在配置看门狗定时更新任务 (计划: ${schedule})..."

    if [ ! -d "/etc/cron.d" ]; then
        echo "⚠️  未找到 /etc/cron.d 目录，尝试使用 crontab 配置..."
        (crontab -l 2>/dev/null | grep -v "${script_path}"; echo "${schedule} ${script_path} run >> ${LOG_FILE} 2>&1") | crontab -
    else
        cat > "$CRON_FILE" << EOF
# Nezha Dashboard Watchdog (Auto-Update GHCR Image)
# 每日定时拉取 GHCR 镜像并比对 SHA256 重建容器
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

${schedule} root ${script_path} run >> ${LOG_FILE} 2>&1
EOF
        chmod 0644 "$CRON_FILE"
    fi

    # 确保 cron 服务正常运行
    if systemctl is-active cron >/dev/null 2>&1; then
        systemctl restart cron 2>/dev/null || true
    elif systemctl is-active crond >/dev/null 2>&1; then
        systemctl restart crond 2>/dev/null || true
    fi

    echo "✅ 看门狗每日自动更新已成功启用！"
    echo "   执行频率: 每天 04:30 (${schedule})"
    echo "   任务配置: ${CRON_FILE}"
    echo "   运行日志: ${LOG_FILE}"
}

# 停用每日定时看门狗
disable_cron() {
    echo "正在停用看门狗每日自动更新..."
    rm -f "$CRON_FILE" 2>/dev/null || true
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -v "watchdog.sh" | crontab - 2>/dev/null || true
    fi
    echo "✅ 看门狗定时任务已停用。"
}

# 查看看门狗状态
status_cron() {
    echo "===================================================================="
    echo "                   🐶 哪吒监控面板看门狗运行状态                   "
    echo "===================================================================="
    local cron_enabled=false
    if [ -f "$CRON_FILE" ]; then
        cron_enabled=true
        echo "定时任务配置: [已启用] ${CRON_FILE}"
        echo "计划规则内容:"
        grep -v '^#' "$CRON_FILE" | grep -v '^$' | sed 's/^/  /'
    elif crontab -l 2>/dev/null | grep -q "watchdog.sh"; then
        cron_enabled=true
        echo "定时任务配置: [已启用] crontab"
        crontab -l | grep "watchdog.sh" | sed 's/^/  /'
    else
        echo "定时任务配置: [未启用] (可通过 'nezha watchdog enable' 启用)"
    fi

    echo ""
    local cur_id
    cur_id=$(docker inspect --format='{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo "未运行")
    local img_id
    img_id=$(docker inspect --format='{{.Id}}' "$IMAGE_NAME" 2>/dev/null || echo "未拉取")
    echo "当前运行容器镜像: ${cur_id}"
    echo "本地最新镜像 ID : ${img_id}"

    echo ""
    echo "=== 最近看门狗执行日志 (最近 15 行) ==="
    if [ -f "$LOG_FILE" ]; then
        tail -n 15 "$LOG_FILE"
    else
        echo "暂无执行日志 (${LOG_FILE})"
    fi
    echo "===================================================================="
}

view_logs() {
    if [ -f "$LOG_FILE" ]; then
        echo "正在实时查看看门狗运行日志 (Ctrl+C 退出)..."
        tail -n 30 -f "$LOG_FILE"
    else
        echo "暂无看门狗日志文件: $LOG_FILE"
    fi
}

case "${1:-run}" in
    run|check)
        run_check
        ;;
    enable|install)
        enable_cron "${2:-$DEFAULT_SCHEDULE}"
        ;;
    disable|uninstall)
        disable_cron
        ;;
    status)
        status_cron
        ;;
    logs)
        view_logs
        ;;
    *)
        echo "用法: $0 {run|enable|disable|status|logs}"
        echo "  run     - 立即执行一次镜像拉取与 SHA256 比对检查，若变化则重建容器"
        echo "  enable  - 启用每日定时执行 (默认 04:30 自动执行)"
        echo "  disable - 停用每日定时执行"
        echo "  status  - 查看当前看门狗定时任务配置与最近更新日志"
        echo "  logs    - 跟踪查看详细运行日志"
        exit 1
        ;;
esac
