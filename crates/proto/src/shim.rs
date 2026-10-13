//! 平台 ↔ agent-shim 的消息（架构方案 3.3）。
//!
//! 目前的传输是 stdio 上的 JSON Lines（`agent-shim serve`）：平台往 shim 的 stdin
//! 写 [`ShimCommand`]，从 stdout 读 [`EventEnvelope`]。以后改成连到编排服务的长连接时，
//! 消息体保持不变。

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// 消息格式版本。shim 在 [`ShimEvent::Ready`] 里报告，平台据此判断是否兼容。
pub const SHIM_PROTOCOL_VERSION: u32 = 1;

/// 平台发给 shim 的指令。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ShimCommand {
    /// 让 agent 执行一轮任务。同一实例同一时间只跑一轮，忙时再发会收到 [`ShimEvent::Error`]。
    Prompt { run_id: String, text: String },
    /// 取消正在执行的这一轮。
    Cancel { run_id: String },
    /// 用户对权限请求的决定。`option_id` 为空表示放弃作答（对应 ACP 的 `cancelled`）。
    PermissionDecision {
        request_id: String,
        option_id: Option<String>,
    },
    /// 让 agent 落盘后退出，沙箱随后会被暂停或销毁。
    Shutdown,
}

/// shim 发出的每条事件都带单调递增的序号，平台按序号写入运行日志、做续传（4.8）。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EventEnvelope {
    pub seq: u64,
    /// Unix 毫秒时间戳。
    pub ts_ms: u64,
    #[serde(flatten)]
    pub event: ShimEvent,
}

/// shim 上报给平台的事件。
///
/// 和某一轮任务相关的事件带 `run_id`；agent 在两轮之间主动发来的更新没有 `run_id`。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ShimEvent {
    /// agent 已启动、会话已就绪，可以接收 [`ShimCommand::Prompt`]。
    /// 每次（重新）启动 agent 都会发一次。
    Ready {
        protocol_version: u32,
        agent_id: String,
        harness: String,
        /// agent 在握手时报告的名称和版本。
        agent_info: Option<Value>,
        session_id: String,
        /// 是否接回了之前的会话（`session/resume` 或 `session/load`）。
        session_restored: bool,
    },
    /// 之前的会话接不回来，开了新会话。编排服务需要补发续跑简报（4.5）。
    SessionLost {
        previous_session_id: String,
        reason: String,
    },
    /// agent 进程退出。`will_restart` 为真时 shim 会按退避策略重启它。
    AgentExited {
        code: Option<i32>,
        will_restart: bool,
        restarts: u32,
    },
    MessageChunk {
        run_id: Option<String>,
        text: String,
    },
    ThoughtChunk {
        run_id: Option<String>,
        text: String,
    },
    ToolCall {
        run_id: Option<String>,
        tool_call_id: String,
        title: Option<String>,
        kind: Option<String>,
        status: Option<String>,
        /// agent 发来的原始内容（ACP `tool_call`），平台展示详情时使用。
        raw: Value,
    },
    ToolCallUpdate {
        run_id: Option<String>,
        tool_call_id: String,
        status: Option<String>,
        raw: Value,
    },
    Plan {
        run_id: Option<String>,
        entries: Value,
    },
    /// 上下文占用、花费等用量信息（ACP `usage_update` 或一轮结束时的 `usage`）。
    Usage { run_id: Option<String>, raw: Value },
    /// agent 请求权限。按预授权策略能直接决定的，紧接着会有 [`ShimEvent::PermissionResolved`]；
    /// 否则等平台发回 [`ShimCommand::PermissionDecision`]。
    PermissionRequested {
        run_id: Option<String>,
        request_id: String,
        title: Option<String>,
        options: Vec<PermissionOption>,
        tool_call: Value,
    },
    PermissionResolved {
        run_id: Option<String>,
        request_id: String,
        /// 选中的选项；为空表示放弃作答。
        option_id: Option<String>,
        by: DecisionSource,
    },
    /// 没有单独建模的会话更新（模式切换、命令列表、各家扩展等），原样透传。
    AgentUpdate {
        run_id: Option<String>,
        kind: String,
        raw: Value,
    },
    /// 一轮任务结束。
    TurnEnded {
        run_id: String,
        stop_reason: StopReason,
    },
    Error {
        run_id: Option<String>,
        message: String,
    },
}

/// 一轮任务结束的原因，取值同 ACP 的 `StopReason`。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StopReason {
    EndTurn,
    MaxTokens,
    MaxTurnRequests,
    Refusal,
    Cancelled,
    /// agent 返回了本协议版本不认识的原因。
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PermissionOption {
    pub option_id: String,
    pub name: String,
    pub kind: PermissionKind,
}

/// 取值同 ACP 的 `PermissionOptionKind`。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PermissionKind {
    AllowOnce,
    AllowAlways,
    RejectOnce,
    RejectAlways,
    #[serde(other)]
    Unknown,
}

impl PermissionKind {
    pub fn is_allow(self) -> bool {
        matches!(self, Self::AllowOnce | Self::AllowAlways)
    }

    pub fn is_reject(self) -> bool {
        matches!(self, Self::RejectOnce | Self::RejectAlways)
    }
}

/// 权限请求是谁决定的。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DecisionSource {
    /// 按计划的预授权范围自动决定（4.7）。
    Policy,
    /// 用户在 App 里决定。
    User,
    /// 等待用户决定超时（4.7）。
    Timeout,
    /// 这一轮被取消，未决的请求一并作废。
    Cancelled,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn command_wire_format() {
        let cmd: ShimCommand =
            serde_json::from_value(json!({"type": "prompt", "run_id": "r1", "text": "hi"}))
                .unwrap();
        assert_eq!(
            cmd,
            ShimCommand::Prompt {
                run_id: "r1".into(),
                text: "hi".into()
            }
        );
        let cmd: ShimCommand = serde_json::from_value(
            json!({"type": "permission_decision", "request_id": "p1", "option_id": null}),
        )
        .unwrap();
        assert_eq!(
            cmd,
            ShimCommand::PermissionDecision {
                request_id: "p1".into(),
                option_id: None
            }
        );
    }

    #[test]
    fn envelope_flattens_event() {
        let env = EventEnvelope {
            seq: 3,
            ts_ms: 10,
            event: ShimEvent::TurnEnded {
                run_id: "r1".into(),
                stop_reason: StopReason::EndTurn,
            },
        };
        let v = serde_json::to_value(&env).unwrap();
        assert_eq!(
            v,
            json!({"seq": 3, "ts_ms": 10, "type": "turn_ended", "run_id": "r1", "stop_reason": "end_turn"})
        );
        let back: EventEnvelope = serde_json::from_value(v).unwrap();
        assert_eq!(back, env);
    }

    #[test]
    fn unknown_enum_values_are_tolerated() {
        let r: StopReason = serde_json::from_value(json!("something_new")).unwrap();
        assert_eq!(r, StopReason::Unknown);
        let k: PermissionKind = serde_json::from_value(json!("allow_forever")).unwrap();
        assert_eq!(k, PermissionKind::Unknown);
        assert!(!k.is_allow() && !k.is_reject());
    }
}
