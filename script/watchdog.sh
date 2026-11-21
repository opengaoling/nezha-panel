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
LOCK_FILE="/run/nezha-watchdog-exec.lock"
[ ! -d "/run" ] && LOCK_FILE="/tmp/nezha-watchdog-exec.lock"

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

# 统一日志输出（直接写入日志文件；终端交互时输出到屏幕，cron 批处理时单向写入防止日志重复）
log() {
    rotate_log_if_needed
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" >> "$LOG_FILE" 2>/dev/null || true
    if [ -t 1 ]; then
        echo "[$ts] $*"
    fi
}

# 检查 SSL 证书健康度并提供自动转正与续期双保险
check_and_guard_cert() {
    local ssl_dir="${BASE_DIR}/ssl"
    [ ! -d "$ssl_dir" ] && return 0

    local cert_file
    cert_file=$(find "$ssl_dir" -maxdepth 1 -name "*.crt" 2>/dev/null | head -n1)
    [ -z "$cert_file" ] && return 0

    local domain
    domain="$(basename "$cert_file" .crt)"

    log "🔒 [SSL 守护] 检查 SSL 证书状态与有效期 (域名: ${domain})..."
    local expiry
    expiry=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
    local issuer subject
    issuer=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
    subject=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/^subject=//')
    log "   证书主体: ${subject}"
    log "   签发主体: ${issuer}"
    log "   到期时间: ${expiry:-未知}"

    # 1. 检查是否为临时自签名证书 (自签名证书 issuer 与 subject 一致，或 issuer 包含 CN = domain)
    local is_self_signed=false
    if [ "$issuer" = "$subject" ] || echo "$issuer" | grep -qi "CN *= *${domain}"; then
        is_self_signed=true
    fi

    if [ "$is_self_signed" = "true" ]; then
        # 1.1 若自签证书剩余有效期不足 30 天（如历史 1 天临时自签证书），先自动平滑升级为 10 年期自签保底
        if ! openssl x509 -checkend 2592000 -noout -in "$cert_file" >/dev/null 2>&1; then
            log "🔄 [SSL 守护] 检测到自签证书剩余有效期不足 30 天（旧版 1 天证书），正在自动平滑升级为 10 年期安全保底证书..."
            openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
                -keyout "${BASE_DIR}/ssl/${domain}.key" \
                -out "${BASE_DIR}/ssl/${domain}.crt" \
                -subj "/CN=${domain}" >/dev/null 2>&1 || true
            docker exec nezha-nginx nginx -s reload 2>/dev/null || true
            log "✅ [SSL 守护] 已自动平滑升级为 10 年期 (3650天) 自签保底证书，Nginx 重载完成！"
        fi

        log "⚠️  [SSL 守护] 触发多引擎自动申请 Let's Encrypt / ZeroSSL / Buypass 正式证书..."
        if docker ps --format '{{.Names}}' | grep -Eq '^nezha-acme$'; then
            local email=""
            [ -f "${BASE_DIR}/.env" ] && email="$(grep -E '^EMAIL=' "${BASE_DIR}/.env" 2>/dev/null | cut -d= -f2 | tr -d ' "\r\n')"
            [ -z "$email" ] && email="admin@${domain}"
            docker exec nezha-acme /usr/local/bin/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
            docker exec nezha-acme /usr/local/bin/acme.sh --register-account -m "$email" --server letsencrypt >/dev/null 2>&1 || true
            docker exec nezha-acme /usr/local/bin/acme.sh --register-account -m "$email" --server zerossl >/dev/null 2>&1 || true
            docker exec nezha-acme /usr/local/bin/acme.sh --upgrade --auto-upgrade 0 >/dev/null 2>&1 || true

            # 清除可能残留的半成品无效配置目录（彻底打破 Skipping invalid cert 死锁）
            docker exec nezha-acme rm -rf "/acme.sh/${domain}_ecc" "/acme.sh/${domain}" >/dev/null 2>&1 || true

            local issued=false
            if docker exec nezha-acme /usr/local/bin/acme.sh --issue \
                -d "${domain}" \
                -w /var/www/html \
                --server letsencrypt >> "$LOG_FILE" 2>&1; then
                issued=true
            else
                docker exec nezha-acme rm -rf "/acme.sh/${domain}_ecc" "/acme.sh/${domain}" >/dev/null 2>&1 || true
                if docker exec nezha-acme /usr/local/bin/acme.sh --issue \
                    -d "${domain}" \
                    -w /var/www/html \
                    --server zerossl >> "$LOG_FILE" 2>&1; then
                    issued=true
                else
                    docker exec nezha-acme rm -rf "/acme.sh/${domain}_ecc" "/acme.sh/${domain}" >/dev/null 2>&1 || true
                    if docker exec nezha-acme /usr/local/bin/acme.sh --issue \
                        -d "${domain}" \
                        -w /var/www/html \
                        --server buypass >> "$LOG_FILE" 2>&1; then
                        issued=true
                    fi
                fi
            fi

            if [ "$issued" = "true" ]; then
                docker exec nezha-acme apk add --no-cache docker-cli >/dev/null 2>&1 || true
                docker exec nezha-acme /usr/local/bin/acme.sh --install-cert \
                    -d "${domain}" \
                    --ecc \
                    --key-file "/ssl/${domain}.key" \
                    --fullchain-file "/ssl/${domain}.crt" \
                    --reloadcmd "docker exec nezha-nginx nginx -t && docker exec nezha-nginx nginx -s reload" >> "$LOG_FILE" 2>&1 || {
                    docker exec nezha-acme /usr/local/bin/acme.sh --install-cert \
                        -d "${domain}" \
                        --key-file "/ssl/${domain}.key" \
                        --fullchain-file "/ssl/${domain}.crt" \
                        --reloadcmd "docker exec nezha-nginx nginx -t && docker exec nezha-nginx nginx -s reload" >> "$LOG_FILE" 2>&1 || true
                }
                docker exec nezha-nginx nginx -s reload 2>/dev/null || true
                log "🎉 [SSL 守护] 正式 SSL 证书签发并替换成功！Nginx 已完成平滑重载。"
                return 0
            else
                # 签发未通过：彻底清理半成品残留目录，杜绝 acme.sh 容器每日 cron 报 Skipping invalid cert 死锁
                docker exec nezha-acme rm -rf "/acme.sh/${domain}_ecc" "/acme.sh/${domain}" >/dev/null 2>&1 || true
                log "⏳ [SSL 守护] 正式证书签发暂未就绪（DNS 可能尚未在全球完全生效、Cloudflare 开启了代理小黄云或 80 端口受阻），将在下个周期自动重试。"
                return 1
            fi
        fi
    fi

    # 2. 检查证书是否在 20 天内到期 (acme.sh 默认 30 天起续期，若距到期小于 20 天说明日常自动续期可能未生效，主动触发补偿)
    if ! openssl x509 -checkend 1728000 -noout -in "$cert_file" >/dev/null 2>&1; then
        log "⚠️  证书将在 20 天内到期，主动触发 acme.sh 续期检查..."
        if docker ps --format '{{.Names}}' | grep -Eq '^nezha-acme$'; then
            if [ -t 1 ]; then
                docker exec nezha-acme /usr/local/bin/acme.sh --cron --home /acme.sh 2>&1 | tee -a "$LOG_FILE" || true
            else
                docker exec nezha-acme /usr/local/bin/acme.sh --cron --home /acme.sh >> "$LOG_FILE" 2>&1 || true
            fi
        else
            log "⚠️  未检测到 nezha-acme 容器运行，尝试拉起..."
            if [ -t 1 ]; then
                $CMD up -d acme 2>&1 | tee -a "$LOG_FILE" || true
            else
                $CMD up -d acme >> "$LOG_FILE" 2>&1 || true
            fi
        fi
    else
        log "✅ 正式 CA 证书状态正常（距到期超过 20 天）。"
    fi

    # 3. 紧急阈值告警 (小于 7 天)
    if ! openssl x509 -checkend 604800 -noout -in "$cert_file" >/dev/null 2>&1; then
        log "🚨 [紧急告警] 证书距到期不足 7 天！请排查 acme.sh 续签日志！"
    fi
}

