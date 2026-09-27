<div align="center">
  <br>
  <h1>🚀 哪吒监控定制安全增强版</h1>
  <p><b>基于 Nezha Monitoring 重构与安全加固 · 内置现代科技风主题 · 全前置 WAF 防探测 · 8位随机路径隐匿</b></p>
  <br>
</div>

---

## 🌟 核心特性

- 🎨 **内置现代科技风磨砂玻璃主题**：无需独立部署前端或子模块依赖，前端静态资源（`user-dist` 与 `admin-dist`）直接内嵌于面板二进制及服务中，高质感玻璃拟态 UI，预渲染技术杜绝白屏与 FOUC 闪烁。
- ⚡ **长时间停留/唤醒防白屏自愈机制**：前端内置全局异常与动态 Chunk 加载失败拦截、Tab 切换/休眠唤醒探测。如果页面长时间空闲造成 React `#root` 异常变白，将毫秒级自动触发无感自愈恢复，免去手动 Ctrl+F5 刷新。
- 🔒 **全前置 WAF 防探测加固（Anti-Probe WAF）**：未通过 8 位随机安全路径直接探测任何内部路径（包括 `/dashboard`、`/dashboard/*`、`/api/v1/*`、`/mcp`、`/swagger`、`/debug/pprof` 等），服务端一律返回纯文本 `404 page not found`，彻底杜绝指纹泄露与扫描器探测。
- 🔑 **8 位随机英文字母隐匿路径（`SecretPath`）**：
  - 全站隐匿在 8 位随机英文字母前缀下（例如：`domain.com/mKovrigH/dashboard/`、`domain.com/mKovrigH/`）。
  - **自动生成与持久化**：首次启动若未设置，系统自动通过高强度安全随机源生成 8 位英文字母并保存至 `config.yaml`。
  - **大小写全兼容**：支持 `/Dashboard` 与 `/dashboard` 访问，智能映射。
  - **无感安全会话**：通过专属路径访问时自动下发安全 Cookie，后续所有的 SPA 资源请求、API 调用与 WebSocket 数据流均畅行无阻。
- 🌐 **去指纹化非特征默认端口（`2052`）**：彻底移除与哪吒监控强关联的传统特征端口（`8008`），默认采用全网无关联的 `2052` 端口；同时该端口原生兼容 Cloudflare CDN 免费版回源转发，兼具隐蔽性与 CDN 扩展性。
- 🧪 **内置 Playwright 12 项 E2E 自动化测试套件**：代码库内置端到端真实浏览器自动化测试脚本及开发规范，确保每次版本更新前均通过包括防探测、网关卡片、表单验证、防回弹、抗白屏等在内的全部质检。

---

## 📦 部署教程

### 方式一：一键自动化部署脚本（强烈推荐 · 内置 Caddy 自动申请与自动续期 SSL 证书）

只需执行一条命令即可完成全套部署，脚本会自动检测并配置 Docker 与 Docker Compose 环境、交互式引导您填写域名、自动生成 8 位安全隐匿路径，并通过 **Caddy 自动向 Let's Encrypt / ZeroSSL 申请 HTTPS 域名证书并在后台静默自动续期**，全程无需任何人工干预或配置繁琐的 certbot 与 crontab 定时任务。

#### 1. 运行一键部署命令
```bash
curl -fsSL https://raw.githubusercontent.com/opengaoling/nezha-panel/master/deploy.sh -o deploy.sh && chmod +x deploy.sh && sudo ./deploy.sh
```
*或使用简短管道执行：*
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/opengaoling/nezha-panel/master/deploy.sh)
```

#### 2. 交互式参数引导
脚本执行后将依次提示以下设置（直接回车可使用建议默认值）：
1. **绑定域名**：输入已解析到本机公网 IP 的域名（例如 `monitor.yourdomain.com`）。
2. **联系邮箱**（可选）：用于接收 Let's Encrypt 证书状态通知，回车可直接跳过（Caddy 仍会自动申请证书）。
3. **通信端口**：默认 `2052`（去特征化端口，支持面板与被控端 Agent 通信）。
4. **8 位安全路径**：系统默认随机生成高强度 8 位英文字母（例如 `mKovrigH`），直接回车确认即可。
5. **安装目录**：默认 `/opt/nezha-dashboard`。

#### 3. 访问面板与后台
部署完成后终端将输出专属访问信息：
- 🌐 **前台监控面板**：`https://<你的域名>/<8位随机路径>/`
- ⚙️ **管理后台控制台**：`https://<你的域名>/<8位随机路径>/dashboard/`
- 👤 **默认管理员账号**：`admin`
- 🔑 **默认管理员密码**：`admin`（首次登录后请立即进入系统设置修改密码）

