# 第三方许可证（WBS 16.5）

平台发出去的每样东西（agent 的模板镜像、服务端镜像、App 里的客户端核心）都带上第三方组件的许可证原文和清单，
CI 按许可证策略检查。法务的判断（商标、各家的使用条款）不是代码能定的，列在第 6 节留给人。

工具是 `tools/licenses/licenses.py`（只用 Python 标准库），策略是 `tools/licenses/policy.toml`，内置测试
`python3 tools/licenses/licenses.py self-test`。

## 1. 带在哪里

| 发出去的东西 | 清单和原文 | 什么时候生成 |
|---|---|---|
| agent 模板镜像（`deploy/templates`） | 镜像里的 `/usr/share/thinktin/licenses` | 模板构建时在镜像里扫描：全局 npm 包（连同全部依赖）、agent 虚拟环境里的 Python 包、Debian 包、Node.js 本身、agent-shim 的 crate，加上 `deploy/templates/notices/` 里补的上游原文 |
| 服务端镜像（`deploy/docker`） | 每个镜像的 `/usr/share/thinktin/licenses`（只算这个程序的 crate） | 镜像构建时按 `cargo metadata` |
| iOS / macOS 的 Swift 包 | `ThinktinCore` 的资源 `Licenses/`（`Bundle.module`） | `tools/client-core/build-apple.sh` |
| Android 库工程 | `assets/thinktin-licenses/` | `tools/client-core/build-android.sh` |

目录里有：

- `inventory.json`：每个组件一条（生态 `npm` / `pypi` / `deb` / `cargo` / `runtime` / `upstream`、名字、版本、许可证的
  SPDX 表达式、声明的原文、许可证从哪认出来的、原文文件、包里子目录下的原文（`bundled_files`：打包进来的第三方代码、
  图标、字体的）、字体（`assets`）、作者、源码在哪（`source_url`：源码仓库，或者 crates.io、npm、PyPI 上这个版本的页面，
  Debian 包是 snapshot.debian.org 上的源码包；LGPL、MPL 这类要求提供源码的，用户从这里拿）。App 的“开源许可”页面读它。
- `NOTICES.md`：人看的索引，按许可证汇总，再逐个列组件。
- `texts/by-hash/<哈希>/<原文件名>`：从包里复制来的 LICENSE、NOTICE、COPYING 等，按内容存（几百个 crate 的
  Apache-2.0 正文只存一份）。Debian 包的原文就在系统的 `/usr/share/doc/<包>/copyright`，不复制。
- `texts/spdx/`：包里没带原文的组件（npm 上不少包只在 package.json 写了 `"license": "MIT"`），用 SPDX 的标准文本
  （`tools/licenses/spdx/`，取自 spdx/license-list-data v3.29.0），版权方按包的元数据（作者）列在清单里。

## 2. 策略（`tools/licenses/policy.toml`）

许可证先认成 SPDX 表达式，再按策略判定。一个包可选几个许可证（`A OR B`）时取对我们最有利的一支，同时适用几个
（`A AND B`）时取最严的。每个许可证落在三类之一：

| 类别 | 例子 | 结果 |
|---|---|---|
| 放行 | MIT、Apache-2.0、BSD、ISC、Unlicense、OFL、CC-BY；弱 copyleft 的 MPL、EPL、CDDL、LGPL（Rust 除外，见下） | 通过（弱 copyleft 的义务见第 6 节第 3 条） |
| 禁止 | AGPL、SSPL、OSL、EUPL、RPL、CPAL（网络 copyleft：用户经网络使用就要向用户公开源码）；BUSL、Elastic、PolyForm、FSL、Commons Clause、CC 的非商用条款（限制商用或托管） | CI 报错，换掉这个包 |
| 其他 | GPL、专有、没写许可证、认不出来、原文里有限制性说法 | 要在 `[[exception]]` 登记、写明理由才通过 |

- **Rust**：crate 静态链接进我们的程序，LGPL 要求用户能换掉库重新链接，静态链接做不到，所以 Rust 的 LGPL 也要单独登记。
- **Debian**：base 镜像里的包都来自 Debian main（DFSG 自由软件）。一个包的 copyright 文件常列好几个许可证（测试文件、
  文档各不相同），不逐个判定，只拦禁止名单里的。
- **`A WITH 例外`**：例外只是额外放宽的（LLVM-exception、Classpath-exception 等，`allow_exceptions`）按 A 判定；
  在禁止名单里的（Commons-Clause 这种附加限制）直接禁止；别的要登记。
