//! SSRF 防护（架构方案 5.6，WBS 9.6）。
//!
//! 用户可以填自定义 base URL，网关替用户发请求，所以上游地址必须是公网地址：
//! - 只允许 https，URL 里不能带用户名密码、查询串和片段；
//! - 主机是 IP 字面量时直接检查（HTTP 客户端不会为 IP 字面量做 DNS 解析）；
//! - 主机是域名时，由 [`PublicOnlyResolver`] 在连接前解析并检查。检查过的地址就是实际连接的地址，
//!   不存在“检查一次、连接时再解析一次”的 DNS 重绑定窗口；
//! - 不跟随重定向（在 HTTP 客户端上配置）。
//!
//! 配了出口代理时，域名由代理解析，这里只能做一次预检，最终要靠代理自己的策略兜底。

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

use reqwest::dns::{Addrs, Name, Resolve, Resolving};
use url::{Host, Url};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SsrfError {
    #[error("upstream url must use https")]
    NotHttps,
    #[error("upstream url must not carry credentials, query or fragment")]
    Extras,
    #[error("upstream url has no host")]
    NoHost,
    #[error("upstream host {0} does not resolve to a public address")]
    NotPublic(String),
    #[error("upstream host {0} did not resolve")]
    NoAddress(String),
}

/// 公网单播 IPv4 地址。
pub fn is_public_v4(ip: Ipv4Addr) -> bool {
    let [a, b, c, _] = ip.octets();
    let blocked = a == 0 // 本网络
        || a == 10
        || a == 127
        || (a == 100 && (64..128).contains(&b)) // 运营商级 NAT，阿里云元数据 100.100.100.200 也在这里
        || (a == 169 && b == 254) // 链路本地，含 169.254.169.254 等云元数据地址
        || (a == 172 && (16..32).contains(&b))
        || (a == 192 && b == 0 && (c == 0 || c == 2)) // 协议分配、文档
        || (a == 192 && b == 88 && c == 99) // 6to4 中继
        || (a == 192 && b == 168)
        || (a == 198 && (b == 18 || b == 19)) // 基准测试
        || (a == 198 && b == 51 && c == 100) // 文档
        || (a == 203 && b == 0 && c == 113) // 文档
        || a >= 224; // 组播、保留、广播
    !blocked
}

/// 公网单播 IPv6 地址。内嵌 IPv4 的形式按内嵌地址判断。
pub fn is_public_v6(ip: Ipv6Addr) -> bool {
    if let Some(v4) = ip.to_ipv4_mapped() {
        return is_public_v4(v4);
    }
    let s = ip.segments();
    // NAT64 知名前缀 64:ff9b::/96：只看内嵌的 IPv4。
    if s[..6] == [0x64, 0xff9b, 0, 0, 0, 0] {
        let [a, b] = s[6].to_be_bytes();
        let [c, d] = s[7].to_be_bytes();
        return is_public_v4(Ipv4Addr::new(a, b, c, d));
    }
    // 只放行全球单播 2000::/3，这一条就排除了 ::、::1、IPv4 兼容地址、fc00::/7、fe80::/10、组播等。
    if s[0] & 0xe000 != 0x2000 {
        return false;
    }
    let blocked = (s[0] == 0x2001 && s[1] < 0x0200) // 2001::/23 协议分配（Teredo、ORCHID 等）
        || (s[0] == 0x2001 && s[1] == 0x0db8) // 文档
        || s[0] == 0x2002 // 6to4，内嵌任意 IPv4
        || (s[0] == 0x3fff && s[1] < 0x1000); // 3fff::/20 文档
    !blocked
}

pub fn is_public(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_public_v4(v4),
        IpAddr::V6(v6) => is_public_v6(v6),
    }
}

/// 静态检查上游 URL。`insecure` 只用于本地开发和测试：允许 http 和非公网地址。
pub fn check_upstream_url(url: &Url, insecure: bool) -> Result<(), SsrfError> {
    if !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(SsrfError::Extras);
    }
    match url.scheme() {
        "https" => {}
        "http" if insecure => {}
        _ => return Err(SsrfError::NotHttps),
    }
    let host = url.host().ok_or(SsrfError::NoHost)?;
    if insecure {
        return Ok(());
    }
    match host {
        Host::Ipv4(ip) if !is_public_v4(ip) => Err(SsrfError::NotPublic(ip.to_string())),
        Host::Ipv6(ip) if !is_public_v6(ip) => Err(SsrfError::NotPublic(ip.to_string())),
        _ => Ok(()),
    }
}

