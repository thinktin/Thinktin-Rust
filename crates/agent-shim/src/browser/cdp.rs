//! Chromium 的 `--remote-debugging-pipe`（docs/browser.md 第 2.5 节）：Chromium 从 fd 3 读命令、往 fd 4 写回复和事件，每条
//! 消息是一段以 NUL 结尾的 JSON。
//!
//! 一条 pipe 上有两个客户端：守门用根会话（和它自动接上的页面会话），Playwright 经前置口用另一个浏览器会话
//! （`Target.attachToBrowserTarget` 开出来的）和它接上的会话。命令 id 统一由这里编号；回复按 id 交回发命令的一方，
//! 事件按会话分：属于前置口的会话的事件交给前置口，其余的交给守门。前置口的回复和事件走同一个通道，先后顺序和
//! Chromium 发出来的一样。

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::{mpsc, oneshot, watch};

/// 一条消息最多多大（截图的回复可能有几 MB）。
const MAX_MESSAGE: usize = 64 << 20;

/// 守门收到的一个事件。
#[derive(Debug, Clone)]
pub struct Event {
    pub method: String,
    pub params: Value,
    /// 事件发生在哪个会话上（根会话上的事件没有）。
    pub session: Option<String>,
}

/// 等一个回复的是谁。
enum Waiter {
    /// shim 自己（守门、前置口开会话）。
    Call(oneshot::Sender<Result<Value, Value>>),
    /// 前置口转来的命令：回复换回它原来的 id，按原样带不带 sessionId 交给前置口。
    Front {
        id: Value,
        session: Option<String>,
        method: String,
    },
}

#[derive(Default)]
struct FrontRoute {
    /// 前置口的浏览器会话：它上面的事件和回复去掉 sessionId 再交给 Playwright（Playwright 当它是根会话）。
    browser: Option<String>,
    /// 属于前置口的会话（浏览器会话，和在它上面接上的页面、iframe、worker）。
    sessions: HashSet<String>,
    tx: Option<mpsc::UnboundedSender<String>>,
    /// 前一个客户端留下、还没断干净的会话：上面的事件丢掉（不交给守门，也不交给下一个客户端）。
    retired: HashSet<String>,
}

pub struct Cdp {
    out: mpsc::UnboundedSender<Vec<u8>>,
    pending: Mutex<HashMap<u64, Waiter>>,
    next_id: AtomicU64,
    front: Mutex<FrontRoute>,
    closed: AtomicBool,
    /// pipe 断了时变成 true（前置口据此断开 Playwright）。
    closed_tx: watch::Sender<bool>,
}

