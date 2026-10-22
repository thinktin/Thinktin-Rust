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
pub mod fcm;
pub mod filter;
pub mod im;
pub mod jpush;

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
    /// 电脑上的高危操作请手机批准（14.2）：批准和拒绝都要打开 App 用私钥签名，通知上没有按钮。
    ComputerApproval,
    /// agent 请用户往保险箱里填账号密码（10.7，目标里有 `vault_request_id`）：运行等着，高优先级。
    VaultRequest,
    /// agent 改了计划、等用户确认（10.7，目标里有 `plan_id`）。
    PlanConfirm,
    /// 其他提醒（`subtype` 说是哪一种）。
    Info,
}

impl PushKind {
    /// 收件箱里记的种类。
    pub fn as_str(self) -> &'static str {
        match self {
            Self::RunFinished => "run_finished",
            Self::RunFailed => "run_failed",
            Self::Approval => "approval",
            Self::ComputerApproval => "computer_approval",
            Self::VaultRequest => "vault_request",
            Self::PlanConfirm => "plan_confirm",
            Self::Info => "info",
        }
    }

    /// iOS 通知的 category，App 里注册同名的操作按钮。
    pub fn category(self) -> &'static str {
        match self {
            Self::RunFinished => "RUN_FINISHED",
            Self::RunFailed => "RUN_FAILED",
            Self::Approval => "APPROVAL",
            Self::ComputerApproval => "COMPUTER_APPROVAL",
            Self::VaultRequest => "VAULT_REQUEST",
            Self::PlanConfirm => "PLAN_CONFIRM",
            Self::Info => "INFO",
        }
    }

    /// 等用户批准的。
    pub fn is_approval(self) -> bool {
        matches!(self, Self::Approval | Self::ComputerApproval)
    }

    /// 运行停下来等用户（审批、填保险箱）：iOS 上是 time-sensitive，Android 走审批的通知渠道、高优先级。
    pub fn waits_for_user(self) -> bool {
        self.is_approval() || self == Self::VaultRequest
    }
}

/// 没给有效期的推送在推送服务那里最多等多久（手机关机、没信号时先存着，开机后送到）。各家推送服务都只给一个
/// 应用留最后一条，所以不会攒一堆旧通知；收件箱里一直都在。
pub const DEFAULT_TTL: Duration = Duration::from_secs(24 * 3600);

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
    /// 过了这个时间就不必再送达（审批超时之后的审批通知没有意义）。没有的按 [`DEFAULT_TTL`]。
    pub ttl: Option<Duration>,
    /// 正文是 agent 生成的：系统通知里要带显式标识（16.3）。
    #[serde(default)]
    pub ai_generated: bool,
    /// 收件人的语言（1.6）：标题、正文已经按它生成，显式标识也按它显示。
    #[serde(default)]
    pub locale: proto::domain::Locale,
    /// 是哪一种提醒（[`proto::domain::notice_subtype`]，运行在等什么时是 `wait_code`）：App 据此跳转、刷新。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subtype: Option<String>,
    /// 应用图标的角标（10.7）：收件人收件箱的未读数，投递时才算（出箱里排着的不带）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub badge: Option<u32>,
}

impl PushMessage {
    /// 系统通知里显示的正文：agent 生成的加上“AI 生成”标识（按收件人的语言）。
    pub fn display_body(&self) -> String {
        if !self.ai_generated {
            return self.body.clone();
        }
        let label = proto::labels::explicit_label(self.locale);
        match self.locale {
            proto::domain::Locale::ZhCn => format!("【{label}】{}", self.body),
            proto::domain::Locale::En => format!("[{label}] {}", self.body),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushTarget {
    pub instance_id: Option<String>,
    pub run_id: Option<String>,
    pub approval_id: Option<String>,
    pub plan_id: Option<String>,
    pub inbox_id: Option<String>,
    /// 保险箱请求（10.7，`thinktin://vault/request/{id}`）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vault_request_id: Option<String>,
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

/// 实时活动（10.6，iOS 的灵动岛、锁屏）的一次推送。
#[derive(Debug, Clone, PartialEq)]
pub struct LivePush {
    pub event: LiveEvent,
    /// 实时活动的动态内容（App 里 `ActivityAttributes.ContentState` 的 JSON）。
    pub content_state: serde_json::Value,
    /// 状态变了（开启、等审批、结束）：立刻送达；只是进度变了：低优先级（苹果对高优先级的更新有预算）。
    pub urgent: bool,
    /// 远程开启时的类型名（App 里 `ActivityAttributes` 的类型名）和静态属性。
    pub attributes: Option<(String, serde_json::Value)>,
    /// 远程开启时的提醒（标题、正文）。
    pub alert: Option<(String, String)>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LiveEvent {
    Start,
    Update,
    End,
}

impl LiveEvent {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Start => "start",
            Self::Update => "update",
            Self::End => "end",
        }
    }
}

/// 发实时活动推送的通道（APNs）。
#[async_trait]
pub trait LiveActivityChannel: Send + Sync {
    /// `token`：更新、结束发到这个实时活动的推送令牌，开启发到设备的推送开启令牌。
    async fn send_live(&self, token: &str, push: &LivePush) -> PushOutcome;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kinds_serialize_as_their_names() {
        for kind in [
            PushKind::RunFinished,
            PushKind::RunFailed,
            PushKind::Approval,
            PushKind::ComputerApproval,
            PushKind::VaultRequest,
            PushKind::PlanConfirm,
            PushKind::Info,
        ] {
            assert_eq!(
                serde_json::to_value(kind).unwrap(),
                serde_json::json!(kind.as_str())
            );
        }
        assert!(PushKind::ComputerApproval.is_approval());
        assert!(!PushKind::RunFailed.is_approval());
        assert!(PushKind::VaultRequest.waits_for_user() && !PushKind::VaultRequest.is_approval());
        assert!(!PushKind::PlanConfirm.waits_for_user());
        assert_eq!(PushKind::VaultRequest.category(), "VAULT_REQUEST");
        assert_eq!(PushKind::PlanConfirm.category(), "PLAN_CONFIRM");
    }
}
