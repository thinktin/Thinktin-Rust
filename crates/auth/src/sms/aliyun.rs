//! 阿里云短信服务（Dysmsapi 2017-05-25 的 SendSms）。
//!
//! - 国内号码（+86）用国内的签名和验证码模板；其他国家和地区的号码用国际 / 港澳台的签名和模板，
//!   没配就不发（报错，由登录接口转成“发送失败”）。
//! - 请求按阿里云的 RPC 签名机制（HMAC-SHA1，签名版本 1.0）签名，POST 表单。
//! - 返回 `Code = "OK"` 才算发出。限流（`isv.BUSINESS_LIMIT_CONTROL`）、号码不对、余额不足等原样报给调用方：
//!   报错里只有阿里云的错误码和说明，不带验证码。

use std::fmt;
use std::time::Duration;

use async_trait::async_trait;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use hmac::{Hmac, KeyInit, Mac};
use serde::Deserialize;
use sha1::Sha1;
use zeroize::Zeroizing;

use super::{CodePurpose, SmsError, SmsSender};

/// 默认的接口地址（中国站；国际站账号用 `https://dysmsapi.ap-southeast-1.aliyuncs.com`）。
pub const ENDPOINT: &str = "https://dysmsapi.aliyuncs.com";

/// 阿里云短信的配置。签名和模板在阿里云控制台申请，模板里的变量是 `${code}`。
pub struct AliyunSmsConfig {
    /// [`ENDPOINT`]（测试时可以是本地地址）。
    pub endpoint: String,
    pub access_key_id: String,
    pub access_key_secret: Zeroizing<String>,
    /// 国内短信的签名，比如 `ThinkTin`。
    pub sign_name: String,
    /// 国内验证码模板的 code（`SMS_` 开头）。
    pub template_code: String,
    /// 国际 / 港澳台消息的签名和模板；不配就只能发国内号码。
    pub international: Option<(String, String)>,
    /// 单次请求的超时。
    pub timeout: Duration,
}

impl fmt::Debug for AliyunSmsConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AliyunSmsConfig")
            .field("endpoint", &self.endpoint)
            .field("access_key_id", &self.access_key_id)
            .field("access_key_secret", &"***")
            .field("sign_name", &self.sign_name)
            .field("template_code", &self.template_code)
            .field("international", &self.international)
            .finish()
    }
}

#[derive(Debug)]
pub struct AliyunSms {
    cfg: AliyunSmsConfig,
    http: reqwest::Client,
}

#[derive(Deserialize)]
struct Reply {
    #[serde(rename = "Code", default)]
    code: String,
    #[serde(rename = "Message", default)]
    message: String,
}

impl AliyunSms {
    pub fn new(cfg: AliyunSmsConfig) -> Result<Self, SmsError> {
        if cfg.access_key_id.is_empty() || cfg.access_key_secret.is_empty() {
            return Err(SmsError("aliyun sms needs an access key".into()));
        }
        if cfg.sign_name.is_empty() || !cfg.template_code.starts_with("SMS_") {
            return Err(SmsError(
                "aliyun sms needs a sign name and an SMS_ template code".into(),
            ));
        }
        let http = reqwest::Client::builder()
            .timeout(cfg.timeout)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|e| SmsError(format!("http client: {e}")))?;
        Ok(Self { cfg, http })
    }

    /// 号码、签名、模板：国内号码去掉 +86；其他的去掉 +，用国际模板。
    fn route(&self, phone: &str) -> Result<(String, &str, &str), SmsError> {
        if let Some(number) = phone.strip_prefix("+86") {
            return Ok((
                number.to_owned(),
                self.cfg.sign_name.as_str(),
                self.cfg.template_code.as_str(),
            ));
        }
        let Some((sign, template)) = &self.cfg.international else {
            return Err(SmsError(
                "no international SMS template is configured for numbers outside mainland China"
                    .into(),
            ));
        };
        let number = phone.strip_prefix('+').unwrap_or(phone);
        Ok((number.to_owned(), sign.as_str(), template.as_str()))
    }
}

