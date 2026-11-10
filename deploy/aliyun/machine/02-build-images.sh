#!/usr/bin/env bash
# 服务机第二步（root）：在服务机上从源码构建三个服务镜像（控制面、模型网关、设备中继），和发布流水线用同一个
# deploy/docker/Dockerfile。不经过镜像仓库：仓库是私有的，机器上不放 GitHub 的凭证；构建完以后导进 k3s（第三步）。
#
# 源码由云端会话打包传上来（只有构建要的那部分，见 docs/deploy-aliyun-sg.md 第 8.6 节）：
#   git archive HEAD -- crates Cargo.toml Cargo.lock tools/licenses deploy/docker deploy/templates/notices \
#       deploy/templates/browser .dockerignore | tar -x -C <dir>/thinktin-src
#   deploy/aliyun/run.sh ecs --push <dir>/thinktin-src /opt/thinktin/thinktin-src
#   deploy/aliyun/run.sh ecs --run 'VERSION=0.1.0-tokyo.<提交> bash /opt/thinktin/deploy/aliyun/machine/02-build-images.sh'
#
# 构建要几十分钟（2 核）：脚本把构建放到后台就返回，日志在 /opt/thinktin/build.log，结束时最后一行是 BUILD OK 或
# BUILD FAILED。看进度：deploy/aliyun/run.sh ecs --run 'tail -5 /opt/thinktin/build.log'
set -euo pipefail
VERSION="${VERSION:?要给 VERSION，比如 0.1.0-tokyo.abc1234}"
PREFIX="${PREFIX:-thinktin.local/tokyo}"
SRC=/opt/thinktin/thinktin-src
LOG=/opt/thinktin/build.log
[ -f "$SRC/Cargo.lock" ] || { echo "没有 $SRC：先把源码传上来"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
if ! command -v docker >/dev/null || ! docker buildx version >/dev/null 2>&1; then
  apt-get update -qq >/dev/null
  apt-get install -y -qq docker.io docker-buildx >/dev/null
fi
systemctl enable --now docker >/dev/null 2>&1
# 刚装好的 docker 要等它真的能用（第一次构建撞上它还没起来，连接被重置以后一直挂着）。
for _ in $(seq 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
docker info >/dev/null 2>&1 || { echo "docker 没起来"; exit 1; }
pkill -f /opt/thinktin/build-run.sh 2>/dev/null || true
pkill -f "docker build -f deploy/docker/Dockerfile" 2>/dev/null || true
# 4G 内存链接大程序不宽裕：加 4G 交换空间（已经有就不动）。
if ! swapon --show | grep -q /swapfile; then
  [ -f /swapfile ] || { fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap -q /swapfile; }
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

cat > /opt/thinktin/build-run.sh <<RUN
#!/usr/bin/env bash
set -uo pipefail
cd "$SRC"
echo "BUILD START \$(date -u +%FT%TZ) version $VERSION"
ok=1
for target in server llm-gw relay; do
  echo "=== \$target \$(date -u +%T)"
  DOCKER_BUILDKIT=1 docker build --progress=plain -f deploy/docker/Dockerfile --target "\$target" \\
    --build-arg THINKTIN_VERSION="$VERSION" -t "$PREFIX/thinktin-\$target:$VERSION" . 2>&1 | grep -v -E "^#[0-9]+ [0-9.]+ +(Compiling|Downloaded|Downloading) " || true
  docker image inspect "$PREFIX/thinktin-\$target:$VERSION" >/dev/null 2>&1 || ok=0
done
docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep "$PREFIX" || true
[ "\$ok" = 1 ] && echo "BUILD OK \$(date -u +%FT%TZ) $PREFIX $VERSION" || echo "BUILD FAILED \$(date -u +%FT%TZ)"
RUN
chmod +x /opt/thinktin/build-run.sh
nohup setsid /opt/thinktin/build-run.sh > "$LOG" 2>&1 < /dev/null &
echo "构建在后台开始了（docker $(docker --version | cut -d, -f1 | cut -d' ' -f3)，$(free -g | awk '/Swap/{print $2}')G 交换空间）；日志 $LOG"
