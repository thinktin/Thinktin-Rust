#!/usr/bin/env bash
# 云端会话自动保存。
#
# 每次工具调用后，把工作区的完整状态（包括没提交、没跟踪的文件）做成快照，
# 强制推送到 GitHub 上的 autosave/<当前分支>。当前分支的提交历史、暂存区都不动。
# 会话因为限额等原因中断、容器被回收后，下一个 agent 用
#   .claude/hooks/autosave.sh --restore <分支>
# 把工作区恢复到最后一次快照。
#
# 只在云端会话（CLAUDE_CODE_REMOTE=true）里生效，设 CLAUDE_AUTOSAVE=0 关闭。
# 日志在 .git/autosave.log。
set -u

die() { echo "autosave: $*" >&2; exit 1; }

restore() {
  local branch=$1 snap base
  [ -z "$(git status --porcelain)" ] || die "工作区有未提交的改动，先处理掉再恢复"
  git fetch --quiet origin "refs/heads/autosave/$branch" || die "GitHub 上没有 autosave/$branch"
  snap=$(git rev-parse FETCH_HEAD)
  # 快照提交的消息以 "autosave:" 开头，它的父提交才是分支本身；
  # 否则快照时工作区是干净的，快照就是分支上的提交。
  if git log -1 --format=%s "$snap" | grep -q '^autosave:'; then
    base=$(git rev-parse "$snap^")
  else
    base=$snap
  fi
  if git fetch --quiet origin "refs/heads/$branch" 2>/dev/null &&
    ! git merge-base --is-ancestor FETCH_HEAD "$base"; then
    die "origin/$branch 上有快照之后的新提交，需要手动合并（快照：$snap）"
  fi
  git checkout --quiet -B "$branch" "$base" || die "切换到 $branch 失败"
  if [ "$snap" = "$base" ]; then
    echo "已恢复到 autosave/$branch：分支 $branch 在 $(git rev-parse --short "$base")，快照时没有未提交的改动。"
  else
    git restore --source="$snap" --worktree -- . || die "恢复工作区失败"
    echo "已恢复到 autosave/$branch：分支 $branch 在 $(git rev-parse --short "$base")，快照里没提交的改动已放回工作区。"
  fi
}

push() {
  local branch=$1 delay commit
  exec 8>"$git_dir/autosave-push.lock"
  flock -w 120 8 || exit 0
  for delay in 0 2 4 8 16; do
    sleep "$delay"
    commit=$(git rev-parse "refs/autosave/$branch") || exit 0
    if git push --quiet --force origin "$commit:refs/heads/autosave/$branch"; then
      echo "$branch $commit" >"$git_dir/autosave.pushed"
      exit 0
    fi
  done
  echo "$(date '+%F %T') 推送 autosave/$branch 失败" >&2
}

snapshot() {
  local branch head tree prev commit session f
  branch=$(git symbolic-ref --quiet --short HEAD) || exit 0  # 分离头指针时跳过
  head=$(git rev-parse --verify --quiet HEAD) || exit 0       # 还没有任何提交时跳过
  for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
    [ -e "$git_dir/$f" ] && exit 0
  done

  exec 9>"$git_dir/autosave.lock"
  flock -w 30 9 || exit 0

  tmp_index=$(mktemp "$git_dir/autosave-index.XXXXXX")
  trap 'rm -f "$tmp_index"' EXIT
  cp "$git_dir/index" "$tmp_index" 2>/dev/null
  GIT_INDEX_FILE=$tmp_index git add -A || exit 0
  tree=$(GIT_INDEX_FILE=$tmp_index git write-tree) || exit 0

  if [ "$tree" = "$(git rev-parse "$head^{tree}")" ]; then
    commit=$head
  else
    prev=$(git rev-parse --verify --quiet "refs/autosave/$branch")
    if [ -n "$prev" ] && [ "$(git rev-parse "$prev^{tree}")" = "$tree" ] &&
      [ "$(git rev-parse --verify --quiet "$prev^")" = "$head" ]; then
      commit=$prev
    else
      session=${CLAUDE_CODE_REMOTE_SESSION_ID:+"Claude-Session: https://claude.ai/code/session_${CLAUDE_CODE_REMOTE_SESSION_ID#cse_}"}
      commit=$(printf 'autosave: %s 的工作区快照\n\n%s\n' "$branch" "$session" |
        git commit-tree "$tree" -p "$head") || exit 0
    fi
  fi

  [ "$(cat "$git_dir/autosave.pushed" 2>/dev/null)" = "$branch $commit" ] && exit 0
  git update-ref "refs/autosave/$branch" "$commit"
  nohup "$0" --push "$branch" </dev/null >>"$log" 2>&1 9>&- &
}

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
git_dir=$(git rev-parse --absolute-git-dir 2>/dev/null) || exit 0
log="$git_dir/autosave.log"

case "${1:-}" in
  --restore) restore "${2:?用法：autosave.sh --restore <分支>}"; exit ;;
esac

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
[ "${CLAUDE_AUTOSAVE:-1}" != "0" ] || exit 0

case "${1:-}" in
  --push) push "$2" ;;
  *) snapshot 2>>"$log" ;;
esac
