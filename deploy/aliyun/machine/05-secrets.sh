#!/usr/bin/env bash
# 服务机第五步（root，重跑没有副作用）：把平台的密钥建成 k3s 里的 Secret，连同模型网关、中继要的两个公钥（ConfigMap）。
# deploy/k8s 也要先传上去（按 server.toml 里配没配审核账号决定带不带固定码）：
#   deploy/aliyun/run.sh ecs --push deploy/k8s /opt/thinktin/deploy/k8s
#   deploy/aliyun/run.sh ecs --run 'bash /opt/thinktin/deploy/aliyun/machine/05-secrets.sh'
#
# 密钥都在服务机的 /opt/thinktin/secrets（目录 0700、文件 0600，只有 root 读得到）。已经有的不重新生成：
#   gen-secrets.txt  thinktin-server gen-secrets 的输出：两个签名种子、验证码密钥、四个数据库密码、两个公钥（04 或这里生成）
#   kms.key          本地主密钥 THINKTIN_KMS_KEY（这里生成）。丢了，所有用户存的 key 和产出物都解不开：要备份，见 README
#   review.code      审核账号的固定验证码 THINKTIN_REVIEW_CODE（这里生成；想自己定就先放一个 6 位数字的文件）
#   oss.env          OSS 的访问密钥，要事先放好（云端会话建好只管这个桶的子账号以后传上来）。两行：
#                      THINKTIN_S3_ACCESS_KEY_ID=…
#                      THINKTIN_S3_SECRET_ACCESS_KEY=…
#   sms.env          可选：短信的 THINKTIN_ALIYUN_SMS_ACCESS_KEY_ID、THINKTIN_ALIYUN_SMS_ACCESS_KEY_SECRET。没有就填占位值
#                    （接口副本没有这两个键起不来；占位值发不出短信，只有审核账号能登录）
#   search.env       可选：平台搜索的 THINKTIN_PARALLEL_SEARCH_KEY、THINKTIN_DEEPSEEK_SEARCH_KEY、THINKTIN_IQS_API_KEY
# sandbox-manager 的 Key 从 /opt/thinktin/target/aliyun-acs/sandbox.json 读（装组件时生成、传上来的）。
#
# 建出来的（命名空间 thinktin；键就是环境变量名，docs/release.md 第 5 节）：
#   Secret thinktin-api      DATABASE_URL（控制面账号）、THINKTIN_ACCESS_TOKEN_SEED、THINKTIN_CODE_PEPPER、THINKTIN_KMS_KEY、
#                            OSS 的两个、短信的两个、配了 review_phone 时的 THINKTIN_REVIEW_CODE
#   Secret thinktin-worker   DATABASE_URL（控制面账号）、THINKTIN_SANDBOX_TOKEN_SEED、THINKTIN_KMS_KEY、OSS 的两个、
#                            THINKTIN_ACS_API_KEY、有的话搜索的 key
#   Secret thinktin-llm-gw   DATABASE_URL（模型网关账号）、THINKTIN_KMS_KEY
#   Secret thinktin-relay    DATABASE_URL（中继账号）
#   Secret thinktin-migrate  DATABASE_URL（属主账号，只有迁移 Job 用）
#   ConfigMap thinktin-llm-gw  THINKTIN_SANDBOX_TOKEN_KEY（沙箱令牌的公钥）
#   ConfigMap thinktin-relay   THINKTIN_ACCESS_TOKEN_KEYS（访问令牌的公钥）
# 值不显示、不上命令行：Secret 从内存盘上只有 root 能读的临时文件建（kubectl --from-env-file），建完就删。
# Secret 变了以后要重跑 06-deploy.sh，Pod 才会带着新值重启。
set -euo pipefail
SELF=$(readlink -f "${BASH_SOURCE[0]}")
# shellcheck source=deploy/aliyun/machine/common.sh
. "$(dirname "$SELF")/common.sh"

KMS_FILE=$SECRETS/kms.key
REVIEW_FILE=$SECRETS/review.code
OSS_FILE=$SECRETS/oss.env
SMS_FILE=$SECRETS/sms.env
SEARCH_FILE=$SECRETS/search.env
SERVER_TOML=$OVERLAY/server.toml
# 接口副本没有短信的 Key 起不来（配置里有 [sms.aliyun]）。这个值不是密钥：阿里云不认它，普通手机号发码会失败。
SMS_PLACEHOLDER=not-configured

