# 哪吒监控定制安全增强版

> 基于 Nezha Monitoring 重构与安全加固的轻量级探针监控面板，内置现代科技风磨砂玻璃主题、全前置 WAF 防探测加固及 8 位随机路径隐匿。

## 🌟 核心特性

- 🎨 **现代科技风磨砂玻璃主题**：高质感 UI 资源直接内嵌，预渲染技术杜绝白屏与 FOUC 闪烁。
- 🔒 **全前置 WAF 防探测 (Anti-Probe WAF)**：未通过安全路径探测任何内部接口，服务端一律伪装为原生 Caddy 欢迎页，彻底防指纹泄露。
- 🔑 **8 位随机英文字母隐匿路径**：全站隐匿在随机路径下（如 `/mKovrigH/` 与 `/mKovrigH/dashboard/`），自动下发安全 Cookie。
- 🌐 **去指纹化默认端口 (`2052`)**：移除传统 `8008` 端口，默认 `2052` 端口原生兼容 Cloudflare CDN 免费版回源转发。

## 🚀 一键部署 (推荐)

支持全自动安装 Docker 环境、生成随机安全路径、通过共享 Caddy 自动申请与全自动续期 SSL 证书：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/opengaoling/nezha-panel/master/deploy.sh)
```

支持命令行参数静默部署：

```bash
# 绑定域名并配置自动 HTTPS (推荐)
bash <(curl -fsSL https://raw.githubusercontent.com/opengaoling/nezha-panel/master/deploy.sh) -d monitor.yourdomain.com -e admin@yourdomain.com -y

# 纯 HTTP 端口部署 (默认 2052 端口)
bash <(curl -fsSL https://raw.githubusercontent.com/opengaoling/nezha-panel/master/deploy.sh) -p 2052 -y
```

部署完成后：
- 🌐 前台监控面板：`https://<你的域名>/<8位随机路径>/`
- ⚙️ 管理后台控制台：`https://<你的域名>/<8位随机路径>/dashboard/`
- 👤 默认管理员账号：`admin`，密码：`admin`（首次登录后请立即修改）

## 🛠️ 常用管理命令

部署完成后，在服务器任意位置均可使用全局 `nezha` 命令：

| 命令 | 说明 |
| --- | --- |
| `nezha` | 打开交互式管理控制台 |
| `nezha status` | 查看容器服务运行状态 |
| `nezha restart` | 重启服务 |
| `nezha update` | 平滑拉取最新镜像并更新 |
| `nezha logs` | 实时查看面板后端服务日志 |
| `nezha logs-caddy` | 查看 Caddy 访问与 SSL 证书日志 |
| `nezha info` | 查看当前配置备忘与访问链接 |
| `nezha clean` | 系统维护 (清理缓存/截断日志/完全卸载) |

## 🐳 Docker Compose 手动部署

```bash
mkdir -p /opt/nezha-dashboard && cd /opt/nezha-dashboard
```

创建 `docker-compose.yaml`：

```yaml
version: '3.8'

services:
  nezha-dashboard:
    image: ghcr.io/opengaoling/nezha-panel:latest
    container_name: nezha-dashboard
    restart: always
    ports:
      - "2052:2052"
    environment:
      - TZ=Asia/Shanghai
    volumes:
      - ./data:/dashboard/data
```

启动命令：

```bash
docker compose up -d
```

## 📄 License

本项目基于原项目协议开源。
