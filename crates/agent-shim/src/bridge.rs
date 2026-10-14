//! 平台工具桥（WBS 6.12）：把平台工具（`thinktin.schedule`、`thinktin.artifacts` 等）以 MCP 服务器的形式注入 agent 的会话。
//!
//! ```text
//! agent ──stdio MCP──▶ agent-shim mcp-bridge ──Unix socket──▶ shim（serve）──stdout 事件──▶ 平台
//!       ◀────────────                       ◀───────────────               ◀──stdin 指令──
//! ```
//!
//! - agent 按会话配置启动 `agent-shim mcp-bridge --socket <路径>`，它是一个只会转发的 MCP 服务器；
//! - shim 在沙箱里监听这个 Unix socket（只有本用户可读写），收到调用后发 [`ShimEvent::PlatformToolCall`]，
//!   等平台回 [`ShimCommand::PlatformToolResult`]；
//! - 调用属于哪一轮由 shim 填（当前正在执行的那一轮），agent 改不了；没有在执行的任务时直接报错。
//!
//! socket 上的消息是 JSON Lines：请求 `{"id":1,"op":"list"}`、`{"id":2,"op":"call","name":..,"arguments":..}`，
//! 回复 `{"id":1,"tools":[..]}`、`{"id":2,"result":{"content":[..],"isError":false}}`，
//! 工具列表变化时 shim 主动发 `{"op":"tools_changed"}`。

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use anyhow::Context;
use proto::shim::{PlatformTool, ShimEvent};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{broadcast, mpsc, oneshot};

use crate::events::EventSink;

/// 注入给 agent 的 MCP 服务器名；Claude Code 里工具名会显示成 `mcp__thinktin__<工具>`。
pub const SERVER_NAME: &str = "thinktin";
/// 我们支持的 MCP 协议版本，按新旧排列。
const MCP_VERSIONS: [&str; 3] = ["2025-06-18", "2025-03-26", "2024-11-05"];

#[derive(Debug, Clone, PartialEq)]
pub struct ToolResult {
    pub content: Vec<Value>,
    pub is_error: bool,
}

impl ToolResult {
    pub fn error(message: impl Into<String>) -> Self {
        Self {
            content: vec![json!({"type": "text", "text": message.into()})],
            is_error: true,
        }
    }

    fn to_json(&self) -> Value {
        json!({"content": self.content, "isError": self.is_error})
    }
}

pub struct Bridge {
    socket: PathBuf,
    /// socket 放在临时目录时，退出时连目录一起删。
    private_dir: Option<PathBuf>,
    tools: RwLock<Vec<PlatformTool>>,
    pending: Mutex<HashMap<String, oneshot::Sender<ToolResult>>>,
    /// 当前正在执行的那一轮。
    run: Mutex<Option<String>>,
    next_call: AtomicU64,
    changed: broadcast::Sender<()>,
    /// shim 退出时清空，否则事件通道永远关不上（输出端在等所有发送方都没了）。
    sink: Mutex<Option<EventSink>>,
    timeout: Duration,
}

