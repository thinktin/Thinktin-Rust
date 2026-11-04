#!/bin/bash
# 把 App Store Connect API key 装到 $RUNNER_TEMP/AuthKey.p8（.github/workflows/ios-release.yml 的几个作业都用它）。
#
# 读环境变量 ASC_KEY_ID、ASC_ISSUER_ID、ASC_KEY_P8（或者以前的 ASC_KEY_P8_BASE64）；P8_IN_VARS=true 表示私钥误填进了
# Environment variables。缺了、格式不对就用 ::error:: 说清楚改哪一格。装好后把 KEY_ID、ISSUER_ID 写进 $GITHUB_ENV（后面的步骤用），
# 私钥路径写进 $GITHUB_OUTPUT 的 path。不打印密钥；两个 id 也加了掩码。
#
# 要在 macOS 的 /bin/bash 3.2 上跑：不用数组（set -u 下空数组会报错），变量后面紧跟中文标点时加花括号。
set -euo pipefail

missing=""
[[ -n "${ASC_KEY_ID:-}" ]] || missing="$missing ASC_KEY_ID"
[[ -n "${ASC_ISSUER_ID:-}" ]] || missing="$missing ASC_ISSUER_ID"
[[ -n "${ASC_KEY_P8:-}" || -n "${ASC_KEY_P8_BASE64:-}" ]] || missing="$missing ASC_KEY_P8"
if [[ -n "$missing" ]]; then
  echo "::error::GitHub 的 Test flight 环境里读不到${missing}：Settings → Environments → Test flight → Environment secrets 里加上（名字要一字不差）"
  if [[ "${P8_IN_VARS:-}" == "true" ]]; then
    echo "::error::ASC_KEY_P8 填在了 Environment variables 里：私钥要放 Environment secrets（变量谁都看得见），挪过去后把变量删掉"
  fi
  exit 1
fi

# 从网页上复制时常带上空格、换行：去掉。
key_id=$(printf '%s' "$ASC_KEY_ID" | tr -d '[:space:]')
issuer_id=$(printf '%s' "$ASC_ISSUER_ID" | tr -d '[:space:]' | tr 'A-F' 'a-f')
if ! [[ "$key_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "::error::ASC_KEY_ID 不像密钥 ID（应该是 10 位大写字母和数字，现在是 ${#key_id} 个字符）：填团队密钥列表里那一行的“密钥 ID”"
  exit 1
fi
if ! [[ "$issuer_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  echo "::error::ASC_ISSUER_ID 不像 Issuer ID（应该是 8-4-4-4-12 位的一串，现在是 ${#issuer_id} 个字符）：填团队密钥页面顶上的 Issuer ID"
  exit 1
fi
echo "::add-mask::$key_id"
echo "::add-mask::$issuer_id"
{
  echo "KEY_ID=$key_id"
  echo "ISSUER_ID=$issuer_id"
} >> "$GITHUB_ENV"

path="$RUNNER_TEMP/AuthKey.p8"
(
  umask 077
  if [[ -n "${ASC_KEY_P8:-}" ]]; then
    # 粘贴时换行可能丢了或变成空格：去掉首尾两行和所有空白，按 64 个字符一行重排成 PEM。
    body=$(printf '%s' "$ASC_KEY_P8" | sed -e 's/-----BEGIN PRIVATE KEY-----//' -e 's/-----END PRIVATE KEY-----//' | tr -d ' \t\r\n')
    { echo "-----BEGIN PRIVATE KEY-----"; printf '%s\n' "$body" | fold -w 64; echo "-----END PRIVATE KEY-----"; } > "$path"
  else
    printf '%s' "$ASC_KEY_P8_BASE64" | base64 --decode > "$path"
  fi
)
if ! openssl pkey -in "$path" -noout 2>/dev/null; then
  echo "::error::ASC_KEY_P8 读不出私钥：用文本编辑打开 .p8 文件，全选复制（从 -----BEGIN 到 END-----）再粘贴一次"
  exit 1
fi
echo "path=$path" >> "$GITHUB_OUTPUT"
