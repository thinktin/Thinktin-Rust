#!/usr/bin/env bash
# 服务机第六步（root，重跑没有副作用）：在服务机上生成东京的部署包，跑迁移 Job，起四个服务，最后体检。
# 前面几步都做完（03 k3s 和镜像、04 数据库、05 Secret），deploy/k8s 也传上来了：
#   deploy/aliyun/run.sh ecs --run 'bash /opt/thinktin/deploy/aliyun/machine/06-deploy.sh'
#
# 迁移加上四个服务换好可能要几分钟（模型网关换版本时先停旧的，最多等进行中的流式请求 300 秒）：脚本先查一遍前提，
# 再把活放到后台就返回，日志在 /opt/thinktin/deploy.log，结束时最后一行是 DEPLOY OK 或 DEPLOY FAILED。看进度：
#   deploy/aliyun/run.sh ecs --run 'tail -60 /opt/thinktin/deploy.log'
#
# 别的用法（都在前台，几秒到几十秒）：
#   06-deploy.sh --status         只体检，不改任何东西：Pod、接口的 /healthz 和 /version（经 Service、经 Caddy 和证书）、
#                                 中继、模型网关的 8790 / 8791、后台副本连不连得上 sandbox-manager
#   06-deploy.sh --review-check   给审核账号发一次码（不发短信），看接口答不答 204。占这个号每天 10 次里的一次，
#                                 之后 60 秒内这个号不能再要码
#
# 可以带的环境变量：VERSION=0.1.0-tokyo.<提交>（部署哪一版镜像，默认见 common.sh；回滚就是带上一版的 VERSION 重跑）。
#
# 做的事：
# 1. 用 deploy/k8s/bundle.sh 生成 tokyo-migrate、tokyo 两个包（k3s 自带的 kubectl），放在 /opt/thinktin/render。
# 2. 迁移 Job（thinktin-migrate-<版本>）：没跑过就跑、等它结束；成功过的不重跑；上次失败的删掉重跑。
# 3. 给四个 Deployment 盖上“配置指纹”（它用到的配置文件、ConfigMap、Secret 现在的版本）：配置或密钥变了 Pod 才重启，
#    没变的不动（envFrom 和挂载的配置不会自己生效；模型网关每重启一次都要断一下）。
# 4. kubectl apply，等四个服务换好；然后体检。输出里没有密钥。
set -euo pipefail
SELF=$(readlink -f "${BASH_SOURCE[0]}")
# shellcheck source=deploy/aliyun/machine/common.sh
. "$(dirname "$SELF")/common.sh"

LOG=$ROOT/deploy.log
LOCK=/run/thinktin-deploy.lock
BUNDLE_SH=$ROOT/deploy/k8s/bundle.sh
SERVER_TOML=$OVERLAY/server.toml
# 换的顺序：模型网关放最后（它要先停旧的，等得最久）。
DEPLOYMENTS="thinktin-api thinktin-worker thinktin-relay thinktin-llm-gw"
MIGRATE_TIMEOUT=600
# Pod 模板里占位的注解（deploy/k8s/overlays/tokyo/kustomization.yaml），部署时换成算出来的指纹。
STAMP_KEY=thinktin.si/config-stamp
# 体检里没过的项数。
PROBLEMS=0

pass() { echo "[通过] $*"; }
note() { echo "[注意] $*"; }
fail() {
  echo "[不通过] $*"
  PROBLEMS=$((PROBLEMS + 1))
}

# HTTP 状态码（连不上是 000）：http_code <curl 参数…>
http_code() {
  local code
  code=$(curl -s -o /dev/null -m 6 -w '%{http_code}' "$@" 2>/dev/null) || true
  echo "${code:-000}"
}

# 等到答 200（刚换好的 Pod，Service 的转发规则可能晚一两秒）：expect_200 <说明> <curl 参数…>
expect_200() {
  local what=$1 code="" i
  shift
  for i in 1 2 3; do
    code=$(http_code "$@")
    [ "$code" = 200 ] && break
    [ "$i" = 3 ] || sleep 2
  done
  if [ "$code" = 200 ]; then
    pass "$what"
  else
    fail "$what：答的是 $code"
  fi
}

# /version 里的服务端版本：server_version <curl 参数…>
server_version() {
  { curl -s -m 6 "$@" 2>/dev/null || true; } | sed -n 's/.*"server_version":"\([^"]*\)".*/\1/p' | head -n 1
}

