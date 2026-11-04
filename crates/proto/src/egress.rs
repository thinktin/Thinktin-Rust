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

/// 浏览器通道（docs/browser.md 第 4 节）：CONNECT 的用户名写这个、密码是浏览器通行证。走哪条通道由通行证里的 `aud`
/// 决定，不看用户名（用户名谁都能写）。
pub const BROWSER_USER: &str = "browser";
/// 浏览器打开一个新网站时问用户最多等这么久（秒）：浏览器工具 60 秒就超时，要给网页加载留时间（用户 2026-11-04 同意）。
pub const BROWSER_ASK_WAIT_SECS: u64 = 40;
/// 每个实例的浏览器通道同时最多这么多条隧道（和直接上网的 4 条分开算）。
pub const BROWSER_MAX_TUNNELS: u32 = 16;
/// 每个实例的浏览器通道每分钟最多开这么多次隧道。
pub const BROWSER_ATTEMPTS_PER_MINUTE: u32 = 600;
/// 一个页面最多从这么多个网站加载资源；一次任务最多这么多个。
pub const BROWSER_HOSTS_PER_PAGE: usize = 100;
pub const BROWSER_HOSTS_PER_RUN: usize = 500;

/// 浏览器里“同一个网站”（用户 2026-11-04 定：按主域名算，技术上是 eTLD+1）：`www.zhihu.com` 和 `zhuanlan.zhihu.com`
/// 都是 `zhihu.com`，`sina.com.cn` 不会被当成 `com.cn`，`github.io` 这类后缀下每个子域名各算一个网站。`host` 已经按
/// [`normalize_host`] 整理过；查不到主域名的（单段名字、本身就是后缀）原样返回。
#[cfg(feature = "site")]
pub fn site_of(host: &str) -> String {
    psl::domain_str(host)
        .map(str::to_owned)
        .unwrap_or_else(|| host.to_owned())
}

/// 走的是哪条通道。
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize, Default,
)]
#[serde(rename_all = "snake_case")]
pub enum Via {
    /// agent 自己直接上网（curl、npm、WebFetch）：每个网站都问。
    #[default]
    Direct,
    /// 平台的浏览器：打开新网站时问，页面资源不问。
    Browser,
}

/// 浏览器为什么要打开这个网站（问用户时给用户看，也记日志）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AskCause {
    /// agent 用 `browser_navigate` 或新标签打开。
    Navigate,
    /// 网页里点了链接、脚本跳转。
    Link,
    /// 提交表单。
    Form,
    /// 服务器跳转。
    Redirect,
    /// 网页弹出的新窗口。
    Popup,
}

/// shim 的浏览器守门问出口代理“能不能打开这个网站”（`POST /v1/browser/ask`）。
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct BrowserAsk {
    pub host: String,
    /// 要打开的网址（只用来给用户看、记日志）。
    #[serde(default)]
    pub url: Option<String>,
    /// 从哪个网站过来的。
    #[serde(default)]
    pub from: Option<String>,
    pub cause: AskCause,
    /// 最多等多久（秒，不超过 [`BROWSER_ASK_WAIT_SECS`]）。
    #[serde(default)]
    pub wait_secs: Option<u64>,
}

/// 出口代理的回答。`result` 是字符串：以后加了新结果老版本照样解析（认不出的按不能打开）。
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct BrowserAskReply {
    /// `allowed`、`pending`、`denied`、`private_address`、`resolve`、`not_allowed`、`quota`、`too_many_asks`、`ask_rate`、
    /// `unavailable`。
    pub result: String,
    /// 允许时管到多大：`default`（搜索、开发网站，只认完整网址）、`once`（这次任务，整个网站）、`always`（整个网站）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
    /// 在等用户回答的那条请求。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
}

impl BrowserAskReply {
    pub fn allowed(&self) -> bool {
        self.result == "allowed"
    }
}

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

    /// 浏览器里按主域名算同一个网站。
    #[cfg(feature = "site")]
    #[test]
    fn sites_follow_the_public_suffix_list() {
        assert_eq!(site_of("www.zhihu.com"), "zhihu.com");
        assert_eq!(site_of("zhuanlan.zhihu.com"), "zhihu.com");
        assert_eq!(site_of("news.sina.com.cn"), "sina.com.cn");
        assert_eq!(site_of("a.b.example.co.uk"), "example.co.uk");
        // 每个子域名属于不同的人。
        assert_eq!(site_of("alice.github.io"), "alice.github.io");
        assert_ne!(site_of("alice.github.io"), site_of("bob.github.io"));
        assert_eq!(
            site_of("xn--fiqs8s.xn--fiqs8s"),
            site_of("xn--fiqs8s.xn--fiqs8s")
        );
        assert_eq!(site_of("localhost"), "localhost");
    }

    #[test]
    fn browser_ask_replies_decode_leniently() {
        let r: BrowserAskReply = serde_json::from_str(r#"{"result":"something_new"}"#).unwrap();
        assert!(!r.allowed());
        let r: BrowserAskReply =
            serde_json::from_str(r#"{"result":"allowed","scope":"once"}"#).unwrap();
        assert!(r.allowed());
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
