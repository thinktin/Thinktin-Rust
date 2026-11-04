//! 给 Playwright 的 CDP 前置口（docs/browser.md 第 2.5 节）：`ws://127.0.0.1:<随机>/`，请求头 `X-Thinktin-Front` 带秘密
//! （不放网址里：Playwright 连不上时会把网址写进给 agent 看的错误）。Playwright 以为连的是浏览器；实际是同一条 pipe 上一个
//! 单独的浏览器会话（`Target.attachToBrowserTarget`），守门的会话它碰不到。少数危险命令直接回错误：拦截请求只有守门能做，
//! 代理、证书、把 CDP 交给网页脚本的都不行；只许 flat 模式的会话（非 flat 的会话能经 `Target.sendMessageToTarget` 绕过
//! 这些检查）。这在同一个用户下只是提高门槛，不是安全边界。

use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::http::StatusCode;

use super::cdp::Cdp;

/// 带秘密的请求头。
pub const SECRET_HEADER: &str = "x-thinktin-front";
/// WebSocket 握手最多等多久（本机别的进程挂着不握手，不能卡住 Playwright 重连）。
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(2);

/// 前置口不转的命令，返回给 Playwright 的原因。
pub fn refused(method: &str, params: &Value) -> Option<&'static str> {
    if method.starts_with("Fetch.") {
        return Some("request interception is reserved for the platform");
    }
    let flat = params.get("flatten").and_then(Value::as_bool) == Some(true);
    match method {
        "Target.exposeDevToolsProtocol" => Some("exposing the protocol to pages is not allowed"),
        "Target.attachToBrowserTarget"
        | "Target.setRemoteLocations"
        | "Target.sendMessageToTarget" => {
            Some("not allowed through the platform's browser connection")
        }
        "Target.attachToTarget" | "Target.setAutoAttach" | "Target.autoAttachRelated" if !flat => {
            Some("only flat sessions are allowed")
        }
        "Network.setRequestInterception" => {
            Some("request interception is reserved for the platform")
        }
        "Security.setIgnoreCertificateErrors" | "Security.setOverrideCertificateErrors" => {
            Some("certificate errors cannot be ignored")
        }
        "Browser.crash" | "Browser.crashGpuProcess" | "Browser.executeBrowserCommand" => {
            Some("not allowed")
        }
        m if m.starts_with("Tethering.") => Some("port forwarding is not allowed"),
        "Target.createBrowserContext"
            if [
                "proxyServer",
                "proxyBypassList",
                "originsWithUniversalNetworkAccess",
            ]
            .iter()
            .any(|k| params.get(*k).is_some()) =>
        {
            Some("browser contexts cannot change the proxy")
        }
        _ => None,
    }
}