#[async_trait]
impl SmsSender for AliyunSms {
    async fn send_code(
        &self,
        phone: &str,
        code: &str,
        _purpose: CodePurpose,
    ) -> Result<(), SmsError> {
        let (number, sign, template) = self.route(phone)?;
        let mut nonce = [0u8; 16];
        getrandom::fill(&mut nonce).map_err(|_| SmsError("no randomness for the nonce".into()))?;
        let mut params: Vec<(&str, String)> = vec![
            ("AccessKeyId", self.cfg.access_key_id.clone()),
            ("Action", "SendSms".into()),
            ("Format", "JSON".into()),
            ("PhoneNumbers", number),
            ("RegionId", "cn-hangzhou".into()),
            ("SignName", sign.to_owned()),
            ("SignatureMethod", "HMAC-SHA1".into()),
            ("SignatureNonce", hex(&nonce)),
            ("SignatureVersion", "1.0".into()),
            ("TemplateCode", template.to_owned()),
            (
                "TemplateParam",
                serde_json::json!({ "code": code }).to_string(),
            ),
            (
                "Timestamp",
                chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
            ),
            ("Version", "2017-05-25".into()),
        ];
        let signature = rpc_signature("POST", &params, &self.cfg.access_key_secret);
        params.push(("Signature", signature));
        let resp = self
            .http
            .post(format!("{}/", self.cfg.endpoint.trim_end_matches('/')))
            .header("content-type", "application/x-www-form-urlencoded")
            .body(canonical_query(&params))
            .send()
            .await
            .map_err(|e| SmsError(format!("aliyun sms request failed: {e}")))?;
        let status = resp.status();
        let reply: Reply = resp
            .json()
            .await
            .map_err(|e| SmsError(format!("aliyun sms reply ({status}) is not json: {e}")))?;
        if reply.code == "OK" {
            Ok(())
        } else {
            Err(SmsError(format!(
                "aliyun sms {}: {}",
                reply.code,
                reply.message.chars().take(200).collect::<String>()
            )))
        }
    }
}

