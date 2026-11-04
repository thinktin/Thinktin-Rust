#!/usr/bin/env python3
"""从 Logo G1.0（docs/brand/logo）生成 Apple 端用的品牌素材。生成物提交进仓库，改 Logo 后重跑这个脚本。

    python3 tools/apple/brand_assets.py [--check]

生成：
- apps/apple/ThinktinKit/Sources/ThinktinUI/Design/BrandLogo+Geometry.swift
    Logo 的四条路径（圆弧按 ≤90° 一段转成三次贝塞尔），给 SwiftUI 的原生矢量 `BrandLogo` 用。
- apps/apple/Thinktin/Resources/Assets.xcassets/AppIcon.appiconset/
    iPhone 图标 1024：浅色（白底，不能有透明）、深色（透明底，罐体线条变浅色）、着色（透明底的白色单色）。
- apps/apple/ThinktinMac/Resources/Assets.xcassets/AppIcon.appiconset/
    Mac 图标 16～1024：macOS 的圆角方形白底（824/1024，带阴影），Logo 在里面。

渲染要 Pillow 和 resvg（pip install pillow resvg-py）；只生成 Swift 代码时（--swift-only）只用标准库。
--check：贝塞尔转换后的路径和原稿各渲染一次，比较像素（保证 Swift 里画出来的和原稿一致）。
"""
import argparse
import io
import json
import math
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../.."))
LOGO = os.path.join(ROOT, "docs/brand/logo")
SWIFT_OUT = os.path.join(ROOT, "apps/apple/ThinktinKit/Sources/ThinktinUI/Design/BrandLogo+Geometry.swift")
IOS_ICON = os.path.join(ROOT, "apps/apple/Thinktin/Resources/Assets.xcassets/AppIcon.appiconset")
MAC_ICON = os.path.join(ROOT, "apps/apple/ThinktinMac/Resources/Assets.xcassets/AppIcon.appiconset")

# 路径 id → Swift 里的名字和说明。
PATHS = {"B": ("body", "罐体"), "R": ("rim", "外罐口"), "I": ("innerRim", "内罐口"), "S": ("loop", "双圈线")}


def load_geometry() -> dict:
    with open(os.path.join(LOGO, "thinktin-geometry.json"), encoding="utf-8") as handle:
        return json.load(handle)


def arc_to_cubics(segment: dict) -> list[tuple]:
    """一段圆弧（圆心 c、半径 r、起始角 a0、扫角 da，y 向下）拆成 ≤90° 的几段，每段一条三次贝塞尔。"""
    cx, cy = segment["c"]
    r = segment["r"]
    a0 = segment["a0"]
    da = segment["da"]
    pieces = max(1, math.ceil(abs(da) / (math.pi / 2) - 1e-9))
    step = da / pieces
    k = 4.0 / 3.0 * math.tan(step / 4.0)
    curves = []
    for index in range(pieces):
        t1 = a0 + step * index
        t2 = t1 + step
        p0 = (cx + r * math.cos(t1), cy + r * math.sin(t1))
        p3 = (cx + r * math.cos(t2), cy + r * math.sin(t2))
        c1 = (p0[0] - k * r * math.sin(t1), p0[1] + k * r * math.cos(t1))
        c2 = (p3[0] + k * r * math.sin(t2), p3[1] - k * r * math.cos(t2))
        curves.append((c1, c2, p3))
    # 最后一个点用记录里的端点，免得浮点误差在接点上留缝。
    c1, c2, _ = curves[-1]
    curves[-1] = (c1, c2, tuple(segment["p1"]))
    return curves


def path_commands(path: dict) -> list[tuple]:
    """("move", p) / ("line", p) / ("curve", c1, c2, p)；closed 的路径最后 ("close",)。"""
    commands: list[tuple] = []
    for index, segment in enumerate(path["segments"]):
        if index == 0:
            commands.append(("move", tuple(segment["p0"])))
        if segment["type"] == "line":
            commands.append(("line", tuple(segment["p1"])))
        else:
            for c1, c2, p in arc_to_cubics(segment):
                commands.append(("curve", c1, c2, p))
    if path.get("closed"):
        commands.append(("close",))
    return commands


