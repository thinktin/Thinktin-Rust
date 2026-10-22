# wip/16.5-round4

目标：修 WBS 16.5（第三方许可证清单和检查）第四轮评审确认的 30 条发现，只改 `tools/licenses/` 和 `docs/licenses.md`。

已完成：
- 从 backend-core 建分支；基线语料（r3fix/run.py 的 4635 个文件、r3verify-falseneg/all.txt 的 9675 个、dlfiles.txt 的
  3027 个）跑过。
- 大文件也算 SHA-256；git 地址去掉 SSH 端口、用户名（发现 2、9）。
- NOTICE、第三方许可清单找禁止名单许可证和限制性说法；3rdpartylicenses.txt、EULA、TERMS、LEGAL 算原文；
  Markdown 写的 AGPL、“License: AGPL-3.0-only”行、AGPL-1.0（发现 0、5、7、8、10、19、20）。
- 限制性说法不怕 Markdown 强调、引用、注释前缀、各种连字符；长得像拉丁字母的字母（ı、ᴏ、І）、附加符号、
  格式字符（BOM、软连字符、零宽空格）先换掉（发现 15、18；顺带修了 BOM 开头的 OFL，发现 22a）。
- GPL / LGPL / GFDL 的正文标题在文件任何位置都按标题提名；Creative Commons 各变体、GFDL、AGPL-1.0、
  creativecommons.org 的 legalcode.txt、CPython 的 LICENSE（Python-2.0.1）（发现 3、5、11、16、26、29）；
  policy.toml 登记 petgraph 0.8.3（Codex，吉祥物图片 CC-BY-SA-4.0，不编进去）。
- 版权声明只能是名字、年份、邮箱：讲授权的词、方括号里的字、太长的都照常核对；名字缩写、Modified work、.no 邮箱、
  Copyright Treaty、Reserved Font Name 折行不再误报（发现 1、6、13、14、21、23、22b）。
- OFL 说明折行、开头版权声明很长；BSD-3 “may not be used to endorse”；行尾连字符（发现 22、24、25）。
- 同义词绕过：授权句里改的实词、讲使用的词、多出来的整句话、条件词、没提到的 copyleft 名字（发现 12）。
- PyPI：很长的 License 字段当原文核对；只有含糊分类时认不出的原文照样算；更多 License 写法（发现 4、17、27、28）。
- “License:”行的正则只在一行之内匹配（几千行分隔线曾经卡住）；去附加符号改用 translate 表。
- docs/licenses.md 第 1、2、7、8 节按现在的行为改写；licenses.py 开头的核对规则说明也更新了。

进行中：
- 无。

下一步：
- 合并到 backend-core（见下面“坑和决定”最后几条）。

坑和决定：
- 不动 `crates/`、`docs/progress.md`（backend-core 上另一个会话在改）。
- 发现 12 没有改成评审建议的“多出来的词只许是网址”：语料里会丢 38 个真实原文。改成按结构的规则（授权句、讲使用的词、
  整句话、条件词），每条都在 14524 个真实文件上核对过没有误报。剩下的口子写在 docs/licenses.md 第 8 节。
- 发现 23 的后半（版权行里中文、日文、韩文、俄文的名字）没改：几个字的限制分不开，保守处理，写进第 8 节。
- 本地检查办法：docker 没开，用 r4/recheck.py 把五个镜像清单里复制出来的原文重新认一遍再 check（基线 0 个错误，
  和 CI 一致），r4/recheck_own.py 从 ~/.cargo/registry 重新扫我们六个 Rust 程序的 crate；r4/pypi_cmp.py 对比本地
  site-packages 的扫描结果。
- PyPI 的新规则会让 pandas、scipy、jupyter_client、nbformat、kiwisolver、matplotlib 要登记（License 字段、LICENSE 带着
  附加的说明）；这些都不在现在的镜像里（Hermes 的 72 个 PyPI 包都查过）。
- 合并时：重新构建模板（build.sh 会因为 licenses.py 改了重新生成 Codex 的 crate 清单），templates.yml 的检查应当通过；
  Codex 的 petgraph 0.8.3 登记已经加了。
