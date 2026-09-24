---
trigger: always_on
description: Strictly prohibits local Docker image builds; all container images must be built and published solely via GitHub Actions CI/CD.
---

# No Local Docker Build Rule

## Strict Prohibition
- **DO NOT** execute local `docker build` or `docker buildx build` to build or push container images to GHCR or any remote registry.
- **DO NOT** perform manual local cross-compilation of Go/CGO binaries to replace CI release artifacts.

## Mandatory Procedure
1. All container images and multi-architecture manifests must be produced exclusively by GitHub Actions CI/CD (`.github/workflows/build-dashboard-app-image.yml`).
2. When changes are made, commit and push to `origin/master`.
3. Manually trigger the cloud build when ready: `gh workflow run build-dashboard-app-image.yml`.
4. Wait for the cloud GitHub Actions workflow to finish (`gh run view <RUN_ID>` / `gh run list`).
5. Never perform local manual build/push interventions to bypass CI wait times.
