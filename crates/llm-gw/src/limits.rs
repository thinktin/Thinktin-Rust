//! 限额与熔断（架构方案 5.6，WBS 9.5）。
//!
//! - 按实例：令牌桶限速、并发上限；被限速后还在猛打（比如 agent 死循环），就熔断一段时间；
//! - 按 key：每天的 token 预算。预算在请求前检查、响应后记账，所以并发请求可能略微超出。

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use crate::store::Limits;

/// 熔断时长。
const BREAKER_COOLDOWN: Duration = Duration::from_secs(300);
/// 超过这么久没请求的实例状态会被清理。
const IDLE_EVICT: Duration = Duration::from_secs(600);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rejection {
    /// 速率超限，多少秒后重试。
    RateLimited { retry_after: u64 },
    /// 并发超限。
    TooManyConcurrent,
    /// 已熔断。
    CircuitOpen { retry_after: u64 },
}

struct Bucket {
    tokens: f64,
    last: Instant,
    /// 最近一分钟内被拒绝的次数及窗口起点。
    rejected: u32,
    rejected_since: Instant,
    open_until: Option<Instant>,
    inflight: Arc<Semaphore>,
    max_concurrent: u32,
}

#[derive(Default)]
pub struct Limiter {
    buckets: Mutex<HashMap<String, Bucket>>,
}

impl Limiter {
    /// 进入一个请求。成功时返回的许可要一直持有到响应结束。
    pub fn acquire(
        &self,
        instance: &str,
        limits: Limits,
    ) -> Result<OwnedSemaphorePermit, Rejection> {
        self.acquire_at(instance, limits, Instant::now())
    }

    fn acquire_at(
        &self,
        instance: &str,
        limits: Limits,
        now: Instant,
    ) -> Result<OwnedSemaphorePermit, Rejection> {
        let rpm = f64::from(limits.requests_per_minute.max(1));
        let max_concurrent = limits.max_concurrent.max(1);
        let mut buckets = self.buckets.lock().unwrap_or_else(|e| e.into_inner());
        if buckets.len() > 10_000 {
            buckets.retain(|_, b| {
                now.duration_since(b.last) < IDLE_EVICT
                    || b.inflight.available_permits() < b.max_concurrent as usize
            });
        }
        let bucket = buckets
            .entry(instance.to_owned())
            .or_insert_with(|| Bucket {
                tokens: rpm,
                last: now,
                rejected: 0,
                rejected_since: now,
                open_until: None,
                inflight: Arc::new(Semaphore::new(max_concurrent as usize)),
                max_concurrent,
            });
        if bucket.max_concurrent != max_concurrent {
            // 上限改了：换一个新信号量，进行中的请求继续持有旧的许可。
            bucket.inflight = Arc::new(Semaphore::new(max_concurrent as usize));
            bucket.max_concurrent = max_concurrent;
        }

        if let Some(until) = bucket.open_until {
            if now < until {
                return Err(Rejection::CircuitOpen {
                    retry_after: until.duration_since(now).as_secs().max(1),
                });
            }
            bucket.open_until = None;
            bucket.rejected = 0;
            bucket.tokens = rpm;
        }

        let elapsed = now.duration_since(bucket.last).as_secs_f64();
        bucket.tokens = (bucket.tokens + elapsed * rpm / 60.0).min(rpm);
        bucket.last = now;
        if bucket.tokens < 1.0 {
            if now.duration_since(bucket.rejected_since) > Duration::from_secs(60) {
                bucket.rejected = 0;
                bucket.rejected_since = now;
            }
            bucket.rejected += 1;
            // 一分钟内被拒的次数达到每分钟配额：客户端无视 429 在猛打，熔断。
            if bucket.rejected >= limits.requests_per_minute.max(1) {
                bucket.open_until = Some(now + BREAKER_COOLDOWN);
                tracing::warn!(target: "llm_gw::breaker", instance, "circuit opened: request rate stays above limit");
                return Err(Rejection::CircuitOpen {
                    retry_after: BREAKER_COOLDOWN.as_secs(),
                });
            }
            let wait = ((1.0 - bucket.tokens) * 60.0 / rpm).ceil() as u64;
            return Err(Rejection::RateLimited {
                retry_after: wait.max(1),
            });
        }
        let permit = bucket
            .inflight
            .clone()
            .try_acquire_owned()
            .map_err(|_| Rejection::TooManyConcurrent)?;
        bucket.tokens -= 1.0;
        Ok(permit)
    }
}

