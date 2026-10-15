#!/usr/bin/env bash
# 打 Android 用的 AAR（WBS 11.1）。需要 Android NDK（ANDROID_NDK_HOME）、cargo-ndk
# （cargo install cargo-ndk）、cmake（aws-lc-rs）；装了 gradle 时直接出 AAR，否则只生成库工程。
#
#   tools/client-core/build-android.sh [输出目录，默认 target/android]
#
# 输出：<out>/thinktin-core/（Android 库工程：Kotlin 绑定 + jniLibs），
#       <out>/thinktin-core/build/outputs/aar/*.aar（有 gradle 时）。
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to the Android NDK}"
command -v cargo-ndk >/dev/null || { echo "install cargo-ndk: cargo install cargo-ndk" >&2; exit 1; }
out="${1:-target/android}"
profile=mobile
abis=(arm64-v8a armeabi-v7a x86_64)

rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
mod="$out/thinktin-core"
rm -rf "$out"
mkdir -p "$mod/src/main/jniLibs" "$mod/src/main/kotlin"
# Android 15 起要求 16 KB 页对齐（新版 NDK 默认就是，老版本靠这个参数）。
RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-z,max-page-size=16384" \
  cargo ndk $(printf -- '-t %s ' "${abis[@]}") -o "$mod/src/main/jniLibs" \
  build -p client-core --lib --profile "$profile"

tools/client-core/gen-bindings.sh "$out/bindings"
cp -R "$out/bindings/kotlin/." "$mod/src/main/kotlin/"

cat > "$mod/src/main/AndroidManifest.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" />
XML
cat > "$mod/build.gradle.kts" <<'GRADLE'
plugins {
    id("com.android.library") version "8.7.3"
    id("org.jetbrains.kotlin.android") version "2.1.0"
}

android {
    namespace = "cn.thinktin.core"
    compileSdk = 35
    defaultConfig { minSdk = 26 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin { jvmToolchain(17) }

dependencies {
    // UniFFI 的 Kotlin 绑定经 JNA 调用 Rust，async 函数是挂起函数。
    implementation("net.java.dev.jna:jna:5.15.0@aar")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
}
GRADLE
cat > "$mod/settings.gradle.kts" <<'GRADLE'
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name = "thinktin-core"
GRADLE
if command -v gradle >/dev/null; then
  (cd "$mod" && gradle --quiet assembleRelease)
  echo "AAR at $mod/build/outputs/aar/"
else
  echo "library module at $mod (no gradle found; include it in the app build)"
fi
