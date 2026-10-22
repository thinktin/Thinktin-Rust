#!/usr/bin/env bash
# 本地开发和测试用的数据库：启动本机的 PostgreSQL 16 和 Redis，建一个开发用超级用户。
# 测试通过 DATABASE_URL 连接，每个测试建一个新库（见 crates/store 的测试辅助）。
#
# 用法：tools/dev/setup-db.sh，然后 export DATABASE_URL=postgres://thinktin_dev:thinktin_dev@127.0.0.1:5432/postgres
set -euo pipefail
if command -v pg_ctlcluster >/dev/null; then
  pg_ctlcluster 16 main start 2>/dev/null || true
fi
for _ in $(seq 30); do
  runuser -u postgres -- pg_isready -q 2>/dev/null && break
  sleep 0.5
done
runuser -u postgres -- psql -q -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_dev') THEN
    CREATE ROLE thinktin_dev LOGIN SUPERUSER PASSWORD 'thinktin_dev';
  END IF;
END $$;
SQL
if command -v redis-server >/dev/null && ! redis-cli ping >/dev/null 2>&1; then
  redis-server --daemonize yes --save '' --appendonly no >/dev/null
fi
echo "DATABASE_URL=postgres://thinktin_dev:thinktin_dev@127.0.0.1:5432/postgres"
