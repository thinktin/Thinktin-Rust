//! 阿里云短信服务（Dysmsapi 2017-05-25 的 SendSms）。
//!
//! - 国内号码（+86）用国内的签名和验证码模板；其他国家和地区的号码用国际 / 港澳台的签名和模板，
//!   没配就不发（报错，由登录接口转成“发送失败”）。
//! - 签名、公共参数由 [`aliyun::RpcClient`] 处理（RPC 签名，HMAC-SHA1）。
//! - 返回 `Code = "OK"` 才算发出。限流（`isv.BUSINESS_LIMIT_CONTROL`）、号码不对、余额不足等原样报给调用方：
//!   报错里只有阿里云的错误码和说明，不带验证码。

use std::fmt;
use std::time::Duration;

use aliyun::RpcClient;
use async_trait::async_trait;
use zeroize::Zeroizing;

use super::{CodePurpose, SmsError, SmsSender};

/// 默认的接口地址（中国站；国际站账号用 `https://dysmsapi.ap-southeast-1.aliyuncs.com`）。
pub const ENDPOINT: &str = "https://dysmsapi.aliyuncs.com";
/// 短信接口的版本。
pub const VERSION: &str = "2017-05-25";

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
    client: RpcClient,
    sign_name: String,
    template_code: String,
    international: Option<(String, String)>,
}

impl AliyunSms {
    pub fn new(cfg: AliyunSmsConfig) -> Result<Self, SmsError> {
        if cfg.sign_name.is_empty() || !cfg.template_code.starts_with("SMS_") {
            return Err(SmsError(
                "aliyun sms needs a sign name and an SMS_ template code".into(),
            ));
        }
        let client = RpcClient::new(
            cfg.endpoint,
            VERSION,
            cfg.access_key_id,
            cfg.access_key_secret,
            cfg.timeout,
        )
        .map_err(|e| SmsError(e.to_string()))?;
        Ok(Self {
            client,
            sign_name: cfg.sign_name,
            template_code: cfg.template_code,
            international: cfg.international,
        })
    }

    /// 号码、签名、模板：国内号码去掉 +86；其他的去掉 +，用国际模板。
    fn route(&self, phone: &str) -> Result<(String, &str, &str), SmsError> {
        if let Some(number) = phone.strip_prefix("+86") {
            return Ok((
                number.to_owned(),
                self.sign_name.as_str(),
                self.template_code.as_str(),
            ));
        }
        let Some((sign, template)) = &self.international else {
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
        let reply = self
            .client
            .call(
                "SendSms",
                &[
                    ("PhoneNumbers", number),
                    ("RegionId", "cn-hangzhou".into()),
                    ("SignName", sign.to_owned()),
                    ("TemplateCode", template.to_owned()),
                    (
                        "TemplateParam",
                        serde_json::json!({ "code": code }).to_string(),
                    ),
                ],
            )
            .await
            .map_err(|e| SmsError(format!("sms: {e}")))?;
        match reply["Code"].as_str() {
            Some("OK") => Ok(()),
            other => Err(SmsError(format!(
                "aliyun sms {}: {}",
                other.unwrap_or("no code"),
                reply["Message"]
                    .as_str()
                    .unwrap_or_default()
                    .chars()
                    .take(200)
                    .collect::<String>()
            ))),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};

    use aliyun::{parse_form, rpc_signature};
    use axum::extract::State;

    use super::*;

    #[derive(Default)]
    struct Fake {
        sent: Mutex<Vec<HashMap<String, String>>>,
    }

    /// 假的阿里云：验签名，记下参数；尾号 0000 的号码按限流拒绝。
    async fn handler(State(fake): State<Arc<Fake>>, body: String) -> axum::Json<serde_json::Value> {
        let params: HashMap<String, String> = parse_form(&body).into_iter().collect();
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
                "Version",
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
                "SendSms",
                VERSION
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
        // 模板 code 不对、没有 AccessKey。
        let config = |template: &str, key: &str| AliyunSmsConfig {
            endpoint: ENDPOINT.into(),
            access_key_id: key.into(),
            access_key_secret: Zeroizing::new("s".into()),
            sign_name: "ThinkTin".into(),
            template_code: template.into(),
            international: None,
            timeout: Duration::from_secs(5),
        };
        assert!(AliyunSms::new(config("100", "id")).is_err());
        assert!(AliyunSms::new(config("SMS_1", "")).is_err());
        assert!(AliyunSms::new(config("SMS_1", "id")).is_ok());
    }
}
