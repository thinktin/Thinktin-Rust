# 实时活动（WBS 10.6）

> iOS 的灵动岛、锁屏上显示运行的进度（App 的界面是 12.10）。App 被挂起后进度照样更新：后台在运行的状态、步数变了时
> 经 APNs 推送更新，运行结束推送 end。计划到点开始的运行，后台在用户的 iPhone 上远程开启（iOS 17.2 起）。
> 推送里只有状态、步数和时间，没有运行的摘要、agent 写的文字：锁屏上谁都看得见。

## 1. 流程

- **App 自己开的**：用户在运行页面上开实时活动（或者 App 发起运行时自动开），拿到 ActivityKit 给的推送令牌
  （`activity.pushTokenUpdates`）后调 `register_live_activity(run_id, token)`。令牌变了再调一次；App 启动、回到前台时
  把每个开着的实时活动（`Activity<RunActivityAttributes>.activities`）现在的令牌再报一次（没变的什么都不做，后台连着
  失败放弃了的从头来）。用户划掉、App 结束了
  调 `end_live_activity(run_id)`。
- **远程开启的**：用户在设置里打开“计划运行时显示实时活动”，App 把推送开启令牌（`Activity<RunActivityAttributes>
  .pushToStartTokenUpdates`）报上来：`set_live_activity_start_token(token)`；关掉时传 nil。计划到点开始的根运行第一次
  被领取时（有步骤的计划是流水线开始时），后台给这个用户登录着、登记了推送开启令牌的每台 iPhone / iPad 发一个开启推送。系统开启实时活动后，App 在
  `Activity<RunActivityAttributes>.activityUpdates` 里拿到它，再把它的推送令牌照上面一样登记。
- 用户自己发起的运行不远程开启（App 自己开，免得一台手机上两个）；子运行、流水线的步骤不单独开，步数算在根运行上。
- 同一个推送开启令牌只属于一台设备。同一台手机换了账号登录（普通推送的令牌跟着手机走到新账号）：之前账号那台设备的
  推送开启令牌清掉，开着的实时活动不再更新（标题是之前账号的实例名，不能出现在现在这个人的锁屏上；App 换账号时在本地
  结束它们）。设备下线、注销账号时也清掉。

## 2. 接口

| 接口 | client-core | 说明 |
|---|---|---|
| `PUT /v1/runs/{id}/live-activity` `{token}` | `register_live_activity` | 登记这台设备上这个运行的实时活动的推送令牌，204。换了令牌（新的实时活动）：现在的状态再发一次（离上次发照样隔 2 秒），8 小时从现在算；同一个令牌再报一次什么都不变（连着失败放弃了的从头来）。只有 iPhone、iPad；一台设备同时最多 10 个；运行结束 10 分钟以上的 422（App 在本地结束它）；别人的运行 404 |
| `DELETE /v1/runs/{id}/live-activity` | `end_live_activity` | 不再推送，204 |
| `PUT /v1/devices/current/live-activity-start` `{token}` | `set_live_activity_start_token(Some)` | 登记推送开启令牌，204；只有 iPhone、iPad |
| `DELETE /v1/devices/current/live-activity-start` | `set_live_activity_start_token(None)` | 清掉 |

令牌是 ActivityKit 给的十六进制串（`Data` 按字节转成十六进制），32 到 512 个字符，不对的返回 422。

## 3. 和 App 的约定

ActivityKit 用默认的 `JSONDecoder` 解推送里的内容，键名要和 Swift 的属性名一模一样（所以这里是驼峰，和接口的下划线不同），
时间用 Unix 秒的整数（默认的 `Date` 解码按 2001 年起的秒数算，对不上，App 里用 `Date(timeIntervalSince1970:)` 转）：

```swift
struct RunActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var state: String      // 运行状态：queued、starting、running、waiting_approval、waiting_device、
                               // waiting_quota、waiting_children（流水线的步骤、子任务在跑）、backoff、
                               // succeeded、failed、cancelled
        var steps: Int         // 已经走了几步（工具调用），连同直接子运行的（流水线的步骤、委派的子任务）
        var startedAt: Int?    // 开始时间，Unix 秒；还没开始时没有
        var endedAt: Int?      // 结束时间，Unix 秒；还没结束时没有
    }
    var runId: String
    var instanceId: String
    var title: String          // 实例名（远程开启时由后台填，命中内容过滤的换成 “ThinkTin”）
}
```

- 类型名必须是 `RunActivityAttributes`（远程开启按它找）。新加字段要是可选的，老版本的 App 才解得开。
- 耗时由 App 用 `startedAt` 自己算（`Text(timerInterval:)`），后台不为了耗时推送。
- Info.plist 要有 `NSSupportsLiveActivities`。步数变得勤的话可以加 `NSSupportsLiveActivitiesFrequentUpdates`（高优先级的
  预算多一些），后台不依赖它。

## 4. 推送

