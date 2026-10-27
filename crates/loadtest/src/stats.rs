//! 延迟分布的汇总。

use std::time::Duration;

use serde::Serialize;

/// 一组延迟的分位数，单位毫秒。
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Summary {
    pub count: usize,
    pub min_ms: f64,
    pub mean_ms: f64,
    pub p50_ms: f64,
    pub p90_ms: f64,
    pub p99_ms: f64,
    pub max_ms: f64,
}

impl Summary {
    pub fn of(samples: &[Duration]) -> Self {
        if samples.is_empty() {
            return Self::default();
        }
        let mut ms: Vec<f64> = samples.iter().map(|d| d.as_secs_f64() * 1000.0).collect();
        ms.sort_by(f64::total_cmp);
        let n = ms.len();
        // 最近秩法：第 ceil(q·n) 个（从 1 数）。
        let pick = |q: f64| {
            let rank = (q * n as f64).ceil() as usize;
            ms[rank.clamp(1, n) - 1]
        };
        Self {
            count: n,
            min_ms: ms[0],
            mean_ms: ms.iter().sum::<f64>() / n as f64,
            p50_ms: pick(0.50),
            p90_ms: pick(0.90),
            p99_ms: pick(0.99),
            max_ms: ms[n - 1],
        }
    }
}

/// 每秒多少个。耗时为零时按 1 毫秒算，避免除以零。
pub fn rate(n: usize, elapsed: Duration) -> f64 {
    n as f64 / elapsed.as_secs_f64().max(0.001)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nearest_rank_percentiles() {
        let samples: Vec<Duration> = (1..=100).map(Duration::from_millis).collect();
        let s = Summary::of(&samples);
        assert_eq!(s.count, 100);
        assert_eq!((s.min_ms, s.max_ms), (1.0, 100.0));
        assert_eq!((s.p50_ms, s.p90_ms, s.p99_ms), (50.0, 90.0, 99.0));
        assert!((s.mean_ms - 50.5).abs() < 1e-9);

        let one = Summary::of(&[Duration::from_millis(7)]);
        assert_eq!((one.p50_ms, one.p99_ms), (7.0, 7.0));
        assert_eq!(Summary::of(&[]), Summary::default());
    }

    #[test]
    fn rate_never_divides_by_zero() {
        assert_eq!(rate(10, Duration::from_secs(2)), 5.0);
        assert!(rate(1, Duration::ZERO).is_finite());
    }
}
