//! 限流与防刷（WBS 5.4）：按设备、按用户、按来源地址的令牌桶，注册风控，事件流并发数。
//!
//! 计数在每个副本的内存里（多副本时实际上限是副本数倍）：挡单个客户端的滥用够用，
//! 要全站精确计数时再换成 Redis。手机号自己的发码限制（间隔、每天次数、尝试次数）在 `auth` 里。
//!
//! 国内移动网络大量用运营商级 NAT，很多人共用一个出口地址，所以按地址的上限给得宽，
//! 只防脚本；IPv6 按 /64 计（一台设备通常能拿到整个 /64）。

use std::collections::HashMap;
use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::extract::{ConnectInfo, FromRequestParts};
use axum::http::request::Parts;
use proto::domain::{DeviceId, UserId};
use serde::Deserialize;

use crate::AppState;

const MINUTE: Duration = Duration::from_secs(60);
const HOUR: Duration = Duration::from_secs(3600);
const DAY: Duration = Duration::from_secs(24 * 3600);

/// 各项上限，0 表示不限。
#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct LimitConfig {
    /// 已登录的请求：每台设备每分钟。
    pub device_per_minute: u32,
    /// 已登录的请求：每个用户（所有设备合计）每分钟。
    pub user_per_minute: u32,
    /// 未登录的接口（发验证码、登录、刷新令牌）：每个来源地址每分钟。
    pub anonymous_per_minute: u32,
    /// 发验证码：每个来源地址每小时。
    pub codes_per_ip_per_hour: u32,
    /// 新注册：每个来源地址每天。
    pub signups_per_ip_per_day: u32,
    /// 新注册：全站每小时（被批量注册时熔断）。
    pub signups_per_hour: u32,
    /// 每个用户同时打开的事件流。
    pub streams_per_user: u32,
    /// IM 渠道的测试消息（10.5）：每个用户每小时。
    pub im_tests_per_hour: u32,
    /// 内容举报（5.5）：每个用户每小时。
    pub reports_per_hour: u32,
    /// 计划的 webhook（7.1）：每个 webhook 每分钟（库里还有每小时的准确计数，这里先挡住洪水）。
    pub hook_events_per_minute: u32,
    /// 每个账号最多几个没删除的实例（归档的也算，11.9）；到了上限领养报 409 `instance_limit`。0 不限。
    pub instances_per_user: u32,
    /// 来源地址取 `X-Forwarded-For` 的最后一项（网关前面有自己的负载均衡时才开）。
    pub trust_forwarded_for: bool,
    /// 最多记多少个计数器；满了先清掉闲置的，还满就不再给新的来源计数（放行）。
    pub max_keys: usize,
}

impl Default for LimitConfig {
    fn default() -> Self {
        Self {
            device_per_minute: 600,
            user_per_minute: 1200,
            anonymous_per_minute: 120,
            codes_per_ip_per_hour: 60,
            signups_per_ip_per_day: 50,
            signups_per_hour: 5000,
            streams_per_user: 32,
            im_tests_per_hour: 10,
            reports_per_hour: 30,
            hook_events_per_minute: 30,
            instances_per_user: 0,
            trust_forwarded_for: false,
            max_keys: 200_000,
        }
    }
}

/// 超限，过多少秒再试。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limited(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum Key {
    Device(DeviceId),
    User(UserId),
    Anonymous(IpAddr),
    Codes(IpAddr),
    SignupsFrom(IpAddr),
    Signups,
    ImTests(UserId),
    Reports(UserId),
    /// webhook 令牌的哈希。
    Hook([u8; 32]),
}

struct Bucket {
    tokens: f64,
    last: Instant,
    capacity: f64,
    window: Duration,
}

pub struct Limiter {
    cfg: LimitConfig,
    buckets: Mutex<HashMap<Key, Bucket>>,
    streams: Mutex<HashMap<UserId, u32>>,
}

/// 计数用的地址：IPv4 映射的 IPv6 按 IPv4，其余 IPv6 按 /64。
pub fn limit_key(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V4(_) => ip,
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => IpAddr::V4(v4),
            None => {
                let s = v6.segments();
                IpAddr::V6(Ipv6Addr::new(s[0], s[1], s[2], s[3], 0, 0, 0, 0))
            }
        },
    }
}