/// 解析域名，任何一个地址不是公网地址就整体拒绝（一半公网一半内网多半是在做重绑定）。
pub async fn resolve_public(host: &str) -> Result<Vec<SocketAddr>, SsrfError> {
    let addrs: Vec<SocketAddr> = tokio::net::lookup_host((host, 0))
        .await
        .map_err(|_| SsrfError::NoAddress(host.to_owned()))?
        .collect();
    if addrs.is_empty() {
        return Err(SsrfError::NoAddress(host.to_owned()));
    }
    if addrs.iter().any(|a| !is_public(a.ip())) {
        return Err(SsrfError::NotPublic(host.to_owned()));
    }
    Ok(addrs)
}

/// 只返回公网地址的 DNS 解析器，装在网关访问厂商用的 HTTP 客户端上。
#[derive(Debug, Clone, Copy, Default)]
pub struct PublicOnlyResolver;

impl Resolve for PublicOnlyResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let host = name.as_str().to_owned();
        Box::pin(async move {
            let addrs = resolve_public(&host).await?;
            Ok(Box::new(addrs.into_iter()) as Addrs)
        })
    }
}

/// 在错误链里找 SSRF 拒绝的原因。
pub fn find_ssrf_error<'a>(err: &'a (dyn std::error::Error + 'static)) -> Option<&'a SsrfError> {
    let mut cur = Some(err);
    while let Some(e) = cur {
        if let Some(found) = e.downcast_ref::<SsrfError>() {
            return Some(found);
        }
        cur = e.source();
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v4(s: &str) -> bool {
        is_public(s.parse().unwrap())
    }

    #[test]
    fn ipv4_ranges() {
        for ip in [
            "0.0.0.0",
            "10.1.2.3",
            "127.0.0.1",
            "100.100.100.200",
            "169.254.169.254",
            "169.254.0.23",
            "172.16.0.1",
            "172.31.255.255",
            "192.168.1.1",
            "192.0.0.8",
            "192.0.2.1",
            "198.18.0.1",
            "198.51.100.7",
            "203.0.113.9",
            "224.0.0.1",
            "240.0.0.1",
            "255.255.255.255",
        ] {
            assert!(!v4(ip), "{ip} should be blocked");
        }
        for ip in [
            "1.1.1.1",
            "8.8.8.8",
            "47.95.1.1",
            "100.63.255.255",
            "100.128.0.1",
            "172.32.0.1",
            "192.169.0.1",
        ] {
            assert!(v4(ip), "{ip} should be allowed");
        }
    }

    #[test]
    fn ipv6_ranges() {
        for ip in [
            "::",
            "::1",
            "::ffff:127.0.0.1",
            "::ffff:169.254.169.254",
            "::127.0.0.1",
            "64:ff9b::a00:1",
            "64:ff9b:1::1",
            "fc00::1",
            "fd00:ec2::254",
            "fe80::1",
            "fec0::1",
            "ff02::1",
            "2001::1",
            "2001:db8::1",
            "2002:a00:1::",
            "3fff::1",
            "100::1",
        ] {
            assert!(!v4(ip), "{ip} should be blocked");
        }
        for ip in [
            "2400:3200::1",
            "2606:4700::1111",
            "::ffff:8.8.8.8",
            "64:ff9b::808:808",
            "2001:200::1",
        ] {
            assert!(v4(ip), "{ip} should be allowed");
        }
    }

    #[test]
    fn static_url_checks() {
        let ok = |s: &str| check_upstream_url(&Url::parse(s).unwrap(), false);
        assert_eq!(ok("https://api.deepseek.com/anthropic"), Ok(()));
        assert_eq!(ok("http://api.deepseek.com"), Err(SsrfError::NotHttps));
        assert_eq!(ok("ftp://api.deepseek.com"), Err(SsrfError::NotHttps));
        assert_eq!(ok("https://u:p@api.deepseek.com"), Err(SsrfError::Extras));
        assert_eq!(ok("https://api.deepseek.com/?x=1"), Err(SsrfError::Extras));
        assert_eq!(ok("https://api.deepseek.com/#x"), Err(SsrfError::Extras));
        // URL 解析器会把各种 IPv4 写法规范化，十六进制、八进制、整数写法都逃不过。
        for s in [
            "https://127.0.0.1",
            "https://0x7f.1",
            "https://2130706433",
            "https://0177.0.0.1",
            "https://[::1]",
            "https://[::ffff:a9fe:a9fe]",
            "https://169.254.169.254:443/latest",
        ] {
            assert!(matches!(ok(s), Err(SsrfError::NotPublic(_))), "{s}");
        }
        assert_eq!(
            check_upstream_url(&Url::parse("http://127.0.0.1:9/x").unwrap(), true),
            Ok(())
        );
    }

    #[tokio::test]
    async fn resolver_blocks_loopback_names() {
        assert_eq!(
            resolve_public("localhost").await,
            Err(SsrfError::NotPublic("localhost".into()))
        );
        let err = PublicOnlyResolver
            .resolve("localhost".parse().unwrap())
            .await
            .err()
            .unwrap();
        assert!(find_ssrf_error(err.as_ref()).is_some());
    }
}
