#!/usr/bin/env python3
"""查二进制里用到的“需要声明理由的 API”有没有在隐私清单里声明（WBS 12.11，docs/ios-appstore.md 第 3 节）。

App Store Connect 按上传的二进制里的符号检查（ITMS-91053），Rust 的 client-core 也算在内：
  scan.py --manifest apps/apple/Thinktin/Resources/PrivacyInfo.xcprivacy target/apple/sim/libclient_core.a Thinktin.app/Thinktin

对每个文件跑 `nm -u`（ELF 的共享库加 -D），按苹果的清单把符号归到 API 类别，用到了却没声明的类别报错退出 1。
符号表见 https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
（只列能从符号认出来的 C 函数和 Objective-C 类；Swift / Foundation 的属性名不在符号表里，靠代码评审）。
"""
import argparse
import re
import plistlib
import subprocess
import sys

FILE_TIMESTAMP = "NSPrivacyAccessedAPICategoryFileTimestamp"
BOOT_TIME = "NSPrivacyAccessedAPICategorySystemBootTime"
DISK_SPACE = "NSPrivacyAccessedAPICategoryDiskSpace"
KEYBOARDS = "NSPrivacyAccessedAPICategoryActiveKeyboards"
USER_DEFAULTS = "NSPrivacyAccessedAPICategoryUserDefaults"

# 符号 → 可能的类别（getattrlist 一类既能读文件时间也能读磁盘空间：声明了其中一个就算）。
SYMBOLS = {
    "stat": {FILE_TIMESTAMP},
    "fstat": {FILE_TIMESTAMP},
    "fstatat": {FILE_TIMESTAMP},
    "lstat": {FILE_TIMESTAMP},
    "getattrlist": {FILE_TIMESTAMP, DISK_SPACE},
    "getattrlistbulk": {FILE_TIMESTAMP},
    "fgetattrlist": {FILE_TIMESTAMP, DISK_SPACE},
    "getattrlistat": {FILE_TIMESTAMP, DISK_SPACE},
    "mach_absolute_time": {BOOT_TIME},
    "statfs": {DISK_SPACE},
    "statvfs": {DISK_SPACE},
    "fstatfs": {DISK_SPACE},
    "fstatvfs": {DISK_SPACE},
    "OBJC_CLASS_$_NSUserDefaults": {USER_DEFAULTS},
    "OBJC_CLASS_$_UITextInputMode": {KEYBOARDS},
}


def normalize(symbol: str) -> str:
    """Mach-O 的 C 符号带前导下划线，有的带 `$INODE64` 之类的后缀；ELF 的带 `@GLIBC_2.x` 版本。"""
    name = symbol.split("@", 1)[0].lstrip("_")
    if not name.startswith("OBJC_CLASS_$_"):
        name = name.split("$", 1)[0]
    if name.endswith("64") and name[:-2]:
        name = name[:-2]
    # glibc 的 stat 家族：__xstat、__fxstat、__lxstat、__fxstatat（Linux 上自测用，Apple 上没有）。
    glibc = re.fullmatch(r"([fl]?)xstat(at)?", name)
    if glibc:
        name = glibc.group(1) + "stat" + (glibc.group(2) or "")
    return name


def undefined_symbols(path: str) -> set:
    args = ["nm", "-u", path]
    with open(path, "rb") as f:
        magic = f.read(4)
    if magic == b"\x7fELF" and path.endswith(".so"):
        args = ["nm", "-D", "--undefined-only", path]
    out = subprocess.run(args, check=True, capture_output=True, text=True).stdout
    symbols = set()
    for line in out.splitlines():
        parts = line.split()
        if parts and not line.endswith(":"):
            symbols.add(parts[-1])
    return symbols


def declared_categories(manifest: str) -> set:
    with open(manifest, "rb") as f:
        data = plistlib.load(f)
    return {entry["NSPrivacyAccessedAPIType"] for entry in data.get("NSPrivacyAccessedAPITypes", [])}


def check(symbols_by_file: dict, declared: set) -> list:
    """返回没声明的用法：(文件, 符号, 可能的类别)。"""
    problems = []
    for path, symbols in symbols_by_file.items():
        for symbol in sorted(symbols):
            categories = SYMBOLS.get(normalize(symbol))
            if categories and not (categories & declared):
                problems.append((path, symbol, sorted(categories)))
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("binaries", nargs="+")
    args = parser.parse_args()
    declared = declared_categories(args.manifest)
    symbols = {path: undefined_symbols(path) for path in args.binaries}
    used = {
        category
        for found in symbols.values()
        for symbol in found
        for category in SYMBOLS.get(normalize(symbol), set())
    }
    print("声明了：" + ", ".join(sorted(declared)))
    print("用到了（可能）：" + ", ".join(sorted(used)))
    problems = check(symbols, declared)
    for path, symbol, categories in problems:
        print(f"::error::{path} 用了 {symbol}，隐私清单里没有声明 {' 或 '.join(categories)}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
