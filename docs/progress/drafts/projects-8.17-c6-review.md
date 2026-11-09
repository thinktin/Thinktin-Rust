# 8.17 C6 对抗评审（workflow `review-8-17-c6`，2026-11-09）

评审对象：`ef51dd5`（编排层：项目里的查队友、看板、提问、委派，负责人，启动说明，等主人确认的提醒，迁移 0063）。
三个角度（安全和隐私、正确性和并发、方案对照和测试覆盖）各一个评审，每个角度一个核对的试着推翻。

## 成立的（都是低），都修了

| 问题 | 怎么修的 | 测试 |
|---|---|---|
| “全部停止”和派单不互相等：同时发生时派单能签出一个没被吊销的常设授权，绕过主人确认（安全、正确性两个角度都报了） | `mark_stopped_all` 先 `SELECT … FOR UPDATE` 锁用户行（派单 `FOR KEY SHARE` 锁着目标的主人），在“全部停止”的事务里最先调 | store `stop_all_waits_for_an_in_flight_dispatch`（去掉锁时失败） |
| `mark_stopped_all` 放在最后，和冻结账号的加锁顺序相反，可能互相等死 | 同上：先锁用户行，再取消运行（和冻结一样） | 同上 |
| 主人确认以后，等着的委派子任务被换成完整的常设授权，断了和负责人授权的父子关系（D5b） | 确认时委派来的留着自己的子授权，别的换新的常设授权 | store `confirming_keeps_a_delegate_child_grant`（去掉修复时失败） |
| 不同主人的 botin 同名时按名字找队友会挑第一个 | `find_teammate` 名字对上不止一个就不猜，要 agent 用实例 id | 单元测试 `teammates_with_the_same_name_need_the_instance_id` |
| 等确认的提醒一个 botin 一小时只有一条：同一小时第二个任务没有提醒；拒绝第一个以后第二个没人提醒 | 每个等着的任务一条（去重键按运行），推送按 botin 互相替换；任务不再等确认（确认、拒绝、取消、过期）的提醒算已读 | `a_stopped_owner_is_asked_first` 加了委派、两条提醒、拒绝一条、确认一条 |
| 负责人既委派又提问时，交还结果的说明只说“回答是别的 agent 写的”，没说子任务的结果也是 | 项目里加一种说明：子任务的结果和回答都是别的 agent 写的 | 单元测试 `project_texts` |

## 推翻的

- 回复里说“对方的主人暂停了它”泄露了“全部停止”：成员本来就看得到粗略状态“等主人”，不算泄露。
- 几条只是测试没覆盖（产出物的边界、委派等确认、拒绝的说明一样、失败的推送、撤下以后别的工具）：代码是对的；这几样都补了测试
  （`artifacts_from_other_members_are_fenced`、`a_stopped_owner_is_asked_first`、`refusals_do_not_tell_why_another_owner_cannot_take_work`、
  `project_notices_are_platform_written` 加失败的、撤下以后的循环加了 5 个工具）。

另外：过了 24 小时没确认、由后台取消的任务，提醒也算已读（执行器的清理里）。