impl Bridge {
    /// 在 `dir` 下建 socket 并开始接受连接。
    pub fn start(
        dir: &Path,
        sink: EventSink,
        tools: Vec<PlatformTool>,
        timeout: Duration,
    ) -> anyhow::Result<Arc<Self>> {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        let mut socket = dir.join("platform-tools.sock");
        let mut private_dir = None;
        if socket.as_os_str().len() >= MAX_SOCKET_PATH {
            // Unix socket 路径有长度上限（约 108 字节）；HOME 很深时改放到临时目录下一个只有本用户能进的目录里。
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.subsec_nanos())
                .unwrap_or_default();
            let short = std::env::temp_dir().join(format!("tt-{}-{nanos:x}", std::process::id()));
            std::fs::DirBuilder::new()
                .mode(0o700)
                .create(&short)
                .with_context(|| format!("creating {}", short.display()))?;
            socket = short.join("bridge.sock");
            private_dir = Some(short);
        } else {
            std::fs::create_dir_all(dir)?;
            std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
        }
        let _ = std::fs::remove_file(&socket);
        let listener =
            UnixListener::bind(&socket).with_context(|| format!("binding {}", socket.display()))?;
        std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600))?;
        let (changed, _) = broadcast::channel(8);
        let bridge = Arc::new(Self {
            socket,
            private_dir,
            tools: RwLock::new(Vec::new()),
            pending: Mutex::default(),
            run: Mutex::default(),
            next_call: AtomicU64::new(1),
            changed,
            sink: Mutex::new(Some(sink)),
            timeout,
        });
        bridge.set_tools(tools);
        let accept = bridge.clone();
        tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                tokio::spawn(accept.clone().serve_conn(stream));
            }
        });
        Ok(bridge)
    }

    /// shim 退出前调用：放掉事件发送端，还在等的调用都失败返回。
    pub fn close(&self) {
        *self.sink.lock().unwrap_or_else(|e| e.into_inner()) = None;
        *self.run.lock().unwrap_or_else(|e| e.into_inner()) = None;
        for (_, tx) in self
            .pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .drain()
        {
            let _ = tx.send(ToolResult::error("the agent-shim is shutting down"));
        }
    }

    pub fn socket_path(&self) -> &Path {
        &self.socket
    }

    /// ACP `session/new` 的 `mcpServers` 条目（stdio 方式）。
    pub fn mcp_server_entry(&self, exe: &Path) -> Value {
        json!({
            "name": SERVER_NAME,
            "command": exe.display().to_string(),
            "args": ["mcp-bridge", "--socket", self.socket.display().to_string()],
            "env": [],
        })
    }

    pub fn set_tools(&self, tools: Vec<PlatformTool>) {
        let valid: Vec<_> = tools
            .into_iter()
            .filter(|t| {
                let ok = PlatformTool::valid_name(&t.name);
                if !ok {
                    tracing::warn!(name = %t.name, "ignoring platform tool with an invalid name");
                }
                ok
            })
            .collect();
        *self.tools.write().unwrap_or_else(|e| e.into_inner()) = valid;
        let _ = self.changed.send(());
    }

    pub fn begin_run(&self, run_id: &str) {
        *self.run.lock().unwrap_or_else(|e| e.into_inner()) = Some(run_id.to_owned());
    }

    /// 一轮结束：这一轮还没回的调用都按失败返回给 agent。
    pub fn end_run(&self, run_id: &str) {
        let mut run = self.run.lock().unwrap_or_else(|e| e.into_inner());
        if run.as_deref() == Some(run_id) {
            *run = None;
        }
        drop(run);
        let prefix = format!("{run_id}:");
        let mut pending = self.pending.lock().unwrap_or_else(|e| e.into_inner());
        let stale: Vec<String> = pending
            .keys()
            .filter(|k| k.starts_with(&prefix))
            .cloned()
            .collect();
        for k in stale {
            if let Some(tx) = pending.remove(&k) {
                let _ = tx.send(ToolResult::error(
                    "the task ended before the platform answered",
                ));
            }
        }
    }

    /// 平台回了结果。返回是否有人在等。
    pub fn resolve(&self, call_id: &str, result: ToolResult) -> bool {
        let tx = self
            .pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(call_id);
        tx.is_some_and(|tx| tx.send(result).is_ok())
    }

    fn tool_list(&self) -> Vec<Value> {
        self.tools
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .map(|t| json!({"name": t.name, "description": t.description, "inputSchema": t.input_schema}))
            .collect()
    }

    async fn call(&self, name: &str, arguments: Value) -> ToolResult {
        let known = self
            .tools
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .any(|t| t.name == name);
        if !known {
            return ToolResult::error(format!("unknown tool `{name}`"));
        }
        let Some(run_id) = self.run.lock().unwrap_or_else(|e| e.into_inner()).clone() else {
            return ToolResult::error("platform tools are only available while a task is running");
        };
        let Some(sink) = self.sink.lock().unwrap_or_else(|e| e.into_inner()).clone() else {
            return ToolResult::error("the agent-shim is shutting down");
        };
        let call_id = format!(
            "{run_id}:{}",
            self.next_call.fetch_add(1, Ordering::Relaxed)
        );
        let (tx, rx) = oneshot::channel();
        self.pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(call_id.clone(), tx);
        sink.emit(ShimEvent::PlatformToolCall {
            run_id,
            call_id: call_id.clone(),
            name: name.to_owned(),
            arguments,
        });
        match tokio::time::timeout(self.timeout, rx).await {
            Ok(Ok(result)) => result,
            _ => {
                self.pending
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .remove(&call_id);
                ToolResult::error("the platform did not answer in time")
            }
        }
    }

    async fn serve_conn(self: Arc<Self>, stream: UnixStream) {
        let (read, mut write) = stream.into_split();
        let (out_tx, mut out_rx) = mpsc::unbounded_channel::<Value>();
        let writer = tokio::spawn(async move {
            while let Some(msg) = out_rx.recv().await {
                let mut line = msg.to_string().into_bytes();
                line.push(b'\n');
                if write.write_all(&line).await.is_err() {
                    break;
                }
            }
        });
        let mut changed = self.changed.subscribe();
        let notify_tx = out_tx.clone();
        let notifier = tokio::spawn(async move {
            while changed.recv().await.is_ok() {
                if notify_tx.send(json!({"op": "tools_changed"})).is_err() {
                    break;
                }
            }
        });
        let mut lines = BufReader::new(read).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let Ok(req) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            let id = req["id"].clone();
            match req["op"].as_str() {
                Some("list") => {
                    let _ = out_tx.send(json!({"id": id, "tools": self.tool_list()}));
                }
                Some("call") => {
                    let this = self.clone();
                    let out = out_tx.clone();
                    let name = req["name"].as_str().unwrap_or_default().to_owned();
                    let args = req.get("arguments").cloned().unwrap_or_else(|| json!({}));
                    tokio::spawn(async move {
                        let result = this.call(&name, args).await;
                        let _ = out.send(json!({"id": id, "result": result.to_json()}));
                    });
                }
                _ => {}
            }
        }
        notifier.abort();
        drop(out_tx);
        let _ = writer.await;
    }
}