# server.toml 里配的审核账号（没配就是空）。
review_phone() {
  sed -n 's/^[[:space:]]*review_phone[[:space:]]*=[[:space:]]*"\([^"]*\)".*$/\1/p' "$SERVER_TOML" 2>/dev/null | head -n 1
}

# ---------- 前提 ----------
preflight() {
  local target name
  k3s_ready || die "k3s 没起来：先跑 03-k3s-caddy.sh（tail -40 $ROOT/k3s-caddy.log 看它跑完没有）"
  [ -f "$BUNDLE_SH" ] && [ -f "$SERVER_TOML" ] \
    || die "没有 $ROOT/deploy/k8s：先把清单传上来（deploy/aliyun/run.sh ecs --push deploy/k8s $ROOT/deploy/k8s）"
  for target in server llm-gw relay; do
    "$K3S" crictl inspecti "$(image "$target")" >/dev/null 2>&1 \
      || die "k3s 里没有 $(image "$target")：先带同一个 VERSION 跑 03-k3s-caddy.sh（它把镜像从 docker 导进来）"
  done
  k get namespace "$NAMESPACE" >/dev/null 2>&1 || die "没有命名空间 $NAMESPACE：先跑 05-secrets.sh"
  for name in thinktin-api thinktin-worker thinktin-llm-gw thinktin-relay thinktin-migrate; do
    k -n "$NAMESPACE" get secret "$name" >/dev/null 2>&1 || die "没有 Secret $name：先跑 05-secrets.sh"
  done
  for name in thinktin-llm-gw thinktin-relay; do
    k -n "$NAMESPACE" get configmap "$name" >/dev/null 2>&1 || die "没有 ConfigMap $name（公钥）：先跑 05-secrets.sh"
  done
}

# ---------- 部署包 ----------
# 一个对象现在的版本（不读内容）：内容换过、对象重建过都会变。没有这个对象输出 absent。
object_version() {
  k -n "$NAMESPACE" get "$1" -o jsonpath='{.metadata.uid}/{.metadata.resourceVersion}' 2>/dev/null || echo absent
}

# 一个 Deployment 的配置指纹：它用到的配置文件、ConfigMap、Secret 的版本合起来的摘要。
stamp_of() {
  {
    case "$1" in
      thinktin-api)
        sha256sum < "$SERVER_TOML"
        object_version secret/thinktin-api
        ;;
      thinktin-worker)
        sha256sum < "$SERVER_TOML"
        object_version secret/thinktin-worker
        object_version secret/thinktin-push
        ;;
      thinktin-llm-gw)
        object_version configmap/thinktin-llm-gw
        object_version secret/thinktin-llm-gw
        ;;
      thinktin-relay)
        object_version configmap/thinktin-relay
        object_version secret/thinktin-relay
        ;;
    esac
  } | sha256sum | cut -c1-16
}