#### 4. 便捷管理工具（全局 `nezha` 快捷命令）
部署脚本会自动在系统注册 `nezha` 全局管理命令，可在任意目录下直接使用：
```bash
nezha              # 打开可视化交互式管理主菜单（推荐）
nezha clean        # 进入系统清理与维护菜单（清理 Docker 冗余镜像/日志截断/彻底卸载）
nezha status       # 查看面板容器与 Caddy 运行状态
nezha logs-caddy   # 实时查看 Caddy 域名证书申请与 Web 访问日志
nezha logs         # 实时查看面板后端服务日志
nezha restart      # 一键平滑重启所有服务
nezha update       # 一键拉取最新镜像平滑更新
nezha info         # 查看当前配置备忘与访问链接
```

运行部署脚本自身亦可调出主菜单与进行快捷维护：
```bash
./deploy.sh        # 打开部署主菜单
./deploy.sh clean  # 直接进入清理与维护菜单
```


---

### 方式二：手动 Docker Compose 部署

#### 1. 创建项目目录
```bash
mkdir -p /opt/nezha-dashboard && cd /opt/nezha-dashboard
```

#### 2. 编写 `docker-compose.yaml`
在当前目录下创建 `docker-compose.yaml` 文件：

```yaml
version: '3.8'

services:
  nezha-dashboard:
    image: ghcr.io/opengaoling/nezha-panel:latest
    container_name: nezha-dashboard
    restart: always
    ports:
      - "2052:2052"   # Web 面板端口与 Agent gRPC 通信端口
    environment:
      - TZ=Asia/Shanghai
      # 可选：自定义固定 8 位防探测字母路径（不填则首次启动自动随机生成）
      # - NEZHA_SECRET_PATH=jjjjjjxf
    volumes:
      - ./data:/dashboard/data
```

#### 3. 启动面板
```bash
docker compose up -d
```

#### 4. 查看生成的防探测访问路径
首次启动时，面板会自动生成 8 位防探测英文路径，通过查看容器日志即可获取：
```bash
docker compose logs -f
```
日志中会输出如下提示：
```text
NEZHA>> generated new secret_path: /jjjjjjxf (access panel via /jjjjjjxf/ or /jjjjjjxf/Dashboard)
```

#### 5. 首次登录与配置
1. 在浏览器中打开：`http://<你的服务器IP>:2052/<8位随机路径>/Dashboard`（例如 `http://1.2.3.4:2052/jjjjjjxf/Dashboard`）。
2. 若系统为初始安装，默认管理员账号密码为：
   - 用户名：`admin`
   - 密　码：`admin`
3. 登录成功后，请立即进入 **后台管理 -> 系统设置** 修改密码，确保服务器安全。

---

### 方式三：Docker CLI 直接运行

如果习惯使用单行命令运行，可直接执行：

```bash
docker run -d \
  --name nezha-dashboard \
  --restart always \
  -p 2052:2052 \
  -e TZ=Asia/Shanghai \
  -v /opt/nezha-dashboard/data:/dashboard/data \
  ghcr.io/opengaoling/nezha-panel:latest
```

查看随机访问路径：
```bash
docker logs nezha-dashboard
```

---

### 方式四：独立二进制 Systemd 服务部署（原生高性能）

适用于不希望运行 Docker 的轻量级云服务器或 VPS：

#### 1. 创建运行目录与数据目录
```bash
sudo mkdir -p /opt/nezha-panel/bin /opt/nezha-panel/data
cd /opt/nezha-panel
```

#### 2. 下载或放置构建好的 dashboard 二进制
```bash
# 将构建产物 dashboard 放置在 /opt/nezha-panel/bin/dashboard
sudo chmod +x /opt/nezha-panel/bin/dashboard
```

#### 3. 配置 Systemd 服务
创建服务单元文件 `/etc/systemd/system/nezha-dashboard.service`：
```ini
[Unit]
Description=Nezha Monitoring Dashboard
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/nezha-panel
ExecStart=/opt/nezha-panel/bin/dashboard -c /opt/nezha-panel/data/config.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
```