impl Drop for Bridge {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.socket);
        if let Some(dir) = &self.private_dir {
            let _ = std::fs::remove_dir(dir);
        }
    }
}

/// socket 路径的长度上限（sockaddr_un.sun_path 是 108 字节，留点余量）。
const MAX_SOCKET_PATH: usize = 100;

// ---------- mcp-bridge 子命令：agent 启动的 MCP 服务器 ----------

fn rpc_result(id: &Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

fn rpc_error(id: &Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}

/// 在 stdio 上当 MCP 服务器，把工具相关的请求转给 shim。
pub async fn run_client(socket: &Path) -> anyhow::Result<()> {
    let stream = UnixStream::connect(socket)
        .await
        .with_context(|| format!("connecting to {}", socket.display()))?;
    let (sock_read, mut sock_write) = stream.into_split();
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<Value>();
    let stdout_task = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(msg) = out_rx.recv().await {
            let mut line = msg.to_string().into_bytes();
            line.push(b'\n');
            if stdout.write_all(&line).await.is_err() || stdout.flush().await.is_err() {
                break;
            }
        }
    });

    // 发给 shim 的请求 id → 对应的 JSON-RPC 请求 id 和方法。
    let waiting: Arc<Mutex<HashMap<u64, (Value, &'static str)>>> = Arc::default();
    let from_shim = {
        let waiting = waiting.clone();
        let out = out_tx.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(sock_read).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let Ok(msg) = serde_json::from_str::<Value>(&line) else {
                    continue;
                };
                if msg["op"] == "tools_changed" {
                    let _ = out.send(
                        json!({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}),
                    );
                    continue;
                }
                let Some(id) = msg["id"].as_u64() else {
                    continue;
                };
                let Some((rpc_id, kind)) = waiting.lock().unwrap().remove(&id) else {
                    continue;
                };
                let reply = match kind {
                    "list" => rpc_result(&rpc_id, json!({"tools": msg["tools"]})),
                    _ => rpc_result(&rpc_id, msg["result"].clone()),
                };
                let _ = out.send(reply);
            }
        })
    };

    let mut next = 1u64;
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let Ok(req) = serde_json::from_str::<Value>(&line) else {
            let _ = out_tx.send(rpc_error(&Value::Null, -32700, "parse error"));
            continue;
        };
        let id = req.get("id").cloned();
        let method = req["method"].as_str().unwrap_or_default();
        let Some(id) = id else {
            // 通知（notifications/initialized 等）不用回。
            continue;
        };
        match method {
            "initialize" => {
                let asked = req["params"]["protocolVersion"]
                    .as_str()
                    .unwrap_or_default();
                let version = MCP_VERSIONS
                    .iter()
                    .find(|v| **v == asked)
                    .unwrap_or(&MCP_VERSIONS[0]);
                let _ = out_tx.send(rpc_result(
                    &id,
                    json!({
                        "protocolVersion": version,
                        "capabilities": {"tools": {"listChanged": true}},
                        "serverInfo": {"name": SERVER_NAME, "version": env!("CARGO_PKG_VERSION")},
                        "instructions": "Tools provided by the ThinkTin platform (schedules, artifacts, delegation).",
                    }),
                ));
            }
            "ping" => {
                let _ = out_tx.send(rpc_result(&id, json!({})));
            }
            "tools/list" | "tools/call" => {
                let sock_id = next;
                next += 1;
                let (kind, msg) = if method == "tools/list" {
                    ("list", json!({"id": sock_id, "op": "list"}))
                } else {
                    let name = req["params"]["name"].clone();
                    let args = req["params"]
                        .get("arguments")
                        .cloned()
                        .unwrap_or_else(|| json!({}));
                    (
                        "call",
                        json!({"id": sock_id, "op": "call", "name": name, "arguments": args}),
                    )
                };
                waiting.lock().unwrap().insert(sock_id, (id.clone(), kind));
                let mut line = msg.to_string().into_bytes();
                line.push(b'\n');
                if sock_write.write_all(&line).await.is_err() {
                    let _ = out_tx.send(rpc_error(&id, -32603, "the agent-shim is gone"));
                    break;
                }
            }
            _ => {
                let _ = out_tx.send(rpc_error(&id, -32601, "method not found"));
            }
        }
    }
    from_shim.abort();
    drop(out_tx);
    let _ = stdout_task.await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tool(name: &str) -> PlatformTool {
        PlatformTool {
            name: name.into(),
            description: format!("{name} tool"),
            input_schema: json!({"type": "object"}),
        }
    }

    async fn ask(stream: &mut BufReader<UnixStream>, req: Value) -> Value {
        let mut line = req.to_string();
        line.push('\n');
        stream.get_mut().write_all(line.as_bytes()).await.unwrap();
        let mut buf = String::new();
        stream.read_line(&mut buf).await.unwrap();
        serde_json::from_str(&buf).unwrap()
    }

    #[tokio::test]
    async fn socket_protocol_and_run_scoping() {
        let dir = tempfile::tempdir().unwrap();
        let (sink, mut events) = EventSink::new();
        let bridge = Bridge::start(
            &dir.path().join("b"),
            sink,
            vec![tool("schedule_list"), tool("bad name!")],
            Duration::from_secs(5),
        )
        .unwrap();
        let mut conn = BufReader::new(UnixStream::connect(bridge.socket_path()).await.unwrap());
        let list = ask(&mut conn, json!({"id": 1, "op": "list"})).await;
        assert_eq!(
            list["tools"].as_array().unwrap().len(),
            1,
            "invalid names are dropped"
        );
        assert_eq!(list["tools"][0]["inputSchema"], json!({"type": "object"}));

        // 没有在执行的任务：直接报错，不打扰平台。
        let r = ask(
            &mut conn,
            json!({"id": 2, "op": "call", "name": "schedule_list"}),
        )
        .await;
        assert_eq!(r["result"]["isError"], true);
        let r = ask(&mut conn, json!({"id": 3, "op": "call", "name": "rm_rf"})).await;
        assert!(
            r["result"]["content"][0]["text"]
                .as_str()
                .unwrap()
                .contains("unknown tool")
        );

        bridge.begin_run("run-7");
        let mut line =
            json!({"id": 4, "op": "call", "name": "schedule_list", "arguments": {"limit": 3}})
                .to_string();
        line.push('\n');
        conn.get_mut().write_all(line.as_bytes()).await.unwrap();
        let ev = events.recv().await.unwrap();
        let ShimEvent::PlatformToolCall {
            run_id,
            call_id,
            name,
            arguments,
        } = ev.event
        else {
            panic!("unexpected {ev:?}")
        };
        assert_eq!((run_id.as_str(), name.as_str()), ("run-7", "schedule_list"));
        assert_eq!(arguments, json!({"limit": 3}));
        assert!(bridge.resolve(
            &call_id,
            ToolResult {
                content: vec![json!({"type":"text","text":"[]"})],
                is_error: false
            }
        ));
        assert!(
            !bridge.resolve(&call_id, ToolResult::error("twice")),
            "a call is answered once"
        );
        let mut buf = String::new();
        conn.read_line(&mut buf).await.unwrap();
        let r: Value = serde_json::from_str(&buf).unwrap();
        assert_eq!(
            r,
            json!({"id": 4, "result": {"content": [{"type":"text","text":"[]"}], "isError": false}})
        );

        // 一轮结束时，还在等的调用都失败返回。
        conn.get_mut()
            .write_all(
                format!(
                    "{}\n",
                    json!({"id": 5, "op": "call", "name": "schedule_list"})
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        let _ = events.recv().await.unwrap();
        bridge.end_run("run-7");
        let mut buf = String::new();
        conn.read_line(&mut buf).await.unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&buf).unwrap()["result"]["isError"],
            true
        );

        // 工具列表变化会通知到连接上。
        bridge.set_tools(vec![tool("schedule_list"), tool("artifacts_get")]);
        let mut buf = String::new();
        conn.read_line(&mut buf).await.unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&buf).unwrap(),
            json!({"op": "tools_changed"})
        );

        // socket 只有本用户能访问。
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(bridge.socket_path())
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[tokio::test]
    async fn calls_time_out() {
        let dir = tempfile::tempdir().unwrap();
        let (sink, _events) = EventSink::new();
        let bridge = Bridge::start(
            dir.path(),
            sink,
            vec![tool("t")],
            Duration::from_millis(100),
        )
        .unwrap();
        bridge.begin_run("r");
        let r = bridge.call("t", json!({})).await;
        assert!(r.is_error);
        assert!(bridge.pending.lock().unwrap().is_empty());
    }
}