- **登记例外**按“生态 + 包名 + 版本 + 许可证”匹配，专有组件再钉住原文的 SHA-256（列表：包里的原文要正好是这几份）：
  上游换了许可证或改了条款原文，登记就对不上，CI 报错，要人重新看。写了 `agents` 的例外只对这些 agent 的镜像有效
  （别的 agent 带上同一个专有组件要另外审查），在这些 agent 的镜像里找不到也报错（上游换了包名，登记不能悄悄失效）。
- **清单的许可证**：App 的 agent 目录里显示的是清单 `agent.license`。`[agents.<id>] license_of` 指定它以哪个包为准，
  检查时两边要一样，上游改了许可证就会发现。

许可证从哪里认（原则：宁可认不出要人看，也不能认宽了）：

1. **元数据里的声明**（npm 的 `license`、PyPI 的 `License-Expression` / `License`、Cargo 的 `license`）：合法的 SPDX
   表达式（标识按 SPDX 的完整列表核对，`tools/licenses/spdx/license-ids.txt`），或对照表里的常见写法（“MIT License”
   “Apache 2.0”）。**有声明但认不出的，不再拿原文或分类去猜**，直接算认不出。`SEE LICENSE IN <文件>` 只看那个文件。
   PyPI 没有 `License-Expression` 时，`License` 字段和许可证分类都只是说明：分类里有 `License` 字段没提到的许可证，
   两个都算（AND）。
2. 没有声明时：**PyPI 的许可证分类**（几个分类用 AND 连：分类本身不说明是“任选其一”；对照表里没有的分类算认不出）。
3. 再没有就看**原文**，分两步：先按正文开头的标题和授权条款里固定的句子提名（可能提名好几个：X11 也含 MIT 的授权句），
   再逐个拿**整份文件和 SPDX 标准文本核对**（`tools/licenses/spdx/<标识>.txt`，Apache-2.0、MPL-2.0 也认标准的头部声明）：
   去掉版权行以后，文件里多出来的词一段不超过 5 个、加起来不超过 8 个（标题、SPDX 标识行这类不算），标准文本缺的不超过
   四分之一。第一个对得上的算数；都对不上算认不出。这样前后加了专有声明、EULA、限制条款的不会被认成宽松许可证，代价是
   带了来历说明、额外版权行的文件也认不出（有声明的包不受影响，没声明的要登记）。
   包里有认不出的许可证文件时加上 `LicenseRef-Unrecognized`，要登记。
4. 含糊的声明（“BSD”）用核对过的原文细化成同一类的（BSD-3-Clause），不是同一类的两个都算（AND）；
   “AGPL”“GPL”这类含糊声明不会被原文改成宽松的。

不管从哪里认的，还要和包里的许可证文件对一遍：文件核对过是要审查的许可证（声明 MIT，文件是 GPL 全文），或者看着像
禁止的许可证（AGPL……），而声明里没有它，报错要人看。只是顺带提到别的许可证的不算。

许可证原文里有限制商用、托管的说法（Commons Clause、non-commercial、BUSL、SSPL、PolyForm……）都会加上
`LicenseRef-Restricted-Terms`，要人看。

**包里子目录下的原文**（`vendor/x/LICENSE`、`fonts/x-OFL.txt`、名字里带 NOTICE、LICENSE、OFL 的，`licenses/` 目录下的；
npm 包不进它自己的 `node_modules`，那是别的包；PyPI 包按 RECORD 找）一起带上：不拿来认包的许可证，但和声明对照（上面那条）、
找限制性说法。

**字体**单独看：字体常常和包的代码分开授权，有的是商用字体（Hermes 的网页界面就带了付费字体）。包里每个字体文件
（`.ttf`、`.otf`、`.woff`、`.woff2`……）都要在 `policy.toml` 的 `[[asset]]` 登记许可证，按字体家族写路径，写明原文在哪：
`license_file`（包里的原文，要核对得上登记的许可证）或 `upstream`（`notices/` 里补的组件）。没登记的报错。
审查不过、agent 又用不到的，在清单的 `[install] prune` 里删掉（见 [templates.md](templates.md)），构建时在扫描前删。

扫描的范围：全局 npm 包（`/usr/local/lib/node_modules`）、基础镜像带的 Yarn（`/opt/yarn-*`）、agent 虚拟环境里的 Python 包
（`.dist-info`、`.egg-info`；venv 里的 pip、setuptools 来自 Debian 的 wheel 包，它们 vendored 的第三方包的版权在 Debian 的
copyright 文件里，一并带上）、dpkg 装的包、Node.js 本身、agent-shim 的 crate，加上 `notices/` 里补的上游原文。Rust 只算会
编进程序的依赖：普通依赖，加上把 C 源码编进程序的 `*-src` 构建依赖（openssl-src 这种）。

