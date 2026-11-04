#!/usr/bin/env bash
# 生成部署包（WBS 2.9）：一个环境的全部清单，镜像固定到给定的版本，输出到标准输出。
# 发布流水线（.github/workflows/release.yml）用它按镜像摘要生成 GitHub Release 的附件；
# 想部署某个提交（预发上试）时也可以手动用，按标签引用。
#
# 用法：
#   deploy/k8s/bundle.sh <包> <镜像前缀> <版本> [<server 摘要> <llm-gw 摘要> <relay 摘要>]
#
#   包        staging、staging-migrate、production、production-migrate、production-canary、
#             tokyo、tokyo-migrate（东京 10 人测试环境，docs/deploy-aliyun-sg.md 第 8.9 节）
#   镜像前缀  比如 ghcr.io/thinktin
#   版本      比如 0.2.0；不给摘要时按标签引用（<前缀>/thinktin-server:<版本>），迁移 Job 的名字也带上它
#   摘要      sha256:...，三个镜像各一个（发布时用：标签被改指向也不影响）
#
# 需要 kubectl（内置 kustomize）。
set -euo pipefail

if [ $# -ne 3 ] && [ $# -ne 6 ]; then
  sed -n '2,15p' "$0" >&2
  exit 2
fi
bundle=$1 prefix=$2 version=$3
here=$(cd "$(dirname "$0")" && pwd)

case "$bundle" in
  staging | production | production-canary | tokyo) source="overlays/$bundle" namespace="" ;;
  staging-migrate) source="migrate" namespace="thinktin-staging" ;;
  production-migrate | tokyo-migrate) source="migrate" namespace="thinktin" ;;
  *) echo "unknown bundle $bundle" >&2; exit 2 ;;
esac

ref() { # 镜像 摘要
  if [ -n "${2:-}" ]; then
    echo "newName: $prefix/$1, digest: $2"
  else
    echo "newName: $prefix/$1, newTag: \"$version\""
  fi
}

work=$(mktemp -d "$here/.bundle.XXXXXX")
trap 'rm -rf "$work"' EXIT
{
  echo "apiVersion: kustomize.config.k8s.io/v1beta1"
  echo "kind: Kustomization"
  echo "resources: [../$source]"
  if [ -n "$namespace" ]; then
    echo "namespace: $namespace"
    # 迁移 Job 每个版本一个名字（thinktin-migrate-0-2-0）。
    suffix=${version,,}
    echo "nameSuffix: -${suffix//[^0-9a-z]/-}"
  fi
  echo "images:"
  echo "  - {name: thinktin-server, $(ref thinktin-server "${4:-}")}"
  echo "  - {name: thinktin-llm-gw, $(ref thinktin-llm-gw "${5:-}")}"
  echo "  - {name: thinktin-relay, $(ref thinktin-relay "${6:-}")}"
} > "$work/kustomization.yaml"
kubectl kustomize "$work"
