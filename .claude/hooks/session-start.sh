#!/bin/bash
# 云端会话启动时：起本机的 PostgreSQL 和 Redis（store 层的测试要用），导出 DATABASE_URL，预取 crate。
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR"
url=$(tools/dev/setup-db.sh | sed -n 's/^DATABASE_URL=//p')
if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -n "$url" ]; then
  echo "export DATABASE_URL=$url" >> "$CLAUDE_ENV_FILE"
fi
cargo fetch --quiet