# 自动检测并全量更新脚本套件（deploy.sh / nezha.sh / watchdog.sh）
auto_update_scripts() {
    log "🔍 [看门狗] 检查管理与看门狗脚本套件最新版本..."
    local tmp_script
    tmp_script=$(mktemp /tmp/nezha-deploy-XXXXXX.sh)
    local urls=(
        "https://raw.githubusercontent.com/opengaoling/nezha-panel/master/deploy.sh"
        "https://fastly.jsdelivr.net/gh/opengaoling/nezha-panel@master/deploy.sh"
        "https://ghfast.top/https://raw.githubusercontent.com/opengaoling/nezha-panel/master/deploy.sh"
    )
    local success=false
    for u in "${urls[@]}"; do
        if curl -fsSL --connect-timeout 8 --max-time 30 "$u" -o "$tmp_script" 2>/dev/null; then
            if [ -s "$tmp_script" ] && bash -n "$tmp_script" >/dev/null 2>&1; then
                success=true
                break
            fi
        fi
    done
    if [ "$success" = "true" ]; then
        local remote_ver
        remote_ver=$(grep -E '^SCRIPT_VERSION=' "$tmp_script" | head -n1 | cut -d= -f2 | tr -d ' "\r\n')
        local local_ver=""
        if [ -f "$BASE_DIR/nezha.sh" ]; then
            local_ver=$(grep -E '^VERSION=' "$BASE_DIR/nezha.sh" | head -n1 | cut -d= -f2 | tr -d ' "\r\n')
        fi
        if [ -n "$remote_ver" ] && [ "$remote_ver" != "$local_ver" ]; then
            if [ -z "$local_ver" ] || [ "$(printf '%s\n%s' "$remote_ver" "$local_ver" | sort -V 2>/dev/null | head -n1)" = "$local_ver" ]; then
                log "⬆️  检测到新版本脚本套件 ($local_ver -> $remote_ver)，自动全量更新与同步..."
                bash "$tmp_script" sync-tools --dir "$BASE_DIR" >/dev/null 2>&1 || true
                if [ -f "$CRON_FILE" ]; then
                    enable_cron "$DEFAULT_SCHEDULE" >/dev/null 2>&1 || true
                fi
                log "✅ 管理、部署与看门狗脚本套件已成功自动更新至: $remote_ver"
            else
                log "ℹ️  本地脚本套件版本 ($local_ver) 高于或等于远端版本 ($remote_ver)，无需更新。"
            fi
        else
            log "✅ 脚本套件状态正常，当前已是最新版 (${local_ver:-$remote_ver})。"
        fi
    else
        log "⚠️  检查脚本套件更新网络超时，保持当前脚本版本运行。"
    fi
    rm -f "$tmp_script" 2>/dev/null || true
}

