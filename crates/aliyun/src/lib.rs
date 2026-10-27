//! 阿里云的 RPC 风格接口（短信 Dysmsapi、密钥管理 KMS 等）：公共参数、签名、调用。
//!
//! 请求按阿里云的 RPC 签名机制（签名版本 1.0）签名：参数按名字排序、按 RFC 3986 编码拼起来，
//! 前面加上请求方法和编码过的 `/`，用 `AccessKeySecret&` 做 HMAC-SHA1，再 Base64。POST 表单。
//!
//! - [`RpcClient`]：调一个接口，返回 JSON；HTTP 不是 2xx 时按返回的 `Code`、`Message` 报错。
//! - [`kms::AliyunKms`]：用阿里云 KMS 包裹、解包用户的数据密钥（主密钥不出 KMS）。

use std::fmt;
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use hmac::{Hmac, KeyInit, Mac};
use sha1::Sha1;
use zeroize::Zeroizing;

pub mod kms;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("aliyun request failed: {0}")]
    Http(String),
    /// 接口返回的错误：HTTP 状态码、阿里云的错误码和说明。
    #[error("aliyun {code}: {message}")]
    Api {
        status: u16,
        code: String,
        message: String,
    },
    #[error("aliyun reply is malformed: {0}")]
    Malformed(String),
    #[error("{0}")]
    Config(String),
}

/// 一个 RPC 风格接口的客户端（一个服务、一个版本）。
pub struct RpcClient {
    endpoint: String,
    version: String,
    access_key_id: String,
    access_key_secret: Zeroizing<String>,
    http: reqwest::Client,
}

impl fmt::Debug for RpcClient {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RpcClient")
            .field("endpoint", &self.endpoint)
            .field("version", &self.version)
            .field("access_key_id", &self.access_key_id)
            .field("access_key_secret", &"***")
            .finish()
    }
}

impl RpcClient {
    /// `endpoint` 比如 `https://dysmsapi.aliyuncs.com`、`https://kms.cn-hangzhou.aliyuncs.com`；
    /// `version` 是接口版本，比如短信的 `2017-05-25`、KMS 的 `2016-01-20`。
    pub fn new(
        endpoint: impl Into<String>,
        version: impl Into<String>,
        access_key_id: impl Into<String>,
        access_key_secret: Zeroizing<String>,
        timeout: Duration,
    ) -> Result<Self, Error> {
        let endpoint = endpoint.into();
        let access_key_id = access_key_id.into();
        if !(endpoint.starts_with("https://") || endpoint.starts_with("http://")) {
            return Err(Error::Config(format!(
                "aliyun endpoint {endpoint:?} must be http(s)"
            )));
        }
        if access_key_id.is_empty() || access_key_secret.is_empty() {
            return Err(Error::Config("aliyun needs an access key".into()));
        }
        let http = reqwest::Client::builder()
            .timeout(timeout)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|e| Error::Http(e.to_string()))?;
        Ok(Self {
            endpoint: endpoint.trim_end_matches('/').to_owned(),
            version: version.into(),
            access_key_id,
            access_key_secret,
            http,
        })
    }

    /// 调一个接口。`params` 是接口自己的参数，公共参数（AccessKeyId、签名、时间戳等）这里加。
    pub async fn call(
        &self,
        action: &str,
        params: &[(&str, String)],
    ) -> Result<serde_json::Value, Error> {
        let mut nonce = [0u8; 16];
        getrandom::fill(&mut nonce)
            .map_err(|_| Error::Config("no randomness for the nonce".into()))?;
        let mut all: Vec<(&str, String)> = vec![
            ("AccessKeyId", self.access_key_id.clone()),
            ("Action", action.to_owned()),
            ("Format", "JSON".into()),
            ("SignatureMethod", "HMAC-SHA1".into()),
            ("SignatureNonce", hex(&nonce)),
            ("SignatureVersion", "1.0".into()),
            (
                "Timestamp",
                chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
            ),
            ("Version", self.version.clone()),
        ];
        all.extend(params.iter().cloned());
        let signature = rpc_signature("POST", &all, &self.access_key_secret);
        all.push(("Signature", signature));
        let resp = self
            .http
            .post(format!("{}/", self.endpoint))
            .header("content-type", "application/x-www-form-urlencoded")
            .body(canonical_query(&all))
            .send()
            .await
            .map_err(|e| Error::Http(e.to_string()))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| Error::Http(e.to_string()))?;
        let reply: serde_json::Value = serde_json::from_str(&text).map_err(|_| {
            Error::Malformed(format!(
                "{status}: {}",
                text.chars().take(200).collect::<String>()
            ))
        })?;
        if status.is_success() {
            return Ok(reply);
        }
        let field = |k: &str| {
            reply[k]
                .as_str()
                .unwrap_or_default()
                .chars()
                .take(200)
                .collect::<String>()
        };
        Err(Error::Api {
            status: status.as_u16(),
            code: field("Code"),
            message: field("Message"),
        })
    }
}

