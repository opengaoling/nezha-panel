#!/usr/bin/env bash
#=============================================================================
# 🚀 哪吒监控定制安全增强版 · 一键部署与管理脚本 (纯 Docker 化 Nginx + acme.sh 架构)
# 项目地址: https://github.com/opengaoling/nezha-panel
# 项目支持系统: Ubuntu / Debian / CentOS / AlmaLinux / Rocky / Fedora / Alpine
# 全容器化部署: Nezha Dashboard + Nginx (alpine) + acme.sh (自动申请与自动续期)
# 彻底移除 Caddy，根除双 Go runtime 竞争导致的内存膨胀与 502 故障
#=============================================================================

# ANSI 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 全局默认参数与版本号
SCRIPT_VERSION="v2.8.0"
DEFAULT_INSTALL_DIR="/opt/nezha-dashboard"
DEFAULT_PORT="2052"
DOCKER_IMAGE="ghcr.io/opengaoling/nezha-panel:latest"
NGINX_IMAGE="nginx:alpine"
ACME_IMAGE="neilpang/acme.sh:latest"

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[ OK ]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERR ]${NC} $1"; }

print_banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}"
    echo "============================================================================"
    echo "       🚀 哪吒监控定制安全增强版 · 一键部署脚本 (${SCRIPT_VERSION})       "
    echo "         基于 Nezha Monitoring · 全前置 WAF 防探测 · 8位安全路径隐匿         "
    echo "      全容器化架构: Docker Nginx + acme.sh 自动申请与自动续期 SSL 证书      "
    echo "============================================================================"
    echo -e "${NC}"
}

check_root() {
    if [ "$(id -u)" != "0" ]; then
        log_err "请使用 root 权限或 sudo 运行此部署脚本。"
        exit 1
    fi
}

# 生成随机 8 位大小写英文字母
generate_random_secret() {
    tr -dc 'a-zA-Z' < /dev/urandom 2>/dev/null | head -c 8 || python3 -c "import random, string; print(''.join(random.choices(string.ascii_letters, k=8)))" 2>/dev/null || echo "mKovrigH"
}

# 检查并安装基础依赖
install_dependencies() {
    log_info "正在检查基础运行依赖 (curl, tar, openssl, awk, sed)..."
    local need_install=""
    for cmd in curl tar openssl awk sed; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            need_install="$need_install $cmd"
        fi
    done

    if [ -n "$need_install" ]; then
        log_info "正在安装缺失的工具:$need_install"
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq $need_install
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y -q $need_install
        elif command -v yum >/dev/null 2>&1; then
            yum install -y -q $need_install
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache $need_install
        fi
    fi
}

# 检查并安装 Docker 与 Docker Compose
check_install_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log_warn "未检测到 Docker 环境，正在使用官方脚本自动安装 Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker 2>/dev/null || service docker start 2>/dev/null || true
    fi

    local has_compose=false
    if docker compose version >/dev/null 2>&1; then
        has_compose=true
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        has_compose=true
        COMPOSE_CMD="docker-compose"
    fi

    if [ "$has_compose" != "true" ]; then
        log_info "正在配置 Docker Compose 插件..."
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq docker-compose-v2 || apt-get install -y -qq docker-compose-plugin || true
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y -q docker-compose-plugin || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y -q docker-compose-plugin || true
        fi

        if docker compose version >/dev/null 2>&1; then
            COMPOSE_CMD="docker compose"
        elif command -v docker-compose >/dev/null 2>&1; then
            COMPOSE_CMD="docker-compose"
        else
            log_info "正在直接下载官方 Docker Compose 可执行插件..."
            local arch="$(uname -m)"
            case "$arch" in
                x86_64)  arch="x86_64" ;;
                aarch64|arm64) arch="aarch64" ;;
                *) arch="x86_64" ;;
            esac
            mkdir -p /usr/local/lib/docker/cli-plugins /usr/libexec/docker/cli-plugins
            curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}" -o /usr/local/lib/docker/cli-plugins/docker-compose
            chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
            cp /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose 2>/dev/null || true
            COMPOSE_CMD="docker compose"
        fi
    fi

    log_ok "Docker 与 Docker Compose 环境已就绪 ($(docker --version 2>/dev/null | head -n1))"
}

