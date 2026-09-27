#!/usr/bin/env bash
#=============================================================================
# 🚀 哪吒监控定制安全增强版 · 一键部署脚本 (内置 Caddy 自动申请与自动续期 SSL 证书)
# 项目地址: https://github.com/opengaoling/nezha-panel
# 项目支持系统: Ubuntu / Debian / CentOS / AlmaLinux / Rocky / Fedora / Alpine
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
SCRIPT_VERSION="v2.5.0"
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
    echo "       🚀 哪吒监控定制安全增强版 · 一键部署脚本 (${SCRIPT_VERSION})       "
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
        if [ "$NON_INTERACTIVE" = "true" ] || [ "$NON_INTERACTIVE" = "1" ]; then
            INPUT_EMAIL=""
        else
            read -r -p "👉 请输入联系邮箱 (用于证书续期通知，建议填写，回车跳过): " INPUT_EMAIL
            INPUT_EMAIL="$(echo "$INPUT_EMAIL" | tr -d ' ')"
        fi
    else
        INPUT_EMAIL="$EMAIL"
    fi

    # 3. 面板监听端口
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

    echo ""
    log_info "配置确认清单:"
    echo "  - 绑定域名:     ${GREEN}${INPUT_DOMAIN}${NC}"
    echo "  - 证书通知邮箱: ${GREEN}${INPUT_EMAIL:-未设置 (Caddy 自动申请)}${NC}"
    echo "  - 内部通信端口: ${GREEN}${INPUT_PORT}${NC}"
    echo "  - 8位安全路径:  ${GREEN}${INPUT_SECRET}${NC}"
    echo "  - 安装目录:     ${GREEN}${INPUT_DIR}${NC}"
    echo "  - 证书方案:     ${GREEN}Caddy 自动申请 Let's Encrypt / ZeroSSL 证书并自动在后台静默续期${NC}"
    echo ""
    if [ "$NON_INTERACTIVE" != "true" ] && [ "$NON_INTERACTIVE" != "1" ]; then
        read -r -p "确认以上配置并开始部署? [Y/n]: " confirm
        if [[ "$confirm" =~ ^[nN]$ ]]; then
            log_warn "用户取消操作，退出脚本。"
            exit 0
        fi
    fi
}

