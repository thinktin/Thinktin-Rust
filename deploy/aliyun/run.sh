#!/usr/bin/env bash
# 阿里云部署脚本的入口（docs/deploy-aliyun-sg.md）：第一次运行时在 target/aliyun-venv 建 Python 环境、装 requirements.txt
# 里锁定的阿里云 SDK，然后执行 deploy/aliyun/<命令>.py。
#
#   deploy/aliyun/run.sh check                      只读检查：Key、身份、新加坡的规格、各产品开没开通、余额
#   deploy/aliyun/run.sh check --region ap-northeast-1
#   deploy/aliyun/run.sh network [--apply]          第 1 阶段：VPC、交换机、安全组（不收费；不加 --apply 只打印计划）
#
# Key 从环境变量 ALIBABA_CLOUD_ACCESS_KEY_ID、ALIBABA_CLOUD_ACCESS_KEY_SECRET 读（云端环境设置的“环境变量”里填），不打印。
set -euo pipefail
cd "$(dirname "$0")/../.."
cmd="${1:?用法：deploy/aliyun/run.sh <check|network> [参数]}"
shift
venv=target/aliyun-venv
req=deploy/aliyun/requirements.txt
if [[ ! -x $venv/bin/python ]] || ! cmp -s "$req" "$venv/requirements.txt"; then
  python3 -m venv "$venv"
  "$venv/bin/pip" install --quiet --disable-pip-version-check -r "$req"
  cp "$req" "$venv/requirements.txt"
fi
exec "$venv/bin/python" "deploy/aliyun/$cmd.py" "$@"
