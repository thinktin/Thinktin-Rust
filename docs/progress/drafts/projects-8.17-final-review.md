# 8.17 收尾的对抗评审（workflow `review-8-17-final`，2026-11-10）

评审对象：`ad6d73d`（8.17 全部：派单、看板、项目里的查队友、提问、委派、流水线、负责人、派单开关和库里的栅栏、迁移 0060–0065）。
四个角度（隐私、数据库和并发、流水线、接口约定和文档）各一个评审，每条发现一个核对的试着推翻。27 条发现，成立 20 条（去重 14 个），
推翻 7 条。没有跨用户的数据整个漏出去的问题。

## 成立的（去重以后 14 个）

| # | 问题 | 级别 | 几个角度报了 | 怎么修 |
|---|---|---|---|---|
| 1 | 创建者给别人的 botin 派任务、开始流水线被拒绝时，409 的代码分得太细：`budget_reached` 说明对方的预算或限额用完了，`agent_unavailable` 现在实际上只剩“对方账号被冻结”一种情况。agent 那边故意只给一种说法，App 这边却分开了 | 低（一个角度定中） | 3 | 目标不是创建者自己的 botin 时，预算用完和用不了合成一个 `agent_unavailable`、一句中性的话；自己的 botin 照旧分开 |
| 2 | 别的主人的 agent 提问、委派时，回复里写着“对方主人暂停了它”，等于告诉它对方按了“全部停止”（C6 评审推翻过，理由是成员本来就看得到“等主人”，其实等确认的任务对成员显示的是“排队”） | 低 | 1 | 目标不是同一个主人时，等确认的和普通排队的回复一样，不提主人、不提暂停 |
| 3 | 同一个主人的 botin 之间提问、委派，子任务用的是调用方的预算，没取目标 botin 自己的限额，主人给它设的限额被绕过去 | 低 | 1 | 取两者里小的那个 |
| 4 | 提问、委派、流水线替别的主人签了常设授权，没写审计；开始流水线时为了检查就先签了每一步的授权 | 低 | 2（流水线角度推翻一条同样的） | 签了就写 `grant.issue` 审计；开始时只检查、不签 |
| 5 | 冻结账号不锁用户行（普通 UPDATE 的锁和派单的 `FOR KEY SHARE` 不冲突），同时派单的能留下一个冻结期间不动、解冻后才跑的运行，等它的负责人或流水线一直等着 | 低（定中被降） | 1 | 冻结先 `SELECT … FOR UPDATE` 锁用户行再读状态，和“全部停止”一样 |
| 6 | 等主人确认的提醒，任务被别的方式结束（提问 30 分钟超时、父运行结束清理子任务、流水线失败取消其它步骤、归档、撤下、全部停止、冻结、关派单开关）时一直是未读，角标不消，点“做”回 409 | 低 | 3 | 所有取消都会经过的 `settle_cancelled_approvals` 一起把这些运行的提醒标已读；流水线取消的步骤补 `run.state` 事件 |
| 7 | 项目看板表没有只按项目的完整索引（都是部分索引），删项目时清理和外键级联都整表扫 | 低 | 1 | 新迁移加 `(project_id, author_user_id)` 索引 |
| 8 | 流水线的步骤不受“每个 botin 最多排 10 个”的限制，每一步拿的是主人剩下的全部预算；开很多条流水线能让主人花到限额的很多倍 | 中 | 1 | 步骤也查排队上限，满了就下一轮再试，不让流水线失败；开始时一个 botin 上的步骤加上已经排着的超过 10 个就拒绝 |
| 9 | 上游的产出物原样复制到下游的工作区，名字叫 `CLAUDE.md`、`AGENTS.md` 的会被 agent 当成自己的说明读进去，绕过“这是别的 botin 写的”边界 | 低（定中被降） | 1 | 项目运行里这类名字改成 `<名字>.upstream.txt`；`artifact_fetch` 拿别的成员的产出物时一样 |
| 10 | 流水线的根运行挂在创建者的专属 botin 上，整条流水线跑的时候查队友、查进度都显示它在忙 | 低 | 1 | 项目里的查队友、查进度不算流水线根运行 |
| 11 | 开始流水线时没写目标，读回来目标是标题 | 低 | 2 | 根运行的提示和标题一样时目标返回空 |
| 12 | 归档了的项目写看板、派任务、开始流水线回 404，client-core 当成“项目没了”把缓存里这个项目的提醒和运行都删了 | 低 | 1 | 这三个写的结果不走 `project_read`，和 8.15 的写一样 |
| 13 | 发布文档里 8.17 退回 8.16 的命令少了必填的 `--operator` | 低 | 1 | 补上 |
| 14 | 看板每人每天 50 条满了以后 429 总说一小时后再试，实际是滚动 24 小时 | 低 | 1 | 和邀请一样按最早一条算还要等多久 |

