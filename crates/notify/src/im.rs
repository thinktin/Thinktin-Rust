//! IM 渠道（WBS 10.5）：把通知发到用户绑定的飞书 / Lark、企业微信、钉钉群机器人。
//!
//! 按各家官方文档（2026-10-21 核对，见 docs/im-channels.md）：
//! - 飞书、Lark：`POST https://open.feishu.cn|open.larksuite.com/open-apis/bot/v2/hook/<token>`。加签时请求体带
//!   `timestamp`（秒）和 `sign = base64(HMAC-SHA256(key = "<timestamp>\n<密钥>", 空消息))`，一小时内有效。
//!   发富文本（`post`）的纯文本节点：`text` 消息会解析 `<at user_id="all">`，agent 写的摘要不能 @ 所有人。
//! - 企业微信：`POST https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=<key>`，没有加签；文本最长 2048 字节，
//!   只有 `mentioned_list` 才会 @ 人，我们不填。
//! - 钉钉：`POST https://oapi.dingtalk.com/robot/send?access_token=<token>`，加签时地址后面加 `timestamp`（毫秒）
//!   和 `sign = urlencode(base64(HMAC-SHA256(key = 密钥, "<timestamp>\n<密钥>")))`，一小时内有效。
//!   `at.isAtAll = false`，不填 `atMobiles`，不会 @ 人。
//!
//! 三家的业务错误大多是 HTTP 200 加上 `code` / `errcode`，按响应体判断。机器人被删、地址失效时停用渠道；
//! 签名、关键词、IP 白名单这些用户能改的设置不对时记下原因、不重试；限流、服务端错误过一阵再试。
//! 记下的原因是我们自己写的（带厂商的错误码），不照抄对方的 `errmsg`：企业微信的会带上调用方的 IP。
//! 地址按固定前缀和 token 拼出来，不跟随重定向；网络错误里去掉地址（地址里有 token）。

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use aws_lc_rs::hmac;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use proto::domain::{ImVendor, Locale};
use serde_json::{Value, json};
use zeroize::Zeroizing;

use crate::PushOutcome;

/// 正文最多多少字节（企业微信文本消息上限 2048 字节，留出余量；其他两家宽得多，统一按这个截断）。
const MAX_TEXT_BYTES: usize = 1800;
/// 被限流以后多久再试：飞书、企业微信按分钟限，钉钉超了会被限 10 分钟。
const RATE_RETRY: Duration = Duration::from_secs(60);
const DINGTALK_THROTTLE: Duration = Duration::from_secs(600);

/// 一个群机器人的凭证（发送时从密钥库解开，用完清零）。
pub struct ImHook {
    pub vendor: ImVendor,
    pub token: Zeroizing<String>,
    /// 加签的密钥；没设就是 None。
    pub secret: Option<Zeroizing<String>>,
}

impl std::fmt::Debug for ImHook {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ImHook")
            .field("vendor", &self.vendor)
            .field("has_secret", &self.secret.is_some())
            .finish_non_exhaustive()
    }
}

/// 发到群里的一条消息：标题和正文都已经按用户的语言写好、过了关键词过滤、带上了 AI 生成标识。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImMessage {
    pub title: String,
    pub text: String,
    pub locale: Locale,
}

#[async_trait]
pub trait ImSender: Send + Sync {
    /// 结果：`Delivered` 发出去了；`InvalidToken` 机器人没了或地址失效（停用渠道）；`Rejected` 设置或内容
    /// 被拒（记下原因，不重试）；`Retry` 过一阵再试。
    async fn send(&self, hook: &ImHook, message: &ImMessage) -> PushOutcome;
}

pub struct ImClient {
    http: reqwest::Client,
    bases: [String; 4],
}

