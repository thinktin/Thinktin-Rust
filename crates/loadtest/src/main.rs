//! `thinktin-loadtest`：压测（WBS 17.5）。每个子命令跑一个场景，结果以 JSON 打到标准输出。
//!
//! ```text
//! # 整点触发洪峰（在 DATABASE_URL 所在的服务器上建临时库，测完删掉）
//! thinktin-loadtest trigger-storm --triggers 10000 --replicas 4
//! # 并发唤醒
//! thinktin-loadtest wake-storm --instances 500 --wakes-per-instance 2 --resume-ms 200
//! # 模型网关流式吞吐（进程内假厂商 + 真实网关，附直连基线）
//! thinktin-loadtest llm-stream --concurrency 256 --requests 5000
//! # 压部署好的网关
//! THINKTIN_LOADTEST_TOKEN=tts1... thinktin-loadtest llm-stream --gateway https://llm-gw.staging --model main
//! ```

use std::time::Duration;

use anyhow::Context;
use clap::{Parser, Subcommand};
use loadtest::scratch::ScratchDb;
use loadtest::{llm_stream, trigger_storm, wake_storm};
use serde::Serialize;

#[derive(Parser)]
#[command(
    name = "thinktin-loadtest",
    version,
    about = "ThinkTin 压测：整点触发洪峰、并发唤醒、模型网关流式吞吐"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(clap::Args)]
struct DbArgs {
    /// Postgres 服务器（连到任意一个库即可，账号要能建库）。在上面建临时库，测完删掉
    #[arg(long, env = "DATABASE_URL")]
    database_url: String,
    /// 被测组件共用的连接池大小（生产按副本数和 Postgres 的连接上限分配）
    #[arg(long, default_value_t = 32)]
    pool: u32,
    /// 测完保留临时库（看数据用）
    #[arg(long)]
    keep: bool,
}

#[derive(Subcommand)]
enum Command {
    /// 整点触发洪峰：很多计划同一时刻到点，多个调度器副本同时扫描
    TriggerStorm {
        #[command(flatten)]
        db: DbArgs,
        #[arg(long, default_value_t = 10_000)]
        triggers: usize,
        #[arg(long, default_value_t = 1_000)]
        users: usize,
        #[arg(long, default_value_t = 4)]
        replicas: usize,
        /// 每个事务处理多少个触发器
        #[arg(long, default_value_t = 100)]
        batch: i64,
        /// 削峰抖动上限（秒）
        #[arg(long, default_value_t = 30)]
        jitter_secs: u64,
    },
    /// 并发唤醒：一批暂停的实例同时被唤醒
    WakeStorm {
        #[command(flatten)]
        db: DbArgs,
        #[arg(long, default_value_t = 500)]
        instances: usize,
        #[arg(long, default_value_t = 100)]
        users: usize,
        /// 每个实例同时被唤醒几次
        #[arg(long, default_value_t = 2)]
        wakes_per_instance: usize,
        #[arg(long, default_value_t = 256)]
        concurrency: usize,
        /// 模拟的建沙箱耗时（毫秒）
        #[arg(long, default_value_t = 500)]
        create_ms: u64,
        /// 模拟的恢复耗时（毫秒）
        #[arg(long, default_value_t = 200)]
        resume_ms: u64,
        /// 模拟的暂停耗时（毫秒）
        #[arg(long, default_value_t = 100)]
        pause_ms: u64,
    },
    /// 模型网关流式吞吐
    LlmStream {
        #[arg(long, default_value_t = 256)]
        concurrency: usize,
        #[arg(long, default_value_t = 5_000)]
        requests: usize,
        /// 每个响应多少块正文（进程内假厂商）
        #[arg(long, default_value_t = 200)]
        chunks: usize,
        /// 每块正文多少字节
        #[arg(long, default_value_t = 64)]
        chunk_bytes: usize,
        /// 块之间停多久（毫秒），模拟模型出字的速度
        #[arg(long, default_value_t = 5)]
        chunk_delay_ms: u64,
        /// 不跑直连假厂商的基线
        #[arg(long)]
        no_baseline: bool,
        /// 压部署好的网关：基地址，比如 https://llm-gw.staging.example。不给就在进程内起假厂商和网关
        #[arg(long, requires = "model")]
        gateway: Option<String>,
        /// 部署好的网关上的沙箱令牌（从环境变量读，不走命令行参数）
        #[arg(long, env = "THINKTIN_LOADTEST_TOKEN", hide_env_values = true)]
        token: Option<String>,
        /// 部署好的网关上的模型别名
        #[arg(long, requires = "gateway")]
        model: Option<String>,
    },
}

fn print<T: Serialize>(report: &T) -> anyhow::Result<()> {
    println!("{}", serde_json::to_string_pretty(report)?);
    Ok(())
}

async fn with_scratch<T, F, Fut>(db: &DbArgs, f: F) -> anyhow::Result<T>
where
    F: FnOnce(ScratchDb) -> Fut,
    Fut: std::future::Future<Output = (ScratchDb, anyhow::Result<T>)>,
{
    let scratch = ScratchDb::create(&db.database_url, db.pool).await?;
    eprintln!("scratch database: {}", scratch.name);
    let (scratch, result) = f(scratch).await;
    if db.keep {
        eprintln!("kept scratch database {}", scratch.name);
    } else {
        scratch
            .drop_db()
            .await
            .context("drop the scratch database")?;
    }
    result
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    match Cli::parse().command {
        Command::TriggerStorm {
            db,
            triggers,
            users,
            replicas,
            batch,
            jitter_secs,
        } => {
            let cfg = trigger_storm::Config {
                triggers,
                users,
                replicas,
                batch,
                max_jitter: Duration::from_secs(jitter_secs),
                ..trigger_storm::Config::default()
            };
            let report = with_scratch(&db, |s| async move {
                let r = trigger_storm::run(&s.db, &cfg).await;
                (s, r)
            })
            .await?;
            print(&report)
        }
        Command::WakeStorm {
            db,
            instances,
            users,
            wakes_per_instance,
            concurrency,
            create_ms,
            resume_ms,
            pause_ms,
        } => {
            let cfg = wake_storm::Config {
                instances,
                users,
                wakes_per_instance,
                concurrency,
                create_latency: Duration::from_millis(create_ms),
                resume_latency: Duration::from_millis(resume_ms),
                pause_latency: Duration::from_millis(pause_ms),
                ..wake_storm::Config::default()
            };
            let pool = db.pool;
            let report = with_scratch(&db, |s| async move {
                let r = wake_storm::run(&s.db, pool, &cfg).await;
                (s, r)
            })
            .await?;
            print(&report)
        }
        Command::LlmStream {
            concurrency,
            requests,
            chunks,
            chunk_bytes,
            chunk_delay_ms,
            no_baseline,
            gateway,
            token,
            model,
        } => {
            let cfg = llm_stream::Config {
                concurrency,
                requests,
                chunks,
                chunk_bytes,
                chunk_delay: Duration::from_millis(chunk_delay_ms),
                baseline: !no_baseline,
            };
            let target = match gateway {
                Some(base) => llm_stream::Target::External {
                    base,
                    token: token.context(
                        "set THINKTIN_LOADTEST_TOKEN to a sandbox token for the gateway",
                    )?,
                    model: model.context("--model is required with --gateway")?,
                },
                None => llm_stream::Target::InProcess,
            };
            print(&llm_stream::run(&target, &cfg).await?)
        }
    }
}