## 3. 上游原文补充（`deploy/templates/notices/<agent id>/`）

有的上游没把原文放进 npm 包，或者包里的程序静态链接了别人的代码却没带原文。这些在 `sources.toml` 里登记：

- `[[file]]`：仓库里放的原文，`url` 钉在上游的标签或提交上。
- `[[installed]]`：镜像里有、但藏在包的子目录里的原文，单独算一个组件（写明它的许可证），按路径通配符找；一个也找不到时
  构建失败。
- `source`（可省）：这个组件的源码在哪，写进清单的 `source_url`。
- `[[cargo]]`：上游的 Rust 程序依赖的 crate。`deploy/templates/build.sh` 构建前用 `licenses.py upstream-cargo` 从上游
  源码（浅克隆）生成到 `crates/`（不进仓库，按标签缓存），构建时并进清单；没生成就构建失败。
- `applies_to`：这些原文是按哪个包的哪个版本核对的。升级 agent 后镜像里没有这个版本，CI 报错，要重新核对、改版本号。

现在补了的：

| agent | 补了什么 |
|---|---|
| 所有模板 | Node.js 的 LICENSE（里面还列了 Node 打包的 V8、OpenSSL、ICU 等）：官方镜像放在 `/usr/local/LICENSE`，扫描时按开头确认是 Node 的再用；没有时按镜像里 Node 的确切版本从上游取。`_base/` 现在是空的，留给所有模板都要补的原文 |
| Claude | Claude Code 二进制是 Bun 编译的单文件程序，npm 包里只有一行 Anthropic 的专有声明。补了 Bun 的许可说明和它静态链接的库的清单、JavaScriptCore（LGPL-2）、TinyCC（LGPL-2.1）、ugrep（BSD-3-Clause）、二进制里带的公共后缀表（MPL-2.0） |
| OpenClaw | Playwright 带的 VS Code 图标字体 codicon：VS Code 的 MIT 原文（Playwright 源码树里有、npm 包里没有）和 vscode-codicons 的 CC-BY-4.0 原文 |
| Hermes | 网页界面终端用的 JetBrains Mono 字体的 OFL 原文 |
| Pi | 上游仓库的 MIT LICENSE（Pi 的 npm 包都写了 MIT，却都没带原文） |
| Codex | Apache-2.0 的 LICENSE、NOTICE（npm 包里都没有）；bubblewrap（LGPL-2.0-or-later）、libcap、zsh（改过）、ripgrep、PCRE2、musl、OpenSSL、V8、wezterm 的原文；语音运行时（GStreamer、GLib 等）包里自带的原文；Codex 自己 1067 个 crate（标签 rust-v0.160.1 的源码） |

## 4. CI

- `ci.yml` 每次推送：内置测试，加上 `tools/licenses/rust.sh` 检查发出去的每个 Rust 程序（服务端、agent-shim、
  客户端核心、电脑端工具服务）依赖的 crate。不限平台，算的是所有平台上可能编进去的依赖。
- `templates.yml` 构建每个模板后，取出镜像里的 `inventory.json`，带着 agent 清单检查（还核对清单 `[install]` 锁的包都在、
  版本对、`agent.license` 和上游一致）。问题写成注解，汇总写进运行的摘要页。
- 每周一 `upstream.py` 看上游新版本时，也对比新版本的许可证，变了的写成警告。

## 5. CI 报了许可证问题怎么办

| 报错 | 处理 |
|---|---|
| 认不出许可证 | 看包里的 LICENSE 和 package.json / METADATA。是常见写法没收进对照表的，加进 `licenses.py` 的 `FREE_TEXT`；真没写许可证的，按 GPL 一类处理（下一行） |
| 需要单独审查（GPL、专有……） | 弄清这个包在镜像里怎么用、许可证要求什么，确认能用后在 `policy.toml` 登记 `[[exception]]`，理由写清楚；拿不准的找法务 |
| 许可证是 X，但包里的文件是（像是）Y | 声明和原文对不上：看包的源码仓库，弄清到底按哪个许可证发布。声明写错了、Y 只管个别文件的，确认后登记 `[[exception]]`（license 写扫描出的 X，用 `text_sha256` 钉住原文）；真是 Y 的按 Y 处理 |
| 在禁止名单里 | 不能用：换一个包，或者让上游换依赖。依赖是间接引进来的，看能不能用 npm 的 `overrides` 去掉 |
| 清单的 `agent.license` 和上游对不上 | 上游改了许可证：复核新许可证还能不能这么用（第 6 节），再改清单 |
| 登记的例外在镜像里没找到 | 上游换了包名或许可证：重新复核，更新登记 |
| `notices/<id>` 的原文按旧版本核对的 | 升级了 agent：按 `sources.toml` 开头的说明重新核对每个组件的版本和原文，换 URL 和文件，改 `applies_to` |

