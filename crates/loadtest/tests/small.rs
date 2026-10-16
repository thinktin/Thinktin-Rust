//! 三个压测场景按小规模跑通，并检查它们的核对项（不看速度，速度的数字在预发环境上跑）。
//! 要数据库的两个场景需要 DATABASE_URL，没有时跳过（THINKTIN_REQUIRE_DB=1 时失败）。

use std::time::Duration;

use loadtest::scratch::ScratchDb;
use loadtest::{llm_stream, trigger_storm, wake_storm};

const POOL: u32 = 16;

async fn scratch() -> Option<ScratchDb> {
    let Ok(url) = std::env::var("DATABASE_URL") else {
        if std::env::var("THINKTIN_REQUIRE_DB").is_ok_and(|v| v == "1") {
            panic!("DATABASE_URL is not set (THINKTIN_REQUIRE_DB=1)");
        }
        eprintln!("skipping: DATABASE_URL is not set (see tools/dev/setup-db.sh)");
        return None;
    };
    Some(ScratchDb::create(&url, POOL).await.unwrap())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn trigger_storm_fires_each_trigger_once() {
    let Some(s) = scratch().await else { return };
    let cfg = trigger_storm::Config {
        triggers: 300,
        users: 20,
        replicas: 3,
        batch: 40,
        max_jitter: Duration::from_secs(30),
        seed_concurrency: 8,
    };
    let r = trigger_storm::run(&s.db, &cfg).await.unwrap();
    eprintln!("{}", serde_json::to_string_pretty(&r).unwrap());
    assert_eq!(r.runs, 300, "one run per trigger");
    assert_eq!(r.distinct_plans, 300);
    assert_eq!(
        r.per_replica.iter().map(|p| p.runs_created).sum::<usize>(),
        300
    );
    assert_eq!(r.per_replica.iter().map(|p| p.triggers).sum::<usize>(), 300);
    assert_eq!((r.duplicates, r.coalesced, r.leftover), (0, 0, 0));
    assert!(
        r.jitter_min_ms >= 0.0 && r.jitter_max_ms < 30_000.0,
        "{r:?}"
    );
    // 300 个摊到 30 秒里：最忙的一秒远少于全部。
    assert!(r.start_peak_per_sec < 100, "{r:?}");
    s.drop_db().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wake_storm_resumes_each_instance_once() {
    let Some(s) = scratch().await else { return };
    let cfg = wake_storm::Config {
        instances: 40,
        users: 8,
        wakes_per_instance: 3,
        concurrency: 32,
        create_latency: Duration::from_millis(5),
        resume_latency: Duration::from_millis(20),
        pause_latency: Duration::from_millis(5),
        setup_concurrency: 8,
    };
    let r = wake_storm::run(&s.db, POOL, &cfg).await.unwrap();
    eprintln!("{}", serde_json::to_string_pretty(&r).unwrap());
    assert_eq!((r.instances, r.wakes), (40, 120));
    assert_eq!(r.errors, 0, "{:?}", r.first_error);
    assert_eq!(
        r.resumes, 40,
        "concurrent wakes of one instance resume it once"
    );
    assert_eq!(r.sandbox_changed, 0);
    assert_eq!(r.running, 40);
    assert_eq!(r.latency.count, 120);
    assert!(r.latency.p50_ms >= 0.0);
    s.drop_db().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn llm_stream_passes_through_and_meters_every_request() {
    let cfg = llm_stream::Config {
        concurrency: 8,
        requests: 64,
        chunks: 20,
        chunk_bytes: 48,
        chunk_delay: Duration::from_millis(1),
        baseline: true,
    };
    let r = llm_stream::run(&llm_stream::Target::InProcess, &cfg)
        .await
        .unwrap();
    eprintln!("{}", serde_json::to_string_pretty(&r).unwrap());
    let g = &r.gateway;
    assert_eq!((g.ok, g.failed), (64, 0), "{:?}", g.first_error);
    assert_eq!(g.mismatched, 0, "stream must pass through byte for byte");
    assert_eq!(g.bytes, 64 * r.response_bytes as u64);
    assert_eq!(r.usage_complete, Some(64));
    assert_eq!(r.usage_other, Some(0));
    assert!(g.ttfb.p50_ms <= g.total.p50_ms);
    let b = r.baseline.as_ref().unwrap();
    assert_eq!((b.ok, b.failed, b.mismatched), (64, 0, 0));
    assert!(r.overhead_ttfb_p50_ms.is_some());
}
