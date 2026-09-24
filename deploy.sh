#!/usr/bin/env bash
#=============================================================================
# 🚀 哪吒监控定制安全增强版 · 一键部署脚本 (内置 Caddy 自动申请与自动续期 SSL 证书)
# 项目地址: https://github.com/opengaoling/nezha-panel
# 支持系统: Ubuntu / Debian / CentOS / AlmaLinux / Rocky / Fedora / Alpine
#=============================================================================

set -e

# ANSI 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 全局默认参数
DEFAULT_INSTALL_DIR="/opt/nezha-dashboard"
DEFAULT_PORT="2052"
DOCKER_IMAGE="ghcr.io/opengaoling/nezha-panel:latest"
CADDY_IMAGE="caddy:2-alpine"

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[ OK ]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERR ]${NC} $1"; }

print_banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}"
    echo "============================================================================"
    echo "       🚀 哪吒监控定制安全增强版 · 一键部署脚本 (内置 Caddy 自动证书)       "
    echo "         基于 Nezha Monitoring · 全前置 WAF 防探测 · 8位安全路径隐匿         "
    echo "          Caddy 自动化 HTTPS: 自动申请 Let's Encrypt / ZeroSSL 证书并自动续期   "
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
    log_info "正在检查基础运行依赖 (curl, tar, openssl)..."
    local need_install=""
    for cmd in curl tar openssl awk; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            need_install="$need_install $cmd"
        fi
    done

    if [ -n "$need_install" ]; then
        log_info "正在安装缺失的工具:$need_install"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq && apt-get install -y -qq $need_install
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

    # 检查 docker compose 命令兼容性
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
            apt-get update -qq && apt-get install -y -qq docker-compose-v2 || apt-get install -y -qq docker-compose-plugin || true
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

    # 2. 邮箱配置 (可选，用于 Let's Encrypt 证书到期告警通知)
    if [ -z "$EMAIL" ]; then
        read -r -p "👉 请输入联系邮箱 (用于证书续期通知，建议填写，回车跳过): " INPUT_EMAIL
        INPUT_EMAIL="$(echo "$INPUT_EMAIL" | tr -d ' ')"
    else
        INPUT_EMAIL="$EMAIL"
    fi

    # 3. 面板监听端口
    if [ -z "$PORT" ]; then
        read -r -p "👉 请输入面板监听通信端口 (默认: $DEFAULT_PORT, 回车确认): " INPUT_PORT
        INPUT_PORT="$(echo "$INPUT_PORT" | tr -d ' ')"
        [ -z "$INPUT_PORT" ] && INPUT_PORT="$DEFAULT_PORT"
    else
        INPUT_PORT="$PORT"
    fi

    # 4. 防探测 8 位安全路径
    local auto_secret="$(generate_random_secret)"
    if [ -z "$SECRET_PATH" ]; then
        read -r -p "👉 请输入 8 位防探测英文安全路径 (默认随机: ${auto_secret}, 回车确认): " INPUT_SECRET
        INPUT_SECRET="$(echo "$INPUT_SECRET" | tr -d ' ')"
        [ -z "$INPUT_SECRET" ] && INPUT_SECRET="$auto_secret"
    else
        INPUT_SECRET="$SECRET_PATH"
    fi

    # 校验 8 位英文字母
    while ! [[ "$INPUT_SECRET" =~ ^[a-zA-Z]{8}$ ]]; do
        log_err "安全路径必须严格为 8 位大小写英文字母！"
        read -r -p "请重新输入 8 位英文字母路径 (或直接回车使用 ${auto_secret}): " INPUT_SECRET
        INPUT_SECRET="$(echo "$INPUT_SECRET" | tr -d ' ')"
        [ -z "$INPUT_SECRET" ] && INPUT_SECRET="$auto_secret"
    done

    # 5. 安装目录
    if [ -z "$INSTALL_DIR" ]; then
        read -r -p "👉 请输入安装目录路径 (默认: $DEFAULT_INSTALL_DIR, 回车确认): " INPUT_DIR
        INPUT_DIR="$(echo "$INPUT_DIR" | tr -d ' ')"
        [ -z "$INPUT_DIR" ] && INPUT_DIR="$DEFAULT_INSTALL_DIR"
    else
        INPUT_DIR="$INSTALL_DIR"
    fi

    echo ""
    log_info "配置确认清单:"
    echo "  - 绑定域名:     ${GREEN}${INPUT_DOMAIN}${NC}"
    echo "  - 证书通知邮箱: ${GREEN}${INPUT_EMAIL:-未设置 (Caddy 自动申请)}${NC}"
    echo "  - 内部通信端口: ${GREEN}${INPUT_PORT}${NC}"
    echo "  - 8位安全路径:  ${GREEN}${INPUT_SECRET}${NC}"
    echo "  - 安装目录:     ${GREEN}${INPUT_DIR}${NC}"
    echo "  - 证书方案:     ${GREEN}Caddy 自动申请 Let's Encrypt / ZeroSSL 证书并自动在后台静默续期${NC}"
    echo ""
    read -r -p "确认以上配置并开始部署? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[nN]$ ]]; then
        log_warn "用户取消操作，退出脚本。"
        exit 0
    fi
}

