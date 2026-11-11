#!/usr/bin/env bash
# 服务机第四步（root，重跑没有副作用）：在服务机的 PostgreSQL 16 上建平台的库和账号，放开 k3s 的 Pod 来连。
#   deploy/aliyun/run.sh ecs --run 'bash /opt/thinktin/deploy/aliyun/machine/04-database.sh'
#
# 建的东西和 docs/deploy-checklist.md 第 3 节一模一样（迁移 0001、0014、0049 和启动时的角色核对要的就是这些）：
#   thinktin_owner                             迁移账号、库 thinktin 的属主（能登录，没有别的权限）
#   thinktin_app / _worker / _llmgw / _relay   服务角色（不能登录；后三个 BYPASSRLS，只有超级用户建得了）
#   thinktin_member / thinktin_project_definer 项目成员读用的两个角色（8.15）。跨用户项目虽然关着，迁移 0049 和控制面
#                                              启动时的角色核对都要它们在、属性对，所以照建
#   thinktin_server_login / _llmgw_login / _relay_login   三个服务的登录账号，只拿对应角色的成员身份
#
# 密码来自 gen-secrets（第一次跑时在机器上生成，存 /opt/thinktin/secrets/gen-secrets.txt，只有 root 读得到），不显示。
# 已经有的角色不重建、不改密码。密码文件和库里的对不上时，最后的登录检查会报出来；确认要以文件为准，再带上
# SYNC_PASSWORDS=1 重跑（把四个登录账号的密码改成文件里的）。
#
# 网络：Postgres 只多监听服务机的内网地址；pg_hba 只放行 k3s 的 Pod 网段和服务机自己（模型网关用服务机的网络，
# 从 172.16.0.168 连过来），只许连 thinktin 这个库、只许这四个账号、scram-sha-256。5432 不在安全组里，机器外面连不到。
set -euo pipefail
SELF=$(readlink -f "${BASH_SOURCE[0]}")
# shellcheck source=deploy/aliyun/machine/common.sh
. "$(dirname "$SELF")/common.sh"
need_root
cd / # 系统用户 postgres 进不了 /root，psql 会抱怨

command -v psql >/dev/null || die "没有 psql：先跑 01-disk-postgres.sh"
# 01-disk-postgres.sh 装出来的就是 16/main（apt 的默认实例）。
PG_CLUSTER=${PG_CLUSTER:-main}
port=$(pg_lsclusters -h 2>/dev/null | awk -v c="$PG_CLUSTER" '$1 == 16 && $2 == c {print $3; exit}')
[ -n "$port" ] || die "没有 PostgreSQL 的实例 16/$PG_CLUSTER（pg_lsclusters 看）：先跑 01-disk-postgres.sh"
[ "$port" = "$DB_PORT" ] || die "PostgreSQL 16/$PG_CLUSTER 的端口是 $port，不是 $DB_PORT（各个服务的 DATABASE_URL 按 $DB_PORT 写）"
unit="postgresql@16-$PG_CLUSTER"
systemctl is-active -q "$unit" || systemctl start "$unit"
pg() { # 以数据库超级用户（系统用户 postgres，本机套接字）执行
  runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -p "$DB_PORT" "$@"
}
wait_for 30 "Postgres 接受连接" pg -d postgres -Atc 'select 1'

gen_secrets_once

# ---------- 库和账号 ----------
echo "=== 库和账号"
before=$(pg -d postgres -Atc "select count(*) from pg_roles where rolname like 'thinktin\\_%'")
sync=false
[ "${SYNC_PASSWORDS:-}" = 1 ] && sync=true
out=$(mktemp /run/thinktin-psql.XXXXXX)
# 密码经标准输入交给 psql（\set），不上命令行；带密码的语句不进服务器日志（出错时默认会把整条语句记下来）。
if ! {
  for login in $DB_LOGINS; do
    printf '\\set pw_%s %s\n' "$login" "'$(db_password "$login")'"
  done
  printf '\\set sync %s\n' "$sync"
  cat <<'SQL'
SET client_min_messages = warning;
SET log_statement = 'none';
SET log_min_error_statement = 'panic';
SET log_min_duration_statement = -1;

-- 迁移账号：表的属主，只给迁移 Job。
SELECT format('CREATE ROLE thinktin_owner LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD %L', :'pw_thinktin_owner')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_owner') \gexec
SELECT 'CREATE DATABASE thinktin OWNER thinktin_owner'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'thinktin') \gexec

