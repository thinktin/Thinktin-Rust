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
  SPDX 表达式、声明的原文、许可证从哪认出来的、原文文件、作者）。App 的“开源许可”页面读它。
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
| 放行 | MIT、Apache-2.0、BSD、ISC、Unlicense、MPL-2.0、EPL、LGPL（Rust 除外，见下） | 通过 |
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
2. 没有声明时：**PyPI 的许可证分类**（几个分类用 AND 连：分类本身不说明是“任选其一”；对照表里没有的分类算认不出）。
3. 再没有就看**原文**，分两步：先按正文开头的标题和授权条款里固定的句子提名（可能提名好几个：X11 也含 MIT 的授权句），
   再逐个拿**整份文件和 SPDX 标准文本核对**（`tools/licenses/spdx/<标识>.txt`，Apache-2.0、MPL-2.0 也认标准的头部声明）：
   去掉版权行以后，文件里多出来的词一段不超过 5 个、加起来不超过 8 个（标题、SPDX 标识行这类不算），标准文本缺的不超过
   四分之一。第一个对得上的算数；都对不上算认不出。这样前后加了专有声明、EULA、限制条款的不会被认成宽松许可证，代价是
   带了来历说明、额外版权行的文件也认不出（有声明的包不受影响，没声明的要登记）。
   包里有认不出的许可证文件时加上 `LicenseRef-Unrecognized`，要登记。
4. 含糊的声明（“BSD”）用核对过的原文细化成同一类的（BSD-3-Clause），不是同一类的两个都算（AND）；
   “AGPL”“GPL”这类含糊声明不会被原文改成宽松的。

不管从哪里认的，许可证原文里有限制商用、托管的说法（Commons Clause、non-commercial、BUSL、SSPL、PolyForm……）都会加上
`LicenseRef-Restricted-Terms`，要人看。

扫描的范围：全局 npm 包（`/usr/local/lib/node_modules`）、基础镜像带的 Yarn（`/opt/yarn-*`）、agent 虚拟环境里的 Python 包
（`.dist-info`、`.egg-info`；venv 里的 pip、setuptools 来自 Debian 的 wheel 包，它们 vendored 的第三方包的版权在 Debian 的
copyright 文件里，一并带上）、dpkg 装的包、Node.js 本身、agent-shim 的 crate，加上 `notices/` 里补的上游原文。Rust 只算会
编进程序的依赖：普通依赖，加上把 C 源码编进程序的 `*-src` 构建依赖（openssl-src 这种）。

## 3. 上游原文补充（`deploy/templates/notices/<agent id>/`）

有的上游没把原文放进 npm 包，或者包里的程序静态链接了别人的代码却没带原文。这些在 `sources.toml` 里登记：

- `[[file]]`：仓库里放的原文，`url` 钉在上游的标签或提交上。
- `[[installed]]`：镜像里有、但藏在包的子目录里（扫描只看包的根目录）的原文，按路径通配符找；一个也找不到时构建失败。
- `[[cargo]]`：上游的 Rust 程序依赖的 crate。`deploy/templates/build.sh` 构建前用 `licenses.py upstream-cargo` 从上游
  源码（浅克隆）生成到 `crates/`（不进仓库，按标签缓存），构建时并进清单；没生成就构建失败。
- `applies_to`：这些原文是按哪个包的哪个版本核对的。升级 agent 后镜像里没有这个版本，CI 报错，要重新核对、改版本号。

现在补了的：

| agent | 补了什么 |
|---|---|
| 所有模板（`_base`） | Node.js 的 LICENSE：官方镜像不带，构建时按镜像里 Node 的确切版本从上游取（里面还列了 Node 打包的 V8、OpenSSL、ICU 等） |
| Claude | Claude Code 二进制是 Bun 编译的单文件程序，npm 包里只有一行 Anthropic 的专有声明。补了 Bun 的许可说明和它静态链接的库的清单、JavaScriptCore（LGPL-2）、TinyCC（LGPL-2.1）、ugrep（BSD-3-Clause）、二进制里带的公共后缀表（MPL-2.0） |
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
3. **LGPL 的组件**。Claude Code 二进制里静态链接了 JavaScriptCore、TinyCC，Codex 带的 bubblewrap、语音运行时也是 LGPL。
   模板镜像只在平台自己的集群里运行、不交给用户时，原文带着就够了；将来要是把镜像交给客户（私有化部署），还要按 LGPL
   提供对应源码或书面承诺（上游的源码都是公开的，地址在 `sources.toml` 里）。base 镜像里的 GPL 软件（bash、git 等 Debian 包）同理。
4. **Bun 静态链接的其余各库**（BoringSSL、zstd、sqlite、ICU 等）的完整原文 Anthropic 没有随包提供，我们带了 Bun 自己的清单
   和链接（`bun-license.mdx`），要不要逐个补齐由法务定。
5. **App 上架**：iOS、Android 的“开源许可”页面要展示客户端核心的清单（12.x、13.x 做界面时接上）。

## 7. 现在的结果（2026-10-21）

| 镜像 | 组件 | 结果 |
|---|---|---|
| `agents/claude:0.90.0` | 471（npm 248、Debian 141、crate 76、上游补的 5） | 通过；Anthropic 的 SDK 和 Claude Code 二进制按专有组件登记 |
| `agents/codex:2.2.2` | 1443（crate 1119、Debian 141、npm 171、上游补的 11） | 通过；zsh 的许可证（没有 SPDX 标识）登记 |
| `agents/pi:1.2.0` | 477 | 通过 |
| `agents/openclaw:2026.10.3` | 765 | 通过 |
| `agents/hermes:0.19.0` | 436（含 Python 包 72） | 通过 |
| 服务端、agent-shim、客户端核心、电脑端工具服务 | 355、106、278、279 个 crate（不限平台） | 通过 |

没有发现网络 copyleft 或限制商用的许可证。弱 copyleft 有：MPL-2.0（几个 crate、Hermes 的 pathspec、Codex 的 symphonia、nucleo）、
LGPL（上面第 6 节第 3 条）。

## 8. 本地跑

```sh
python3 tools/licenses/licenses.py self-test
tools/licenses/rust.sh                                   # 发出去的 Rust 程序，结果在 target/licenses
deploy/templates/build.sh codex                          # 构建模板（会先生成 Codex 的 crate 清单）
docker run --rm thinktin/agents/codex:2.2.2 cat /usr/share/thinktin/licenses/inventory.json > /tmp/codex.json
python3 tools/licenses/licenses.py check /tmp/codex.json --manifest crates/catalog/manifests/codex.toml
```