render() {
  local bundle name
  mkdir -p "$RENDER/bin"
  chmod 700 "$RENDER"
  # bundle.sh 要一个叫 kubectl 的命令（只用它内置的 kustomize，不连集群）：给它 k3s 自带的那个。
  printf '#!/bin/sh\nexec %s kubectl "$@"\n' "$K3S" > "$RENDER/bin/kubectl"
  chmod 755 "$RENDER/bin/kubectl"
  for bundle in tokyo-migrate tokyo; do
    if ! PATH="$RENDER/bin:$PATH" bash "$BUNDLE_SH" "$bundle" "$IMAGE_PREFIX" "$VERSION" \
      > "$RENDER/$bundle.rendered.yaml" 2> "$RENDER/$bundle.err"; then
      echo "[不通过] 生成 $bundle 的部署包失败："
      tail -n 5 "$RENDER/$bundle.err" | cut -c1-300
      return 1
    fi
    rm -f "$RENDER/$bundle.err"
  done
  mv "$RENDER/tokyo-migrate.rendered.yaml" "$RENDER/tokyo-migrate.yaml"

  # 盖配置指纹：每个 Deployment 的 Pod 模板里那个占位的注解，换成它自己的指纹。
  : > "$RENDER/stamps.txt"
  for name in $DEPLOYMENTS; do
    echo "$name $(stamp_of "$name")" >> "$RENDER/stamps.txt"
  done
  if ! python3 - "$RENDER/stamps.txt" "$STAMP_KEY" "$RENDER/tokyo.rendered.yaml" > "$RENDER/tokyo.yaml.new" <<'PY'; then
import sys

stamps = dict(line.split() for line in open(sys.argv[1], encoding="utf-8") if line.strip())
placeholder = "        %s: unset" % sys.argv[2]
done = set()
docs = open(sys.argv[3], encoding="utf-8").read().split("\n---\n")
for i, doc in enumerate(docs):
    lines = doc.split("\n")
    if "kind: Deployment" not in lines:
        continue
    # kustomize 输出里顶层的键按字母排：metadata 下第一个两格缩进的 name 就是这个 Deployment 的名字。
    name = next((line[len("  name: "):] for line in lines if line.startswith("  name: ")), None)
    if name in stamps and lines.count(placeholder) == 1:
        lines[lines.index(placeholder)] = '        %s: "%s"' % (sys.argv[2], stamps[name])
        docs[i] = "\n".join(lines)
        done.add(name)
missing = sorted(set(stamps) - done)
if missing:
    sys.exit("no %s placeholder in: %s" % (sys.argv[2], ", ".join(missing)))
sys.stdout.write("\n---\n".join(docs))
PY
    echo "[不通过] 盖配置指纹失败（清单的样子变了？对照 overlays/tokyo/kustomization.yaml 里的 config-stamp）"
    rm -f "$RENDER/tokyo.yaml.new"
    return 1
  fi
  mv "$RENDER/tokyo.yaml.new" "$RENDER/tokyo.yaml"
  rm -f "$RENDER/tokyo.rendered.yaml"
  # 清单里的镜像 k3s 里都要有（imagePullPolicy 是 Never，没有的话 Pod 一直起不来）。
  while IFS= read -r name; do
    "$K3S" crictl inspecti "$name" >/dev/null 2>&1 || { echo "[不通过] 清单要的镜像 k3s 里没有：$name"; return 1; }
  done < <(sed -n 's/^ *image: *//p' "$RENDER/tokyo.yaml" "$RENDER/tokyo-migrate.yaml" | sort -u)
  echo "[已生成] $RENDER/tokyo-migrate.yaml、$RENDER/tokyo.yaml（版本 $VERSION）"
}

# ---------- 迁移 ----------
# Job 的状态：absent、running、complete、failed。
job_state() {
  local conds
  conds=$(k -n "$NAMESPACE" get job "$1" \
    -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}' 2>/dev/null) || {
    echo absent
    return 0
  }
  case " $conds" in
    *" Complete "*) echo complete ;;
    *" Failed "*) echo failed ;;
    *) echo running ;;
  esac
}

# 迁移 Job 的 Pod 现在什么样、最后说了什么（迁移的日志里是迁移的名字和数据库的报错，没有连接串）。
job_report() {
  k -n "$NAMESPACE" get pods -l "job-name=$1" --no-headers \
    -o custom-columns='POD:.metadata.name,PHASE:.status.phase,WAITING:.status.containerStatuses[0].state.waiting.reason,EXIT:.status.containerStatuses[0].state.terminated.exitCode' \
    2>&1 | sed 's/^/  /'
  { k -n "$NAMESPACE" logs "job/$1" --tail=30 2>&1 || true; } | cut -c1-400 | sed 's/^/  /'
  k -n "$NAMESPACE" get events --sort-by=.lastTimestamp 2>/dev/null | grep -F "$1" | tail -n 5 | cut -c1-300 | sed 's/^/  /' || true
}

migrate() {
  local job state end
  job=$(sed -n 's/^  name: \(thinktin-migrate[a-z0-9.-]*\)$/\1/p' "$RENDER/tokyo-migrate.yaml" | head -n 1)
  [ -n "$job" ] || { echo "[不通过] 迁移的清单里找不到 Job 的名字"; return 1; }
  state=$(job_state "$job")
  case "$state" in
    complete)
      echo "[已有] 迁移 Job $job 以前成功过，不重跑（库是后来重建的话，先 k3s kubectl -n $NAMESPACE delete job $job）"
      return 0
      ;;
    failed)
      echo "上次的迁移 Job $job 失败了，它最后的样子："
      job_report "$job"
      echo "删掉它重跑……"
      k -n "$NAMESPACE" delete job "$job" --wait=true --timeout=120s >/dev/null
      ;;
    running)
      echo "迁移 Job $job 已经在跑，等它……"
      ;;
  esac
  if [ "$state" != running ]; then
    k apply -f "$RENDER/tokyo-migrate.yaml" >/dev/null
    echo "迁移 Job $job 开始了……"
  fi
  end=$((SECONDS + MIGRATE_TIMEOUT))
  while :; do
    state=$(job_state "$job")
    case "$state" in
      complete)
        echo "[通过] 迁移跑完了：$({ k -n "$NAMESPACE" logs "job/$job" --tail=1 2>/dev/null || true; } | cut -c1-200)"
        return 0
        ;;
      failed)
        echo "[不通过] 迁移失败（服务没动）。修好以后重跑这个脚本，它会删掉失败的 Job 再跑："
        job_report "$job"
        return 1
        ;;
    esac
    if [ "$SECONDS" -ge "$end" ]; then
      echo "[不通过] 迁移 Job 等了 $MIGRATE_TIMEOUT 秒还没结束（Pod 起不来？）："
      job_report "$job"
      return 1
    fi
    sleep 3
  done
}