# 交互式收集配置
gather_user_input() {
    echo -e "${YELLOW}------------------------------------------------------------${NC}"
    echo -e "${BOLD}请配置部署参数（直接回车可使用默认建议值）：${NC}"
    echo -e "${YELLOW}------------------------------------------------------------${NC}"

    # 1. 域名配置
    while true; do
        if [ -n "$DOMAIN" ]; then
            INPUT_DOMAIN="$DOMAIN"
        else
            read -r -p "👉 请输入要绑定的域名 (例如: monitor.yourdomain.com): " INPUT_DOMAIN
        fi
        INPUT_DOMAIN="$(echo "$INPUT_DOMAIN" | tr -d ' ')"
        if [[ "$INPUT_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
            break
        else
            log_err "域名格式不正确，请输入合法域名（如 monitor.example.com）："
            DOMAIN=""
        fi
    done

    # 2. 邮箱配置 (可选，用于证书通知)
    if [ -z "$EMAIL" ]; then
        if [ "$NON_INTERACTIVE" = "true" ] || [ "$NON_INTERACTIVE" = "1" ]; then
            INPUT_EMAIL=""
        else
            read -r -p "👉 请输入联系邮箱 (用于 acme.sh 证书通知，建议填写，回车跳过): " INPUT_EMAIL
            INPUT_EMAIL="$(echo "$INPUT_EMAIL" | tr -d ' ')"
        fi
    else
        INPUT_EMAIL="$EMAIL"
    fi

    # 3. 面板监听通信端口
    if [ -z "$PORT" ]; then
        if [ "$NON_INTERACTIVE" = "true" ] || [ "$NON_INTERACTIVE" = "1" ]; then
            INPUT_PORT="$DEFAULT_PORT"
        else
            read -r -p "👉 请输入面板监听通信端口 (默认: $DEFAULT_PORT, 回车确认): " INPUT_PORT
            INPUT_PORT="$(echo "$INPUT_PORT" | tr -d ' ')"
            [ -z "$INPUT_PORT" ] && INPUT_PORT="$DEFAULT_PORT"
        fi
    else
        INPUT_PORT="$PORT"
    fi

    # 4. 防探测 8 位安全路径
    local auto_secret="$(generate_random_secret)"
    if [ -z "$SECRET_PATH" ]; then
        if [ "$NON_INTERACTIVE" = "true" ] || [ "$NON_INTERACTIVE" = "1" ]; then
            INPUT_SECRET="$auto_secret"
        else
            read -r -p "👉 请输入 8 位防探测英文安全路径 (默认随机: ${auto_secret}, 回车确认): " INPUT_SECRET
            INPUT_SECRET="$(echo "$INPUT_SECRET" | tr -d ' ')"
            [ -z "$INPUT_SECRET" ] && INPUT_SECRET="$auto_secret"
        fi
    else
        INPUT_SECRET="$SECRET_PATH"
    fi

    # 校验 8 位英文字母
    while ! [[ "$INPUT_SECRET" =~ ^[a-zA-Z]{8}$ ]]; do
        log_err "安全路径必须严格为 8 位大小写英文字母！"
        if [ "$NON_INTERACTIVE" = "true" ] || [ "$NON_INTERACTIVE" = "1" ]; then
            INPUT_SECRET="$auto_secret"
            break
        fi
        read -r -p "请重新输入 8 位英文字母路径 (或直接回车使用 ${auto_secret}): " INPUT_SECRET
        INPUT_SECRET="$(echo "$INPUT_SECRET" | tr -d ' ')"
        [ -z "$INPUT_SECRET" ] && INPUT_SECRET="$auto_secret"
    done

    # 5. 安装目录
    if [ -z "$INSTALL_DIR" ]; then
        if [ "$NON_INTERACTIVE" = "true" ] || [ "$NON_INTERACTIVE" = "1" ]; then
            INPUT_DIR="$DEFAULT_INSTALL_DIR"
        else
            read -r -p "👉 请输入安装目录路径 (默认: $DEFAULT_INSTALL_DIR, 回车确认): " INPUT_DIR
            INPUT_DIR="$(echo "$INPUT_DIR" | tr -d ' ')"
            [ -z "$INPUT_DIR" ] && INPUT_DIR="$DEFAULT_INSTALL_DIR"
        fi
    else
        INPUT_DIR="$INSTALL_DIR"
    fi

    # 6. Agent 通信密钥 (方便旧探针直接上线)
    local existing_agent_key=""
    if [ -f "$INPUT_DIR/data/config.yaml" ]; then
        existing_agent_key="$(grep -E '^agent_secret_key:' "$INPUT_DIR/data/config.yaml" | awk '{print $2}' | tr -d ' "\r\n')"
    fi

    if [ -z "$AGENT_KEY" ]; then
        if [ "$NON_INTERACTIVE" = "true" ] || [ "$NON_INTERACTIVE" = "1" ]; then
            INPUT_AGENT_KEY="$existing_agent_key"
        else
            if [ -n "$existing_agent_key" ]; then
                read -r -p "👉 检测到已有 Agent 通信密钥 (${existing_agent_key})，回车沿用或输入新密钥: " INPUT_AGENT_KEY
                INPUT_AGENT_KEY="$(echo "$INPUT_AGENT_KEY" | tr -d ' ')"
                [ -z "$INPUT_AGENT_KEY" ] && INPUT_AGENT_KEY="$existing_agent_key"
            else
                read -r -p "👉 是否指定旧的 Agent 通信密钥 (方便旧探针无缝上线，回车自动随机生成): " INPUT_AGENT_KEY
                INPUT_AGENT_KEY="$(echo "$INPUT_AGENT_KEY" | tr -d ' ')"
            fi
        fi
    else
        INPUT_AGENT_KEY="$AGENT_KEY"
    fi

    echo ""
    log_info "配置确认清单:"
    echo "  - 绑定域名:     ${GREEN}${INPUT_DOMAIN}${NC}"
    echo "  - 证书通知邮箱: ${GREEN}${INPUT_EMAIL:-未设置 (acme.sh 自动注册)}${NC}"
    echo "  - 内部通信端口: ${GREEN}${INPUT_PORT}${NC}"
    echo "  - 8位安全路径:  ${GREEN}${INPUT_SECRET}${NC}"
    echo "  - Agent通信密钥: ${GREEN}${INPUT_AGENT_KEY:-系统自动生成随机密钥}${NC}"
    echo "  - 安装目录:     ${GREEN}${INPUT_DIR}${NC}"
    echo "  - 架构方案:     ${GREEN}纯 Docker 化 Nginx + acme.sh (零宿主机软件依赖，轻量安全)${NC}"
    echo ""
    if [ "$NON_INTERACTIVE" != "true" ] && [ "$NON_INTERACTIVE" != "1" ]; then
        read -r -p "确认以上配置并开始部署? [Y/n]: " confirm
        if [[ "$confirm" =~ ^[nN]$ ]]; then
            log_warn "用户取消操作，退出脚本。"
            exit 0
        fi
    fi
}

# 清理历史 Caddy 容器并检查端口
check_ports() {
    log_info "正在清理历史 Caddy 容器并检查端口占用情况 (80, 443, ${INPUT_PORT})..."

    # 清理所有历史 Caddy 容器
    for old_caddy in nezha-caddy caddy-gateway caddy-ssl-test; do
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$old_caddy"; then
            log_info "清理历史 Caddy 容器: $old_caddy ..."
            docker rm -f "$old_caddy" >/dev/null 2>&1 || true
        fi
    done
    docker rmi caddy:2.8.4-alpine 2>/dev/null || true

    # 停止宿主机原生 nginx 服务（如果被 apt 启动占用了 80/443 端口）
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
        log_info "停止宿主机原生 Nginx 以便让 Docker 版 Nginx 绑定 80/443 端口..."
        systemctl stop nginx 2>/dev/null || true
        systemctl disable nginx 2>/dev/null || true
    fi

    # 检查原生 nezha-dashboard.service
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nezha-dashboard.service 2>/dev/null; then
        systemctl stop nezha-dashboard.service 2>/dev/null || true
        systemctl disable nezha-dashboard.service 2>/dev/null || true
    fi

    local conflict=false
    for p in 80 443; do
        if ss -tuln 2>/dev/null | grep -q ":$p " || netstat -tuln 2>/dev/null | grep -q ":$p "; then
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "nezha-nginx"; then
                log_ok "端口 $p 已由 Docker nezha-nginx 监听 (部署将平滑更新)。"
            else
                log_warn "端口 $p 已被其他程序占用，请确认是否继续。"
                conflict=true
            fi
        fi
    done

    local p="$INPUT_PORT"
    if ss -tuln 2>/dev/null | grep -q ":$p " || netstat -tuln 2>/dev/null | grep -q ":$p "; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "nezha-dashboard"; then
            log_ok "通信端口 $p 正在由本服务 nezha-dashboard 使用。"
        else
            log_warn "通信端口 $p 已被其他程序占用。"
        fi
    fi

    if [ "$conflict" = "true" ]; then
        read -r -p "是否尝试强行继续部署? [y/N]: " force_continue
        if ! [[ "$force_continue" =~ ^[yY]$ ]]; then
            exit 1
        fi
    fi
}

# 自动放行防火墙端口 (80, 443, $INPUT_PORT)
open_firewall_ports() {
    log_info "正在配置系统防火墙放行端口 (80, 443, ${INPUT_PORT})..."
    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT 1 -p tcp --dport "$INPUT_PORT" -j ACCEPT 2>/dev/null || true
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1 || true
        fi
    fi
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 80/tcp >/dev/null 2>&1 || true
        ufw allow 443/tcp >/dev/null 2>&1 || true
        ufw allow "${INPUT_PORT}/tcp" >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=443/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${INPUT_PORT}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

# 生成 Nginx 配置文件
generate_nginx_conf() {
    local target_dir="$1"
    local domain="$2"
    local secret="$3"
    local port="$4"
    local secret_lower
    secret_lower="$(echo "$secret" | tr '[:upper:]' '[:lower:]')"

    cat > "${target_dir}/nginx.conf" <<EOF
# =============================================================================
# 哪吒监控定制安全增强版 · Docker Nginx HTTPS 反向代理配置
# SSL 证书由 Docker acme.sh 自动申请与自动续期
# =============================================================================

# HTTP 重定向与 acme.sh 验证路径
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    underscores_in_headers on;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS 主站
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain};

    # 允许包含下划线的 Header（解决 Agent 携带 client_secret、client_uuid 等下划线头部被 Nginx 丢弃导致无法认证上线的问题）
    underscores_in_headers on;

    ssl_certificate     /etc/nginx/ssl/${domain}.crt;
    ssl_certificate_key /etc/nginx/ssl/${domain}.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Cache-Control "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0" always;
    add_header Pragma "no-cache" always;

    proxy_connect_timeout       10s;
    proxy_send_timeout          120s;
    proxy_read_timeout          120s;
    proxy_buffering             off;
    proxy_buffer_size           8k;
    proxy_http_version          1.1;

    # gRPC Agent 监控心跳流
    location /proto.NezhaService/ {
        grpc_pass grpc://nezha-dashboard:${port};
        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_read_timeout 86400s;
        grpc_send_timeout 86400s;
        grpc_buffer_size 32k;
    }

    # 安全路径前缀
    location ~* ^/(${secret}|${secret_lower})(/.*)?$ {
        proxy_pass http://nezha-dashboard:${port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Secret-Path ${secret};
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # 前端静态资源与 API（由 Go 后端内置 WAF anti-probe 校验权限与提供防探测保护）
    location ~ ^/(assets/|dashboard/assets/|api/|terminal|ws/|favicon\.ico|manifest\.json|robots\.txt|apple-touch-icon\.png|android-chrome-.*\.png|logo\.svg|dashboard/logo\.svg|animated-man\.webp|dashboard/animated-man\.webp) {
        proxy_pass http://nezha-dashboard:${port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location / {
        return 404;
    }
}
EOF
}

# 生成 docker-compose.yaml 文件
generate_compose_yaml() {
    local target_dir="$1"
    local port="$2"
    local secret="$3"

    cat > "${target_dir}/docker-compose.yaml" <<EOF
services:
  nezha-dashboard:
    image: ${DOCKER_IMAGE}
    container_name: nezha-dashboard
    restart: always
    ports:
      - "${port}:${port}"
    environment:
      - TZ=Asia/Shanghai
      - NEZHA_SECRET_PATH=${secret}
      - GOMEMLIMIT=512MiB
    volumes:
      - ./data:/dashboard/data
    deploy:
      resources:
        limits:
          memory: 600m
        reservations:
          memory: 128m
    healthcheck:
      test: ["CMD", "/dashboard/app", "-v"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    networks:
      - nezha-net

  nginx:
    image: ${NGINX_IMAGE}
    container_name: nezha-nginx
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./ssl:/etc/nginx/ssl:ro
      - ./acme-challenge:/var/www/html/.well-known/acme-challenge:ro
    deploy:
      resources:
        limits:
          memory: 64m
    depends_on:
      - nezha-dashboard
    networks:
      - nezha-net

  acme:
    image: ${ACME_IMAGE}
    container_name: nezha-acme
    restart: always
    environment:
      - TZ=Asia/Shanghai
    volumes:
      - ./acme-data:/acme.sh
      - ./ssl:/ssl
      - ./acme-challenge:/var/www/html/.well-known/acme-challenge
      - /var/run/docker.sock:/var/run/docker.sock
    entrypoint: /bin/sh -c 'which docker >/dev/null 2>&1 || apk add --no-cache docker-cli >/dev/null 2>&1; trap exit TERM; while :; do /usr/local/bin/acme.sh --cron --home /acme.sh; sleep 86400; done'
    networks:
      - nezha-net

networks:
  nezha-net:
    name: nezha_internal_net
    driver: bridge
EOF
}

# 生成看门狗镜像自动更新脚本 (每天定时拉取 GHCR 镜像并比对 SHA256 平滑重建)
generate_watchdog_script() {
    local target_dir="$1"
    cat > "${target_dir}/watchdog.sh" << 'WATCHDOG_SH_EOF'
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
WATCHDOG_SH_EOF
    chmod +x "${target_dir}/watchdog.sh"
}

# 证书准备与申请
prepare_and_issue_ssl() {
    local target_dir="$1"
    local domain="$2"
    local email="$3"

    mkdir -p "${target_dir}/ssl" "${target_dir}/acme-challenge" "${target_dir}/acme-data"

    local cert_file="${target_dir}/ssl/${domain}.crt"
    local key_file="${target_dir}/ssl/${domain}.key"

    # 1. 尝试从旧 Caddy 数据卷迁移已有证书
    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
        if [ -d "/var/lib/docker/volumes/nezha_caddy_data" ]; then
            log_info "发现历史 Caddy 证书卷，正在平滑迁移至 Nginx SSL 目录..."
            local caddy_crt
            caddy_crt="$(find /var/lib/docker/volumes/nezha_caddy_data -name "${domain}.crt" 2>/dev/null | head -n1)"
            local caddy_key
            caddy_key="$(find /var/lib/docker/volumes/nezha_caddy_data -name "${domain}.key" 2>/dev/null | head -n1)"
            if [ -n "$caddy_crt" ] && [ -n "$caddy_key" ]; then
                cp "$caddy_crt" "$cert_file"
                cp "$caddy_key" "$key_file"
                chmod 600 "$key_file"
                log_ok "成功迁移历史证书！"
            fi
        fi
    fi

    # 2. 如果没有有效证书，则临时启动自签名证书供 Nginx 启动，再通过 acme.sh 签发
    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
        log_info "生成临时启动证书以引导 Nginx 容器..."
        openssl req -x509 -nodes -days 1 -newkey rsa:2048 \
            -keyout "$key_file" \
            -out "$cert_file" \
            -subj "/CN=${domain}" >/dev/null 2>&1 || true
    fi

    # 3. 启动容器集群以开启 HTTP 80 Webroot
    log_info "启动基础容器集群进行 Webroot ACME 验证..."
    local compose_cmd="$(get_compose_cmd)"
    (cd "$target_dir" && ($compose_cmd pull nginx acme nezha-dashboard || true) && $compose_cmd up -d --remove-orphans)

    # 4. 如果没有被 acme.sh 管理，则通过 acme.sh 执行签发并配置 reload 钩子
    if ! docker exec nezha-acme /usr/local/bin/acme.sh --list 2>/dev/null | grep -q "$domain"; then
        log_info "正在通过 acme.sh 自动申请 Let's Encrypt SSL 证书 (域名: ${domain})..."
        [ -n "$email" ] && docker exec nezha-acme /usr/local/bin/acme.sh --register-account -m "$email" >/dev/null 2>&1 || true

        docker exec nezha-acme /usr/local/bin/acme.sh --issue \
            -d "${domain}" \
            -w /var/www/html \
            --server letsencrypt 2>&1 || {
            log_warn "Let's Encrypt 签发遇到问题，尝试使用 ZeroSSL 引擎..."
            docker exec nezha-acme /usr/local/bin/acme.sh --issue \
                -d "${domain}" \
                -w /var/www/html 2>&1 || true
        }

        # 安装证书并绑定自动 reload 钩子
        docker exec nezha-acme apk add --no-cache docker-cli >/dev/null 2>&1 || true
        docker exec nezha-acme /usr/local/bin/acme.sh --install-cert \
            -d "${domain}" \
            --ecc \
            --key-file "/ssl/${domain}.key" \
            --fullchain-file "/ssl/${domain}.crt" \
            --reloadcmd "docker exec nezha-nginx nginx -s reload" 2>&1 || {
            docker exec nezha-acme /usr/local/bin/acme.sh --install-cert \
                -d "${domain}" \
                --key-file "/ssl/${domain}.key" \
                --fullchain-file "/ssl/${domain}.crt" \
                --reloadcmd "docker exec nezha-nginx nginx -s reload" 2>&1 || true
        }
        docker exec nezha-nginx nginx -s reload 2>/dev/null || true
    fi
}

# 写入部署配置文件
write_configs() {
    log_info "正在初始化部署目录: $INPUT_DIR"
    mkdir -p "$INPUT_DIR" "$INPUT_DIR/data" "$INPUT_DIR/data/tsdb" "$INPUT_DIR/ssl" "$INPUT_DIR/acme-challenge" "$INPUT_DIR/acme-data"
    cd "$INPUT_DIR"

    # 生成 Nginx 配置
    generate_nginx_conf "$INPUT_DIR" "$INPUT_DOMAIN" "$INPUT_SECRET" "$INPUT_PORT"

    # 生成 docker-compose.yaml
    generate_compose_yaml "$INPUT_DIR" "$INPUT_PORT" "$INPUT_SECRET"

    # 预置/更新 data/config.yaml (启用 TSDB 时序数据库与 Agent 通信密钥)
    local config_file="$INPUT_DIR/data/config.yaml"
    if [ -f "$config_file" ]; then
        if [ -n "$INPUT_AGENT_KEY" ]; then
            if grep -qE '^agent_secret_key:' "$config_file"; then
                sed -i -E "s/^(agent_secret_key:).*/\1 ${INPUT_AGENT_KEY}/" "$config_file"
            else
                echo "agent_secret_key: ${INPUT_AGENT_KEY}" >> "$config_file"
            fi
            log_ok "已预置 Agent 通信密钥 (agent_secret_key): ${INPUT_AGENT_KEY}"
        fi
        if grep -qE '^tsdb: *\{\}' "$config_file"; then
            sed -i '/^tsdb: *{}/c\tsdb:\n  data_path: data/tsdb\n  retention_days: 30' "$config_file"
            log_ok "已默认开启 TSDB 时序库 (30天自动滚动清理，防 sqlite 膨胀)"
        elif ! grep -qE '^tsdb:' "$config_file"; then
            cat >> "$config_file" <<EOF
tsdb:
  data_path: data/tsdb
  retention_days: 30
EOF
            log_ok "已默认配置开启 TSDB 时序存储"
        fi
    else
        cat > "$config_file" <<EOF
tsdb:
  data_path: data/tsdb
  retention_days: 30
EOF
        if [ -n "$INPUT_AGENT_KEY" ]; then
            echo "agent_secret_key: ${INPUT_AGENT_KEY}" >> "$config_file"
            log_ok "已预置 Agent 通信密钥 (agent_secret_key): ${INPUT_AGENT_KEY}"
        fi
        log_ok "已默认开启 TSDB 时序存储 (data/tsdb, 30天自动清理，防 sqlite 膨胀)"
    fi

    # 写入环境配置备忘 .env
    cat > "$INPUT_DIR/.env" <<EOF
DOMAIN=${INPUT_DOMAIN}
EMAIL=${INPUT_EMAIL}
PORT=${INPUT_PORT}
SECRET_PATH=${INPUT_SECRET}
AGENT_KEY=${INPUT_AGENT_KEY}
INSTALL_DIR=${INPUT_DIR}
EOF

    # 写入全局管理工具 nezha.sh
    cat > "$INPUT_DIR/nezha.sh" << 'NEZHA_SH_EOF'
#!/usr/bin/env bash
# Nezha Dashboard Management Tool (Docker Nginx + acme.sh Edition)
VERSION="v2.8.0"

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

press_any_key() {
    echo ""
    read -r -p "按回车键继续..." dummy
}

clean_docker_cache() {
    echo "正在清理 Docker 悬空镜像及未使用的构建缓存..."
    docker image prune -f
    docker builder prune -f 2>/dev/null || true
    docker rmi caddy:2.8.4-alpine 2>/dev/null || true
    echo "Docker 镜像与构建缓存清理完毕！"
}

clean_container_logs() {
    echo "正在清理 Docker 容器超大运行日志文件..."
    local cleaned=0
    if [ -d "/var/lib/docker/containers" ]; then
        for log_file in $(find /var/lib/docker/containers/ -name "*-json.log" 2>/dev/null); do
            if [ -f "$log_file" ]; then
                truncate -s 0 "$log_file" 2>/dev/null || true
                cleaned=$((cleaned + 1))
            fi
        done
        echo "已成功截断清空 $cleaned 个 Docker 容器日志文件！"
    else
        echo "未发现 /var/lib/docker/containers 目录。"
    fi
}

clean_sqlite_vacuum() {
    local db_path="${BASE_DIR}/data/sqlite.db"
    if [ ! -f "$db_path" ]; then
        echo "未发现数据库文件: $db_path"
        return
    fi
    local old_size
    old_size=$(du -h "$db_path" 2>/dev/null | cut -f1)
    echo "正在压缩与整理 SQLite 数据库碎片 (当前物理大小: ${old_size})..."
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import sqlite3; conn=sqlite3.connect('$db_path'); conn.execute('VACUUM'); conn.close()" 2>/dev/null || true
    elif command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "$db_path" "VACUUM;" 2>/dev/null || true
    fi
    local new_size
    new_size=$(du -h "$db_path" 2>/dev/null | cut -f1)
    echo "✅ SQLite 数据库压缩整理完毕！体积由 ${old_size} 优化至 ${new_size}。"
}

clean_containers_keep_data() {
    echo "此操作将停止并移除所有面板容器，但保留数据目录和证书！"
    read -r -p "确认清理容器与网络环境? [y/N]: " confirm_c
    if [[ "$confirm_c" =~ ^[yY]$ ]]; then
        echo "正在停止容器..."
        $CMD down --remove-orphans 2>/dev/null || true
        echo "容器已清理完毕，数据目录与 SSL 证书依然完整保留。"
        echo "如需重新启动服务，只需执行: nezha start"
    fi
}

clean_uninstall_all() {
    echo "⚠️  高危警告：此操作将彻底删除哪吒面板容器、网络以及所有数据库与配置数据！"
    read -r -p "此操作不可逆，请确认是否继续？请输入 'yes' 确认: " confirm_clean
    if [ "$confirm_clean" = "yes" ] || [ "$confirm_clean" = "YES" ]; then
        echo "正在彻底卸载与清理..."
        bash "$BASE_DIR/watchdog.sh" disable 2>/dev/null || true
        rm -f /etc/cron.d/nezha-watchdog /var/log/nezha-watchdog.log 2>/dev/null || true
        $CMD down -v --remove-orphans 2>/dev/null || true
        docker rm -f nezha-dashboard nezha-nginx nezha-acme nezha-caddy 2>/dev/null || true
        rm -f /usr/local/bin/nezha 2>/dev/null || true
        cd /
        rm -rf "$BASE_DIR"
        echo "哪吒面板服务及所有数据已彻底卸载并清理完毕！"
        exit 0
    else
        echo "已取消彻底卸载操作。"
    fi
}

cleanup_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "============================================================================"
        echo "                      🧹 哪吒监控 · 系统清理与维护菜单                      "
        echo "============================================================================"
        echo "  1. 清理 Docker 悬空镜像与构建缓存 (释放磁盘空间，不影响正在运行的服务)"
        echo "  2. 截断/清理 Docker 容器超大运行日志 (释放日志磁盘占用)"
        echo "  3. 压缩与整理 SQLite 数据库 (执行 VACUUM 回收空间与碎片整理)"
        echo "  4. 停止并清理容器 (保留面板数据和 SSL 证书配置)"
        echo "  5. 彻底卸载面板端与清理所有数据/证书 (危险操作，不可逆)"
        echo "  ----------------------------------------------------------------------------"
        echo "  0. 返回主菜单"
        echo ""
        read -r -p "👉 请输入清理选择 [0-5]: " clean_choice
        case "$clean_choice" in
            1) clean_docker_cache; press_any_key ;;
            2) clean_container_logs; press_any_key ;;
            3) clean_sqlite_vacuum; press_any_key ;;
            4) clean_containers_keep_data; press_any_key ;;
            5) clean_uninstall_all; press_any_key; break ;;
            0|b|B|q|Q) break ;;
            *) echo "无效输入，请重新选择。"; sleep 1 ;;
        esac
    done
}

