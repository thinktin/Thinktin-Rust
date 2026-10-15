//! 按行分隔的 JSON-RPC 2.0 连接，ACP 的 stdio 传输就是这种格式。
//!
//! 一条连接两个方向都能发请求：shim 调 agent 的 `session/prompt`，agent 也会反过来
//! 调 shim 的 `session/request_permission`。

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, oneshot};

#[derive(Debug, Clone, PartialEq)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
    pub data: Option<Value>,
}

impl RpcError {
    pub const METHOD_NOT_FOUND: i64 = -32601;
    pub const INTERNAL: i64 = -32603;
    /// 本地错误码：连接已断开，不会出现在线路上。
    pub const CLOSED: i64 = -32099;

    pub fn new(code: i64, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            data: None,
        }
    }

    pub fn method_not_found(method: &str) -> Self {
        Self::new(
            Self::METHOD_NOT_FOUND,
            format!("method not found: {method}"),
        )
    }

    pub fn closed() -> Self {
        Self::new(Self::CLOSED, "connection closed")
    }

    fn to_json(&self) -> Value {
        let mut v = json!({"code": self.code, "message": self.message});
        if let Some(data) = &self.data {
            v["data"] = data.clone();
        }
        v
    }

    fn from_json(v: &Value) -> Self {
        Self {
            code: v
                .get("code")
                .and_then(Value::as_i64)
                .unwrap_or(Self::INTERNAL),
            message: v
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("unknown error")
                .to_owned(),
            data: v.get("data").cloned(),
        }
    }
}

impl std::fmt::Display for RpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} (code {})", self.message, self.code)?;
        if let Some(data) = &self.data {
            write!(f, ": {data}")?;
        }
        Ok(())
    }
}

impl std::error::Error for RpcError {}

/// 对方发来的请求或通知。
#[derive(Debug)]
pub enum Incoming {
    Request {
        id: Value,
        method: String,
        params: Value,
    },
    Notification {
        method: String,
        params: Value,
    },
}

type Pending = Arc<Mutex<HashMap<u64, oneshot::Sender<Result<Value, RpcError>>>>>;

pub struct Peer {
    out: mpsc::UnboundedSender<String>,
    pending: Pending,
    next_id: AtomicU64,
}

impl Peer {
    /// 在读写两端上启动连接。返回的接收端收到 `None` 表示对方已断开。
    pub fn start<R, W>(reader: R, writer: W) -> (Arc<Peer>, mpsc::UnboundedReceiver<Incoming>)
    where
        R: AsyncRead + Unpin + Send + 'static,
        W: AsyncWrite + Unpin + Send + 'static,
    {
        let (out_tx, out_rx) = mpsc::unbounded_channel();
        let (in_tx, in_rx) = mpsc::unbounded_channel();
        let pending: Pending = Arc::default();
        tokio::spawn(write_loop(writer, out_rx));
        tokio::spawn(read_loop(reader, in_tx, pending.clone()));
        let peer = Arc::new(Peer {
            out: out_tx,
            pending,
            next_id: AtomicU64::new(1),
        });
        (peer, in_rx)
    }

    pub async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id, tx);
        let msg = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        if self.out.send(msg.to_string()).is_err() {
            self.pending.lock().unwrap().remove(&id);
            return Err(RpcError::closed());
        }
        rx.await.unwrap_or_else(|_| Err(RpcError::closed()))
    }

    pub fn notify(&self, method: &str, params: Value) -> Result<(), RpcError> {
        let msg = json!({"jsonrpc": "2.0", "method": method, "params": params});
        self.out
            .send(msg.to_string())
            .map_err(|_| RpcError::closed())
    }

    pub fn respond(&self, id: Value, result: Result<Value, RpcError>) {
        let msg = match result {
            Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
            Err(err) => json!({"jsonrpc": "2.0", "id": id, "error": err.to_json()}),
        };
        // 对方已断开时回复无处可送，丢弃即可。
        let _ = self.out.send(msg.to_string());
    }
}

async fn write_loop<W: AsyncWrite + Unpin>(mut writer: W, mut rx: mpsc::UnboundedReceiver<String>) {
    while let Some(mut line) = rx.recv().await {
        line.push('\n');
        if let Err(err) = writer.write_all(line.as_bytes()).await {
            tracing::debug!("jsonrpc write failed: {err}");
            break;
        }
        if writer.flush().await.is_err() {
            break;
        }
    }
    // writer 在这里被 drop，对方的 stdin 随之关闭。
}