# ---------- 服务 ----------
# 一个服务没换好时：它的 Pod 什么样、最后几行日志、最近的事件。
diagnose() {
  local pod prev
  k -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=$1" --no-headers \
    -o custom-columns='POD:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[0].ready,WAITING:.status.containerStatuses[0].state.waiting.reason,RESTARTS:.status.containerStatuses[0].restartCount' \
    2>&1 | sed 's/^/  /'
  for pod in $(k -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=$1" -o name 2>/dev/null); do
    echo "  --- $pod 最后几行日志"
    { k -n "$NAMESPACE" logs "$pod" --tail=8 2>&1 || true; } | cut -c1-400 | sed 's/^/  /'
    prev=$(k -n "$NAMESPACE" logs "$pod" --previous --tail=8 2>/dev/null || true)
    if [ -n "$prev" ]; then
      echo "  --- $pod 上一次启动（重启过）"
      cut -c1-400 <<< "$prev" | sed 's/^/  /'
    fi
  done
  echo "  --- 最近的事件"
  { k -n "$NAMESPACE" get events --sort-by=.lastTimestamp 2>/dev/null || true; } | tail -n 6 | cut -c1-300 | sed 's/^/  /'
}

rollout() {
  local name secs failed=0
  # 这个函数的调用处带着 ||，set -e 在里面不起作用：每一步自己看结果。
  if ! k apply -f "$RENDER/tokyo.yaml" 2>&1 | cut -c1-300 | sed 's/^/  /'; then
    echo "[不通过] kubectl apply 失败（上面是它说的）"
    return 1
  fi
  for name in $DEPLOYMENTS; do
    secs=240
    # 模型网关先停旧的再起新的：旧的最多等进行中的流式请求 300 秒。
    [ "$name" = thinktin-llm-gw ] && secs=480
    if k -n "$NAMESPACE" rollout status "deploy/$name" --timeout="${secs}s" >/dev/null 2>&1; then
      echo "[通过] $name 换好了"
    else
      echo "[不通过] $name 等了 $secs 秒没换好："
      diagnose "$name"
      failed=1
    fi
  done
  return "$failed"
}

# ---------- 体检 ----------
# 一个 Deployment 用的镜像（全名）。
deploy_image() {
  case "$1" in
    thinktin-api | thinktin-worker) image server ;;
    *) image "${1#thinktin-}" ;;
  esac
}

