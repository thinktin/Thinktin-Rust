#!/usr/bin/env bash
# 一键生成宣传片：裁剪字体 → 合成配乐 → 逐帧渲染并编码 → 导出封面
set -euo pipefail
cd "$(dirname "$0")"

[ -d node_modules/playwright ] || npm install --no-audit --no-fund
python3 fonts.py
python3 music.py
node render.mjs "$@"
ffmpeg -v error -y -ss 18.5 -i out/thinktin-promo.mp4 -frames:v 1 out/poster.png
echo "完成：out/thinktin-promo.mp4、out/poster.png"