show_info() {
    source "$BASE_DIR/.env" 2>/dev/null || true
    local current_agent_key="$AGENT_KEY"
    if [ -f "$BASE_DIR/data/config.yaml" ]; then
        local cfg_key
        cfg_key="$(grep -E '^agent_secret_key:' "$BASE_DIR/data/config.yaml" | awk '{print $2}' | tr -d ' "\r\n')"
        [ -n "$cfg_key" ] && current_agent_key="$cfg_key"
    fi
    echo "============================================================================"
    echo "                    哪吒监控安全增强版 · 部署配置信息                    "
    echo "============================================================================"
    echo "绑定域名:     https://${DOMAIN}"
    echo "前台监控主页: https://${DOMAIN}/${SECRET_PATH}/"
    echo "后台管理控制: https://${DOMAIN}/${SECRET_PATH}/dashboard/"
    echo "默认管理账号: admin"
    echo "默认管理密码: admin (首次进入后台请立即修改)"
    [ -n "$current_agent_key" ] && echo "Agent 通信密钥: ${current_agent_key}"
    echo "通信端口:     ${PORT}"
    echo "安装目录:     ${BASE_DIR}"
    echo "网关架构:     Docker Nginx (alpine, 极低内存)"
    echo "时序存储:     TSDB 已启用 (data/tsdb, 30天自动滚动保留，防 sqlite 膨胀)"
    echo "镜像看门狗:   已配置守护 (每日 04:30 自动拉取 GHCR 镜像并比对 SHA256 平滑重建)"
    echo "证书续期:     Docker acme.sh 容器后台自动守护续期"
    echo "证书文件:     ${BASE_DIR}/ssl/${DOMAIN}.crt"
    echo "============================================================================"
}

