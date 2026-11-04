//! 给 Playwright 的 CDP 前置口（docs/browser.md 第 2.5 节）：`ws://127.0.0.1:<随机>/<秘密>`。Playwright 以为连的是浏览器；
//! 实际是同一条 pipe 上一个单独的浏览器会话（`Target.attachToBrowserTarget`），守门的会话它碰不到。少数危险命令直接回
//! 错误：拦截请求只有守门能做，代理、证书、把 CDP 交给网页脚本的都不行。这在同一个用户下只是提高门槛，不是安全边界。

use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::http::StatusCode;

use super::cdp::Cdp;

/// 前置口不转的命令，返回给 Playwright 的原因。
pub fn refused(method: &str, params: &Value) -> Option<&'static str> {
    if method.starts_with("Fetch.") {
        return Some("request interception is reserved for the platform");
    }
    match method {
        "Target.exposeDevToolsProtocol" => Some("exposing the protocol to pages is not allowed"),
        "Target.attachToBrowserTarget" | "Target.setRemoteLocations" => {
            Some("not allowed through the platform's browser connection")
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

/// 一次只服务一个客户端（Playwright MCP）。`secret` 是网址里的秘密路径。
pub async fn serve(listener: TcpListener, secret: String, cdp: Arc<Cdp>) {
    let path = format!("/{secret}");
    while let Ok((stream, _)) = listener.accept().await {
        // 签名是 tungstenite 定的，错误类型改不了。
        #[allow(clippy::result_large_err)]
        let check = |req: &Request, resp: Response| -> Result<Response, ErrorResponse> {
            if req.uri().path() == path {
                Ok(resp)
            } else {
                let mut e = ErrorResponse::new(None);
                *e.status_mut() = StatusCode::NOT_FOUND;
                Err(e)
            }
        };
        let Ok(ws) = tokio_tungstenite::accept_hdr_async(stream, check).await else {
            continue;
        };
        if cdp.is_closed() {
            return;
        }
        if let Err(e) = client(ws, &cdp).await {
            tracing::info!(error = %e, "the browser automation client disconnected");
        }
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
                    // pipe 断了。
                    None => break,
                },
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
                        let _ = tx.send(reply(json!({"error": {"code": -32001, "message": "session not found"}})));
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
        for ok in [
            "Target.setAutoAttach",
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