- 主题 `<bundle id>.push-type.liveactivity`，`apns-push-type: liveactivity`，和普通推送同一把 .p8 密钥、同一个
  `[push.apns]` 配置；配了 APNs 就开（后台任务 `live-activities`）。设备的推送令牌登记为 `apns_sandbox`（开发包，10.7）
  的，实时活动也发到沙盒环境（`sandbox_endpoint`）；没有推送令牌的（被清掉了）按生产环境发。
- 载荷 `{"aps": {"timestamp": <秒>, "event": "start" | "update" | "end", "content-state": {...}}}`：
  - **start**（远程开启）：发到推送开启令牌，加 `attributes-type`、`attributes`、`alert`（标题是实例名，正文“计划开始运行了”，
    按用户的语言）和 `input-push-token: 1`（iOS 18 起系统把新实时活动的令牌交给 App）。
  - **update**：运行没结束时。**end**：运行结束了（成功、失败、取消），之后不再发；系统按默认的时间从锁屏上移走。
- 合并和限频：后台每秒看一次哪些实时活动的内容和上次发的不一样，只发现在的样子（中间的变化合成一次）。先轮每个用户
  等得最久的那一个，再轮第二个，一个用户一次最多 5 个：刷令牌的账号再多，每个用户的实时活动每一批都排得上（等了多久
  从上次发、或者换令牌算起，刚换过令牌的排到后面）。状态变了的
  离上次至少 2 秒（同一秒里的两次更新系统会丢掉后一次），优先级 10；只是步数变了的离上次至少 20 秒，优先级 5（苹果对
  优先级 10 的更新有预算）。更新一小时内送不到就算了（`apns-expiration`），反正系统只留最后一条；end 只发一次，等
  8 小时（手机离线久一点也送得到）。
- 多个后台副本：领了的锁 60 秒，每条发之前续锁；前面的发得慢、锁已经过期的不发（别的副本可能领去发了，远程开启发两次
  就是两个实时活动），下一轮再领。领了以后不该发了的（App 关掉了、设备下线了、同一台手机换了账号、远程开启的令牌
  关掉或换了）也不发。
- 远程开启的：一台设备同时开着的最多 2 个；开启后 App 一直没报上令牌、运行就结束了的，了结掉（没法发 end，系统 8 小时
  后自己结束）。
- 结果：推送开启令牌失效（410、`BadDeviceToken`）清掉，这台设备不再远程开启，直到 App 报上新的；实时活动的令牌失效
  （用户划掉了、系统结束了）或者请求被拒，这个实时活动不再发；暂时失败（429、5xx、网络）退避重试（5 秒起翻倍，最多
  10 分钟），连着 13 次（一个小时出头）才不再发；App 再报一次令牌（同一个也行）就从头来。令牌失效、App 关掉了的，同一个令牌再报也不
  重新打开（换了令牌才算新的）。发送期间 App 换了令牌，这一次的结果不记，新令牌接着发。
- 实时活动最多显示 8 小时（苹果的上限），开了更久的不再发；一天前的记录由维护任务删掉。
- 指标：`thinktin_live_activity_total{result=sent|retried|ended|dropped}`。

## 5. 测试

| 测试 | 位置 |
|---|---|
| 登记、换令牌重发、关掉、只有 iPhone、别人的运行、领取的条件（没发过、状态变了、步数隔一阵、重试时间）、锁、远程开启的数量上限、没拿到令牌就结束的了结、开启令牌只属于一台设备、下线清掉 | `crates/store/src/tests.rs`（`live_activities_follow_their_runs_per_device`） |
| 刷令牌占不满整批（每个用户的份额、先轮每个用户的第一个、刚换过令牌的排后面）、同一个令牌不重新打开、放弃了的从头来、早就结束的运行、并发登记和并发远程开启超不过上限 | `crates/store/src/tests.rs`（`live_activities_resist_floods_and_races`） |
| 步数连同子运行、续锁（领了以后关掉远程开启、换了账号的不发）、换令牌后 8 小时重算、同一台手机换账号 | `crates/store/src/tests.rs`（`live_activities_follow_the_phone`） |
| 主题、推送类型、优先级、过期时间（end 等得久）、开启的载荷、令牌失效 | `crates/notify/src/apns.rs`（`live_activities_use_their_own_topic_and_payload`） |
| 跟着运行更新、合并、低优先级的步数更新、end；计划运行远程开启（用户自己发起的不开）、标题过滤；令牌失效、重试和放弃、重新登记；发得慢时锁过期的不发 | `crates/orchestrator/tests/live.rs` |
| 有步骤的计划：根运行远程开启一个，步骤不单独开；第一步就起不来的流水线自己失败，不影响别的 | `crates/orchestrator/tests/pipeline.rs`（`scheduled_pipelines_start_one_live_activity`、`a_pipeline_whose_first_step_cannot_start_fails_alone`） |
| 接口 | `crates/gateway/tests/api.rs`（`live_activities_over_http`） |
| client-core 方法 | `crates/client-core/tests/client.rs`（`ffi_live_activities`） |