show_cert_info() {
    source "$BASE_DIR/.env" 2>/dev/null || true
    local cert_file="${BASE_DIR}/ssl/${DOMAIN}.crt"
    echo "============================================================================"
    echo "                      🔒 SSL 证书状态信息                      "
    echo "============================================================================"
    if [ -f "$cert_file" ]; then
        echo "证书路径: $cert_file"
        openssl x509 -in "$cert_file" -noout -subject -dates -issuer 2>/dev/null || echo "无法读取证书信息"
        echo ""
        local expiry
        expiry=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
        echo "到期时间: $expiry"
        if openssl x509 -checkend $((15 * 86400)) -noout -in "$cert_file" 2>/dev/null; then
            echo "状态: ✅ 正常有效（距到期超过 15 天）"
        else
            echo "状态: ⚠️  证书将在 15 天内到期，后台 acme.sh 将自动续签。"
        fi
        echo ""
        echo "=== acme.sh 容器内证书注册列表 ==="
        docker exec nezha-acme /usr/local/bin/acme.sh --list 2>/dev/null || true
    else
        echo "未检测到证书文件: $cert_file"
    fi
    echo "============================================================================"
}

watchdog_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "============================================================================"
        echo "                   🐶 哪吒监控 · 镜像更新看门狗守护管理                     "
        echo "============================================================================"
        echo "  1. 立即执行看门狗检查 (拉取 GHCR 镜像比对 SHA256，变动则平滑重建)"
        echo "  2. 启用每日自动更新看门狗 (每天 04:30 自动执行)"
        echo "  3. 停用每日自动更新看门狗"
        echo "  4. 查看看门狗运行状态与最近更新日志"
        echo "  5. 实时追踪看门狗运行日志"
        echo "  ----------------------------------------------------------------------------"
        echo "  0. 返回上级菜单"
        echo ""
        read -r -p "👉 请输入选择 [0-5]: " wd_choice
        case "$wd_choice" in
            1) bash "$BASE_DIR/watchdog.sh" run; press_any_key ;;
            2) bash "$BASE_DIR/watchdog.sh" enable; press_any_key ;;
            3) bash "$BASE_DIR/watchdog.sh" disable; press_any_key ;;
            4) bash "$BASE_DIR/watchdog.sh" status; press_any_key ;;
            5) bash "$BASE_DIR/watchdog.sh" logs ;;
            0|b|B|q|Q) break ;;
            *) echo "无效输入，请重新选择。"; sleep 1 ;;
        esac
    done
}