def content_bounds(geometry: dict) -> tuple[float, float, float, float]:
    """线条外缘的包围盒（中心线采样 + 半个线宽），给 App 里不带白边的 Logo 用。"""
    xs, ys = [], []
    for path in geometry["paths"]:
        half = path["stroke"] / 2
        for segment in path["segments"]:
            if segment["type"] == "line":
                points = [segment["p0"], segment["p1"]]
            else:
                cx, cy = segment["c"]
                points = [
                    (cx + segment["r"] * math.cos(segment["a0"] + segment["da"] * i / 32),
                     cy + segment["r"] * math.sin(segment["a0"] + segment["da"] * i / 32))
                    for i in range(33)
                ]
            for x, y in points:
                xs += [x - half, x + half]
                ys += [y - half, y + half]
    return (math.floor(min(xs)), math.floor(min(ys)), math.ceil(max(xs)), math.ceil(max(ys)))


def fmt(value: float) -> str:
    text = f"{value:.3f}".rstrip("0").rstrip(".")
    return text if text not in ("-0", "") else "0"


def swift_source(geometry: dict) -> str:
    min_x, min_y, max_x, max_y = content_bounds(geometry)
    gradient = geometry["gradient"]
    lines = [
        "// 自动生成，不要手改：tools/apple/brand_assets.py 从 docs/brand/logo/thinktin-geometry.json（Logo G1.0）生成。",
        "// 圆弧按 ≤90° 一段转成三次贝塞尔；坐标是 1000 × 1000 的画板单位（原点左上，y 向下）。",
        "import CoreGraphics",
        "",
        "extension BrandLogo {",
        "    /// 线条外缘的包围盒（画板单位）：App 里的 Logo 按它等比缩放、不带原稿的白边。",
        f"    static let contentBounds = CGRect(x: {min_x}, y: {min_y}, width: {max_x - min_x}, height: {max_y - min_y})",
        "",
        "    /// 双圈线的线性渐变：画板坐标的起止点和九个色标（sRGB）。",
        f"    static let gradientStart = CGPoint(x: {fmt(gradient['x1'])}, y: {fmt(gradient['y1'])})",
        f"    static let gradientEnd = CGPoint(x: {fmt(gradient['x2'])}, y: {fmt(gradient['y2'])})",
        "    static let gradientStops: [(location: Double, hex: UInt32)] = [",
    ]
    for location, color in gradient["stops"]:
        lines.append(f"        ({fmt(location)}, 0x{color.lstrip('#').upper()}),")
    lines += ["    ]", ""]
    for path in geometry["paths"]:
        name, label = PATHS[path["id"]]
        lines.append(f"    /// {label}（{path['id']}）：线宽 {fmt(path['stroke'])}。")
        lines.append(f"    static let {name}Width: CGFloat = {fmt(path['stroke'])}")
        lines.append(f"    static func {name}Path(_ path: inout BrandLogoPathBuilder) {{")
        for command in path_commands(path):
            if command[0] == "move":
                lines.append(f"        path.move({fmt(command[1][0])}, {fmt(command[1][1])})")
            elif command[0] == "line":
                lines.append(f"        path.line({fmt(command[1][0])}, {fmt(command[1][1])})")
            elif command[0] == "curve":
                _, c1, c2, p = command
                lines.append(
                    f"        path.curve({fmt(p[0])}, {fmt(p[1])}, {fmt(c1[0])}, {fmt(c1[1])}, {fmt(c2[0])}, {fmt(c2[1])})"
                )
            else:
                lines.append("        path.close()")
        lines += ["    }", ""]
    lines[-1] = "}"
    return "\n".join(lines) + "\n"


