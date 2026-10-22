#!/usr/bin/env python3
"""第三方许可证清单和许可证策略检查（WBS 16.5，说明见 docs/licenses.md）。

只用标准库（Python 3.11 以上），在模板镜像里、CI 主机上、Rust 的构建镜像里都能跑。

  scan     扫描装好的 npm 包、Python 包、Debian 包（模板镜像构建时在镜像里跑），
           把许可证、NOTICE 原文复制到输出目录，写清单 inventory.json 和索引 NOTICES.md
  cargo    按 cargo metadata 列出几个程序实际依赖的 crate，同样复制原文、写清单
  upstream-cargo  按 deploy/templates/notices/<agent>/sources.toml 的 [[cargo]]，从上游源码生成上游程序的 crate 清单
  check    按策略（tools/licenses/policy.toml）检查清单：禁止的许可证、没登记的专有或认不出的许可证、
           声明和原文对不上、没登记的字体、清单里 agent 的许可证和上游对不上
  summary  几个清单的汇总（组件数、非用不可的 copyleft 组件），docs/licenses.md 第 7 节用
  self-test  内置测试

输出目录（模板镜像里是 /usr/share/thinktin/licenses）：
  inventory.json   每个组件一条：生态、名字、版本、许可证（SPDX 表达式）、原文的位置
  NOTICES.md       人看的索引：按许可证汇总、每个组件的许可证和原文位置
  texts/by-hash/<哈希>/  复制来的 LICENSE、NOTICE 原文，按内容存（Debian 包的原文就在 /usr/share/doc/<包>/copyright）
  texts/spdx/      包里没带原文的组件用的 SPDX 标准文本
"""

import sys

if sys.version_info < (3, 11):
    # macOS 自带的 python3 是 3.9：给个明白的提示，不要一个 tomllib 的 ImportError。
    sys.exit("tools/licenses/licenses.py 要 Python 3.11 以上（用到 tomllib），现在是 %d.%d" % sys.version_info[:2])

import argparse
import email.parser
import fnmatch
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import tomllib
import unicodedata
from pathlib import Path

SCHEMA = 2
MAX_TEXT_BYTES = 1 << 20  # 单个原文文件的上限，超过的只记路径不复制
SCAN_MAX_BYTES = 16 << 20  # 找限制性说法、禁止名单许可证时读的上限；更大的文件要人看
MAX_ANNOTATIONS = 30
# 包里没带原文的组件，用 SPDX 的标准文本（spdx/ 下，取自 spdx/license-list-data v3.29.0），加上元数据里的作者。
SPDX_DIR = Path(__file__).resolve().with_name("spdx")
NODE_LICENSE_URL = "https://raw.githubusercontent.com/nodejs/node/v%s/LICENSE"

# ---------------------------------------------------------------------------
# SPDX 表达式

_TOKEN = re.compile(r"\s*(\(|\)|[A-Za-z0-9.+:_-]+)")
_OPS = {"AND", "OR", "WITH"}


class SpdxError(ValueError):
    pass


def parse_spdx(text):
    """解析 SPDX 表达式，返回语法树：("id", 名字) / ("with", 名字, 例外) / ("and" | "or", [子树...])。

    运算符不分大小写（npm 上有人写小写的 `and`、`or`）。语法不对时抛 SpdxError。
    """
    tokens, pos = [], 0
    text = text.strip()
    while pos < len(text):
        m = _TOKEN.match(text, pos)
        if not m:
            raise SpdxError("无法解析的字符：%r" % text[pos:])
        tokens.append(m.group(1))
        pos = m.end()
    if not tokens:
        raise SpdxError("空表达式")
    i = 0

    def peek():
        return tokens[i].upper() if i < len(tokens) else None

    def take():
        nonlocal i
        i += 1
        return tokens[i - 1]

    def expr_or():
        items = [expr_and()]
        while peek() == "OR":
            take()
            items.append(expr_and())
        return items[0] if len(items) == 1 else ("or", items)

    def expr_and():
        items = [expr_with()]
        while peek() == "AND":
            take()
            items.append(expr_with())
        return items[0] if len(items) == 1 else ("and", items)

    def expr_with():
        node = atom()
        if peek() == "WITH":
            take()
            if peek() in (None, "(", ")") or peek() in _OPS:
                raise SpdxError("WITH 后面要跟例外的名字")
            if node[0] != "id":
                raise SpdxError("WITH 只能跟在单个许可证后面")
            node = ("with", node[1], take())
        return node

    def atom():
        tok = peek()
        if tok is None:
            raise SpdxError("表达式不完整")
        if tok == "(":
            take()
            node = expr_or()
            if peek() != ")":
                raise SpdxError("括号不配对")
            take()
            return node
        if tok == ")" or tok in _OPS:
            raise SpdxError("这里应该是许可证名字：%s" % tokens[i])
        return ("id", take())

    tree = expr_or()
    if i != len(tokens):
        raise SpdxError("多余的内容：%s" % " ".join(tokens[i:]))
    return tree


def render_spdx(tree, top=True):
    kind = tree[0]
    if kind == "id":
        return tree[1]
    if kind == "with":
        return "%s WITH %s" % (tree[1], tree[2])
    joined = (" %s " % kind.upper()).join(render_spdx(t, False) for t in tree[1])
    return joined if top else "(%s)" % joined


def spdx_ids(tree):
    if tree[0] in ("id", "with"):
        return [tree[1]]
    return [x for t in tree[1] for x in spdx_ids(t)]


def _load_ids(name):
    try:
        lines = (SPDX_DIR / name).read_text(encoding="utf-8").splitlines()
    except OSError:
        return set()
    return {line.strip() for line in lines if line.strip() and not line.startswith("#")}


# SPDX 的全部许可证标识和例外标识（spdx/license-ids.txt、exception-ids.txt，取自 license-list-data v3.29.0）。
# 不在这两张表里、也不是 LicenseRef- / AdditionRef- 的词不算 SPDX：“MIT License”“Commons-Clause”这类按自由文本处理。
LICENSE_IDS = _load_ids("license-ids.txt")
EXCEPTION_IDS = _load_ids("exception-ids.txt")
_CANONICAL = {x.upper(): x for x in LICENSE_IDS}
_CANONICAL_EXC = {x.upper(): x for x in EXCEPTION_IDS}
_LICENSE_REF = re.compile(r"^(DocumentRef-[A-Za-z0-9.-]+:)?LicenseRef-[A-Za-z0-9.-]+$")
_ADDITION_REF = re.compile(r"^(DocumentRef-[A-Za-z0-9.-]+:)?AdditionRef-[A-Za-z0-9.-]+$")


def _canonical_id(x):
    """SPDX 许可证标识的官方写法（`GPL-2.0+` 这种带 + 的也认）；不是标识返回 None。"""
    if _LICENSE_REF.match(x):
        return x
    if x.upper() in _CANONICAL:
        return _CANONICAL[x.upper()]
    if x.endswith("+") and x[:-1].upper() in _CANONICAL:
        return _CANONICAL[x[:-1].upper()] + "+"
    return None


def _canonical_exception(x):
    if _ADDITION_REF.match(x):
        return x
    return _CANONICAL_EXC.get(x.upper())


def _canonical_tree(tree):
    if tree[0] == "id":
        lid = _canonical_id(tree[1])
        return ("id", lid) if lid else None
    if tree[0] == "with":
        lid, exc = _canonical_id(tree[1]), _canonical_exception(tree[2])
        return ("with", lid, exc) if lid and exc else None
    kids = [_canonical_tree(t) for t in tree[1]]
    return (tree[0], kids) if all(kids) else None


def is_spdx(text):
    return canonical_spdx(text) is not None


def canonical_spdx(text):
    """合法的 SPDX 表达式统一写法（标识按官方大小写、运算符大写）；语法不对、或有不在 SPDX 表里的标识，返回 None。"""
    try:
        tree = _canonical_tree(parse_spdx(text))
    except SpdxError:
        return None
    return render_spdx(tree) if tree else None


# 常见的非 SPDX 写法 → SPDX（键是小写、去掉多余空白后的文本）。
FREE_TEXT = {
    "mit license": "MIT",
    "the mit license": "MIT",
    "mit licence": "MIT",
    "mit/x11": "MIT",
    "expat": "MIT",
    "mit-style": "MIT",
    "apache 2.0": "Apache-2.0",
    "apache 2": "Apache-2.0",
    "apache-2": "Apache-2.0",
    "apache2": "Apache-2.0",
    "apache license 2.0": "Apache-2.0",
    "apache license, version 2.0": "Apache-2.0",
    "apache license version 2.0": "Apache-2.0",
    "apache software license": "Apache-2.0",
    "apache software license 2.0": "Apache-2.0",
    "asl 2.0": "Apache-2.0",
    "apache": "Apache-2.0",  # 不写版本的“Apache”（sqlite-vec 的 "MIT OR Apache"）；Apache 1.x 早就没人用了
    "bsd": "LicenseRef-BSD-Unspecified",
    "bsd license": "LicenseRef-BSD-Unspecified",
    "bsd-style": "LicenseRef-BSD-Unspecified",
    "new bsd": "BSD-3-Clause",
    "new bsd license": "BSD-3-Clause",
    "modified bsd license": "BSD-3-Clause",
    "3-clause bsd": "BSD-3-Clause",
    "3-clause bsd license": "BSD-3-Clause",
    "bsd 3-clause": "BSD-3-Clause",
    "bsd-3": "BSD-3-Clause",
    "simplified bsd": "BSD-2-Clause",
    "2-clause bsd": "BSD-2-Clause",
    "bsd 2-clause": "BSD-2-Clause",
    "bsd-2": "BSD-2-Clause",
    "isc license": "ISC",
    "isc license (iscl)": "ISC",
    "iscl": "ISC",
    "revised bsd": "BSD-3-Clause",
    "bsd (3-clause)": "BSD-3-Clause",
    "bsd (2-clause)": "BSD-2-Clause",
    "apache license v2.0": "Apache-2.0",
    "apache license v2": "Apache-2.0",
    "apache license (2.0)": "Apache-2.0",
    "cc0 1.0 universal": "CC0-1.0",
    "zpl 2.1": "ZPL-2.1",
    "gnu lgpl": "LicenseRef-LGPL-Unspecified",
    "gnu gpl": "LicenseRef-GPL-Unspecified",
    "psf": "PSF-2.0",
    "psfl": "PSF-2.0",
    "psf license": "PSF-2.0",
    "python software foundation license": "PSF-2.0",
    "mpl 2.0": "MPL-2.0",
    "mpl-2": "MPL-2.0",
    "mozilla public license 2.0": "MPL-2.0",
    "mozilla public license 2.0 (mpl 2.0)": "MPL-2.0",
    "public domain": "LicenseRef-Public-Domain",
    "the unlicense": "Unlicense",
    "the unlicense (unlicense)": "Unlicense",
    "unlicensed": "LicenseRef-Unlicensed",
    "cc0": "CC0-1.0",
    "cc0 1.0": "CC0-1.0",
    "zlib/libpng": "Zlib",
    "boost": "BSL-1.0",
    "boost software license 1.0": "BSL-1.0",
    "lgpl": "LicenseRef-LGPL-Unspecified",
    "gpl": "LicenseRef-GPL-Unspecified",
    "agpl": "LicenseRef-AGPL-Unspecified",
    "proprietary": "LicenseRef-Proprietary",
    "commercial": "LicenseRef-Proprietary",
    "all rights reserved": "LicenseRef-Proprietary",
}

# PyPI 的 License 分类（Classifier: License :: ...）的最后一段 → SPDX。
CLASSIFIERS = {
    "mit license": "MIT",
    "mit no attribution license (mit-0)": "MIT-0",
    "apache software license": "Apache-2.0",
    "bsd license": "LicenseRef-BSD-Unspecified",
    "isc license (iscl)": "ISC",
    "python software foundation license": "PSF-2.0",
    "mozilla public license 2.0 (mpl 2.0)": "MPL-2.0",
    "mozilla public license 1.1 (mpl 1.1)": "MPL-1.1",
    "the unlicense (unlicense)": "Unlicense",
    "cc0 1.0 universal (cc0 1.0) public domain dedication": "CC0-1.0",
    "public domain": "LicenseRef-Public-Domain",
    "zope public license": "ZPL-2.1",
    "eclipse public license 2.0 (epl-2.0)": "EPL-2.0",
    "eclipse public license 1.0 (epl-1.0)": "EPL-1.0",
    "boost software license 1.0 (bsl-1.0)": "BSL-1.0",
    "universal permissive license (upl)": "UPL-1.0",
    "historical permission notice and disclaimer (hpnd)": "HPND",
    "artistic license": "Artistic-2.0",
    "academic free license (afl)": "AFL-3.0",
    "european union public licence 1.2 (eupl 1.2)": "EUPL-1.2",
    "european union public licence 1.1 (eupl 1.1)": "EUPL-1.1",
    "server side public license (sspl)": "SSPL-1.0",
    "gnu affero general public license v3": "AGPL-3.0-only",
    "gnu affero general public license v3 or later (agplv3+)": "AGPL-3.0-or-later",
    "gnu general public license v2 (gplv2)": "GPL-2.0-only",
    "gnu general public license v2 or later (gplv2+)": "GPL-2.0-or-later",
    "gnu general public license v3 (gplv3)": "GPL-3.0-only",
    "gnu general public license v3 or later (gplv3+)": "GPL-3.0-or-later",
    "gnu general public license (gpl)": "LicenseRef-GPL-Unspecified",
    "gnu lesser general public license v2 (lgplv2)": "LGPL-2.0-only",
    "gnu lesser general public license v2 or later (lgplv2+)": "LGPL-2.0-or-later",
    "gnu lesser general public license v3 (lgplv3)": "LGPL-3.0-only",
    "gnu lesser general public license v3 or later (lgplv3+)": "LGPL-3.0-or-later",
    "gnu library or lesser general public license (lgpl)": "LicenseRef-LGPL-Unspecified",
    "other/proprietary license": "LicenseRef-Proprietary",
    "freeware": "LicenseRef-Proprietary",
    "free for non-commercial use": "LicenseRef-NonCommercial",
}


def _norm_text(s):
    return re.sub(r"\s+", " ", s).strip().lower()


def normalize_declared(text):
    """把元数据里声明的许可证文本变成 SPDX 表达式；认不出返回 None。

    依次试：合法的 SPDX 表达式、Cargo 的旧写法 `MIT/Apache-2.0`、常见的自由文本写法。
    """
    if not text or not text.strip():
        return None
    text = text.strip()
    if text.startswith("(") and text.endswith(")") and "(" not in text[1:]:
        text = text[1:-1].strip()
    key = _norm_text(text).rstrip(".")
    if key in FREE_TEXT:
        return FREE_TEXT[key]
    c = canonical_spdx(text)
    if c:
        return c
    # GNU、MPL 的简写：LGPLv3、LGPL v2.1+、GPL-3 or later、MPLv2、MPL v2.0
    m = re.fullmatch(r"(?:gnu\s+)?(a|l)?gpl[\s-]*v?(\d)(?:\.(\d))?(\+|\s+or\s+later)?", key)
    if m:
        lid = "%sGPL-%s.%s-%s" % ((m.group(1) or "").upper(), m.group(2), m.group(3) or "0", "or-later" if m.group(4) else "only")
        return lid if lid in LICENSE_IDS else None
    m = re.fullmatch(r"mpl[\s-]*v?(\d)(?:\.(\d))?", key)
    if m:
        lid = "MPL-%s.%s" % (m.group(1), m.group(2) or "0")
        return lid if lid in LICENSE_IDS else None
    # 结尾多一个 License（“BSD 3-Clause License”“Expat license”“Apache-2.0 license”）
    m = re.fullmatch(r"(.+?)\s+licen[cs]e", key)
    if m and normalize_declared(m.group(1)):
        return normalize_declared(m.group(1))
    # 括号里是同一个许可证的别名（“Expat (MIT/X11)”“ISC License (ISCL)”）；括号里是别的话（“MIT (non-commercial use
    # only)”）不认
    m = re.fullmatch(r"(.+?)\s*\(([^()]+)\)", text)
    if m:
        outer, inner = normalize_declared(m.group(1)), normalize_declared(m.group(2))
        if outer and outer == inner:
            return outer
    if "/" in text:  # Cargo 早期用 / 表示“任选其一”：`MIT/Apache-2.0`、`Apache-2.0 / MIT`
        c = canonical_spdx(" OR ".join(p.strip() for p in text.split("/")))
        if c:
            return c
    # “MIT OR Apache 2.0”这类混写：逐段换成 SPDX 再试一次。
    parts = re.split(r"\s+(and|or)\s+", text, flags=re.I)
    if len(parts) > 1:
        out = []
        for j, p in enumerate(parts):
            if j % 2:
                out.append(p.upper())
                continue
            sub = normalize_declared(p)
            if not sub:
                return None
            out.append("(%s)" % sub if " " in sub else sub)
        return canonical_spdx(" ".join(out))
    return None


# 从原文识别许可证，分两步：
# 1. 提名：按许可证正文开头的标题（只看开头 TITLE_WINDOW 个字符），或者授权条款里固定的句子，猜是哪个许可证；
# 2. 核对：整个文件要和这个许可证的 SPDX 标准文本（tools/licenses/spdx/<标识>.txt）或标准头部声明（_HEADERS）
#    逐词对得上（_aligns）。多出来的往往正是附加的限制条款、专有声明、EULA，缺了的可能正是授权的那几个词，
#    所以容差按位置算：
#    - 标准文本的占位处（<year>、<copyright holders>、BSD 第三条的组织名）可以换成名字，一处最多 VERIFY_FILL_WORDS 个词；
#    - 别处多出来的词一段不超过 VERIFY_EXTRA_RUN 个、加起来不超过 VERIFY_EXTRA_WORDS 个（标题、SPDX 标识行这些
#      无害的词不算）；多出来的词里有限制性的说法（not、only、commercial……）或者非拉丁字母的文字（中文、俄文的
#      附加条款）就对不上；
#    - 标准文本里缺的词一段不超过 VERIFY_MISSING_RUN 个、加起来不超过 VERIFY_MISSING（比例）；缺的是授权的词
#      （use、copy、distribute……）就对不上。可以省的部分（附录、“How to Apply”、Exhibit）整段缺也行；
#    - 版权行只去掉版权声明本身（“Copyright (c) 2024 Acme Inc.”），同一行后面别的话照常核对。
#    对不上就算认不出，要人登记。
# 提名用的说法都是许可证正文里固定的句子，正文里顺带提到的别的许可证（MPL-2.0 定义“次级许可证”时提到 AGPL）不算。
# 一份原文可能被几条规则提名（X11 也含 MIT 的授权句），按规则顺序逐个核对，第一个对得上的算数；
# 都对不上时记第一个提名。禁止名单里那些许可证的正文标题、声明在文件里任何位置出现都记下来（_DENY_SECTIONS），
# 检查时和包的声明对照：合并成一个文件的第三方许可清单里，AGPL 的那一段可能在很后面。
TITLE_WINDOW = 300
VERIFY_EXTRA_WORDS = 8
VERIFY_EXTRA_RUN = 5
VERIFY_FILL_WORDS = 10
VERIFY_MISSING_RUN = 6
VERIFY_MISSING = 0.03
VERIFY_MISSING_MIN = 8
VERIFY_MAX_CHARS = 200000  # 比这长的原文不核对（不会是一份许可证）：截断核对会漏掉后面附加的条款
NOTICE_MAX_WORDS = 16
_TITLE_RULES = [
    ("MPL-2.0", ["mozilla public license", "2.0"]),
    ("MPL-1.1", ["mozilla public license", "version 1.1"]),
    ("SSPL-1.0", ["server side public license"]),
    ("BUSL-1.1", ["business source license"]),
    ("Elastic-2.0", ["elastic license 2.0"]),
    ("PolyForm-Noncommercial-1.0.0", ["polyform noncommercial license"]),
    ("AGPL-3.0-only", ["gnu affero general public license"]),
    ("AGPL-1.0-only", ["affero general public license", "!gnu affero"]),  # 2002 年 Affero 公司的第 1 版，标题没有 GNU
    ("EUPL-1.1", ["european union public licen", "1.1"]),
    ("EUPL-1.2", ["european union public licen"]),
    ("OSL-3.0", ["open software license"]),
    ("RPL-1.5", ["reciprocal public license"]),
    ("CPAL-1.0", ["common public attribution license"]),
    ("GFDL-1.3-only", ["gnu free documentation license", "version 1.3"]),
    ("GFDL-1.2-only", ["gnu free documentation license", "version 1.2"]),
    ("GFDL-1.1-only", ["gnu free documentation license", "version 1.1"]),
    ("LGPL-2.1-only", ["gnu lesser general public license", "version 2.1"]),
    ("LGPL-3.0-only", ["gnu lesser general public license"]),
    ("LGPL-2.0-only", ["gnu library general public license"]),
    ("GPL-3.0-only", ["gnu general public license", "version 3"]),
    ("GPL-2.0-only", ["gnu general public license", "version 2"]),
    ("EPL-2.0", ["eclipse public license", "2.0"]),
    ("EPL-1.0", ["eclipse public license", "1.0"]),
    ("CDDL-1.1", ["common development and distribution license", "version 1.1"]),
    ("CDDL-1.0", ["common development and distribution license"]),
    ("Apache-2.0", ["apache license", "version 2.0"]),
    ("Apache-1.1", ["apache software license, version 1.1"]),
    ("OFL-1.1", ["sil open font license", "version 1.1"]),
    ("BSD-3-Clause-Clear", ["the clear bsd license"]),
    ("WTFPL", ["do what the fuck you want to public license"]),
    ("BlueOak-1.0.0", ["blue oak model license"]),
    ("BSL-1.0", ["boost software license"]),
    ("Artistic-2.0", ["the artistic license 2.0"]),
    ("CC0-1.0", ["cc0 1.0 universal"]),
    ("CC-BY-4.0", ["creative commons attribution 4.0 international"]),
    ("Unicode-3.0", ["unicode license v3"]),
    ("PSF-2.0", ["python software foundation license"]),
    ("CC-BY-3.0", ["creative commons", "attribution 3.0"]),
    ("CDLA-Permissive-2.0", ["community data license agreement", "permissive", "2.0"]),
    ("Unicode-DFS-2016", ["unicode, inc. license agreement - data files and software"]),
    ("FSL-1.1-MIT", ["functional source license", "mit future license"]),
    ("FSL-1.1-ALv2", ["functional source license"]),
]
# 只有许可证正文自己才有的标题（带版本和日期），文件任何位置出现都算按标题提名：GPL 原文前面有好几段说明
# （Linux、git、libgit2 的 COPYING），标题就不在开头。
_HEADINGS = [
    ("GPL-3.0-only", ["gnu general public license version 3, 29 june 2007"]),
    ("GPL-2.0-only", ["gnu general public license version 2, june 1991"]),
    ("LGPL-3.0-only", ["gnu lesser general public license version 3, 29 june 2007"]),
    ("LGPL-2.1-only", ["gnu lesser general public license version 2.1, february 1999"]),
    ("LGPL-2.0-only", ["gnu library general public license version 2, june 1991"]),
    ("GFDL-1.3-only", ["gnu free documentation license version 1.3, 3 november 2008"]),
    ("GFDL-1.2-only", ["gnu free documentation license version 1.2, november 2002"]),
    ("GFDL-1.1-only", ["gnu free documentation license version 1.1, march 2000"]),
    # CPython 发布的 LICENSE：PSF 的协议加上 BeOpen、CNRI 1.6.1、CWI 的历史协议（SPDX 的 Python-2.0.1）。
    ("Python-2.0.1", ["python software foundation license", "cnri license agreement for python 1.6.1"]),
]
# Creative Commons 的标题：Attribution[-NonCommercial][-ShareAlike|-NoDerivatives] <版本>，creativecommons.org
# 发的 legalcode.txt 开头就是这一行（“Attribution 4.0 International”），前面没有“Creative Commons”。
_CC_TITLE = re.compile(r"\battribution((?:-(?:noncommercial|sharealike|noderivatives|noderivs)){0,2}) ([1-4]\.[05])\b")
_CC_PARTS = {"noncommercial": "-NC", "sharealike": "-SA", "noderivatives": "-ND", "noderivs": "-ND"}
_GRANT_MIT = "permission is hereby granted, free of charge, to any person obtaining a copy"
_BODY_RULES = [
    ("Apache-2.0", ["licensed under the apache license, version 2.0"]),
    ("MPL-2.0", ["subject to the terms of the mozilla public license, v. 2.0"]),
    ("AGPL-3.0-only", ["under the terms of the gnu affero general public license"]),
    ("LicenseRef-LGPL-Unspecified", ["under the terms of the gnu lesser general public license"]),
    ("LicenseRef-GPL-Unspecified", ["under the terms of the gnu general public license"]),
    ("Unlicense", ["this is free and unencumbered software released into the public domain"]),
    # Python 本身的许可证是 PSF 的协议再加 BeOpen、CNRI、CWI 三份历史协议。
    ("Python-2.0", ["python software foundation license", "beopen.com license agreement for python 2.0"]),
    ("PSF-2.0", ["python software foundation license agreement"]),
    ("Zlib", ["this software is provided 'as-is', without any express or implied warranty",
              "altered source versions must be plainly marked as such"]),
    # OFL 的授权句和 MIT 的开头一样（“Permission is hereby granted, free of charge, to any person obtaining a copy of
    # the Font Software”）：标题不在开头时也先认 OFL。
    ("OFL-1.1", ["sil open font license", "permission is hereby granted, free of charge, to any person obtaining a copy of the font software"]),
    # 先认含 MIT 授权句的特殊许可证：JSON（“用于善不用于恶”，有使用限制）、Unicode 的数据文件许可。
    ("JSON", [_GRANT_MIT, "shall be used for good, not evil"]),
    ("Unicode-DFS-2016", [_GRANT_MIT, "unicode data files"]),
    # MIT-0 要正面认：有授权句，但没有“须保留版权和许可声明”那一条件。
    ("MIT-0", [_GRANT_MIT, "!subject to the following condition", "!shall be included"]),
    ("X11", [_GRANT_MIT, "except as contained in this notice, the name of"]),
    ("MIT", [_GRANT_MIT]),
    ("curl", ["permission to use, copy, modify, and distribute this software for any purpose with or without fee",
              "except as contained in this notice, the name of a copyright holder"]),
    ("ISC", ["permission to use, copy, modify, and/or distribute this software for any purpose", "provided that the above copyright notice"]),
    ("ISC", ["permission to use, copy, modify, and distribute this software for any purpose", "provided that the above copyright notice"]),
    ("0BSD", ["permission to use, copy, modify, and/or distribute this software for any purpose"]),
    # HPND 和 MIT-CMU 很像，MIT-CMU 多一段开头（“By obtaining, using, and/or copying …”），短的先核对。
    ("HPND", ["permission to use, copy, modify", "for any purpose and without fee is hereby granted"]),
    ("MIT-CMU", ["permission to use, copy, modify", "for any purpose and without fee is hereby granted"]),
    # BSD 一族：Sleepycat（要求公开源码）、带广告条款的 BSD-4 都含 BSD-3 的句子，先认它们。
    ("Sleepycat", ["redistribution and use in source and binary forms", "information on how to obtain complete source code"]),
    ("BSD-4-Clause", ["redistribution and use in source and binary forms", "all advertising materials mentioning features"]),
    ("BSD-3-Clause-Clear", ["redistribution and use in source and binary forms",
                            "no express or implied licenses to any party's patent rights are granted"]),
    ("BSD-3-Clause", ["redistribution and use in source and binary forms", "endorse or promote products"]),
    ("BSD-1-Clause", ["redistribution and use in source and binary forms", "!redistributions in binary form"]),
    ("BSD-2-Clause", ["redistribution and use in source and binary forms"]),
]
# 禁止名单里的许可证：正文的标题和“按某许可证授权”的固定声明，在文件任何位置出现都记下（不只开头）。
# 只用这些许可证自己的正文才有的句子：GPL-3 第 13 条（“licensed under version 3 of the GNU Affero …”）、MPL-2.0 的
# “次级许可证”提到 AGPL 的说法不算。另外 “License: AGPL-3.0-only”“SPDX-License-Identifier: …”这种行（打包工具生成的
# 第三方清单里每个依赖一行）按声明认（_license_lines）。
_DENY_SECTIONS = [
    ("AGPL-3.0-only", ["gnu affero general public license version 3, 19 november 2007"]),
    ("AGPL-3.0-only", ["under the gnu affero general public license"]),
    ("AGPL-3.0-only", ["under the terms of the gnu affero general public license"]),
    ("AGPL-3.0-only", ["users interacting with it remotely through a computer network"]),
    ("AGPL-3.0-only", ["under the agpl"]),
    ("AGPL-1.0-only", ["affero general public license version 1, march 2002"]),
    ("AGPL-1.0-only", ["any user interacting with the program was given the opportunity to request transmission"]),
    ("SSPL-1.0", ["server side public license version 1"]),
    ("EUPL-1.2", ["european union public licence v. 1."]),
    ("EUPL-1.2", ["licensed under the eupl"]),
    ("OSL-3.0", ['this open software license (the "license") applies']),
    ("RPL-1.5", ["reciprocal public license (rpl)"]),
    ("CPAL-1.0", ["common public attribution license version 1.0"]),
]