impl ImClient {
    pub fn new() -> Result<Self, reqwest::Error> {
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(3))
            .timeout(Duration::from_secs(8))
            .redirect(reqwest::redirect::Policy::none())
            .https_only(true)
            .build()?;
        Ok(Self::with_http(http, proto::im::webhook_base))
    }

    /// 测试用：自己的 HTTP 客户端和地址前缀。
    pub fn with_http(http: reqwest::Client, base: impl Fn(ImVendor) -> &'static str) -> Self {
        Self::with_bases(http, |v| base(v).to_owned())
    }

    pub fn with_bases(http: reqwest::Client, base: impl Fn(ImVendor) -> String) -> Self {
        let bases = [
            ImVendor::Feishu,
            ImVendor::Lark,
            ImVendor::Wecom,
            ImVendor::Dingtalk,
        ]
        .map(base);
        Self { http, bases }
    }

    fn base(&self, vendor: ImVendor) -> &str {
        let i = match vendor {
            ImVendor::Feishu => 0,
            ImVendor::Lark => 1,
            ImVendor::Wecom => 2,
            ImVendor::Dingtalk => 3,
        };
        &self.bases[i]
    }

    /// 请求地址和请求体（签名按现在的时间算）。
    fn request(
        &self,
        hook: &ImHook,
        message: &ImMessage,
        now: SystemTime,
    ) -> (Zeroizing<String>, Value) {
        let since = now.duration_since(UNIX_EPOCH).unwrap_or_default();
        let mut url = Zeroizing::new(format!("{}{}", self.base(hook.vendor), hook.token.as_str()));
        let text = truncate(&message.text, MAX_TEXT_BYTES);
        let body = match hook.vendor {
            ImVendor::Feishu | ImVendor::Lark => {
                let lang = match message.locale {
                    Locale::ZhCn => "zh_cn",
                    Locale::En => "en_us",
                };
                let mut body = json!({
                    "msg_type": "post",
                    "content": { "post": { lang: {
                        "title": truncate(&message.title, 200),
                        "content": [[{ "tag": "text", "text": text }]],
                    } } },
                });
                if let Some(secret) = &hook.secret {
                    let ts = since.as_secs();
                    body["timestamp"] = json!(ts.to_string());
                    body["sign"] = json!(feishu_sign(secret, ts));
                }
                body
            }
            ImVendor::Wecom => json!({
                "msgtype": "text",
                "text": { "content": truncate(&format!("{}\n{text}", message.title), MAX_TEXT_BYTES) },
            }),
            ImVendor::Dingtalk => {
                if let Some(secret) = &hook.secret {
                    let ts = since.as_millis() as u64;
                    let sign = dingtalk_sign(secret, ts);
                    url.push_str(&format!(
                        "&timestamp={ts}&sign={}",
                        url_encode_base64(&sign)
                    ));
                }
                json!({
                    "msgtype": "text",
                    "text": { "content": truncate(&format!("{}\n{text}", message.title), MAX_TEXT_BYTES) },
                    "at": { "isAtAll": false },
                })
            }
        };
        (url, body)
    }
}

/// 飞书：`timestamp + "\n" + 密钥` 当 HMAC 的密钥，对空消息签名，再 Base64。
pub fn feishu_sign(secret: &str, timestamp_secs: u64) -> String {
    let key = Zeroizing::new(format!("{timestamp_secs}\n{secret}"));
    let tag = hmac::sign(&hmac::Key::new(hmac::HMAC_SHA256, key.as_bytes()), b"");
    STANDARD.encode(tag.as_ref())
}

/// 钉钉：密钥当 HMAC 的密钥，对 `timestamp + "\n" + 密钥` 签名，再 Base64（放进地址前还要 URL 编码）。
pub fn dingtalk_sign(secret: &str, timestamp_ms: u64) -> String {
    let message = Zeroizing::new(format!("{timestamp_ms}\n{secret}"));
    let tag = hmac::sign(
        &hmac::Key::new(hmac::HMAC_SHA256, secret.as_bytes()),
        message.as_bytes(),
    );
    STANDARD.encode(tag.as_ref())
}

fn url_encode_base64(s: &str) -> String {
    s.replace('+', "%2B")
        .replace('/', "%2F")
        .replace('=', "%3D")
}

/// 按字节截断，不切开字符；截了就在末尾加省略号。
fn truncate(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_owned();
    }
    let mut end = max.saturating_sub('…'.len_utf8());
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", &s[..end])
}