/// 阿里云 RPC 签名（签名版本 1.0）：参数按名字排序、按 RFC 3986 编码拼起来，
/// 前面加上请求方法和编码过的 `/`，用 `AccessKeySecret&` 做 HMAC-SHA1，再 Base64。
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
fn percent_encode(s: &str) -> String {
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
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};

    use axum::extract::State;

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
    }

    #[derive(Default)]
    struct Fake {
        sent: Mutex<Vec<HashMap<String, String>>>,
    }

    fn decode(s: &str) -> String {
        let b = s.as_bytes();
        let mut out = Vec::new();
        let mut i = 0;
        while i < b.len() {
            if b[i] == b'%' && i + 2 < b.len() {
                out.push(u8::from_str_radix(&s[i + 1..i + 3], 16).unwrap());
                i += 3;
            } else {
                out.push(b[i]);
                i += 1;
            }
        }
        String::from_utf8(out).unwrap()
    }

    /// 假的阿里云：验签名，记下参数；尾号 0000 的号码按限流拒绝。
    async fn handler(State(fake): State<Arc<Fake>>, body: String) -> axum::Json<serde_json::Value> {
        let params: HashMap<String, String> = body
            .split('&')
            .filter_map(|kv| kv.split_once('='))
            .map(|(k, v)| (decode(k), decode(v)))
            .collect();
        let signed: Vec<(&str, String)> = params
            .iter()
            .filter(|(k, _)| k.as_str() != "Signature")
            .map(|(k, v)| (k.as_str(), v.clone()))
            .collect();
        if rpc_signature("POST", &signed, "key-secret") != params["Signature"] {
            return axum::Json(serde_json::json!({
                "Code": "SignatureDoesNotMatch", "Message": "Specified signature is not matched"
            }));
        }
        let limited = params["PhoneNumbers"].ends_with("0000");
        fake.sent.lock().unwrap().push(params);
        if limited {
            return axum::Json(serde_json::json!({
                "Code": "isv.BUSINESS_LIMIT_CONTROL", "Message": "触发小时级流控Permits:5"
            }));
        }
        axum::Json(serde_json::json!({ "Code": "OK", "Message": "OK", "BizId": "1" }))
    }

    async fn setup(secret: &str, international: bool) -> (AliyunSms, Arc<Fake>) {
        let fake = Arc::new(Fake::default());
        let app = axum::Router::new()
            .route("/", axum::routing::post(handler))
            .with_state(fake.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let sms = AliyunSms::new(AliyunSmsConfig {
            endpoint: format!("http://{addr}"),
            access_key_id: "key-id".into(),
            access_key_secret: Zeroizing::new(secret.into()),
            sign_name: "ThinkTin".into(),
            template_code: "SMS_100".into(),
            international: international.then(|| ("ThinkTin Global".into(), "SMS_200".into())),
            timeout: Duration::from_secs(5),
        })
        .unwrap();
        (sms, fake)
    }

    #[tokio::test]
    async fn codes_go_out_with_the_right_template() {
        let (sms, fake) = setup("key-secret", true).await;
        sms.send_code("+8613800138000", "123456", CodePurpose::Login)
            .await
            .unwrap();
        sms.send_code("+85291234567", "654321", CodePurpose::Login)
            .await
            .unwrap();
        let sent = fake.sent.lock().unwrap().clone();
        assert_eq!(sent.len(), 2);
        let pick = |p: &HashMap<String, String>| {
            [
                "PhoneNumbers",
                "SignName",
                "TemplateCode",
                "TemplateParam",
                "Action",
            ]
            .map(|k| p[k].clone())
        };
        assert_eq!(
            pick(&sent[0]),
            [
                "13800138000",
                "ThinkTin",
                "SMS_100",
                r#"{"code":"123456"}"#,
                "SendSms"
            ]
            .map(String::from)
        );
        assert_eq!(
            pick(&sent[1])[..3],
            ["85291234567", "ThinkTin Global", "SMS_200"].map(String::from)
        );

        // 限流：报阿里云的错误码，不带验证码。
        let err = sms
            .send_code("+8613900000000", "777888", CodePurpose::Login)
            .await
            .unwrap_err();
        assert!(err.0.contains("isv.BUSINESS_LIMIT_CONTROL"), "{err}");
        assert!(!err.0.contains("777888"), "{err}");
    }

    #[tokio::test]
    async fn misconfiguration_is_reported() {
        // 没配国际模板：境外号码不发。
        let (sms, fake) = setup("key-secret", false).await;
        let err = sms
            .send_code("+14155550100", "123456", CodePurpose::Login)
            .await
            .unwrap_err();
        assert!(err.0.contains("international"), "{err}");
        assert!(fake.sent.lock().unwrap().is_empty());
        // 密钥不对：签名对不上。
        let (sms, _) = setup("wrong-secret", false).await;
        let err = sms
            .send_code("+8613800138000", "123456", CodePurpose::Login)
            .await
            .unwrap_err();
        assert!(err.0.contains("SignatureDoesNotMatch"), "{err}");
        assert!(!format!("{sms:?}").contains("wrong-secret"));
        // 模板 code 不对。
        let bad = AliyunSms::new(AliyunSmsConfig {
            endpoint: ENDPOINT.into(),
            access_key_id: "id".into(),
            access_key_secret: Zeroizing::new("s".into()),
            sign_name: "ThinkTin".into(),
            template_code: "100".into(),
            international: None,
            timeout: Duration::from_secs(5),
        });
        assert!(bad.is_err());
    }
}