# 检查端口占用 (80, 443, $INPUT_PORT)
check_ports() {
    log_info "正在检查端口占用情况 (80, 443, ${INPUT_PORT})..."
    # 检查是否有名为 caddy-ssl-test 的测试容器占用了 80/443
    if command -v docker >/dev/null 2>&1 && docker ps -a -q -f name=caddy-ssl-test 2>/dev/null | grep -q .; then
        log_info "清理历史临时测试容器 caddy-ssl-test..."
        docker rm -f caddy-ssl-test >/dev/null 2>&1 || true
    fi

    # 检测宿主机是否有独立原生 nezha-dashboard.service 服务占用通信端口
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nezha-dashboard.service 2>/dev/null; then
        log_warn "检测到宿主机正在运行原生 nezha-dashboard.service 服务。"
        read -r -p "是否停止原生服务以便无缝切换至 Docker Compose 统一管理？[Y/n]: " stop_systemd
        if [[ ! "$stop_systemd" =~ ^[nN]$ ]]; then
            systemctl stop nezha-dashboard.service 2>/dev/null || true
            systemctl disable nezha-dashboard.service 2>/dev/null || true
            log_ok "已停止并禁用原生 nezha-dashboard.service。"
        fi
    fi

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

# 自动放行防火墙端口 (80, 443, $INPUT_PORT)
open_firewall_ports() {
    log_info "正在配置系统防火墙放行端口 (80, 443, ${INPUT_PORT})..."
    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT 1 -p udp --dport 443 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT 1 -p tcp --dport "$INPUT_PORT" -j ACCEPT 2>/dev/null || true
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1 || true
        fi
    fi
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 80/tcp >/dev/null 2>&1 || true
        ufw allow 443/tcp >/dev/null 2>&1 || true
        ufw allow 443/udp >/dev/null 2>&1 || true
        ufw allow "${INPUT_PORT}/tcp" >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=443/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=443/udp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${INPUT_PORT}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

# 写入部署配置文件
write_configs() {
    log_info "正在初始化部署目录: $INPUT_DIR"
    mkdir -p "$INPUT_DIR" "$INPUT_DIR/data"
    cd "$INPUT_DIR"

    local secret_lower
    secret_lower="$(echo "$INPUT_SECRET" | tr '[:upper:]' '[:lower:]')"

    # 1. 写入 Caddyfile
    log_info "正在生成 Caddyfile 自动化 HTTPS 配置文件..."
    cat > "$INPUT_DIR/Caddyfile" <<EOF
#=============================================================================
# Caddy 自动化 HTTPS 配置文件
# 自动向 Let's Encrypt / ZeroSSL 申请证书并在后台定时自动续期
# 自动启用 HTTP->HTTPS 强制跳转、TLS 1.3 及 HTTP/3 (QUIC)
#=============================================================================
${INPUT_DOMAIN} {
$( [ -n "$INPUT_EMAIL" ] && [ "$INPUT_EMAIL" != "0" ] && echo "    tls ${INPUT_EMAIL}" )

    # 启用智能高效压缩 (排除 gRPC 二进制数据流)
    @notGrpc {
        not header Content-Type application/grpc*
    }
    encode @notGrpc zstd gzip

    # 1. gRPC 流量匹配并反向代理 (Agent 通信)，必须透传 h2c (Cleartext HTTP/2)
    @grpc {
        header Content-Type application/grpc*
    }
    handle @grpc {
        reverse_proxy nezha-dashboard:${INPUT_PORT} {
            transport http {
                versions h2c 2
            }
        }
    }

    # 2. 匹配合法面板请求：
    # (a) URL 显式包含 8 位安全路径（如 /${INPUT_SECRET}/ 或 /${INPUT_SECRET}/dashboard/）
    # (b) 或携带合法安全凭据且请求的是前端资源或 API（如 /assets/*, /dashboard/assets/*, /api/*）
    @validPanel \`{path}.startsWith('/${INPUT_SECRET}') || {path}.startsWith('/${secret_lower}') || (({http.request.cookie.nz-secret-path} == '${INPUT_SECRET}' || {http.request.cookie.gw-secret-path} == '${INPUT_SECRET}' || {http.request.header.X-Secret-Path} == '${INPUT_SECRET}' || {http.request.uri.query.secret} == '${INPUT_SECRET}') && ({path}.startsWith('/assets/') || {path}.startsWith('/dashboard/assets/') || {path}.startsWith('/api/') || {path} == '/favicon.ico' || {path} == '/manifest.json' || {path} == '/robots.txt'))\`
    handle @validPanel {
        header {
            Cache-Control "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0"
            Pragma "no-cache"
            Expires "0"
            -ETag
            -Last-Modified
        }

        reverse_proxy nezha-dashboard:${INPUT_PORT} {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_down Cache-Control "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0"
            header_down Pragma "no-cache"
            header_down Expires "0"
            header_down -ETag
            header_down -Last-Modified
        }
    }

    # 3. 兜底伪装：未携带安全凭据的探测请求完全呈现 Caddy 原生默认欢迎页与静态服务
    handle {
        root * /usr/share/caddy
        file_server
    }

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
      nezha-net:
        ipv4_address: 172.18.0.2

  caddy:
    image: ${CADDY_IMAGE}
    container_name: nezha-caddy
    restart: always
    ports:
      - "80:80"       # ACME 验证与自动跳转 HTTPS
      - "443:443"     # HTTPS (TLS 1.3 / HTTP/2)
      - "443:443/udp" # HTTP/3 (QUIC)
    extra_hosts:
      - "nezha-dashboard:172.18.0.2"
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
    ipam:
      config:
        - subnet: 172.18.0.0/16
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
VERSION="v2.5.0"

# 解析实际路径以防通过软链接执行
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
    docker rm -f caddy-ssl-test 2>/dev/null || true
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

clean_containers_keep_data() {
    echo "此操作将停止并移除面板和 Caddy 容器及网络，但保留数据目录和证书！"
    read -r -p "确认清理容器与网络环境? [y/N]: " confirm_c
    if [[ "$confirm_c" =~ ^[yY]$ ]]; then
        echo "正在停止容器并清理网络环境..."
        $CMD down --remove-orphans 2>/dev/null || true
        echo "容器已清理完毕，数据目录与 SSL 证书依然完整保留。"
        echo "如需重新启动服务，只需执行: nezha start"
    fi
}

clean_uninstall_all() {
    echo "⚠️  高危警告：此操作将彻底删除哪吒面板容器、网络、SSL 证书卷以及所有数据库与配置数据！"
    read -r -p "此操作不可逆，请确认是否继续？请输入 'yes' 确认: " confirm_clean
    if [ "$confirm_clean" = "yes" ] || [ "$confirm_clean" = "YES" ]; then
        echo "正在彻底卸载与清理..."
        $CMD down -v --remove-orphans 2>/dev/null || true
        docker volume rm -f nezha_caddy_data nezha_caddy_config 2>/dev/null || true
        docker network rm nezha_internal_net 2>/dev/null || true
        rm -f /usr/local/bin/nezha 2>/dev/null || true
        cd /
        rm -rf "$BASE_DIR"
        echo "哪吒面板与 Caddy 服务及所有数据已彻底卸载并清理完毕！"
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
        echo "  3. 停止并清理容器与虚拟网络 (保留面板数据和 SSL 证书配置)"
        echo "  4. 彻底卸载面板端与清理所有数据/证书 (危险操作，不可逆)"
        echo "  ----------------------------------------------------------------------------"
        echo "  0. 返回主菜单"
        echo ""
        read -r -p "👉 请输入清理选择 [0-4]: " clean_choice
        case "$clean_choice" in
            1) clean_docker_cache; press_any_key ;;
            2) clean_container_logs; press_any_key ;;
            3) clean_containers_keep_data; press_any_key ;;
            4) clean_uninstall_all; press_any_key; break ;;
            0|b|B|q|Q) break ;;
            *) echo "无效输入，请重新选择。"; sleep 1 ;;
        esac
    done
}

show_info() {
    source "$BASE_DIR/.env" 2>/dev/null || true
    echo "============================================================================"
    echo "                    哪吒监控安全增强版 · 部署配置信息                    "
    echo "============================================================================"
    echo "绑定域名:     https://${DOMAIN}"
    echo "前台监控主页: https://${DOMAIN}/${SECRET_PATH}/"
    echo "后台管理控制: https://${DOMAIN}/${SECRET_PATH}/dashboard/"
    echo "默认管理账号: admin"
    echo "默认管理密码: admin (首次进入后台请立即修改)"
    echo "内部通信端口: ${PORT}"
    echo "安装目录:     ${BASE_DIR}"
    echo "证书管理机制: Caddy 自动申请与全自动后台续期 (免配置 Crontab)"
    echo "============================================================================"
}

show_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "============================================================================"
        echo "       🚀 哪吒监控定制安全增强版 · 管理控制台 (${VERSION})       "
        echo "============================================================================"
        echo "  1. 查看服务运行状态 (Status)"
        echo "  2. 启动面板与 Caddy 服务 (Start)"
        echo "  3. 停止服务 (Stop)"
        echo "  4. 重启所有容器服务 (Restart)"
        echo "  5. 查看部署配置信息 (Info)"
        echo "  6. 查看面板服务日志 (Panel Logs)"
        echo "  7. 查看 Caddy 与 SSL 证书日志 (Caddy & SSL Logs)"
        echo "  8. 平滑更新面板镜像 (Update)"
        echo "  9. 系统清理与维护 (Docker 缓存清理 / 日志截断 / 彻底卸载)"
        echo "  ----------------------------------------------------------------------------"
        echo "  0. 退出管理控制台"
        echo ""
        read -r -p "👉 请输入选择 [0-9]: " choice
        case "$choice" in
            1) echo "=== 服务运行状态 ==="; $CMD ps; press_any_key ;;
            2) echo "正在启动服务..."; $CMD up -d; press_any_key ;;
            3) echo "正在停止服务..."; $CMD stop; press_any_key ;;
            4) echo "正在重启所有容器..."; $CMD restart; press_any_key ;;
            5) show_info; press_any_key ;;
            6) $CMD logs -f nezha-dashboard ;;
            7) echo "查看 Caddy 日志 (Ctrl+C 退出)..."; $CMD logs -f caddy ;;
            8) echo "正在拉取最新镜像并更新..."; $CMD pull && $CMD up -d --force-recreate --remove-orphans; press_any_key ;;
            9) cleanup_menu ;;
            0|q|Q) echo "已退出。"; exit 0 ;;
            *) echo "无效输入，请重新选择。"; sleep 1 ;;
        esac
    done
}

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
        $CMD up -d --force-recreate --remove-orphans
        echo "更新完毕！"
        ;;
    info)
        show_info
        ;;
    clean|cleanup)
        cleanup_menu
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
        echo "用法: $0 {menu|status|start|stop|restart|logs|logs-caddy|update|info|clean|uninstall|version}"
        exit 1
        ;;
esac
EOF
    chmod +x "$INPUT_DIR/nezha.sh"
    ln -sf "$INPUT_DIR/nezha.sh" /usr/local/bin/nezha 2>/dev/null || true
}

# 启动服务
start_services() {
    log_info "正在拉取最新容器镜像并启动服务..."
    cd "$INPUT_DIR"
    $COMPOSE_CMD pull || true
    $COMPOSE_CMD up -d --force-recreate --remove-orphans

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
    echo -e "  🌐 ${BOLD}前台监控面板${NC}:     ${CYAN}${panel_url}${NC}"
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
    echo -e "     - 管理主控制台:       ${CYAN}nezha${NC}"
    echo -e "     - 查看运行状态:       ${CYAN}nezha status${NC}"
    echo -e "     - 查看证书与访问日志: ${CYAN}nezha logs-caddy${NC}"
    echo -e "     - 查看面板服务日志:   ${CYAN}nezha logs${NC}"
    echo -e "     - 重启所有服务:       ${CYAN}nezha restart${NC}"
    echo -e "     - 平滑更新版本:       ${CYAN}nezha update${NC}"
    echo -e "     - 查看当前配置信息:   ${CYAN}nezha info${NC}"
    echo -e "     - 系统清理与维护:     ${CYAN}nezha clean${NC}"
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

# 按回车键继续
press_any_key() {
    echo ""
    read -r -p "按回车键继续..." dummy
}

# 服务管理：查看运行状态
service_status() {
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    if [ ! -d "$target_dir" ] || [ ! -f "$target_dir/docker-compose.yaml" ]; then
        log_warn "未在 $target_dir 检测到有效部署，请先执行安装。"
        return
    fi
    local cmd="$(get_compose_cmd)"
    echo "=== 服务运行状态 ($target_dir) ==="
    (cd "$target_dir" && $cmd ps)
}

# 服务管理：启动服务
service_start() {
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    local cmd="$(get_compose_cmd)"
    log_info "正在启动面板与 Caddy 服务..."
    (cd "$target_dir" && $cmd up -d)
    log_ok "服务已启动。"
}

# 服务管理：停止服务
service_stop() {
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    local cmd="$(get_compose_cmd)"
    log_info "正在停止服务..."
    (cd "$target_dir" && $cmd stop)
    log_ok "服务已停止。"
}

# 服务管理：重启服务
service_restart() {
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    local cmd="$(get_compose_cmd)"
    log_info "正在重启所有容器..."
    (cd "$target_dir" && $cmd restart)
    log_ok "所有服务已重启完成。"
}

# 服务管理：查看面板日志
service_logs() {
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    local cmd="$(get_compose_cmd)"
    echo "正在查看面板日志 (按 Ctrl+C 退出)..."
    (cd "$target_dir" && $cmd logs -f nezha-dashboard)
}

# 服务管理：查看 Caddy 日志
service_logs_caddy() {
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    local cmd="$(get_compose_cmd)"
    echo "正在查看 Caddy 域名证书申请与 Web 访问日志 (按 Ctrl+C 退出)..."
    (cd "$target_dir" && $cmd logs -f caddy)
}

# 服务管理：拉取镜像平滑更新
service_update() {
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    local cmd="$(get_compose_cmd)"
    log_info "正在拉取最新镜像并平滑更新..."
    (cd "$target_dir" && $cmd pull && $cmd up -d --remove-orphans)
    log_ok "面板更新完成！"
}

# 服务管理：显示配置与访问链接
service_info() {
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    if [ -f "$target_dir/.env" ]; then
        source "$target_dir/.env" 2>/dev/null || true
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
    echo -e "  - 内部通信端口: ${GREEN}${PORT}${NC}"
    echo -e "  - 安装目录:     ${GREEN}${INSTALL_DIR:-$target_dir}${NC}"
    echo -e "  - 证书管理机制: ${GREEN}Caddy 自动申请与全自动后台续期 (免配置 Crontab)${NC}"
    echo -e "${CYAN}${BOLD}============================================================================${NC}"
    echo ""
}

# 清理功能 1: 清理 Docker 悬空镜像与构建缓存
clean_docker_cache() {
    log_info "正在清理 Docker 悬空镜像及未使用的构建缓存..."
    if command -v docker >/dev/null 2>&1; then
        docker image prune -f
        docker builder prune -f 2>/dev/null || true
        docker rm -f caddy-ssl-test 2>/dev/null || true
        log_ok "Docker 悬空镜像与构建缓存清理完毕！"
    else
        log_warn "未检测到 Docker。"
    fi
}

# 清理功能 2: 截断并清理容器日志
clean_container_logs() {
    log_info "正在扫描并截断清理 Docker 容器日志文件..."
    local cleaned=0
    if [ -d "/var/lib/docker/containers" ]; then
        for log_file in $(find /var/lib/docker/containers/ -name "*-json.log" 2>/dev/null); do
            if [ -f "$log_file" ]; then
                truncate -s 0 "$log_file" 2>/dev/null || true
                cleaned=$((cleaned + 1))
            fi
        done
        log_ok "已成功截断清空 $cleaned 个 Docker 容器日志文件，释放磁盘空间！"
    else
        log_info "未发现 /var/lib/docker/containers 目录。"
    fi
}

# 清理功能 3: 停止并清理容器与虚拟网络 (保留数据与证书)
clean_containers_keep_data() {
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    local cmd="$(get_compose_cmd)"
    if [ -d "$target_dir" ] && [ -f "$target_dir/docker-compose.yaml" ]; then
        log_warn "此操作将停止并移除面板和 Caddy 容器实例及虚拟网络，但会完整保留数据目录和 SSL 证书！"
        read -r -p "确认清理容器与网络环境? [y/N]: " confirm_clean_c
        if [[ "$confirm_clean_c" =~ ^[yY]$ ]]; then
            log_info "正在停止容器并清理网络环境..."
            (cd "$target_dir" && $cmd down --remove-orphans 2>/dev/null || true)
            log_ok "容器与虚拟网络已清理完毕，数据目录 ($target_dir/data) 和 SSL 证书依然完整保留。"
            log_info "如需重新启动服务，只需执行: nezha start 或 $0 start"
        else
            log_info "已取消清理容器操作。"
        fi
    else
        log_warn "未找到已部署的 compose 目录: $target_dir"
    fi
}

# 清理功能 4: 彻底卸载面板并清理全部数据与证书 (高危卸载)
clean_uninstall_all() {
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    local cmd="$(get_compose_cmd)"
    echo ""
    echo -e "${RED}${BOLD}============================================================================${NC}"
    echo -e "${RED}${BOLD}  ⚠️  高危警告：彻底卸载与完全清除操作                                        ${NC}"
    echo -e "${RED}${BOLD}============================================================================${NC}"
    echo -e "${RED}此操作将："
    echo -e "  1. 彻底停止并删除所有哪吒与 Caddy 容器实例"
    echo -e "  2. 删除内部虚拟桥接网络 nezha_internal_net"
    echo -e "  3. 删除 Caddy 证书持久化卷 (nezha_caddy_data / nezha_caddy_config)"
    echo -e "  4. 彻底删除安装目录 (${target_dir}) 及其所有数据库和配置数据！"
    echo -e "  5. 移除全局快捷管理命令 /usr/local/bin/nezha"
    echo -e "${NC}"
    read -r -p "此操作不可逆，请确认是否彻底卸载并清理全部数据？请输入 'yes' 确认: " confirm_clean
    if [ "$confirm_clean" = "yes" ] || [ "$confirm_clean" = "YES" ]; then
        log_info "正在彻底卸载与清理..."
        if [ -d "$target_dir" ] && [ -f "$target_dir/docker-compose.yaml" ]; then
            (cd "$target_dir" && $cmd down -v --remove-orphans 2>/dev/null || true)
        fi
        if command -v docker >/dev/null 2>&1; then
            docker rm -f nezha-dashboard nezha-caddy caddy-ssl-test 2>/dev/null || true
            docker volume rm -f nezha_caddy_data nezha_caddy_config 2>/dev/null || true
            docker network rm nezha_internal_net 2>/dev/null || true
        fi
        if [ -d "$target_dir" ]; then
            rm -rf "$target_dir"
            log_ok "已清除安装目录: $target_dir"
        fi
        rm -f /usr/local/bin/nezha 2>/dev/null || true
        log_ok "已移除全局 nezha 命令。"
        echo -e "${GREEN}${BOLD}哪吒面板、Caddy 证书服务及所有数据已彻底卸载并清理完毕！${NC}"
    else
        log_info "已取消彻底卸载操作。"
    fi
}

# 交互式清理菜单
cleanup_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}${BOLD}"
        echo "============================================================================"
        echo "                      🧹 哪吒监控 · 系统清理与维护菜单                      "
        echo "============================================================================"
        echo -e "${NC}"
        echo -e "${GREEN}${BOLD}  1.${NC} 清理 Docker 悬空镜像与构建缓存 (释放磁盘空间，不影响正在运行的服务)"
        echo -e "${GREEN}${BOLD}  2.${NC} 截断/清理 Docker 容器超大运行日志 (释放日志磁盘占用)"
        echo -e "${YELLOW}${BOLD}  3.${NC} 停止并清理容器与虚拟网络 (保留面板数据和 SSL 证书配置)"
        echo -e "${RED}${BOLD}  4.${NC} 彻底卸载面板端与清理所有数据/证书 (危险操作，不可逆)"
        echo -e "  ----------------------------------------------------------------------------"
        echo -e "${BLUE}${BOLD}  0.${NC} 返回主菜单"
        echo ""
        read -r -p "👉 请输入清理选项 [0-4]: " clean_choice
        case "$clean_choice" in
            1) clean_docker_cache; press_any_key ;;
            2) clean_container_logs; press_any_key ;;
            3) clean_containers_keep_data; press_any_key ;;
            4) clean_uninstall_all; press_any_key; break ;;
            0|b|B|q|Q) break ;;
            *) log_warn "无效输入，请重新选择。"; sleep 1 ;;
        esac
    done
}

# 完整安装流程
do_install() {
    print_banner
    install_dependencies
    check_install_docker
    gather_user_input
    check_ports
    open_firewall_ports
    write_configs
    start_services
    print_success
}

# 交互式主菜单
show_main_menu() {
    while true; do
        print_banner
        echo -e "${GREEN}${BOLD}  1.${NC} 安装 / 重新部署哪吒面板 (Install / Redeploy)"
        echo -e "${GREEN}${BOLD}  2.${NC} 启动面板与 Caddy 服务 (Start Services)"
        echo -e "${GREEN}${BOLD}  3.${NC} 停止面板与 Caddy 服务 (Stop Services)"
        echo -e "${GREEN}${BOLD}  4.${NC} 重启所有容器服务 (Restart Services)"
        echo -e "${GREEN}${BOLD}  5.${NC} 查看运行状态与配置 (Status & Info)"
        echo -e "${GREEN}${BOLD}  6.${NC} 查看面板服务日志 (Panel Logs)"
        echo -e "${GREEN}${BOLD}  7.${NC} 查看 Caddy 与 SSL 证书日志 (Caddy & SSL Logs)"
        echo -e "${GREEN}${BOLD}  8.${NC} 平滑更新面板镜像版本 (Update Image)"
        echo -e "${YELLOW}${BOLD}  9.${NC} 系统清理与维护 (Docker 缓存清理 / 日志截断 / 卸载清理)"
        echo -e "  ----------------------------------------------------------------------------"
        echo -e "${RED}${BOLD}  0.${NC} 退出脚本"
        echo ""
        read -r -p "👉 请输入选择 [0-9]: " menu_choice
        case "$menu_choice" in
            1) do_install; break ;;
            2) service_start; press_any_key ;;
            3) service_stop; press_any_key ;;
            4) service_restart; press_any_key ;;
            5) service_info; service_status; press_any_key ;;
            6) service_logs ;;
            7) service_logs_caddy ;;
            8) service_update; press_any_key ;;
            9) cleanup_menu ;;
            0|q|Q) echo "退出脚本。"; exit 0 ;;
            *) log_warn "无效输入，请重新选择。"; sleep 1 ;;
        esac
    done
}

# 显示帮助信息
show_usage() {
    echo -e "${BOLD}哪吒监控定制安全增强版 · 一键部署与管理脚本${NC}"
    echo "项目地址: https://github.com/opengaoling/nezha-panel"
    echo ""
    echo "用法: $0 [命令|选项]"
    echo ""
    echo "常用管理命令:"
    echo "  menu          显示交互式主菜单 (默认)"
    echo "  install       安装或重新部署哪吒面板与 Caddy"
    echo "  clean         进入系统清理与维护菜单 (清理 Docker 缓存/日志/彻底卸载)"
    echo "  status        查看服务运行状态"
    echo "  start         启动面板与 Caddy 服务"
    echo "  stop          停止服务"
    echo "  restart       重启所有服务"
    echo "  logs          查看面板服务实时日志"
    echo "  logs-caddy    查看 Caddy 与 SSL 证书申请日志"
    echo "  update        拉取最新镜像平滑更新"
    echo "  info          查看当前配置与访问链接"
    echo "  uninstall     彻底卸载并清理全部数据与证书"
    echo ""
    echo "配置选项 (用于自动化/非交互部署):"
    echo "  -d, --domain <domain>   绑定域名"
    echo "  -e, --email <email>     证书通知邮箱 (可选)"
    echo "  -p, --port <port>       内部通信端口 (默认: 2052)"
    echo "  -s, --secret <secret>   8位英文字母安全路径"
    echo "  --dir <path>            安装目录 (默认: /opt/nezha-dashboard)"
    echo "  -y, --yes               非交互自动确认模式"
    echo "  -h, --help              查看帮助信息"
    echo ""
}

# 解析命令行参数与子命令
ACTION=""
CLI_SPECIFIED_DOMAIN=""
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -d|--domain) CLI_SPECIFIED_DOMAIN="$2"; DOMAIN="$2"; shift 2 ;;
            -e|--email)  EMAIL="$2"; shift 2 ;;
            -p|--port)   PORT="$2"; shift 2 ;;
            -s|--secret) SECRET_PATH="$2"; shift 2 ;;
            --dir)       INSTALL_DIR="$2"; shift 2 ;;
            -y|--yes)    NON_INTERACTIVE="true"; shift ;;
            install|setup) ACTION="install"; shift ;;
            clean|cleanup|--clean) ACTION="clean"; shift ;;
            status) ACTION="status"; shift ;;
            start) ACTION="start"; shift ;;
            stop) ACTION="stop"; shift ;;
            restart) ACTION="restart"; shift ;;
            logs) ACTION="logs"; shift ;;
            logs-caddy|logs-ssl) ACTION="logs-caddy"; shift ;;
            update) ACTION="update"; shift ;;
            info) ACTION="info"; shift ;;
            uninstall) ACTION="uninstall"; shift ;;
            menu) ACTION="menu"; shift ;;
            -v|--version|version) echo "哪吒监控一键部署脚本版本: ${SCRIPT_VERSION}"; exit 0 ;;
            -h|--help) show_usage; exit 0 ;;
            *) shift ;;
        esac
    done
}

# 脚本主执行入口
main() {
    check_root
    parse_args "$@"

    # 尝试预加载已有部署配置
    local target_dir="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    if [ -f "$target_dir/.env" ]; then
        source "$target_dir/.env" 2>/dev/null || true
    fi

    # 如果指定了具体子命令动作，直接执行
    if [ -n "$ACTION" ]; then
        case "$ACTION" in
            install) do_install ;;
            clean) cleanup_menu ;;
            status) service_status ;;
            start) service_start ;;
            stop) service_stop ;;
            restart) service_restart ;;
            logs) service_logs ;;
            logs-caddy) service_logs_caddy ;;
            update) service_update ;;
            info) service_info ;;
            uninstall) clean_uninstall_all ;;
            menu) show_main_menu ;;
            *) show_main_menu ;;
        esac
        return
    fi

    # 如果通过参数直接传入了域名或指定了自动确认，则直接开始安装
    if [ -n "$CLI_SPECIFIED_DOMAIN" ] || [ "$NON_INTERACTIVE" = "true" ]; then
        do_install
    else
        show_main_menu
    fi
}

main "$@"