impl Limiter {
    pub fn new(cfg: LimitConfig) -> Self {
        Self {
            cfg,
            buckets: Mutex::default(),
            streams: Mutex::default(),
        }
    }

    pub fn config(&self) -> &LimitConfig {
        &self.cfg
    }

    fn take(&self, key: Key, capacity: u32, window: Duration) -> Result<(), Limited> {
        if capacity == 0 {
            return Ok(());
        }
        let now = Instant::now();
        let mut map = self.buckets.lock().unwrap_or_else(|e| e.into_inner());
        if !map.contains_key(&key) && map.len() >= self.cfg.max_keys {
            // 闲置满一个周期的桶已经回满，删掉不影响结果。
            map.retain(|_, b| now.duration_since(b.last) < b.window);
            if map.len() >= self.cfg.max_keys {
                return Ok(());
            }
        }
        let b = map.entry(key).or_insert_with(|| Bucket {
            tokens: f64::from(capacity),
            last: now,
            capacity: f64::from(capacity),
            window,
        });
        let refill = now.duration_since(b.last).as_secs_f64() * b.capacity / b.window.as_secs_f64();
        b.tokens = (b.tokens + refill).min(b.capacity);
        b.last = now;
        if b.tokens >= 1.0 {
            b.tokens -= 1.0;
            return Ok(());
        }
        let wait = (1.0 - b.tokens) * b.window.as_secs_f64() / b.capacity;
        Err(Limited(wait.ceil().max(1.0) as u64))
    }

    /// IM 渠道的测试消息：按用户（每条都真的发到群里，别让人拿来刷群）。
    pub fn im_tests(&self, user: UserId) -> Result<(), Limited> {
        self.take(Key::ImTests(user), self.cfg.im_tests_per_hour, HOUR)
    }

    /// 内容举报：按用户（每条都进运营的队列）。
    pub fn reports(&self, user: UserId) -> Result<(), Limited> {
        self.take(Key::Reports(user), self.cfg.reports_per_hour, HOUR)
    }

    /// 已登录的请求：按设备、按用户。
    pub fn authed(&self, user: UserId, device: DeviceId) -> Result<(), Limited> {
        self.take(Key::Device(device), self.cfg.device_per_minute, MINUTE)?;
        self.take(Key::User(user), self.cfg.user_per_minute, MINUTE)
    }

    /// 未登录的接口：按来源地址。拿不到地址（测试、内部调用）时不限。
    pub fn anonymous(&self, ip: Option<IpAddr>) -> Result<(), Limited> {
        match ip {
            Some(ip) => self.take(
                Key::Anonymous(limit_key(ip)),
                self.cfg.anonymous_per_minute,
                MINUTE,
            ),
            None => Ok(()),
        }
    }

    /// 这个来源地址乱猜过太多次了吗（不扣次数，只看）：超了的连库都不用查。
    pub fn anonymous_exhausted(&self, ip: Option<IpAddr>) -> Result<(), Limited> {
        let (Some(ip), cap) = (ip, self.cfg.anonymous_per_minute) else {
            return Ok(());
        };
        if cap == 0 {
            return Ok(());
        }
        let now = Instant::now();
        let mut map = self.buckets.lock().unwrap_or_else(|e| e.into_inner());
        let Some(b) = map.get_mut(&Key::Anonymous(limit_key(ip))) else {
            return Ok(());
        };
        let refill = now.duration_since(b.last).as_secs_f64() * b.capacity / b.window.as_secs_f64();
        b.tokens = (b.tokens + refill).min(b.capacity);
        b.last = now;
        if b.tokens >= 1.0 {
            return Ok(());
        }
        let wait = (1.0 - b.tokens) * b.window.as_secs_f64() / b.capacity;
        Err(Limited(wait.ceil().max(1.0) as u64))
    }

    /// 计划的 webhook 收事件：按 webhook（令牌的哈希）每分钟。
    pub fn hook(&self, token_hash: [u8; 32]) -> Result<(), Limited> {
        self.take(
            Key::Hook(token_hash),
            self.cfg.hook_events_per_minute,
            MINUTE,
        )
    }

    /// 发验证码：按来源地址每小时。
    pub fn codes(&self, ip: Option<IpAddr>) -> Result<(), Limited> {
        match ip {
            Some(ip) => self.take(
                Key::Codes(limit_key(ip)),
                self.cfg.codes_per_ip_per_hour,
                HOUR,
            ),
            None => Ok(()),
        }
    }