# 检查端口占用 (80, 443, $INPUT_PORT)
check_ports() {
    log_info "正在检查端口占用情况 (80, 443, ${INPUT_PORT})..."
    local conflict=false
    for p in 80 443 "$INPUT_PORT"; do
        if ss -tuln 2>/dev/null | grep -q ":$p " || netstat -tuln 2>/dev/null | grep -q ":$p "; then
            # 检查是否是现有 caddy 或 nezha 容器占用的，若目录一致则可直接覆盖升级
            if [ -d "$INPUT_DIR" ] && [ -f "$INPUT_DIR/docker-compose.yaml" ]; then
                log_warn "检测到端口 $p 已在使用，正在检查是否为本服务..."
            else
                log_err "端口 $p 已被其他程序占用，请先停止占用该端口的服务 (例如 Nginx/Apache) 后再试。"
                conflict=true
            fi
        fi
    done

    if [ "$conflict" = "true" ]; then
        read -r -p "是否尝试强行继续部署? [y/N]: " force_continue
        if ! [[ "$force_continue" =~ ^[yY]$ ]]; then
            exit 1
        fi
    fi
}

# 写入部署配置文件
write_configs() {
    log_info "正在初始化部署目录: $INPUT_DIR"
    mkdir -p "$INPUT_DIR" "$INPUT_DIR/data"
    cd "$INPUT_DIR"

    # 1. 写入 Caddyfile
    log_info "正在生成 Caddyfile 自动化 HTTPS 配置文件..."
    cat > "$INPUT_DIR/Caddyfile" <<EOF
#=============================================================================
# Caddy 自动化 HTTPS 配置文件
# 自动向 Let's Encrypt / ZeroSSL 申请证书并在后台定时自动续期
# 自动启用 HTTP->HTTPS 强制跳转、TLS 1.3 及 HTTP/3 (QUIC)
#=============================================================================
${INPUT_DOMAIN} {
$( [ -n "$INPUT_EMAIL" ] && echo "    email ${INPUT_EMAIL}" )

    # 反向代理至面板容器，自动透传 WebSocket、真实客户端 IP 与 Host
    reverse_proxy nezha-dashboard:${INPUT_PORT} {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }

    # 启用智能高效压缩
    encode zstd gzip

    # 日志输出配置
    log {
        output stdout
        format console
        level INFO
    }
}
EOF

    # 2. 写入 docker-compose.yaml
    log_info "正在生成 docker-compose.yaml 文件..."
    cat > "$INPUT_DIR/docker-compose.yaml" <<EOF
version: '3.8'

services:
  nezha-dashboard:
    image: ${DOCKER_IMAGE}
    container_name: nezha-dashboard
    restart: always
    ports:
      - "${INPUT_PORT}:${INPUT_PORT}" # Agent gRPC 通信端口
    environment:
      - TZ=Asia/Shanghai
      - NEZHA_SECRET_PATH=${INPUT_SECRET}
    volumes:
      - ./data:/dashboard/data
    networks:
      - nezha-net

  caddy:
    image: ${CADDY_IMAGE}
    container_name: nezha-caddy
    restart: always
    ports:
      - "80:80"       # ACME 验证与自动跳转 HTTPS
      - "443:443"     # HTTPS (TLS 1.3 / HTTP/2)
      - "443:443/udp" # HTTP/3 (QUIC)
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data      # 核心证书持久化目录，确保证书自动续期安全保存
      - caddy_config:/config  # Caddy 配置缓存
    depends_on:
      - nezha-dashboard
    networks:
      - nezha-net

volumes:
  caddy_data:
    name: nezha_caddy_data
  caddy_config:
    name: nezha_caddy_config

networks:
  nezha-net:
    name: nezha_internal_net
    driver: bridge
EOF

    # 3. 写入环境配置备忘 .env
    cat > "$INPUT_DIR/.env" <<EOF
DOMAIN=${INPUT_DOMAIN}
EMAIL=${INPUT_EMAIL}
PORT=${INPUT_PORT}
SECRET_PATH=${INPUT_SECRET}
INSTALL_DIR=${INPUT_DIR}
EOF

    # 4. 创建便捷管理命令 nezha
    cat > "$INPUT_DIR/nezha.sh" << 'EOF'
#!/usr/bin/env bash
# Nezha Dashboard & Caddy Management Tool

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

if docker compose version >/dev/null 2>&1; then
    CMD="docker compose"
else
    CMD="docker-compose"
fi

case "$1" in
    status)
        echo "=== 服务运行状态 ==="
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
    logs-caddy|logs-ssl)
        echo "查看 Caddy 证书申请与 Web 访问日志 (Ctrl+C 退出)..."
        $CMD logs -f caddy
        ;;
    update)
        echo "正在拉取最新镜像并平滑更新..."
        $CMD pull
        $CMD up -d --remove-orphans
        echo "更新完毕！"
        ;;
    info)
        source "$BASE_DIR/.env" 2>/dev/null || true
        echo "=============================================="
        echo "哪吒监控安全增强版 · 部署配置信息"
        echo "=============================================="
        echo "绑定域名:     https://${DOMAIN}"
        echo "前台安全网关: https://${DOMAIN}/${SECRET_PATH}/"
        echo "后台管理控制: https://${DOMAIN}/${SECRET_PATH}/dashboard/"
        echo "默认管理账号: admin"
        echo "默认管理密码: admin (首次进入后台请立即修改)"
        echo "内部通信端口: ${PORT}"
        echo "证书管理机制: Caddy 自动申请与全自动后台续期"
        echo "=============================================="
        ;;
    *)
        echo "用法: $0 {status|start|stop|restart|logs|logs-caddy|update|info}"
        exit 1
        ;;
