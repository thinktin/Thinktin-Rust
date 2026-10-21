"""按 index.html 里实际用到的字符裁剪字体，输出 fonts/*.woff2。

改了片中文字后重新运行：python3 fonts.py
源字体（Google Fonts，OFL 许可）首次运行时下载到 .cache/fonts/。
依赖：pip install fonttools brotli
"""

import pathlib
import string
import urllib.request

from fontTools import subset

HERE = pathlib.Path(__file__).resolve().parent
CACHE = HERE / ".cache" / "fonts"
OUT = HERE / "fonts"

SOURCES = {
    "NotoSansSC-400": "https://fonts.gstatic.com/s/notosanssc/v41/k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYw.ttf",
    "NotoSansSC-700": "https://fonts.gstatic.com/s/notosanssc/v41/k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaGzjCnYw.ttf",
    "NotoSansSC-900": "https://fonts.gstatic.com/s/notosanssc/v41/k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG3bCnYw.ttf",
    "Inter-400": "https://fonts.gstatic.com/s/inter/v20/UcCO3FwrK3iLTeHuS_nVMrMxCp50SjIw2boKoduKmMEVuLyfMZg.ttf",
    "Inter-600": "https://fonts.gstatic.com/s/inter/v20/UcCO3FwrK3iLTeHuS_nVMrMxCp50SjIw2boKoduKmMEVuGKYMZg.ttf",
    "Inter-800": "https://fonts.gstatic.com/s/inter/v20/UcCO3FwrK3iLTeHuS_nVMrMxCp50SjIw2boKoduKmMEVuDyYMZg.ttf",
    "JetBrainsMono-500": "https://fonts.gstatic.com/s/jetbrainsmono/v24/tDbY2o-flEEny0FZhsfKu5WU4zr3E_BX0PnT8RD8-qxjPQ.ttf",
}


def used_text() -> str:
    html = (HERE / "index.html").read_text(encoding="utf-8")
    extra = {c for c in html if ord(c) > 0x7F}
    return string.printable + "".join(sorted(extra))


def fetch(name: str) -> pathlib.Path:
    path = CACHE / f"{name}.ttf"
    if not path.exists():
        CACHE.mkdir(parents=True, exist_ok=True)
        print(f"下载 {name}")
        urllib.request.urlretrieve(SOURCES[name], path)
    return path


def main() -> None:
    OUT.mkdir(exist_ok=True)
    text = used_text()
    for name in SOURCES:
        options = subset.Options()
        options.flavor = "woff2"
        options.layout_features = ["*"]
        options.name_IDs = ["*"]
        options.notdef_outline = True
        font = subset.load_font(str(fetch(name)), options)
        subsetter = subset.Subsetter(options)
        subsetter.populate(text=text)
        subsetter.subset(font)
        target = OUT / f"{name}.woff2"
        subset.save_font(font, str(target), options)
        print(f"{target.name}: {target.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
