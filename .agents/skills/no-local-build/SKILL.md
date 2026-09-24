---
name: no-local-build
description: Enforces cloud-only CI/CD container image builds and strictly prohibits local Docker image builds or manual local binary compilation for releases.
---

# 云端自动化构建规范 (No Local Build Policy)

本 Skill 规范了 Nezha Panel 及相关组件的镜像构建与发布准则，严禁在本地进行容器镜像构建或跨架构编译。

## 1. 核心铁律 (Strict Policy)

- **严禁本地构建镜像**：禁止在本地执行 `docker build`、`docker buildx build` 或向 GHCR 等镜像仓库直接推送镜像。
- **严禁本地交叉编译发布包**：禁止在本地手动跨架构编译（如使用交叉编译器针对 AMD64/ARM64 编译 Go/CGO 二进制）替代官方 CI。
- **完全依赖 GitHub Actions**：所有生产容器镜像及多架构 Manifest List 必须 100% 由 GitHub Actions 云端工作流自动构建与发布。

---

## 2. 规范背景与依据 (Rationale)

1. **运行时兼容性与稳定性**：
   - 哪吒监控面板底层数据库（SQLite3）强依赖 `CGO_ENABLED=1`。
   - 本地主机（如 ARM64）与目标生产主机（如 AMD64）架构不同，本地模拟或交叉编译极易出现 C 依赖库缺失、静态链接不全或 QEMU 模拟陷阱，导致线上容器秒退报错并引发 `502 Bad Gateway`。
2. **唯一可信构建源 (Single Source of Truth)**：
   - 云端 GitHub Actions 具备标准、干净且可追溯的 Ubuntu Runner 环境。
   - 保证发布的每一个镜像版本都严格对应 Git Commit SHA，避免本地未受版本控制的文件或缓存污染生产镜像。
3. **流程一致性**：
   - 杜绝因个人开发机环境差异导致的“在我机器上是好的，部署上去就坏了”的偶发故障。

---

## 3. 标准操作流程 (Standard Workflow)

当代码、模板、静态资源或 Docker 配置发生变动时，必须严格遵循以下步骤：

1. **提交代码并推送**：
   ```bash
   git add <modified-files>
   git commit -m "feat/fix: <description>"
   git push origin master
   ```
2. **按需手动触发云端构建**：
   镜像构建由 GitHub Actions 手动触发，推送代码不会自动触发多架构构建。准备发布新版本时执行：
   ```bash
   gh workflow run build-dashboard-app-image.yml
   ```
3. **监控云端构建进度**：
   使用 GitHub CLI 工具跟踪云端 Workflow 运行状态，不得中途打断或本地顶替：
   ```bash
   gh run list --limit 3
   gh run view <RUN_ID>
   ```
4. **等待云端完成交付**：
   - 云端多架构（`linux/amd64,linux/arm64`）构建通常耗时约 25~30 分钟。
   - 必须等待 GitHub Actions 状态变更为 `completed / success` 且镜像已推送至 GHCR。
5. **验证与部署**：
   在服务器上执行拉取与启动：
   ```bash
   docker compose pull && docker compose up -d
   ```