## 推翻的

- 出口代理的触发器在同一个代数重复问时把代数清空、不报错：只有项目删了、同时又撞上别的事务锁着那一行才会到，最坏是主人自己点“一直
  允许”加到自己的新工作区。
- 关派单开关的 UPDATE 可能被派单的 `FOR SHARE` 一直挤着、60 秒超时：要每秒几百个项目派单持续一分钟，生产环境 8.18 之前不开；超时了
  再跑一次就行。
- 每天清理归档了 30 天的看板条目没有分批：每小时只删这一小时到期的，量很小，和私人看板一样。
- 流水线的步骤开头没有“谁派的”平台说明：方案里定的，交接说明里有流水线和步骤的名字。
- 流水线替别人签授权没审计（流水线角度）：方案的审计只列了创建者的任务。另外两个角度认为该记，按第 4 条修。
- 关着派单开关时，非成员派单回 503 不是 404：对所有人、所有项目 id 都一样，不泄露什么。
- 看板的标签没查自己保险箱里的值：标签是自己特意打的短标签，网关还会转成小写。

## 修复

workflow `fix-8-17-final` 分四批按顺序在同一个工作区修（每批提交、推送），每个修复都先把它改坏、确认测试会失败。

| # | 提交 | 测试（改坏时失败） |
|---|---|---|
| 1 | `80ccc8b`（安卓绑定 `e4ed14a`） | store `budget_and_agent_limits`（别人的 botin 回 `AgentUnavailable`，自己的回 `BudgetReached`）；网关 `project_tasks_over_http` |
| 2 | `5250b6c`，复查后 `936d4e9` | 编排 `a_held_task_looks_queued_to_other_owners`、`a_held_task_looks_queued_to_the_same_owner_too` |
| 3 | `cbc51ab`，复查后 `680d7ea` | store `same_owner_children_keep_the_target_limit`、`creator_children_take_whichever_cap_is_set` |
| 4 | `2557cbc` | 编排 `an_ask_audits_the_grant_it_issues`、`a_delegation_audits_the_grant_it_issues`、`a_pipeline_step_issues_and_audits_its_grant_when_it_starts` |
| 5 | `2fceab4`，复查后 `1a8a066` | 编排 `freezing_waits_for_an_in_flight_dispatch`、`freezing_does_not_deadlock_with_a_run_writer`、`stop_all_does_not_deadlock_with_a_run_writer`；store `stop_all_waits_for_an_in_flight_dispatch` |
| 6 | `09e4777`、`2b7dae3`、`a80c020`、`4677437`，复查后 `936d4e9` | store `held_reminders_are_read_when_*`（清理、主人或项目停下、关掉或删掉 botin、私人那边取消）；编排 `a_stopped_pipeline_settles_its_held_step`、`a_refused_step_stops_the_held_one_beside_it` |
| 7 | `a64bb96`（迁移 0066） | store `project_board_lookups_by_project_use_an_index` |
| 8 | `0a5c1f7`（安卓绑定 `4066ca7`） | store `project_pipeline_steps_wait_for_a_full_queue`；编排 `a_full_queue_defers_a_pipeline_step` |
| 9 | `34fdf3e` | 编排 `autoloaded_names_become_inert`、`project_handoff_renames_instruction_files`、`fetching_another_members_instruction_file_renames_it` |
| 10 | `4d9c2e5`，复查后 `936d4e9` | 编排 `a_pipeline_root_does_not_make_its_anchor_busy`（查队友、查进度、提问、最近做完的） |
| 11 | `a38f90e` | store `project_pipeline_start_rules`；编排 `project_handoff_without_a_goal`、`a_project_pipeline_without_a_goal` |
| 12 | `79cd9f7` | client-core `ffi_writes_to_an_archived_project_keep_the_cache`（项目运行本来就不进缓存，影响的只是提醒和没上传的已读） |
| 13 | `f63d44d` | server `release_doc_dispatch_commands_parse`（文档里的命令按真的命令行解析） |
| 14 | `012afeb` | store `project_board_isolation` |

