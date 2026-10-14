# AI 生成内容标识与内容安全（WBS 16.3）

依据《人工智能生成合成内容标识办法》（国家网信办等四部门，2025 年 9 月 1 日施行）和配套的强制性国家标准 GB 45438-2025。

## 1. 显式标识（用户看得见的）

| 场景 | 做法 | 位置 |
|---|---|---|
| App 里的对话流 | 事件里 `agent.message`、`agent.thought`、`agent.plan` 是 agent 生成的，client-core 的 `InstanceEvent.ai_generated` 为真，界面在旁边显示“AI 生成” | `proto::labels::is_ai_generated_event`、`crates/client-core/src/ffi.rs` |
| 收件箱 | 正文是 agent 写的（运行摘要、工具调用标题、agent 起的计划名）时 `ai_generated` 为真，界面显示标识 | `inbox_items.ai_generated`、`orchestrator::outbox::Notice` |
| 系统通知（APNs、厂商通道） | 通知栏由系统绘制，正文前加“【AI 生成】” | `notify::PushMessage::display_body` |
| 下载产出物 | 纯文本、Markdown 末尾追加一行“——本内容由人工智能生成（服务提供者）”；其他类型见待决问题 | `crates/gateway/src/routes/artifacts.rs` |
| 复制、导出 | 客户端在复制 agent 输出时带上标识（App 端实现，WBS 12.x / 13.x） | — |

## 2. 隐式标识（文件元数据）

下载产出物时响应头 `x-aigc` 带制作要素：`{"Label":"1","ContentProducer":"<服务提供者>","ProduceID":"<产出物 id>"}`。服务提供者名称或编码在 `[compliance] content_producer` 配置。

字段名按 GB 45438-2025 附录 E 的公开解读，**上线前要拿标准原文核对**；按标准把元数据写进文件本身（各文件格式的写法见 TC260 的实践指南）也要在上线前补上。

## 3. 内容安全

- 推送的标题和正文经第三方厂商通道发到通知栏，发之前过内容过滤（`notify::filter::ContentFilter`）。命中的不丢通知，正文换成“有新的结果，打开 App 查看”，原文留在只有本人可见的收件箱里。
- 现在是本地关键词表（`[compliance] push_keywords_file`，一行一个）；接第三方内容安全服务时再实现一个 `ContentFilter`。

## 4. 日志留存

- 平台始终给 AI 生成内容加标识，不提供去掉显式标识的选项，所以不触发办法第九条（应用户要求提供无显式标识内容时，留存提供对象等日志不少于六个月）。
- 网络安全法要求的网络日志（不少于六个月）：审计日志（`audit_log`）和用量记录（`usage_records`）不自动清理；对话事件只保留 30 天（隐私最小化），不属于网络日志。
