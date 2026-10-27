#!/usr/bin/env python3
"""生成官网安装包的更新清单 latest.json（13.12，docs/android-release.md 第 3 节）。

用法：
  update-manifest.py thinktin-0.2.0.apk --notes-zh "修了几个问题" --notes-en "Bug fixes" > latest.json

从安装包里读版本号（aapt2 dump badging），算 SHA-256 和大小，用 apksigner 确认签过名并打印证书指纹（和上一版
对一下：签名换了的话装着的 App 拒绝更新）。安装包要上传到 --url-base 下的同名文件；只认 thinktin.cn 和它的子域名。
"""
import argparse
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
from urllib.parse import urlparse


def build_tool(name):
    home = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if not home:
        sys.exit("设一下 ANDROID_HOME（要用 build-tools 里的 aapt2、apksigner）")
    found = sorted(glob.glob(os.path.join(home, "build-tools", "*", name)))
    if not found:
        sys.exit(f"build-tools 里没有 {name}")
    return found[-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("apk")
    parser.add_argument("--url-base", default="https://thinktin.cn/download/android/")
    parser.add_argument("--notes-zh", default="")
    parser.add_argument("--notes-en", default="")
    args = parser.parse_args()

    badging = subprocess.run(
        [build_tool("aapt2"), "dump", "badging", args.apk], check=True, capture_output=True, text=True
    ).stdout
    package = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging)
    if not package or package.group(1) != "cn.thinktin.app":
        sys.exit("不是 ThinkTin 的安装包")
    min_sdk = re.search(r"sdkVersion:'(\d+)'", badging)

    certs = subprocess.run(
        [build_tool("apksigner"), "verify", "--print-certs", args.apk], capture_output=True, text=True
    )
    if certs.returncode != 0:
        sys.exit("安装包没签名或签名不对：\n" + certs.stderr)
    for line in certs.stdout.splitlines():
        if "SHA-256" in line:
            print(line, file=sys.stderr)

    url = args.url_base.rstrip("/") + "/" + os.path.basename(args.apk)
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    if parsed.scheme != "https" or not (host == "thinktin.cn" or host.endswith(".thinktin.cn")):
        sys.exit("下载地址要是 https 的 thinktin.cn（或子域名），App 只认这些")

    with open(args.apk, "rb") as f:
        data = f.read()
    manifest = {
        "version_code": int(package.group(2)),
        "version_name": package.group(3),
        "apk_url": url,
        "sha256": hashlib.sha256(data).hexdigest(),
        "size": len(data),
        "min_sdk": int(min_sdk.group(1)) if min_sdk else 26,
        "notes": {"zh": args.notes_zh, "en": args.notes_en},
    }
    json.dump(manifest, sys.stdout, ensure_ascii=False, indent=2)
    print()


if __name__ == "__main__":
    main()