status() {
  local name got want pid code listening version phone
  PROBLEMS=0
  echo "=== 体检 $(date -u +%FT%TZ)（要的版本 $VERSION）"
  k -n "$NAMESPACE" get pods --no-headers \
    -o custom-columns='POD:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,IP:.status.podIP,IMAGE:.spec.containers[0].image' \
    2>&1 | sed 's/^/  /' || true
  for name in $DEPLOYMENTS; do
    got=$(k -n "$NAMESPACE" get deploy "$name" \
      -o jsonpath='{.status.readyReplicas}/{.status.updatedReplicas}/{.spec.replicas} {.spec.template.spec.containers[0].image}' 2>/dev/null || true)
    want="1/1/1 $(deploy_image "$name")"
    if [ "$got" = "$want" ]; then
      pass "$name 就绪（${want#* }）"
    else
      fail "$name 没就绪或者不是要的版本（就绪/已更新/副本数 镜像：${got:-没有这个 Deployment}）"
    fi
  done

  echo "--- 接口（thinktin-api）"
  expect_200 "经 Service $API_SERVICE_IP：/healthz" "http://$API_SERVICE_IP/healthz"
  expect_200 "经 Service：/readyz（接口连得上数据库）" "http://$API_SERVICE_IP/readyz"
  version=$(server_version "http://$API_SERVICE_IP/version")
  if [ "$version" = "$VERSION" ]; then
    pass "经 Service：/version 是 $version"
  else
    fail "经 Service：/version 是 ${version:-（没答）}，要的是 $VERSION"
  fi
  # 在本机用域名连自己（--resolve，不绕公网）：验 Caddy、证书和转发。
  expect_200 "经 Caddy 和证书：https://$API_HOST/healthz" --resolve "$API_HOST:443:127.0.0.1" "https://$API_HOST/healthz"
  version=$(server_version --resolve "$API_HOST:443:127.0.0.1" "https://$API_HOST/version")
  if [ "$version" = "$VERSION" ]; then
    pass "经 Caddy 和证书：https://$API_HOST/version 是 $version"
  else
    fail "经 Caddy 和证书：https://$API_HOST/version 是 ${version:-（没答）}"
  fi
  # 真的绕公网走一遍（解析到公网地址再回到这台机器）。从机器里连自己的公网地址不一定通，不通只提醒：
  # 以外面连的结果为准（云端会话里 curl https://api.thinktin.si/version）。
  code=$(http_code -w '%{http_code} %{remote_ip}' "https://$API_HOST/healthz")
  if [ "${code%% *}" = 200 ]; then
    pass "经公网：https://$API_HOST/healthz（解析到 ${code#* }）"
  else
    note "从服务机绕公网连 https://$API_HOST/healthz 答的是 ${code%% *}：在外面再验一次（云端会话里 curl -sS https://$API_HOST/version）"
  fi

  echo "--- 设备中继（thinktin-relay）"
  expect_200 "经 Service $RELAY_SERVICE_IP：/readyz（中继连得上数据库）" "http://$RELAY_SERVICE_IP/readyz"
  expect_200 "经 Caddy 和证书：https://$RELAY_HOST/healthz" --resolve "$RELAY_HOST:443:127.0.0.1" "https://$RELAY_HOST/healthz"
  # WebSocket 握手（不带令牌）：中继答 401 说明升级请求穿过 Caddy 到了中继。
  code=$(http_code --http1.1 --resolve "$RELAY_HOST:443:127.0.0.1" -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "https://$RELAY_HOST/v1/connect")
  if [ "$code" = 401 ]; then
    pass "wss://$RELAY_HOST/v1/connect 的握手到了中继（没带令牌，答 401）"
  else
    fail "wss://$RELAY_HOST/v1/connect 的握手答的是 $code（应该是 401：没带令牌）"
  fi

  echo "--- 模型网关（thinktin-llm-gw，服务机的网络）"
  listening=$(ss -ltnH 2>/dev/null || true)
  for name in 8790 8791; do
    if grep -q -E "[:.]$name[[:space:]]" <<< "$listening"; then
      pass "服务机在监听 $name"
    else
      fail "服务机没在监听 $name（8790 是模型网关，8791 是受控出网通道）"
    fi
  done
  expect_200 "http://$NODE_IP:8790/healthz（沙箱连的就是这个地址）" "http://$NODE_IP:8790/healthz"

  echo "--- 后台副本（thinktin-worker）到 sandbox-manager"
  pid=$(pod_pid thinktin-worker)
  if [ -n "$pid" ]; then
    echo "从后台副本的 Pod 里经 http://$NODE_IP:$SANDBOX_PROXY_PORT（上游 $(upstream_now)）："
    sandbox_manager_verdict "$(sandbox_manager_code "$pid")" || PROBLEMS=$((PROBLEMS + 1))
  else
    fail "没有在跑的 thinktin-worker Pod，测不了它到 sandbox-manager 的路"
    echo "从服务机经 http://$NODE_IP:$SANDBOX_PROXY_PORT（上游 $(upstream_now)）："
    sandbox_manager_verdict "$(sandbox_manager_code)" || PROBLEMS=$((PROBLEMS + 1))
  fi

  echo "--- 别的"
  phone=$(review_phone)
  if [ -n "$phone" ]; then
    if [ "$(k -n "$NAMESPACE" get secret thinktin-api -o go-template='{{if index .data "THINKTIN_REVIEW_CODE"}}yes{{else}}no{{end}}' 2>/dev/null || true)" = yes ]; then
      pass "审核账号 $phone 配着固定码（码在服务机的 $SECRETS/review.code；发码不走短信，--review-check 可以实测）"
    else
      fail "server.toml 配了审核账号 $phone，Secret thinktin-api 里没有固定码：重跑 05-secrets.sh"
    fi
  else
    note "server.toml 没配审核账号（review_phone）：登录全靠短信"
  fi
  for name in $DEPLOYMENTS; do
    got=$({ k -n "$NAMESPACE" logs "deploy/$name" --tail=300 2>/dev/null || true; } | grep -c '"level":"ERROR"' || true)
    [ "${got:-0}" = 0 ] || note "$name 最近 300 行日志里有 $got 条 ERROR（k3s kubectl -n $NAMESPACE logs deploy/$name --tail=300 | grep ERROR）"
  done
  free -m | awk '/^Mem/{print "  内存 " $3 " / " $2 " MB 在用，可用 " $7 " MB"} /^Swap/{print "  交换 " $3 " / " $2 " MB 在用"}'
  df -h / | awk 'NR==2{print "  系统盘 " $3 " / " $2 "，剩 " $4 "（后台副本存放工作区归档时最多临时占 10G）"}'
  if [ "$PROBLEMS" = 0 ]; then
    echo "体检全过。"
  else
    echo "体检有 $PROBLEMS 项没过（上面标了 [不通过] 的）。"
  fi
  [ "$PROBLEMS" = 0 ]
}

