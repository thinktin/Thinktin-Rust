# 压测（WBS 17.5）

`crates/loadtest` 出一个命令 `thinktin-loadtest`，三个场景各是一个子命令，结果以 JSON 打到标准输出。被测组件和负载在同一个进程里跑：调度器、实例生命周期、模型网关都是真实代码，只有沙箱后端和厂商是模拟的。CI 里按小规模跑通并检查核对项（`crates/loadtest/tests/small.rs`），正式的数字等 2.4 部署后在预发环境上跑。

要数据库的两个场景在 `DATABASE_URL` 所在的服务器上新建一个临时库（`thinktin_loadtest_…`），跑迁移、造数据，测完删掉（`--keep` 保留）；连接账号要能建库。`--pool` 是被测组件共用的连接池大小，按生产里每个副本分到的连接数填。

## 整点触发洪峰

```sh
cargo run --release -p loadtest -- trigger-storm --triggers 10000 --users 1000 --replicas 4 --batch 100 --pool 32
```

`triggers` 个计划在同一个整点到点，`replicas` 个调度器副本同时扫描一次。看：

- `fire_ms`、`triggers_per_sec`：全部生成运行用了多久。
- 核对项：`runs` = `distinct_plans` = `triggers`，`duplicates`、`leftover` 为 0（多副本靠 SKIP LOCKED 分头处理，唯一约束兜底）。
- `jitter_min_ms`、`jitter_max_ms`、`start_peak_per_sec`：削峰抖动之后运行最早开始时间的分布，最忙的那一秒有多少个运行可以开始，就是执行器要扛住的峰值。

## 并发唤醒

```sh
cargo run --release -p loadtest -- wake-storm --instances 500 --wakes-per-instance 2 --concurrency 256 --resume-ms 200 --pool 32
```

先领养 `instances` 个实例、建沙箱、暂停，再把每个实例同时唤醒 `wakes_per_instance` 次。沙箱后端是本地后端加固定延迟（`--create-ms`、`--resume-ms`、`--pause-ms`），用 Cube 联调（2.3）实测的耗时填。看：

- `latency`（分位数）、`wakes_per_sec`。
- 核对项：`errors` 为 0，`resumes` = 实例数（同一个实例的重复唤醒排在行锁后面，看到已经在跑就直接返回），`sandbox_changed` 为 0，`running` = 实例数。
- `pool_bound_per_sec` = 连接池大小 / 恢复耗时：`ensure_running` 调沙箱后端期间一直占着一个连接和实例行锁，单副本的唤醒吞吐不会超过这个数。实测接近它时说明瓶颈在连接池，要么加副本、加连接，要么把沙箱调用挪到事务外面（先标“唤醒中”再提交）。

## 模型网关流式吞吐

```sh
cargo run --release -p loadtest -- llm-stream --concurrency 256 --requests 5000 --chunks 200 --chunk-bytes 64 --chunk-delay-ms 5
```

进程内起一个假厂商（每个响应 `chunks` 块正文、块间停 `chunk_delay_ms`）和真实的网关（验沙箱令牌、限流、换 key、改模型名、透传、计量），每个并发连接用自己的实例和令牌，限流放到测不到的高度。默认再直连假厂商跑一遍基线（`--no-baseline` 关掉）。看：

- `gateway.ttfb`、`gateway.total`、`requests_per_sec`、`mib_per_sec`；`overhead_ttfb_p50_ms` 是网关比直连多出来的首字节延迟中位数。
- 核对项：`failed`、`mismatched` 为 0（逐字节透传），`usage_complete` = 成功数（每个请求一条完整用量）。

压部署好的网关：沙箱令牌从环境变量读，不核对内容，只统计。

```sh
THINKTIN_LOADTEST_TOKEN=tts1.… cargo run --release -p loadtest -- llm-stream --gateway https://llm-gw.staging.example --model main --concurrency 64 --requests 1000
```

## 还没覆盖的

- 执行器领取运行、起 agent 的吞吐：要真实沙箱，随 2.3 / 2.4 在预发环境测。
- 接入网关的事件流扇出（很多 App 同时连 WebSocket）：等预发环境，用 client-core 起连接。
- 模型网关接数据库时的路由缓存和用量批量写：进程内模式用的是内存目录和只计数的用量记录，测的是网关本身；接库的部分在预发环境用 `--gateway` 压。