    /// 新注册：按来源地址每天，全站每小时。
    pub fn signup(&self, ip: Option<IpAddr>) -> Result<(), Limited> {
        if let Some(ip) = ip {
            self.take(
                Key::SignupsFrom(limit_key(ip)),
                self.cfg.signups_per_ip_per_day,
                DAY,
            )?;
        }
        self.take(Key::Signups, self.cfg.signups_per_hour, HOUR)
    }

    /// 打开一个事件流；返回的守卫释放时计数减一。
    pub fn open_stream(self: &Arc<Self>, user: UserId) -> Result<StreamGuard, Limited> {
        let mut map = self.streams.lock().unwrap_or_else(|e| e.into_inner());
        let n = map.entry(user).or_insert(0);
        if self.cfg.streams_per_user > 0 && *n >= self.cfg.streams_per_user {
            return Err(Limited(5));
        }
        *n += 1;
        Ok(StreamGuard {
            limiter: self.clone(),
            user,
        })
    }

    #[cfg(test)]
    fn open_streams(&self, user: UserId) -> u32 {
        self.streams
            .lock()
            .unwrap()
            .get(&user)
            .copied()
            .unwrap_or(0)
    }
}

/// 一个打开着的事件流。
pub struct StreamGuard {
    limiter: Arc<Limiter>,
    user: UserId,
}

impl Drop for StreamGuard {
    fn drop(&mut self) {
        let mut map = self
            .limiter
            .streams
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if let Some(n) = map.get_mut(&self.user) {
            *n = n.saturating_sub(1);
            if *n == 0 {
                map.remove(&self.user);
            }
        }
    }
}

/// 请求的来源地址：默认是 TCP 对端地址；配了 `trust_forwarded_for` 时取 `X-Forwarded-For`
/// 的最后一项（自己的负载均衡追加的那一项，前面的可以被客户端伪造）。
pub struct ClientIp(pub Option<IpAddr>);

pub(crate) fn client_ip(parts: &Parts, trust_forwarded_for: bool) -> Option<IpAddr> {
    if trust_forwarded_for
        && let Some(ip) = parts
            .headers
            .get("x-forwarded-for")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.rsplit(',').next())
            .and_then(|v| v.trim().parse::<IpAddr>().ok())
    {
        return Some(ip);
    }
    parts
        .extensions
        .get::<ConnectInfo<SocketAddr>>()
        .map(|c| c.0.ip())
}