# 给审核账号发一次码：接口答 204 说明这个号不走短信（短信的 Key 还是占位值，别的号在这一步会失败）。
review_check() {
  local phone code
  phone=$(review_phone)
  [ -n "$phone" ] || die "server.toml 里没配审核账号（[api] review_phone）"
  code=$(http_code -H 'Content-Type: application/json' -d "{\"phone\":\"$phone\"}" "http://$API_SERVICE_IP/v1/auth/code")
  case "$code" in
    204)
      echo "[通过] 审核账号 $phone 发码成功（204，没发短信）。验证码是服务机上 $SECRETS/review.code 里的 6 位数字，5 分钟内有效；这个号 60 秒后才能再要码"
      ;;
    429)
      echo "[注意] 答了 429：这个号刚要过码（60 秒一次），或者今天的 10 次用完了。发码这条路本身是通的"
      ;;
    503)
      echo "[不通过] 答了 503：这个号走了短信那条路（审核账号没生效？看接口副本启动日志里有没有 app review account is enabled）"
      return 1
      ;;
    *)
      echo "[不通过] 发码答的是 $code（应该是 204）"
      return 1
      ;;
  esac
}

# ---------- 入口 ----------
case "${1:-}" in
  --status)
    need_root
    k3s_ready || die "k3s 没起来：先跑 03-k3s-caddy.sh"
    status
    exit
    ;;
  --review-check)
    need_root
    k3s_ready || die "k3s 没起来：先跑 03-k3s-caddy.sh"
    review_check
    exit
    ;;
  --foreground) ;;
  "")
    need_root
    preflight
    if ! (flock -n 9) 9> "$LOCK"; then
      die "上一次部署还在跑：tail -60 $LOG"
    fi
    nohup setsid bash "$SELF" --foreground > "$LOG" 2>&1 < /dev/null &
    echo "前提都在；部署在后台开始了（版本 $VERSION）。日志 $LOG，最后一行是 DEPLOY OK 或 DEPLOY FAILED"
    exit 0
    ;;
  *)
    sed -n '2,16p' "$SELF" >&2
    exit 2
    ;;
esac

exec 9> "$LOCK"
flock -n 9 || { echo "DEPLOY FAILED：另一个还在跑"; exit 1; }
DONE=0
finish() {
  local rc=$?
  if [ "$rc" = 0 ] && [ "$DONE" = 1 ]; then
    echo "DEPLOY OK $(date -u +%FT%TZ) 版本 $VERSION"
  else
    echo "DEPLOY FAILED $(date -u +%FT%TZ)（原因在上面；修好以后重跑这个脚本）"
  fi
}
trap finish EXIT
echo "DEPLOY START $(date -u +%FT%TZ) 版本 $VERSION"
need_root
preflight
echo "=== 部署包"
render
echo "=== 迁移"
migrate
echo "=== 服务"
rolled=0
rollout || rolled=1
healthy=0
status || healthy=1
if [ "$rolled" = 0 ] && [ "$healthy" = 0 ]; then
  DONE=1
else
  exit 1
fi