async fn read_loop<R: AsyncRead + Unpin>(
    reader: R,
    incoming: mpsc::UnboundedSender<Incoming>,
    pending: Pending,
) {
    let mut lines = BufReader::new(reader).lines();
    loop {
        let line = match lines.next_line().await {
            Ok(Some(line)) => line,
            Ok(None) => break,
            Err(err) => {
                tracing::debug!("jsonrpc read failed: {err}");
                break;
            }
        };
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(msg) = serde_json::from_str::<Value>(line) else {
            // 有的 agent 会往 stdout 打日志，跳过非 JSON 的行。
            tracing::warn!("ignoring non-JSON line from agent: {}", truncate(line, 200));
            continue;
        };
        dispatch(msg, &incoming, &pending);
    }
    for (_, tx) in pending.lock().unwrap().drain() {
        let _ = tx.send(Err(RpcError::closed()));
    }
}

fn dispatch(msg: Value, incoming: &mpsc::UnboundedSender<Incoming>, pending: &Pending) {
    let id = msg.get("id").filter(|id| !id.is_null()).cloned();
    if let Some(method) = msg.get("method").and_then(Value::as_str) {
        let params = msg.get("params").cloned().unwrap_or(Value::Null);
        let method = method.to_owned();
        let item = match id {
            Some(id) => Incoming::Request { id, method, params },
            None => Incoming::Notification { method, params },
        };
        let _ = incoming.send(item);
        return;
    }
    let Some(id) = id.as_ref().and_then(Value::as_u64) else {
        tracing::warn!("ignoring JSON-RPC message without method or numeric id: {msg}");
        return;
    };
    let Some(tx) = pending.lock().unwrap().remove(&id) else {
        tracing::warn!("ignoring response to unknown request id {id}");
        return;
    };
    let result = match msg.get("error") {
        Some(err) => Err(RpcError::from_json(err)),
        None => Ok(msg.get("result").cloned().unwrap_or(Value::Null)),
    };
    let _ = tx.send(result);
}

pub(crate) fn truncate(s: &str, max: usize) -> &str {
    match s.char_indices().nth(max) {
        Some((i, _)) => &s[..i],
        None => s,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    type Endpoint = (Arc<Peer>, mpsc::UnboundedReceiver<Incoming>);

    /// 两个 Peer 背靠背连起来。
    fn pair() -> (Endpoint, Endpoint) {
        let (a, b) = tokio::io::duplex(1 << 16);
        let (ar, aw) = tokio::io::split(a);
        let (br, bw) = tokio::io::split(b);
        (Peer::start(ar, aw), Peer::start(br, bw))
    }

    #[tokio::test]
    async fn request_response_both_ways() {
        let ((a, _a_in), (b, mut b_in)) = pair();
        let server = tokio::spawn(async move {
            let Some(Incoming::Request { id, method, params }) = b_in.recv().await else {
                panic!("expected request");
            };
            assert_eq!(method, "echo");
            b.respond(id, Ok(params));
            let Some(Incoming::Request { id, method, .. }) = b_in.recv().await else {
                panic!("expected request");
            };
            b.respond(id, Err(RpcError::method_not_found(&method)));
            let Some(Incoming::Notification { method, .. }) = b_in.recv().await else {
                panic!("expected notification");
            };
            assert_eq!(method, "ping");
        });
        assert_eq!(
            a.request("echo", json!({"x": 1})).await.unwrap(),
            json!({"x": 1})
        );
        let err = a.request("nope", json!({})).await.unwrap_err();
        assert_eq!(err.code, RpcError::METHOD_NOT_FOUND);
        a.notify("ping", json!(null)).unwrap();
        server.await.unwrap();
    }

    #[tokio::test]
    async fn pending_requests_fail_when_peer_goes_away() {
        let (a, b) = tokio::io::duplex(1024);
        let (ar, aw) = tokio::io::split(a);
        let (peer, _incoming) = Peer::start(ar, aw);
        let req = tokio::spawn({
            let peer = peer.clone();
            async move { peer.request("slow", json!({})).await }
        });
        tokio::task::yield_now().await;
        drop(b);
        assert_eq!(req.await.unwrap().unwrap_err().code, RpcError::CLOSED);
    }

    #[tokio::test]
    async fn non_json_lines_are_skipped() {
        let (a, mut b) = tokio::io::duplex(1024);
        let (ar, aw) = tokio::io::split(a);
        let (_peer, mut incoming) = Peer::start(ar, aw);
        b.write_all(b"npm WARN something\n{\"jsonrpc\":\"2.0\",\"method\":\"hi\"}\n")
            .await
            .unwrap();
        let Some(Incoming::Notification { method, params }) = incoming.recv().await else {
            panic!("expected notification");
        };
        assert_eq!(method, "hi");
        assert_eq!(params, Value::Null);
    }
}
