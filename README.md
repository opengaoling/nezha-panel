# 🚀 哪吒监控定制安全增强版 (极轻量高可用版)

> 基于 [Nezha Monitoring](https://github.com/nezhahq/nezha) 深度重构与安全加固的轻量级探针监控面板。  
> 采用 **纯 Docker 容器化 Nginx + acme.sh** 自动化 HTTPS 架构，结合 **Go 运行时内核级内存回收优化**，彻底根除 502 Bad Gateway 与内存持续暴涨崩溃隐患。

---

## 🌟 核心特性与重大升级

### 1. 🛡️ 极轻量纯 Docker Nginx + acme.sh 架构 (彻底替代 Caddy)
- **极低常驻内存**：使用 `nginx:alpine` 替代庞大吃内存的 Caddy，Nginx 常驻内存仅 **~8 MiB**（相比 Caddy 降幅达 90%+）。
- **自动化证书管理**：采用官方 `neilpang/acme.sh` 独立容器在后台定时守护，支持 **Let's Encrypt / ZeroSSL ECC 证书** 自动申请、ARI 智能续期检测及自动热重载 (`nginx -s reload`)。
- **纯容器化管理**：零宿主机软件包污染，通过 `docker compose` 一键启停、迁移与平滑更新。
- **Agent 通信加速**：使用 Nginx 原生 `grpc_pass` 承载探针客户端长连接与监控流，避免 Caddy h2c 协议转换开销。

### 2. ⚡ 内存暴涨根治与 OOM / 502 熔断防护
专为 **512M ~ 1GB 内存小规格 VPS** 量身打造的内存优化体系：
- **主动式更低 GC 阈值**：Go 运行时内置 `debug.SetGCPercent(20)`，当堆内存较小变化时即触发垃圾回收，消除驻留内存峰值。
- **定时物理内存退还**：内置每 6 小时定时任务强制执行 `runtime.GC()` 与 `debug.FreeOSMemory()`，将闲置页彻底归还 Linux 操作系统。
- **数据库碎片定时整理**：每周日定时自动执行 SQLite `VACUUM` 与 VictoriaMetrics TSDB 内存刷盘，防止数据膨胀拖垮内存。
- **软硬双层安全熔断**：
  - 容器环境变量设置 `GOMEMLIMIT=512MiB`，配合 Go runtime 软上限防止失控。
  - Compose 资源限制 `deploy.resources.limits.memory: 600m`，避免机器整机死机。
  - 内置 Docker 容器健康检查（Healthcheck），遇异常自动毫秒级拉起，告别长时间 502。

### 3. 🔒 全前置 WAF 防探测 + 8 位随机路径隐匿
- **8 位随机英文字母入口**：全站默认隐匿在随机路径下（例如 `https://yourdomain.com/fEimQQwM/`）。
- **WAF 防扫描阻断**：任何未经随机路径认证、直接探测根路径 `/`、敏感接口 `/api/*` 或后台管理 `/dashboard` 的网络扫描器，服务端坚决返回 `HTTP 404 Not Found`，彻底隐藏哪吒面板特征指纹。
- **动静分离代理**：优化 Nginx 静态资源路由，彻底规避 Nginx location "If is Evil" 导致的脚本加载 404 及空白屏幕（白屏）问题。
- **去指纹化内部通信端口**：彻底移除原版易被网络空间测绘扫描识别的经典 `8008` 特征端口，内部默认采用 `2052`；外部公网访问与 Agent 通信统一由 Nginx 承接标准的 **`443`** TLS 加密流量（亦可自由映射至 Cloudflare 官方支持的 HTTPS 端口如 `2053` / `8443`），支持 Cloudflare Full / Strict 严格端到端加密回源。

### 4. 🎨 现代科技风磨砂玻璃主题
- 内置高质感毛玻璃（Frosted Glass）UI，支持自动跟随系统的深色/浅色模式切换。
- 支持桌面端/移动端自适应布局、自定义服务器分组过滤、实时 WebSocket 心跳监控。

---

## 📊 架构对比：旧版 Caddy vs 新版 Nginx + acme.sh

| 评估指标 | 旧版 (Caddy) | 新版 (Docker Nginx + acme.sh) | 提升效果 |
| :--- | :--- | :--- | :--- |
| **反向代理内存占用** | 100 MiB ~ 250 MiB+ | **~8 MiB** (`nginx:alpine`) | **内存降低 95%+** |
| **SSL 证书守护内存** | 绑定在 Caddy 进程 | **~2 MiB** (`neilpang/acme.sh`) | 极简独立隔离 |
| **小内存机器稳定性** | 高峰期频繁 OOM、报 502 | **常驻平稳在 ~15 MiB**，零 502 崩溃 | **彻底根除 502** |
| **证书签发方式** | Caddy 内置自动申请 | acme.sh Webroot + ECC 高级证书 | 兼容性更广，续期透明 |
| **宿主机环境要求** | 需安装复杂环境或独立 Caddy | **仅需 Docker**，零外部污染 | 开箱即用 |

---

## 🚀 极速一键部署 (推荐)

在服务器终端执行一键部署脚本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/opengaoling/nezha-panel/master/deploy.sh)
```

> **提示**：如果之前安装过旧版本或 Caddy 版本，直接重新运行上述脚本并选择更新，脚本将自动完成数据迁移并平滑切换至 Nginx + acme.sh 架构！

### 🤖 命令行参数静默安装 (自动化脚本支持)

```bash
# 绑定域名并配置自动 HTTPS (推荐生产环境使用)
bash <(curl -fsSL https://raw.githubusercontent.com/opengaoling/nezha-panel/master/deploy.sh) \
  -d monitor.yourdomain.com \
  -e admin@yourdomain.com \
  -y

# 自定义安装目录与通信端口
bash <(curl -fsSL https://raw.githubusercontent.com/opengaoling/nezha-panel/master/deploy.sh) \
  -d monitor.yourdomain.com \
  -e admin@yourdomain.com \
  -p 2052 \
  --dir /opt/nezha-dashboard \
  -y
```

### 访问地址与初始凭据
- 🌐 **前台监控面板**：`https://<你的域名>/<8位随机安全路径>/`
- ⚙️ **管理后台系统**：`https://<你的域名>/<8位随机安全路径>/dashboard/`
- 👤 **默认管理员账号**：`admin`
- 🔑 **默认管理员密码**：`admin` *(首次登录后请务必在后台立即修改！)*

---

## 🛠️ 常用管理命令 (`nezha`)

安装完成后，在系统任意目录均可直接使用快捷命令 `nezha`：

```bash
# 打开交互式可视化管理菜单
nezha

# 常用快捷子命令
nezha status       # 查看所有容器 (dashboard / nginx / acme) 运行状态与内存
nezha restart      # 重启所有容器服务
nezha update       # 平滑升级至最新镜像版本并应用配置
nezha cert         # 查看 SSL 证书有效期与签发详情
nezha logs         # 实时跟踪面板 Go 服务日志
nezha logs-nginx   # 查看 Nginx 访问与反向代理日志
nezha logs-acme    # 查看 acme.sh 证书续期守护日志
nezha info         # 查看当前配置备忘与完整访问链接
nezha clean        # 进入系统维护与清理菜单 (清理 Docker 缓存/截断大日志)
nezha uninstall    # 彻底卸载面板服务与清理数据
```

---

## 🐳 Docker Compose 手动部署方案

如果你偏好完全手动管理 Docker Compose，可参考以下标准配置：

1. 创建并进入安装目录：
```bash
mkdir -p /opt/nezha-dashboard/ssl /opt/nezha-dashboard/acme-challenge /opt/nezha-dashboard/data
cd /opt/nezha-dashboard
```

2. 编写 `docker-compose.yaml`：
```yaml
services:
  nezha-dashboard:
    image: ghcr.io/opengaoling/nezha-panel:latest
    container_name: nezha-dashboard
    restart: always
    environment:
      - TZ=Asia/Shanghai
      - GOMEMLIMIT=512MiB
    deploy:
      resources:
        limits:
          memory: 600m
    volumes:
      - ./data:/dashboard/data
    networks:
      - nezha_net
    healthcheck:
      test: ["CMD", "/dashboard/app", "-v"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s

  nezha-nginx:
    image: nginx:alpine
    container_name: nezha-nginx
    restart: always
    ports:
      - "80:80"
      - "443:443"
    deploy:
      resources:
        limits:
          memory: 64m
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./ssl:/etc/nginx/ssl:ro
      - ./acme-challenge:/var/www/html:ro
    depends_on:
      nezha-dashboard:
        condition: service_healthy
    networks:
      - nezha_net

  nezha-acme:
    image: neilpang/acme.sh:latest
    container_name: nezha-acme
    restart: always
    environment:
      - TZ=Asia/Shanghai
    volumes:
      - ./ssl:/ssl
      - ./acme-challenge:/var/www/html
      - acme_data:/acme.sh
      - /var/run/docker.sock:/var/run/docker.sock:ro
    entrypoint: >
      sh -c "which docker >/dev/null 2>&1 || (apk update && apk add --no-cache docker-cli);
             exec daemon"
    networks:
      - nezha_net

volumes:
  acme_data:
    name: nezha_acme_data

networks:
  nezha_net:
    name: nezha_internal_net
    driver: bridge
```

---

## ❓ 常见问题排查 (FAQ)

### Q1: 部署完成后，通过域名直接打开显示 404 Not Found？
> **解答**：这是本版本的核心防探测安全机制。面板全站隐匿在生成的 8 位随机英文路径下（例如 `https://yourdomain.com/fEimQQwM/`）。未带安全前缀的直接访问将被 Nginx 与 Go WAF 一律返回 404 隐藏特征。请在终端运行 `nezha info` 查看完整的专属访问入口。

### Q2: 为什么从 Caddy 切换为 Nginx + acme.sh？
> **解答**：Caddy 基于 Go 编写，虽然证书申请简便，但在反向代理持续大量的 Agent gRPC 长连接与 WebSocket 流时，堆内存常驻容易飙升至 100M~250M+。在 512M 或 1G VPS 上极易诱发 Linux OOM Killer 杀掉面板导致 502。更换为 C 语言编写的高性能 `nginx:alpine` 后，常驻内存骤降至 **~8MB**，配合 acme.sh 独立容器，稳定性大幅提升。

### Q3: SSL 证书是如何自动续期的？
> **解答**：`nezha-acme` 容器作为后台常驻守护进程，每天定时运行检查。证书到期前 30 天（或遵循 Let's Encrypt ARI 续期窗口）将自动通过 HTTP-01 Webroot 模式申请新证书，并自动向 Docker API 发送指令优雅重载 Nginx，整个过程对网站访问零中断。可随时运行 `nezha cert` 查看当前证书状态。

---

## 📄 开源许可 (License)

本项目基于原项目 [Nezha Monitoring](https://github.com/nezhahq/nezha) 协议开源。
