#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-/root/workspace/sub2api-hf}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/Wei-Shaw/sub2api.git}"
ORIGIN_REPO="${ORIGIN_REPO:-comtnt-gh/sub2api-hf}"
PUSH_REMOTE="${PUSH_REMOTE:-git@github.com:comtnt-gh/sub2api-hf.git}"
SYNC_BRANCH="${SYNC_BRANCH:-sync/upstream-main}"
BASE_BRANCH="${BASE_BRANCH:-main}"
IMAGE_TAG="${IMAGE_TAG:-sub2api-hf:sync-test}"
GHCR_WORKFLOW="${GHCR_WORKFLOW:-GHCR Image}"

log() {
  printf '\033[1;34m==>\033[0m %s\n' "$*"
}

die() {
  printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
用法:
  sync_sub2api_hf_upstream.sh prepare
  sync_sub2api_hf_upstream.sh verify
  sync_sub2api_hf_upstream.sh push
  sync_sub2api_hf_upstream.sh pr
  sync_sub2api_hf_upstream.sh watch-ghcr [run-id]
  sync_sub2api_hf_upstream.sh status

环境变量可覆盖:
  REPO_DIR, UPSTREAM_URL, ORIGIN_REPO, PUSH_REMOTE, SYNC_BRANCH, BASE_BRANCH, IMAGE_TAG, GHCR_WORKFLOW
USAGE
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

repo_cd() {
  cd "$REPO_DIR" || die "无法进入仓库目录: $REPO_DIR"
  git rev-parse --show-toplevel >/dev/null 2>&1 || die "不是 Git 仓库: $REPO_DIR"
}

ensure_clean_tree() {
  local status
  status="$(git status --short)"
  if [[ -n "$status" ]]; then
    printf '%s\n' "$status" >&2
    die "工作树不干净。请先提交、暂存或清理改动后再继续。"
  fi
}

ensure_upstream() {
  if git remote get-url upstream >/dev/null 2>&1; then
    git remote set-url upstream "$UPSTREAM_URL"
  else
    git remote add upstream "$UPSTREAM_URL"
  fi
}

prepare() {
  need_cmd git
  repo_cd
  ensure_clean_tree

  log "配置 upstream: $UPSTREAM_URL"
  ensure_upstream

  log "拉取 origin 和 upstream"
  git fetch origin --prune
  git fetch upstream --prune

  log "切换并更新 $BASE_BRANCH"
  git checkout "$BASE_BRANCH"
  git pull --ff-only origin "$BASE_BRANCH"
  ensure_clean_tree

  if git show-ref --verify --quiet "refs/heads/$SYNC_BRANCH"; then
    log "切换已有同步分支: $SYNC_BRANCH"
    git checkout "$SYNC_BRANCH"
  else
    log "创建同步分支: $SYNC_BRANCH"
    git checkout -b "$SYNC_BRANCH"
  fi

  log "合并 upstream/main"
  if ! git merge upstream/main; then
    cat >&2 <<'MSG'

合并出现冲突。处理原则:
- 保留上游业务代码、修复和测试。
- 保留本仓库 Docker/GHCR/Hugging Face/Redis/DATABASE_URL/Supabase pooler/migration advisory lock 适配。
- 处理后运行: git add <files> && git commit
- 再执行: sync_sub2api_hf_upstream.sh verify
MSG
    exit 1
  fi

  log "prepare 完成"
  git status --short --branch
}

verify_sensitive_scan() {
  log "执行通用敏感值形态扫描"
  local strict_pattern dsn_pattern hits
  strict_pattern='(hf_[A-Za-z0-9]{20,}|sbp_[A-Za-z0-9]{20,})'
  dsn_pattern='(postgresql://[^[:space:]"]+:[^[:space:]"]+@|postgres://[^[:space:]"]+:[^[:space:]"]+@|DATABASE_URL=.*postgres)'

  if rg -n --hidden \
    --glob '!/.git/**' \
    --glob '!node_modules/**' \
    --glob '!frontend/node_modules/**' \
    --glob '!backend/tmp/**' \
    --glob '!backend/config.yaml' \
    --glob '!backend/config.*.yaml' \
    "$strict_pattern" .; then
    die "发现疑似真实 token。请移除后再继续。"
  fi

  hits="$(rg -n --hidden \
    --glob '!/.git/**' \
    --glob '!/.codex/skills/sync-upstream/scripts/sync_sub2api_hf_upstream.sh' \
    --glob '!node_modules/**' \
    --glob '!frontend/node_modules/**' \
    --glob '!backend/tmp/**' \
    --glob '!backend/config.yaml' \
    --glob '!backend/config.*.yaml' \
    "$dsn_pattern" . || true)"

  hits="$(printf '%s\n' "$hits" | rg -v 'postgresql://user:password@host|postgres://user:pass@host|postgres://user:pass@example.com|postgres://postgres:postgres@db|secret%40value@aws-1-us-west-2.pooler.supabase.com' || true)"

  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" >&2
    cat >&2 <<'MSG'

发现疑似敏感值或 DSN。请确认是否仅为文档/测试示例。
若包含真实 token、真实 DSN、管理员密码或私密凭据，必须移除后再继续。
MSG
    exit 1
  fi
}

verify() {
  need_cmd git
  need_cmd go
  need_cmd rg
  need_cmd docker
  repo_cd

  log "确认部署适配关键文件仍存在"
  test -f Dockerfile || die "缺少 Dockerfile"
  test -f Dockerfile.goreleaser || die "缺少 Dockerfile.goreleaser"
  test -f deploy/docker-entrypoint.sh || die "缺少 deploy/docker-entrypoint.sh"
  test -f .github/workflows/ghcr-image.yml || die "缺少 GHCR workflow"

  log "检查关键适配文本"
  rg -q 'redis-server|redis-cli' Dockerfile Dockerfile.goreleaser deploy/docker-entrypoint.sh || die "未找到 Redis 镜像/entrypoint 适配"
  rg -q 'ghcr.io/comtnt-gh/sub2api-hf' .github/workflows README.md README_CN.md || die "未找到 GHCR 镜像引用"
  rg -q 'DATABASE_URL|REDIS_URL' backend/internal/setup backend/internal/config || die "未找到 DATABASE_URL/REDIS_URL 支持"
  rg -q 'MIGRATIONS_DISABLE_ADVISORY_LOCK' backend/internal/repository || die "未找到 migration advisory lock 开关"

  verify_sensitive_scan

  log "运行 backend setup/config 测试"
  (cd backend && go test ./internal/setup ./internal/config)

  log "运行 repository 定向测试"
  (cd backend && go test ./internal/repository -run 'TestApplyMigrations|TestTableExists|TestBuildRedisOptions|Test.*Migrations')

  log "运行 service 定向测试"
  (cd backend && go test -tags unit ./internal/service -run 'TestAuthServiceRecordSuccessfulLogin|TestAuthServiceLogin_DoesNotApplyEmailFirstBindDefaults|Test.*Bedrock|Test.*ContentModeration|TestRegistrationEmailPolicy|TestAccountTestService')

  log "检查 entrypoint shell 语法"
  sh -n deploy/docker-entrypoint.sh

  log "检查 diff 空白错误"
  git diff --check

  log "构建 Docker 镜像: $IMAGE_TAG"
  docker build -t "$IMAGE_TAG" .

  log "verify 完成"
}

push_branch() {
  need_cmd git
  repo_cd
  local current
  current="$(git branch --show-current)"
  [[ "$current" == "$SYNC_BRANCH" ]] || die "当前分支是 $current，请先切到 $SYNC_BRANCH"
  log "推送 $SYNC_BRANCH 到 $PUSH_REMOTE"
  git push "$PUSH_REMOTE" "$SYNC_BRANCH"
}

create_pr() {
  need_cmd gh
  repo_cd
  local current
  current="$(git branch --show-current)"
  [[ "$current" == "$SYNC_BRANCH" ]] || die "当前分支是 $current，请先切到 $SYNC_BRANCH"

  log "创建 PR"
  gh pr create \
    --repo "$ORIGIN_REPO" \
    --base "$BASE_BRANCH" \
    --head "$SYNC_BRANCH" \
    --title "Sync upstream main" \
    --body "同步 upstream/main，并保留 Hugging Face Space / GHCR 部署适配。

验证建议已通过：
- go test ./internal/setup ./internal/config
- go test ./internal/repository -run 'TestApplyMigrations|TestTableExists|TestBuildRedisOptions|Test.*Migrations'
- go test -tags unit ./internal/service -run 'TestAuthServiceRecordSuccessfulLogin|TestAuthServiceLogin_DoesNotApplyEmailFirstBindDefaults|Test.*Bedrock|Test.*ContentModeration|TestRegistrationEmailPolicy|TestAccountTestService'
- sh -n deploy/docker-entrypoint.sh
- git diff --check
- docker build -t ${IMAGE_TAG} .

同步策略：merge upstream/main，不使用 rebase/force push。"
}

watch_ghcr() {
  need_cmd gh
  repo_cd
  local run_id="${1:-}"
  if [[ -z "$run_id" ]]; then
    log "查找最新 $GHCR_WORKFLOW workflow run"
    run_id="$(gh run list --repo "$ORIGIN_REPO" --workflow "$GHCR_WORKFLOW" --limit 1 --json databaseId --jq '.[0].databaseId')"
  fi
  [[ -n "$run_id" && "$run_id" != "null" ]] || die "没有找到 GHCR workflow run"
  log "观察 GHCR workflow run: $run_id"
  gh run watch "$run_id" --repo "$ORIGIN_REPO" --interval 15 --exit-status
}

status_info() {
  need_cmd git
  repo_cd
  git remote -v
  git status --short --branch
  git log --oneline --decorate -8
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    prepare) prepare ;;
    verify) verify ;;
    push) push_branch ;;
    pr) create_pr ;;
    watch-ghcr) shift; watch_ghcr "${1:-}" ;;
    status) status_info ;;
    -h|--help|help|"") usage ;;
    *) usage; die "未知子命令: $cmd" ;;
  esac
}

main "$@"