-- 服务用的四个角色。迁移里也会建，但建 BYPASSRLS 的角色要超级用户，属主账号建不了：这里先建好，迁移按名字跳过。
SELECT 'CREATE ROLE thinktin_app NOLOGIN NOBYPASSRLS'
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_app') \gexec
SELECT 'CREATE ROLE thinktin_worker NOLOGIN BYPASSRLS'
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_worker') \gexec
SELECT 'CREATE ROLE thinktin_llmgw NOLOGIN BYPASSRLS'
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_llmgw') \gexec
SELECT 'CREATE ROLE thinktin_relay NOLOGIN BYPASSRLS'
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_relay') \gexec

-- 项目成员的只读角色和定义者函数的属主（8.15，迁移 0049 核对这些属性）：都不能登录、不绕过行级安全；定义者不继承、
-- 不是任何角色的成员。迁移账号能 SET ROLE 到定义者（把函数交给它），但不继承它的权限。
SELECT 'CREATE ROLE thinktin_member NOLOGIN NOBYPASSRLS'
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_member') \gexec
SELECT 'CREATE ROLE thinktin_project_definer NOLOGIN NOBYPASSRLS NOINHERIT'
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_project_definer') \gexec
GRANT thinktin_project_definer TO thinktin_owner WITH INHERIT FALSE, SET TRUE;

-- 三个服务的登录账号，只拿对应角色的成员身份。控制面对成员角色只 SET ROLE、不继承（继承了，登录账号自己就拿到成员读策略）。
SELECT format('CREATE ROLE thinktin_server_login LOGIN PASSWORD %L', :'pw_thinktin_server_login')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_server_login') \gexec
GRANT thinktin_app, thinktin_worker TO thinktin_server_login;
GRANT thinktin_member TO thinktin_server_login WITH INHERIT FALSE, SET TRUE;
SELECT format('CREATE ROLE thinktin_llmgw_login LOGIN PASSWORD %L', :'pw_thinktin_llmgw_login')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_llmgw_login') \gexec
GRANT thinktin_llmgw TO thinktin_llmgw_login;
SELECT format('CREATE ROLE thinktin_relay_login LOGIN PASSWORD %L', :'pw_thinktin_relay_login')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_relay_login') \gexec
GRANT thinktin_relay TO thinktin_relay_login;

\if :sync
ALTER ROLE thinktin_owner PASSWORD :'pw_thinktin_owner';
ALTER ROLE thinktin_server_login PASSWORD :'pw_thinktin_server_login';
ALTER ROLE thinktin_llmgw_login PASSWORD :'pw_thinktin_llmgw_login';
ALTER ROLE thinktin_relay_login PASSWORD :'pw_thinktin_relay_login';
\endif
SQL
} | pg -d postgres -f - > "$out" 2>&1; then
  echo "[不通过] 建库、建账号时出错（只显示错误那一行，语句不显示）："
  { grep -E '^(psql:.*)?(ERROR|FATAL)' "$out" || true; } | sed 's/^psql:[^ ]* //' | cut -c1-200 | head -n 5
  rm -f "$out"
  exit 1