# 核心检查与更新逻辑
run_check() {
    # 0. 防止任务重叠的并发文件锁保护 (flock)
    if command -v flock >/dev/null 2>&1; then
        exec 200>"$LOCK_FILE"
        if ! flock -n 200; then
            log "⚠️  检测到已有看门狗任务正在执行中，跳过本次触发。"
            return 0
        fi
    fi

    log "===================================================================="
    check_and_guard_cert
    auto_update_scripts
    log "🔍 [看门狗] 开始检查哪吒监控面板镜像更新..."

    # 1. 获取当前容器对应的镜像 ID (SHA256) 与准确运行状态
    local current_id=""
    local is_running="false"
    if docker ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}\$"; then
        current_id=$(docker inspect --format='{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)
        is_running=$(docker inspect --format='{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo "false")
    fi

    if [ "$is_running" = "true" ]; then
        log "📌 当前容器正在运行中，镜像 ID: ${current_id}"
    elif [ -n "$current_id" ]; then
        log "⚠️  当前容器存在但处于停止状态 (Running: false)，镜像 ID: ${current_id}，稍后将自动重建启动。"
    else
        log "⚠️  未检测到运行中的 ${CONTAINER_NAME} 容器实例。"
    fi

    # 2. 拉取远端最新镜像
    log "⬇️ 正在拉取远端最新镜像: ${IMAGE_NAME} ..."
    if [ -t 1 ]; then
        if ! docker pull "$IMAGE_NAME" 2>&1 | tee -a "$LOG_FILE"; then
            log "❌ 镜像拉取失败，请检查主机网络与 GitHub Container Registry 连接。"
            return 1
        fi
    else
        if ! docker pull "$IMAGE_NAME" >> "$LOG_FILE" 2>&1; then
            log "❌ 镜像拉取失败，请检查主机网络与 GitHub Container Registry 连接。"
            return 1
        fi
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
    if [ -n "$current_id" ] && [ "$current_id" = "$latest_id" ] && [ "$is_running" = "true" ]; then
        log "✅ 镜像未发生变化 (SHA256: ${latest_id:0:19}...)，当前运行已是最新版，无需重建。"
        log "===================================================================="
        return 0
    fi

    # 5. SHA256 发生变化或容器停止/不存在，执行平滑重建
    log "⚡ 检测到镜像更新或容器需要重建启动!"
    log "   旧镜像: ${current_id:-<无运行实例>}"
    log "   新镜像: ${latest_id}"
    log "🔄 正在平滑重建 ${CONTAINER_NAME} 容器 (保持 nginx/acme 独立运行不受影响)..."

    local recreate_ok=false
    if [ -t 1 ]; then
        if $CMD up -d --force-recreate --no-deps "$CONTAINER_NAME" 2>&1 | tee -a "$LOG_FILE"; then
            recreate_ok=true
        fi
    else
        if $CMD up -d --force-recreate --no-deps "$CONTAINER_NAME" >> "$LOG_FILE" 2>&1; then
            recreate_ok=true
        fi
    fi

    if [ "$recreate_ok" = "true" ]; then
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
        (crontab -l 2>/dev/null | grep -v "${script_path}"; echo "${schedule} ${script_path} run >/dev/null 2>&1") | crontab -
    else
        cat > "$CRON_FILE" << EOF
# Nezha Dashboard Watchdog (Auto-Update GHCR Image)
# 每日定时拉取 GHCR 镜像并比对 SHA256 重建容器 (内部自带 flock 并发锁保护)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

${schedule} root ${script_path} run >/dev/null 2>&1
EOF
        chmod 0644 "$CRON_FILE"
    fi

    # 确保 cron / crond 服务开机自启并立即处于运行状态
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || true
        systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true
    elif command -v service >/dev/null 2>&1; then
        service cron start 2>/dev/null || service crond start 2>/dev/null || true
        service cron restart 2>/dev/null || service crond restart 2>/dev/null || true
    fi

    echo "✅ 看门狗每日自动更新已成功启用！"
    echo "   执行频率: 每天 04:30 (${schedule})"
    echo "   并发保护: 内部 flock 文件锁 (${LOCK_FILE})"
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

# 手动触发全量更新部署、管理与看门狗脚本套件
update_all_scripts() {
    echo "正在从 GitHub 获取最新的部署与管理套件以更新所有脚本..."
    auto_update_scripts
    echo "✅ 部署、管理与看门狗脚本套件更新完毕！"
}

# 查看看门狗状态
status_cron() {
    echo "===================================================================="
    echo "                   🐶 哪吒监控面板看门狗运行状态                   "
    echo "===================================================================="
    if [ -f "$CRON_FILE" ]; then
        echo "定时任务配置: [已启用] ${CRON_FILE}"
        echo "计划规则内容:"
        grep -v '^#' "$CRON_FILE" | grep -v '^$' | sed 's/^/  /'
    elif crontab -l 2>/dev/null | grep -q "watchdog.sh"; then
        echo "定时任务配置: [已启用] crontab"
        crontab -l | grep "watchdog.sh" | sed 's/^/  /'
    else
        echo "定时任务配置: [未启用] (可通过 'nezha watchdog enable' 启用)"
    fi

    local cron_svc_status="未知"
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active cron >/dev/null 2>&1; then
            cron_svc_status="运行中 (cron.service active)"
        elif systemctl is-active crond >/dev/null 2>&1; then
            cron_svc_status="运行中 (crond.service active)"
        else
            cron_svc_status="⚠️ 未运行 (cron/crond inactive! 定时任务无法触发，请执行: systemctl enable --now cron)"
        fi
    elif command -v service >/dev/null 2>&1; then
        if service cron status >/dev/null 2>&1 || service crond status >/dev/null 2>&1; then
            cron_svc_status="运行中"
        else
            cron_svc_status="⚠️ 未运行"
        fi
    fi
    echo "系统守护服务: ${cron_svc_status}"

    echo ""
    local cur_id
    cur_id=$(docker inspect --format='{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo "未运行")
    local img_id
    img_id=$(docker inspect --format='{{.Id}}' "$IMAGE_NAME" 2>/dev/null || echo "未拉取")
    local is_run
    is_run=$(docker inspect --format='{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo "false")
    echo "容器运行状态: [${is_run}] (Running: ${is_run})"
    echo "当前运行镜像: ${cur_id}"
    echo "本地最新镜像: ${img_id}"

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
    update|upgrade)
        update_all_scripts
        ;;
    cert-guard|guard-cert)
        check_and_guard_cert
        ;;
    status)
        status_cron
        ;;
    logs)
        view_logs
        ;;
    *)
        echo "用法: $0 {run|enable|disable|status|logs|update|cert-guard}"
        echo "  run        - 立即执行一次镜像拉取与 SHA256 比对检查，若变化则重建容器"
        echo "  enable     - 启用每日定时执行 (默认 04:30 自动执行，带 flock 并发锁)"
        echo "  disable    - 停用每日定时执行"
        echo "  update     - 从 GitHub 更新部署、管理与看门狗全套脚本至最新版"
        echo "  cert-guard - 立即执行 SSL 证书健康检查与自签名证书自动转正"
        echo "  status     - 查看当前看门狗定时任务配置与最近更新日志"
        echo "  logs       - 跟踪查看详细运行日志"
        exit 1
        ;;
esac
