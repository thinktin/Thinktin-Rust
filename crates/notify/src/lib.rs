//! 通知（架构方案 8.3，WBS 10.x）：APNs、国内 Android 厂商推送、FCM、IM 渠道。
//!
//! 推送只放标题和摘要，不放对话正文（8.3）。审批类推送用可操作通知，但“批准”必须打开 App、
//! 生物识别解锁私钥签名后才算数，通知上只能直接“拒绝”。
//!
//! 每个通道实现 [`PushChannel`]；出箱投递器（7.5）按设备的推送令牌选通道发送，按 [`PushOutcome`] 处理结果。

use std::time::Duration;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

pub mod apns;

/// 推送的种类，决定客户端怎么展示（iOS 的 category、Android 的通知渠道）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PushKind {
    /// 运行完成。
    RunFinished,
    /// 运行失败或需要用户处理（key 失效、额度用完）。
    RunFailed,
    /// 需要审批：可操作通知，只能直接“拒绝”。
    Approval,
    /// 其他提醒。
    Info,
}

impl PushKind {
    /// 收件箱里记的种类。
    pub fn as_str(self) -> &'static str {
        match self {
            Self::RunFinished => "run_finished",
            Self::RunFailed => "run_failed",
            Self::Approval => "approval",
            Self::Info => "info",
        }
    }

    /// iOS 通知的 category，App 里注册同名的操作按钮。
    pub fn category(self) -> &'static str {
        match self {
            Self::RunFinished => "RUN_FINISHED",
            Self::RunFailed => "RUN_FAILED",
            Self::Approval => "APPROVAL",
            Self::Info => "INFO",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushMessage {
    pub kind: PushKind,
    /// 标题，比如实例名。
    pub title: String,
    /// 摘要，一两句话，不含对话正文。
    pub body: String,
    /// 同一个运行的通知归成一组。
    pub thread_id: Option<String>,
    /// 同一个 id 的新通知替换旧的（比如审批状态变化）。
    pub collapse_id: Option<String>,
    /// 客户端打开通知后要跳转的对象（只放 id，不放内容）。
    pub target: PushTarget,
    /// 过了这个时间就不必再送达（审批超时之后的审批通知没有意义）。
    pub ttl: Option<Duration>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushTarget {
    pub instance_id: Option<String>,
    pub run_id: Option<String>,
    pub approval_id: Option<String>,
    pub plan_id: Option<String>,
    pub inbox_id: Option<String>,
}

/// 发送结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PushOutcome {
    Delivered {
        id: Option<String>,
    },
    /// 推送令牌已失效（App 被卸载、令牌被重置）：从库里删掉，不再重试。
    InvalidToken {
        reason: String,
    },
    /// 暂时失败：按退避重试。
    Retry {
        after: Option<Duration>,
        reason: String,
    },
    /// 请求本身有问题（载荷过大、主题不对）：记下来，不重试。
    Rejected {
        reason: String,
    },
}

#[async_trait]
pub trait PushChannel: Send + Sync {
    fn name(&self) -> &'static str;
    async fn send(&self, device_token: &str, message: &PushMessage) -> PushOutcome;
}

/// 测试用：记下所有消息，按预设返回结果。
#[derive(Default)]
pub struct RecordingChannel {
    pub sent: std::sync::Mutex<Vec<(String, PushMessage)>>,
}

#[async_trait]
impl PushChannel for RecordingChannel {
    fn name(&self) -> &'static str {
        "recording"
    }

    async fn send(&self, device_token: &str, message: &PushMessage) -> PushOutcome {
        self.sent
            .lock()
            .unwrap()
            .push((device_token.to_owned(), message.clone()));
        PushOutcome::Delivered { id: None }
    }
}