fi
rm -f "$out"
after=$(pg -d postgres -Atc "select count(*) from pg_roles where rolname like 'thinktin\\_%'")
echo "[通过] 库 thinktin（属主 $(pg -d postgres -Atc "select pg_get_userbyid(datdba) from pg_database where datname = 'thinktin'")）；thinktin_ 开头的角色 $after 个（这次新建 $((after - before)) 个$([ "$sync" = true ] && echo "，四个登录账号的密码改成了密钥文件里的")）"
pg -d postgres -At -F ' | ' <<'SQL' | sed 's/^/  /'
SELECT r.rolname,
       CASE WHEN r.rolcanlogin THEN 'LOGIN' ELSE 'NOLOGIN' END,
       CASE WHEN r.rolbypassrls THEN 'BYPASSRLS' ELSE '-' END,
       CASE WHEN r.rolinherit THEN '-' ELSE 'NOINHERIT' END,
       coalesce((SELECT string_agg(g.rolname || CASE WHEN m.inherit_option THEN '' ELSE '（只能 SET ROLE）' END, '、' ORDER BY g.rolname)
                   FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid WHERE m.member = r.oid), '-')
  FROM pg_roles r WHERE r.rolname LIKE 'thinktin\_%' ORDER BY r.rolcanlogin DESC, r.rolname;
SQL

# ---------- 监听和 pg_hba ----------
echo "=== 监听和 pg_hba"
conf_dir=$(dirname "$(pg -d postgres -Atc 'show config_file')")
hba=$(pg -d postgres -Atc 'show hba_file')
want_listen="localhost,$NODE_IP"
mkdir -p "$conf_dir/conf.d"
cat > "$conf_dir/conf.d/50-thinktin.conf" <<EOF
# deploy/aliyun/machine/04-database.sh 写的。k3s 的 Pod 经服务机的内网地址连过来；谁能连由 pg_hba.conf 管。
listen_addresses = '$want_listen'
password_encryption = 'scram-sha-256'
EOF
chown postgres:postgres "$conf_dir/conf.d/50-thinktin.conf"
chmod 644 "$conf_dir/conf.d/50-thinktin.conf"

# 监听的地址里有内网 IP：开机时等网卡拿到地址再起（不然那个地址绑不上，只剩 localhost，Pod 都连不到库）。
mkdir -p "/etc/systemd/system/$unit.service.d"
dropin="/etc/systemd/system/$unit.service.d/thinktin.conf"
if [ ! -f "$dropin" ]; then
  cat > "$dropin" <<'EOF'
[Unit]
After=network-online.target
Wants=network-online.target
EOF
  systemctl daemon-reload
fi