# 只有一段“按某许可证授权”头部声明的许可证文件（常见于 Apache-2.0、MPL-2.0）：按标准头部核对。
_HEADERS = {
    "Apache-2.0": (
        'Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance '
        "with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0 Unless "
        "required by applicable law or agreed to in writing, software distributed under the License is distributed on an "
        '"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the '
        "specific language governing permissions and limitations under the License."
    ),
    "MPL-2.0": (
        "This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not "
        "distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/."
    ),
}
# 许可证官方发布的文件里有、SPDX 标准文本里没有的固定句子：核对前去掉（只去一字不差的这几句，网址只认官方的；
# 句子里的空格可以是任何空白，折行不同也认）。
_PREAMBLES = {
    "OFL-1.1": [r"This Font Software is licensed under the SIL Open Font License,? Version 1\.1[.,]?\s+This license is copied "
                r"below, and is also available with a FAQ at:?\s+<?https?://(?:scripts\.sil\.org/OFL|openfontlicense\.org)/?>?(?=\s|$)"],
    "CC0-1.0": [r"For more information, please see\s+<?https?://creativecommons\.org/publicdomain/zero/1\.0/?>?"],
    # creativecommons.org 发的 legalcode.txt：说明里两个 wiki 地址、最后声明里的一句
    "CC-BY-4.0": [r"(?<=\s)wiki\.creativecommons\.org/Considerations_for_licens(?:ors|ees)(?=\s)",
                  r"The\s+text\s+of\s+the\s+Creative\s+Commons\s+public\s+licenses\s+is\s+dedicated\s+to\s+the\s+public\s+domain\s+"
                  r"under\s+the\s+CC0\s+Public\s+Domain\s+Dedication\."],
}
# 标准文本里可以省的部分（附录、“How to Apply”、Exhibit、CC 的说明和免责声明）：(从这一句, 到这一句之前)，
# 到结尾的写 None。
_OPTIONAL_SPANS = {
    "Apache-2.0": [("END OF TERMS AND CONDITIONS", None)],
    "GPL-2.0-only": [("END OF TERMS AND CONDITIONS", None)],
    "GPL-3.0-only": [("END OF TERMS AND CONDITIONS", None)],
    "LGPL-2.0-only": [("END OF TERMS AND CONDITIONS", None)],
    "LGPL-2.1-only": [("END OF TERMS AND CONDITIONS", None)],
    # SPDX 的 LGPL-3.0 文本后面附了整篇 GPL-3.0；单独发的 COPYING.LESSER 没有。
    "LGPL-3.0-only": [("GNU GENERAL PUBLIC LICENSE", None)],
    "MPL-2.0": [("Exhibit A - Source Code Form License Notice", None)],
    "EPL-2.0": [("Exhibit A – Form of Secondary Licenses Notice", None)],
    "CC-BY-3.0": [("Creative Commons Notice", None)],
    "CC-BY-4.0": [("Creative Commons is not a party", None)],
    "CC0-1.0": [("CREATIVE COMMONS CORPORATION IS NOT A LAW FIRM", "Statement of Purpose")],
}
# 官方发布的文件比 SPDX 标准文本多出来的开头、结尾（可以有、可以没有，有的话照常核对）：CPython 的 LICENSE 开头的
# 历史说明（spdx/Python-2.0.1.history，取自 CPython 3.14 的 LICENSE）、结尾文档里代码的 0BSD 许可。
_OPTIONAL_HEAD_FILES = {"Python-2.0.1": "Python-2.0.1.history"}
_OPTIONAL_TAIL_FILES = {"Python-2.0.1": ("ZERO-CLAUSE BSD LICENSE FOR CODE IN THE PYTHON DOCUMENTATION\n\n", "0BSD.txt")}
# GNU 发布的 GPL-2.0 原文最后一段，SPDX 的标准文本里没有（在可以省的部分里）。
_OPTIONAL_TAIL = {
    "GPL-2.0-only": "This General Public License does not permit incorporating your program into proprietary programs. "
                    "If your program is a subroutine library, you may consider it more useful to permit linking proprietary "
                    "applications with the library. If this is what you want to do, use the GNU Lesser General Public "
                    "License instead of this License.",
}
# SPDX 的模板里标成可变、纯文本版里却写成默认值的地方：换成占位，名字换了也对得上。
_BSD_SLOTS = [("THE COPYRIGHT HOLDERS AND CONTRIBUTORS", "<copyright holders and contributors>"),
              ("THE COPYRIGHT HOLDER OR CONTRIBUTORS", "<copyright holder or contributors>")]
# 标准文本的另一种常见写法（核对时也认）：BSD-3 第三条写成“The name of the author may not be used to endorse …”，
# 主语是占位（换成名字），后面一字不差。
_TEMPLATE_VARIANTS = {
    "BSD-3-Clause": [("Neither the name of <copyright holder> nor the names of its contributors may be used", "<name> may not be used")],
}
_TEMPLATE_SLOTS = {
    "BSD-3-Clause": [("Neither the name of the copyright holder nor", "Neither the name of <copyright holder> nor")] + _BSD_SLOTS,
    "BSD-2-Clause": _BSD_SLOTS,
    "BSD-1-Clause": _BSD_SLOTS,
    "MIT": [("THE AUTHORS OR COPYRIGHT HOLDERS", "<copyright holders>")],
}
# GNU 的 GPL-2.0、LGPL-2.x 里自由软件基金会的地址：各版本不一样（59 Temple Place、51 Franklin Street，现在的原文
# 换成了 <https://fsf.org/> 和“see <https://www.gnu.org/licenses/>”），当占位。
_FSF_ADDRESS = (r"51\s+Franklin\s+St(?:reet)?,\s*Fifth\s+Floor,\s*"
                r"Boston,\s*MA\s+02110-1301,?\s+USA", "<fsf address>")
