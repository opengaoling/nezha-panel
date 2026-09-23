<div align="center">
  <br>
  <h1>🚀 哪吒监控定制安全增强版</h1>
  <p><b>基于 Nezha Monitoring 重构与安全加固 · 内置现代科技风主题 · 全前置 WAF 防探测 · 8位随机路径隐匿</b></p>
  <br>
</div>

---

## 🌟 核心特性

- 🎨 **内置现代科技风磨砂玻璃主题**：无需独立部署前端或子模块依赖，前端资源（`user-dist` 与 `admin-dist`）直接内嵌于面板中，预渲染技术杜绝白屏与 FOUC 闪烁。
- 🔐 **前置访问身份网关**：未登录用户在进入监控主界面前必须登录，账号密码与面板完全统一，支持记住账号凭据与平滑动画解锁。
- 🛡️ **前置 WAF 防探测加固（Anti-Probe WAF）**：未登录前直接探测任何内部路径（包括 `/dashboard`、`/dashboard/*`、`/api/v1/*`、`/mcp`、`/swagger`、`/debug/pprof` 等），服务端一律返回纯文本 `404 page not found`，彻底杜绝指纹泄露与扫描器探测。
- 🔒 **8 位随机大小写英文字母防探测路径（`SecretPath`）**：
  - 全站隐匿在 8 位随机英文字母前缀下（例如：`domain.com/jjjjjjxf/Dashboard`、`domain.com/jjjjjjxf/`）。
  - **自动生成与持久化**：首次启动若未设置，系统自动通过安全随机源生成 8 位英文字母并保存至 `config.yaml`。
  - **大小写全兼容**：支持 `/Dashboard` 与 `/dashboard` 访问，未登录访问后台自动重定向至登录界面，登录成功后自动跳转回目标后台。
  - **无感安全会话**：通过专属路径访问时自动下发 `nz-secret-path` Cookie，后续所有的 SPA 资源请求、API 调用与 WebSocket 数据流均畅行无阻。

---

## 📦 部署教程

### 方式一：Docker Compose 部署（强烈推荐）

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
      - "8008:8008"   # Web 面板端口与 Agent gRPC 通信端口
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
1. 在浏览器中打开：`http://<你的服务器IP>:8008/<8位随机路径>/Dashboard`（例如 `http://1.2.3.4:8008/jjjjjjxf/Dashboard`）。
2. 若系统为初始安装，默认管理员账号密码为：
   - 用户名：`admin`
   - 密　码：`admin`
3. 登录成功后，请立即进入 **后台管理 -> 系统设置** 修改密码，确保服务器安全。

---

### 方式二：Docker CLI 直接运行

如果习惯使用单行命令运行，可直接执行：

```bash
docker run -d \
  --name nezha-dashboard \
  --restart always \
  -p 8008:8008 \
  -e TZ=Asia/Shanghai \
  -v /opt/nezha-dashboard/data:/dashboard/data \
  ghcr.io/opengaoling/nezha-panel:latest
```

查看随机访问路径：
```bash
docker logs nezha-dashboard
```

---

### 方式三：独立二进制 Systemd 服务部署（原生高性能）

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

### 方式四：反向代理与域名 SSL 配置

为面板绑定域名并配置 SSL 证书时，需注意开启 **WebSocket** 支持与 **gRPC** 兼容。

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

    # WebSocket 支持
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";

    location / {
        proxy_pass http://127.0.0.1:8008;
    }
}
```

#### Caddy 配置示例
```caddy
monitor.yourdomain.com {
    reverse_proxy 127.0.0.1:8008
}
```

---

## ⚙️ 核心配置说明

所有面板配置保存在挂载目录的 `data/config.yaml` 中，支持热重载或重启生效：

| 配置项 | 环境变量 | 说明 | 示例 |
| :--- | :--- | :--- | :--- |
| `secret_path` | `NEZHA_SECRET_PATH` | 8 位随机英文路径防探测前缀 | `jjjjjjxf` |
| `listen_port` | - | 面板服务监听端口 | `8008` |
| `agent_secret_key` | - | Agent 通信连接密钥 | 在后台管理界面配置 |
| `jwt_timeout` | - | 登录 Token 过期有效时长（小时） | `24` |
| `force_auth` | - | 是否强制要求全局认证 | `true` |

---

## 🖥️ 被控端（Agent）接入指南

在需要被监控的客户端服务器上，执行一键接入命令：

```bash
curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o nezha.sh && chmod +x nezha.sh
./nezha.sh install_agent <面板域名或IP> 8008 <Agent通信密钥>
```

> **提示**：如果面板配置了反向代理，请确保反代服务（如 Nginx/Cloudflare）放行了 gRPC 通信或将 Agent 通信端口直连宿主机的 8008 端口。

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