impl FromRequestParts<AppState> for ClientIp {
    type Rejection = std::convert::Infallible;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        Ok(ClientIp(client_ip(
            parts,
            state.limits().config().trust_forwarded_for,
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn limiter(cfg: LimitConfig) -> Arc<Limiter> {
        Arc::new(Limiter::new(cfg))
    }

    #[test]
    fn buckets_refill_over_the_window() {
        let l = limiter(LimitConfig::default());
        let key = Key::Anonymous("1.2.3.4".parse().unwrap());
        for _ in 0..3 {
            l.take(key, 3, MINUTE).unwrap();
        }
        let Limited(wait) = l.take(key, 3, MINUTE).unwrap_err();
        assert!((1..=20).contains(&wait), "one token every 20s: {wait}");
        // 半个周期过去，补回一半多一点。
        l.buckets.lock().unwrap().get_mut(&key).unwrap().last -= Duration::from_secs(41);
        l.take(key, 3, MINUTE).unwrap();
        l.take(key, 3, MINUTE).unwrap();
        assert!(l.take(key, 3, MINUTE).is_err());
        // 0 = 不限。
        for _ in 0..100 {
            l.take(Key::Signups, 0, HOUR).unwrap();
        }
    }

    #[test]
    fn devices_and_users_are_counted_separately() {
        let l = limiter(LimitConfig {
            device_per_minute: 2,
            user_per_minute: 3,
            ..LimitConfig::default()
        });
        let (user, d1, d2) = (UserId::new(), DeviceId::new(), DeviceId::new());
        l.authed(user, d1).unwrap();
        l.authed(user, d1).unwrap();
        assert!(l.authed(user, d1).is_err(), "device limit");
        l.authed(user, d2).unwrap();
        assert!(l.authed(user, d2).is_err(), "the user's total is used up");
        l.authed(UserId::new(), DeviceId::new()).unwrap();
    }

    #[test]
    fn addresses_group_ipv6_by_prefix() {
        let a: IpAddr = "2001:db8:1:2:aaaa::1".parse().unwrap();
        let b: IpAddr = "2001:db8:1:2:bbbb::9".parse().unwrap();
        let c: IpAddr = "2001:db8:1:3::1".parse().unwrap();
        assert_eq!(limit_key(a), limit_key(b));
        assert_ne!(limit_key(a), limit_key(c));
        let mapped: IpAddr = "::ffff:10.1.2.3".parse().unwrap();
        assert_eq!(limit_key(mapped), "10.1.2.3".parse::<IpAddr>().unwrap());

        let l = limiter(LimitConfig {
            codes_per_ip_per_hour: 1,
            ..LimitConfig::default()
        });
        l.codes(Some(a)).unwrap();
        assert!(l.codes(Some(b)).is_err(), "same /64");
        l.codes(Some(c)).unwrap();
        l.codes(None).unwrap();
        l.codes(None).unwrap();
    }

    #[test]
    fn peeking_at_an_address_does_not_use_it_up() {
        let l = limiter(LimitConfig {
            anonymous_per_minute: 2,
            hook_events_per_minute: 1,
            ..LimitConfig::default()
        });
        let ip: IpAddr = "1.2.3.4".parse().unwrap();
        for _ in 0..5 {
            l.anonymous_exhausted(Some(ip)).unwrap();
        }
        l.anonymous(Some(ip)).unwrap();
        l.anonymous(Some(ip)).unwrap();
        assert!(l.anonymous_exhausted(Some(ip)).is_err());
        l.anonymous_exhausted(None).unwrap();
        // 每个 webhook 各算各的。
        l.hook([1; 32]).unwrap();
        assert!(l.hook([1; 32]).is_err());
        l.hook([2; 32]).unwrap();
    }

    #[test]
    fn signups_have_a_per_address_and_a_global_cap() {
        let l = limiter(LimitConfig {
            signups_per_ip_per_day: 1,
            signups_per_hour: 2,
            ..LimitConfig::default()
        });
        let ip: IpAddr = "1.2.3.4".parse().unwrap();
        l.signup(Some(ip)).unwrap();
        assert!(l.signup(Some(ip)).is_err());
        l.signup(None).unwrap();
        let Limited(wait) = l.signup(Some("5.6.7.8".parse().unwrap())).unwrap_err();
        assert!(wait > 0);
    }

    #[test]
    fn streams_are_counted_while_open() {
        let l = limiter(LimitConfig {
            streams_per_user: 2,
            ..LimitConfig::default()
        });
        let user = UserId::new();
        let a = l.open_stream(user).unwrap();
        let _b = l.open_stream(user).unwrap();
        assert!(l.open_stream(user).is_err());
        drop(a);
        assert_eq!(l.open_streams(user), 1);
        let _c = l.open_stream(user).unwrap();
        l.open_stream(UserId::new()).unwrap();
    }

    #[test]
    fn full_table_drops_idle_buckets_first() {
        let l = limiter(LimitConfig {
            max_keys: 2,
            ..LimitConfig::default()
        });
        let ip = |s: &str| Key::Anonymous(s.parse().unwrap());
        l.take(ip("1.1.1.1"), 1, MINUTE).unwrap();
        l.take(ip("2.2.2.2"), 1, MINUTE).unwrap();
        // 表满了、都还在周期内：新来源不计数（放行），老来源照样限。
        l.take(ip("3.3.3.3"), 1, MINUTE).unwrap();
        l.take(ip("3.3.3.3"), 1, MINUTE).unwrap();
        assert!(l.take(ip("1.1.1.1"), 1, MINUTE).is_err());
        // 闲置满一个周期的被清掉，新来源开始计数。
        l.buckets
            .lock()
            .unwrap()
            .get_mut(&ip("2.2.2.2"))
            .unwrap()
            .last -= MINUTE;
        l.take(ip("3.3.3.3"), 1, MINUTE).unwrap();
        assert!(l.take(ip("3.3.3.3"), 1, MINUTE).is_err());
    }
}