fn code(v: &Value) -> Option<i64> {
    v.as_i64()
        .or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))
}

#[async_trait]
impl ImSender for ImClient {
    async fn send(&self, hook: &ImHook, message: &ImMessage) -> PushOutcome {
        let vendor = hook.vendor.as_str();
        // 存进库之前校验过；发之前再查一遍（地址是拼出来的，token 里不能有别的字符）。
        let token_ok = (8..=128).contains(&hook.token.len())
            && hook
                .token
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
        if !token_ok {
            return PushOutcome::InvalidToken {
                reason: format!("{vendor}: malformed webhook token"),
            };
        }
        let (url, body) = self.request(hook, message, SystemTime::now());
        let resp = match self.http.post(url.as_str()).json(&body).send().await {
            Ok(r) => r,
            Err(e) => {
                return PushOutcome::Retry {
                    after: None,
                    reason: format!("{vendor}: network: {}", e.without_url()),
                };
            }
        };
        let status = resp.status().as_u16();
        let body: Value = resp.json().await.unwrap_or(Value::Null);
        let field = if matches!(hook.vendor, ImVendor::Feishu | ImVendor::Lark) {
            "code"
        } else {
            "errcode"
        };
        let code = code(&body[field]);
        if status == 200 && code == Some(0) {
            return PushOutcome::Delivered { id: None };
        }
        classify(hook.vendor, status, code)
    }
}

/// 按厂商的错误码分类（见模块说明）。
fn classify(vendor: ImVendor, status: u16, code: Option<i64>) -> PushOutcome {
    let name = vendor.as_str();
    let reason = |what: &str| match code {
        Some(c) => format!("{name} {c}: {what}"),
        None => format!("{name} http {status}: {what}"),
    };
    let gone = |what: &str| PushOutcome::InvalidToken {
        reason: reason(what),
    };
    let rejected = |what: &str| PushOutcome::Rejected {
        reason: reason(what),
    };
    let retry = |after: Option<Duration>, what: &str| PushOutcome::Retry {
        after,
        reason: reason(what),
    };
    match (vendor, code) {
        (ImVendor::Feishu | ImVendor::Lark, Some(c)) => match c {
            19001 => gone("the bot's webhook token is invalid (bot removed?)"),
            19021 => {
                rejected("signature rejected or timestamp out of range; check the signing secret")
            }
            19022 => rejected("the bot only accepts listed IP addresses"),
            19024 => rejected("the message has none of the bot's custom keywords"),
            11232 => retry(Some(RATE_RETRY), "rate limited"),
            9499 => rejected("bad request"),
            _ => retry(None, "unexpected error"),
        },
        (ImVendor::Wecom, Some(c)) => match c {
            93000 | 93004 | 93008 | 93019 => {
                gone("the webhook is invalid or the bot was removed from the group")
            }
            93001 => rejected("the group does not allow bot messages"),
            45009 | 45033 => retry(Some(RATE_RETRY), "rate limited"),
            -1 => retry(None, "service busy"),
            40008 | 44004 | 45002 | 93017 => rejected("message rejected"),
            _ => retry(None, "unexpected error"),
        },
        (ImVendor::Dingtalk, Some(c)) => match c {
            300001 | 300005 | 400101 | 400102 | 400106 | 400013 => {
                gone("the bot's access token is invalid, the bot is disabled or the group is gone")
            }
            310000 => rejected(
                "security check failed (signing secret, custom keywords or IP list); check the bot's security settings",
            ),
            410100 | 130101 => retry(
                Some(DINGTALK_THROTTLE),
                "rate limited (the bot is throttled for 10 minutes)",
            ),
            430101..=430104 => rejected("content rejected as unsafe"),
            -1 => retry(None, "service busy"),
            _ => retry(None, "unexpected error"),
        },
        (_, None) => match status {
            429 => retry(Some(RATE_RETRY), "rate limited"),
            500..=599 => retry(None, "server error"),
            _ => rejected("unexpected response"),
        },
    }
}

#[cfg(test)]
mod tests;
