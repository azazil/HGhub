#!/usr/bin/env bash
# 把源仓库最新版同步到 main，再合并进 myguo。
#
# 用法:
#   pnpm sync:upstream            # 只更新本地 main 和 myguo
#   pnpm sync:upstream -- --push  # 同时推送 origin/main 和 origin/myguo
#
# 分支约定:
#   main   源仓库镜像，跟踪 upstream/main，推送目标 origin
#   myguo  本地开发 + 发版分支

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PUSH=0
for arg in "$@"; do
  case "$arg" in
    --) shift ;;
    --push) PUSH=1 ;;
    -h|--help)
      sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf '[FAIL] 未知参数: %s\n' "$arg" >&2
      exit 1
      ;;
  esac
done

info() { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[OK]   %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "当前目录不是 git 仓库"
git remote get-url upstream >/dev/null 2>&1 || fail "缺少 upstream 远程仓库"
git show-ref --verify --quiet refs/heads/myguo || fail "本地没有 myguo 分支"
git show-ref --verify --quiet refs/heads/main || fail "本地没有 main 分支"

if ! git diff --quiet || ! git diff --cached --quiet; then
  fail "工作区有未提交修改，请先 commit 或 stash 后再同步"
fi

info "拉取 upstream..."
git fetch upstream --tags

info "更新 main（仅 fast-forward）..."
git checkout main
if ! git merge --ff-only upstream/main; then
  fail "main 与 upstream/main 已分叉，无法 fast-forward；请先处理 main 上的本地提交"
fi

if [[ "$PUSH" == "1" ]]; then
  info "推送 main 到 origin..."
  git push origin main
fi

info "合并 main 到 myguo..."
git checkout myguo
if ! git merge --no-edit main; then
  printf '\n[WARN] 合并有冲突。解决冲突后执行：\n' >&2
  printf '  git add -A && git commit\n' >&2
  printf '  git push origin myguo\n\n' >&2
  exit 1
fi

if [[ "$PUSH" == "1" ]]; then
  info "推送 myguo 到 origin..."
  git push origin myguo
fi

ok "同步完成：myguo 已包含 upstream/main 的最新内容"