## 6. 留给人的（法务复核，上线前）

代码能保证“带了原文、没有禁止的许可证、例外都登记了”，下面这些要人判断：

1. **Claude（Anthropic 专有）**。Anthropic 的 legal-and-compliance 页面允许在托管沙箱里预装、运行 Claude Code，条件是
   （2026-10-20 核对）：接受 Anthropic 商业条款；二进制不改，不去掉、不限制它自带的登录方式（Claude 账号、用户自己的
   API key）；平台不代付、不转售、不居间 Claude 用量，每个用户用自己的 Anthropic key、Claude 订阅或第三方推理平台的凭证。
   要确认：
   - 平台的形态（用户自带 key，模型请求经平台的模型网关转发）算不算“居间”；
   - WBS 里 P4 的“平台代付额度”不能用在 Claude 上；
   - 2026-10-14 定的“Claude agent 什么 key 都能接”（含非 Anthropic 的兼容接口）和条款、地区政策的关系
     （[接入说明 2.1 节](agent-integration.md)）。
2. **命名和商标**。App 里叫“Claude Agent”（Agent SDK 的品牌指引允许的写法），不能叫“Claude Code”或用 Anthropic 的标志；
   Codex 不能做我们的产品名（OpenAI 的品牌指引不允许在应用名里用它的模型名），可以说“使用 OpenAI Codex”；
   OpenClaw、Hermes（Nous Research）、Pi 的名字和图标用在 App 的 agent 目录里，要看各自的商标政策。
3. **弱 copyleft 的义务**（清单见第 7 节，`licenses.py summary` 生成）。不改上游代码时，要做的是“带原文、告诉对方源码在哪”：
   - **MPL-2.0**（Codex 的 symphonia、nucleo，客户端核心和电脑端的 uniffi，OpenClaw 的 web-push 和两个原生包
     `@trycua/cua-driver`、`@ubjs/node`，Hermes 的 certifi、pathspec、tqdm）：以可执行形式分发时，要让对方知道怎么拿到
     这部分的源码（3.2 条）。npm、PyPI 包本身就是源码；编进程序的（Rust crate、原生包）靠清单里的 `source_url`
     （crates.io、上游仓库的版本页）和 App 的“开源许可”页面。改了 MPL 的文件，改过的文件要按 MPL 公开。
   - **EPL、CDDL**：同 MPL（现在的镜像里没有）。
   - **LGPL**：Claude Code 二进制里静态链接了 JavaScriptCore、TinyCC，Codex 带的 bubblewrap、语音运行时（GStreamer、GLib）。
     模板镜像只在平台自己的集群里运行、不交给用户时，原文带着就够了；将来要是把镜像交给客户（私有化部署），还要按 LGPL
     提供对应源码或书面承诺：源码地址在清单的 `source_url`（`sources.toml` 的 `source`），Codex 语音运行时每个库的确切
     源码包和 SHA-256 在它带的 `sources.json` 里（一起带进了清单）。base 镜像里的 GPL 软件（bash、git 等 Debian 包）同理，
     源码包在 snapshot.debian.org（清单里有链接）。
   - **Bun 编译的 Claude Code 二进制**静态链接 JavaScriptCore（LGPL-2）：LGPL 要求用户能换掉库重新链接，单文件程序做不到；
     这是 Anthropic 分发的二进制，我们原样转发，要法务看转发时我们要承担什么。
4. **Bun 静态链接的其余各库**（BoringSSL、zstd、sqlite、ICU 等）的完整原文 Anthropic 没有随包提供，我们带了 Bun 自己的清单
   和链接（`bun-license.mdx`），要不要逐个补齐由法务定。
5. **App 上架**：iOS、Android 的“开源许可”页面要展示客户端核心的清单（12.x、13.x 做界面时接上）。

## 7. 现在的结果（2026-10-21）

`python3 tools/licenses/licenses.py summary <各个 inventory.json>` 生成：