/// 两个字符串一样长且每个字节都相同（比较时间不随第一个不同的字节变）。
fn same(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// 一次只服务一个客户端（Playwright MCP）；`secret` 要出现在请求头里。pipe 断了就不再收。
pub async fn serve(listener: TcpListener, secret: String, cdp: Arc<Cdp>) {
    let busy = Arc::new(tokio::sync::Mutex::new(()));
    loop {
        let accepted = tokio::select! {
            a = listener.accept() => a,
            () = cdp.wait_closed() => return,
        };
        let stream = match accepted {
            Ok((s, _)) => s,
            Err(e) => {
                tracing::warn!(error = %e, "the browser front port could not accept a connection");
                tokio::time::sleep(Duration::from_millis(100)).await;
                continue;
            }
        };
        let (secret, cdp, busy) = (secret.clone(), cdp.clone(), busy.clone());
        tokio::spawn(async move {
            #[allow(clippy::result_large_err)]
            let check = |req: &Request, resp: Response| -> Result<Response, ErrorResponse> {
                let ok = req.uri().path() == "/"
                    && req
                        .headers()
                        .get(SECRET_HEADER)
                        .is_some_and(|v| same(v.as_bytes(), secret.as_bytes()));
                if ok {
                    Ok(resp)
                } else {
                    let mut e = ErrorResponse::new(None);
                    *e.status_mut() = StatusCode::NOT_FOUND;
                    Err(e)
                }
            };
            let Ok(Ok(ws)) = tokio::time::timeout(
                HANDSHAKE_TIMEOUT,
                tokio_tungstenite::accept_hdr_async(stream, check),
            )
            .await
            else {
                return;
            };
            // 已经有一个客户端在用：不排队，直接断开（Playwright 会报连不上）。
            let Ok(_held) = busy.try_lock() else {
                let mut ws = ws;
                let _ = ws.close(None).await;
                return;
            };
            if cdp.is_closed() {
                return;
            }
            if let Err(e) = client(ws, &cdp).await {
                tracing::info!(error = %e, "the browser automation client disconnected");
            }
        });
    }
}

async fn client(
    ws: tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>,
    cdp: &Arc<Cdp>,
) -> anyhow::Result<()> {
    let session = cdp
        .call("Target.attachToBrowserTarget", json!({}), None)
        .await?["sessionId"]
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| anyhow::anyhow!("no browser session"))?;
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();
    cdp.attach_front(&session, tx.clone());
    let (mut sink, mut stream) = ws.split();
    let result = async {
        loop {
            tokio::select! {
                out = rx.recv() => match out {
                    Some(text) => sink.send(Message::text(text)).await?,
                    None => break,
                },
                // pipe 断了：把排着的回复（都是错误）发完，断开 Playwright。
                () = cdp.wait_closed() => {
                    while let Ok(t) = rx.try_recv() {
                        sink.send(Message::text(t)).await?;
                    }
                    break;
                }
                msg = stream.next() => {
                    let text = match msg {
                        Some(Ok(Message::Text(t))) => t.to_string(),
                        Some(Ok(Message::Binary(b))) => String::from_utf8_lossy(&b).into_owned(),
                        Some(Ok(Message::Ping(_) | Message::Pong(_) | Message::Frame(_))) => continue,
                        Some(Ok(Message::Close(_))) | None => break,
                        Some(Err(e)) => return Err(e.into()),
                    };
                    let Ok(cmd) = serde_json::from_str::<Value>(&text) else { continue };
                    let id = cmd.get("id").cloned().unwrap_or(Value::Null);
                    let method = cmd["method"].as_str().unwrap_or_default().to_owned();
                    let params = cmd.get("params").cloned().unwrap_or_else(|| json!({}));
                    let sid = cmd["sessionId"].as_str().map(str::to_owned);
                    let reply = |body: Value| {
                        let mut v = body;
                        v["id"] = id.clone();
                        if let Some(s) = &sid {
                            v["sessionId"] = Value::from(s.as_str());
                        }
                        v.to_string()
                    };
                    if method == "Browser.close" {
                        // 不真关 Chromium：回成功、断开 Playwright。
                        let _ = tx.send(reply(json!({"result": {}})));
                        while let Ok(t) = rx.try_recv() {
                            sink.send(Message::text(t)).await?;
                        }
                        break;
                    }
                    if let Some(why) = refused(&method, &params) {
                        let _ = tx.send(reply(json!({"error": {"code": -32000, "message": why}})));
                        continue;
                    }
                    if !cdp.forward_front(id.clone(), &method, params, sid.as_deref()) {
                        let why = if cdp.is_closed() { "the browser connection is closed" } else { "session not found" };
                        let _ = tx.send(reply(json!({"error": {"code": -32001, "message": why}})));
                    }
                }
            }
        }
        anyhow::Ok(())
    }
    .await;
    cdp.detach_front();
    cdp.fire(
        "Target.detachFromTarget",
        json!({"sessionId": session}),
        None,
    );
    let _ = sink.close().await;
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dangerous_commands_are_refused() {
        assert!(refused("Fetch.enable", &json!({})).is_some());
        assert!(refused("Fetch.continueRequest", &json!({})).is_some());
        assert!(refused("Target.exposeDevToolsProtocol", &json!({})).is_some());
        assert!(refused("Tethering.bind", &json!({"port": 9222})).is_some());
        assert!(
            refused(
                "Target.createBrowserContext",
                &json!({"proxyServer": "http://evil:1"})
            )
            .is_some()
        );
        assert!(
            refused(
                "Target.createBrowserContext",
                &json!({"disposeOnDetach": true})
            )
            .is_none()
        );
        assert!(
            refused(
                "Security.setIgnoreCertificateErrors",
                &json!({"ignore": true})
            )
            .is_some()
        );
        assert!(
            refused(
                "Target.setAutoAttach",
                &json!({"autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true})
            )
            .is_none()
        );
        for ok in [
            "Browser.setDownloadBehavior",
            "Target.createTarget",
            "Runtime.evaluate",
            "Page.navigate",
            "Browser.getVersion",
        ] {
            assert!(refused(ok, &json!({})).is_none(), "{ok}");
        }
    }
}