show_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "============================================================================"
        echo "  🚀 哪吒监控定制安全增强版 · 管理控制台 (${VERSION}, Docker Nginx+acme)  "
        echo "============================================================================"
        echo "  1. 查看服务运行状态 (Status)"
        echo "  2. 启动服务 (Start)"
        echo "  3. 停止服务 (Stop)"
        echo "  4. 重启所有容器服务 (Restart)"
        echo "  5. 查看部署配置信息 (Info)"
        echo "  6. 查看面板服务日志 (Panel Logs)"
        echo "  7. 查看 Nginx 网关日志 (Nginx Logs)"
        echo "  8. 查看 acme.sh 续期日志 (acme.sh Logs)"
        echo "  9. 平滑更新面板镜像 (Update)"
        echo "  a. 查看 SSL 证书状态 (SSL Cert Info)"
        echo "  b. 重新加载 Nginx 配置 (Reload Nginx)"
        echo "  c. 系统清理与维护 (Docker 缓存清理 / 日志截断 / 彻底卸载)"
        echo "  d. 镜像更新看门狗守护 (每日 04:30 自动拉取 GHCR 镜像并比对重建)"
        echo "  ----------------------------------------------------------------------------"
        echo "  0. 退出管理控制台"
        echo ""
        read -r -p "👉 请输入选择 [0-9/a-d]: " choice
        case "$choice" in
            1) echo "=== 容器运行状态 ==="; $CMD ps; press_any_key ;;
            2) echo "正在启动服务..."; $CMD up -d; press_any_key ;;
            3) echo "正在停止服务..."; $CMD stop; press_any_key ;;
            4) echo "正在重启所有容器..."; $CMD restart; press_any_key ;;
            5) show_info; press_any_key ;;
            6) $CMD logs -f nezha-dashboard ;;
            7) $CMD logs -f nginx ;;
            8) $CMD logs -f acme ;;
            9) echo "正在平滑更新镜像..."; $CMD pull && $CMD up -d --remove-orphans; press_any_key ;;
            a|A) show_cert_info; press_any_key ;;
            b|B) docker exec nezha-nginx nginx -s reload && echo "✅ Nginx 重载成功！"; press_any_key ;;
            c|C) cleanup_menu ;;
            d|D) watchdog_menu ;;
            0|q|Q) echo "已退出。"; exit 0 ;;
            *) echo "无效输入，请重新选择。"; sleep 1 ;;
        esac
    done
}