/// 每把 key 每天已用的 token 数。多副本时以用量表为准（见 `pg::PgLedger`）。
#[async_trait::async_trait]
pub trait BudgetLedger: Send + Sync {
    async fn used(&self, credential: &str, day: u64) -> u64;
    /// 响应结束时记账（在 Drop 里调用，不能等待）。
    fn add(&self, credential: &str, day: u64, tokens: u64);
}

#[derive(Default)]
pub struct MemoryLedger(Mutex<HashMap<(String, u64), u64>>);

#[async_trait::async_trait]
impl BudgetLedger for MemoryLedger {
    async fn used(&self, credential: &str, day: u64) -> u64 {
        let map = self.0.lock().unwrap_or_else(|e| e.into_inner());
        map.get(&(credential.to_owned(), day)).copied().unwrap_or(0)
    }

    fn add(&self, credential: &str, day: u64, tokens: u64) {
        let mut map = self.0.lock().unwrap_or_else(|e| e.into_inner());
        map.retain(|(_, d), _| *d + 1 >= day);
        let entry = map.entry((credential.to_owned(), day)).or_default();
        *entry = entry.saturating_add(tokens);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn limits(rpm: u32, conc: u32) -> Limits {
        Limits {
            requests_per_minute: rpm,
            max_concurrent: conc,
        }
    }

    #[test]
    fn token_bucket_refills() {
        let l = Limiter::default();
        let t0 = Instant::now();
        let lim = limits(60, 100);
        let mut permits = Vec::new();
        for _ in 0..60 {
            permits.push(l.acquire_at("i", lim, t0).unwrap());
        }
        assert_eq!(
            l.acquire_at("i", lim, t0).unwrap_err(),
            Rejection::RateLimited { retry_after: 1 }
        );
        // 每秒补 1 个。
        assert!(
            l.acquire_at("i", lim, t0 + Duration::from_millis(1100))
                .is_ok()
        );
        // 别的实例不受影响。
        assert!(l.acquire_at("j", lim, t0).is_ok());
    }

    #[test]
    fn concurrency_is_bounded_and_released() {
        let l = Limiter::default();
        let t0 = Instant::now();
        let lim = limits(100, 2);
        let a = l.acquire_at("i", lim, t0).unwrap();
        let _b = l.acquire_at("i", lim, t0).unwrap();
        assert_eq!(
            l.acquire_at("i", lim, t0).unwrap_err(),
            Rejection::TooManyConcurrent
        );
        drop(a);
        assert!(l.acquire_at("i", lim, t0).is_ok());
    }

    #[test]
    fn hammering_opens_the_circuit() {
        let l = Limiter::default();
        let t0 = Instant::now();
        let lim = limits(5, 100);
        let mut permits = Vec::new();
        for _ in 0..5 {
            permits.push(l.acquire_at("i", lim, t0).unwrap());
        }
        for _ in 0..4 {
            assert!(matches!(
                l.acquire_at("i", lim, t0),
                Err(Rejection::RateLimited { .. })
            ));
        }
        assert_eq!(
            l.acquire_at("i", lim, t0).unwrap_err(),
            Rejection::CircuitOpen { retry_after: 300 }
        );
        // 熔断期间，令牌桶补满了也不放行。
        let later = t0 + Duration::from_secs(120);
        assert!(matches!(
            l.acquire_at("i", lim, later),
            Err(Rejection::CircuitOpen { retry_after: 180 })
        ));
        assert!(l.acquire_at("i", lim, t0 + BREAKER_COOLDOWN).is_ok());
    }

    #[tokio::test]
    async fn ledger_tracks_days() {
        let l = MemoryLedger::default();
        l.add("c", 10, 100);
        l.add("c", 10, 50);
        assert_eq!(l.used("c", 10).await, 150);
        assert_eq!(l.used("c", 11).await, 0);
        l.add("c", 12, 1);
        assert_eq!(l.used("c", 10).await, 0, "old days are dropped");
    }
}
