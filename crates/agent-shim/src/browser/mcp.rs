//! Playwright MCP 子进程的 MCP 客户端（stdio JSON-RPC，复用 [`crate::jsonrpc::Peer`]）。

use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};

use crate::jsonrpc::{Incoming, Peer, RpcError};

pub struct McpClient {
    peer: Arc<Peer>,
}

impl McpClient {
    /// 在子进程的 stdin、stdout 上握手。
    pub async fn connect(
        stdout: tokio::process::ChildStdout,
        stdin: tokio::process::ChildStdin,
        timeout: Duration,
    ) -> anyhow::Result<Self> {
        let (peer, mut incoming) = Peer::start(stdout, stdin);
        // 对方发来的请求（roots/list 之类）一律不支持；通知不用管。
        let answer = peer.clone();
        tokio::spawn(async move {
            while let Some(msg) = incoming.recv().await {
                if let Incoming::Request { id, method, .. } = msg {
                    answer.respond(id, Err(RpcError::method_not_found(&method)));
                }
            }
        });
        let init = peer.request(
            "initialize",
            json!({
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "thinktin-agent-shim", "version": env!("CARGO_PKG_VERSION")},
            }),
        );
        tokio::time::timeout(timeout, init)
            .await
            .map_err(|_| anyhow::anyhow!("the browser tools did not start in time"))??;
        peer.notify("notifications/initialized", json!({}))?;
        Ok(Self { peer })
    }

    /// 调一个工具：返回 MCP 的结果（`content`、`isError`）。
    pub async fn call(&self, name: &str, arguments: Value) -> Result<Value, RpcError> {
        self.peer
            .request("tools/call", json!({"name": name, "arguments": arguments}))
            .await
    }
}