esac
EOF
    chmod +x "$INPUT_DIR/nezha.sh"
    ln -sf "$INPUT_DIR/nezha.sh" /usr/local/bin/nezha 2>/dev/null || true
}

# 启动服务
start_services() {
    log_info "正在拉取容器镜像并启动服务..."
    cd "$INPUT_DIR"
    $COMPOSE_CMD pull
    $COMPOSE_CMD up -d

    log_info "等待服务启动与初始化..."
    sleep 5

    # 简单健康检测
    local running_cnt="$($COMPOSE_CMD ps --status running 2>/dev/null | grep -E "nezha-dashboard|nezha-caddy" | wc -l)"
    if [ "$running_cnt" -ge 2 ]; then
        log_ok "面板容器与 Caddy 证书服务均已成功启动！"
    else
        log_warn "容器启动中，请使用 '$COMPOSE_CMD ps' 查看容器实时状态。"
    fi
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
    echo -e "  🌐 ${BOLD}前台安全访问网关${NC}: ${CYAN}${panel_url}${NC}"
    echo -e "  ⚙️  ${BOLD}管理后台控制台${NC}:   ${CYAN}${dash_url}${NC}"
    echo ""
    echo -e "  👤 ${BOLD}初始管理员账号${NC}:   ${YELLOW}admin${NC}"
    echo -e "  🔑 ${BOLD}初始管理员密码${NC}:   ${YELLOW}admin${NC} ${RED}(首次登录后请务必立即修改！)${NC}"
    echo ""
    echo -e "  🔒 ${BOLD}SSL 域名证书状态${NC}:"
    echo -e "     - ${GREEN}Caddy 自动化 HTTPS 已就绪${NC}：正在/已自动向 Let's Encrypt / ZeroSSL 申请证书。"
    echo -e "     - ${GREEN}全自动证书续期${NC}：后台服务会在证书到期前自动续签，${BOLD}无需任何人工干预或配置 Crontab${NC}。"
    echo -e "     - 证书及密钥已在 Docker 卷 ${CYAN}nezha_caddy_data${NC} 中持久化保存。"
    echo ""
    echo -e "  🖥️  ${BOLD}被控端（Agent）接入命令${NC}:"
    echo -e "     ${YELLOW}curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o nezha.sh && chmod +x nezha.sh${NC}"
    echo -e "     ${YELLOW}./nezha.sh install_agent ${INPUT_DOMAIN} ${INPUT_PORT} <你的Agent密钥>${NC}"
    echo ""
    echo -e "  🛠️  ${BOLD}常用管理命令（已全局注册 nezha 命令）${NC}:"
    echo -e "     - 查看运行状态:       ${CYAN}nezha status${NC}"
    echo -e "     - 查看证书与访问日志: ${CYAN}nezha logs-caddy${NC}"
    echo -e "     - 查看面板服务日志:   ${CYAN}nezha logs${NC}"
    echo -e "     - 重启所有服务:       ${CYAN}nezha restart${NC}"
    echo -e "     - 平滑更新版本:       ${CYAN}nezha update${NC}"
    echo -e "     - 查看当前配置信息:   ${CYAN}nezha info${NC}"
    echo ""
    echo -e "${GREEN}============================================================================${NC}"
}

# 脚本主执行入口
main() {
    print_banner
    check_root
    install_dependencies
    check_install_docker
    gather_user_input
    check_ports
    write_configs
    start_services
    print_success
}

main "$@"
