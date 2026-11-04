//! 受控出网通道（WBS 2.7，[出口代理](../../../docs/egress.md)）：实例能上哪些网站、每天多少流量，网站名怎么写才算数。
//!
//! 档位在 [`crate::domain::EgressMode`]。接口（用户改设置）和出口代理（每个 CONNECT）用同一个 [`normalize_host`]，
//! 存进库的和代理比较的是同一种写法。

/// “开发网站”档自带的网站：装软件包、拉代码常用的几个，精确匹配（不含子域名）。按需要再加，用户也可以自己加。
pub const DEV_HOSTS: &[&str] = &[
    "registry.npmjs.org",
    "pypi.org",
    "files.pythonhosted.org",
    "index.crates.io",
    "static.crates.io",
    "proxy.golang.org",
    "sum.golang.org",
    "github.com",
    "codeload.github.com",
    "raw.githubusercontent.com",
];

/// 默认就能用的搜索：常用搜索引擎和 agent 常用的搜索接口（用户 2026-11-04 定：搜索直接联网）。不放能替人抓任意网页的
/// 服务（比如 r.jina.ai、翻译代理，还有 Tavily：它的 `/extract` 按给的网址抓任意网页）：那等于绕过了逐个网站问用户。
/// 代理只看得到网站名、看不到路径，所以同一个网站上既能搜索又能抓网页的接口不能放进来。
pub const SEARCH_HOSTS: &[&str] = &[
    "www.google.com",
    "google.com",
    "www.bing.com",
    "bing.com",
    "cn.bing.com",
    "duckduckgo.com",
    "html.duckduckgo.com",
    "lite.duckduckgo.com",
    "www.baidu.com",
    "baidu.com",
    "m.baidu.com",
    "www.sogou.com",
    "www.so.com",
    "search.brave.com",
    "api.search.brave.com",
];

/// 每个实例最多一直允许这么多个网站。
pub const MAX_HOSTS: usize = 50;

/// 问用户的时候，代理先等这么久（秒）：这期间用户同意了就接着连，没回应就告诉 agent 先做别的。
pub const ASK_WAIT_SECS: u64 = 60;

/// 一次任务里最多有这么多个网站同时在等用户回答（再多的直接拒绝，免得 agent 一口气弹一堆提示）。
pub const MAX_PENDING_ASKS: u32 = 5;

/// 每个实例一小时里最多登记这么多条新请求（定时任务每跑一次都问的话，不至于一直弹提示）。
pub const MAX_ASKS_PER_HOUR: u32 = 20;

/// 每个实例每天（北京时间自然日）最多这么多字节的双向流量。用户 2026-11-04 先定 100 MiB，同一天为了浏览器提到 300 MiB
/// （docs/browser.md 第 11 节第 4 条；浏览器和直接上网共用）。
pub const DAILY_BYTES: u64 = 300 << 20;

/// 每个实例同时最多这么多条隧道（用户 2026-11-04 定：4 条）。
pub const MAX_TUNNELS: u32 = 4;

/// 每天按北京时间切（相对 UTC 的秒数）：出口代理记账和 App 看用量用同一天。
pub const DAY_UTC_OFFSET_SECS: i64 = 8 * 3600;

/// 网站名不合规的原因。
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum HostError {
    #[error("the host name is empty or too long")]
    Length,
    #[error("only plain ASCII host names are accepted (use the punycode form)")]
    NotAscii,
    #[error("IP addresses are not accepted, use a host name")]
    IpLiteral,
    #[error("the host name must have at least two labels, like example.com")]
    SingleLabel,
    #[error(
        "each part of the host name must be 1-63 letters, digits or hyphens, not starting or ending with a hyphen"
    )]
    BadLabel,
}

