//! 设备中继的连接协议（WBS 14.1）。
//!
//! 电脑（macOS App 里的守护进程）主动连出到中继：`GET /v1/connect` 升级成 WebSocket，
//! 请求头 `Authorization: Bearer <访问令牌>`，令牌是这台电脑登录账号时拿到的（设备会话）。
//! 中继验签、核对会话，只接受 macOS 设备；一台电脑同时只保留最新的一个连接。
//!
//! 之后两边发 JSON 文本帧，`type` 字段区分种类：电脑发 [`ComputerFrame`]，中继发 [`RelayFrame`]。
//!
//! - **心跳**：中继每隔 `heartbeat_secs` 发一个 WebSocket ping；三个周期内没收到电脑的任何帧（含 pong）
//!   就断开、标记离线。电脑那边三个周期没收到 ping 也应该重连。
//! - **令牌**：访问令牌 15 分钟过期，电脑在过期前发 [`ComputerFrame::Auth`] 换上新令牌（刷新令牌的流程
//!   和手机一样），否则中继以 [`close::UNAUTHENTICATED`] 关闭，电脑刷新令牌后重连。
//! - **工具调用**：agent 用电脑上的工具时，平台按会话绑定（运行 → 实例 → 用户 → 用户自己在线的电脑）
//!   选目标，不取自 agent 的输出；中继转来 [`RelayFrame::Call`]，电脑回 [`ComputerFrame::CallResult`]。
//!   过了 `expires_at` 平台就不等了，电脑可以放弃；连接断了，转出去没回的调用判失败，不会重发
//!   （工具可能有副作用）。
//! - **消息**：手机和电脑之间的配对、审批、能力令牌（见 docs/pairing.md）经平台转发，收件方不在线时排队。
//!   中继投递 [`RelayFrame::Message`]，电脑处理完回 [`ComputerFrame::Ack`]；没回 ack 的下次连上再投一次，
//!   电脑按消息 id 去重。

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::domain::{
    DeviceCallId, DeviceId, DeviceMessage, DeviceMessageId, DeviceMessageKind, RunId,
};

/// 中继的关闭码。
pub mod close {
    /// 令牌过期、会话被吊销：刷新令牌后重连。
    pub const UNAUTHENTICATED: u16 = 4001;
    /// 账号被冻结（4.6）：不要重连。
    pub const ACCOUNT_FROZEN: u16 = 4003;
    /// 同一台电脑又连了一次，这个旧连接被顶掉：不要自动重连（两个进程会互相顶）。
    pub const REPLACED: u16 = 4009;
    /// 协议错误：帧太大、不是 JSON、不认识的种类。
    pub const PROTOCOL: u16 = 1008;
    /// 中继重启或下线：马上重连（会连到别的副本）。
    pub const RESTARTING: u16 = 1012;
}

/// 一帧最大多少字节（工具结果里可能有截图）。
pub const MAX_FRAME_BYTES: usize = 16 << 20;
/// 工具调用的参数最大多少字节（JSON）。
pub const MAX_CALL_ARGUMENTS_BYTES: usize = 4 << 20;
/// 工具结果最大多少字节（JSON）。
pub const MAX_CALL_RESULT_BYTES: usize = 12 << 20;
/// 转发的消息正文最大多少字节（JSON）。
pub const MAX_MESSAGE_BODY_BYTES: usize = 64 << 10;
/// 电脑报上来的工具最多多少个。
pub const MAX_TOOLS: usize = 256;

/// 电脑发给中继的帧。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ComputerFrame {
    /// 连上后报一下自己：现在能用的工具（随系统权限变化，变了再发一次）、App 版本。
    Hello {
        #[serde(default)]
        tools: Vec<String>,
        #[serde(default)]
        app_version: String,
    },
    /// 换上新的访问令牌（必须是同一个用户的同一台设备）。
    Auth { token: String },
    /// 工具调用的结果：MCP 的 content 数组；工具自己报错时 `is_error` 为真。
    #[serde(rename = "result")]
    CallResult {
        call: DeviceCallId,
        #[serde(default)]
        content: Vec<Value>,
        #[serde(default)]
        is_error: bool,
    },
    /// 这条消息收到并处理了，之后不再投递。
    Ack { message: DeviceMessageId },
    /// 发给手机的消息（配对确认、审批请求）。`ref` 原样带回 [`RelayFrame::Sent`] 或 [`RelayFrame::Error`]。
    Send {
        to: DeviceId,
        kind: DeviceMessageKind,
        body: Value,
        #[serde(default, rename = "ref", skip_serializing_if = "Option::is_none")]
        reference: Option<String>,
    },
}

/// 中继发给电脑的帧。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RelayFrame {
    /// 连上了：这台电脑的设备 id、心跳间隔。
    Welcome {
        device: DeviceId,
        heartbeat_secs: u64,
    },
    /// agent 要用电脑上的工具。过了 `expires_at` 平台就不等结果了。
    Call {
        id: DeviceCallId,
        tool: String,
        arguments: Value,
        run: Option<RunId>,
        expires_at: DateTime<Utc>,
    },
    /// 手机发来的消息。处理完回 [`ComputerFrame::Ack`]。
    Message { message: DeviceMessage },
    /// [`ComputerFrame::Send`] 的消息存下了（手机不在线时排队）。
    Sent {
        id: DeviceMessageId,
        #[serde(default, rename = "ref", skip_serializing_if = "Option::is_none")]
        reference: Option<String>,
    },
    /// 某一帧没处理成（连接不断）。`code`：`invalid`（内容不对）、`not_found`（收件设备不存在或不是对面那种设备）、
    /// `too_large`、`internal`。
    Error {
        #[serde(default, rename = "ref", skip_serializing_if = "Option::is_none")]
        reference: Option<String>,
        code: String,
        message: String,
    },
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn frames_are_tagged_json() {
        let call = DeviceCallId::new();
        let f: ComputerFrame = serde_json::from_value(json!({
            "type": "result", "call": call, "content": [{"type": "text", "text": "ok"}]
        }))
        .unwrap();
        assert_eq!(
            f,
            ComputerFrame::CallResult {
                call,
                content: vec![json!({"type": "text", "text": "ok"})],
                is_error: false
            }
        );
        let hello: ComputerFrame = serde_json::from_str(r#"{"type":"hello"}"#).unwrap();
        assert_eq!(
            hello,
            ComputerFrame::Hello {
                tools: vec![],
                app_version: String::new()
            }
        );
        let to = DeviceId::new();
        let send: ComputerFrame = serde_json::from_value(json!({
            "type": "send", "to": to, "kind": "approval_request", "body": {"x": 1}, "ref": "r1"
        }))
        .unwrap();
        assert!(matches!(
            send,
            ComputerFrame::Send { kind: DeviceMessageKind::ApprovalRequest, reference: Some(ref r), .. } if r == "r1"
        ));
        assert!(serde_json::from_str::<ComputerFrame>(r#"{"type":"bogus"}"#).is_err());

        let sent = serde_json::to_value(RelayFrame::Sent {
            id: DeviceMessageId::new(),
            reference: None,
        })
        .unwrap();
        assert_eq!(sent["type"], "sent");
        assert!(sent.get("ref").is_none());
        let welcome = serde_json::to_value(RelayFrame::Welcome {
            device: to,
            heartbeat_secs: 20,
        })
        .unwrap();
        assert_eq!(
            welcome,
            json!({"type": "welcome", "device": to, "heartbeat_secs": 20})
        );
    }
}