case "$1" in
    status)
        echo "=== 容器运行状态 ==="
        $CMD ps
        ;;
    restart)
        echo "正在重启所有容器..."
        $CMD restart
        ;;
    stop)
        echo "正在停止服务..."
        $CMD stop
        ;;
    start)
        echo "正在启动服务..."
        $CMD up -d
        ;;
    logs)
        $CMD logs -f nezha-dashboard
        ;;
    logs-nginx)
        $CMD logs -f nginx
        ;;
    logs-acme)
        $CMD logs -f acme
        ;;
    update)
        echo "正在拉取最新镜像并平滑更新..."
        $CMD pull
        $CMD up -d --remove-orphans
        echo "更新完毕！"
        ;;
    reload-nginx)
        docker exec nezha-nginx nginx -s reload && echo "✅ Nginx 重载成功！"
        ;;
    cert)
        show_cert_info
        ;;
    info)
        show_info
        ;;
    clean|cleanup)
        cleanup_menu
        ;;
    vacuum|clean-db)
        clean_sqlite_vacuum
        ;;
    watchdog)
        shift
        bash "$BASE_DIR/watchdog.sh" "$@"
        ;;
    uninstall)
        clean_uninstall_all
        ;;
    version|-v|--version)
        echo "哪吒监控管理脚本版本: ${VERSION}"
        ;;
    menu|"")
        show_menu
        ;;
    *)
        echo "用法: $0 {menu|status|start|stop|restart|logs|logs-nginx|logs-acme|update|reload-nginx|cert|info|clean|vacuum|watchdog|uninstall|version}"
        exit 1
        ;;
esac
NEZHA_SH_EOF
    chmod +x "$INPUT_DIR/nezha.sh"
    ln -sf "$INPUT_DIR/nezha.sh" /usr/local/bin/nezha 2>/dev/null || true

    generate_watchdog_script "$INPUT_DIR"
    bash "$INPUT_DIR/watchdog.sh" enable "30 4 * * *" >/dev/null 2>&1 || true
    log_ok "已配置并启用看门狗自动更新守护 (每日 04:30 自动拉取 GHCR 镜像并校验重建)"
}

# 平滑更新现有面板部署 (自动迁移老旧 Caddy 配置为 Nginx + acme.sh)
service_update() {
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    if [ ! -d "$target_dir" ] || [ ! -f "$target_dir/.env" ]; then
        log_warn "未在 $target_dir 找到已有部署配置，请先运行安装选项。"
        return
    fi
    source "$target_dir/.env" 2>/dev/null || true
    local cmd="$(get_compose_cmd)"

    log_info "正在检测并升级配置架构 (移除 Caddy，迁移为 Docker Nginx + acme.sh)..."
    docker rm -f nezha-caddy caddy-gateway 2>/dev/null || true
    docker rmi caddy:2.8.4-alpine 2>/dev/null || true

    mkdir -p "${target_dir}/ssl" "${target_dir}/acme-challenge" "${target_dir}/acme-data" "${target_dir}/data/tsdb"
    generate_nginx_conf "$target_dir" "$DOMAIN" "$SECRET_PATH" "$PORT"
    generate_compose_yaml "$target_dir" "$PORT" "$SECRET_PATH"

    # 升级时自动开启 TSDB 时序数据库支持 (彻底解决 sqlite 膨胀)
    local config_file="${target_dir}/data/config.yaml"
    if [ -f "$config_file" ]; then
        if grep -qE '^tsdb: *\{\}' "$config_file"; then
            sed -i '/^tsdb: *{}/c\tsdb:\n  data_path: data/tsdb\n  retention_days: 30' "$config_file"
            log_ok "已为现有部署自动升级开启 TSDB 时序库 (30天自动滚动清理，防 sqlite 膨胀)"
        elif ! grep -qE '^tsdb:' "$config_file"; then
            cat >> "$config_file" <<EOF
tsdb:
  data_path: data/tsdb
  retention_days: 30
EOF
            log_ok "已自动追加开启 TSDB 时序库配置"
        fi
    fi

    prepare_and_issue_ssl "$target_dir" "$DOMAIN" "$EMAIL"

    generate_watchdog_script "$target_dir"
    bash "$target_dir/watchdog.sh" enable "30 4 * * *" >/dev/null 2>&1 || true
    log_ok "已升级并启用看门狗镜像自动更新守护 (每日 04:30 自动拉取并平滑重建)"

    log_info "正在拉取最新容器镜像并启动服务..."
    (cd "$target_dir" && $cmd pull && $cmd up -d --remove-orphans)

    # 尝试重载 Nginx
    docker exec nezha-nginx nginx -s reload >/dev/null 2>&1 || true

    log_ok "面板已平滑更新至最新 Docker Nginx + acme.sh 架构！"
}

# 执行全量安装
do_install() {
    print_banner
    install_dependencies
    check_install_docker
    gather_user_input
    check_ports
    open_firewall_ports
    write_configs
    prepare_and_issue_ssl "$INPUT_DIR" "$INPUT_DOMAIN" "$INPUT_EMAIL"
    print_success
}

# 显示最终部署成功信息
print_success() {
    local panel_url="https://${INPUT_DOMAIN}/${INPUT_SECRET}/"
    local dash_url="https://${INPUT_DOMAIN}/${INPUT_SECRET}/dashboard/"

    echo ""
    echo -e "${GREEN}${BOLD}============================================================================${NC}"
    echo -e "${GREEN}${BOLD}             🎉 恭喜！哪吒监控定制安全增强版已成功部署并启动！             ${NC}"
    echo -e "${GREEN}${BOLD}============================================================================${NC}"
    echo ""
    echo -e "  🌐 ${BOLD}前台监控面板${NC}:     ${CYAN}${panel_url}${NC}"
    echo -e "  ⚙️  ${BOLD}管理后台控制台${NC}:   ${CYAN}${dash_url}${NC}"
    echo ""
    echo -e "  👤 ${BOLD}初始管理员账号${NC}:   ${YELLOW}admin${NC}"
    echo -e "  🔑 ${BOLD}初始管理员密码${NC}:   ${YELLOW}admin${NC} ${RED}(首次登录后请务必立即修改！)${NC}"
    local current_agent_key="$INPUT_AGENT_KEY"
    if [ -z "$current_agent_key" ] && [ -f "$INPUT_DIR/data/config.yaml" ]; then
        current_agent_key="$(grep -E '^agent_secret_key:' "$INPUT_DIR/data/config.yaml" | awk '{print $2}' | tr -d ' "\r\n')"
    fi
    if [ -n "$current_agent_key" ]; then
        echo -e "  🗝️  ${BOLD}Agent 通信密钥${NC}:   ${GREEN}${current_agent_key}${NC} (旧探针可直接使用此密钥连接上线)"
    fi
    echo ""
    echo -e "  🔒 ${BOLD}SSL 证书状态${NC}:"
    echo -e "     - ${GREEN}acme.sh 已签发 Let's Encrypt 证书${NC}"
    echo -e "     - ${GREEN}后台 acme 容器每日自动检测续期${NC}，证书到期前自动热更新并重载 Nginx"
    echo ""
    echo -e "  🛡️  ${BOLD}性能与存储优化特性${NC}:"
    echo -e "     - ${GREEN}纯 Docker Nginx 网关${NC}：内存常驻仅 ~6MB，彻底替代 Caddy"
    echo -e "     - ${GREEN}内置 TSDB 时序数据库${NC}：VictoriaMetrics 引擎托管监控数据，30 天滚动保留，防 sqlite.db 膨胀"
    echo -e "     - ${GREEN}面板软硬内存限制${NC}：GOMEMLIMIT=512MiB + Docker limit 600m，防止 502 崩溃"
    echo -e "     - ${GREEN}自动内存回收${NC}：Go GC 阈值降至 20%，每 6 小时自动向操作系统退还物理内存"
    echo -e "     - ${GREEN}看门狗镜像守护${NC}：每日 04:30 自动拉取 GHCR 镜像并比对 SHA256，变动时平滑重建"
    echo ""
    echo -e "  🛠️  ${BOLD}常用管理命令（已注册 nezha 全局命令）${NC}:"
    echo -e "     - 管理控制台:     ${CYAN}nezha${NC}"
    echo -e "     - 查看运行状态:   ${CYAN}nezha status${NC}"
    echo -e "     - 看门狗更新状态: ${CYAN}nezha watchdog status${NC}"
    echo -e "     - 查看 Nginx 日志:${CYAN}nezha logs-nginx${NC}"
    echo -e "     - 查看证书状态:   ${CYAN}nezha cert${NC}"
    echo -e "     - 平滑更新镜像:   ${CYAN}nezha update${NC}"
    echo ""
    echo -e "${GREEN}============================================================================${NC}"
}

