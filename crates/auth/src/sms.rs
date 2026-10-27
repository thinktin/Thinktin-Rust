//! 短信验证码的发送通道（可替换）：阿里云短信服务（[`aliyun`]）；本地开发打印到标准错误；测试记下来。

use std::sync::Mutex;

use async_trait::async_trait;

pub mod aliyun;

/// 验证码的用途：哈希里带着它，一种用途的码不能拿去做另一件事。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CodePurpose {
    Login,
    DeleteAccount,
    ChangePhone,
}

impl CodePurpose {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Login => "login",
            Self::DeleteAccount => "delete_account",
            Self::ChangePhone => "change_phone",
        }
    }
}

#[derive(Debug, thiserror::Error)]
#[error("sms delivery failed: {0}")]
pub struct SmsError(pub String);

#[async_trait]
pub trait SmsSender: Send + Sync {
    /// 发送验证码。`phone` 是 E.164。实现不得把验证码写进日志。
    async fn send_code(
        &self,
        phone: &str,
        code: &str,
        purpose: CodePurpose,
    ) -> Result<(), SmsError>;
}

/// 本地开发用：把验证码打印到标准错误。只能在开发环境显式启用。
pub struct DevConsoleSms;

#[async_trait]
impl SmsSender for DevConsoleSms {
    async fn send_code(
        &self,
        phone: &str,
        code: &str,
        purpose: CodePurpose,
    ) -> Result<(), SmsError> {
        eprintln!("[dev sms] {phone} {}: {code}", purpose.as_str());
        Ok(())
    }
}

/// 测试用：记下发出的验证码。
#[derive(Default)]
pub struct RecordingSms {
    sent: Mutex<Vec<(String, String, CodePurpose)>>,
}

impl RecordingSms {
    /// 发给某个号码的最后一个验证码。
    pub fn last_code(&self, phone: &str) -> Option<String> {
        self.sent
            .lock()
            .unwrap()
            .iter()
            .rev()
            .find(|(p, _, _)| p == phone)
            .map(|(_, c, _)| c.clone())
    }

    pub fn count(&self) -> usize {
        self.sent.lock().unwrap().len()
    }
}

#[async_trait]
impl SmsSender for RecordingSms {
    async fn send_code(
        &self,
        phone: &str,
        code: &str,
        purpose: CodePurpose,
    ) -> Result<(), SmsError> {
        self.sent
            .lock()
            .unwrap()
            .push((phone.to_owned(), code.to_owned(), purpose));
        Ok(())
    }
}