def bezier_svg(geometry: dict, stroke_color: str = "#000000") -> str:
    """把转换后的贝塞尔路径写成 SVG，和原稿对比用（--check）。"""
    gradient = geometry["gradient"]
    stops = "".join(f'<stop offset="{location}" stop-color="{color}"/>' for location, color in gradient["stops"])
    out = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1000" viewBox="0 0 1000 1000">',
        f'<defs><linearGradient id="g" gradientUnits="userSpaceOnUse" x1="{gradient["x1"]}" y1="{gradient["y1"]}" '
        f'x2="{gradient["x2"]}" y2="{gradient["y2"]}">{stops}</linearGradient></defs>',
        '<rect width="1000" height="1000" fill="#FFFFFF"/>',
    ]
    for path in geometry["paths"]:
        d = []
        for command in path_commands(path):
            if command[0] == "move":
                d.append(f"M {command[1][0]} {command[1][1]}")
            elif command[0] == "line":
                d.append(f"L {command[1][0]} {command[1][1]}")
            elif command[0] == "curve":
                _, c1, c2, p = command
                d.append(f"C {c1[0]} {c1[1]} {c2[0]} {c2[1]} {p[0]} {p[1]}")
            else:
                d.append("Z")
        stroke = "url(#g)" if path["id"] == "S" else stroke_color
        out.append(
            f'<path d="{" ".join(d)}" fill="none" stroke="{stroke}" stroke-width="{path["stroke"]}" '
            'stroke-linecap="round" stroke-linejoin="round"/>'
        )
    out.append("</svg>")
    return "\n".join(out)


# MARK: - 渲染

def master_svg(ink: str = "#000000", background: str | None = "#FFFFFF", loop_ink: str | None = None) -> str:
    """原稿 SVG 换颜色：罐体线条 ink，背景（None 时透明），双圈线 loop_ink（None 时保留渐变）。"""
    with open(os.path.join(LOGO, "thinktin-master-gradient.svg"), encoding="utf-8") as handle:
        svg = handle.read()
    svg = svg.replace('stroke="#000000"', f'stroke="{ink}"')
    if background is None:
        svg = re.sub(r'<rect width="1000" height="1000" fill="#FFFFFF"/>\n?', "", svg)
    else:
        svg = svg.replace('<rect width="1000" height="1000" fill="#FFFFFF"/>',
                          f'<rect width="1000" height="1000" fill="{background}"/>')
    if loop_ink is not None:
        svg = svg.replace('stroke="url(#thinktin-gradient)"', f'stroke="{loop_ink}"')
    return svg


def render(svg: str, size: int):
    import resvg_py
    from PIL import Image

    # 宽高按 mm 写的，渲染时直接给像素尺寸。
    svg = svg.replace('width="100mm" height="100mm"', f'width="{size}" height="{size}"')
    data = resvg_py.svg_to_bytes(svg_string=svg, width=size, height=size)
    return Image.open(io.BytesIO(bytes(data))).convert("RGBA")