# 辅助检测 Compose 执行命令
get_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo "docker compose"
    fi
}

press_any_key() {
    echo ""
    read -r -p "按回车键继续..." dummy
}

service_status() {
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    if [ ! -d "$target_dir" ] || [ ! -f "$target_dir/docker-compose.yaml" ]; then
        log_warn "未在 $target_dir 检测到有效部署，请先执行安装。"
        return
    fi
    local cmd="$(get_compose_cmd)"
    echo "=== 容器运行状态 ($target_dir) ==="
    (cd "$target_dir" && $cmd ps)
}

service_start() {
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    local cmd="$(get_compose_cmd)"
    log_info "正在启动面板服务..."
    (cd "$target_dir" && $cmd up -d)
    log_ok "服务已启动。"
}

service_stop() {
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    local cmd="$(get_compose_cmd)"
    log_info "正在停止服务..."
    (cd "$target_dir" && $cmd stop)
    log_ok "服务已停止。"
}

service_restart() {
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    local cmd="$(get_compose_cmd)"
    log_info "正在重启所有容器..."
    (cd "$target_dir" && $cmd restart)
    log_ok "所有服务已重启完成。"
}

service_logs() {
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    local cmd="$(get_compose_cmd)"
    echo "正在查看面板日志 (按 Ctrl+C 退出)..."
    (cd "$target_dir" && $cmd logs -f nezha-dashboard)
}

service_logs_nginx() {
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    local cmd="$(get_compose_cmd)"
    echo "正在查看 Nginx 日志 (按 Ctrl+C 退出)..."
    (cd "$target_dir" && $cmd logs -f nginx)
}

service_logs_acme() {
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    local cmd="$(get_compose_cmd)"
    echo "正在查看 acme.sh 续期日志 (按 Ctrl+C 退出)..."
    (cd "$target_dir" && $cmd logs -f acme)
}

service_cert() {
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    if [ -f "$target_dir/.env" ]; then
        source "$target_dir/.env" 2>/dev/null || true
    fi
    local cert_file="${target_dir}/ssl/${DOMAIN}.crt"
    echo "============================================================================"
    echo "                      🔒 SSL 证书状态信息                      "
    echo "============================================================================"
    if [ -f "$cert_file" ]; then
        echo "证书路径: $cert_file"
        openssl x509 -in "$cert_file" -noout -subject -dates -issuer 2>/dev/null || echo "无法读取证书信息"
        echo ""
        local expiry
        expiry=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
        echo "到期时间: $expiry"
        if openssl x509 -checkend $((15 * 86400)) -noout -in "$cert_file" 2>/dev/null; then
            echo "状态: ✅ 正常有效（距到期超过 15 天）"
        else
            echo "状态: ⚠️  证书将在 15 天内到期，后台 acme.sh 将自动续签。"
        fi
        echo ""
        echo "=== acme.sh 容器内证书注册列表 ==="
        docker exec nezha-acme /usr/local/bin/acme.sh --list 2>/dev/null || true
    else
        echo "未检测到证书文件: $cert_file"
    fi
    echo "============================================================================"
}

service_info() {
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    if [ -f "$target_dir/.env" ]; then
        source "$target_dir/.env" 2>/dev/null || true
    fi
    local current_agent_key="$AGENT_KEY"
    if [ -f "$target_dir/data/config.yaml" ]; then
        local cfg_key
        cfg_key="$(grep -E '^agent_secret_key:' "$target_dir/data/config.yaml" | awk '{print $2}' | tr -d ' "\r\n')"
        [ -n "$cfg_key" ] && current_agent_key="$cfg_key"
    fi
    echo ""
    echo -e "${CYAN}${BOLD}============================================================================${NC}"
    echo -e "${CYAN}${BOLD}                    哪吒监控安全增强版 · 部署配置信息                    ${NC}"
    echo -e "${CYAN}${BOLD}============================================================================${NC}"
    echo -e "  - 绑定域名:     ${GREEN}https://${DOMAIN}${NC}"
    echo -e "  - 前台监控主页: ${GREEN}https://${DOMAIN}/${SECRET_PATH}/${NC}"
    echo -e "  - 后台管理控制: ${GREEN}https://${DOMAIN}/${SECRET_PATH}/dashboard/${NC}"
    echo -e "  - 默认管理账号: ${YELLOW}admin${NC}"
    echo -e "  - 默认管理密码: ${YELLOW}admin (首次进入后台请立即修改)${NC}"
    [ -n "$current_agent_key" ] && echo -e "  - Agent通信密钥: ${GREEN}${current_agent_key}${NC} (旧探针可直接使用此密钥连接上线)"
    echo -e "  - 通信端口:     ${GREEN}${PORT}${NC}"
    echo -e "  - 安装目录:     ${GREEN}${INSTALL_DIR:-$target_dir}${NC}"
    echo -e "  - 容器网关:     ${GREEN}Docker Nginx (alpine)${NC}"
    echo -e "  - 时序存储:     ${GREEN}TSDB 已启用 (data/tsdb, 30天自动滚动清理，防 sqlite 膨胀)${NC}"
    echo -e "  - 证书守护:     ${GREEN}Docker acme.sh (自动续期)${NC}"
    echo -e "${CYAN}${BOLD}============================================================================${NC}"
    echo ""
}

service_vacuum() {
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    local db_path="${target_dir}/data/sqlite.db"
    if [ ! -f "$db_path" ]; then
        log_warn "未发现数据库文件: $db_path"
        return
    fi
    local old_size
    old_size=$(du -h "$db_path" 2>/dev/null | cut -f1)
    log_info "正在压缩与整理 SQLite 数据库碎片 (当前大小: ${old_size})..."
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import sqlite3; conn=sqlite3.connect('$db_path'); conn.execute('VACUUM'); conn.close()" 2>/dev/null || true
    elif command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "$db_path" "VACUUM;" 2>/dev/null || true
    fi
    local new_size
    new_size=$(du -h "$db_path" 2>/dev/null | cut -f1)
    log_ok "SQLite 数据库压缩整理完毕！体积由 ${old_size} 优化至 ${new_size}。"
}

