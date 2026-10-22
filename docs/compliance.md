# AI 生成内容标识与内容安全（WBS 16.3）

依据《人工智能生成合成内容标识办法》（国家网信办等四部门，2025 年 9 月 1 日施行）和配套的强制性国家标准 GB 45438-2025。

## 1. 显式标识（用户看得见的）

| 场景 | 做法 | 位置 |
|---|---|---|
| App 里的对话流 | 事件里 `agent.message`、`agent.thought`、`agent.plan` 是 agent 生成的，client-core 的 `InstanceEvent.ai_generated` 为真，界面在旁边显示“AI 生成” | `proto::labels::is_ai_generated_event`、`crates/client-core/src/ffi.rs` |
| 收件箱 | 正文是 agent 写的（运行摘要、工具调用标题、agent 起的计划名）时 `ai_generated` 为真，界面显示标识 | `inbox_items.ai_generated`、`orchestrator::outbox::Notice` |
| 系统通知（APNs、厂商通道） | 通知栏由系统绘制，正文前加“【AI 生成】” | `notify::PushMessage::display_body` |
| 下载产出物 | 纯文本、Markdown 末尾追加一行“——本内容由人工智能生成（服务提供者）”（`[compliance] label_downloads` 可关）；其他类型不加显式标识，只有隐式标识（2026-10-14 决定） | `crates/gateway/src/routes/artifacts.rs` |
| 复制、导出 | 客户端在复制 agent 输出时带上标识（App 端实现，WBS 12.x / 13.x） | — |

## 2. 隐式标识（文件元数据）

下载产出物时响应头 `x-aigc` 带制作要素：`{"Label":"1","ContentProducer":"<服务提供者>","ProduceID":"<产出物 id>"}`。服务提供者名称或编码在 `[compliance] content_producer` 配置。

字段名按 GB 45438-2025 附录 E 的公开解读，**上线前要拿标准原文核对**；按标准把元数据写进文件本身（各文件格式的写法见 TC260 的实践指南）也要在上线前补上。

## 3. 内容安全

- 推送的标题和正文经第三方厂商通道发到通知栏，发到用户绑定的 IM 群（10.5，[IM 渠道](im-channels.md)）也一样，发之前过内容过滤（`notify::filter::ContentFilter`）。命中的不丢通知，正文换成“有新的结果，打开 App 查看”，原文留在只有本人可见的收件箱里。
- 现在是本地关键词表（`[compliance] push_keywords_file`，一行一个）；接第三方内容安全服务时再实现一个 `ContentFilter`。

### 3.1 投诉举报（WBS 5.5）

应用审核（聊天类 App 要有举报不当内容的入口）和生成式人工智能服务管理暂行办法（建立投诉举报机制、及时受理处理并反馈
结果）都要求用户能举报 agent 生成的内容。

- **提交**：App 长按 agent 的回复或产出物，选原因（`harmful`、`illegal`、`sexual`、`hateful`、`privacy`、
  `misinformation`、`infringement`、`other`），可以写一段说明（最多 1000 字）：`POST /v1/reports`
  `{run_id, event_seq?, artifact_id?, reason, note?}`，client-core 的 `report_content`。只能举报自己的运行；同一条
  内容再举报一次返回那一条待处理的举报（200），新的返回 201；每人每小时最多 30 条（`[api.limits] reports_per_hour`）。
  `GET /v1/reports`（`reports()`）看自己的举报和处理结果。
- **复制内容**：提交时把被举报的那一条复制下来：运行的提问和摘要（各最多 4000 字）、那条事件（超过 64 KB 的只留截断后
  的文字）、产出物的名字、类型、大小和 SHA-256（产出物本身不复制）。用户删了运行、事件过了 30 天保留期，运营照样看得
  到；只复制被举报的这一条，接口不回显。
- **处理**：运营在后台副本上用 `thinktin-server admin reports` 看待处理的队列（先来的在前，显示等了多久），
  `admin report <id>` 看详情（举报的人的手机号打码、原因、说明、复制下来的内容；这是运维命令里唯一输出对话内容的，用户
  提交举报就是让运营看它），处理完 `admin close-report <id> --resolution "…" --operator 名字`：结果记在举报上，原样发到
  举报的人的收件箱和推送（不要写别人的信息），处理人只进审计。
- **时效**：后台每小时报 `thinktin_content_reports_open`（待处理几条）和 `thinktin_content_report_oldest_seconds`
  （最早一条等了多久），超过约定的时限（建议 24 小时）告警。每条新举报还打一条 warn 日志。
- **审计**：`content.reported`（举报 id、原因、运行、事件、产出物）、`content.report_closed`（处理人、原因）。
- **注销**：举报和复制下来的内容随账号一起删掉（第 5 节）。

## 4. 日志留存

- 平台始终给 AI 生成内容加标识，不提供去掉显式标识的选项，所以不触发办法第九条（应用户要求提供无显式标识内容时，留存提供对象等日志不少于六个月）。
- 网络安全法要求的网络日志（不少于六个月）：审计日志（`audit_log`）和用量记录（`usage_records`）不自动清理；对话事件只保留 30 天（隐私最小化），不属于网络日志。

## 5. 注销（WBS 16.4 的技术部分）

注销要用发到本人手机的专用验证码确认，确认后在一个事务里（`store::Tx::erase_account`）：

- 先锁住用户行，等正在给这个用户写数据的事务（调度器建运行、API 请求）提交，之后的删除不会漏掉它们的行；
- 销毁用户的 DEK：key 密文、产出物内容从此无法解密；key 密文本身也清空。删掉的产出物由触发器把密文的键排进 `blob_purge`，后台维护任务从对象存储删掉（单个删除、删运行级联同样走这个队列）；
- 删除用户的内容：运行（提示词、摘要、错误）、事件、审批、产出物索引、计划（含触发器、流水线步骤）、收件箱、推送记录（含已送达的：载荷里有通知正文）、团队、团队模板、IM 群机器人的凭证、内容举报（里面复制了被举报的内容）；
- 去标识化：手机号改成 `deleted`（同一手机号可以重新注册成新账号）、昵称、设备名和推送令牌清空、实例名清空；
- 吊销全部会话和运行授权；实例标记删除，沙箱和工作区卷由巡检回收；
- 保留：审计日志和用量记录（只有 id、计数和时间，按网络日志的要求保留）。

测试：`crates/store/src/tests.rs` 的 `erasing_an_account_deletes_its_content`（逐表检查注销用户的行全部删除、另一个用户不受影响）。

平时的保留期：送达（或放弃）的推送记录 7 天后删除（同样的内容在收件箱里，用户自己能看、能删）；事件 30 天。