| 清单 | 组件 | 结果 |
|---|---|---|
| `agents/claude:0.90.0` | 471（cargo 76、deb 141、npm 248、runtime 1、upstream 5） | 通过；Anthropic 的 SDK 和 Claude Code 二进制按专有组件登记 |
| `agents/codex:2.2.2` | 1443（cargo 1119、deb 141、npm 171、runtime 1、upstream 11） | 通过；zsh 的许可证（没有 SPDX 标识）、lzma-sys 带的 xz 源码树登记 |
| `agents/pi:1.2.0` | 477（cargo 76、deb 141、npm 258、runtime 1、upstream 1） | 通过；删掉了 DOOM 演示扩展 |
| `agents/openclaw:2026.10.3` | 766（cargo 76、deb 141、npm 547、runtime 1、upstream 1） | 通过；网页界面的 9 个 OFL 字体家族、Playwright 的 codicon 字体登记 |
| `agents/hermes:0.19.0` | 437（cargo 76、deb 141、npm 146、pypi 72、runtime 1、upstream 1） | 通过；删掉了网页界面的商用字体，JetBrains Mono 登记 |
| 服务端、agent-shim、客户端核心、电脑端工具服务 | 355、106、278、279 个 crate（不限平台） | 通过 |

没有发现网络 copyleft 或限制商用的许可证。非用不可的 copyleft（`A OR B` 里有宽松一支的不算；Debian 包不算）：

- LGPL：JavaScriptCore（LGPL-2.0）、TinyCC（LGPL-2.1，都在 Claude Code 二进制里）；bubblewrap（LGPL-2.0-or-later）、
  语音运行时（LGPL-2.1、LGPL-2.0，都在 Codex 里）。
- MPL-2.0：Codex 的 nucleo、nucleo-matcher、option-ext 和 symphonia 一族（9 个 crate）；客户端核心和电脑端工具服务的
  uniffi 一族（8 个 crate）；OpenClaw 的 web-push、`@trycua/cua-driver-linux-x64-gnu`、`@ubjs/core`、`@ubjs/node`、
  `@ubjs/node-linux-x64-gnu`；Hermes 的 certifi、pathspec、tqdm；Claude Code 二进制里的公共后缀表。

## 8. 已知的缺口

扫描只能看到包里写明的东西。下面这些看不全，要人知道：

- **包里编译好的原生代码**：npm 的 `.node`、`.wasm`（koffi、node-pty、tree-sitter、OpenClaw 的原生包），PyPI 的 wheel 里的
  `.so`（cryptography 静态链接的 OpenSSL 和 Rust crate，pydantic-core 的 Rust crate，uvloop 的 libuv，Pillow 的 libjpeg、
  libpng、freetype 等）。它们静态链接的第三方代码，只有包自己带了原文的才在清单里。
- **打包好的 JavaScript**（`dist/*.js`、Hermes 的 `web_dist/assets/*.js`）：打包工具把依赖合进一个文件，依赖的许可证注释
  在文件里，不单独扫描。
- **Codex 二进制里 V8 带的第三方库**（ICU、abseil 等）和 **Bun 静态链接的各库**（BoringSSL、zstd、sqlite 等）：只带了
  上游给的清单和主要的原文（第 3 节）。
- **Rust crate 里的字体**（`include_bytes!` 编进程序的）不检查；crate 子目录里的原文只在核对得上时才和声明对照
  （没核对上的 GPL 原文常是“任选其一”里的另一支，比如 zstd 的 `BSD OR GPL-2.0`）。
- **Android 库工程的 JVM 依赖**（JNA、kotlinx-coroutines）不在清单里：`build-android.sh` 只生成了 Rust 客户端核心的清单，
  App 工程（13.x）接入时要加上 Gradle 依赖的许可证。
- **Codex 的 1071 个 crate** 按上游 `rust-v0.160.1` 标签的 Cargo.lock 解析（不加 `--locked`，因为上游发布时只改工作区版本号），
  和 OpenAI 实际构建用的可能有出入。

## 9. 本地跑

```sh
python3 tools/licenses/licenses.py self-test
tools/licenses/rust.sh                                   # 发出去的 Rust 程序，结果在 target/licenses
deploy/templates/build.sh codex                          # 构建模板（会先生成 Codex 的 crate 清单）
docker run --rm thinktin/agents/codex:2.2.2 cat /usr/share/thinktin/licenses/inventory.json > /tmp/codex.json
python3 tools/licenses/licenses.py check /tmp/codex.json --manifest crates/catalog/manifests/codex.toml
python3 tools/licenses/licenses.py summary /tmp/*.json target/licenses/*/inventory.json   # 第 7 节的汇总
```