#### 4. 启动与开机自启
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now nezha-dashboard
```

#### 5. 查看运行状态与 8 位随机访问路径
```bash
sudo systemctl status nezha-dashboard
# 或查看日志获取生成的 8 位随机路径：
sudo journalctl -u nezha-dashboard -n 50 --no-pager
# 或直接读取配置文件：
cat /opt/nezha-panel/data/config.yaml | grep secret_path
```

---

### 方式五：自定义反向代理配置（若已有独立 Nginx / Caddy 服务）

若您已在宿主机部署了统一反向代理服务（不使用部署脚本内置的 Caddy 容器），可按以下配置反向代理至面板（注意放行 WebSocket 与 gRPC）：

#### Nginx 配置示例
```nginx
server {
    listen 80;
    server_name monitor.yourdomain.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name monitor.yourdomain.com;

    ssl_certificate /path/to/fullchain.cer;
    ssl_certificate_key /path/to/private.key;

    # 传递真实客户端 IP
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    # gRPC 通信（Agent 监控数据上报）
    location /proto.NezhaService/ {
        grpc_pass grpc://127.0.0.1:2052;
        grpc_read_timeout 1d;
        grpc_send_timeout 1d;
        client_max_body_size 0;
    }

    # WebSocket 与 Web 页面支持
    location / {
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_pass http://127.0.0.1:2052;
    }
}
```

#### Caddy 配置示例
```caddy
monitor.yourdomain.com {
    # 全站禁用浏览器缓存，避免前端资源更新后白屏
    header {
        Cache-Control "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0"
        Pragma "no-cache"
        Expires "0"
        -ETag
        -Last-Modified
    }

    # gRPC 流量匹配并反向代理 (Agent 通信)，透传 h2c (Cleartext HTTP/2)
    @grpc {
        header Content-Type application/grpc*
    }
    reverse_proxy @grpc 127.0.0.1:2052 {
        transport http {
            versions h2c 2
        }
    }

    # 普通 Web / REST API / WebSocket 反向代理
    reverse_proxy 127.0.0.1:2052 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
    }

    # 智能压缩（排除 gRPC 二进制数据流）
    @notGrpc {
        not header Content-Type application/grpc*
    }
    encode @notGrpc zstd gzip
}
```

---

## ⚙️ 核心配置说明

所有面板配置保存在挂载目录的 `data/config.yaml` 中，支持热重载或重启生效：

| 配置项 | 环境变量 | 说明 | 示例 |
| :--- | :--- | :--- | :--- |
| `secret_path` | `NEZHA_SECRET_PATH` | 8 位随机英文路径防探测前缀 | `jjjjjjxf` |
| `listen_port` | - | 面板服务监听端口（默认去指纹化端口） | `2052` |
| `agent_secret_key` | - | 全局 Agent 通信连接密钥（兼容旧机器快速上线） | `your-secret-here` |
| `jwt_timeout` | - | 登录 Token 过期有效时长（小时） | `24` |
| `force_auth` | - | 是否强制要求全局认证 | `true` |

---

## 🖥️ 被控端（Agent）接入指南

### 1. 新机器一键接入

在需要被监控的客户端服务器上，执行接入命令：

**推荐：通过 443 端口启用 TLS 加密接入（安全且穿透性强）**
```bash
curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o nezha.sh && chmod +x nezha.sh
./nezha.sh install_agent <你的域名> 443 <Agent通信密钥> --tls
```

**或者：直连面板 2052 端口接入**
```bash
./nezha.sh install_agent <面板域名或IP> 2052 <Agent通信密钥>
```

### 2. 原有已有旧机器无感恢复上线

若原先已有大量机器安装了 Agent，**完全不需要去每台机器上重装或修改配置**：
1. 查看您原有机器 Agent 配置文件中记录的通信密钥（即 `client_secret`）；
2. 打开部署目录下的 `data/config.yaml`，将 `agent_secret_key` 设置为您原有的密钥：
   ```yaml
   agent_secret_key: "您原机器的密钥"
   ```
3. 执行 `docker compose restart nezha-dashboard` 重启面板；
4. 原有的全部旧机器将在数十秒内自动重新连接并全部恢复上线。

---

## 🛡️ 防探测安全机制说明

1. **直接探测防护**：
   - 任何未通过 8 位秘密路径或无安全 Cookie 的客户端，访问 `domain.com/`、`domain.com/dashboard`、`domain.com/api/v1/setting` 等，均直接返回 `404 page not found`，对全网扫描器（如 Shodan、Censys、FOFA）完全隐匿。
2. **凭据隔离**：
   - 必须通过 `domain.com/<8位字母>/` 或 `domain.com/<8位字母>/Dashboard` 访问。
   - 访问一次有效秘密路径后，浏览器将自动保存安全 Cookie，后续正常使用无需反复输入随机前缀。
3. **安全建议**：
   - 首次部署完成后，建议在管理后台重命名管理员账号并设置强密码。
   - 防探测路径（8 位随机字母）请妥善保存，切勿公开泄露。

---

## 🧪 自动化 Playwright E2E 验证

本项目已配置基于 Playwright 的端到端真实浏览器自动化验证体系，覆盖鉴权、防探测、路由跳转与防白屏全流程：

```bash
# 执行全量 12 项端到端实机验证
python3 /home/ubuntu/playwright_verification/verify_with_playwright.py
```

### 自动化覆盖场景与质量基线
1. **未登录拦截与重定向**：访问未授权后台立即跳转 `/?redirect=` 并展示安全网关卡片，无控制台错误。
2. **表单完整性与无品牌泄露**：校验输入项均可用，DOM 根节点与文本绝无品牌标识泄漏。
3. **安全网关登录与自动放行**：提交凭证完成 `/api/v1/login` 认证，直接平滑进入后台。
4. **后台会话稳定（防反弹）**：直接访问后台稳定停留，React 根容器稳定挂载（杜绝白屏）。
5. **前台公开监控态**：已登录状态下展示通用用户状态条（`#gw-auth-pill`），网关自动隐匿。
6. **退出登录闭环**：退出登录即刻注销会话、清除 Cookie 并重新唤起安全网关。