impl Cdp {
    /// 在 pipe 的两端上启动。返回的接收端收到 `None` 表示 pipe 断了（Chromium 退出或者出错）。
    pub fn start<R, W>(reader: R, writer: W) -> (Arc<Cdp>, mpsc::UnboundedReceiver<Event>)
    where
        R: AsyncRead + Unpin + Send + 'static,
        W: AsyncWrite + Unpin + Send + 'static,
    {
        let (out_tx, out_rx) = mpsc::unbounded_channel();
        let (ev_tx, ev_rx) = mpsc::unbounded_channel();
        let cdp = Arc::new(Cdp {
            out: out_tx,
            pending: Mutex::default(),
            next_id: AtomicU64::new(1),
            front: Mutex::default(),
            closed: AtomicBool::new(false),
            closed_tx: watch::channel(false).0,
        });
        tokio::spawn(write_loop(writer, out_rx));
        tokio::spawn(read_loop(reader, cdp.clone(), ev_tx));
        (cdp, ev_rx)
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::Acquire)
    }

    /// pipe 断了时返回。
    pub async fn wait_closed(&self) {
        let mut rx = self.closed_tx.subscribe();
        let _ = rx.wait_for(|c| *c).await;
    }

    fn send(&self, id: u64, method: &str, params: Value, session: Option<&str>) -> bool {
        let mut msg = json!({"id": id, "method": method, "params": params});
        if let Some(s) = session {
            msg["sessionId"] = Value::from(s);
        }
        let mut bytes = msg.to_string().into_bytes();
        bytes.push(0);
        self.out.send(bytes).is_ok()
    }

    /// 发一条命令、等回复：`Ok(result)` 或 `Err(error 对象)`。
    pub async fn call_raw(
        &self,
        method: &str,
        params: Value,
        session: Option<&str>,
    ) -> Result<Value, Value> {
        let closed = || json!({"code": -32000, "message": "the browser connection is closed"});
        if self.is_closed() {
            return Err(closed());
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.lock_pending().insert(id, Waiter::Call(tx));
        if !self.send(id, method, params, session) {
            self.lock_pending().remove(&id);
            return Err(closed());
        }
        rx.await.unwrap_or_else(|_| Err(closed()))
    }

    pub async fn call(
        &self,
        method: &str,
        params: Value,
        session: Option<&str>,
    ) -> anyhow::Result<Value> {
        self.call_raw(method, params, session)
            .await
            .map_err(|e| anyhow::anyhow!("{method}: {}", e["message"].as_str().unwrap_or("error")))
    }

    /// 只发不等（回复丢掉）。
    pub fn fire(&self, method: &str, params: Value, session: Option<&str>) {
        if self.is_closed() {
            return;
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let _ = self.send(id, method, params, session);
    }

    /// 前置口接上：`browser` 是它的浏览器会话，`tx` 收给 Playwright 的消息（已经是 JSON 文本）。
    pub fn attach_front(&self, browser: &str, tx: mpsc::UnboundedSender<String>) {
        let mut f = self.lock_front();
        f.browser = Some(browser.to_owned());
        f.sessions = HashSet::from([browser.to_owned()]);
        f.tx = Some(tx);
    }

    /// 前置口的客户端走了：它还没回的命令作废（回复不交给下一个客户端），它的会话上之后的事件丢掉。
    pub fn detach_front(&self) {
        self.lock_pending()
            .retain(|_, w| !matches!(w, Waiter::Front { .. }));
        let mut f = self.lock_front();
        let old = std::mem::take(&mut f.sessions);
        f.retired.extend(old);
        f.browser = None;
        f.tx = None;
    }

    /// 前置口转来的一条命令（已经核对过能不能发）。`session` 为空时发到前置口的浏览器会话上。返回 false 表示这个会话不归
    /// 前置口管（不发）。
    pub fn forward_front(
        &self,
        id: Value,
        method: &str,
        params: Value,
        session: Option<&str>,
    ) -> bool {
        if self.is_closed() {
            return false;
        }
        let target = {
            let f = self.lock_front();
            match session {
                Some(s) if f.sessions.contains(s) => s.to_owned(),
                Some(_) => return false,
                None => match &f.browser {
                    Some(b) => b.clone(),
                    None => return false,
                },
            }
        };
        let cdp_id = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.lock_pending().insert(
            cdp_id,
            Waiter::Front {
                id,
                session: session.map(str::to_owned),
                method: method.to_owned(),
            },
        );
        if !self.send(cdp_id, method, params, Some(&target)) {
            self.lock_pending().remove(&cdp_id);
        }
        true
    }

    fn lock_pending(&self) -> std::sync::MutexGuard<'_, HashMap<u64, Waiter>> {
        self.pending.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn lock_front(&self) -> std::sync::MutexGuard<'_, FrontRoute> {
        self.front.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// 收到一条消息：回复交给等它的，事件按会话分。
    fn dispatch(&self, msg: Value, events: &mpsc::UnboundedSender<Event>) {
        if let Some(id) = msg.get("id").and_then(Value::as_u64) {
            let Some(waiter) = self.lock_pending().remove(&id) else {
                return;
            };
            let result = match msg.get("error") {
                Some(e) => Err(e.clone()),
                None => Ok(msg.get("result").cloned().unwrap_or_else(|| json!({}))),
            };
            match waiter {
                Waiter::Call(tx) => {
                    let _ = tx.send(result);
                }
                Waiter::Front {
                    id,
                    session,
                    method,
                } => {
                    let mut f = self.lock_front();
                    // flat 模式下 attachToTarget 的回复带新会话的 id：它也归前置口。
                    if method == "Target.attachToTarget"
                        && let Ok(r) = &result
                        && let Some(s) = r.get("sessionId").and_then(Value::as_str)
                    {
                        f.sessions.insert(s.to_owned());
                    }
                    let mut reply = match result {
                        Ok(r) => json!({"id": id, "result": r}),
                        Err(e) => json!({"id": id, "error": e}),
                    };
                    if let Some(s) = session {
                        reply["sessionId"] = Value::from(s);
                    }
                    if let Some(tx) = &f.tx {
                        let _ = tx.send(reply.to_string());
                    }
                }
            }
            return;
        }
        let Some(method) = msg.get("method").and_then(Value::as_str) else {
            return;
        };
        let session = msg.get("sessionId").and_then(Value::as_str);
        let params = msg.get("params").cloned().unwrap_or_else(|| json!({}));
        {
            let mut f = self.lock_front();
            if let Some(s) = session
                && f.retired.contains(s)
            {
                if method == "Target.detachedFromTarget"
                    && let Some(c) = params.get("sessionId").and_then(Value::as_str)
                {
                    f.retired.remove(c);
                }
                return;
            }
            // 前一个客户端的会话断开了。
            if method == "Target.detachedFromTarget"
                && let Some(c) = params.get("sessionId").and_then(Value::as_str)
                && f.retired.remove(c)
            {
                return;
            }
            if let Some(s) = session
                && f.sessions.contains(s)
            {
                let child = params.get("sessionId").and_then(Value::as_str);
                match (method, child) {
                    ("Target.attachedToTarget", Some(c)) => {
                        f.sessions.insert(c.to_owned());
                    }
                    ("Target.detachedFromTarget", Some(c)) => {
                        f.sessions.remove(c);
                    }
                    _ => {}
                }
                let mut ev = json!({"method": method, "params": params});
                if f.browser.as_deref() != Some(s) {
                    ev["sessionId"] = Value::from(s);
                }
                if let Some(tx) = &f.tx {
                    let _ = tx.send(ev.to_string());
                }
                return;
            }
        }
        let _ = events.send(Event {
            method: method.to_owned(),
            params,
            session: session.map(str::to_owned),
        });
    }

    fn close(&self) {
        self.closed.store(true, Ordering::Release);
        let closed = json!({"code": -32000, "message": "the browser connection is closed"});
        let waiters: Vec<_> = self.lock_pending().drain().collect();
        let f = self.lock_front();
        for (_, w) in waiters {
            match w {
                Waiter::Call(tx) => {
                    let _ = tx.send(Err(closed.clone()));
                }
                // 前置口转来、还没回的命令：回一个错误，Playwright 不用干等。
                Waiter::Front { id, session, .. } => {
                    let mut reply = json!({"id": id, "error": closed});
                    if let Some(s) = session {
                        reply["sessionId"] = Value::from(s);
                    }
                    if let Some(tx) = &f.tx {
                        let _ = tx.send(reply.to_string());
                    }
                }
            }
        }
        drop(f);
        // 前置口那边：断开，Playwright 会报浏览器断了。
        self.closed_tx.send_replace(true);
    }
}

async fn write_loop<W: AsyncWrite + Unpin>(mut w: W, mut rx: mpsc::UnboundedReceiver<Vec<u8>>) {
    while let Some(msg) = rx.recv().await {
        if w.write_all(&msg).await.is_err() || w.flush().await.is_err() {
            break;
        }
    }
}

async fn read_loop<R: AsyncRead + Unpin>(
    mut r: R,
    cdp: Arc<Cdp>,
    events: mpsc::UnboundedSender<Event>,
) {
    let mut buf: Vec<u8> = Vec::with_capacity(64 << 10);
    let mut chunk = vec![0u8; 64 << 10];
    // 已经找过、没有 NUL 的前缀长度（大消息分很多块到，每块只找新来的部分）。
    let mut scanned = 0;
    'outer: loop {
        let n = match r.read(&mut chunk).await {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        buf.extend_from_slice(&chunk[..n]);
        while let Some(pos) = buf[scanned..].iter().position(|b| *b == 0) {
            let end = scanned + pos;
            let msg: Vec<u8> = buf.drain(..=end).collect();
            scanned = 0;
            match serde_json::from_slice::<Value>(&msg[..msg.len() - 1]) {
                Ok(v) => cdp.dispatch(v, &events),
                Err(e) => tracing::warn!(error = %e, "malformed message from the browser"),
            }
        }
        scanned = buf.len();
        if buf.len() > MAX_MESSAGE {
            tracing::error!("the browser sent an oversized message; closing");
            break 'outer;
        }
    }
    cdp.close();
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// 一个假的 Chromium：读命令，按脚本回。
    async fn read_msg<R: AsyncRead + Unpin>(r: &mut R) -> Value {
        let mut out = Vec::new();
        let mut b = [0u8; 1];
        loop {
            r.read_exact(&mut b).await.unwrap();
            if b[0] == 0 {
                return serde_json::from_slice(&out).unwrap();
            }
            out.push(b[0]);
        }
    }

    async fn write_msg<W: AsyncWrite + Unpin>(w: &mut W, v: Value) {
        let mut bytes = v.to_string().into_bytes();
        bytes.push(0);
        w.write_all(&bytes).await.unwrap();
    }

    #[tokio::test]
    async fn replies_go_back_to_the_caller_and_events_are_split_by_session() {
        let (to_chrome, mut chrome_in) = tokio::io::duplex(1 << 16);
        let (mut chrome_out, from_chrome) = tokio::io::duplex(1 << 16);
        let (cdp, mut events) = Cdp::start(from_chrome, to_chrome);
        let call = tokio::spawn({
            let cdp = cdp.clone();
            async move { cdp.call("Browser.getVersion", json!({}), None).await }
        });
        let cmd = read_msg(&mut chrome_in).await;
        assert_eq!(cmd["method"], "Browser.getVersion");
        assert!(cmd.get("sessionId").is_none());
        write_msg(
            &mut chrome_out,
            json!({"id": cmd["id"], "result": {"product": "Chrome/1"}}),
        )
        .await;
        assert_eq!(call.await.unwrap().unwrap()["product"], "Chrome/1");

        // 前置口接上浏览器会话 B：它的命令编了新号，回复换回原来的 id、不带 sessionId。
        let (ftx, mut frx) = mpsc::unbounded_channel();
        cdp.attach_front("B", ftx);
        assert!(cdp.forward_front(json!(7), "Target.setAutoAttach", json!({}), None));
        let cmd = read_msg(&mut chrome_in).await;
        assert_eq!(cmd["sessionId"], "B");
        assert_ne!(cmd["id"], json!(7));
        // 先来一个 B 上的事件（接上一个页面 P），再来回复：前置口收到的顺序不变。
        write_msg(
            &mut chrome_out,
            json!({"method": "Target.attachedToTarget", "sessionId": "B",
                   "params": {"sessionId": "P", "targetInfo": {"type": "page"}}}),
        )
        .await;
        write_msg(&mut chrome_out, json!({"id": cmd["id"], "result": {}})).await;
        let ev: Value = serde_json::from_str(&frx.recv().await.unwrap()).unwrap();
        assert_eq!(ev["method"], "Target.attachedToTarget");
        assert!(ev.get("sessionId").is_none());
        let reply: Value = serde_json::from_str(&frx.recv().await.unwrap()).unwrap();
        assert_eq!(reply, json!({"id": 7, "result": {}}));
        // P 归前置口：可以发命令，事件带 sessionId 交给前置口。
        assert!(cdp.forward_front(json!(8), "Runtime.enable", json!({}), Some("P")));
        let cmd = read_msg(&mut chrome_in).await;
        assert_eq!(cmd["sessionId"], "P");
        // 守门的会话 G 不归前置口：不发。
        assert!(!cdp.forward_front(json!(9), "Runtime.evaluate", json!({}), Some("G")));
        // G 上的事件交给守门。
        write_msg(
            &mut chrome_out,
            json!({"method": "Fetch.requestPaused", "sessionId": "G", "params": {"requestId": "r1"}}),
        )
        .await;
        let ev = events.recv().await.unwrap();
        assert_eq!(
            (ev.method.as_str(), ev.session.as_deref()),
            ("Fetch.requestPaused", Some("G"))
        );
        // pipe 断了：守门的事件通道关掉，再调用马上失败。
        drop(chrome_out);
        assert!(events.recv().await.is_none());
        assert!(
            cdp.call("Browser.getVersion", json!({}), None)
                .await
                .is_err()
        );
    }
}
