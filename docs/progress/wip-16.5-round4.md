# wip/16.5-round4

目标：修 WBS 16.5（第三方许可证清单和检查）第四轮评审确认的 30 条发现，只改 `tools/licenses/` 和 `docs/licenses.md`。

已完成：
- 从 backend-core 建分支；基线语料（r3fix/run.py 的 4635 个文件、r3verify-falseneg/all.txt 的 9675 个）跑过。
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

进行中：
- 同义词绕过（发现 12）。

下一步：
- PyPI（4、17、27、28）、文档。

坑和决定：
- 不动 `crates/`、`docs/progress.md`（backend-core 上另一个会话在改）。
