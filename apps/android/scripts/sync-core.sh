#!/usr/bin/env bash
# 把 client-core（crates/client-core）的 Kotlin 绑定、各 ABI 的 .so 和许可证资源同步进 :core 模块。
#
#   apps/android/scripts/sync-core.sh                 # 交叉编译（需要 NDK、cargo-ndk），再同步全部
#   apps/android/scripts/sync-core.sh --from <dir>    # 不编译，从已有的输出目录同步（build-android.sh 的输出，如 target/android）
#   apps/android/scripts/sync-core.sh --bindings-only # 只重新生成并同步 Kotlin 绑定（只需要 cargo）
#   apps/android/scripts/sync-core.sh --check         # 同上但不写入：提交的绑定和 Rust 不一致时非零退出（CI 用）
#
# 生成的绑定先过 scripts/patch-bindings.py（UniFFI 0.32 的 `message` 字段与 Kotlin 2 冲突，见该文件）。
# 绑定（client_core.kt）提交进 git；jniLibs 和 assets/thinktin-licenses 是生成物，已在 .gitignore 里。
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
core="$repo/apps/android/core/src/main"
kt_rel="kotlin/cn/thinktin/core/client_core.kt"

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

mode=full
from=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      [[ $# -ge 2 ]] || usage
      mode=from
      from="$2"
      shift 2
      ;;
    --bindings-only) mode=bindings; shift ;;
    --check) mode=check; shift ;;
    -h | --help) usage ;;
    *) echo "未知参数：$1" >&2; usage ;;
  esac
done

sync_bindings() { # $1 = 含 kotlin/cn/thinktin/core/client_core.kt 的目录
  local src="$1/$kt_rel"
  [[ -f "$src" ]] || { echo "找不到绑定：$src" >&2; exit 1; }
  mkdir -p "$core/kotlin/cn/thinktin/core"
  cp "$src" "$core/$kt_rel"
  python3 "$here/patch-bindings.py" "$core/$kt_rel"
  echo "绑定 → apps/android/core/src/main/$kt_rel"
}

sync_native() { # $1 = build-android.sh 的输出目录
  local mod="$1/thinktin-core/src/main"
  [[ -d "$mod/jniLibs" ]] || { echo "找不到 $mod/jniLibs（先跑 tools/client-core/build-android.sh）" >&2; exit 1; }
  rm -rf "$core/jniLibs"
  mkdir -p "$core/jniLibs"
  cp -R "$mod/jniLibs/." "$core/jniLibs/"
  echo "jniLibs → apps/android/core/src/main/jniLibs（$(cd "$core/jniLibs" && ls | tr '\n' ' ')）"
  if [[ -d "$mod/assets/thinktin-licenses" ]]; then
    rm -rf "$core/assets/thinktin-licenses"
    mkdir -p "$core/assets"
    cp -R "$mod/assets/thinktin-licenses" "$core/assets/"
    echo "许可证 → apps/android/core/src/main/assets/thinktin-licenses"
  else
    echo "警告：$mod/assets/thinktin-licenses 不存在，跳过许可证资源" >&2
  fi
}

case "$mode" in
  full)
    "$repo/tools/client-core/build-android.sh" "$repo/target/android"
    sync_bindings "$repo/target/android/bindings"
    sync_native "$repo/target/android"
    ;;
  from)
    [[ "$from" = /* ]] || from="$repo/$from"
    if [[ -f "$from/bindings/$kt_rel" ]]; then
      sync_bindings "$from/bindings"
    else
      sync_bindings "$from/thinktin-core/src/main"
    fi
    sync_native "$from"
    ;;
  bindings)
    "$repo/tools/client-core/gen-bindings.sh" "$repo/target/bindings"
    sync_bindings "$repo/target/bindings"
    ;;
  check)
    "$repo/tools/client-core/gen-bindings.sh" "$repo/target/bindings"
    expected="$repo/target/bindings/client_core.patched.kt"
    cp "$repo/target/bindings/$kt_rel" "$expected"
    python3 "$here/patch-bindings.py" "$expected" >/dev/null
    if ! diff -u "$core/$kt_rel" "$expected" > "$repo/target/bindings/client_core.kt.diff"; then
      head -n 60 "$repo/target/bindings/client_core.kt.diff" >&2
      echo >&2
      echo "提交的 Kotlin 绑定和 crates/client-core 不一致。运行下面的命令更新后提交：" >&2
      echo "  apps/android/scripts/sync-core.sh --bindings-only" >&2
      exit 1
    fi
    echo "Kotlin 绑定和 crates/client-core 一致"
    ;;
esac
