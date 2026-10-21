#!/usr/bin/env bash
# 一键生成宣传片：裁剪字体 → 合成音乐 → 逐帧渲染并编码
set -euo pipefail
cd "$(dirname "$0")"

[ -d node_modules/playwright ] || npm install --no-audit --no-fund
python3 fonts.py
python3 music.py
node render.mjs "$@"
node render.mjs --stills 17.5 >/dev/null
cp out/stills/t17.50.png out/poster.png
echo "完成：out/thinktin-promo.mp4、out/poster.png"