def logo_tile(svg: str, size: int, fraction: float, bounds: tuple):
    """把 Logo 的内容区（不带白边）等比放大到 size 的 fraction，居中放在透明的 size × size 上。"""
    from PIL import Image

    min_x, min_y, max_x, max_y = bounds
    big = 4096  # 先按大尺寸渲染再缩，线条边缘更干净。
    image = render(svg, big)
    scale = big / 1000
    crop = image.crop((int(min_x * scale), int(min_y * scale), math.ceil(max_x * scale), math.ceil(max_y * scale)))
    target = fraction * size
    ratio = target / max(crop.width, crop.height)
    crop = crop.resize((max(1, round(crop.width * ratio)), max(1, round(crop.height * ratio))), Image.LANCZOS)
    tile = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    tile.alpha_composite(crop, ((size - crop.width) // 2, (size - crop.height) // 2))
    return tile


def write_ios_icons(bounds: tuple) -> None:
    from PIL import Image

    os.makedirs(IOS_ICON, exist_ok=True)
    size = 1024
    # 浅色：白底、不透明（App Store 不收带透明的图标）。Logo 内容高约 72%，留出系统圆角的余量。
    light = Image.new("RGBA", (size, size), (255, 255, 255, 255))
    light.alpha_composite(logo_tile(master_svg(background=None), size, 0.72, bounds))
    light.convert("RGB").save(os.path.join(IOS_ICON, "AppIcon.png"), optimize=True)
    # 深色：透明底（系统铺深色底），罐体线条换成浅色，双圈保留渐变。
    logo_tile(master_svg(ink="#F2F2F7", background=None), size, 0.72, bounds).save(
        os.path.join(IOS_ICON, "AppIcon-dark.png"), optimize=True)
    # 着色：系统按亮度上色，给透明底的白色单色。
    logo_tile(master_svg(ink="#FFFFFF", background=None, loop_ink="#FFFFFF"), size, 0.72, bounds).save(
        os.path.join(IOS_ICON, "AppIcon-tinted.png"), optimize=True)
    contents = {
        "images": [
            {"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": "AppIcon-dark.png",
             "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "tinted"}], "filename": "AppIcon-tinted.png",
             "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        ],
        "info": {"author": "xcode", "version": 1},
    }
    with open(os.path.join(IOS_ICON, "Contents.json"), "w", encoding="utf-8") as handle:
        json.dump(contents, handle, indent=2)
        handle.write("\n")


def mac_icon_master(bounds: tuple):
    """macOS 的图标要自己画外形：1024 画布上 824 × 824 的圆角方形（圆角约 185），白底、轻阴影，Logo 在里面。"""
    from PIL import Image, ImageDraw, ImageFilter

    size = 1024
    body = 824
    offset = (size - body) // 2
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [offset, offset + 12, offset + body, offset + body + 12], radius=185, fill=(0, 0, 0, 70))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14)))
    plate = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(plate).rounded_rectangle([offset, offset, offset + body, offset + body], radius=185,
                                            fill=(255, 255, 255, 255))
    canvas.alpha_composite(plate)
    logo = logo_tile(master_svg(background=None), body, 0.74, bounds)
    canvas.alpha_composite(logo, (offset, offset))
    return canvas


def write_mac_icons(bounds: tuple) -> None:
    from PIL import Image

    os.makedirs(MAC_ICON, exist_ok=True)
    master = mac_icon_master(bounds)
    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            master.resize((pixels, pixels), Image.LANCZOS).save(os.path.join(MAC_ICON, name), optimize=True)
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
    with open(os.path.join(MAC_ICON, "Contents.json"), "w", encoding="utf-8") as handle:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, handle, indent=2)
        handle.write("\n")


def check(geometry: dict) -> int:
    """贝塞尔版和原稿各渲染一次，比较像素差。"""
    from PIL import ImageChops

    original = render(master_svg(), 1000)
    converted = render(bezier_svg(geometry), 1000)
    diff = ImageChops.difference(original.convert("RGB"), converted.convert("RGB")).convert("L")
    histogram = diff.histogram()
    total = sum(histogram)
    over = sum(histogram[33:])
    worst = max(i for i, count in enumerate(histogram) if count)
    print(f"贝塞尔版 vs 原稿（1000 px）：最大差 {worst}/255，差超过 32 的像素 {over}/{total}")
    return 0 if over <= total * 0.0005 else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--check", action="store_true", help="只检查贝塞尔转换和原稿的像素差")
    parser.add_argument("--swift-only", action="store_true", help="只生成 Swift 代码（不渲染图标）")
    args = parser.parse_args()
    geometry = load_geometry()
    if args.check:
        return check(geometry)
    with open(SWIFT_OUT, "w", encoding="utf-8") as handle:
        handle.write(swift_source(geometry))
    print(f"写了 {os.path.relpath(SWIFT_OUT, ROOT)}")
    if args.swift_only:
        return 0
    bounds = content_bounds(geometry)
    write_ios_icons(bounds)
    write_mac_icons(bounds)
    print(f"写了 {os.path.relpath(IOS_ICON, ROOT)} 和 {os.path.relpath(MAC_ICON, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