# 本地主密钥：32 字节，十六进制。只生成一次。
ensure_kms_key() {
  if [ ! -s "$KMS_FILE" ]; then
    (umask 077 && head -c 32 /dev/urandom | od -An -v -tx1 | tr -d ' \n' > "$KMS_FILE.new" && echo >> "$KMS_FILE.new")
    mv "$KMS_FILE.new" "$KMS_FILE"
    echo "[已生成] 本地主密钥 $KMS_FILE（不显示）。现在就备份：丢了它，用户存的 key 和产出物都解不开"
  fi
  chmod 600 "$KMS_FILE"
  [[ "$(cat "$KMS_FILE")" =~ ^[0-9a-f]{64}$ ]] || die "$KMS_FILE 不是 64 位十六进制（不显示）。不要重新生成，先弄清楚怎么回事"
}

# 固定码的规矩和服务端一样（auth::service::check_review_code）：6 位数字，不能是同一个数字或顺着、倒着连号。
review_code_py() {
  python3 - "$@" <<'PY'
import secrets
import sys


def easy(code):
    steps = [int(b) - int(a) for a, b in zip(code, code[1:])]
    return all(s == steps[0] for s in steps) and abs(steps[0]) <= 1


if sys.argv[1] == "new":
    while True:
        code = "%06d" % secrets.randbelow(10**6)
        if not easy(code):
            break
    print(code)
else:
    code = open(sys.argv[2]).read().strip()
    sys.exit(0 if len(code) == 6 and code.isascii() and code.isdigit() and not easy(code) else 1)
PY
}

ensure_review_code() {
  if [ ! -s "$REVIEW_FILE" ]; then
    (umask 077 && review_code_py new > "$REVIEW_FILE.new")
    mv "$REVIEW_FILE.new" "$REVIEW_FILE"
    echo "[已生成] 审核账号的固定码 $REVIEW_FILE（不显示；要用它登录的人自己在阿里云控制台上看，见 README）"
  fi
  chmod 600 "$REVIEW_FILE"
  review_code_py check "$REVIEW_FILE" || die "$REVIEW_FILE 要是 6 位数字，不能是同一个数字或连号（不显示）"
}