logins=${DB_LOGINS// /,}
block="# BEGIN thinktin（deploy/aliyun/machine/04-database.sh 写的，手改会被覆盖）
# k3s 的 Pod（接口、后台、中继、迁移 Job）。
host    $DB_NAME    $logins    $POD_CIDR    scram-sha-256
# 服务机自己的内网地址（模型网关用服务机的网络）。
host    $DB_NAME    $logins    $NODE_IP/32    scram-sha-256
# END thinktin"
current=$(cat "$hba")
rest=$(sed '/^# BEGIN thinktin/,/^# END thinktin/d' "$hba")
new="$rest
$block"
if [ "$current" != "$new" ]; then
  [ -f "$hba.before-thinktin" ] || cp -p "$hba" "$hba.before-thinktin"
  printf '%s\n' "$new" > "$hba"
  echo "[已写] $hba 里 thinktin 的两条"
fi

if [ "$(pg -d postgres -Atc 'show listen_addresses')" != "$want_listen" ]; then
  # 改监听地址要重启（连着的服务会断一下，自己重连）。
  systemctl restart "$unit"
  wait_for 60 "Postgres 重启后接受连接" pg -d postgres -Atc 'select 1'
  [ "$(pg -d postgres -Atc 'show listen_addresses')" = "$want_listen" ] \
    || die "重启以后 listen_addresses 还不是 $want_listen：postgresql.conf 没有 include_dir = 'conf.d'？"
  echo "[已重启] Postgres 现在监听 $want_listen"
else
  pg -d postgres -Atc 'select pg_reload_conf()' >/dev/null
fi
bad=$(pg -d postgres -Atc "select count(*) from pg_hba_file_rules where error is not null")
[ "$bad" = 0 ] || die "$hba 里有 $bad 条规则 Postgres 不认（select line_number, error from pg_hba_file_rules where error is not null）"
have=$(ss -ltnH 2>/dev/null)
grep -qF "$NODE_IP:$DB_PORT " <<< "$have" || die "Postgres 没在 $NODE_IP:$DB_PORT 上监听（ss -ltn 看）"
echo "[通过] 监听 $(pg -d postgres -Atc 'show listen_addresses')；pg_hba 放行 $POD_CIDR 和 $NODE_IP/32 → 库 $DB_NAME"

# ---------- 用每个账号连一遍 ----------
echo "=== 登录检查（经 $NODE_IP:$DB_PORT，和服务连的是同一个地址）"
pgpass=$(mktemp /run/thinktin-pgpass.XXXXXX)
trap 'rm -f "$pgpass"' EXIT
for login in $DB_LOGINS; do
  printf '%s:%s:%s:%s:%s\n' "$NODE_IP" "$DB_PORT" "$DB_NAME" "$login" "$(db_password "$login")" >> "$pgpass"
done
as() { # 账号 SQL：用这个账号经内网地址连上去执行，输出结果（密码从只有 root 能读的 pgpass 文件取）
  PGPASSFILE=$pgpass PGCONNECT_TIMEOUT=5 psql -X -At -w -v ON_ERROR_STOP=1 \
    "host=$NODE_IP port=$DB_PORT dbname=$DB_NAME user=$1 sslmode=disable" -c "$2" 2>&1
}
failed=0
check() { # 账号 说明 SQL（要输出 t）
  local got why
  got=$(as "$1" "$3") || true
  if [ "$got" = t ]; then
    echo "[通过] $1：$2"
  else
    # 报错里说原因的那一行（FATAL / ERROR）；没有就给最后一行。
    why=$(grep -m 1 -E 'FATAL|ERROR|error:' <<< "$got" || tail -n 1 <<< "$got")
    echo "[不通过] $1：$2（${why:0:200}）"
    failed=1
  fi
}
# 迁移 0049 的要求：迁移账号能 SET ROLE 到定义者，但不继承它；库是它的，public 里能建表。
check thinktin_owner "连得上；能 SET ROLE 到 thinktin_project_definer、不继承它；能在 public 里建表" \
  "select pg_has_role(current_user, 'thinktin_project_definer', 'SET') and not pg_has_role(current_user, 'thinktin_project_definer', 'USAGE') and has_schema_privilege('public', 'CREATE')"
# 控制面启动时的核对（store::Db::check_roles）：能 SET ROLE 到业务、后台、项目成员三个角色，不是定义者的成员。
check thinktin_server_login "连得上；能 SET ROLE 到 thinktin_app、thinktin_worker、thinktin_member，不是定义者的成员" \
  "select pg_has_role(session_user, 'thinktin_app', 'SET') and pg_has_role(session_user, 'thinktin_worker', 'SET') and pg_has_role(session_user, 'thinktin_member', 'SET') and not pg_has_role(session_user, 'thinktin_member', 'USAGE') and not pg_has_role(session_user, 'thinktin_project_definer', 'MEMBER')"
check thinktin_llmgw_login "连得上；有 thinktin_llmgw 的权限" "select pg_has_role(session_user, 'thinktin_llmgw', 'USAGE')"
check thinktin_relay_login "连得上；有 thinktin_relay 的权限" "select pg_has_role(session_user, 'thinktin_relay', 'USAGE')"
if [ "$failed" = 1 ]; then
  echo "密码对不上（password authentication failed）多半是角色先建了、密钥文件后来换过：确认以文件为准再 SYNC_PASSWORDS=1 重跑。"
  exit 1
fi
echo "Pod 网段那一条要等有 Pod 连库才验得到：06-deploy.sh 的迁移 Job 是第一个。"
