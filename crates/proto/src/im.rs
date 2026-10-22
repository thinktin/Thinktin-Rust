//! IM 渠道（WBS 10.5）：飞书 / Lark、企业微信、钉钉的群机器人 webhook。
//!
//! 用户粘贴的 webhook 地址只认各家官方的固定前缀，后面只能跟 token：存下来的只有 token（加密），
//! 发送时按 [`webhook_base`] 重新拼地址，所以库里的数据指不到别的主机（防 SSRF）。

use crate::domain::ImVendor;

/// 各家 webhook 地址的固定前缀，后面接 token。
pub fn webhook_base(vendor: ImVendor) -> &'static str {
    match vendor {
        ImVendor::Feishu => "https://open.feishu.cn/open-apis/bot/v2/hook/",
        ImVendor::Lark => "https://open.larksuite.com/open-apis/bot/v2/hook/",
        ImVendor::Wecom => "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=",
        ImVendor::Dingtalk => "https://oapi.dingtalk.com/robot/send?access_token=",
    }
}

/// 有没有“加签”：飞书、Lark、钉钉可以设签名密钥，企业微信没有（地址里的 key 就是凭证）。
pub fn supports_secret(vendor: ImVendor) -> bool {
    !matches!(vendor, ImVendor::Wecom)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum ImUrlError {
    #[error("not a Feishu, Lark, WeCom or DingTalk group bot webhook address")]
    UnknownAddress,
    #[error("the webhook token is missing or malformed")]
    BadToken,
    #[error("this vendor has no signing secret")]
    SecretNotSupported,
    #[error("the signing secret is malformed")]
    BadSecret,
}

/// 解析用户粘贴的 webhook 地址，返回平台和 token。地址要一字不差地以官方前缀开头（https、官方域名、
/// 官方路径；大小写、端口、用户名、多余的路径或参数都不认），token 只能是字母、数字、`-`、`_`。
pub fn parse_webhook(url: &str) -> Result<(ImVendor, String), ImUrlError> {
    let url = url.trim();
    let (vendor, token) = ImVendor::ALL
        .iter()
        .find_map(|v| url.strip_prefix(webhook_base(*v)).map(|t| (*v, t)))
        .ok_or(ImUrlError::UnknownAddress)?;
    if !valid_token(token) {
        return Err(ImUrlError::BadToken);
    }
    Ok((vendor, token.to_owned()))
}

fn valid_token(token: &str) -> bool {
    (8..=128).contains(&token.len())
        && token
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// 检查签名密钥：企业微信不收；其他的是 8 到 128 个可见 ASCII 字符（钉钉的以 `SEC` 开头）。
pub fn check_secret(vendor: ImVendor, secret: &str) -> Result<(), ImUrlError> {
    if !supports_secret(vendor) {
        return Err(ImUrlError::SecretNotSupported);
    }
    let ok = (8..=128).contains(&secret.len()) && secret.bytes().all(|b| b.is_ascii_graphic());
    if !ok || (vendor == ImVendor::Dingtalk && !secret.starts_with("SEC")) {
        return Err(ImUrlError::BadSecret);
    }
    Ok(())
}

/// 给用户辨认用的提示：token 后 4 位。
pub fn hint(token: &str) -> String {
    let n = token.len();
    format!("…{}", &token[n.saturating_sub(4)..])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn official_addresses_parse_to_vendor_and_token() {
        for (url, vendor, token) in [
            (
                "https://open.feishu.cn/open-apis/bot/v2/hook/2f8a6c1e-1111-4a2b-9c3d-0123456789ab",
                ImVendor::Feishu,
                "2f8a6c1e-1111-4a2b-9c3d-0123456789ab",
            ),
            (
                "https://open.larksuite.com/open-apis/bot/v2/hook/abcdef1234567890",
                ImVendor::Lark,
                "abcdef1234567890",
            ),
            (
                " https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=693a91f6-7xxx-4bc4-97a0-0ec2sifa5aaa\n",
                ImVendor::Wecom,
                "693a91f6-7xxx-4bc4-97a0-0ec2sifa5aaa",
            ),
            (
                "https://oapi.dingtalk.com/robot/send?access_token=0123456789abcdef0123456789abcdef",
                ImVendor::Dingtalk,
                "0123456789abcdef0123456789abcdef",
            ),
        ] {
            assert_eq!(parse_webhook(url), Ok((vendor, token.to_owned())), "{url}");
        }
    }

    #[test]
    fn anything_but_the_exact_official_prefix_is_rejected() {
        let token = "0123456789abcdef";
        for url in [
            format!("http://open.feishu.cn/open-apis/bot/v2/hook/{token}"),
            format!("https://open.feishu.cn.evil.com/open-apis/bot/v2/hook/{token}"),
            format!("https://open.feishu.cn./open-apis/bot/v2/hook/{token}"),
            format!("https://OPEN.FEISHU.CN/open-apis/bot/v2/hook/{token}"),
            format!("https://open.feishu.cn:8443/open-apis/bot/v2/hook/{token}"),
            format!("https://user@open.feishu.cn/open-apis/bot/v2/hook/{token}"),
            format!("https://evil.com/?https://open.feishu.cn/open-apis/bot/v2/hook/{token}"),
            format!("https://open.feishu.cn/open-apis/bot/hook/{token}"),
            format!("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?debug=1&key={token}"),
            format!("https://1.2.3.4/robot/send?access_token={token}"),
            String::new(),
        ] {
            assert_eq!(
                parse_webhook(&url),
                Err(ImUrlError::UnknownAddress),
                "{url}"
            );
        }
        for url in [
            format!("https://open.feishu.cn/open-apis/bot/v2/hook/{token}/x"),
            format!("https://open.feishu.cn/open-apis/bot/v2/hook/{token}?x=1"),
            format!("https://open.feishu.cn/open-apis/bot/v2/hook/{token}#frag"),
            format!("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key={token}&debug=1"),
            format!("https://oapi.dingtalk.com/robot/send?access_token={token}@evil.com"),
            "https://oapi.dingtalk.com/robot/send?access_token=short".into(),
            format!(
                "https://oapi.dingtalk.com/robot/send?access_token={}",
                "a".repeat(129)
            ),
        ] {
            assert_eq!(parse_webhook(&url), Err(ImUrlError::BadToken), "{url}");
        }
    }

    #[test]
    fn secrets_are_checked_per_vendor() {
        assert_eq!(
            check_secret(ImVendor::Wecom, "whatever123"),
            Err(ImUrlError::SecretNotSupported)
        );
        assert_eq!(
            check_secret(ImVendor::Dingtalk, "abcdefgh12345678"),
            Err(ImUrlError::BadSecret)
        );
        assert_eq!(
            check_secret(ImVendor::Dingtalk, "SECabcdef0123456789"),
            Ok(())
        );
        assert_eq!(check_secret(ImVendor::Feishu, "kJzMpX2c9vQ1"), Ok(()));
        assert_eq!(
            check_secret(ImVendor::Feishu, "short"),
            Err(ImUrlError::BadSecret)
        );
        assert_eq!(
            check_secret(ImVendor::Lark, "has space in it"),
            Err(ImUrlError::BadSecret)
        );
        assert_eq!(hint("0123456789abcdef"), "…cdef");
    }
}