第 9 条的文件名单：`CLAUDE.md`、`CLAUDE.local.md`、`AGENTS.md`、`AGENTS.override.md`、`AGENT.md`、`GEMINI.md`、`HERMES.md`，
OpenClaw 的 `SOUL.md`、`TOOLS.md`、`IDENTITY.md`、`USER.md`、`HEARTBEAT.md`、`BOOTSTRAP.md`、`MEMORY.md`（不分大小写）。

## 修复的复查

两个角度（完整性和测试强度：逐条改坏；修复带出来的新问题），每条一个反驳者。8 条成立（去重 7 个），都修了：

| 问题 | 级别 | 怎么修 | 提交 | 测试 |
|---|---|---|---|---|
| N1 第 3 条的修法：同一个主人的子运行上限取了目标还剩的，可执行器续租时把树里这个主人用掉的（负责人的）也算进来，负责人先花了比目标限额多的，子运行一开始就超。流水线后面的步骤从 C10 起就有同样的问题（前面同一个主人的步骤用掉的算两遍） | 中 | 子运行、步骤的上限 = 还剩的 + 树里这个主人已经用掉的（`tree_relative_cap`） | `680d7ea` | store `same_owner_children_keep_the_target_limit`（负责人花了 25,000）、`later_pipeline_steps_count_earlier_spend_once` |
| N2 第 5 条的修法：冻结拿 `FOR UPDATE`，和外键检查的 `FOR KEY SHARE` 冲突，锁着运行再写收件箱的事务（执行器收尾）会和它互相等死；“全部停止”从 C6 起就是这样 | 低 | 冻结、“全部停止”拿 `FOR NO KEY UPDATE`，项目里 `lock_users` 拿 `FOR SHARE`（照样互相等，不挡外键） | `1a8a066` | 编排 `freezing_does_not_deadlock_with_a_run_writer`、`stop_all_does_not_deadlock_with_a_run_writer`（改回 `FOR UPDATE` 时报死锁）；`freezing_waits_for_an_in_flight_dispatch`、store `stop_all_waits_for_an_in_flight_dispatch`（改回 `KEY SHARE` 时失败） |
| N3 第 2 条没修全：同一个主人的 agent 照样拿到“暂停了”，它说的话成员都看得到 | 低 | 项目里等确认的回复谁问都和普通的一样 | `936d4e9` | 编排 `a_held_task_looks_queued_to_the_same_owner_too` |
| R1/N4 第 10 条没修全：提问还把流水线的根运行算成忙 | 低 | 提问也用查队友的过滤 | `936d4e9` | 编排 `a_pipeline_root_does_not_make_its_anchor_busy` 加了提问 |
| R2 流水线一步开不了时取消别的步骤的 `run.state` 没测到 | 低 | 补测试 | `936d4e9` | 编排 `a_refused_step_stops_the_held_one_beside_it` |
| R3 同一个主人的子运行一边不限时的两种情况没测到 | 低 | 补测试 | `680d7ea` | store `creator_children_take_whichever_cap_is_set` |
| R4 查进度的“最近做完的”不算根运行没测到 | 低 | 补测试 | `936d4e9` | 编排 `a_pipeline_root_does_not_make_its_anchor_busy` 加了做完以后 |
