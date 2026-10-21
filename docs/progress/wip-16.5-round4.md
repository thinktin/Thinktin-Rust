# wip/16.5-round4

目标：修 WBS 16.5（第三方许可证清单和检查）第四轮评审确认的 30 条发现，只改 `tools/licenses/` 和 `docs/licenses.md`。

已完成：
- 从 backend-core 建分支。

进行中：
- 按主题分组、复现，跑基线语料（r3fix/run.py，4635 个真实许可证文件）。

下一步：
- 逐个主题修，每个主题加自测用例，跑语料对比，提交推送。

坑和决定：
- 不动 `crates/`、`docs/progress.md`（backend-core 上另一个会话在改）。