# 一个“键=值”文件里要的键都在、值像样（没有空白和引号）、没有不认识的键。check_env_file 文件 必须有的键… [-- 可以有的键…]
check_env_file() {
  local file=$1 key value required=1 allowed=" "
  shift
  chmod 600 "$file"
  for key in "$@"; do
    if [ "$key" = -- ]; then
      required=0
      continue
    fi
    allowed="$allowed$key "
    value=$(env_file_value "$file" "$key")
    if [ -z "$value" ]; then
      [ "$required" = 1 ] && die "$file 里没有 $key=…"
      continue
    fi
    [[ "$value" =~ ^[^[:space:]\"\']+$ ]] || die "$file 里 $key 的值带了空白或引号（不显示）：一行一个 键=值，不加引号"
  done
  while IFS= read -r key; do
    [[ "$allowed" == *" $key "* ]] || die "$file 里有不认识的键 $key"
  done < <(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*$/\1/p' "$file")
}

# server.toml 里配没配审核账号：配了，Secret thinktin-api 才带固定码（只配一个接口副本起不来）。
review_configured() {
  grep -q '^[[:space:]]*review_phone[[:space:]]*=' "$SERVER_TOML"
}

toml_string() { # server.toml 里 键 = "值" 的值（第一处）
  sed -n "/^[[:space:]]*$1[[:space:]]*=/{s/^[^\"]*\"\\([^\"]*\\)\".*\$/\\1/p;q}" "$SERVER_TOML"
}

database_url() { # 登录账号
  printf 'postgres://%s:%s@%s:%s/%s?sslmode=disable' "$1" "$(db_password "$1")" "$NODE_IP" "$DB_PORT" "$DB_NAME"
}

# 每个 Secret、ConfigMap 写成一个“键=值”文件，放进目录 $1（调用的人保证它只有 root 能读）。
write_env_files() {
  local dir=$1 key value acs
  acs=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["api_key"])' "$ACS_STATE") \
    || die "读不出 $ACS_STATE 里的 api_key（sandbox-manager 的 Key）"
  [[ "$acs" =~ ^[^[:space:]\"\']+$ ]] || die "$ACS_STATE 里的 api_key 不像一个 Key（不显示）"
  {
    printf 'DATABASE_URL=%s\n' "$(database_url thinktin_server_login)"
    printf 'THINKTIN_ACCESS_TOKEN_SEED=%s\n' "$(gen_value THINKTIN_ACCESS_TOKEN_SEED)"
    printf 'THINKTIN_CODE_PEPPER=%s\n' "$(gen_value THINKTIN_CODE_PEPPER)"
    printf 'THINKTIN_KMS_KEY=%s\n' "$(cat "$KMS_FILE")"
    for key in THINKTIN_S3_ACCESS_KEY_ID THINKTIN_S3_SECRET_ACCESS_KEY; do
      printf '%s=%s\n' "$key" "$(env_file_value "$OSS_FILE" "$key")"
    done
    for key in THINKTIN_ALIYUN_SMS_ACCESS_KEY_ID THINKTIN_ALIYUN_SMS_ACCESS_KEY_SECRET; do
      value=""
      [ -f "$SMS_FILE" ] && value=$(env_file_value "$SMS_FILE" "$key")
      printf '%s=%s\n' "$key" "${value:-$SMS_PLACEHOLDER}"
    done
    if review_configured; then
      printf 'THINKTIN_REVIEW_CODE=%s\n' "$(tr -d '[:space:]' < "$REVIEW_FILE")"
    fi
  } > "$dir/thinktin-api.env"
  {
    printf 'DATABASE_URL=%s\n' "$(database_url thinktin_server_login)"
    printf 'THINKTIN_SANDBOX_TOKEN_SEED=%s\n' "$(gen_value THINKTIN_SANDBOX_TOKEN_SEED)"
    printf 'THINKTIN_KMS_KEY=%s\n' "$(cat "$KMS_FILE")"
    for key in THINKTIN_S3_ACCESS_KEY_ID THINKTIN_S3_SECRET_ACCESS_KEY; do
      printf '%s=%s\n' "$key" "$(env_file_value "$OSS_FILE" "$key")"
    done
    printf 'THINKTIN_ACS_API_KEY=%s\n' "$acs"
    if [ -f "$SEARCH_FILE" ]; then
      for key in THINKTIN_PARALLEL_SEARCH_KEY THINKTIN_DEEPSEEK_SEARCH_KEY THINKTIN_IQS_API_KEY; do
        value=$(env_file_value "$SEARCH_FILE" "$key")
        [ -n "$value" ] && printf '%s=%s\n' "$key" "$value"
      done
    fi
    true
  } > "$dir/thinktin-worker.env"
  {
    printf 'DATABASE_URL=%s\n' "$(database_url thinktin_llmgw_login)"
    printf 'THINKTIN_KMS_KEY=%s\n' "$(cat "$KMS_FILE")"
  } > "$dir/thinktin-llm-gw.env"
  printf 'DATABASE_URL=%s\n' "$(database_url thinktin_relay_login)" > "$dir/thinktin-relay.env"
  printf 'DATABASE_URL=%s\n' "$(database_url thinktin_owner)" > "$dir/thinktin-migrate.env"
  # 公钥（不是秘密）。
  printf 'THINKTIN_SANDBOX_TOKEN_KEY=%s\n' "$(public_key llm-gw)" > "$dir/public-llm-gw.env"
  printf 'THINKTIN_ACCESS_TOKEN_KEYS=%s\n' "$(public_key relay)" > "$dir/public-relay.env"
}

# 建或更新一个 Secret / ConfigMap（内容经管道给 kubectl apply，不上命令行），说一句结果和它有哪些键。
apply_from_env_file() { # secret|configmap 名字 文件
  local kind=$1 name=$2 file=$3 result
  if [ "$kind" = secret ]; then
    result=$(k -n "$NAMESPACE" create secret generic "$name" --from-env-file="$file" --dry-run=client -o yaml \
      | k -n "$NAMESPACE" apply -f - 2>&1) || { echo "[不通过] $kind/$name：${result:0:200}"; return 1; }
  else
    result=$(k -n "$NAMESPACE" create configmap "$name" --from-env-file="$file" --dry-run=client -o yaml \
      | k -n "$NAMESPACE" apply -f - 2>&1) || { echo "[不通过] $kind/$name：${result:0:200}"; return 1; }
  fi
  echo "[${result##* }] $kind/$name：$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*$/\1/p' "$file" | tr '\n' ' ')"
}

main() {
  need_root
  # 这个脚本建的文件（密钥、临时的“键=值”文件）都只有 root 能读。
  umask 077
  k3s_ready || die "k3s 没起来：先跑 03-k3s-caddy.sh（tail -40 $ROOT/k3s-caddy.log 看它跑完没有）"
  [ -f "$SERVER_TOML" ] || die "没有 $SERVER_TOML：先把 deploy/k8s 传上来（run.sh ecs --push deploy/k8s $ROOT/deploy/k8s）"

  gen_secrets_once
  ensure_kms_key
  # kid 要和配置对得上：模型网关、中继按 kid 找公钥。
  local kid
  kid=$(public_key relay) && [ "${kid%%=*}" = "$(toml_string access_token_kid)" ] \
    || die "访问令牌公钥的 kid 和 server.toml 的 api.access_token_kid 对不上"
  kid=$(public_key llm-gw) && [ "${kid%%=*}" = "$(toml_string token_kid)" ] \
    || die "沙箱令牌公钥的 kid 和 server.toml 的 sandbox.token_kid 对不上"

  [ -f "$OSS_FILE" ] || die "没有 $OSS_FILE：OSS 的访问密钥要事先放好（只有 root 能读，两行：THINKTIN_S3_ACCESS_KEY_ID=…、THINKTIN_S3_SECRET_ACCESS_KEY=…）"
  check_env_file "$OSS_FILE" THINKTIN_S3_ACCESS_KEY_ID THINKTIN_S3_SECRET_ACCESS_KEY
  local sms="占位值（发不出短信）" search="没配（agent 没有 web_search）" review="没配 review_phone，不带固定码"
  if [ -f "$SMS_FILE" ]; then
    check_env_file "$SMS_FILE" THINKTIN_ALIYUN_SMS_ACCESS_KEY_ID THINKTIN_ALIYUN_SMS_ACCESS_KEY_SECRET
    sms="用 $SMS_FILE 里的"
  fi
  if [ -f "$SEARCH_FILE" ]; then
    check_env_file "$SEARCH_FILE" -- THINKTIN_PARALLEL_SEARCH_KEY THINKTIN_DEEPSEEK_SEARCH_KEY THINKTIN_IQS_API_KEY
    search="用 $SEARCH_FILE 里的"
  fi
  if review_configured; then
    ensure_review_code
    review="$(toml_string review_phone) 用固定码登录（码在 $REVIEW_FILE）"
  fi
  [ -r "$ACS_STATE" ] || die "没有 $ACS_STATE（sandbox-manager 的 Key）：云端会话里 run.sh acs --addons 读回来，再 run.sh ecs --push target/aliyun-acs $ROOT/target/aliyun-acs"
  chmod 600 "$ACS_STATE"
  chmod 700 "$(dirname "$ACS_STATE")"

  local tmp
  tmp=$(mktemp -d /run/thinktin-secrets.XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  write_env_files "$tmp"

  echo "=== Secret 和 ConfigMap（命名空间 $NAMESPACE；只列键，不显示值）"
  k create namespace "$NAMESPACE" --dry-run=client -o yaml | k apply -f - >/dev/null
  local name
  for name in thinktin-api thinktin-worker thinktin-llm-gw thinktin-relay thinktin-migrate; do
    apply_from_env_file secret "$name" "$tmp/$name.env"
  done
  apply_from_env_file configmap thinktin-llm-gw "$tmp/public-llm-gw.env"
  apply_from_env_file configmap thinktin-relay "$tmp/public-relay.env"
  echo "短信的 Key：$sms；搜索的 key：$search；审核账号：$review"
  echo "密钥文件：$(find "$SECRETS" -maxdepth 1 -type f ! -name '.*' -printf '%f（%m） ' | sort)，目录 $(stat -c '%a %U' "$SECRETS")"
  echo "有变化（上面不是 unchanged 的）要重跑 06-deploy.sh，Pod 才带着新值重启。"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