show_main_menu() {
    while true; do
        print_banner
        echo -e "${GREEN}${BOLD}  1.${NC} 安装 / 重新部署哪吒面板 (Install / Redeploy)"
        echo -e "${GREEN}${BOLD}  2.${NC} 启动面板服务 (Start Services)"
        echo -e "${GREEN}${BOLD}  3.${NC} 停止面板服务 (Stop Services)"
        echo -e "${GREEN}${BOLD}  4.${NC} 重启所有容器服务 (Restart Services)"
        echo -e "${GREEN}${BOLD}  5.${NC} 查看运行状态与配置 (Status & Info)"
        echo -e "${GREEN}${BOLD}  6.${NC} 查看面板服务日志 (Panel Logs)"
        echo -e "${GREEN}${BOLD}  7.${NC} 查看 Nginx 网关日志 (Nginx Logs)"
        echo -e "${GREEN}${BOLD}  8.${NC} 查看 acme.sh 续期日志 (acme.sh Logs)"
        echo -e "${GREEN}${BOLD}  9.${NC} 平滑更新面板镜像版本 (Update Image)"
        echo -e "${YELLOW}${BOLD}  c.${NC} 系统清理与维护 (Docker 缓存清理 / 日志截断 / 卸载清理)"
        echo -e "${CYAN}${BOLD}  d.${NC} 镜像看门狗设置 (每日 04:30 自动比对 SHA256 平滑更新)"
        echo -e "  ----------------------------------------------------------------------------"
        echo -e "${RED}${BOLD}  0.${NC} 退出脚本"
        echo ""
        read -r -p "👉 请输入选择 [0-9/c/d]: " menu_choice
        case "$menu_choice" in
            1) do_install; break ;;
            2) service_start; press_any_key ;;
            3) service_stop; press_any_key ;;
            4) service_restart; press_any_key ;;
            5) service_info; service_status; press_any_key ;;
            6) service_logs ;;
            7) service_logs_nginx ;;
            8) service_logs_acme ;;
            9) service_update; press_any_key ;;
            c|C) source "${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}/nezha.sh" 2>/dev/null && cleanup_menu || echo "请先安装面板。" ;;
            d|D) source "${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}/nezha.sh" 2>/dev/null && watchdog_menu || (bash "${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}/watchdog.sh" status; press_any_key) ;;
            0|q|Q) echo "退出脚本。"; exit 0 ;;
            *) log_warn "无效输入，请重新选择。"; sleep 1 ;;
        esac
    done
}

show_usage() {
    echo -e "${BOLD}哪吒监控定制安全增强版 · 一键部署与管理脚本 (Docker Nginx + acme.sh)${NC}"
    echo "项目地址: https://github.com/opengaoling/nezha-panel"
    echo ""
    echo "用法: $0 [命令|选项]"
    echo ""
    echo "常用管理命令:"
    echo "  menu          显示交互式主菜单 (默认)"
    echo "  install       安装或重新部署哪吒面板"
    echo "  update        平滑升级至 Docker Nginx + acme.sh 架构并拉取最新镜像"
    echo "  status        查看所有容器运行状态"
    echo "  start         启动面板所有容器"
    echo "  stop          停止面板所有容器"
    echo "  restart       重启所有容器"
    echo "  logs          查看面板服务日志"
    echo "  logs-nginx    查看 Nginx 网关访问日志"
    echo "  logs-acme     查看 acme.sh 证书续期日志"
    echo "  vacuum        压缩与整理 SQLite 数据库释放物理磁盘空间"
    echo "  watchdog      配置或运行看门狗镜像自动更新守护 (每日拉取对比 SHA256)"
    echo "  info          查看当前配置与访问链接"
    echo "  uninstall     彻底卸载并清理全部数据与证书"
    echo ""
    echo "选项:"
    echo "  -d, --domain DOMAIN       指定绑定域名"
    echo "  -e, --email EMAIL         指定证书通知邮箱"
    echo "  -p, --port PORT           指定内部通信端口 (默认: 2052)"
    echo "  -s, --secret SECRET       指定 8 位防探测英文安全路径"
    echo "  -k, --agent-key KEY       指定 Agent 通信密钥 (方便旧探针直接上线)"
    echo "  --dir DIR                 指定安装目录 (默认: /opt/nezha-dashboard)"
    echo "  -y, --yes                 静默自动确认部署"
    echo ""
}

ACTION=""
CLI_SPECIFIED_DOMAIN=""
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -d|--domain) CLI_SPECIFIED_DOMAIN="$2"; DOMAIN="$2"; shift 2 ;;
            -e|--email)  EMAIL="$2"; shift 2 ;;
            -p|--port)   PORT="$2"; shift 2 ;;
            -s|--secret) SECRET_PATH="$2"; shift 2 ;;
            -k|--key|--agent-key) AGENT_KEY="$2"; shift 2 ;;
            --dir)       INSTALL_DIR="$2"; shift 2 ;;
            -y|--yes)    NON_INTERACTIVE="true"; shift ;;
            install|setup) ACTION="install"; shift ;;
            clean|cleanup|--clean) ACTION="clean"; shift ;;
            status) ACTION="status"; shift ;;
            start) ACTION="start"; shift ;;
            stop) ACTION="stop"; shift ;;
            restart) ACTION="restart"; shift ;;
            logs) ACTION="logs"; shift ;;
            logs-nginx) ACTION="logs-nginx"; shift ;;
            logs-acme) ACTION="logs-acme"; shift ;;
            cert) ACTION="cert"; shift ;;
            update) ACTION="update"; shift ;;
            vacuum|clean-db) ACTION="vacuum"; shift ;;
            watchdog) ACTION="watchdog"; shift ;;
            info) ACTION="info"; shift ;;
            uninstall) ACTION="uninstall"; shift ;;
            menu) ACTION="menu"; shift ;;
            -v|--version|version) echo "哪吒监控一键部署脚本版本: ${SCRIPT_VERSION}"; exit 0 ;;
            -h|--help) show_usage; exit 0 ;;
            *) shift ;;
        esac
    done
}

main() {
    check_root
    parse_args "$@"

    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    if [ -f "$target_dir/.env" ]; then
        source "$target_dir/.env" 2>/dev/null || true
    fi

    if [ -n "$ACTION" ]; then
        case "$ACTION" in
            install) do_install ;;
            clean) source "$target_dir/nezha.sh" 2>/dev/null && cleanup_menu ;;
            status) service_status ;;
            start) service_start ;;
            stop) service_stop ;;
            restart) service_restart ;;
            logs) service_logs ;;
            logs-nginx) service_logs_nginx ;;
            logs-acme) service_logs_acme ;;
            cert) service_cert ;;
            update) service_update ;;
            vacuum) service_vacuum ;;
            watchdog) bash "$target_dir/watchdog.sh" "$@" ;;
            info) service_info ;;
            uninstall) source "$target_dir/nezha.sh" 2>/dev/null && clean_uninstall_all ;;
            menu) show_main_menu ;;
            *) show_main_menu ;;
        esac
        return
    fi

    if [ -n "$CLI_SPECIFIED_DOMAIN" ] || [ "$NON_INTERACTIVE" = "true" ]; then
        do_install
    else
        show_main_menu
    fi
}

main "$@"