/// 阿里云 RPC 签名（签名版本 1.0）。公开出来给测试里的假服务验签用。
pub fn rpc_signature(method: &str, params: &[(&str, String)], secret: &str) -> String {
    let to_sign = format!(
        "{method}&{}&{}",
        percent_encode("/"),
        percent_encode(&canonical_query(params))
    );
    let mut mac =
        Hmac::<Sha1>::new_from_slice(format!("{secret}&").as_bytes()).expect("any key length");
    mac.update(to_sign.as_bytes());
    let out: [u8; 20] = mac.finalize().into_bytes().into();
    STANDARD.encode(out)
}

/// 按名字排好序、编码过的 `名=值&名=值`。
fn canonical_query(params: &[(&str, String)]) -> String {
    let mut pairs: Vec<(String, String)> = params
        .iter()
        .map(|(k, v)| (percent_encode(k), percent_encode(v)))
        .collect();
    pairs.sort();
    pairs
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join("&")
}

/// RFC 3986 编码：除了字母、数字和 `-_.~`，每个字节都编码成 `%XX`（大写）。
pub fn percent_encode(s: &str) -> String {
    use fmt::Write;
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            let _ = write!(out, "%{b:02X}");
        }
    }
    out
}

/// 测试里的假服务用：把表单解成参数（`%XX` 解码）。
pub fn parse_form(body: &str) -> Vec<(String, String)> {
    fn decode(s: &str) -> String {
        let b = s.as_bytes();
        let mut out = Vec::with_capacity(b.len());
        let mut i = 0;
        while i < b.len() {
            if b[i] == b'%'
                && i + 2 < b.len()
                && let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16)
            {
                out.push(v);
                i += 3;
            } else {
                out.push(b[i]);
                i += 1;
            }
        }
        String::from_utf8_lossy(&out).into_owned()
    }
    body.split('&')
        .filter_map(|kv| kv.split_once('='))
        .map(|(k, v)| (decode(k), decode(v)))
        .collect()
}

fn hex(bytes: &[u8]) -> String {
    use fmt::Write;
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        let _ = write!(s, "{b:02x}");
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 阿里云文档里的 RPC 签名示例（ECS DescribeRegions，AccessKeySecret 是 testsecret）。
    #[test]
    fn signature_matches_the_aliyun_example() {
        let params: Vec<(&str, String)> = vec![
            ("Timestamp", "2016-02-23T12:46:24Z".into()),
            ("Format", "XML".into()),
            ("AccessKeyId", "testid".into()),
            ("Action", "DescribeRegions".into()),
            ("SignatureMethod", "HMAC-SHA1".into()),
            (
                "SignatureNonce",
                "3ee8c1b8-83d3-44af-a94f-4e0ad82fd6cf".into(),
            ),
            ("Version", "2014-05-26".into()),
            ("SignatureVersion", "1.0".into()),
        ];
        assert_eq!(
            rpc_signature("GET", &params, "testsecret"),
            "OLeaidS1JvxuMvnyHOwuJ+uX5qY="
        );
        assert_eq!(percent_encode("a b*~/中"), "a%20b%2A~%2F%E4%B8%AD");
        assert_eq!(
            parse_form("a=1%2B1&b=%E4%B8%AD&c"),
            [
                ("a".to_string(), "1+1".to_string()),
                ("b".to_string(), "中".to_string())
            ]
        );
    }

    #[test]
    fn clients_need_an_endpoint_and_a_key() {
        let secret = || Zeroizing::new("s".to_owned());
        let timeout = Duration::from_secs(1);
        assert!(RpcClient::new("kms.aliyuncs.com", "v", "id", secret(), timeout).is_err());
        assert!(RpcClient::new("https://x", "v", "", secret(), timeout).is_err());
        let c = RpcClient::new("https://x/", "v", "id", secret(), timeout).unwrap();
        assert_eq!(c.endpoint, "https://x");
        assert!(!format!("{c:?}").contains("\"s\""));
    }
}
