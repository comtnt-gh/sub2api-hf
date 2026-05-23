---
name: sync-upstream
description: "Use when Codex needs to sync the sub2api-hf project with upstream/main from Wei-Shaw/sub2api, merge upstream updates without rebase or force push, preserve GHCR/Hugging Face Space deployment adaptations, embedded Redis, external PostgreSQL DATABASE_URL support, Supabase pooler compatibility, and validate/publish the updated ghcr.io image."
---

# Sync Upstream

用于把 `/root/workspace/sub2api-hf` 同步到上游 `https://github.com/Wei-Shaw/sub2api.git`，并保留本仓库面向 Hugging Face Space 和 GHCR 的部署改造。

## 固定策略

- 使用 `merge` 同步 `upstream/main`，不要 rebase，不要 force push。
- 默认工作分支为 `sync/upstream-main`，目标分支为 `main`。
- `origin` 固定为 `https://github.com/comtnt-gh/sub2api-hf.git`，推送可使用 `git@github.com:comtnt-gh/sub2api-hf.git`。
- 遇到冲突时，优先接收上游业务代码、修复和测试，同时保留本仓库部署适配。
- 不把真实 Supabase DSN、Hugging Face token、管理员密码或其他敏感值写入文件、PR 描述或日志。

## 标准流程

可以直接运行辅助脚本，也可以按同样顺序手动执行：

```bash
/root/workspace/sub2api-hf/.codex/skills/sync-upstream/scripts/sync_sub2api_hf_upstream.sh prepare
/root/workspace/sub2api-hf/.codex/skills/sync-upstream/scripts/sync_sub2api_hf_upstream.sh verify
/root/workspace/sub2api-hf/.codex/skills/sync-upstream/scripts/sync_sub2api_hf_upstream.sh push
/root/workspace/sub2api-hf/.codex/skills/sync-upstream/scripts/sync_sub2api_hf_upstream.sh pr
```

PR 创建后等待 GitHub CI 和 Security Scan 全部通过，再用 merge commit 合并。合并到 `main` 后观察 GHCR 发布：

```bash
/root/workspace/sub2api-hf/.codex/skills/sync-upstream/scripts/sync_sub2api_hf_upstream.sh watch-ghcr
```

## 冲突和保留点

重点检查这些部署适配不能丢：

- Docker 镜像内必须包含 `redis-server`、`redis-cli`、`su-exec`、PostgreSQL client 和 `/app/redis`。
- `deploy/docker-entrypoint.sh` 必须继续支持容器内 Redis 启动、等待 Redis 就绪，再启动 Sub2API。
- GHCR workflow 必须继续发布 `ghcr.io/comtnt-gh/sub2api-hf:latest`，并可保留 `sha-<shortsha>` 标签。
- Auto setup 必须继续支持 `DATABASE_URL`、`REDIS_URL`、Supabase pooler、`binary_parameters=yes` 和原 split env 回退。
- migrations 必须继续支持 `MIGRATIONS_DISABLE_ADVISORY_LOCK=true`。
- README/HF front matter 和 Hugging Face Space/GHCR 部署说明不要被上游覆盖掉。

## 验证要求

同步后至少运行脚本的 `verify`。它会执行：

- `go test ./internal/setup ./internal/config`
- repository migrations/Redis options 定向测试
- service 定向单测
- `sh -n deploy/docker-entrypoint.sh`
- `git diff --check`
- 通用敏感值形态扫描
- `docker build -t sub2api-hf:sync-test .`

如果 Docker 构建受网络波动影响失败，可以重试一次；如果仍失败，先定位日志，不要跳过验证。

## 发布检查

- PR body 要说明同步来源、merge 策略和验证结果。
- CI 通过后再合并 PR。
- 合并后确认 `GHCR Image` workflow 成功，`headSha` 是合并后的 `main` commit。
- Hugging Face Space 只引用 GHCR `latest`，源码同步不需要改动 Space 仓库三文件。