/// 把用户填的、或者 CONNECT 里的网站名整理成唯一的写法：小写、去掉末尾的点；只收普通的 DNS 名字（字母、数字、
/// 连字符，至少两段）。不收 IP 地址（含十进制、十六进制、八进制这类变形）、端口、用户名、路径、通配符、
/// 非 ASCII 字符（国际化域名要用 punycode 形式）。`allow_single_label` 只给本地测试用（`localhost`）。
pub fn normalize_host(raw: &str, allow_single_label: bool) -> Result<String, HostError> {
    let host = raw.strip_suffix('.').unwrap_or(raw);
    if host.is_empty() || host.len() > 253 {
        return Err(HostError::Length);
    }
    if !host.is_ascii() {
        return Err(HostError::NotAscii);
    }
    let host = host.to_ascii_lowercase();
    if host.parse::<std::net::IpAddr>().is_ok() || host.starts_with('[') {
        return Err(HostError::IpLiteral);
    }
    let labels: Vec<&str> = host.split('.').collect();
    for label in &labels {
        let ok = !label.is_empty()
            && label.len() <= 63
            && !label.starts_with('-')
            && !label.ends_with('-')
            && label
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-');
        if !ok {
            return Err(HostError::BadLabel);
        }
    }
    // 最后一段全是数字（含 0x 开头的十六进制）的，解析器可能当成 IPv4 的变形（比如 `2130706433`、`127.1`、`0x7f.1`）。
    let last = labels.last().copied().unwrap_or_default();
    if last.bytes().all(|b| b.is_ascii_digit())
        || (last.starts_with("0x") && last[2..].bytes().all(|b| b.is_ascii_hexdigit()))
    {
        return Err(HostError::IpLiteral);
    }
    if labels.len() < 2 && !allow_single_label {
        return Err(HostError::SingleLabel);
    }
    Ok(host)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 以后加了新档位，老版本解析实例时按只连模型，不报错。
    #[test]
    fn unknown_modes_decode_as_model_only() {
        use crate::domain::{EgressMode, Instance};
        let mut v = serde_json::json!({
            "id": "01890000-0000-7000-8000-000000000002",
            "agent_id": "claude", "agent_version": "1", "harness": "acp", "name": "a",
            "state": "running",
            "created_at": "2026-11-04T00:00:00Z", "last_active_at": "2026-11-04T00:00:00Z",
            "egress_mode": "mirror", "egress_hosts": ["x.example.com"]
        });
        let i: Instance = serde_json::from_value(v.clone()).unwrap();
        assert_eq!(i.egress_mode, EgressMode::Model);
        v["egress_mode"] = "dev".into();
        let i: Instance = serde_json::from_value(v.clone()).unwrap();
        assert_eq!(i.egress_mode, EgressMode::Dev);
        v.as_object_mut().unwrap().remove("egress_mode");
        let i: Instance = serde_json::from_value(v).unwrap();
        assert_eq!(i.egress_mode, EgressMode::Dev);
    }

    #[test]
    fn host_names_are_normalised_and_tricks_refused() {
        assert_eq!(normalize_host("GitHub.com.", false).unwrap(), "github.com");
        assert_eq!(
            normalize_host("a-b.example.cn", false).unwrap(),
            "a-b.example.cn"
        );
        for bad in [
            "",
            "127.0.0.1",
            "127.1",
            "2130706433",
            "0x7f.1",
            "0x7f000001",
            "[::1]",
            "::1",
            "localhost",
            "*.example.com",
            "example.com:443",
            "user@example.com",
            "example.com/path",
            "-bad.example.com",
            "bad-.example.com",
            "ex ample.com",
            "例子.中国",
            "a..b",
        ] {
            assert!(
                normalize_host(bad, false).is_err(),
                "{bad} should be refused"
            );
        }
        assert_eq!(normalize_host("localhost", true).unwrap(), "localhost");
        assert!(normalize_host(&format!("{}.com", "a".repeat(64)), false).is_err());
        for host in DEV_HOSTS.iter().chain(SEARCH_HOSTS) {
            assert_eq!(normalize_host(host, false).as_deref(), Ok(*host));
        }
    }
}
