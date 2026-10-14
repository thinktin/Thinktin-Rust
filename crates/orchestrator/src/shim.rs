//! 编排服务和沙箱里的 agent-shim 之间的连接，以及平台工具的接口。
//!
//! 执行器只依赖 [`ShimConnector`]：生产环境在沙箱里启动 `agent-shim serve`（见 [`crate::exec`]），
//! 测试用进程内的替身。

use std::time::Duration;

use async_trait::async_trait;
use proto::domain::{GrantId, InstanceId, PlanId, RunId, UserId};
use proto::shim::{PlatformTool, ShimCommand, ShimEvent};
use serde_json::Value;
use store::InstanceRuntime;
use tokio::sync::mpsc;

/// 启动 shim 需要的东西。
pub struct ShimLaunch {
    pub instance: InstanceRuntime,
    pub run: RunId,
    /// 沙箱令牌：只经环境变量交给 shim，不进命令行、不进日志。
    pub token: String,
    /// 预授权的工具种类（ACP tool kind）。
    pub allow_tools: Vec<String>,
    /// 超出预授权的请求交给用户，最多等这么久。
    pub ask_timeout: Duration,
    pub platform_tools: Vec<PlatformTool>,
}

impl std::fmt::Debug for ShimLaunch {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ShimLaunch")
            .field("instance", &self.instance.id)
            .field("run", &self.run)
            .field("allow_tools", &self.allow_tools)
            .finish_non_exhaustive()
    }
}

/// 一个运行中的 shim：发指令、收事件。事件通道关闭表示 shim 退出了。
pub struct ShimSession {
    pub commands: mpsc::Sender<ShimCommand>,
    pub events: mpsc::Receiver<ShimEvent>,
    pub process: Box<dyn ShimProcess>,
}

#[async_trait]
pub trait ShimProcess: Send + Sync {
    /// 等进程退出。
    async fn wait(&mut self);
    /// 强行结束。
    async fn kill(&mut self);
}

#[derive(Debug, thiserror::Error)]
#[error("cannot start agent-shim: {0}")]
pub struct ConnectError(pub String);

#[async_trait]
pub trait ShimConnector: Send + Sync {
    async fn start(&self, launch: &ShimLaunch) -> Result<ShimSession, ConnectError>;
}

/// 平台工具调用的上下文：谁的哪个运行在调。
#[derive(Debug, Clone, Copy)]
pub struct ToolContext {
    pub user: UserId,
    pub instance: InstanceId,
    pub run: RunId,
    pub plan: Option<PlanId>,
    pub grant: GrantId,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ToolOutput {
    /// MCP 的 content 数组。
    pub content: Vec<Value>,
    pub is_error: bool,
}

impl ToolOutput {
    pub fn text(text: impl Into<String>) -> Self {
        Self {
            content: vec![serde_json::json!({ "type": "text", "text": text.into() })],
            is_error: false,
        }
    }

    pub fn error(text: impl Into<String>) -> Self {
        Self {
            is_error: true,
            ..Self::text(text)
        }
    }
}

/// 平台提供给 agent 的工具（thinktin.schedule 等，WBS 7.8）。
#[async_trait]
pub trait PlatformTools: Send + Sync {
    fn tools(&self) -> Vec<PlatformTool>;
    async fn call(&self, ctx: &ToolContext, name: &str, arguments: &Value) -> ToolOutput;
}

/// 不提供平台工具。
pub struct NoPlatformTools;

#[async_trait]
impl PlatformTools for NoPlatformTools {
    fn tools(&self) -> Vec<PlatformTool> {
        Vec::new()
    }

    async fn call(&self, _ctx: &ToolContext, name: &str, _arguments: &Value) -> ToolOutput {
        ToolOutput::error(format!("unknown platform tool {name}"))
    }
}

/// 事件在运行日志里的 kind：`agent.<shim 事件类型>`。
pub fn event_kind(ev: &ShimEvent) -> &'static str {
    match ev {
        ShimEvent::Ready { .. } => "agent.ready",
        ShimEvent::SessionLost { .. } => "agent.session_lost",
        ShimEvent::AgentExited { .. } => "agent.exited",
        ShimEvent::MessageChunk { .. } => "agent.message",
        ShimEvent::ThoughtChunk { .. } => "agent.thought",
        ShimEvent::ToolCall { .. } => "agent.tool_call",
        ShimEvent::ToolCallUpdate { .. } => "agent.tool_call_update",
        ShimEvent::Plan { .. } => "agent.plan",
        ShimEvent::Usage { .. } => "agent.usage",
        ShimEvent::PermissionRequested { .. } => "agent.permission_requested",
        ShimEvent::PermissionResolved { .. } => "agent.permission_resolved",
        ShimEvent::AgentUpdate { .. } => "agent.update",
        ShimEvent::TurnStarted { .. } => "agent.turn_started",
        ShimEvent::PlatformToolCall { .. } => "agent.platform_tool_call",
        ShimEvent::TurnEnded { .. } => "agent.turn_ended",
        ShimEvent::Error { .. } => "agent.error",
    }
}