_TEMPLATE_SLOT_RES = {"GPL-2.0-only": [_FSF_ADDRESS], "LGPL-2.0-only": [_FSF_ADDRESS], "LGPL-2.1-only": [_FSF_ADDRESS]}
# 版权声明：Copyright (c) …、Copyright 2024 …、Copyright Acme Inc.、© …、(c) 2024 …（区分大小写），前面可以有一两个词
# （Portions、Modified work、Digitized data copyright (c) …）。条款编号“(c) You must retain …”、正文里的
# “COPYRIGHT HOLDERS AND CONTRIBUTORS”“copyright protection”“WIPO Copyright Treaty”不算。
_NOTICE_START = re.compile(
    r"^\s*(?:<program>\s+)?(?:[A-Z][a-z]+(?:\s+[a-z]+)?\s+)?(?:"
    r"(?:[Cc]opyright|COPYRIGHT)\s*(?:\([cC]\)|©|\d|[<\[{])"
    r"|Copyright\s+(?!(?:Holders?|Owners?|Notices?|Act|Laws?|Licen[cs]es?|Agent|Office|Statement|Policy|Protection|Treaty|Treaties|"
    r"Conventions?)\b)[A-Z]|Copyright\s+[a-z][\w.-]*,?\s+(?:Inc|LLC|Ltd|GmbH|Corp)\b"
    r"|©|\([cC]\)\s*(?:\d|[Cc]opyright\b)|SPDX-FileCopyrightText:)"
)
# OFL 的版权行常把“with Reserved Font Name …”折到下一行：这一行也算版权声明。
_RFN = re.compile(r"^\s*(?:and\s+)?with\s+reserved\s+font\s+names?\b", re.I)
# 版权行里常跟着的商标声明（字体：“Source is a trademark of Adobe …”）：和版权声明一起去掉。
_TRADEMARK = re.compile(r"\b(?:is|are)\s+(?:a\s+|the\s+)?(?:registered\s+)?trademarks?\s+(?:of|owned\s+by)\b", re.I)
# 断句：句号后面是大写字母；名字里的缩写（Nathaniel J. Smith、Isaac Z. Schlueter）不断开。
_SENTENCE_END = re.compile(r"(?<![\s(.,][A-Z]\.)(?<=[.!?])\s+(?=[A-Z]|[^\x00-\x7f])|(?<=[;:])\s+")
# 版权声明里的邮箱、网址（scheme 和主机名；路径照常看）：christian@cjohansen.no 的 no 不是限制性的词。
_EMAIL_URL = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+|(?:https?://|www\.)[\w-]+(?:\.[\w-]+)+")
# 占位写法：<year>、<copyright holders>、[yyyy]。尖括号里的网址、邮箱是正文；Markdown 链接 [x](…) 也是。
_PLACEHOLDER = re.compile(r"<(?!\s*(?:https?://|mailto:|www\.)|[^<>\s]+@)[^<>\n]{1,60}>|\[(?![^\]\n]*\]\()[^\[\]\n]{1,40}\]")
_SLOT = "qqslotqq"
# 多出来的词里有这些，说明加了条件或限制：对不上。
_LIMITING = set(
    "not no non only solely exclusively except excluding exclude excludes unless never cannot prohibit prohibits "
    "prohibited prohibition forbid forbids forbidden restrict restricts restricted restriction restrictions restrictive "
    "limit limits limited limitation limitations personal personally internal internally evaluation evaluate trial "
    "commercial commercially noncommercial paid pay payment fee fees subscription subscriptions subscriber purchase "
    "purchased purchaser customer customers revoke revoked revocable revocation terminate terminated termination void "
    "agreement agreements eula proprietary confidential must require requires required obtain".split()
)
# 加条件的常见说法里的词（“Redistribution needs written approval”“Resale disallowed”“production deployments”）：
# 许可证标准文本里多出来这些词也算限制性的。真实的许可证文件里从来不多出这些词（语料里核对过）。
# 常是名字一部分的（Research、Enterprise、Production）不在这里：多出来的整句话、授权句里多出来的词另有规则。
_CONDITION_WORDS = set(
    "need needs needed approval approvals approve approved consents barred disallow disallowed disallows resale resell "
    "reseller resellers seat seats deployment deployments hosted saas employees contractors".split()
)
_LIMITING |= _CONDITION_WORDS
# 讲使用、复制、分发的词：标准文本已经授了权，文件里多出来这些词就是对使用加的条件（“For academic research use”）。
# 真实的许可证文件里从来不多出这些词（语料里核对过；单复数不同、行尾拆开的不算多出来）。
_USAGE_WORDS = set(
    "use used uses using usage copy copies modify distribute distributed redistribute redistributed redistribution "
    "redistributions sell sold sublicense sublicensed permission permitted granted grant grants reproduce publish merge".split()
)
# copyleft、限制性许可证的名字：标准文本里没提到的、文件里多出来的（“Licensed under the GNU Affero …”）算限制性的。
_COPYLEFT_NAMES = set("gnu gpl lgpl agpl affero copyleft eupl sspl busl".split())
# 版权声明里出现这些，就不当成版权声明去掉（照常核对）：版权行里藏的限制。公司名常带的 Limited 不算。
# 加条件的说法里的词（_CONDITION_WORDS）在版权声明里按 _NOTICE_CLAUSE 看（Nous Research、Manufacturing Consent 是名字）。
_NOTICE_LIMITING = _LIMITING - _CONDITION_WORDS - {"limited", "limit", "limits"} | {"may", "shall", "subject", "terms"}
# 讲授权、使用条件的词：版权声明里只有名字、年份、邮箱，有这些词的是条款（“Copyright 2024 Foo, licensed for academic
# research …”），不当版权声明去掉。_NOTICE_NAMEABLE 里的也常是名字的一部分（Nous Research、Public Sans、Pydantic
# Services），只有小写时才算。
_NOTICE_CLAUSE = set(
    "license licenses licence licences licensed licensing licensee licensees licensor sublicense sublicensed use used using "
    "usage user users grant grants granted permission permissions permitted permit permits allow allows allowed disallowed "
    "distribute distributed distributing distribution redistribute redistributed redistributing redistribution sell sold "
    "selling resale resell reselling copies approval approve approved consent written agree agreed accept accepted condition "
    "conditions provided purpose purposes deploy deployed deployment deployments hosted hosting embed embedded embedding "
    "install installed installation seat seats need needs needed separately separate employees contractors under eula gnu gpl "
    "lgpl agpl affero charge price buy bought valid research academic educational public free service services program "
    "general key keys production university universities enterprise enterprises military government governments".split()
) | _CONDITION_WORDS
_NOTICE_NAMEABLE = set("research academic educational public free service services program general key keys production "
                       "university universities consent enterprise enterprises government governments grant".split())
# 标准文本里缺了这些词就对不上：授权的范围被删了。
_GRANT_WORDS = set(
    "use copy modify merge publish distribute sublicense sell redistribute redistribution redistributions permission "
    "permitted granted grant grants hereby royalty perpetual irrevocable worldwide reproduce derivative".split()
)
# 授权的那几句（标准文本里有 hereby、grant、granted、permitted 的句子，“Permission is hereby granted …”“Redistribution
# and use … are permitted provided that …”）：缺了、多了实词都对不上（授权的范围被改了：Apache 删掉 make、have made、
# import，加上“for academic research”）。虚词、网址、单个字母不算。
_GRANT_SENTENCE = re.compile(r"[^\s.:;](?:(?!\n\s*\n)[^.:;])*?\b(?:hereby|grants?|granted|permitted)\b(?:(?!\n\s*\n)[^.:;])*", re.I)
_GRANT_MARK, _GRANT_STOP = "qqgrantqq", "qqgrantendqq"
_FUNCTION_WORDS = set("a an the and or of to in on at by for with as well is are be any all each this that these those such its "
                      "it their them you your http https www com org".split())
# 句子结束（. ! ? ; 后面是空白）：核对时记下文件里哪些词后面句子结束了，多出来一整句话（“Resale disallowed.”）就看得出来。
_SENT_END = re.compile(r"(?<=[^\W_])[.!?;](?=\s|$)")
_END = "qqendqq"
# 核对时文件里可以多出来的“无害”的词：标题、SPDX 标识行、“All rights reserved”。
_BENIGN_WORDS = set(
    "the a an and or of license licence licensed mit x11 expat isc bsd new simplified modified clause apache version v "
    "spdx identifier all rights reserved software".split()
)


def _fold_table():
    """_fold 用的替换表：长得和拉丁字母一样的西里尔、希腊字母，拉丁字母的小型大写（ᴏ ɪ ꜱ）、无点的 ı 这些，和不显示的
    格式字符（BOM、软连字符、零宽空格……，直接去掉）。小写的像拉丁字母的，大写也换（І：先 fold 再 lower 也不漏）；
    只有大写像的（В、Н、Т）小写不换，整个词都是西里尔字母的照样算外文。"""
    lower = dict(zip("аеорсухіјѕԁһүӏԛԝοαειινρτυχϲϳıȷᴀʙᴄᴅᴇꜰɢʜɪᴊᴋʟᴍɴᴏᴘʀꜱᴛᴜᴠᴡʏᴢɑɡɩ",
                     "aeopcyxijsdhylqwoaeiivptuxcjijabcdefghijklmnoprstuvwyzagi"))
    upper = dict(zip("АВЕКМНОРСТХΑΒΕΖΗΙΚΜΝΟΡΤΥΧӀ", "ABEKMHOPCTXABEZHIKMNOPTYXI"))
    table = {ord(s): d for s, d in list(upper.items()) + list(lower.items())}
    for s, d in lower.items():
        if len(s.upper()) == 1 and not s.upper().isascii():
            table.setdefault(ord(s.upper()), d.upper())
    for c in list(range(0x10000)) + list(range(0xE0000, 0xE0080)):
        if unicodedata.category(chr(c)) == "Cf":
            table[c] = None
    return table


_FOLD = _fold_table()
# 没有分解形式的拉丁字母：换成最接近的 ASCII（Søren、Łukasz、Straße 这样的名字里有）。
_LATIN_EXTRA = str.maketrans({"ß": "ss", "æ": "ae", "Æ": "AE", "ø": "o", "Ø": "O", "œ": "oe", "Œ": "OE", "đ": "d", "Đ": "D",
                              "ł": "l", "Ł": "L", "þ": "th", "Þ": "Th", "ð": "d", "Ð": "D", "ħ": "h", "Ħ": "H", "ŋ": "ng",
                              "Ŋ": "Ng", "ĸ": "k", "ə": "e", "Ə": "E"})
_CJK = r"぀-ヿ㐀-䶿一-鿿가-힯豈-﫿"


def _fold(text):
    """NFKC（全角字母、连字 ﬀ 换成普通字母），按 _FOLD 换掉长得像拉丁字母的字母、去掉格式字符，再去掉拉丁字母的附加符号。"""
    return _deaccent(unicodedata.normalize("NFKC", text).translate(_FOLD))


_DEACCENTED = {}


def _deaccent_char(c):
    out = _DEACCENTED.get(c)
    if out is None:
        out = c
        if "LATIN" in unicodedata.name(c, ""):
            out = "".join(ch for ch in unicodedata.normalize("NFKD", c) if not unicodedata.combining(ch)).translate(_LATIN_EXTRA)
        _DEACCENTED[c] = out
    return out


def _deaccent(text):
    """带附加符号的拉丁字母换成不带的（commercíal、COMMERCİAL、Marchán → commercial、COMMERCIAL、Marchan），没有分解形式的
    换成最接近的（ł → l、ß → ss）。别的文字（中文、俄文）不动。"""
    if text.isascii():
        return text
    table = {ord(c): _deaccent_char(c) for c in set(text) if ord(c) > 127}
    text = text.translate({k: v for k, v in table.items() if v != chr(k)})
    return re.sub(r"(?<=[A-Za-z])[\u0300-\u036f]+", "", text)


def _matches(t, needles):
    for n in needles:
        if n.startswith("!"):
            if n[1:] in t:
                return False
        elif n not in t:
            return False
    return True


def _strip_comments(text):
    return "\n".join(re.sub(r"^\s*(?://+|#+|;+|--+|>+|/?\*+/?)\s?", "", line) for line in text.splitlines())


def _normalized(text, limit=8000):
    """提名、找禁止名单许可证用的文本：小写、空白合成一个，去掉注释前缀和 Markdown 的格式（**粗体**、# 标题、
    _强调_、`代码`、===== 和 ----- 下划线）。"""
    t = _strip_comments(_fold(text[:limit] if limit else text))
    t = re.sub(r"[_=~`]+|-{2,}", " ", t.replace("*", "").replace("#", ""))
    return _norm_text(t).replace("“", '"').replace("”", '"').replace("’", "'")


# 打包工具生成的第三方清单里每个依赖一行的许可证（rollup / vite 的 “License: MIT”、源文件头的 SPDX-License-Identifier）。
# 只在一行之内匹配（[ \t]，不用 \s）：很长的分隔线、空白不会让正则来回回溯。
_LICENSE_LINE = re.compile(r"(?im)^[ \t*#/>-]*(?:SPDX-License-Identifier|Licen[cs]es?(?:[ \t]+type)?)[ \t]*[:=][ \t]*\**[ \t]*"
                           r"([^\n]+?)[ \t]*\**[ \t]*$")
# 禁止名单那一类许可证（网络 copyleft、限制商用或托管）：文件任何位置提到都要记下的。policy.toml 的 deny 加了新的一类，
# 这里也要加（内置测试会查）。
_DENY_CLASS = re.compile(r"^(?:LicenseRef-)?(?:AGPL|SSPL|OSL|EUPL|RPL|CPAL|BUSL|Elastic|PolyForm|FSL|CC-BY-NC|Commons-Clause|"
                         r"NonCommercial)", re.I)


def _license_lines(text):
    """“License: X”“SPDX-License-Identifier: X”行里认得出的、禁止名单那一类的许可证。"""
    out = []
    for m in _LICENSE_LINE.finditer(text):
        value = m.group(1).strip().strip("\"'`,;.")
        if len(value) > 120 or not re.search(r"(?i)agpl|affero|sspl|osl|eupl|rpl|cpal|bus|elastic|polyform|fsl|nc|commons", value):
            continue
        expr = normalize_declared(value) or CLASSIFIERS.get(_norm_text(value))
        if expr:
            try:
                out += [i for i in spdx_ids(parse_spdx(expr)) if _DENY_CLASS.match(i)]
            except SpdxError:
                pass
    return out


def _proposals(text, full=None):
    """(提名列表, 按标题提名的集合)：开头的标题（_TITLE_RULES、Creative Commons 的标题），文件任何位置的正文标题
    （_HEADINGS），再是开头 8000 个字符里的固定句子（_BODY_RULES）。full 是整个文件的 _normalized（算过的话）。"""
    t = _normalized(text)
    heads = [t[:TITLE_WINDOW]]
    # 开头的版权声明很长（字体常列好几个版权方）时，标题会被挤出窗口：跳过开头的版权行再看一次。
    lines = text[:20000].splitlines()
    i = 0
    while i < len(lines) and (not lines[i].strip() or _NOTICE_START.match(_fold(lines[i])) or _RFN.match(_fold(lines[i]))):
        i += 1
    if i:
        heads.append(_normalized("\n".join(lines[i:]), limit=TITLE_WINDOW * 4)[:TITLE_WINDOW])
    titled = [spdx for spdx, needles in _TITLE_RULES if any(_matches(head, needles) for head in heads)]
    for head in heads:
        if "creative commons" in head:
            for m in _CC_TITLE.finditer(head):
                lid = "CC-BY%s-%s" % ("".join(_CC_PARTS[p] for p in m.group(1).split("-")[1:]), m.group(2))
                if lid in LICENSE_IDS:
                    titled.append(lid)
    full = _normalized(text, limit=None) if full is None else full
    titled += [spdx for spdx, needles in _HEADINGS if _matches(full, needles)]
    out = titled + [spdx for spdx, needles in _BODY_RULES if _matches(t, needles)]
    return list(dict.fromkeys(out)), set(titled)


def candidates(text):
    """按标题或固定句子猜原文可能是哪些许可证（没核对过），按规则顺序。"""
    return _proposals(text)[0]


def deny_sections(text, full=None):
    """文件里任何位置出现的禁止名单许可证的正文标题、授权声明（_DENY_SECTIONS），和“License: X”行里禁止名单那一类的
    许可证。"""
    t = _normalized(text, limit=None) if full is None else full
    found = [spdx for spdx, needles in _DENY_SECTIONS if _matches(t, needles)]
    return list(dict.fromkeys(found + _license_lines(text)))


def propose(text):
    """第一个提名（没核对过）；猜不出返回 None。"""
    found = candidates(text)
    return found[0] if found else None


def _tokens(text):
    out = []
    for w in re.findall(r"[^\W_]+", text.lower().replace("'", "").replace("’", "")):
        if w.isascii():
            out.append(w)
        else:
            # 汉字、假名、韩文不用空格分词：一个字算一个词
            out += re.findall(r"[%s]|[^%s]+" % (_CJK, _CJK), w)
    return out


def _foreign(w):
    """非拉丁字母的词（中文、俄文……）：许可证标准文本都是英文，多出来的这种词多半是附加条款。词已经过 _fold
    （带附加符号的拉丁字母、长得像拉丁字母的字母都换成了 ASCII），还剩非 ASCII 的字母就算。"""
    return not w.isascii() and any(ch.isalpha() for ch in w)


def _is_plain_notice(s, template=False):
    """这一句只是版权声明（名字、年份、邮箱）：名字最多 NOTICE_MAX_WORDS 个词，没有限制性的说法、讲授权和使用条件的词、
    非拉丁字母的文字。占位去掉（文件里只去标准文本里有的占位，别的尖括号、方括号里的字照常看），邮箱和网址的主机名
    去掉；限制性的说法在网址的路径里也算，讲授权的词在网址里不算（https://angular.dev/license、github.com/x/public-sans）。"""
    s = (_PLACEHOLDER if template else _known_placeholder()).sub(" ", s).replace("'", "").replace("’", "")
    words = _tokens(_EMAIL_URL.sub(" ", s))
    names = [w for w in words if not w.isdigit() and w not in _BENIGN_WORDS and w not in ("c", "copyright")]
    if len(names) > NOTICE_MAX_WORDS or any(w in _NOTICE_LIMITING or _foreign(w) for w in words):
        return False
    outside_urls = re.findall(r"[^\W_]+", re.sub(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+|(?:https?://|www\.)\S+|\b[\w.-]+\.(?:com|org|net|io|dev)/\S*",
                                                 " ", s))
    return not any(w.lower() in _NOTICE_CLAUSE and (w.lower() not in _NOTICE_NAMEABLE or w.islower()) for w in outside_urls)


def _drop_notices(line, template=False):
    """版权行：去掉版权声明本身，同一行后面别的话留着照常核对。版权声明里有限制性的说法、讲授权和使用条件的词
    （“Copyright 2024 Acme: you may only …”“Copyright 2024 Acme, licensed for academic research …”）或者太长，就不当版权
    声明，整句照常核对。"""
    keep = []
    for s in _SENTENCE_END.split(line):
        notice = _NOTICE_START.match(s) or _RFN.match(s) or _TRADEMARK.search(s)
        if not (notice and _is_plain_notice(s, template)):
            keep.append(s)
    return " ".join(keep)


def _known_placeholders():
    found = set()
    for path in SPDX_DIR.glob("*.txt"):
        found.update(m.group(0) for m in _PLACEHOLDER.finditer(path.read_text(encoding="utf-8")))
    for pairs in _TEMPLATE_SLOTS.values():
        for _, new in pairs:
            found.update(m.group(0) for m in _PLACEHOLDER.finditer(new))
    found = sorted(found, key=len, reverse=True)
    return re.compile("|".join(re.escape(p) for p in found), re.I) if found else None


_KNOWN_PLACEHOLDER = None


def _known_placeholder():
    global _KNOWN_PLACEHOLDER
    if _KNOWN_PLACEHOLDER is None:
        _KNOWN_PLACEHOLDER = _known_placeholders() or re.compile(r"(?!)")
    return _KNOWN_PLACEHOLDER


def _words(text, template=False, ends=None):
    """核对用的词（小写；占位处是 _SLOT）：去掉注释前缀和版权声明。标准文本里的占位写法都是占位；文件里只有
    标准文本里出现过的占位写法（GNU 原文里的 <year>、Apache 附录的 [yyyy]）算占位，别的尖括号里的字照常核对。
    ends（集合）：后面句子结束了的词的下标。"""
    text = _strip_comments(_fold(text).replace("\r", ""))
    text = "\n".join(_drop_notices(line, template) if _NOTICE_START.match(line) or _RFN.match(line) else line
                     for line in text.splitlines())
    text = (_PLACEHOLDER if template else _known_placeholder()).sub(" %s " % _SLOT, text)
    if ends is None:
        return _tokens(text)
    out = []
    for w in _tokens(_SENT_END.sub(" %s " % _END, text)):
        if w == _END:
            if out:
                ends.add(len(out) - 1)
        else:
            out.append(w)
    return out


_TEMPLATES = {}


def _template_words(lid):
    """lid 的标准文本（和标准头部）：[(词, 可以省的词的下标集合, 授权的句子里的词的下标集合)]。"""
    if lid not in _TEMPLATES:
        out = []
        path = SPDX_DIR / ("%s.txt" % lid)
        if path.is_file():
            text = path.read_text(encoding="utf-8")
            for old, new in _TEMPLATE_SLOTS.get(lid, []):
                text = text.replace(old, new)
            for pat, new in _TEMPLATE_SLOT_RES.get(lid, []):
                text = re.sub(pat, new, text)
            for variant in [text] + [text.replace(a, b) for a, b in _TEMPLATE_VARIANTS.get(lid, []) if a in text]:
                out.append(_template_parts(lid, variant))
        if lid in _HEADERS:
            out.append(_mark_grants(_words(_grant_marked(_HEADERS[lid]), template=True), set()))
        _TEMPLATES[lid] = out
    return _TEMPLATES[lid]


def _template_parts(lid, text):
    """一份标准文本的 (词, 可以省的词的下标, 授权的句子里的词的下标)：按可以省的部分（_OPTIONAL_SPANS、开头结尾）切开。"""
    parts, pos = [], 0
    for start, end in _OPTIONAL_SPANS.get(lid, []):
        a = text.find(start, max(pos, 1))
        b = text.find(end, a) if end and a >= 0 else len(text)
        if a < 0 or b < 0:
            raise SystemExit("spdx/%s.txt 里找不到可以省的部分（%s）" % (lid, start))
        parts += [(text[pos:a], False), (text[a:b], True)]
        pos = b
    tail = _OPTIONAL_TAIL.get(lid, "")
    if lid in _OPTIONAL_TAIL_FILES:
        prefix, name = _OPTIONAL_TAIL_FILES[lid]
        tail += prefix + (SPDX_DIR / name).read_text(encoding="utf-8")
    head = (SPDX_DIR / _OPTIONAL_HEAD_FILES[lid]).read_text(encoding="utf-8") if lid in _OPTIONAL_HEAD_FILES else ""
    parts = [(head, True)] + parts + [(text[pos:], False), (tail, True)]
    words, optional = [], set()
    for part, opt in parts:
        w = _words(_grant_marked(part), template=True)
        if opt:
            optional.update(range(len(words), len(words) + len(w)))
        words += w
    return _mark_grants(words, optional)


def _mark_grants(words, optional):
    """去掉 _GRANT_MARK、_GRANT_STOP，返回 (词, 可以省的下标, 授权的句子里的词的下标)。"""
    out, opt, grant, inside = [], set(), set(), False
    for i, w in enumerate(words):
        if w in (_GRANT_MARK, _GRANT_STOP):
            inside = w == _GRANT_MARK
            continue
        if i in optional:
            opt.add(len(out))
        if inside:
            grant.add(len(out))
        out.append(w)
    return out, opt, grant


def _grant_marked(text):
    """标准文本里授权的句子前后加上标记（_template_parts、_HEADERS 用）。"""
    return _GRANT_SENTENCE.sub(lambda m: " %s %s %s " % (_GRANT_MARK, m.group(0), _GRANT_STOP), text)


def _content(w):
    """实词：不是虚词、网址、单个字母、数字。"""
    return len(w) > 1 and not w.isdigit() and w not in _FUNCTION_WORDS and w not in _BENIGN_WORDS


def _aligns(got, want, optional, grant=frozenset(), ends=frozenset()):
    """文件的词 got 和标准文本的词 want 逐段对照（见上面的说明）。grant：标准文本里授权的句子的词的下标；ends：文件里
    后面句子结束了的词的下标。"""
    import difflib

    sm = difflib.SequenceMatcher(None, got, want, autojunk=False)
    required = sum(1 for i, w in enumerate(want) if w != _SLOT and i not in optional and not w.isdigit())
    vocabulary = set(want)
    names = _COPYLEFT_NAMES - vocabulary
    extra_total = missing_total = 0
    pa = pb = 0
    for b in sm.get_matching_blocks():
        gap = range(pb, b.b)
        extras = [w for w in got[pa:b.a] if w != _SLOT and w not in _BENIGN_WORDS and not w.isdigit()]
        missing = [want[i] for i in gap if want[i] != _SLOT and i not in optional and not want[i].isdigit()]
        joined, need = "".join(extras), "".join(missing)
        if extras and missing and (joined == need or joined + "s" == need or joined == need + "s"):
            # 同一个词拆开、连起来写（行尾连字符 dis-/tribute、non-exclusive 和 nonexclusive），单复数不同
            pa, pb = b.a + b.size, b.b + b.size
            continue
        if any(w in _LIMITING or w in _USAGE_WORDS or w in names or _foreign(w) for w in extras):
            return False
        # 授权的句子里缺了实词、多了实词：授权的范围被改了
        in_grant = any(i in grant for i in gap) or (pb - 1 in grant and pb in grant)
        if any(i in grant and want[i] != _SLOT and i not in optional and _content(want[i]) for i in gap):
            return False
        if in_grant and any(_content(w) and w not in vocabulary for w in extras) and not any(want[i] == _SLOT for i in gap):
            return False
        # 多出来一整句话（前一个词后面句子结束，多出来的词里又有句子结束、有实词，标准文本这里什么也没缺）：附加的条件
        if pa - 1 in ends and not missing and any(k in ends for k in range(pa, b.a)) and any(_content(w) for w in extras) \
                and not any(want[i] == _SLOT for i in gap):
            return False
        if any(want[i] == _SLOT for i in gap):
            if len(extras) > VERIFY_FILL_WORDS:
                return False
        elif extras:
            if len(extras) > VERIFY_EXTRA_RUN:
                return False
            extra_total += len(extras)
        if missing:
            if len(missing) > VERIFY_MISSING_RUN or any(w in _GRANT_WORDS for w in missing):
                return False
            missing_total += len(missing)
        pa, pb = b.a + b.size, b.b + b.size
    return extra_total <= VERIFY_EXTRA_WORDS and missing_total <= max(VERIFY_MISSING_MIN, VERIFY_MISSING * required)


def verify_text(text, lid):
    """原文是不是就是 lid 这个许可证（标准文本或标准头部），没有多出来的条款、没有删掉授权。"""
    if len(text) > VERIFY_MAX_CHARS:
        return False
    for pat in _PREAMBLES.get(lid, []):
        text = re.sub(pat.replace(" ", r"\s+"), " ", text, flags=re.I)
    ends = set()
    got = _words(text, ends=ends)
    if not any(w != _SLOT for w in got):
        return False
    return any(_aligns(got, want, optional, grant, ends) for want, optional, grant in _template_words(lid) if want)


def examine(text):
    """一份原文：提名（proposed）、核对过没有（verified）、提名是不是来自标题（titled）、所有提名和文件里任何位置
    出现的禁止名单许可证（candidates）。proposed 是第一个核对得上的提名；都对不上时是第一个提名。"""
    full = _normalized(text, limit=None)
    found, titled = _proposals(text, full)
    lid, ok = (found[0] if found else None), False
    for x in found:
        if verify_text(text, x):
            lid, ok = x, True
            break
    return {"proposed": lid, "verified": ok, "titled": lid in titled,
            "candidates": list(dict.fromkeys(found + deny_sections(text, full)))}


def identify(text):
    """(许可证, 核对过没有)：第一个核对得上的提名；都对不上时是第一个提名和 False。"""
    r = examine(text)
    return r["proposed"], r["verified"]


def detect_text(text):
    """原文核对过的许可证；提名不出来或者对不上标准文本，返回 None。"""
    lid, ok = identify(text)
    return lid if ok else None


# ---------------------------------------------------------------------------
# 原文文件

# 许可证、NOTICE 文件的名字：以这些词开头，或者词在 - _ . 后面（LICENSE-MIT、node-runtime-NOTICE.md、jetbrains-mono-OFL.txt、
# ThirdPartyNotices.txt、Angular 生成的 3rdpartylicenses.txt、EULA.txt、TERMS-OF-USE.md）；只叫 TERMS、LEGAL 的
# （TERMS.md、LEGAL.txt）也算，名字里带 terms 的别的文件（terms.json、glossary-terms.txt）不算。
_LEGAL_NAME = re.compile(
    r"(^|[-_. ])(LICEN[CS]E|COPYING|NOTICE|UNLICENSE|COPYRIGHT|PATENTS|THIRD[-_ ]?PARTY|3RD[-_ ]?PARTY|EULA|"
    r"TERMS[-_ ]?(?:OF[-_ ]?(?:USE|SERVICE)|AND[-_ ]?CONDITIONS)|OFL([-_. ]|$))"
    r"|^(TERMS|LEGAL)(\.(md|txt|rst|html?))?$", re.I)
# 字体：TrueType / OpenType / Web 字体、字体集合、Type 1（.pfb、.pfa、.afm、.pfm、.t1）、点阵字体（.bdf、.pcf、.fnt、.fon）。
_FONT_EXT = {".ttf", ".otf", ".woff", ".woff2", ".eot", ".ttc", ".otc", ".dfont", ".pfb", ".pfa", ".afm", ".pfm", ".t1",
             ".bdf", ".pcf", ".pcf.gz", ".bdf.gz", ".fnt", ".fon"}
_CODE_EXT = {
    ".js", ".cjs", ".mjs", ".ts", ".cts", ".mts", ".jsx", ".tsx", ".json", ".py", ".pyc", ".pyi", ".rs", ".go",
    ".map", ".sh", ".yml", ".yaml", ".toml", ".css", ".svg", ".png", ".jpg", ".gif", ".wasm", ".node", ".so",
    ".d", ".h", ".c", ".cc", ".cpp", ".java", ".rb",
} | _FONT_EXT
# 包里不看的目录：版本库、别的包（node_modules 下每个包单独记）。别的隐藏目录（.vitepress、.next）照样看。
_SKIP_DIRS = {".git", ".hg", ".svn", "node_modules"}


def _is_code(name):
    lower = name.lower()
    return any(lower.endswith(ext) for ext in _CODE_EXT)


def _is_font(name):
    lower = name.lower()
    return any(lower.endswith(ext) for ext in _FONT_EXT)


def is_legal_file(name):
    return _LEGAL_NAME.search(name) is not None and not _is_code(name)


def _bundled_kind(path, in_licenses_dir=False):
    """包里子目录下的文件算什么：legal（许可证、NOTICE；licenses/ 目录下的都算）、font，或者 None。"""
    name = Path(path).name
    if _is_font(name):
        return "font"
    if is_legal_file(name) or (in_licenses_dir and not _is_code(name)):
        return "legal"
    return None


def bundled_files(directory, stop_at=None):
    """包里子目录下（不进 node_modules：那是别的包）的许可证、NOTICE 和字体，返回 (原文列表, 字体列表)。

    打包进来的第三方代码、图标、字体的原文常在子目录里（vendor/x/LICENSE、fonts/x-OFL.txt）；字体常常单独授权
    （有的是商用字体），每个都要登记（policy.toml 的 [[asset]]）。字体在包的根目录也算。
    stop_at：子目录里有这个文件就是另一个包，不进去（cargo 的 git 依赖：整个仓库都在，旁边是工作区里别的 crate）。"""
    directory = Path(directory)
    legal, fonts = [], []
    for dirpath, dirnames, filenames in os.walk(directory):
        here = Path(dirpath)
        dirnames[:] = sorted(d for d in dirnames if d not in _SKIP_DIRS and not (stop_at and (here / d / stop_at).is_file()))
        in_licenses_dir = re.fullmatch(r"(?i)licen[cs]es", here.name) is not None
        for f in sorted(filenames):
            kind = _bundled_kind(here / f, in_licenses_dir)
            if kind == "font":
                fonts.append(here / f)
            elif kind == "legal" and here != directory:
                legal.append(here / f)
    return legal, fonts


def legal_files(directory):
    """目录里（只看这一层）的许可证、NOTICE 文件，按名字排序。"""
    try:
        entries = sorted(os.scandir(directory), key=lambda e: e.name)
    except OSError:
        return []
    return [Path(e.path) for e in entries if is_legal_file(e.name) and e.is_file()]


def read_text(path):
    """原文（最多 SCAN_MAX_BYTES + 1 个字节：长度超过 SCAN_MAX_BYTES 说明没读完）。"""
    try:
        with open(path, "rb") as f:
            data = f.read(SCAN_MAX_BYTES + 1)
    except OSError:
        return None
    return data.decode("utf-8", errors="replace")


def legal_text(path):
    """拿来认许可证、找限制性说法的正文：HTML 的（LICENSE.html、ThirdPartyNotices.html）去掉标签。"""
    text = read_text(path)
    if text is not None and Path(path).name.lower().endswith((".html", ".htm")):
        import html

        text = re.sub(r"(?is)<(script|style)\b.*?</\1\s*>", " ", text)
        text = html.unescape(re.sub(r"(?s)<[^>]*>", " ", text))
    return text


def is_notice(path):
    """NOTICE、版权声明、第三方许可清单：讲的是别人的许可证或者只是署名，不拿来认这个包自己的许可证。"""
    name = Path(path).name.upper()
    return (
        re.search(r"(^|[-_. ])(NOTICE|COPYRIGHT|PATENTS|AUTHORS)", name) is not None
        or "THIRD" in name
        or "3RD" in name
        or re.match(r"^LICENSES(\.|$)", name) is not None
    )


def license_from_files(paths):
    """从原文认许可证（只用核对过的）。NOTICE、第三方清单不参与。多个认出来的用 AND 连起来。

    有认不出的许可证文件时加上 LicenseRef-Unrecognized（要登记）：认不出的可能正是专有或限制性的条款，
    不能因为旁边还有一份 MIT 原文就当它是 MIT。有许可证文件但一个也认不出时返回 LicenseRef-Unrecognized，
    一个许可证文件也没有返回 None。
    """
    found, unknown = [], False
    for p in paths:
        if is_notice(p):
            continue
        text = legal_text(p)
        if text is None:
            continue
        spdx = detect_text(text)
        if spdx is None:
            unknown = True
        elif spdx not in found:
            found.append(spdx)
    if unknown:
        found.append("LicenseRef-Unrecognized")
    if not found:
        return None
    return found[0] if len(found) == 1 else " AND ".join(found)


def file_detections(paths):
    """每个许可证文件提名的许可证和核对结果（examine），给检查时和声明对照用。NOTICE、第三方许可清单不提名
    （讲的是别人的许可证），只记里面任何位置出现的禁止名单许可证（deny_sections）：打包工具把依赖的许可证合进
    一个 THIRD_PARTY_NOTICES、3rdpartylicenses.txt，AGPL、BUSL 的依赖就藏在那里。"""
    out = []
    for p in paths:
        text = legal_text(p)
        if text is None:
            continue
        if is_notice(p):
            found = deny_sections(text)
            if found:
                out.append((p, {"proposed": None, "verified": False, "titled": False, "candidates": found, "notice": True}))
            continue
        out.append((p, examine(text)))
    return out


# 许可证原文里出现这些说法，说明条款限制商用、托管或竞争（Commons Clause、非商用、BUSL、SSPL、FSL……），
# 不管元数据怎么声明，都加上 LicenseRef-Restricted-Terms 要人看。比对前把连字符、下划线、空白统一成一个空格。
# GPL 正文里的“noncommercially”、Unlicense 的“commercial or non-commercial”不算。
_RESTRICTED_PHRASES = [
    "commons clause",
    "non commercial",
    "noncommercial use",
    "noncommercial purpose",
    "attribution noncommercial",
    "not for commercial",
    "commercial use is not permitted",
    "commercial use is prohibited",
    "may not be used for commercial",
    "shall not be used for commercial",
    "business source license",
    "server side public license",
    "elastic license",
    "functional source license",
    "competing use",
    "polyform",
    "for evaluation purposes only",
    "as a hosted service",
    "as a hosted or managed service",
    "as a managed service",
    "software as a service",
    "non production use",
    "sustainable use license",
    "source available license",
    "confluent community license",
    "prosperity public license",
]


def restricted_terms(paths):
    """许可证文件（NOTICE、第三方许可清单也算）里的限制性说法（_RESTRICTED_PHRASES）。"""
    hits = []
    for p in paths:
        text = legal_text(p)
        if text is None:
            continue
        if len(text.encode("utf-8", errors="replace")) > SCAN_MAX_BYTES:
            hits.append("file too large to scan: %s" % Path(p).name)
            continue
        hits += [h for h in _restricted_in(text) if h not in hits]
    return hits


def _restricted_in(text):
    """一段原文里的限制性说法。只留字母、数字和断句的标点：Markdown 的 **粗体**、> 引用、// 注释前缀、各种连字符都当
    空格，说法拆不开。"""
    t = re.sub(r"[^\w.!?;:,]+|_+", " ", _fold(text).lower())
    t = re.sub(r"\bcommercial,? (or|and) non ?commercial\b|\bnon ?commercial,? (or|and) commercial\b", "", t)
    return [phrase for phrase in _RESTRICTED_PHRASES if phrase in t]


# ---------------------------------------------------------------------------
# 清单

def _relative(f, base):
    """f 相对 base 的路径；不在 base 下面时用 ../（PyPI 包装到虚拟环境根目录下的数据文件）。"""
    if not base:
        return str(f)
    try:
        return str(Path(f).relative_to(base))
    except ValueError:
        return os.path.relpath(f, base)


class Inventory:
    def __init__(self, out, subject):
        self.out = Path(out)
        self.subject = subject
        self.components = {}

    def add(self, ecosystem, name, version, declared, license, license_from, files, path, root_level=False, extra=None,
            authors=None, bundled=None, fonts=None, source_url=None, asset_base=None, texts=None):
        """files：包根目录的许可证文件（拿来认许可证）；bundled：子目录里的（打包进来的第三方代码、字体的原文，
        只拿来和声明对照、找限制性说法）；fonts：包里的字体（相对 path 记下来，检查时要有登记）；texts：不是文件的
        许可证原文 [(名字, 原文)]（PyPI 的 License 字段里的整篇正文），和根目录的许可证文件一样和声明对照、找限制性说法。

        同名同版本的包在别的位置又出现一次（npm 的依赖树里常见）：这一份的原文、字体也记上（可能被打过补丁、
        或者构建时只删了一份里的字体），许可证认得不一样时两个都算（AND）。"""
        key = (ecosystem, name, version)
        self._where = {}
        copied, digests = self._copy(ecosystem, name, version, files)
        bundled_copied, bundled_digests = self._copy(ecosystem, name, version, bundled)
        checked = ecosystem not in ("deb", "runtime")
        base = asset_base or path
        detections = [
            dict({"file": self._where.get(Path(src), str(src)), "path": _relative(src, base)}, **r, **({"bundled": True} if b else {}))
            for b, group in ((False, files), (True, bundled)) if checked
            for src, r in file_detections(group or [])
        ] + [dict({"file": label, "path": label}, **examine(text)) for label, text in (texts or []) if checked]
        restricted = restricted_terms(list(files or []) + list(bundled or [])) if checked else []
        for _, text in (texts or []) if checked else []:
            restricted += [h for h in _restricted_in(text) if h not in restricted]
        if restricted and license:
            try:
                wrap = parse_spdx(license)[0] == "or"
            except SpdxError:
                wrap = True
            license = "%s AND LicenseRef-Restricted-Terms" % ("(%s)" % license if wrap else license)
        c = {
            "ecosystem": ecosystem,
            "name": name,
            "version": version,
            "license": license,
            "restricted_terms": restricted or None,
            "file_licenses": detections,
            "declared": declared,
            "license_from": license_from,
            "files": copied,
            "text_sha256": digests,
            "generic_files": [] if copied or not license else self._generic(license),
            "bundled_files": bundled_copied,
            "bundled_sha256": bundled_digests,
            "assets": [{"kind": "font", "path": _relative(f, base)} for f in fonts or []],
            "authors": authors or None,
            "source_url": source_url,
            "path": str(path) if path else None,
            "root_level": root_level,
            "locations": 1,
        }
        if extra:
            c.update(extra)
        if key in self.components:
            return self._merge_copy(self.components[key], c)
        self.components[key] = c
        return c

    @staticmethod
    def _merge_copy(c, new):
        """同一个包的另一份：原文、字体、提名、限制性说法都并进来。"""
        c["locations"] += 1
        c["root_level"] = c["root_level"] or new["root_level"]
        if new["license"] != c["license"]:
            c["license"] = _and([c["license"], new["license"]]) if c["license"] and new["license"] else None
        for k in ("files", "text_sha256", "bundled_files", "bundled_sha256", "generic_files"):
            c[k] = list(dict.fromkeys((c.get(k) or []) + (new.get(k) or [])))
        seen = {(d["file"], d.get("path"), d.get("bundled", False)) for d in c["file_licenses"]}
        c["file_licenses"] += [d for d in new["file_licenses"] if (d["file"], d.get("path"), d.get("bundled", False)) not in seen]
        paths = {a["path"] for a in c["assets"]}
        c["assets"] += [a for a in new["assets"] if a["path"] not in paths]
        terms = list(dict.fromkeys((c.get("restricted_terms") or []) + (new.get("restricted_terms") or [])))
        c["restricted_terms"] = terms or None
        return c

    def _generic(self, license):
        """许可证表达式里每个许可证的 SPDX 标准文本（有的话），复制到 texts/spdx/ 一份。"""
        try:
            ids = spdx_ids(parse_spdx(license))
        except SpdxError:
            return []
        out = []
        for lid in dict.fromkeys(ids):
            src = SPDX_DIR / ("%s.txt" % lid)
            if not src.is_file():
                continue
            rel = Path("texts") / "spdx" / src.name
            target = self.out / rel
            if not target.is_file():
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(src, target)
            out.append(str(rel))
        return out

    def _copy(self, ecosystem, name, version, files):
        """原文按内容存：texts/by-hash/<哈希前 16 位>/<原文件名>。几百个 crate 的 LICENSE-APACHE 一字不差，只存一份。
        太大的（超过 MAX_TEXT_BYTES）不复制、只记原来的位置，但哈希照样算：登记例外钉住的原文要包括它。"""
        copied, digests = [], []
        for src in files or []:
            src = Path(src)
            try:
                size = src.stat().st_size
                data = src.read_bytes() if size <= MAX_TEXT_BYTES else None
                if data is None:
                    h = hashlib.sha256()
                    with open(src, "rb") as f:
                        for chunk in iter(lambda: f.read(1 << 20), b""):
                            h.update(chunk)
            except OSError:
                continue
            if data is None:
                copied.append(str(src))  # 太大：只记原来的位置
                self._where[src] = str(src)
                digests.append(h.hexdigest())
                continue
            digest = hashlib.sha256(data).hexdigest()
            rel = Path("texts") / "by-hash" / digest[:16] / src.name
            target = self.out / rel
            if not target.is_file():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            copied.append(str(rel))
            self._where[src] = str(rel)
            digests.append(digest)
        return copied, digests

    def merge(self, other_dir):
        """并入另一个清单（比如 agent-shim 的 Rust crate 清单），原文一起复制过来。"""
        other_dir = Path(other_dir)
        data = json.loads((other_dir / "inventory.json").read_text(encoding="utf-8"))
        for c in data["components"]:
            key = (c["ecosystem"], c["name"], c["version"])
            if key in self.components:
                continue
            refs = c["files"] + c.get("generic_files", []) + c.get("bundled_files", []) + [d["file"] for d in c.get("file_licenses") or []]
            for f in dict.fromkeys(refs):
                if os.path.isabs(f):
                    continue  # 太大没复制的原文：记的是镜像里的位置
                src = other_dir / f
                if not src.is_file():
                    raise SystemExit("%s：%s %s 的原文 %s 不在清单目录里" % (other_dir, c["name"], c["version"], f))
                target = self.out / f
                if not target.is_file():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(src, target)
            c = dict(c, merged_from=data.get("subject"))
            self.components[key] = c

    def write(self):
        self.out.mkdir(parents=True, exist_ok=True)
        comps = sorted(self.components.values(), key=lambda c: (c["ecosystem"], c["name"].lower(), c["version"]))
        doc = {"schema": SCHEMA, "subject": self.subject, "components": comps}
        (self.out / "inventory.json").write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        (self.out / "NOTICES.md").write_text(render_notices(doc), encoding="utf-8")
        return doc


def render_notices(doc):
    comps = doc["components"]
    lines = [
        "# 第三方组件许可证",
        "",
        "`%s` 里带的第三方组件和它们的许可证。原文在本目录的 `texts/` 下（Debian 包的在 `/usr/share/doc/<包>/copyright`）；"
        "机器可读的清单是 `inventory.json`。由 tools/licenses/licenses.py 生成。" % doc["subject"],
        "",
        "## 按许可证",
        "",
        "| 许可证 | 组件数 |",
        "|---|---|",
    ]
    counts = {}
    for c in comps:
        counts[c["license"] or "（未识别：%s）" % (c["declared"] or "无声明")] = counts.get(c["license"] or "（未识别：%s）" % (c["declared"] or "无声明"), 0) + 1
    for lic, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
        lines.append("| %s | %d |" % (lic.replace("|", "\\|"), n))
    lines += [
        "",
        "## 组件",
        "",
        "包里没带原文的，列的是 SPDX 标准文本（`texts/spdx/`），版权方按包的元数据（作者）。“包内”是包里子目录下的原文"
        "（打包进来的第三方代码、字体、图标的）。源码：包的源码仓库或这个版本的发布页。",
        "",
        "| 生态 | 组件 | 版本 | 许可证 | 原文 | 源码 |",
        "|---|---|---|---|---|---|",
    ]
    for c in comps:
        files = "、".join("`%s`" % f for f in c["files"])
        if not files and c.get("generic_files"):
            files = "标准文本 %s；版权方：%s" % ("、".join("`%s`" % f for f in c["generic_files"]), c.get("authors") or "包里没写")
        if c.get("bundled_files"):
            files = (files + "；" if files else "") + "包内：" + "、".join("`%s`" % f for f in c["bundled_files"])
        lic = c["license"] or "未识别（%s）" % (c["declared"] or "无声明")
        cells = (c["ecosystem"], c["name"], c["version"], lic, files or "—", c.get("source_url") or "—")
        lines.append("| %s |" % " | ".join(str(x).replace("|", "\\|").replace("\n", " ") for x in cells))
    return "\n".join(lines) + "\n"


_VAGUE = ("LicenseRef-BSD-Unspecified", "LicenseRef-LGPL-Unspecified", "LicenseRef-GPL-Unspecified", "LicenseRef-AGPL-Unspecified")


def _is_vague(expr):
    return any(v in expr for v in _VAGUE)


def _same_family(vague, precise):
    """原文认出来的（BSD-3-Clause）是含糊声明（BSD）的一种，才拿它代替声明。"""
    try:
        ids = spdx_ids(parse_spdx(precise))
    except SpdxError:
        return False
    family = {
        "LicenseRef-BSD-Unspecified": ("BSD-", "0BSD"),
        "LicenseRef-LGPL-Unspecified": ("LGPL-",),
        "LicenseRef-GPL-Unspecified": ("GPL-",),
        "LicenseRef-AGPL-Unspecified": ("AGPL-",),
    }.get(vague)
    return bool(family) and all(i.startswith(family) for i in ids)


def _family(lid):
    """GPL-2.0-only、GPL-2.0-or-later、GPL-2.0+ 是同一个许可证的不同版本选择，比较时当一个。"""
    return re.sub(r"(-only|-or-later|\+)$", "", lid)


def _covers(expr, lid):
    """许可证表达式里有没有 lid（或者同一个许可证的别的版本选择；含糊的 LicenseRef-GPL-Unspecified 算任何 GPL）。"""
    try:
        ids = spdx_ids(parse_spdx(expr))
    except SpdxError:
        return False
    want = _family(lid)
    for i in ids:
        have = _family(i)
        if have == want:
            return True
        for a, b in ((have, want), (want, have)):
            m = re.fullmatch(r"LicenseRef-(\w+)-Unspecified", a)
            if m and b.startswith(m.group(1) + "-"):
                return True
    return False


def _and(items):
    items = list(dict.fromkeys(items))
    return " AND ".join("(%s)" % i if " OR " in i else i for i in items)


def resolve_license(declared_list, files, classifiers=(), see_file=None):
    """包的许可证。元数据里有声明就以声明为准（SPDX 表达式，或认得出的写法）；声明认不出时不拿原文或分类去猜
    （猜出来的可能比真实的宽松），返回 None，要人登记。

    - “SEE LICENSE IN <文件>”：只看那个文件的原文（see_file；文件不存在时传 False）。
    - 声明含糊（“BSD”）：原文认出来是同一类的（BSD-3-Clause）就用原文的，否则用含糊的。
    - 没有声明：PyPI 的许可证分类（几个分类都适用，用 AND 连：分类本身不说明是“任选其一”）、原文识别。
    """
    declared_list = [d for d in declared_list if d and d.strip()]
    normalized = [normalize_declared(d) for d in declared_list if not d.strip().upper().startswith("SEE LICEN")]
    if any(n is None for n in normalized):
        return None, "none"  # 有一个声明认不出（可能正是限制性的），别的声明认得出也不算
    vague, unrecognized = None, False
    for n in normalized:
        if not _is_vague(n):
            return n, "metadata"
        vague = vague or n
    if see_file is not None:
        from_file = license_from_files([see_file]) if see_file else None
        if not from_file or "LicenseRef-Unrecognized" in from_file:
            return None, "none"
        return from_file, "text"
    if unrecognized:
        return None, "none"
    if vague:
        from_text = license_from_files(files)
        if from_text and _same_family(vague, from_text):
            return from_text, "text"
        if from_text:
            return _and([vague, from_text]), "metadata"
        return vague, "metadata"
    if any(not _is_vague(c) for c in classifiers):
        return _and(classifiers), "classifier"
    from_text = license_from_files(files)
    if classifiers:
        # 分类都含糊（“BSD License”）：和含糊的声明一样，核对过的同一类原文细化它，别的（包括认不出的原文）一起算（AND）
        if from_text and len(classifiers) == 1 and _same_family(classifiers[0], from_text):
            return from_text, "text"
        return _and(([from_text] if from_text else []) + list(classifiers)), "classifier"
    if from_text == "LicenseRef-Unrecognized":
        return None, "none"  # 一个也认不出：许可证未知（要登记），不是“认出来一半”
    if from_text:
        return from_text, "text"
    return None, "none"


# ---------------------------------------------------------------------------
# npm

def npm_declared(pkg):
    lic = pkg.get("license")
    if isinstance(lic, dict):
        lic = lic.get("type")
    if isinstance(lic, str) and lic.strip():
        return lic.strip()
    lics = pkg.get("licenses")
    if isinstance(lics, list):
        names = [x.get("type") if isinstance(x, dict) else x for x in lics]
        names = [n for n in names if isinstance(n, str) and n.strip()]
        if names:
            return " OR ".join(names)
    if isinstance(lics, str) and lics.strip():
        return lics.strip()
    return None


def scan_npm(inv, root):
    """root 是一个 node_modules 目录（全局安装的是 /usr/local/lib/node_modules）。直接在它下面的包是顶层包。"""
    root = Path(root)
    if not root.is_dir():
        return
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        here = Path(dirpath)
        dirnames.sort()
        parent = here.parent
        in_modules = parent.name == "node_modules" or (parent.name.startswith("@") and parent.parent.name == "node_modules")
        if "package.json" not in filenames or not in_modules or here.name.startswith("."):
            continue
        root_level = parent == root or (parent.parent == root and parent.name.startswith("@"))
        try:
            pkg = json.loads((here / "package.json").read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            pkg = None
        if not isinstance(pkg, dict) or not isinstance(pkg.get("name"), str) or not isinstance(pkg.get("version"), str):
            # node_modules 下的目录有 package.json 却读不出名字和版本：不能悄悄跳过，记成认不出的组件，检查时报错。
            name = here.name if not parent.name.startswith("@") else "%s/%s" % (parent.name, here.name)
            inv.add("npm", name, "?", "package.json 读不出名字或版本", None, "none", legal_files(here), here, root_level)
            continue
        npm_component(inv, here, pkg, root_level)


def npm_component(inv, here, pkg, root_level):
    name, version = pkg.get("name"), pkg.get("version")
    if not isinstance(name, str) or not isinstance(version, str):
        return
    declared = npm_declared(pkg)
    files = legal_files(here)
    see_file = None
    if declared and declared.upper().startswith("SEE LICEN"):
        # “SEE LICENSE IN <文件>”：原文在包里指定的那个文件（可能不叫 LICENSE），许可证只按它认。
        m = re.match(r"(?i)^see licen[cs]e in\s+(.+)$", declared.strip())
        ref = (here / m.group(1).strip()) if m else None
        see_file = ref if ref and ref.is_file() and here.resolve() in ref.resolve().parents else False
        if see_file and see_file not in files:
            files.append(see_file)
    license, source = resolve_license([declared] if declared else [], files, see_file=see_file)
    bundled, fonts = bundled_files(here)
    inv.add("npm", name, version, declared, license, source, files, here, root_level, authors=npm_author(pkg),
            bundled=bundled, fonts=fonts, source_url=npm_source(pkg, name, version))


def git_web_url(url):
    """git 仓库地址（git+https://…/x.git、git@github.com:a/b.git、github:a/b）换成网页地址；认不出返回 None。"""
    if not isinstance(url, str) or not url.strip():
        return None
    u = url.strip()
    m = re.fullmatch(r"(?:(github|gitlab|bitbucket):)?(\w[\w.-]*/(?!\.\.?$)[\w.-]+)", u)
    if m:
        return "https://%s.%s/%s" % (m.group(1) or "github", "org" if m.group(1) == "bitbucket" else "com", m.group(2))
    u = re.sub(r"^git\+", "", u)
    # ssh://[用户@]主机[:端口]/org/repo、ssh://[用户@]主机:org/repo（scp 写法套了 ssh://）：网页地址不带用户和 SSH 端口
    u = re.sub(r"^ssh://(?:[^@/]+@)?([^:/]+)(?::\d*)?[:/]", r"https://\1/", u)
    u = re.sub(r"^git://", "https://", u)
    u = re.sub(r"^[^@/:]+@([^:/]+):", r"https://\1/", u)  # git@github.com:org/repo.git
    u = re.sub(r"^(https?://)[^@/]*@", r"\1", u)  # https://user[:token]@host/…：网页地址不带用户名、口令
    u = re.sub(r"\.git(#.*)?$", "", u)
    return u if u.startswith(("https://", "http://")) else None


def npm_source(pkg, name, version):
    """源码在哪：package.json 的 repository，没有就是 npm 上这个版本的页面（包本身就是源码）。"""
    repo = pkg.get("repository")
    url = git_web_url(repo.get("url") if isinstance(repo, dict) else repo)
    if url and isinstance(repo, dict) and isinstance(repo.get("directory"), str) and "github.com/" in url:
        url = "%s/tree/HEAD/%s" % (url, repo["directory"].strip("/"))
    return url or "https://www.npmjs.com/package/%s/v/%s" % (name, version)


def scan_npm_packages(inv, pattern):
    """不在 node_modules 里的 npm 包（比如基础镜像带的 /opt/yarn-v1.22.22），连同它自己的 node_modules。"""
    import glob as globmod

    for d in sorted(globmod.glob(pattern)):
        here = Path(d)
        try:
            pkg = json.loads((here / "package.json").read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            continue
        npm_component(inv, here, pkg, root_level=False)
        scan_npm(inv, here / "node_modules")


def npm_author(pkg):
    a = pkg.get("author")
    if isinstance(a, dict):
        a = a.get("name")
    return a.strip() if isinstance(a, str) and a.strip() else None


# ---------------------------------------------------------------------------
# Python

# PyPI 的 License 字段里不说明任何事情的占位写法，当成没写（看分类和原文）。“Custom”之类有含义的不在这里。
_NOT_A_DECLARATION = {
    "unknown", "none", "n/a", "dual license", "license", "license.txt", "license.md", "see license",
    "see license file", "see license.txt", "see licence", "file license",
}


def pypi_norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def scan_python(inv, site_packages, root_names=()):
    """site_packages 是一个 site-packages 目录。root_names 是直接要求安装的包（清单 [install] 里的）。"""
    site_packages = Path(site_packages)
    roots = {pypi_norm(n) for n in root_names}
    dists = sorted(site_packages.glob("*.dist-info")) + sorted(site_packages.glob("*.egg-info"))
    for dist in dists:
        if dist.is_dir():
            meta_path = dist / ("METADATA" if dist.suffix == ".dist-info" else "PKG-INFO")
        else:
            meta_path = dist  # 单个文件的 .egg-info
        if not meta_path.is_file():
            continue
        msg = email.parser.HeaderParser().parsestr(meta_path.read_text(encoding="utf-8", errors="replace"))
        name, version = msg.get("Name"), msg.get("Version")
        if not name or not version:
            continue
        declared = []
        expr = msg.get("License-Expression")
        raw_expr = expr.strip() if expr else None
        if expr:
            declared.append(expr.strip())
            # 认得出的 License-Expression 为准（PEP 639：有它就不看 License 字段和许可证分类）；认不出时一起报
            expr = expr if normalize_declared(expr) else None
        lic = (msg.get("License") or "").strip()
        texts, shown_lic = [], []
        if len(lic) <= 120 and "\n" not in lic:
            if lic and _norm_text(lic).rstrip(".") not in _NOT_A_DECLARATION:
                declared.append(lic)
                shown_lic.append(lic)
        else:
            # 有的包把整篇许可证正文塞进 License 字段（setuptools 的 license=open("LICENSE").read()）：当一份原文核对，
            # 核对得上就是那个许可证的声明，对不上就是认不出的声明；照样和声明对照、找限制性说法。
            body = re.sub(r"\n {7}\|?|\n {8}", "\n", lic)
            texts.append(("METADATA:License", body))
            lid = detect_text(body)
            declared.append(lid or "License text (unrecognized)")
            shown_lic.append("License: %s…" % re.sub(r"\s+", " ", body)[:60])
        classifiers = [c.split("::")[-1].strip() for c in msg.get_all("Classifier") or [] if c.startswith("License ::")]
        classifiers = [c for c in classifiers if c.lower() != "osi approved"]
        mapped = [CLASSIFIERS[c.lower()] for c in classifiers if c.lower() in CLASSIFIERS]
        # 对照表里没有的许可证分类当成认不出的声明（可能正是限制性的），除非有明确的 License-Expression。
        declared += ["Classifier: %s" % c for c in classifiers if c.lower() not in CLASSIFIERS]
        if expr:
            declared, mapped, shown_lic = declared[:1], [], []
        files = legal_files(dist) if dist.is_dir() else []
        # venv 里的 pip、setuptools 是 Debian 的 python3-pip-whl / python3-setuptools-whl 那个 wheel 装的，
        # 它们 vendored 的第三方包（pip/_vendor：certifi、requests、urllib3……）的版权和许可证在 Debian 的 copyright 文件里。
        extra = {}
        deb_copyright = Path("/usr/share/doc/python3-%s-whl/copyright" % pypi_norm(name))
        if deb_copyright.is_file():
            files.append(deb_copyright)
        vendor_txt = site_packages / pypi_norm(name).replace("-", "_") / "_vendor" / "vendor.txt"
        if vendor_txt.is_file():
            extra["vendored"] = [line.strip() for line in vendor_txt.read_text(encoding="utf-8").splitlines()
                                 if line.strip() and not line.strip().startswith("#")]
        for lf in msg.get_all("License-File") or []:
            for cand in (dist / "licenses" / lf, dist / lf):
                if cand.is_file() and cand not in files:
                    files.append(cand)
        lic_dir = dist / "licenses"
        if lic_dir.is_dir():
            for p in sorted(lic_dir.rglob("*")):
                if p.is_file() and p not in files:
                    files.append(p)
        bundled, fonts = record_files(dist, site_packages)
        license, source = resolve_license(declared, files, mapped)
        if license and not expr and source in ("metadata", "text"):
            # 没有 License-Expression 时，License 字段和许可证分类都只是说明，分类里有 License 字段没提到的许可证
            # （License: MIT，分类却是 GPL），两个都算（AND），要人看。
            more = [m for m in mapped if not all(_covers(license, i) for i in spdx_ids(parse_spdx(m)))]
            if more:
                license = _and([license] + more)
        shown = "; ".join(([raw_expr] if raw_expr else []) + shown_lic + ["Classifier: %s" % c for c in classifiers]) or None
        authors = msg.get("Author") or msg.get("Author-email") or msg.get("Maintainer") or msg.get("Maintainer-email")
        inv.add("pypi", name, version, shown, license, source, files, dist, pypi_norm(name) in roots, extra=extra or None,
                authors=authors.strip() if authors and authors.strip().upper() != "UNKNOWN" else None,
                bundled=[f for f in bundled if f not in files], fonts=fonts, asset_base=site_packages,
                source_url=pypi_source(msg, name, version), texts=texts)


def record_files(dist, site_packages):
    """PyPI 包装进来的文件（.dist-info 的 RECORD、.egg-info 的 installed-files.txt）里，许可证、NOTICE 和字体。
    包自己的 .dist-info 里的不算（已经按包的原文处理），装到 site-packages 外面的（bin/ 下的脚本）不算。"""
    legal, fonts = [], []
    if not dist.is_dir():
        return legal, fonts
    if (dist / "RECORD").is_file():
        import csv
        import io

        rows = csv.reader(io.StringIO((dist / "RECORD").read_text(encoding="utf-8", errors="replace")))
        base, names = site_packages, [row[0] for row in rows if row]
    elif (dist / "installed-files.txt").is_file():
        base, names = dist, (dist / "installed-files.txt").read_text(encoding="utf-8", errors="replace").splitlines()
    else:
        return legal, fonts
    # wheel 的数据文件（.data/data）装在虚拟环境的根目录下（<venv>/share/…），也算；bin/ 下的脚本不算。
    sp = site_packages.resolve()
    root = sp.parents[2] if len(sp.parents) > 2 and sp.parent.parent.name == "lib" else sp
    for n in sorted(set(x.strip() for x in names if x.strip())):
        p = (base / n).resolve()
        if root not in p.parents or dist.resolve() in p.parents or not p.is_file():
            continue
        if root != sp and sp not in p.parents and p.relative_to(root).parts[0] == "bin":
            continue
        kind = _bundled_kind(p, re.fullmatch(r"(?i)licen[cs]es", p.parent.name) is not None)
        if kind == "font":
            fonts.append(p)
        elif kind == "legal":
            legal.append(p)
    return legal, fonts


def pypi_source(msg, name, version):
    """源码在哪：Project-URL 里的 Source / Repository / Homepage，再是 Home-page，都没有就是 PyPI 上这个版本的页面。"""
    urls = {}
    for v in msg.get_all("Project-URL") or []:
        label, _, url = v.partition(",")
        if url.strip().startswith(("https://", "http://")):
            urls.setdefault(re.sub(r"[^a-z]", "", label.lower()), url.strip())
    for label in ("source", "sourcecode", "repository", "code", "github", "homepage", "home"):
        if label in urls:
            return urls[label]
    home = (msg.get("Home-page") or "").strip()
    if home.startswith(("https://", "http://")):
        return home
    return "https://pypi.org/project/%s/%s/" % (name, version)


# ---------------------------------------------------------------------------
# Debian

_DEP5_LICENSE = re.compile(r"^License:\s*(.+?)\s*$", re.M)


def scan_deb(inv, admindir=None):
    """dpkg 装的包。原文就在 /usr/share/doc/<包>/copyright，不复制，只记位置和 DEP-5 格式里声明的许可证名。"""
    cmd = ["dpkg-query", "-W", "-f", "${Package}\t${Version}\t${Status}\t${source:Package}\t${source:Version}\n"]
    if admindir:
        cmd.insert(1, "--admindir=%s" % admindir)
    try:
        out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 3 or not parts[2].endswith(" installed"):
            continue
        name, version = parts[0], parts[1]
        name_noarch = name.split(":", 1)[0]
        copyright = Path("/usr/share/doc") / name_noarch / "copyright"
        declared = None
        if copyright.is_file():
            text = read_text(copyright) or ""
            names = []
            for m in _DEP5_LICENSE.finditer(text):
                for n in re.split(r"\s+(?:or|and)\s+|,\s*", m.group(1)):
                    n = n.strip()
                    if n and n not in names and len(n) < 60:
                        names.append(n)
            declared = ", ".join(names) or None
        inv.components.setdefault(
            ("deb", name_noarch, version),
            {
                "ecosystem": "deb",
                "name": name_noarch,
                "version": version,
                "license": None,
                "declared": declared,
                "license_from": "dep5" if declared else "none",
                "restricted_terms": None,
                "files": [str(copyright)] if copyright.is_file() else [],
                "text_sha256": [],
                "generic_files": [],
                "authors": None,
                # 源码包：Debian 的 snapshot 存档里按版本一直留着。
                "source_url": "https://snapshot.debian.org/package/%s/%s/" % (parts[3], parts[4]) if len(parts) >= 5 and parts[3] else None,
                "path": None,
                "root_level": False,
                "locations": 1,
            },
        )


# ---------------------------------------------------------------------------
# 额外的原文（上游有、装好的包里没带的，比如 Codex 的 NOTICE）

def scan_extra(inv, directory):
    """directory 下有 sources.toml（格式见 docs/licenses.md 第 3 节）：

    - [[file]]：仓库里放的上游原文。component、version、license、path（相对 directory）、url。
    - [[installed]]：镜像里已经有、但不在包的根目录（扫描找不到）的原文。component、version、license、
      glob（镜像里的绝对路径，可以用 **）。一个也匹配不到时构建失败：上游改了目录结构。
    - [[cargo]]：上游的 Rust 程序（比如 Codex 的二进制）依赖的 crate。构建前由 `licenses.py upstream-cargo`
      从上游源码生成到 directory/crates/（不进仓库，deploy/templates/build.sh 会自动跑），这里并进清单。
    - applies_to：这些原文是按哪个包的哪个版本核对的（"<生态>:<包名>@<版本>"），检查时镜像里没有这个
      版本就报错：上游升级后要重新核对。
    """
    directory = Path(directory)
    meta = directory / "sources.toml"
    if not meta.is_file():
        return
    data = tomllib.loads(meta.read_text(encoding="utf-8"))
    applies_to = data.get("applies_to", [])
    groups = {}
    def group(f):
        key = (f["component"], f["version"])
        g = groups.setdefault(key, {"license": f["license"], "files": [], "urls": [], "source": None})
        g["source"] = g["source"] or f.get("source")
        if g["license"] != f["license"]:
            raise SystemExit("%s：%s %s 的几个文件写的许可证不一样（%s、%s），分成不同的 component"
                             % (meta, f["component"], f["version"], g["license"], f["license"]))
        return g

    for f in data.get("file", []):
        group(f)
        groups[(f["component"], f["version"])]["files"].append(directory / f["path"])
        groups[(f["component"], f["version"])]["urls"].append(f.get("url"))
    for f in data.get("installed", []):
        import glob as globmod

        hits = sorted(Path(p) for p in globmod.glob(f["glob"], recursive=True) if Path(p).is_file())
        if not hits:
            raise SystemExit("%s：[[installed]] %s 在镜像里一个文件也没匹配到（%s）：上游改了目录结构？"
                             % (meta, f["component"], f["glob"]))
        group(f)["files"] += hits
    for (name, version), g in groups.items():
        missing = [str(p) for p in g["files"] if not p.is_file()]
        if missing:
            raise SystemExit("extra 原文缺文件：%s" % ", ".join(missing))
        inv.add("upstream", name, version, g["license"], canonical_spdx(g["license"]) or g["license"], "extra", g["files"], None,
                extra={"urls": [u for u in g["urls"] if u], "applies_to": applies_to, "notices_dir": directory.name},
                source_url=g["source"])
    if data.get("cargo"):
        crates = directory / "crates"
        want = upstream_cargo_subject(data["cargo"])
        got = None
        if (crates / "inventory.json").is_file():
            got = json.loads((crates / "inventory.json").read_text(encoding="utf-8")).get("subject")
        key = (crates / "key.json").read_text(encoding="utf-8") if (crates / "key.json").is_file() else None
        if got != want or key != upstream_cargo_key(data["cargo"]):
            raise SystemExit("%s 声明了上游的 Rust 程序，但 %s 没生成、不是这个版本或者是旧的扫描程序生成的（要 %s，有 %s）。"
                             "先运行 python3 tools/licenses/licenses.py upstream-cargo %s" % (meta, crates, want, got, directory))
        inv.merge(crates)
        for c in inv.components.values():
            if c.get("merged_from") == want:
                c.setdefault("applies_to", applies_to)
                c.setdefault("notices_dir", directory.name)


def upstream_cargo_subject(entries):
    return "; ".join("%s@%s %s" % (e["repo"], e["tag"], ",".join(e["packages"])) for e in entries)


def upstream_cargo_key(entries):
    """缓存的 crates/ 还能不能用：[[cargo]] 的每一项（含 manifest、target）、扫描程序本身和 SPDX 标准文本
    （改了扫描规则、核对用的标准文本都要重新生成）。"""
    h = hashlib.sha256(Path(__file__).read_bytes())
    for path in sorted(p for p in SPDX_DIR.iterdir() if p.is_file()):
        h.update(path.name.encode() + b"\0" + path.read_bytes() + b"\0")
    return json.dumps({"entries": entries, "tool": h.hexdigest()[:16], "schema": SCHEMA}, sort_keys=True)


def cmd_upstream_cargo(args):
    """按 sources.toml 的 [[cargo]]，从上游源码（浅克隆）生成 crate 清单到 <目录>/crates/。已经是这个版本就跳过。"""
    directory = Path(args.notices_dir)
    meta = directory / "sources.toml"
    if not meta.is_file():
        return 0
    entries = tomllib.loads(meta.read_text(encoding="utf-8")).get("cargo", [])
    if not entries:
        return 0
    subject = upstream_cargo_subject(entries)
    key = upstream_cargo_key(entries)
    out = directory / "crates"
    if (out / "key.json").is_file() and (out / "key.json").read_text(encoding="utf-8") == key:
        print("%s 已是 %s" % (out, subject), file=sys.stderr)
        return 0
    for tool in ("git", "cargo"):
        if not shutil.which(tool):
            raise SystemExit("upstream-cargo 要用 %s（从上游源码生成 %s 的 crate 清单），先装上" % (tool, subject))
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        parts = []
        for i, e in enumerate(entries):
            repo = tmp / ("repo%d" % i)
            subdir = str(Path(e["manifest"]).parent)
            subprocess.run(["git", "clone", "-q", "--depth", "1", "--branch", e["tag"], "--filter=blob:none", "--sparse", e["repo"], str(repo)],
                           check=True)
            subprocess.run(["git", "-C", str(repo), "sparse-checkout", "set", subdir], check=True)
            part = tmp / ("part%d" % i)
            inv = Inventory(part, "%s@%s" % (e["repo"], e["tag"]))
            # 上游的 rust-toolchain.toml 锁的版本不用装：读清单用现有的 stable 就行。上游发布时只改工作区自己的
            # 版本号、不更新 Cargo.lock，所以不加 --locked（第三方依赖的解析不变）。
            env_backup = os.environ.get("RUSTUP_TOOLCHAIN")
            os.environ["RUSTUP_TOOLCHAIN"] = os.environ.get("THINKTIN_UPSTREAM_TOOLCHAIN", "stable")
            try:
                scan_cargo(inv, e["packages"], target=e.get("target"), manifest_path=repo / e["manifest"], locked=False)
            finally:
                if env_backup is None:
                    os.environ.pop("RUSTUP_TOOLCHAIN", None)
                else:
                    os.environ["RUSTUP_TOOLCHAIN"] = env_backup
            inv.write()
            parts.append(part)
        if out.exists():
            shutil.rmtree(out)
        inv = Inventory(out, subject)
        for part in parts:
            inv.merge(part)
        doc = inv.write()
        (out / "key.json").write_text(key, encoding="utf-8")
    print("%s：%d 个 crate → %s" % (subject, len(doc["components"]), out), file=sys.stderr)
    return 0


def scan_runtime_node(inv):
    """Node.js 本身（基础镜像带的）。官方镜像不带 Node 的 LICENSE（里面还列了 Node 打包进去的 V8、OpenSSL、ICU 等的许可证），
    按镜像里 Node 的确切版本从上游取一份；取不到构建就失败，不悄悄漏掉。"""
    try:
        version = subprocess.run(["node", "--version"], check=True, capture_output=True, text=True).stdout.strip().lstrip("v")
    except (OSError, subprocess.CalledProcessError):
        return
    # 官方镜像把 Node 发行包里的 LICENSE 放在 /usr/local/LICENSE（名字太普通，按开头确认是 Node 的）。
    files = [p for p in (Path("/usr/local/share/doc/node/LICENSE"), Path("/usr/local/include/node/LICENSE"), Path("/usr/local/LICENSE"))
             if p.is_file() and (read_text(p) or "").lstrip().startswith("Node.js is licensed for use as follows")][:1]
    urls = []
    tmp = None
    if not files:
        url = NODE_LICENSE_URL % version
        tmp = Path(tempfile.mkdtemp()) / "LICENSE"
        tmp.write_bytes(fetch(url))
        files, urls = [tmp], [url]
    inv.add("runtime", "node", version, "MIT", "MIT", "metadata", files, shutil.which("node"), extra={"urls": urls} if urls else None,
            authors="Node.js contributors", source_url="https://github.com/nodejs/node/tree/v%s" % version)
    if tmp:
        shutil.rmtree(tmp.parent, ignore_errors=True)


def fetch(url, attempts=4):
    import time
    import urllib.request

    for i in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                return r.read()
        except OSError as e:
            if i == attempts - 1:
                raise SystemExit("取不到 %s：%s" % (url, e))
            time.sleep(2 ** (i + 1))


# ---------------------------------------------------------------------------
# Cargo

def scan_cargo(inv, packages, target=None, manifest_path=None, metadata_json=None, locked=True):
    """packages 是工作区里程序的包名；列出它们在 target 平台上的运行时依赖（不含 dev 依赖和只在构建时用的依赖）。"""
    if metadata_json:
        meta = json.loads(Path(metadata_json).read_text(encoding="utf-8"))
    else:
        cmd = ["cargo", "metadata", "--format-version", "1"] + (["--locked"] if locked else [])
        if manifest_path:
            cmd += ["--manifest-path", str(manifest_path)]
        if target:
            cmd += ["--filter-platform", target]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit("cargo metadata 失败：\n%s" % r.stderr[-4000:])
        meta = json.loads(r.stdout)
    by_id = {p["id"]: p for p in meta["packages"]}
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    workspace = set(meta["workspace_members"])
    wanted = [pid for pid in workspace if by_id[pid]["name"] in packages]
    missing = set(packages) - {by_id[p]["name"] for p in wanted}
    if missing:
        raise SystemExit("工作区里没有这些包：%s" % ", ".join(sorted(missing)))
    seen, stack = set(), list(wanted)
    while stack:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        for dep in nodes[pid]["deps"]:
            kinds = [k.get("kind") for k in dep.get("dep_kinds", [])]
            # 普通依赖会编进程序；构建依赖一般不会，但 *-src（openssl-src 这种）是把 C 源码编进去的。
            if any(k is None for k in kinds) or ("build" in kinds and by_id[dep["pkg"]]["name"].endswith("-src")):
                stack.append(dep["pkg"])
    for pid in sorted(seen - workspace, key=lambda p: (by_id[p]["name"], by_id[p]["version"])):
        p = by_id[pid]
        src_dir = Path(p["manifest_path"]).parent
        files = legal_files(src_dir)
        if p.get("license_file"):
            lf = src_dir / p["license_file"]
            if lf.is_file() and lf not in files:
                files.append(lf)
        declared = p.get("license")
        license, source = resolve_license([declared] if declared else [], files)
        bundled, _ = bundled_files(src_dir, stop_at="Cargo.toml")
        inv.add("cargo", p["name"], p["version"], declared or (p.get("license_file") and "license-file: %s" % p["license_file"]),
                license, source, files, None, root_level=False, authors=", ".join(p.get("authors") or []) or None,
                bundled=bundled, source_url=cargo_source(p), asset_base=src_dir)


def cargo_source(p):
    """源码在哪：Cargo.toml 的 repository；crates.io 上的包也可以按版本下载源码。"""
    src = p.get("source") or ""
    if src.startswith("registry+") and "crates.io" in src:
        return "https://crates.io/crates/%s/%s" % (p["name"], p["version"])
    if src.startswith("git+"):
        return git_web_url(src.split("?")[0].split("#")[0])
    return git_web_url(p.get("repository")) or p.get("repository")


# ---------------------------------------------------------------------------
# 策略检查

_DENY_WORDS = re.compile(
    r"agpl|affero|sspl|server[\s_-]*side[\s_-]*public|busl|business[\s_-]*source|commons[\s_-]*clause|"
    r"non[\s_-]?commercial|cc-by(-sa)?-nc|polyform|elastic[\s_-]*license",
    re.I,
)


class Policy:
    def __init__(self, data):
        self.allow = data.get("allow", [])
        self.deny = data.get("deny", [])
        # `A WITH 例外`：例外只是额外放宽（LLVM-exception、Classpath-exception……）时按 A 判定；
        # 不在这张表里的例外要人看，在禁止名单里的（Commons-Clause 这种附加限制）直接禁止。
        self.allow_exceptions = data.get("allow_exceptions", [])
        self.ecosystems = data.get("ecosystem", {})
        self.exceptions = data.get("exception", [])
        self.assets = data.get("asset", [])
        self.agents = data.get("agents", {})
        for i, e in enumerate(self.exceptions):
            for k in ("ecosystem", "name", "license", "reason"):
                if not e.get(k):
                    raise SystemExit("policy: 第 %d 个 [[exception]] 缺 %s" % (i + 1, k))
        for i, e in enumerate(self.assets):
            for k in ("ecosystem", "name", "path", "license", "reason"):
                if not e.get(k):
                    raise SystemExit("policy: 第 %d 个 [[asset]] 缺 %s" % (i + 1, k))

    @classmethod
    def load(cls, path):
        return cls(tomllib.loads(Path(path).read_text(encoding="utf-8")))

    def classify_id(self, lid, ecosystem):
        eco = self.ecosystems.get(ecosystem, {})
        if any(fnmatch.fnmatchcase(lid.upper(), pat.upper()) for pat in self.deny + eco.get("deny", [])):
            return "deny"
        if any(fnmatch.fnmatchcase(lid.upper(), pat.upper()) for pat in eco.get("review", [])):
            return "review"
        if any(fnmatch.fnmatchcase(lid.upper(), pat.upper()) for pat in self.allow + eco.get("allow", [])):
            return "allow"
        return "review"

    def classify(self, expr, ecosystem):
        """allow / review（要登记）/ deny。OR 取最有利的一支，AND 取最严的。"""
        rank = {"allow": 0, "review": 1, "deny": 2}
        try:
            tree = parse_spdx(expr)
        except SpdxError:
            return "review"

        def walk(t):
            if t[0] == "id":
                return self.classify_id(t[1], ecosystem)
            if t[0] == "with":
                base = self.classify_id(t[1], ecosystem)
                exc = t[2].upper()
                if any(fnmatch.fnmatchcase(exc, pat.upper()) for pat in self.deny):
                    return "deny"
                if any(fnmatch.fnmatchcase(exc, pat.upper()) for pat in self.allow_exceptions):
                    return base
                return max(base, "review", key=rank.get)
            results = [walk(x) for x in t[1]]
            pick = min if t[0] == "or" else max
            return pick(results, key=rank.get)

        return walk(tree)

    def exception_for(self, c, agent=None):
        """这个组件登记过的例外。写了 agents 的例外只在这些 agent 的镜像里有效（别的 agent 带上了同一个专有组件，
        要重新审查，不能沿用）。text_sha256 是一个值时原文里要有这一份；是列表时原文（包括子目录里的）要正好是这几份。"""
        shown = c["license"] or c["declared"] or ""
        for e in self.exceptions:
            if e["ecosystem"] != c["ecosystem"] or not fnmatch.fnmatchcase(c["name"], e["name"]):
                continue
            if not fnmatch.fnmatchcase(c["version"], e.get("version", "*")):
                continue
            if e["license"] != shown:
                continue
            if e.get("agents") and agent not in e["agents"]:
                continue
            pins = e.get("text_sha256")
            have = set(c.get("text_sha256") or []) | set(c.get("bundled_sha256") or [])
            if isinstance(pins, str) and pins not in have:
                continue
            if isinstance(pins, list) and set(pins) != have:
                continue
            return e
        return None


    def asset_for(self, c, asset, agent=None):
        """包里这个字体（或别的资源）登记过的许可证：按生态、包名、版本、包里的路径匹配（都可以用通配符，path 可以是列表）。"""
        for e in self.assets:
            if e["ecosystem"] != c["ecosystem"] or not fnmatch.fnmatchcase(c["name"], e["name"]):
                continue
            if not fnmatch.fnmatchcase(c["version"], e.get("version", "*")):
                continue
            if not any(fnmatch.fnmatchcase(asset["path"], pat) for pat in _as_list(e["path"])):
                continue
            if e.get("agents") and agent not in e["agents"]:
                continue
            return e
        return None


def _as_list(v):
    return [v] if isinstance(v, str) else list(v or [])


def check_assets(c, label, policy, agent, used, comps):
    """包里的字体都要登记许可证（[[asset]]）：字体常常和包的代码分开授权，有的是商用字体，不能跟着包算。
    登记写了 license_file（包里的路径）的，包里要有这份原文、核对得上登记的许可证；写了 upstream 的，
    notices/ 里要有这个组件（原文从上游补）。"""
    errors, missing, checked = [], [], set()
    for a in c.get("assets") or []:
        e = policy.asset_for(c, a, agent)
        if e is None:
            missing.append(a["path"])
            continue
        used.add(id(e))
        if id(e) in checked:
            continue
        checked.add(id(e))
        verdict = policy.classify(e["license"], c["ecosystem"])
        if verdict != "allow":
            errors.append("%s：字体 %s 登记的许可证 %s %s" % (label, a["path"], e["license"],
                                                         "在禁止名单里" if verdict == "deny" else "不在放行名单里"))
        texts = _as_list(e.get("license_file"))
        found = [d for d in c.get("file_licenses") or [] if d.get("verified") and _covers(e["license"], d["proposed"])]
        bad = [pat for pat in texts if not any(fnmatch.fnmatchcase(d.get("path", ""), pat) for d in found)]
        if bad:
            errors.append("%s：登记说字体 %s 的 %s 原文在 %s，包里没有核对得上的这份原文" % (label, a["path"], e["license"], "、".join(bad)))
        if e.get("upstream") and not any(x["ecosystem"] == "upstream" and x["name"] == e["upstream"] and x["license"]
                                         and all(_covers(x["license"], i) for i in spdx_ids(parse_spdx(e["license"])))
                                         for x in comps):
            errors.append("%s：登记说字体 %s 的原文由 notices/ 里的 %s 补上，清单里没有这个组件（或许可证对不上）"
                          % (label, a["path"], e["upstream"]))
        if not texts and not e.get("upstream"):
            errors.append("%s：[[asset]] %s 要写 license_file（包里的原文）或 upstream（notices/ 里补的原文）" % (label, e["path"]))
    if missing:
        errors.append("%s：带了 %d 个没登记的字体（%s）。字体常常单独授权（有的是商用字体），查清许可证后在 policy.toml "
                      "登记 [[asset]]，见 docs/licenses.md" % (label, len(missing), "、".join(missing[:6]) + ("……" if len(missing) > 6 else "")))
    return errors


def check(inventory, policy, manifest=None, out=sys.stdout):
    """返回 (错误列表, 警告列表, 汇总的 Markdown)。"""
    errors, warnings, registered = [], [], []
    comps = inventory["components"]
    agent = manifest["agent"]["id"] if manifest else None
    used_assets = set()
    for c in comps:
        label = "%s %s@%s" % (c["ecosystem"], c["name"], c["version"])
        errors += check_assets(c, label, policy, agent, used_assets, comps)
        eco = policy.ecosystems.get(c["ecosystem"], {})
        if eco.get("mode") == "deny-only":
            # Debian main 都是自由软件；只拦明确禁止的（DEP-5 里声明的许可证名，写法五花八门：AGPL-3+、AGPLv3+、
            # GNU-AGPL-3……，按名字匹配之外再按关键词）。
            for n in re.split(r",\s*", c["declared"] or ""):
                spdx = normalize_declared(n) or n
                if n and (any(fnmatch.fnmatchcase(spdx.upper(), pat.upper()) for pat in policy.deny) or _DENY_WORDS.search(n)):
                    errors.append("%s：许可证 %s 在禁止名单里" % (label, n))
            continue
        exc = policy.exception_for(c, manifest["agent"]["id"] if manifest else None)
        if exc:
            registered.append((c, exc))
            # 登记管的是这个包的许可证；包里新出现的禁止名单许可证、限制性说法登记时没看过，照样要报。
            errors += cross_check(c, label, policy, registered=True)
            new_terms = [t for t in c.get("restricted_terms") or [] if t not in _as_list(exc.get("restricted_terms"))]
            if new_terms:
                errors.append("%s：登记过例外，但包里的原文有限制性的说法（%s），登记时没确认过。复核后在登记里写上 "
                              "restricted_terms" % (label, "、".join(new_terms)))
            continue
        if c["license"] is None:
            errors.append("%s：认不出许可证（声明：%s）。查清后在 policy.toml 登记，见 docs/licenses.md" % (label, c["declared"] or "无"))
            continue
        verdict = policy.classify(c["license"], c["ecosystem"])
        if verdict == "deny":
            errors.append("%s：许可证 %s 在禁止名单里（网络 copyleft 或限制商用、托管）" % (label, c["license"]))
        elif verdict == "review":
            errors.append("%s：许可证 %s 需要单独审查，确认能用后在 policy.toml 的 [[exception]] 登记" % (label, c["license"]))
        errors += cross_check(c, label, policy)
        if not c["files"] and not c.get("generic_files") and c["ecosystem"] != "deb":
            warnings.append(label)

    present = {"%s:%s@%s" % (c["ecosystem"], c["name"], c["version"]) for c in comps}
    stale = {}
    for c in comps:
        for ref in c.get("applies_to") or []:
            if ref not in present:
                stale.setdefault((c.get("notices_dir"), ref), True)
    for d, ref in stale:
        errors.append("deploy/templates/notices/%s 的原文是按 %s 核对的，镜像里没有这个版本：上游升级了，"
                      "按 docs/licenses.md 重新核对原文后更新 sources.toml" % (d, ref))

    unused = [e for e in policy.exceptions if e.get("agents") and manifest and manifest["agent"]["id"] in e["agents"]
              and not any(x is e for _, x in registered)]
    for e in unused:
        errors.append("policy.toml 登记的 %s %s（%s）在清单里没找到：上游换了包名或许可证？复核后更新登记" % (e["ecosystem"], e["name"], e["license"]))
    for e in policy.assets:
        if e.get("agents") and agent in e["agents"] and id(e) not in used_assets:
            errors.append("policy.toml 登记的字体 %s %s 的 %s 在清单里没找到：上游换了包名或目录？复核后更新登记"
                          % (e["ecosystem"], e["name"], "、".join(_as_list(e["path"]))))

    if manifest:
        errors += check_manifest(inventory, policy, manifest)

    summary = render_summary(inventory, errors, warnings, registered)
    return errors, warnings, summary


def cross_check(c, label, policy, registered=False):
    """声明和包里的许可证原文对不上，声明里却没有：
    - 禁止名单里的许可证：文件里任何一个提名、任何位置的正文标题或授权声明（核对过没有都算）；
    - 要审查的许可证（GPL……）：核对过的，或者是按标题提名的（核对不上也算：GPL 的原文前面加了一句话照样是 GPL）；
      包自己根目录的许可证文件，第一个提名是要审查的许可证、又什么都核对不上，也算。
    声明写 MIT、包里却是 GPL 的原文，以原文为准要人看。registered：登记过例外的包只查禁止名单。"""
    errors = []
    license = c["license"]
    for f in c.get("file_licenses") or []:
        lid = f.get("proposed")
        ids = list(dict.fromkeys(([lid] if lid else []) + (f.get("candidates") or [])))
        for x in ids:
            verdict = policy.classify_id(x, c["ecosystem"])
            if verdict == "allow" or (license and _covers(license, x)):
                continue
            if verdict == "deny":
                flagged = True
            elif registered or x != lid:
                flagged = False
            else:
                flagged = f.get("verified") or f.get("titled") or not f.get("bundled")
            if flagged:
                errors.append("%s：许可证是 %s，但包里的 %s %s %s，声明里没有。查清后改正或在 policy.toml 登记"
                              % (label, license, f.get("path") or f["file"], "是" if x == lid and f.get("verified") else "像是", x))
    return errors


def _license_shown(c, policy, agent=None):
    exc = policy.exception_for(c, agent)
    if exc and exc.get("as"):
        return exc["as"]
    return c["license"] or c["declared"]


def check_manifest(inventory, policy, manifest):
    """清单 [install] 里的包都在镜像里；清单写的 agent.license 和 policy.toml 指定的那个包的许可证一致。"""
    errors = []
    agent = manifest["agent"]["id"]
    comps = inventory["components"]
    inst = manifest.get("install", {})
    wanted = []
    for spec in inst.get("npm", []):
        at = spec.rindex("@", 1)
        wanted.append(("npm", spec[:at], spec[at + 1:]))
    for spec in inst.get("pip", []):
        name, version = spec.split("==", 1)
        wanted.append(("pypi", pypi_norm(name.split("[", 1)[0]), version))
    for eco, name, version in wanted:
        hit = [c for c in comps if c["ecosystem"] == eco and (pypi_norm(c["name"]) if eco == "pypi" else c["name"]) == name and c["root_level"]]
        if not hit:
            errors.append("清单 [install] 的 %s %s 不在镜像里" % (eco, name))
        elif not any(c["version"] == version for c in hit):
            errors.append("清单 [install] 锁定 %s %s@%s，镜像里是 %s" % (eco, name, version, ", ".join(c["version"] for c in hit)))
    rule = policy.agents.get(agent)
    if not rule:
        errors.append("policy.toml 没有 [agents.%s]：要写明 agent.license 对应哪个包" % agent)
        return errors
    eco, name = rule["license_of"].split(":", 1)
    hit = [c for c in comps if c["ecosystem"] == eco and c["name"] == name]
    if not hit:
        errors.append("[agents.%s] license_of 指的 %s 不在镜像里" % (agent, rule["license_of"]))
        return errors
    shown = _license_shown(hit[0], policy, agent)
    if shown != manifest["agent"]["license"]:
        errors.append(
            "清单 agent.license 是 %s，但 %s 的许可证是 %s：上游改了许可证？复核后改清单（App 的目录里显示的是清单写的）"
            % (manifest["agent"]["license"], rule["license_of"], shown)
        )
    return errors


def render_summary(inventory, errors, warnings, registered):
    comps = inventory["components"]
    by_eco = {}
    for c in comps:
        by_eco[c["ecosystem"]] = by_eco.get(c["ecosystem"], 0) + 1
    lines = [
        "### 许可证：%s" % inventory["subject"],
        "",
        "%d 个组件（%s）。%s" % (
            len(comps),
            "、".join("%s %d" % kv for kv in sorted(by_eco.items())),
            "**%d 个问题**" % len(errors) if errors else "符合策略",
        ),
        "",
    ]
    if errors:
        lines += ["问题：", ""] + ["- %s" % e for e in errors] + [""]
    if registered:
        lines += ["登记过的例外：", ""]
        for c, e in registered:
            lines.append("- %s %s@%s：%s（%s）" % (c["ecosystem"], c["name"], c["version"], e.get("as") or e["license"], e["reason"]))
        lines.append("")
    generic = [c for c in comps if not c["files"] and c.get("generic_files")]
    if generic:
        lines.append("%d 个包没带许可证原文，用的是 SPDX 标准文本加元数据里的作者。" % len(generic))
        lines.append("")
    if warnings:
        lines.append("%d 个包既没带原文、也没有对应的标准文本（tools/licenses/spdx/），例如：%s" % (len(warnings), "、".join(warnings[:5])))
        lines.append("")
    return "\n".join(lines)


def esc_data(s):
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def esc_prop(s):
    return esc_data(s).replace(":", "%3A").replace(",", "%2C")


# ---------------------------------------------------------------------------
# 命令行

def cmd_scan(args):
    inv = Inventory(args.out, args.subject)
    root_names = []
    if args.manifest:
        m = tomllib.loads(Path(args.manifest).read_text(encoding="utf-8"))
        root_names = [s.split("==", 1)[0].split("[", 1)[0] for s in m.get("install", {}).get("pip", [])]
    for root in args.npm_root or []:
        scan_npm(inv, root)
    for pattern in args.npm_package or []:
        scan_npm_packages(inv, pattern)
    for sp in args.site_packages or []:
        for path in sorted(Path("/").glob(sp.lstrip("/"))) if any(ch in sp for ch in "*?[") else [Path(sp)]:
            scan_python(inv, path, root_names)
    if args.deb:
        scan_deb(inv)
    if args.node:
        scan_runtime_node(inv)
    for d in args.extra or []:
        scan_extra(inv, d)
    for d in args.merge or []:
        inv.merge(d)
    doc = inv.write()
    print("%s：%d 个组件 → %s" % (args.subject, len(doc["components"]), args.out), file=sys.stderr)


def cmd_cargo(args):
    inv = Inventory(args.out, args.subject or "+".join(args.package))
    scan_cargo(inv, args.package, target=args.target, manifest_path=args.manifest_path, metadata_json=args.metadata,
               locked=not args.no_locked)
    doc = inv.write()
    print("%s：%d 个 crate → %s" % (inv.subject, len(doc["components"]), args.out), file=sys.stderr)


def cmd_check(args):
    inventory = json.loads(Path(args.inventory).read_text(encoding="utf-8"))
    policy = Policy.load(args.policy)
    manifest = tomllib.loads(Path(args.manifest).read_text(encoding="utf-8")) if args.manifest else None
    errors, warnings, summary = check(inventory, policy, manifest)
    print(summary)
    actions = os.environ.get("GITHUB_ACTIONS") == "true"
    if actions:
        file = args.manifest or str(args.policy)
        for e in errors[:MAX_ANNOTATIONS]:
            print("::error file=%s,title=%s::%s" % (esc_prop(file), esc_prop("许可证：" + inventory["subject"]), esc_data(e)))
        if len(errors) > MAX_ANNOTATIONS:
            print("::error title=%s::还有 %d 个问题，见运行摘要" % (esc_prop("许可证：" + inventory["subject"]), len(errors) - MAX_ANNOTATIONS))
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
                f.write(summary + "\n")
    return 1 if errors else 0


_COPYLEFT = ("GPL-*", "LGPL-*", "AGPL-*", "MPL-*", "EPL-*", "CDDL-*", "LicenseRef-*GPL-*")
# copyleft 的强弱：只管改过的文件（MPL、EPL、CDDL）< 库本身（LGPL）< 整个程序（GPL）< 网络服务也算（AGPL）。
_COPYLEFT_RANK = (("*AGPL-*", 4), ("*LGPL-*", 2), ("*GPL-*", 3))


def _copyleft_rank(lid):
    for pat, rank in _COPYLEFT_RANK:
        if fnmatch.fnmatchcase(lid.upper(), pat.upper()):
            return rank
    return 1


def copyleft_ids(expr):
    """许可证表达式里非用不可的 copyleft 许可证：OR 里有一支不是 copyleft 就不算（我们选那一支），都是 copyleft
    时选限制最少的一支（最强的那个许可证最弱，一样时许可证少的）；AND 全算。"""
    try:
        tree = parse_spdx(expr)
    except SpdxError:
        return []

    def walk(t):
        if t[0] in ("id", "with"):
            return [t[1]] if any(fnmatch.fnmatchcase(t[1].upper(), pat.upper()) for pat in _COPYLEFT) else []
        parts = [walk(x) for x in t[1]]
        if t[0] == "or":
            return [] if any(not x for x in parts) else min(parts, key=lambda x: (max(map(_copyleft_rank, x)), len(x)))
        return [i for x in parts for i in x]

    return list(dict.fromkeys(walk(tree)))


def summarize(inventories):
    """几个清单的汇总（docs/licenses.md 第 7 节用）：每个清单的组件数，和非用不可的 copyleft 组件（Debian 包除外）。"""
    lines = ["| 清单 | 组件 |", "|---|---|"]
    copyleft = {}
    for inv in inventories:
        comps = inv["components"]
        by_eco = {}
        for c in comps:
            by_eco[c["ecosystem"]] = by_eco.get(c["ecosystem"], 0) + 1
        lines.append("| `%s` | %d（%s） |" % (inv["subject"], len(comps), "、".join("%s %d" % kv for kv in sorted(by_eco.items()))))
        for c in comps:
            if c["ecosystem"] == "deb" or not c.get("license"):
                continue
            for lid in copyleft_ids(c["license"]):
                copyleft.setdefault(lid, {}).setdefault("%s %s" % (c["ecosystem"], c["name"]), set()).add(inv["subject"])
    lines += ["", "非用不可的 copyleft（OR 里有宽松一支的不算；Debian 包见各自的 copyright）：", ""]
    if not copyleft:
        lines.append("- 无")
    for lid in sorted(copyleft):
        items = ["%s（%s）" % (name, "、".join(sorted(subjects))) for name, subjects in sorted(copyleft[lid].items())]
        lines.append("- %s：%s" % (lid, "；".join(items)))
    return "\n".join(lines) + "\n"


def cmd_summary(args):
    print(summarize([json.loads(Path(f).read_text(encoding="utf-8")) for f in args.inventory]), end="")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("scan", help="扫描装好的包，写清单")
    s.add_argument("--out", required=True)
    s.add_argument("--subject", required=True, help="清单说的是什么，比如 agents/claude:0.90.0")
    s.add_argument("--npm-root", action="append", help="node_modules 目录，可给多个")
    s.add_argument("--npm-package", action="append", help="不在 node_modules 里的 npm 包目录，可以用通配符（基础镜像的 /opt/yarn-*）")
    s.add_argument("--site-packages", action="append", help="site-packages 目录，可以用通配符")
    s.add_argument("--manifest", help="agent 清单（用来认 [install] 里直接装的 Python 包）")
    s.add_argument("--deb", action="store_true", help="扫描 dpkg 装的包")
    s.add_argument("--node", action="store_true", help="记下 Node.js 本身")
    s.add_argument("--extra", action="append", help="额外原文的目录（里面有 sources.toml）")
    s.add_argument("--merge", action="append", help="并入另一个清单目录（比如 agent-shim 的 crate 清单）")
    s.set_defaults(func=cmd_scan)

    c = sub.add_parser("cargo", help="列出工作区程序依赖的 crate，写清单")
    c.add_argument("--out", required=True)
    c.add_argument("--subject")
    c.add_argument("-p", "--package", action="append", required=True, help="工作区里的程序包名，可给多个")
    c.add_argument("--target", help="只算这个平台上的依赖，比如 x86_64-unknown-linux-gnu；不给就算全部平台")
    c.add_argument("--manifest-path")
    c.add_argument("--no-locked", action="store_true",
                   help="不加 --locked：给上游工程（比如 Codex）生成清单、它的 Cargo.lock 只差工作区自己的版本号时用")
    c.add_argument("--metadata", help=argparse.SUPPRESS)  # 测试用：直接给 cargo metadata 的输出
    c.set_defaults(func=cmd_cargo)

    u = sub.add_parser("upstream-cargo", help="按 sources.toml 的 [[cargo]] 从上游源码生成 crate 清单")
    u.add_argument("notices_dir", help="deploy/templates/notices/<agent id>")
    u.set_defaults(func=cmd_upstream_cargo)

    k = sub.add_parser("check", help="按策略检查清单")
    k.add_argument("inventory")
    k.add_argument("--policy", default=str(Path(__file__).with_name("policy.toml")))
    k.add_argument("--manifest", help="agent 清单：再核对 [install] 和 agent.license")
    k.set_defaults(func=cmd_check)

    m = sub.add_parser("summary", help="几个清单的汇总：组件数、非用不可的 copyleft 组件")
    m.add_argument("inventory", nargs="+")
    m.set_defaults(func=cmd_summary)

    t = sub.add_parser("self-test", help="内置测试")
    t.set_defaults(func=lambda a: self_test())

    args = p.parse_args(argv)
    return args.func(args) or 0


# ---------------------------------------------------------------------------
# 测试

def _spdx_text(lid, holder="2024 Someone"):
    """测试用：SPDX 标准全文，占位写法换成具体的版权方。"""
    return _PLACEHOLDER.sub(holder, (SPDX_DIR / ("%s.txt" % lid)).read_text(encoding="utf-8"))


MIT_TEXT = _spdx_text("MIT")
APACHE_TEXT = _spdx_text("Apache-2.0")
BSD3_TEXT = _spdx_text("BSD-3-Clause")
ISC_TEXT = _spdx_text("ISC")
ZERO_BSD_TEXT = _spdx_text("0BSD")

AGPL_TEXT = """                    GNU AFFERO GENERAL PUBLIC LICENSE
                       Version 3, 19 November 2007
"""

MPL_TEXT = """Mozilla Public License Version 2.0
==================================

1. Definitions
--------------

1.1. "Contributor"
    means each individual or legal entity that creates, contributes to
    the creation of, or owns Covered Software.

1.12. "Secondary License"
    means either the GNU General Public License, Version 2.0, the GNU
    Lesser General Public License, Version 2.1, the GNU Affero General
    Public License, Version 3.0, or any later versions of those
    licenses.
"""

PROPRIETARY_TEXT = """© Anthropic PBC. All rights reserved. Use is subject to the Legal Agreements outlined here: https://example.com/legal.
"""

TEST_POLICY = """
allow = ["MIT", "Apache-2.0", "BSD-*", "ISC", "0BSD", "LGPL-*", "MPL-2.0", "LicenseRef-BSD-Unspecified"]
allow_exceptions = ["LLVM-exception"]
deny = ["AGPL-*", "SSPL-*", "BUSL-*", "Commons-Clause", "LicenseRef-Commons-Clause", "CC-BY-NC-*", "EUPL-*", "OSL-*", "RPL-*", "CPAL-*"]

[ecosystem.cargo]
review = ["LGPL-*"]

[ecosystem.deb]
mode = "deny-only"

[[exception]]
ecosystem = "npm"
name = "@vendor/sdk"
version = "1.*"
license = "SEE LICENSE IN README.md"
as = "LicenseRef-Vendor-Commercial"
reason = "专有，法务确认过"
agents = ["demo"]

[agents.demo]
license_of = "npm:@vendor/sdk"
"""


def self_test():
    failures = []

    def eq(got, want, what):
        if got != want:
            failures.append("%s：得到 %r，应该是 %r" % (what, got, want))

    # SPDX 解析和规范化
    eq(canonical_spdx("MIT"), "MIT", "单个标识")
    eq(canonical_spdx("mit or apache-2.0"), "MIT OR Apache-2.0", "小写运算符和标识")
    eq(canonical_spdx("(MIT OR Apache-2.0) AND Unicode-3.0"), "(MIT OR Apache-2.0) AND Unicode-3.0", "括号")
    eq(canonical_spdx("Apache-2.0 WITH LLVM-exception"), "Apache-2.0 WITH LLVM-exception", "WITH")
    eq(canonical_spdx("MIT License"), None, "自由文本不是 SPDX")
    eq(canonical_spdx("(MIT"), None, "括号不配对")
    eq(canonical_spdx("MIT AND"), None, "表达式不完整")
    eq(canonical_spdx("LicenseRef-Foo"), "LicenseRef-Foo", "LicenseRef")
    eq(normalize_declared("MIT/Apache-2.0"), "MIT OR Apache-2.0", "Cargo 的旧写法")
    eq(normalize_declared("Apache-2.0 / MIT"), "Apache-2.0 OR MIT", "Cargo 的旧写法（带空格）")
    eq(normalize_declared("mit/x11"), "MIT", "MIT/X11 不是两个许可证")
    eq(normalize_declared("Apache License, Version 2.0"), "Apache-2.0", "自由文本")
    eq(normalize_declared("(MIT)"), "MIT", "整个包在括号里")
    eq(normalize_declared("MIT or Apache 2.0"), "MIT OR Apache-2.0", "混写")
    eq(normalize_declared("BSD"), "LicenseRef-BSD-Unspecified", "含糊的 BSD")
    eq(normalize_declared("SEE LICENSE IN LICENSE.md"), None, "SEE LICENSE IN 认不出")
    eq(normalize_declared(""), None, "空")

    # 原文识别
    eq(detect_text(MIT_TEXT), "MIT", "MIT 原文")
    eq(detect_text(APACHE_TEXT), "Apache-2.0", "Apache 原文")
    eq(detect_text(BSD3_TEXT), "BSD-3-Clause", "BSD-3 原文")
    eq(detect_text(ISC_TEXT), "ISC", "ISC 原文")
    eq(detect_text(ZERO_BSD_TEXT), "0BSD", "0BSD 原文")
    eq(identify(AGPL_TEXT)[0], "AGPL-3.0-only", "AGPL 原文（提名；没有标准文本，核对不了）")
    eq(detect_text(PROPRIETARY_TEXT), None, "专有声明认不出")
    eq(identify(MPL_TEXT)[0], "MPL-2.0", "MPL-2.0 正文里提到 AGPL 不算 AGPL")
    eq(detect_text(_spdx_text("MPL-2.0")), "MPL-2.0", "MPL-2.0 全文核对得上")
    eq(detect_text("Copyright 2020 X\n\n" + _HEADERS["Apache-2.0"]), "Apache-2.0", "Apache 头部声明")
    eq(detect_text("Copyright 2020 X\n\nLicensed under the Apache License, Version 2.0 (the \"License\"); "
                   "except that you may not offer it as a service."), None, "改过的 Apache 头部核对不上")
    eq(detect_text("# MIT License\n\n" + MIT_TEXT), "MIT", "Markdown 标题")
    eq(detect_text("Some notice. This product includes software under the GNU General Public License."), None, "顺带提到 GPL 不算")
    # tools/licenses/spdx/ 里的每份标准文本都认得出是它自己（相近的许可证：X11 和 MIT、curl 和 ISC、Python 和 PSF、
    # BSD-1 和 BSD-2，靠核对分开）。
    for path in sorted(SPDX_DIR.glob("*.txt")):
        if path.stem not in ("license-ids", "exception-ids"):
            eq(identify(_spdx_text(path.stem)), (path.stem, True), "%s 标准文本" % path.stem)
    eq(identify(APACHE_TEXT.replace("(c) You must retain", "(c)  You must retain")), ("Apache-2.0", True),
       "Apache 的条款“(c) You must retain”不是版权行")
    eq(is_legal_file("LICENSE"), True, "LICENSE")
    eq(is_legal_file("LICENSE-APACHE"), True, "LICENSE-APACHE")
    eq(is_legal_file("license.md"), True, "license.md")
    eq(is_legal_file("NOTICE.txt"), True, "NOTICE.txt")
    eq(is_legal_file("license.js"), False, "代码文件不算")
    eq(is_legal_file("README.md"), False, "README 不算")

    # 策略判定
    pol = Policy(tomllib.loads(TEST_POLICY))
    eq(pol.classify("MIT", "npm"), "allow", "放行")
    eq(pol.classify("AGPL-3.0-only", "npm"), "deny", "禁止")
    eq(pol.classify("MIT OR AGPL-3.0-only", "npm"), "allow", "OR 取有利的")
    eq(pol.classify("MIT AND AGPL-3.0-only", "npm"), "deny", "AND 取最严的")
    eq(pol.classify("GPL-3.0-only", "npm"), "review", "GPL 要登记")
    eq(pol.classify("GPL-2.0-only OR MIT", "npm"), "allow", "GPL 或 MIT")
    eq(pol.classify("LGPL-3.0-only", "npm"), "allow", "LGPL 在 npm 放行")
    eq(pol.classify("LGPL-3.0-only", "cargo"), "review", "LGPL 在 cargo 要登记（静态链接）")
    eq(pol.classify("Apache-2.0 WITH LLVM-exception", "cargo"), "allow", "WITH 按主许可证")
    eq(pol.classify("not spdx", "npm"), "review", "解析不了的要登记")

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        # npm：顶层包、带 scope 的包、嵌套的包、包里非包的 package.json、各种 license 字段写法
        nm = tmp / "node_modules"

        def pkg(path, data, files=None):
            path.mkdir(parents=True, exist_ok=True)
            (path / "package.json").write_text(json.dumps(data))
            for name, text in (files or {}).items():
                (path / name).write_text(text)

        pkg(nm / "a", {"name": "a", "version": "1.0.0", "license": "MIT"}, {"LICENSE": MIT_TEXT})
        pkg(nm / "a" / "lib", {"type": "module"})
        pkg(nm / "a" / "node_modules" / "b", {"name": "b", "version": "2.0.0", "license": {"type": "ISC"}, "author": {"name": "Bea"}})
        pkg(nm / "a" / "node_modules" / "c", {"name": "c", "version": "0.1.0", "licenses": [{"type": "MIT"}, {"type": "Apache-2.0"}]})
        pkg(nm / "@vendor" / "sdk", {"name": "@vendor/sdk", "version": "1.2.0", "license": "SEE LICENSE IN README.md"},
            {"LICENSE.md": PROPRIETARY_TEXT, "README.md": "readme"})
        pkg(nm / "d", {"name": "d", "version": "3.0.0"}, {"LICENSE.txt": BSD3_TEXT})
        pkg(nm / "e", {"name": "e", "version": "1.0.0", "license": "AGPL-3.0"})
        pkg(nm / "f", {"name": "f", "version": "1.0.0", "license": "Apache 2.0"}, {"NOTICE": "Copyright f"})
        pkg(nm / "g", {"name": "g", "version": "1.0.0", "license": "MIT"}, {"license.js": "code"})
        pkg(nm / "a" / "node_modules" / "d", {"name": "d", "version": "3.0.0"}, {"LICENSE.txt": BSD3_TEXT})

        out = tmp / "out"
        inv = Inventory(out, "test")
        scan_npm(inv, nm)
        got = {c["name"]: c for c in inv.components.values()}
        eq(sorted(got), ["@vendor/sdk", "a", "b", "c", "d", "e", "f", "g"], "npm 包")
        eq(got["a"]["license"], "MIT", "npm license 字符串")
        eq(got["a"]["root_level"], True, "顶层包")
        eq(got["b"]["license"], "ISC", "npm license 对象")
        eq(got["b"]["root_level"], False, "嵌套的不是顶层")
        eq(got["b"]["generic_files"], ["texts/spdx/ISC.txt"] if (SPDX_DIR / "ISC.txt").is_file() else [], "没带原文用标准文本")
        eq(got["b"]["authors"], "Bea", "npm 作者")
        eq(got["a"]["generic_files"], [], "带了原文就不用标准文本")
        eq(got["c"]["license"], "MIT OR Apache-2.0", "npm licenses 数组")
        eq(got["@vendor/sdk"]["license"], None, "专有的认不出")
        eq(got["@vendor/sdk"]["root_level"], True, "带 scope 的顶层包")
        eq(sorted(Path(f).name for f in got["@vendor/sdk"]["files"]), ["LICENSE.md", "README.md"], "SEE LICENSE IN 指的文件")
        eq(got["d"]["license"], "BSD-3-Clause", "没声明时看原文")
        eq(got["d"]["license_from"], "text", "来源是原文")
        eq(got["d"]["locations"], 2, "同名同版本只记一次")
        eq(got["e"]["license"], "AGPL-3.0", "AGPL")
        eq(got["f"]["license"], "Apache-2.0", "自由文本声明")
        eq([Path(f).name for f in got["f"]["files"]], ["NOTICE"], "NOTICE 复制")
        eq(got["g"]["files"], [], "代码文件不当原文")
        eq((out / got["a"]["files"][0]).read_text(), MIT_TEXT, "原文复制到 texts/")

        # Python：License-Expression、分类、原文、整篇正文塞进 License 字段
        sp = tmp / "site-packages"

        def dist(name, version, headers, files=None, licenses_dir=None):
            d = sp / ("%s-%s.dist-info" % (name.replace("-", "_"), version))
            d.mkdir(parents=True)
            body = "Metadata-Version: 2.4\nName: %s\nVersion: %s\n" % (name, version) + "".join("%s: %s\n" % h for h in headers)
            (d / "METADATA").write_text(body + "\nlong description\n")
            for fname, text in (files or {}).items():
                (d / fname).write_text(text)
            for fname, text in (licenses_dir or {}).items():
                (d / "licenses").mkdir(exist_ok=True)
                (d / "licenses" / fname).write_text(text)

        dist("hermes-agent", "0.19.0", [("License-Expression", "MIT"), ("License-File", "LICENSE")], licenses_dir={"LICENSE": MIT_TEXT})
        dist("old-style", "1.0", [("License", "BSD"), ("Classifier", "License :: OSI Approved :: BSD License")], {"LICENSE.txt": BSD3_TEXT})
        dist("classified", "2.0", [("Classifier", "License :: OSI Approved :: Apache Software License")])
        dist("text-in-field", "1.0", [("License", MIT_TEXT.replace("\n", "\n        "))], {"LICENSE": MIT_TEXT})
        dist("dual", "1.0", [("Classifier", "License :: OSI Approved :: MIT License"), ("Classifier", "License :: OSI Approved :: Apache Software License")])
        dist("unknown", "1.0", [("License", "UNKNOWN")])
        dist("dateutil", "2.9.0", [("License", "Dual License"), ("Classifier", "License :: OSI Approved :: BSD License"),
                                   ("Classifier", "License :: OSI Approved :: Apache Software License")])
        dist("pathspec", "1.1.1", [("Classifier", "License :: OSI Approved :: Mozilla Public License 2.0 (MPL 2.0)"), ("License-File", "LICENSE")],
             licenses_dir={"LICENSE": MPL_TEXT})
        inv = Inventory(out, "test")
        scan_python(inv, sp, ["hermes-agent"])
        got = {c["name"]: c for c in inv.components.values()}
        eq(got["hermes-agent"]["license"], "MIT", "License-Expression")
        eq(got["hermes-agent"]["root_level"], True, "直接装的包")
        eq([Path(f).name for f in got["hermes-agent"]["files"]], ["LICENSE"], "licenses/ 下的原文")
        eq(got["old-style"]["license"], "BSD-3-Clause", "含糊的声明看原文")
        eq(got["classified"]["license"], "Apache-2.0", "只有分类")
        eq(got["text-in-field"]["license"], "MIT", "正文塞进 License 字段")
        eq(got["dual"]["license"], "MIT AND Apache-2.0", "两个分类按 AND（分类不说明是任选其一）")
        eq(got["unknown"]["license"], None, "UNKNOWN")
        eq((got["pathspec"]["license"], got["pathspec"]["license_from"]), ("MPL-2.0", "classifier"), "明确的分类比原文识别优先")
        eq(got["dateutil"]["license"], "LicenseRef-BSD-Unspecified AND Apache-2.0", "“Dual License”不算声明，分类按 AND")

        # extra 原文
        ex = tmp / "extra"
        ex.mkdir()
        (ex / "NOTICE").write_text("Copyright OpenAI")
        (ex / "sources.toml").write_text('[[file]]\ncomponent = "codex"\nversion = "0.1"\nlicense = "Apache-2.0"\npath = "NOTICE"\nurl = "https://example.com/NOTICE"\n')
        inv = Inventory(out, "test")
        scan_extra(inv, ex)
        c = inv.components[("upstream", "codex", "0.1")]
        eq((c["license"], [Path(f).name for f in c["files"]], c["urls"]), ("Apache-2.0", ["NOTICE"], ["https://example.com/NOTICE"]), "extra")

        # cargo：只算普通依赖，dev 依赖和只在构建时用的不算；license 为空时看 license_file
        crate_dir = tmp / "registry"
        for n in ("dep", "devdep", "builddep", "lf"):
            (crate_dir / n).mkdir(parents=True)
            (crate_dir / n / "Cargo.toml").write_text("")
        (crate_dir / "dep" / "LICENSE-MIT").write_text(MIT_TEXT)
        (crate_dir / "lf" / "COPYING").write_text(ISC_TEXT)

        def cp(n, lic, lf=None, ws=False):
            return {"id": n, "name": n, "version": "1.0.0", "license": lic, "license_file": lf,
                    "manifest_path": str((tmp / "ws" if ws else crate_dir / n) / "Cargo.toml")}

        meta = {
            "packages": [cp("app", "UNLICENSED", ws=True), cp("dep", "MIT/Apache-2.0"), cp("devdep", "AGPL-3.0"),
                         cp("builddep", "GPL-3.0"), cp("lf", None, "COPYING")],
            "workspace_members": ["app"],
            "resolve": {"nodes": [
                {"id": "app", "deps": [{"pkg": "dep", "dep_kinds": [{"kind": None}]}, {"pkg": "devdep", "dep_kinds": [{"kind": "dev"}]},
                                       {"pkg": "builddep", "dep_kinds": [{"kind": "build"}]}]},
                {"id": "dep", "deps": [{"pkg": "lf", "dep_kinds": [{"kind": None}]}]},
                {"id": "devdep", "deps": []}, {"id": "builddep", "deps": []}, {"id": "lf", "deps": []},
            ]},
        }
        mj = tmp / "meta.json"
        mj.write_text(json.dumps(meta))
        inv = Inventory(out, "app")
        scan_cargo(inv, ["app"], metadata_json=mj)
        got = {c["name"]: c for c in inv.components.values()}
        eq(sorted(got), ["dep", "lf"], "cargo 只算普通依赖")
        eq(got["dep"]["license"], "MIT OR Apache-2.0", "cargo 旧写法")
        eq(got["lf"]["license"], "ISC", "license_file")

        # 检查：例外、未知、禁止、清单核对
        inv = Inventory(out, "agents/demo:1.0")
        scan_npm(inv, nm)
        doc = inv.write()
        manifest = {"agent": {"id": "demo", "license": "LicenseRef-Vendor-Commercial"}, "install": {"npm": ["@vendor/sdk@1.2.0", "a@1.0.0"]}}
        errors, warnings, summary = check(doc, pol, manifest)
        joined = "\n".join(errors)
        eq("npm e@1.0.0" in joined and "禁止" in joined, True, "AGPL 被拦")
        eq("@vendor/sdk" in joined, False, "登记过的专有包不报错")
        eq(len(errors), 1, "只有 AGPL 一个问题：%s" % errors)
        eq("登记过的例外" in summary, True, "汇总里列出例外")
        bad = dict(manifest, agent={"id": "demo", "license": "MIT"})
        errors, _, _ = check(doc, pol, bad)
        eq(any("agent.license" in e for e in errors), True, "清单的许可证和上游对不上")
        wrong_version = dict(manifest, install={"npm": ["@vendor/sdk@1.3.0"]})
        errors, _, _ = check(doc, pol, wrong_version)
        eq(any("锁定" in e for e in errors), True, "版本和清单对不上")
        # 上游改了许可证：例外不再匹配
        doc2 = json.loads(json.dumps(doc))
        for c in doc2["components"]:
            if c["name"] == "@vendor/sdk":
                c["declared"] = "SEE LICENSE IN TERMS.md"
        errors, _, _ = check(doc2, pol, manifest)
        eq(any("@vendor/sdk" in e and "认不出" in e for e in errors), True, "例外按声明匹配，声明变了要重新登记")
        eq(any("没找到" in e for e in errors), True, "登记了但没用上的例外要报")
        # 原文的哈希：写了就要对上
        sha = hashlib.sha256(PROPRIETARY_TEXT.encode()).hexdigest()
        pinned = Policy(tomllib.loads(TEST_POLICY.replace('reason = "专有', 'text_sha256 = "%s"\nreason = "专有' % sha)))
        errors, _, _ = check(doc, pinned, manifest)
        eq(len(errors), 1, "原文哈希对得上：%s" % errors)
        pinned = Policy(tomllib.loads(TEST_POLICY.replace('reason = "专有', 'text_sha256 = "%s"\nreason = "专有' % ("0" * 64))))
        errors, _, _ = check(doc, pinned, manifest)
        eq(any("@vendor/sdk" in e and "认不出" in e for e in errors), True, "原文改了登记失效")
        # extra 原文按哪个版本核对的
        stale_doc = json.loads(json.dumps(doc))
        stale_doc["components"].append({"ecosystem": "upstream", "name": "bun", "version": "1", "license": "MIT", "declared": "MIT",
                                         "files": ["x"], "root_level": False, "applies_to": ["npm:@vendor/sdk@9.9.9"], "notices_dir": "demo"})
        errors, _, _ = check(stale_doc, pol, manifest)
        eq(any("notices/demo" in e for e in errors), True, "extra 原文的版本对不上要报")
        # Debian：只拦禁止的
        deb_doc = {"subject": "x", "components": [
            {"ecosystem": "deb", "name": "bash", "version": "5", "license": None, "declared": "GPL-3+, BSD-4-clause", "files": [], "root_level": False},
            {"ecosystem": "deb", "name": "bad", "version": "1", "license": None, "declared": "AGPL-3.0", "files": [], "root_level": False},
        ]}
        errors, _, _ = check(deb_doc, pol)
        eq(errors == ["deb bad@1：许可证 AGPL-3.0 在禁止名单里"], True, "Debian 只拦禁止的：%s" % errors)

    # 对抗式评审复现过的绕过：每一条都要拦住（errors 非空）
    commons_clause = APACHE_TEXT + "\n\"Commons Clause\" License Condition v1.0\nThe Software is provided to you by the Licensor\n"
    eula = "Acme EULA. All rights reserved. Commercial agreement required for any use.\n"
    noncommercial = re.sub(r"without\s+restriction", "for non-commercial purposes only", MIT_TEXT, count=1)
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        nm = tmp / "node_modules"
        cases = {
            "unknown-spdx-id": ({"license": "MIT AND AGPL-1.0-or-later"}, {"LICENSE": MIT_TEXT}),
            "commons-clause-declared": ({"license": "Commons-Clause"}, {"LICENSE": commons_clause}),
            "commons-clause-with": ({"license": "Apache-2.0 WITH Commons-Clause"}, {"LICENSE": APACHE_TEXT}),
            "cc-nc-and": ({"license": "MIT AND CC-BY-NC-ND-4.0"}, {"LICENSE": MIT_TEXT}),
            "see-eula-next-to-mit": ({"license": "SEE LICENSE IN LICENSE.md"}, {"LICENSE.md": eula, "LICENSE-THIRD-PARTY.md": MIT_TEXT}),
            "unrecognized-file-next-to-mit": ({}, {"LICENSE": eula, "LICENSE-MIT": MIT_TEXT}),
            "mit-declared-commons-clause-text": ({"license": "MIT"}, {"LICENSE": MIT_TEXT + "\nCommons Clause applies.\n"}),
            "mit-worded-noncommercial": ({}, {"LICENSE": noncommercial}),
        }
        for name, (meta, files) in cases.items():
            d = nm / name
            d.mkdir(parents=True)
            (d / "package.json").write_text(json.dumps(dict({"name": name, "version": "1.0.0"}, **meta)))
            for fname, text in files.items():
                (d / fname).write_text(text)
        inv = Inventory(tmp / "out", "bypass")
        scan_npm(inv, nm)
        doc = inv.write()
        errors, _, _ = check(doc, pol)
        for name in cases:
            eq(any(" %s@" % name in e for e in errors), True, "绕过要被拦住：%s（%s）" % (name, inv.components[("npm", name, "1.0.0")]["license"]))
        unlicense = ("This is free and unencumbered software released into the public domain.\n\nAnyone is free to copy, modify, "
                     "publish, use, compile, sell, or\ndistribute this software, either in source code form or as a compiled\n"
                     "binary, for any purpose, commercial or non-commercial, and by any\nmeans.\n")
        eq(restricted_terms([tmp / "u.txt"]) if (tmp / "u.txt").write_text(unlicense) else None, [], "Unlicense 的“commercial or non-commercial”不算限制")
        eq(pol.classify("Apache-2.0 WITH LicenseRef-Extra", "npm"), "review", "不认识的 WITH 例外要人看")
        eq(normalize_declared("Apache-2.0 WITH Commons-Clause"), None, "Commons-Clause 不是 SPDX 的例外标识")
        eq(normalize_declared("AGPL-1.0-or-later"), "AGPL-1.0-or-later", "SPDX 表里的标识都认")
        eq(normalize_declared("GPL-2.0+"), "GPL-2.0+", "带 + 的旧写法")
        eq(copyleft_ids("MIT OR GPL-3.0-or-later"), [], "OR 里有宽松的一支不算 copyleft")
        eq(copyleft_ids("MPL-2.0 AND MIT"), ["MPL-2.0"], "AND 里的 copyleft")
        eq(copyleft_ids("LGPL-2.1-only OR GPL-2.0-only"), ["LGPL-2.1-only"], "都是 copyleft 时取限制少的一支")
        eq(copyleft_ids("GPL-2.0-only OR LGPL-2.1-only"), ["LGPL-2.1-only"], "限制少的一支写在后面也选它")
        eq(copyleft_ids("GPL-3.0-only OR MPL-2.0"), ["MPL-2.0"], "MPL 比 GPL 限制少")
        eq(copyleft_ids("(MIT AND GPL-2.0-only) OR LGPL-2.1-only"), ["LGPL-2.1-only"], "按每一支里最强的比")
        # PyPI：几个分类按 AND，AGPL + MIT 要拦
        sp = tmp / "sp"
        d = sp / "agplmit-1.0.dist-info"
        d.mkdir(parents=True)
        (d / "METADATA").write_text("Metadata-Version: 2.1\nName: agplmit\nVersion: 1.0\n"
                                    "Classifier: License :: OSI Approved :: GNU Affero General Public License v3\n"
                                    "Classifier: License :: OSI Approved :: MIT License\n\nx\n")
        d = sp / "oddclass-1.0.dist-info"
        d.mkdir(parents=True)
        (d / "METADATA").write_text("Metadata-Version: 2.1\nName: oddclass\nVersion: 1.0\n"
                                    "Classifier: License :: Aladdin Free Public License (AFPL)\n\nx\n")
        inv = Inventory(tmp / "out2", "py")
        scan_python(inv, sp)
        errors, _, _ = check(inv.write(), pol)
        eq(any("agplmit@" in e and "禁止" in e for e in errors), True, "AGPL 分类加 MIT 分类要拦")
        eq(any("oddclass@" in e for e in errors), True, "对照表里没有的许可证分类要人看")
        # 写了 agents 的例外只在这些 agent 里有效
        vendor = {"ecosystem": "npm", "name": "@vendor/sdk", "version": "1.2.0", "license": None,
                  "declared": "SEE LICENSE IN README.md", "files": ["x"], "text_sha256": [], "root_level": True}
        eq(pol.exception_for(vendor, "demo") is not None, True, "登记的 agent 里有效")
        eq(pol.exception_for(vendor, "other"), None, "别的 agent 里无效")
        eq(pol.exception_for(vendor, None), None, "不带清单检查时无效")
        # Debian 的各种写法
        deb_doc = {"subject": "x", "components": [
            {"ecosystem": "deb", "name": n, "version": "1", "license": None, "declared": decl, "files": [], "root_level": False}
            for n, decl in [("a", "AGPLv3+"), ("b", "GNU-AGPL-3"), ("c", "SSPL"), ("ok", "GPL-2+, BSD-3-clause, Expat")]
        ]}
        errors, _, _ = check(deb_doc, pol)
        eq(sorted(e.split("@")[0] for e in errors), ["deb a", "deb b", "deb c"], "Debian 的 AGPL、SSPL 各种写法：%s" % errors)

    # 原文识别的评审发现：特殊许可证不被当成 MIT / BSD，前面有别的条款的不认
    x11 = MIT_TEXT.replace("The above copyright notice and this permission notice shall",
                           "The above copyright notice and this permission notice (including the next\nparagraph) shall")
    eq(detect_text(x11), "MIT", "X11 写法“(including the next paragraph)”是 MIT，不是 MIT-0")
    eq(detect_text("// " + MIT_TEXT.replace("\n", "\n// ")), "MIT", "源文件注释里的 MIT")
    eq(identify(BSD3_TEXT + "\n3. All advertising materials mentioning features or use of this software must display\n")[0],
       "BSD-4-Clause", "带广告条款的 BSD（提名）")
    eq(detect_text(BSD3_TEXT + "\n3. All advertising materials mentioning features or use of this software must display\n"), None,
       "带广告条款的不是 BSD-3")
    eq(identify(BSD3_TEXT + "\nmust be accompanied by information on how to obtain complete source code for the DB software\n")[0],
       "Sleepycat", "Sleepycat 要求公开源码（提名）")
    eq(identify(MIT_TEXT + "\nThe Software shall be used for Good, not Evil.\n")[0], "JSON", "JSON 许可证（提名）")
    eq(detect_text(MIT_TEXT + "\nThe Software shall be used for Good, not Evil.\n"), None, "JSON 不是 MIT")
    for name, text in [
        ("EULA 前言", "Copyright (c) 2024 Acme Inc.\n\nUse of this software requires a valid Acme subscription.\n\n"
                     "This package bundles code from left-pad:\n\n" + MIT_TEXT),
        ("只能配合某服务用", "Copyright (c) 2024 Acme Inc.\nLicensed for use only with Acme Cloud.\n\n" + MIT_TEXT),
        ("藏在“copyright”句子里的限制", "The copyright holder grants you a license to run this software only in non-production "
                                     "environments; production use requires a paid plan.\n" + MIT_TEXT),
        ("专有声明提到 Apache", "Copyright (c) 2024 Acme Corp. All rights reserved. This software is proprietary and confidential. "
                              "Redistribution is prohibited. Portions of this software are used under the Apache License, "
                              "Version 2.0 (see THIRD_PARTY_NOTICES)."),
    ]:
        eq(detect_text(text), None, "多出条款的原文认不出：%s" % name)
    eq(detect_text("SPDX-License-Identifier: MIT\n\n" + MIT_TEXT), "MIT", "SPDX 标识行不算多余的话")
    bsd_named = BSD3_TEXT.replace("the copyright holder nor", "Google Inc. nor")
    eq(detect_text(bsd_named), "BSD-3-Clause", "BSD 第三条换成组织名")
    eq(detect_text("Copyright Acme Corp. All rights reserved.\nThis is proprietary software licensed under the Acme EULA.\n\n"
                   "Bundled third-party code:\n\n" + MIT_TEXT), None, "专有声明后面带的 MIT 原文不算")
    eq(detect_text("\"Commons Clause\" License Condition v1.0\n\nThe Software is provided to you by the Licensor under the License, "
                   "as defined below, subject to the following condition.\n\n" + MIT_TEXT), None, "Commons Clause 前言后面的 MIT 不算")
    eq(detect_text("MIT License\n\nCopyright (c) 2015-2024 A. Person, B. Person and contributors\n\n" + MIT_TEXT.split("\n\n", 2)[2]),
       "MIT", "标题和版权行不算多余的话")
    if (SPDX_DIR / "Unicode-3.0.txt").is_file():
        eq(detect_text((SPDX_DIR / "Unicode-3.0.txt").read_text()), "Unicode-3.0", "Unicode-3.0 不是 MIT-0")

    # 第三轮评审：版权行里、非拉丁文字、短句写的限制，删掉的授权，都核对不上
    import textwrap

    mit_body = MIT_TEXT.split("\n\n", 1)[1]
    apache_cut = re.sub(r"2\. Grant of Copyright License\..*?4\. Redistribution\.", "4. Redistribution.", APACHE_TEXT, flags=re.S)
    ofl = _spdx_text("OFL-1.1")
    for name, text in [
        ("专有声明在 © 行上", "© Foo Inc. All rights reserved. Use is subject to the Legal Agreements outlined here: "
                           "https://foo.example/legal. You may not redistribute, sublicense or resell this package.\n\n"
                           "Portions Copyright (c) 2020 Bar contributors, included under the following license:\n\nMIT License\n\n" + mit_body),
        ("版权行后面的订阅条件", "Copyright (c) 2024 Foo Inc. Use of this Software is limited to customers holding a paid subscription.\n\n" + mit_body),
        ("版权行冒号后面的限制", "(c) 2024 Foo: you may only run this software on hardware sold by Foo.\n\n" + mit_body),
        ("字体版权行后面的商用条件", "Copyright 2020 Foo Type Foundry. Embedding this font in a product requires a paid commercial license.\n\n" + ofl),
        ("中文附加条款", MIT_TEXT + "\n附加条款：本软件仅限个人非营利使用，禁止任何商业用途。商业授权请联系 Foo 公司。\n"),
        ("中文条款插在中间", MIT_TEXT.replace("The above copyright notice", "本软件禁止商用。\nThe above copyright notice")),
        ("俄文附加条款", MIT_TEXT + "\nкоммерческое использование запрещено\n"),
        ("全角字母写的限制", MIT_TEXT + "\nＣｏｍｍｅｒｃｉａｌ ｕｓｅ ｉｓ ｐｒｏｈｉｂｉｔｅｄ\n"),
        ("短句：只限个人使用", MIT_TEXT + "\nPersonal use only. No redistribution.\n"),
        ("短句：不能商用", MIT_TEXT + "\nNo commercial use.\n"),
        ("否定授权", MIT_TEXT.replace("without restriction", "not without restriction", 1)),
        ("权利清单换成只能内部使用", re.sub(r"without\s+restriction.*?furnished\s+to\s+do\s+so", "solely to use the Software internally",
                                           MIT_TEXT, flags=re.S)),
        ("删掉 distribute", re.sub(r"publish,\s+distribute,", "publish,", MIT_TEXT)),
        ("Apache 删掉第 2、3 条", apache_cut),
        ("Apache 头部加只能评估", "Copyright 2020 X\n\n" + _HEADERS["Apache-2.0"] + "\nFor internal evaluation only.\n"),
        ("MPL 头部加不能用于生产", _HEADERS["MPL-2.0"] + "\nNot for production.\n"),
        ("填充后面附加的限制", MIT_TEXT + " " * 200000 + "Commercial use is prohibited. The MIT terms above are void.\n"),
        ("OFL 网址里藏的条款", "This Font Software is licensed under the SIL Open Font License, Version 1.1.\nThis license is copied below, "
                            "and is also available with a FAQ at:\nhttps://openfontlicense.org/#Desktop_and_web_embedding_require_a_"
                            "separate_paid_commercial_license_from_Foo\n\n" + ofl),
    ]:
        eq(detect_text(text), None, "限制条款核对不上：%s" % name)
    eq("AGPL-3.0-only" in candidates(AGPL_TEXT.replace("ff", "ﬀ")), True, "连字写的 Affero 照样提名 AGPL")
    eq("AGPL-3.0-only" in candidates(AGPL_TEXT.replace("AFFERO", "AFFЕRO")), True, "西里尔字母写的 Affero 照样提名 AGPL")
    for name, text, want in [
        ("持有人叫 Nor", MIT_TEXT.replace("2024 Someone", "2020 Nor Khasyatillah"), "MIT"),
        ("字体版权行带商标声明", "Copyright 2010, 2012 Adobe Systems Incorporated (http://www.adobe.com/), with Reserved Font Name "
                              "'Source'. All Rights Reserved. Source is a trademark of Adobe Systems Incorporated in the United States "
                              "and/or other countries.\n\nThis Font Software is licensed under the SIL Open Font License, Version 1.1.\n\n"
                              "This license is copied below, and is also available with a FAQ at: http://scripts.sil.org/OFL\n\n" + ofl, "OFL-1.1"),
        ("BSD 免责里写组织名", BSD3_TEXT.replace("THE COPYRIGHT HOLDERS AND CONTRIBUTORS", "ZETETIC LLC")
                               .replace("THE COPYRIGHT HOLDER OR CONTRIBUTORS", "ZETETIC LLC"), "BSD-3-Clause"),
        ("HPND 写了持有人的名字", _spdx_text("HPND", "Secret Labs AB and Fredrik Lundh"), "HPND"),
    ]:
        eq(detect_text(text), want, "核对得上：%s" % name)
    # 标准文本换个折行照样核对得上（版权行判断不能依赖原来的折行：CC-BY 折到行首的“Copyright Treaty”不是版权行）
    for path in sorted(SPDX_DIR.glob("*.txt")):
        if path.stem in ("license-ids", "exception-ids"):
            continue
        for width in (50, 62, 66, 78, 82, 95):
            out = []
            for para in re.split(r"\n\s*\n", path.read_text(encoding="utf-8")):
                # 版权行还是单独一行（真实的文件里也是），别的重新折行
                lines, run = [], []
                for line in para.splitlines() + [None]:
                    if line is None or _NOTICE_START.match(line) or _RFN.match(line):
                        if run:
                            lines.append(textwrap.fill(" ".join(" ".join(run).split()), width))
                            run = []
                        if line is not None:
                            lines.append(line.strip())
                    else:
                        run.append(line)
                out.append("\n".join(lines))
            rewrapped = "\n\n".join(out)
            eq(identify(rewrapped), (path.stem, True), "%s 标准文本按 %d 列换行以后" % (path.stem, width))
    # GNU 现在发布的 GPL-2.0、LGPL-2.1：地址换成了网址（Ubuntu 26.04 的 /usr/share/common-licenses 就是这一版）
    for lid in ("GPL-2.0-only", "LGPL-2.1-only"):
        current = re.sub(r"51 Franklin Street, Fifth Floor, Boston, MA\s+02110-1301,?\s+USA", "<https://fsf.org/>",
                         re.sub(r"write to the Free Software Foundation, Inc\., 51 Franklin Street, Fifth Floor, Boston, MA\s+02110-1301,?\s+USA",
                                "see <https://www.gnu.org/licenses/>", _spdx_text(lid)))
        eq("Franklin" in current, False, "%s 换掉了地址" % lid)
        eq(identify(current), (lid, True), "GNU 现在的 %s 原文（地址换成网址）" % lid)
    # GNU 发布的原文（Debian 的 /usr/share/common-licenses）核对得上
    for name, lid in [("GPL-2", "GPL-2.0-only"), ("GPL-3", "GPL-3.0-only"), ("LGPL-2.1", "LGPL-2.1-only"), ("LGPL-3", "LGPL-3.0-only"),
                      ("Apache-2.0", "Apache-2.0"), ("MPL-2.0", "MPL-2.0")]:
        sys_text = Path("/usr/share/common-licenses") / name
        if sys_text.is_file():
            eq(identify(sys_text.read_text(encoding="utf-8")), (lid, True), "GNU / Debian 的 %s 原文" % name)
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        nm = tmp / "node_modules"
        (nm / "bom").mkdir(parents=True)
        (nm / "bom" / "package.json").write_text("﻿" + json.dumps({"name": "bom", "version": "1.0.0", "license": "AGPL-3.0-only"}))
        (nm / "noversion").mkdir()
        (nm / "noversion" / "package.json").write_text(json.dumps({"name": "noversion", "license": "MIT"}))
        inv = Inventory(tmp / "out", "edge")
        scan_npm(inv, nm)
        errors, _, _ = check(inv.write(), pol)
        eq(any("bom@1.0.0" in e and "禁止" in e for e in errors), True, "带 BOM 的 package.json 照样读")
        eq(any("noversion@?" in e for e in errors), True, "读不出版本的包不能悄悄跳过")
        # .egg-info
        sp = tmp / "sp"
        (sp / "eggy-1.0.egg-info").mkdir(parents=True)
        (sp / "eggy-1.0.egg-info" / "PKG-INFO").write_text("Metadata-Version: 1.1\nName: eggy\nVersion: 1.0\nLicense: AGPL-3.0-only\n")
        inv = Inventory(tmp / "out2", "egg")
        scan_python(inv, sp)
        eq(inv.components.get(("pypi", "eggy", "1.0"), {}).get("license"), "AGPL-3.0-only", ".egg-info 也扫")
        # 声明和原文对不上：声明 MIT，包里却是 GPL 的原文（核对过）或者像 AGPL 的原文
        nm = tmp / "cross" / "node_modules"
        agpl_like = AGPL_TEXT + "\nAdditional permission: you may also use this file under the MIT license.\n"
        for name, decl, files in [("gplfile", "MIT", {"COPYING": _spdx_text("GPL-3.0-only")}),
                                  ("dualgpl", "MIT OR GPL-3.0-or-later", {"COPYING": _spdx_text("GPL-3.0-only")}),
                                  ("agpllike", "MIT", {"LICENSE": agpl_like}),
                                  ("mitfile", "MIT", {"LICENSE": MIT_TEXT}),
                                  ("gplmention", "MIT", {"LICENSE": MIT_TEXT + "\nFormerly GPL.\n"}),
                                  ("gplsentence", "MIT", {"LICENSE": MIT_TEXT + "\nParts were once distributed under the terms "
                                                          "of the GNU General Public License.\n"})]:
            (nm / name).mkdir(parents=True)
            (nm / name / "package.json").write_text(json.dumps({"name": name, "version": "1.0.0", "license": decl}))
            for fn, text in files.items():
                (nm / name / fn).write_text(text)
        inv = Inventory(tmp / "out-cross", "cross")
        scan_npm(inv, nm)
        errors, _, _ = check(inv.write(), pol)
        eq(any("gplfile@" in e and "GPL-3.0-only" in e for e in errors), True, "声明 MIT、包里是 GPL 原文要拦")
        eq(any("agpllike@" in e and "AGPL" in e for e in errors), True, "声明 MIT、包里像 AGPL 原文要拦")
        eq(any("gplsentence@" in e and "GPL" in e for e in errors), True, "根目录的原文说按 GPL 分发、又核对不上 MIT，要人看")
        eq([e for e in errors if "dualgpl@" in e or "mitfile@" in e or "gplmention@" in e], [],
           "声明里有的、对得上的、只是顺带提到的不拦")
        # PyPI 没有 License-Expression 时，License 字段没提到的分类也算
        sp = tmp / "sp-cls"
        for name, cls in [("mitgpl", "GNU General Public License v3 (GPLv3)"), ("mitmit", "MIT License"), ("mitbsd", "BSD License")]:
            (sp / ("%s-1.0.dist-info" % name)).mkdir(parents=True)
            (sp / ("%s-1.0.dist-info" % name) / "METADATA").write_text(
                "Metadata-Version: 2.1\nName: %s\nVersion: 1.0\nLicense: MIT\nClassifier: License :: OSI Approved :: %s\n\nx\n"
                % (name, cls))
        (sp / "exprgpl-1.0.dist-info").mkdir(parents=True)
        (sp / "exprgpl-1.0.dist-info" / "METADATA").write_text(
            "Metadata-Version: 2.4\nName: exprgpl\nVersion: 1.0\nLicense-Expression: MIT\n"
            "Classifier: License :: OSI Approved :: GNU General Public License v3 (GPLv3)\n\nx\n")
        inv = Inventory(tmp / "out-cls", "cls")
        scan_python(inv, sp)
        got = {k[1]: v["license"] for k, v in inv.components.items()}
        eq(got, {"mitgpl": "MIT AND GPL-3.0-only", "mitmit": "MIT", "mitbsd": "MIT AND LicenseRef-BSD-Unspecified", "exprgpl": "MIT"},
           "License 字段加上没提到的分类（含糊的也算）；License-Expression 为准")
        # 认不出的分类、认不出的 License-Expression 不能被认得出的 License 字段盖过去；含糊的 GPL 分类也算
        sp = tmp / "sp-cls2"
        for name, headers, files in [
            ("restricted-cls", "License: MIT\nClassifier: License :: Free To Use But Restricted\n", {}),
            ("osl-cls", "License: MIT\nClassifier: License :: OSI Approved :: Open Software License 3.0 (OSL-3.0)\n", {}),
            ("bad-expr", "License-Expression: MIT AND Commons-Clause\nLicense: MIT\n", {}),
            ("vague-gpl", "License: MIT\nClassifier: License :: OSI Approved :: GNU General Public License (GPL)\n", {}),
            ("vague-gpl-text", "Classifier: License :: OSI Approved :: GNU General Public License (GPL)\n", {"LICENSE": MIT_TEXT}),
        ]:
            d = sp / ("%s-1.0.dist-info" % name.replace("-", "_"))
            d.mkdir(parents=True)
            (d / "METADATA").write_text("Metadata-Version: 2.1\nName: %s\nVersion: 1.0\n%s\nx\n" % (name, headers))
            for fn, text in files.items():
                (d / fn).write_text(text)
        inv = Inventory(tmp / "out-cls2", "cls2")
        scan_python(inv, sp)
        got = {k[1]: v["license"] for k, v in inv.components.items()}
        eq(got, {"restricted-cls": None, "osl-cls": None, "bad-expr": None, "vague-gpl": "MIT AND LicenseRef-GPL-Unspecified",
                 "vague-gpl-text": "MIT AND LicenseRef-GPL-Unspecified"}, "PyPI 的几个声明都要认得出、都算")
        # 包里子目录下的原文和字体；不进 node_modules
        nm = tmp / "bundle" / "node_modules"
        pkg = nm / "ui"
        for rel, text in [("package.json", json.dumps({"name": "ui", "version": "1.0.0", "license": "MIT",
                                                      "repository": {"type": "git", "url": "git+https://github.com/acme/ui.git"}})),
                          ("LICENSE", MIT_TEXT), ("vendor/gpl-lib/COPYING", _spdx_text("GPL-3.0-only")),
                          ("fonts/brand-OFL.txt", "Copyright 2020 The Brand Authors\n\nThis Font Software is licensed under the "
                           "SIL Open Font License, Version 1.1.\nThis license is copied below, and is also available with a FAQ "
                           "at:\nhttps://openfontlicense.org\n\n" + _spdx_text("OFL-1.1")),
                          ("fonts/brand-Regular.woff2", "x"), ("fonts/paid-Bold.woff2", "x"), ("node-runtime-NOTICE.md", "Notice."),
                          ("node_modules/inner/LICENSE", _spdx_text("GPL-3.0-only")), ("node_modules/inner/package.json",
                                                                                      json.dumps({"name": "inner", "version": "1.0.0", "license": "MIT"}))]:
            (pkg / rel).parent.mkdir(parents=True, exist_ok=True)
            (pkg / rel).write_text(text)
        inv = Inventory(tmp / "out-bundle", "bundle")
        scan_npm(inv, nm)
        ui = inv.components[("npm", "ui", "1.0.0")]
        eq(sorted(Path(f).name for f in ui["bundled_files"]), ["COPYING", "brand-OFL.txt"], "子目录下的原文（不进 node_modules）")
        eq([Path(f).name for f in ui["files"]], ["LICENSE", "node-runtime-NOTICE.md"], "名字中间带 NOTICE 的也算原文")
        eq([a["path"] for a in ui["assets"]], ["fonts/brand-Regular.woff2", "fonts/paid-Bold.woff2"], "字体")
        eq(ui["source_url"], "https://github.com/acme/ui", "npm 的 repository")
        eq(ui["license"], "MIT", "子目录下的原文不参与认包的许可证")
        apol = Policy({"allow": ["MIT", "OFL-1.1"], "asset": [
            {"ecosystem": "npm", "name": "ui", "path": ["fonts/brand-*.woff2"], "license": "OFL-1.1",
             "license_file": "fonts/brand-OFL.txt", "reason": "OFL", "agents": ["demo"]},
            {"ecosystem": "npm", "name": "ui", "path": "fonts/paid-*.woff2", "license": "OFL-1.1",
             "license_file": "fonts/paid-OFL.txt", "reason": "原文不在", "agents": ["other"]}]})
        demo = {"agent": {"id": "demo", "license": "MIT"}, "install": {}}
        errors, _, _ = check(inv.write(), apol)
        eq(any("ui@" in e and "COPYING" in e and "GPL-3.0-only" in e for e in errors), True, "子目录下的 GPL 原文要和声明对照")
        eq(any("ui@" in e and "2 个没登记的字体" in e for e in errors), True, "不带清单检查时登记不生效")
        doc = inv.write()
        errs = [e for e in check_assets(ui, "ui", apol, "demo", set(), doc["components"])]
        eq(errs, ["ui：带了 1 个没登记的字体（fonts/paid-Bold.woff2）。字体常常单独授权（有的是商用字体），查清许可证后在 "
                  "policy.toml 登记 [[asset]]，见 docs/licenses.md"], "登记过的字体、旁边有核对得上的原文")
        errs = check_assets(ui, "ui", apol, "other", set(), doc["components"])
        eq(any("paid-OFL.txt" in e for e in errs), True, "登记说的原文包里没有要报错")
        eq(git_web_url("git@github.com:a/b.git"), "https://github.com/a/b", "git@ 地址")
        eq(git_web_url("github:a/b"), "https://github.com/a/b", "github: 简写")
        eq(git_web_url("a/b"), "https://github.com/a/b", "user/repo 简写")
        eq(is_notice("OPENCLAW_PATCH_NOTICE.md"), True, "名字中间带 NOTICE 的是 NOTICE")
        eq(is_legal_file("noticeboard.ts"), False, "代码文件不算")
        eq(is_legal_file("officially.txt"), False, "OFL 要是单独的词")
        # PyPI：RECORD 里的文件
        sp = tmp / "sp-rec"
        dist = sp / "webapp-1.0.dist-info"
        dist.mkdir(parents=True)
        (dist / "METADATA").write_text("Metadata-Version: 2.1\nName: webapp\nVersion: 1.0\nLicense-Expression: MIT\n"
                                       "Project-URL: Source, https://github.com/acme/webapp\n\nx\n")
        for rel in ("webapp/__init__.py", "webapp/static/fonts/Brand.woff2", "webapp/static/vendor/LICENSE.txt"):
            (sp / rel).parent.mkdir(parents=True, exist_ok=True)
            (sp / rel).write_text(MIT_TEXT if rel.endswith(".txt") else "x")
        (dist / "RECORD").write_text("webapp/__init__.py,,\nwebapp/static/fonts/Brand.woff2,,\nwebapp/static/vendor/LICENSE.txt,,\n"
                                     "webapp/static/gone.woff2,,\n../../../bin/webapp,,\nwebapp-1.0.dist-info/METADATA,,\n")
        inv = Inventory(tmp / "out-rec", "rec")
        scan_python(inv, sp)
        web = inv.components[("pypi", "webapp", "1.0")]
        eq([a["path"] for a in web["assets"]], ["webapp/static/fonts/Brand.woff2"], "RECORD 里的字体（删掉的不算），相对 site-packages")
        eq([Path(f).name for f in web["bundled_files"]], ["LICENSE.txt"], "RECORD 里的原文")
        eq(web["source_url"], "https://github.com/acme/webapp", "Project-URL 的 Source")
        # sources.toml：同一组件的许可证要一致
        ex = tmp / "conflict"
        ex.mkdir()
        (ex / "a").write_text("a")
        (ex / "b").write_text("b")
        (ex / "sources.toml").write_text('[[file]]\ncomponent = "x"\nversion = "1"\nlicense = "MIT"\npath = "a"\n'
                                         '[[file]]\ncomponent = "x"\nversion = "1"\nlicense = "Apache-2.0"\npath = "b"\n')
        try:
            scan_extra(Inventory(tmp / "out3", "x"), ex)
            eq("没报错", "报错", "同一组件写了不同的许可证")
        except SystemExit:
            pass
        # cargo：*-src 构建依赖算进去
        reg = tmp / "reg"
        for n in ("openssl-src", "cc"):
            (reg / n).mkdir(parents=True)
        meta = {
            "packages": [{"id": "app", "name": "app", "version": "1", "license": "UNLICENSED", "license_file": None,
                          "manifest_path": str(tmp / "ws" / "Cargo.toml")}]
            + [{"id": n, "name": n, "version": "1", "license": "Apache-2.0", "license_file": None,
                "manifest_path": str(reg / n / "Cargo.toml")} for n in ("openssl-src", "cc")],
            "workspace_members": ["app"],
            "resolve": {"nodes": [
                {"id": "app", "deps": [{"pkg": "openssl-src", "dep_kinds": [{"kind": "build"}]}, {"pkg": "cc", "dep_kinds": [{"kind": "build"}]}]},
                {"id": "openssl-src", "deps": []}, {"id": "cc", "deps": []},
            ]},
        }
        (tmp / "m.json").write_text(json.dumps(meta))
        inv = Inventory(tmp / "out4", "app")
        scan_cargo(inv, ["app"], metadata_json=tmp / "m.json")
        eq(sorted(c["name"] for c in inv.components.values()), ["openssl-src"], "*-src 构建依赖算，别的构建依赖不算")
    eq(pol.classify("FSL-1.1-MIT", "npm") in ("review", "deny"), True, "FSL 不放行")

    # 第三轮评审：和声明对照、登记过的例外、合并、同一个包的几份
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        nm = tmp / "node_modules"
        mit_body = MIT_TEXT.split("\n\n", 1)[1]
        long_mit = MIT_TEXT + ("\n\n---\n\n" + MIT_TEXT) * 9
        busl = "Business Source License 1.1\n\nThe Licensor grants a right to make non-production use of the Licensed Work.\n"
        cases = {
            "agpl-title-mit-body": ("MIT", {"LICENSE": "GNU AFFERO GENERAL PUBLIC LICENSE v3\n\n" + mit_body}),
            "agpl-deep-in-notices": ("MIT", {"LICENSE.md": long_mit + "\n\n## foo\n\n" + AGPL_TEXT}),
            "busl-deep-in-notices": ("MIT", {"LICENSE.md": MIT_TEXT + ("\n\n---\n\n" + MIT_TEXT) * 60 + "\n\n" + busl}),
            "json-root": ("MIT", {"LICENSE": MIT_TEXT + "\nThe Software shall be used for Good, not Evil.\n"}),
            "gpl-with-preface": ("MIT", {"COPYING": "This project is licensed under GPLv3, see below.\n\n" + _spdx_text("GPL-3.0-only")}),
            "eupl-bundled": ("MIT", {"LICENSE": MIT_TEXT, "vendor/x/LICENSE": "EUROPEAN UNION PUBLIC LICENCE v. 1.2\nEUPL © the European Union 2007, 2016\n"}),
            "osl-bundled": ("MIT", {"LICENSE": MIT_TEXT, "vendor/x/LICENSE": 'Open Software License ("OSL") v. 3.0\n\nThis Open Software License (the "License") applies to any original work\n'}),
            "agpl-copyright-line": ("MIT", {"LICENSE": "Copyright (c) 2024 Foo Inc. This program is distributed under the terms of the GNU Affero "
                                                     "General Public License as published by the Free Software Foundation.\n\n" + mit_body}),
        }
        for name, (decl, files) in cases.items():
            d = nm / name
            for fname, text in dict(files, **{"package.json": json.dumps({"name": name, "version": "1.0.0", "license": decl})}).items():
                (d / fname).parent.mkdir(parents=True, exist_ok=True)
                (d / fname).write_text(text)
        inv = Inventory(tmp / "out", "r3")
        scan_npm(inv, nm)
        errors, _, _ = check(inv.write(), pol)
        for name in cases:
            eq(any(" %s@" % name in e for e in errors), True, "要拦：%s（%s）" % (name, inv.components[("npm", name, "1.0.0")]["file_licenses"]))
        eq(any("busl-deep-in-notices@" in e and "Restricted" in e for e in errors), True, "很长的文件后面的限制性说法也找得到")

        # 登记过的例外：包里新出现的禁止名单许可证、限制性说法照样报；列表钉住的原文包括子目录里的
        sdk = tmp / "exc" / "node_modules" / "@vendor" / "sdk"
        for fname, text in {"package.json": json.dumps({"name": "@vendor/sdk", "version": "1.2.0", "license": "SEE LICENSE IN README.md"}),
                            "LICENSE.md": PROPRIETARY_TEXT, "README.md": "readme", "vendor/evil/LICENSE": AGPL_TEXT,
                            "vendor/evil/COPYING": busl}.items():
            (sdk / fname).parent.mkdir(parents=True, exist_ok=True)
            (sdk / fname).write_text(text)
        inv = Inventory(tmp / "out-exc", "agents/demo:1.0")
        scan_npm(inv, tmp / "exc" / "node_modules")
        doc = inv.write()
        manifest = {"agent": {"id": "demo", "license": "LicenseRef-Vendor-Commercial"}, "install": {"npm": ["@vendor/sdk@1.2.0"]}}
        errors, _, _ = check(doc, pol, manifest)
        eq(any("@vendor/sdk" in e and "AGPL" in e for e in errors), True, "登记过的包里新出现的 AGPL 要报")
        eq(any("@vendor/sdk" in e and "限制性的说法" in e for e in errors), True, "登记过的包里新出现的限制性说法要报")
        sdk_c = inv.components[("npm", "@vendor/sdk", "1.2.0")]
        root_pins = [hashlib.sha256((sdk / f).read_bytes()).hexdigest() for f in ("LICENSE.md", "README.md")]
        pinned = Policy(tomllib.loads(TEST_POLICY.replace('reason = "专有', 'text_sha256 = %s\nreason = "专有' % json.dumps(root_pins))))
        eq(pinned.exception_for(sdk_c, "demo"), None, "列表钉住的原文要包括子目录里的")
        all_pins = root_pins + sdk_c["bundled_sha256"]
        pinned = Policy(tomllib.loads(TEST_POLICY.replace('reason = "专有', 'text_sha256 = %s\nreason = "专有' % json.dumps(all_pins))))
        eq(pinned.exception_for(sdk_c, "demo") is not None, True, "根目录和子目录的原文都钉住")

        # 合并：子目录的原文一起复制；清单引用的原文缺了要报
        shim = Inventory(tmp / "shim", "agent-shim")
        (tmp / "crate" / "unicode").mkdir(parents=True)
        (tmp / "crate" / "LICENSE-MIT").write_text(MIT_TEXT)
        (tmp / "crate" / "unicode" / "LICENSE-UNICODE").write_text(_spdx_text("Unicode-3.0"))
        shim.add("cargo", "regex-syntax", "0.8", "MIT", "MIT", "metadata", [tmp / "crate" / "LICENSE-MIT"], None,
                 bundled=[tmp / "crate" / "unicode" / "LICENSE-UNICODE"], asset_base=tmp / "crate")
        shim.write()
        img = Inventory(tmp / "img", "img")
        img.merge(tmp / "shim")
        rs = img.components[("cargo", "regex-syntax", "0.8")]
        eq(all((tmp / "img" / f).is_file() for f in rs["files"] + rs["bundled_files"]), True, "合并时子目录的原文一起复制")
        os.remove(tmp / "shim" / rs["bundled_files"][0])
        try:
            Inventory(tmp / "img2", "img").merge(tmp / "shim")
            eq("没报错", "报错", "合并时清单引用的原文缺了")
        except SystemExit:
            pass

        # 同名同版本的另一份里的字体、原文也记上；根目录的 OFL 原文可以当字体的 license_file
        nm = tmp / "dup" / "node_modules"
        for host, extra in (("a-host", {}), ("b-host", {"fonts/Commercial.woff2": "x", "fonts/LICENSE": MIT_TEXT + "\nNon-commercial use only.\n"})):
            d = nm / host / "node_modules" / "fontpkg"
            for fname, text in dict(extra, **{"package.json": json.dumps({"name": "fontpkg", "version": "1.0.0", "license": "MIT"}),
                                              "LICENSE": MIT_TEXT}).items():
                (d / fname).parent.mkdir(parents=True, exist_ok=True)
                (d / fname).write_text(text)
            (nm / host / "package.json").write_text(json.dumps({"name": host, "version": "1.0.0", "license": "MIT"}))
        fontsrc = nm / "@fontsource" / "inter"
        for fname, text in {"package.json": json.dumps({"name": "@fontsource/inter", "version": "5.0.0", "license": "OFL-1.1"}),
                            "LICENSE": _spdx_text("OFL-1.1"), "files/inter-latin-400-normal.woff2": "x"}.items():
            (fontsrc / fname).parent.mkdir(parents=True, exist_ok=True)
            (fontsrc / fname).write_text(text)
        inv = Inventory(tmp / "out-dup", "dup")
        scan_npm(inv, nm)
        fp = inv.components[("npm", "fontpkg", "1.0.0")]
        eq(([a["path"] for a in fp["assets"]], fp["locations"]), (["fonts/Commercial.woff2"], 2), "另一份里的字体也记上")
        eq(fp["restricted_terms"] is not None, True, "另一份里的限制性说法也记上")
        ofl_pol = Policy({"allow": ["MIT", "OFL-1.1"], "asset": [
            {"ecosystem": "npm", "name": "@fontsource/inter", "path": "files/*.woff2", "license": "OFL-1.1", "license_file": "LICENSE",
             "reason": "OFL"}]})
        doc = inv.write()
        inter = inv.components[("npm", "@fontsource/inter", "5.0.0")]
        eq(check_assets(inter, "inter", ofl_pol, None, set(), doc["components"]), [], "根目录的 OFL 原文可以当字体的 license_file")

        # 扫描：隐藏目录、更多字体格式、HTML 的许可证文件
        nm = tmp / "scan" / "node_modules"
        pkg = nm / "docsite"
        for rel, text in {"package.json": json.dumps({"name": "docsite", "version": "1.0.0", "license": "MIT"}),
                          "LICENSE.html": "<html><body><h1>MIT License</h1><p>" + MIT_TEXT.replace("\n\n", "</p><p>") + "</p></body></html>",
                          ".vitepress/theme/fonts/CommercialSans.woff2": "x", ".vitepress/theme/fonts/LICENSE": MIT_TEXT + "\nNon-commercial use only.\n",
                          "standard_fonts/FoxitSans.pfb": "x", "fonts/NotoCJK.otc": "x", "fonts/fixed.pcf.gz": "x",
                          ".git/LICENSE": AGPL_TEXT}.items():
            (pkg / rel).parent.mkdir(parents=True, exist_ok=True)
            (pkg / rel).write_text(text)
        inv = Inventory(tmp / "out-scan", "scan")
        scan_npm(inv, nm)
        ds = inv.components[("npm", "docsite", "1.0.0")]
        eq(sorted(a["path"] for a in ds["assets"]), [".vitepress/theme/fonts/CommercialSans.woff2", "fonts/NotoCJK.otc", "fonts/fixed.pcf.gz",
                                                     "standard_fonts/FoxitSans.pfb"], "隐藏目录里的字体、Type 1 / 集合 / 点阵字体")
        eq(ds["restricted_terms"] is not None, True, "隐藏目录里的原文也看（.git 不看）")
        eq([(d["path"], d["proposed"], d["verified"]) for d in ds["file_licenses"] if not d.get("bundled")], [("LICENSE.html", "MIT", True)],
           "HTML 的许可证文件去掉标签再认")
        # PyPI：装到虚拟环境根目录下的数据文件；RECORD 按 CSV 读
        venv = tmp / "venv"
        sp = venv / "lib" / "python3.12" / "site-packages"
        dist = sp / "lab-1.0.dist-info"
        dist.mkdir(parents=True)
        (dist / "METADATA").write_text("Metadata-Version: 2.1\nName: lab\nVersion: 1.0\nLicense-Expression: MIT\n\nx\n")
        for rel in ("lab/__init__.py", "lab/fonts/Paid, Bold.woff2", "../../../share/jupyter/lab/static/Brand.woff2", "../../../bin/lab"):
            (sp / rel).parent.mkdir(parents=True, exist_ok=True)
            (sp / rel).write_text("x")
        (dist / "RECORD").write_text('lab/__init__.py,,\n"lab/fonts/Paid, Bold.woff2",sha256=x,1\n'
                                     "../../../share/jupyter/lab/static/Brand.woff2,,\n../../../bin/lab,,\n")
        inv = Inventory(tmp / "out-venv", "venv")
        scan_python(inv, sp)
        lab = inv.components[("pypi", "lab", "1.0")]
        eq(sorted(a["path"] for a in lab["assets"]), ["../../../share/jupyter/lab/static/Brand.woff2", "lab/fonts/Paid, Bold.woff2"],
           "RECORD 里带逗号的路径、装到 share/ 的字体")
        # cargo：git 依赖的整个仓库都在，旁边别的 crate 的原文不算这个 crate 的
        repo = tmp / "git" / "nucleo"
        for rel, text in {"Cargo.toml": "", "LICENSE": _spdx_text("MPL-2.0"), "matcher/Cargo.toml": "", "matcher/LICENSE": _spdx_text("GPL-3.0-only"),
                          "vendor/lib/COPYING": MIT_TEXT}.items():
            (repo / rel).parent.mkdir(parents=True, exist_ok=True)
            (repo / rel).write_text(text)
        legal, _ = bundled_files(repo, stop_at="Cargo.toml")
        eq([str(Path(f).relative_to(repo)) for f in legal], ["vendor/lib/COPYING"], "不进工作区里别的 crate")
        # 上游 crate 清单的缓存：版本对、但不是这个扫描程序（或这套标准文本）生成的，不能用
        up = tmp / "notices-up"
        (up / "crates").mkdir(parents=True)
        entry = {"repo": "https://example.com/x", "tag": "v1", "manifest": "Cargo.toml", "packages": ["x"]}
        (up / "sources.toml").write_text('[[cargo]]\nrepo = "%s"\ntag = "v1"\nmanifest = "Cargo.toml"\npackages = ["x"]\n' % entry["repo"])
        Inventory(up / "crates", upstream_cargo_subject([entry])).write()
        for key in (None, upstream_cargo_key([entry]).replace('"schema"', '"old"')):
            if key:
                (up / "crates" / "key.json").write_text(key)
            try:
                scan_extra(Inventory(tmp / "out-up", "x"), up)
                eq("没报错", "报错", "旧的上游 crate 清单（%s）" % ("没有 key.json" if key is None else "key 不对"))
            except SystemExit:
                pass
        (up / "crates" / "key.json").write_text(upstream_cargo_key([entry]))
        scan_extra(Inventory(tmp / "out-up", "x"), up)
    eq(git_web_url("git+ssh://git@github.com:a/b.git"), "https://github.com/a/b", "git+ssh://git@host:org/repo")
    eq(git_web_url("../local"), None, "相对路径不是仓库")
    # 第四轮评审：SSH 端口、没写用户、地址里的用户名和口令都不进网页地址
    for url, want in [("ssh://git@github.com:22/org/repo.git", "https://github.com/org/repo"),
                      ("git+ssh://git@gitlab.com:2222/org/repo.git", "https://gitlab.com/org/repo"),
                      ("git+ssh://github.com:org/repo.git", "https://github.com/org/repo"),
                      ("git+ssh://user@host.com:org/repo.git", "https://host.com/org/repo"),
                      ("ssh://git@github.com/org/repo.git", "https://github.com/org/repo"),
                      ("git://github.com/org/repo.git", "https://github.com/org/repo"),
                      ("git+https://jimmywarting@github.com/jimmywarting/FormData.git", "https://github.com/jimmywarting/FormData"),
                      ("https://user:token@example.com/org/repo", "https://example.com/org/repo"),
                      ("user@host.com:org/repo.git", "https://host.com/org/repo")]:
        eq(git_web_url(url), want, "网页地址：%s" % url)
    # 第四轮评审：NOTICE、第三方许可清单（合并成一个文件的）也找禁止名单许可证和限制性说法；EULA、TERMS 也是原文
    long_mit = MIT_TEXT + ("\n\n---\n\n" + MIT_TEXT) * 12
    agpl_md = ("GNU Affero General Public License\n=================================\n\n_Version 3, 19 November 2007_\n"
               "_Copyright © 2007 Free Software Foundation, Inc. <<http://fsf.org/>>_\n\n## Preamble\n")
    agpl_1 = "AFFERO GENERAL PUBLIC LICENSE\nVersion 1, March 2002 Copyright © 2002 Affero Inc.\n"
    busl = "Business Source License 1.1\n\nThe Licensor grants a right to make non-production use of the Licensed Work.\n"
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        nm = tmp / "node_modules"
        cases = {}
        for fname in ("ThirdPartyNotices.txt", "dist/THIRD-PARTY-NOTICES.md", "dist/LICENSES.md", "NOTICE", "dist/3rdpartylicenses.txt",
                      "COPYRIGHT", "vendor/evil/NOTICE.txt", "THIRD_PARTY_LICENSES.txt"):
            for kind, body in (("agpl-notice", "foo is distributed under the terms of the GNU Affero General Public License as "
                                               "published by the Free Software Foundation."),
                               ("agpl-md", agpl_md), ("agpl-line", "## foo\nLicense: AGPL-3.0-only\nBy: Foo\n"),
                               ("agpl-licensed", "foo: Licensed under the GNU Affero General Public License v3.0."),
                               ("agpl-1", agpl_1), ("busl", busl)):
                cases["%s-%s" % (kind, re.sub(r"\W+", "-", fname).lower())] = {fname: long_mit + "\n\n" + body}
        cases["eula-busl"] = {"EULA.txt": "Business Source License 1.1\nNon-commercial use only.\n"}
        cases["terms-busl"] = {"vendor/x/TERMS-OF-USE.md": busl}
        cases["md-agpl-in-license"] = {"LICENSE.md": "# Licenses of bundled dependencies\n\n" + long_mit + "\n\n" + agpl_md}
        for name, files in cases.items():
            d = nm / name
            for fname, text in dict(files, **{"package.json": json.dumps({"name": name, "version": "1.0.0", "license": "MIT"}),
                                              "LICENSE": MIT_TEXT}).items():
                (d / fname).parent.mkdir(parents=True, exist_ok=True)
                (d / fname).write_text(text)
        (nm / "plain-notices" / "dist").mkdir(parents=True)
        (nm / "plain-notices" / "package.json").write_text(json.dumps({"name": "plain-notices", "version": "1.0.0", "license": "MIT"}))
        (nm / "plain-notices" / "LICENSE").write_text(MIT_TEXT)
        (nm / "plain-notices" / "dist" / "THIRD_PARTY_NOTICES.md").write_text(long_mit + "\n## bar\nLicense: MIT OR GPL-3.0-only\n")
        inv = Inventory(tmp / "out", "r4")
        scan_npm(inv, nm)
        errors, _, _ = check(inv.write(), pol)
        for name in cases:
            eq(any(" %s@" % name in e for e in errors), True, "合并的第三方清单里的禁止名单许可证要拦：%s（%s）"
               % (name, inv.components[("npm", name, "1.0.0")]["file_licenses"]))
        eq([e for e in errors if "plain-notices@" in e], [], "第三方清单里只有宽松的、要审查的许可证不报")
    eq((is_legal_file("3rdpartylicenses.txt"), is_legal_file("EULA.txt"), is_legal_file("TERMS-OF-USE.md"), is_legal_file("TERMS.md"),
        is_legal_file("LEGAL.txt"), is_legal_file("terms.json"), is_legal_file("glossary-terms.txt"), is_legal_file("legalese.py")),
       (True, True, True, True, True, False, False, False), "3rdpartylicenses.txt、EULA、TERMS 是原文，名字里带 terms 的别的文件不是")
    eq(identify(agpl_1)[0], "AGPL-1.0-only", "AGPL-1.0（标题没有 GNU）")
    eq(identify(AGPL_TEXT)[0], "AGPL-3.0-only", "GNU 的 AGPL 还是 AGPL-3.0")
    # 限制性说法：Markdown 的强调、引用、注释前缀、各种连字符拆不开；长得像拉丁字母的字母、附加符号、格式字符藏不住
    with tempfile.TemporaryDirectory() as tmp:
        for i, (tail, want) in enumerate([
                ("This software may **not** be used for commercial purposes.", "may not be used for commercial"),
                ("**NOT** for commercial use.", "not for commercial"), ("Licensed for non-*commercial* use.", "non commercial"),
                ("> This software may not be used for\n> commercial purposes.", "may not be used for commercial"),
                ("Business Source\n// License 1.1.", "business source license"),
                ("non‑commercial use only", "non commercial"), ("non–commercial use", "non commercial"),
                ("non­commercial use", "noncommercial use"), ("non−commercial use", "non commercial"),
                ("Free for nón-commercíal use only.", "non commercial"), ("Free for non-commercıal use.", "non commercial"),
                ("Business Sóurce License", "business source license"), ("Commons​ Clause", "commons clause")]):
            f = Path(tmp) / ("LICENSE%d" % i)
            f.write_text(MIT_TEXT + "\n" + tail + "\n")
            eq(want in restricted_terms([f]), True, "限制性说法照样找得到：%r" % tail)
    for tail in ["Nᴏt for commercıal use.", "Nót for commercíal use.", "NOT FOR COMMERCİAL USE.", "N​ot for comm​ercial use."]:
        eq(detect_text(MIT_TEXT + "\n" + tail + "\n"), None, "换了字母写的限制核对不上：%r" % tail)
    agpl_glyph = AGPL_TEXT.replace("PUBLIC", "PUBLІC") + "\nunder the terms of the GNU Affero General Publıc License as published by\n"
    eq(("AGPL-3.0-only" in candidates(agpl_glyph), "AGPL-3.0-only" in deny_sections(MIT_TEXT * 3 + agpl_glyph)), (True, True),
       "大写的 І、无点的 ı 写的 AGPL 照样认")
    eq(detect_text(MIT_TEXT.replace("2024 Someone", "2024 Søren Łukasz, Jürgen Straße, Barış Çelik")), "MIT",
       "名字里的 ø ł ß ı ç 不算外文")
    eq(detect_text("﻿" + MIT_TEXT), "MIT", "开头的 BOM 不算")
    # 版权声明里藏的条款：讲授权、使用条件的词，方括号、尖括号里的字，都不当版权声明去掉
    for notice in [
            "Copyright (c) 2024 Foo Inc, licensed for academic research and teaching at accredited universities",
            "Copyright (c) 2024 Foo Inc, for use by Foo employees and contractors on Foo projects",
            "Copyright (c) 2024 Foo Inc, Licensed For Academic Research",
            "Copyright (c) 2024 Foo Inc., licensed to holders of a valid Foo Pro license key for use on one seat per key",
            "Copyright (c) 2024 Foo Inc. © Free for universities and research labs, everyone else needs written approval from Foo Inc.",
            "Copyright (c) 2024 Foo Inc., production deployments need a Foo Enterprise license from foo.example.",
            "Copyright (c) 2024 Foo Inc. [Licensed to ACME Corp, internal use only]",
            "Copyright (c) 2024 Foo Inc. [not for resale] [no commercial use] [evaluation copy, expires 2025]",
            "Copyright (c) 2024 Foo Inc. <This copy is licensed for non-production evaluation only> <You may not redistribute it>",
            "Copyright 2024 John Q. Public. Licensed for internal evaluation only.", "Copyright 2024 J. Doe. Do not redistribute.",
            "Copyright 2024 Foo; use by customers requires a fee", "Copyright (c) 2024 Foo (https://foo.example/only-personal-use)"]:
        eq(detect_text(notice + "\n\n" + mit_body), None, "版权声明里的条款核对不上：%s" % notice)
    for notice in [
            "Copyright (c) 2016 Nathaniel J. Smith <njs@pobox.com> and other contributors",
            "Copyright (c) Isaac Z. Schlueter, Kat Marchán, npm, Inc., and Contributors",
            "Copyright (c) 2018 Kyle E. Mitchell & other authors listed in AUTHORS",
            "Copyright 2010 James Halliday (mail@substack.net); Modified work Copyright 2014 Contributors (ben@npmjs.com)",
            "Copyright (c) 2010-2017, Christian Johansen, christian@cjohansen.no", "Copyright (c) 2019 Ola Nordmann <ola@example.no>",
            "Copyright (c) 2025 Nous Research", "Copyright © 2026 to present Pydantic Services Inc. and individual contributors.",
            "Copyright (c) 2015 holger krekel (rather uses bitbucket/hpk42)", "Copyright (c) 2010-2026 Google LLC. https://angular.dev/license",
            "Copyright 2015 The Public Sans Project Authors (https://github.com/uswds/public-sans)",
            "Copyright (c) 2013 Foo Bar. Digitized data copyright (c) 2010-2012 The Baz Foundation and Qux S.A.",
            "Copyright {yyyy} {name of copyright owner}"]:
        eq(detect_text(notice + "\n\n" + mit_body), "MIT", "真实的版权声明照样核对得上：%s" % notice)
    ofl_terms = ofl[ofl.index("SIL OPEN FONT LICENSE"):]
    eq(detect_text("Copyright (c) 2011, Pablo Impallari (www.impallari.com|impallari@gmail.com),\nwith Reserved Font Name "
                   "\"Abril Fatface\".\n\n" + ofl_terms), "OFL-1.1", "OFL 的“with Reserved Font Name”折到下一行")
    for notice in ["Copyright 2024 Foo Type Foundry (foo@example.com),\nwith Reserved Font Name \"Foo Sans\", desktop use licensed separately.",
                   "Copyright 2024 Foo Type Foundry, with Reserved Font Name Foo Sans, desktop installation and app embedding licensed "
                   "separately by Foo Type Foundry."]:
        eq(detect_text(notice + "\n\n" + ofl_terms), None, "OFL 版权行里的条件核对不上：%s" % notice)
    # 真实原文的写法：OFL 的说明折行不同、开头的版权声明很长；BSD 第三条写成“may not be used to endorse”；行尾连字符
    ofl_head = "Copyright 2012 Google Inc. All Rights Reserved.\n\n"
    eq(detect_text(ofl_head + "This Font Software is licensed under the SIL Open Font License,\nVersion 1.1.\n\nThis license is copied "
                   "below, and is also available with a FAQ at:\nhttps://openfontlicense.org\n\n" + ofl_terms), "OFL-1.1", "OFL 的说明折了行")
    eq(detect_text(ofl_head + "This Font Software is licensed under the SIL Open Font License, Version 1.1,\nThis license is copied "
                   "below, and is also available with a FAQ at: https://openfontlicense.org\n\n" + ofl_terms), "OFL-1.1", "OFL 的说明“Version 1.1,”")
    long_header = " ".join("Copyright (c) %d, Foundry Number %d (https://foundry%d.example)." % (2000 + i, i, i) for i in range(8))
    eq(identify(long_header + "\n\n" + ofl), ("OFL-1.1", True), "版权声明比提名窗口长的 OFL")
    bsd_author = BSD3_TEXT.replace("Neither the name of the copyright holder nor the names of its contributors may be used",
                                   "The name of the author may not be used")
    eq(bsd_author != BSD3_TEXT and detect_text(bsd_author) == "BSD-3-Clause", True, "BSD-3 第三条“The name of the author may not be used”")
    eq(detect_text(bsd_author.replace("may not be used to endorse", "may not be used for commercial purposes or to endorse")), None,
       "第三条里加的限制照样核对")
    hyphenated = MIT_TEXT.replace("distribute,", "dis-\ntribute,").replace("following", "fol-\nlowing")
    eq((hyphenated != MIT_TEXT, detect_text(hyphenated)), (True, "MIT"), "行尾连字符拆开的词（dis-/tribute）")
    eq(detect_text(BSD3_TEXT.replace("Redistributions in binary form", "Redistribution in binary form")), "BSD-3-Clause", "单复数不同")
    # 不用那几个限制性的词写的条件：多出来的整句话、讲使用的词、授权句里加的或删的实词、没提到的 copyleft 名字
    for tail in ["Redistribution needs written approval.", "Resale disallowed.", "Use by governments is barred.",
                 "Companies need a license.", "One seat per license.", "Production deployments need a Foo Enterprise license.",
                 "Redistribution in a SaaS offering is reserved.", "Licensed under the GNU Affero General Public License version 3.",
                 "Military use is disallowed."]:
        eq((detect_text(MIT_TEXT + "\n" + tail + "\n"), detect_text(tail + "\n\n" + MIT_TEXT)), (None, None),
           "前后加的条件核对不上：%s" % tail)
    eq(detect_text("For academic research use.\n\n" + MIT_TEXT), None, "开头加的“For academic research use.”核对不上")
    for a, b in [("to deal in the Software", "to deal in the Software on Foo hardware"),
                 ("copies of the Software,", "copies of the Software for academic research,")]:
        eq(detect_text(MIT_TEXT.replace(a, b, 1)), None, "授权句里加的话核对不上：%s" % b)
    for pat, new in [(r"make,\s+have\s+made,\s+", ""), (r"import,\s+and\s+otherwise\s+transfer", "and transfer"),
                     (r"publicly\s+display,\s+publicly\s+perform,\s+", ""), (r"non-exclusive,\s+no-charge,\s+", "")]:
        narrowed = re.sub(pat, new, APACHE_TEXT)
        eq((narrowed != APACHE_TEXT, detect_text(narrowed)), (True, None), "Apache 的授权删了词核对不上：%s" % pat)
    for name, text, want in [
            ("BSD 授权句里多了“as well as documentation”",
             BSD3_TEXT.replace("binary forms, with", "binary forms of the software as well as documentation, with"), "BSD-3-Clause"),
            ("OFL 旧的前言（font names of derivative works are changed）",
             ofl.replace("provided that any reserved names are not used by derivative works", "provided that the font names of "
                         "derivative works are changed"), "OFL-1.1"),
            ("版权方叫 Grant", "Copyright 2014-2019 Grant Jenks\n\n" + mit_body, "MIT"),
            ("版权方是小写的 npm, Inc.", ISC_TEXT.replace("2024 Someone", "npm, Inc.").replace("Copyright (c)", "Copyright"), "ISC")]:
        eq(detect_text(text), want, "真实原文的写法核对得上：%s" % name)
    # 很长的分隔线、空白不能让正则来回回溯（找“License: X”行时曾经是平方级的）
    import time

    started = time.time()
    deny_sections(("-" * 100 + "\n") * 3000 + "License: AGPL-3.0-only\n")
    restricted_in_dashes = _restricted_in((" " * 100 + "\n") * 3000)
    eq((time.time() - started < 3, restricted_in_dashes), (True, []), "几千行分隔线、空白几秒内扫完")
    # PyPI：常见的 License 字段写法；很长、多行的 License 字段当原文核对；只有含糊的分类时认不出的原文照样算
    for text, want in [("BSD 3-Clause License", "BSD-3-Clause"), ("BSD-3-Clause License", "BSD-3-Clause"), ("Expat license", "MIT"),
                       ("Expat (MIT/X11)", "MIT"), ("Simplified BSD License", "BSD-2-Clause"), ("Revised BSD License", "BSD-3-Clause"),
                       ("BSD (3-clause)", "BSD-3-Clause"), ("Apache 2.0 License", "Apache-2.0"), ("Apache License v2.0", "Apache-2.0"),
                       ("Apache License (2.0)", "Apache-2.0"), ("Apache-2.0 license", "Apache-2.0"), ("MPL v2", "MPL-2.0"),
                       ("MPLv2.0", "MPL-2.0"), ("ISCL", "ISC"), ("CC0 1.0 Universal", "CC0-1.0"), ("ZPL 2.1", "ZPL-2.1"),
                       ("LGPLv3", "LGPL-3.0-only"), ("LGPL v3", "LGPL-3.0-only"), ("LGPLv3+", "LGPL-3.0-or-later"),
                       ("GNU LGPL", "LicenseRef-LGPL-Unspecified"), ("GPLv2+", "GPL-2.0-or-later"), ("The MIT License (MIT)", "MIT"),
                       ("MIT (non-commercial use only)", None), ("Apache 2.0 (with Commons Clause)", None), ("Elastic License", None),
                       ("MIT No Attribution License", None), ("Business Source License", None)]:
        eq(normalize_declared(text), want, "PyPI 的 License 写法：%s" % text)
    with tempfile.TemporaryDirectory() as tmp:
        sp = Path(tmp) / "sp"
        eula = ("This software is the confidential property of Foo Corp. Use of this software requires a separate written agreement "
                "with Foo Corp; redistribution is not permitted.")
        nc = "Free for non-commercial use. Commercial use requires a paid license from Foo Inc.; contact licensing@foo.example for details."
        mit_cls = "Classifier: License :: OSI Approved :: MIT License\n"
        bsd_cls = "Classifier: License :: OSI Approved :: BSD License\n"
        fold = lambda t: t.strip().replace("\n", "\n        ")
        for name, headers, files in [
                ("long-commons", "License: %s\n%s" % (fold(MIT_TEXT + "\n\"Commons Clause\" License Condition v1.0\n"), mit_cls), {}),
                ("long-eula", "License: %s\n%s" % (eula, mit_cls), {}),
                ("long-eula-file", "License: %s\n" % eula, {"LICENSE": MIT_TEXT}),
                ("long-nc", "License: %s\n%s" % (nc, mit_cls), {"LICENSE": MIT_TEXT}),
                ("long-ccnc", "License: %s\n%s" % (fold("Attribution-NonCommercial 4.0 International\n\nCreative Commons Corporation "
                                                       "is not a law firm.\n"), mit_cls), {}),
                ("vague-proprietary", bsd_cls, {"LICENSE": "Copyright (c) 2024 Acme Corp. All rights reserved. " + eula}),
                ("vague-bsd3", bsd_cls, {"LICENSE": BSD3_TEXT}),
                ("vague-mit", bsd_cls, {"LICENSE": MIT_TEXT})]:
            d = sp / ("%s-1.0.dist-info" % name.replace("-", "_"))
            d.mkdir(parents=True)
            (d / "METADATA").write_text("Metadata-Version: 2.1\nName: %s\nVersion: 1.0\n%s\nx\n" % (name, headers))
            for fn, text in files.items():
                (d / fn).write_text(text)
        inv = Inventory(Path(tmp) / "out", "pypi")
        scan_python(inv, sp)
        got = {k[1]: v for k, v in inv.components.items()}
        errors, _, _ = check(inv.write(), pol)
        for name in ("long-commons", "long-eula", "long-eula-file", "long-nc", "long-ccnc", "vague-proprietary"):
            eq(any("pypi %s@" % name in e for e in errors), True, "PyPI 要拦：%s（%s）" % (name, got[name]["license"]))
        eq(got["long-commons"]["restricted_terms"] is not None and got["long-ccnc"]["restricted_terms"] is not None, True,
           "License 字段里的限制性说法也找")
        eq((got["long-eula"]["license"], got["long-eula"]["declared"].startswith("License: This software is the confidential")), (None, True),
           "很长的 License 字段核对不上就是认不出的声明，清单里也列出来")
        eq((got["vague-proprietary"]["license"], got["vague-bsd3"]["license"], got["vague-mit"]["license"]),
           ("LicenseRef-Unrecognized AND LicenseRef-BSD-Unspecified", "BSD-3-Clause", "MIT AND LicenseRef-BSD-Unspecified"),
           "只有含糊的分类：同一类的原文细化，别的原文（包括认不出的）一起算")
    # GPL、LGPL 原文前面有好几段说明（Linux、git、libgit2 的 COPYING）：按文件里任何位置的正文标题提名
    preface = ("NOTE! This copyright does *not* cover programs that merely use the services of this project through its "
               "public interfaces - that is considered normal use, and does *not* fall under the heading of \"derived work\". "
               "Also note that the only valid version of the GPL as far as this project is concerned is _this_ particular "
               "version of the license (ie v2, not v2.2 or v3.x or whatever), unless explicitly otherwise stated.\n\n"
               "In addition to the permissions in the GNU General Public License, the authors give you unlimited permission "
               "to link the compiled version of this library into combinations with other programs, and to distribute those "
               "combinations without any restriction coming from the use of this file.\n\n----------\n\n")
    with tempfile.TemporaryDirectory() as tmp:
        nm = Path(tmp) / "node_modules"
        cases = {}
        for lid in ("GPL-2.0-only", "GPL-3.0-only", "LGPL-2.1-only", "LGPL-2.0-only"):
            text = preface + _spdx_text(lid)
            eq((candidates(text)[:1], examine(text)["titled"]), ([lid], True), "%s 前面有长说明照样按标题提名" % lid)
            cases["preface-root-%s" % lid.lower()] = {"COPYING": text}
            cases["preface-bundled-%s" % lid.lower()] = {"vendor/libgit2/COPYING": text}
        cc = {"CC-BY-SA-4.0": "Attribution-ShareAlike 4.0 International", "CC-BY-ND-4.0": "Attribution-NoDerivatives 4.0 International",
              "CC-BY-NC-SA-4.0": "Attribution-NonCommercial-ShareAlike 4.0 International", "CC-BY-SA-3.0": "Attribution-ShareAlike 3.0 Unported"}
        for lid, title in cc.items():
            text = "%s\n\n=======\n\nCreative Commons Corporation (\"Creative Commons\") is not a law firm.\n" % title
            eq(candidates(text), [lid], "Creative Commons 的标题：%s" % lid)
            cases["cc-%s" % lid.lower()] = {"assets/emoji/LICENSE.txt": text}
        if Path("/usr/share/common-licenses/GFDL-1.3").is_file():
            gfdl = Path("/usr/share/common-licenses/GFDL-1.3").read_text(encoding="utf-8")
            eq(identify(gfdl)[0], "GFDL-1.3-only", "GFDL-1.3")
            cases["gfdl-docs"] = {"docs/COPYING.FDL": gfdl}
        cases["ccbysa-declared-ccby"] = {"LICENSE": "Attribution-ShareAlike 4.0 International\n\nCreative Commons Corporation is not a law firm.\n"}
        for name, files in cases.items():
            d = nm / name
            decl = "CC-BY-4.0" if name == "ccbysa-declared-ccby" else "MIT"
            for fname, text in dict({"LICENSE": MIT_TEXT}, **files, **{"package.json": json.dumps({"name": name, "version": "1.0.0", "license": decl})}).items():
                (d / fname).parent.mkdir(parents=True, exist_ok=True)
                (d / fname).write_text(text)
        inv = Inventory(Path(tmp) / "out", "families")
        scan_npm(inv, nm)
        errors, _, _ = check(inv.write(), Policy(dict(tomllib.loads(TEST_POLICY), allow=["MIT", "CC-BY-4.0"])))
        for name in cases:
            eq(any(" %s@" % name in e for e in errors), True, "声明里没有的要拦：%s（%s）" % (name, inv.components[("npm", name, "1.0.0")]["file_licenses"]))
    # creativecommons.org 发的 CC-BY-4.0 legalcode.txt；CPython 的 LICENSE（Python-2.0.1，前面有历史说明、后面有 0BSD）
    ccby = (SPDX_DIR / "CC-BY-4.0.txt").read_text(encoding="utf-8")
    legalcode = ccby.replace("Creative Commons Attribution 4.0 International", "Attribution 4.0 International\n\n" + "=" * 70, 1)
    for who in ("licensors", "licensees"):
        legalcode = legalcode.replace("More considerations for %s." % who,
                                      "More considerations for %s:\n    wiki.creativecommons.org/Considerations_for_%s\n" % (who, who))
    legalcode = legalcode.replace("considered the “Licensor.”", "considered the “Licensor.” The text of the Creative Commons public "
                                  "licenses is dedicated to the public domain under the CC0 Public Domain Dedication.")
    eq(identify(legalcode), ("CC-BY-4.0", True), "creativecommons.org 的 CC-BY-4.0 legalcode.txt")
    eq(identify(legalcode + "\nCommercial use of the Licensed Material requires a separate paid license.\n")[1], False,
       "legalcode 后面加条件核对不上")
    cpython = ((SPDX_DIR / "Python-2.0.1.history").read_text(encoding="utf-8") + (SPDX_DIR / "Python-2.0.1.txt").read_text(encoding="utf-8")
               + "\nZERO-CLAUSE BSD LICENSE FOR CODE IN THE PYTHON DOCUMENTATION\n----------\n\n"
               + ZERO_BSD_TEXT.split("\n\n", 1)[1])
    eq(identify(cpython), ("Python-2.0.1", True), "CPython 的 LICENSE")
    eq(identify((SPDX_DIR / "Python-2.0.1.txt").read_text(encoding="utf-8")), ("Python-2.0.1", True), "没有历史说明的 Python-2.0.1")
    eq(identify(cpython.replace("Thanks to the many outside volunteers", "Commercial redistribution requires a paid license. Thanks "
                                "to the many outside volunteers"))[1], False, "历史说明里加的条件照样核对")
    deny_pats = tomllib.loads(Path(__file__).with_name("policy.toml").read_text(encoding="utf-8")).get("deny", [])
    eq([p for p in deny_pats if not _DENY_CLASS.match(p.rstrip("*").rstrip("-") or "x")], [],
       "policy.toml 禁止名单里的每一类，_DENY_CLASS 都认（文件任何位置提到都记下）")
    # 太大不复制的原文也算哈希：登记例外钉住的原文列表要包括它
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        big = tmp / "pkg" / "THIRD_PARTY_LICENSES.txt"
        big.parent.mkdir()
        big.write_bytes(b"x" * (MAX_TEXT_BYTES + 10))
        inv = Inventory(tmp / "out", "big")
        c = inv.add("npm", "big", "1.0.0", "MIT", "MIT", "metadata", [big], big.parent)
        eq((c["files"], c["text_sha256"]), ([str(big)], [hashlib.sha256(big.read_bytes()).hexdigest()]), "太大的原文只记位置，哈希照算")

    # 仓库里的策略文件能加载，例外都写了理由
    real = Path(__file__).with_name("policy.toml")
    if real.is_file():
        Policy.load(real)

    if failures:
        for f in failures:
            print("FAIL", f)
        return 1
    print("licenses.py self-test: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
