//! 接受连接：限请求头的读取时间（慢慢发请求头的连接占不住），支持 WebSocket 升级。
//! 和控制面的 `server` 里的一样；升级以后的长连接不归这里管，由 [`crate::Relay`] 自己计数、停机时关掉。

use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use axum::Router;
use axum::extract::ConnectInfo;
use hyper::body::Incoming;
use hyper_util::rt::{TokioIo, TokioTimer};
use tokio::net::TcpListener;
use tokio::sync::{Semaphore, watch};
use tower::Service;

/// 同时在握手（还没升级）的连接数上限。
const MAX_HANDSHAKES: usize = 4096;

/// 在 `listener` 上服务 `app`，直到 `stop` 完成；之后不再接受新连接，等还没升级的连接处理完再返回。
pub async fn serve(
    listener: TcpListener,
    app: Router,
    header_read_timeout: Duration,
    stop: impl Future<Output = ()>,
) -> std::io::Result<()> {
    let total = Arc::new(Semaphore::new(MAX_HANDSHAKES));
    let (stop_tx, stop_rx) = watch::channel(false);
    tokio::pin!(stop);
    loop {
        let (stream, peer) = tokio::select! {
            () = &mut stop => break,
            accepted = listener.accept() => match accepted {
                Ok(pair) => pair,
                Err(e) => {
                    tracing::warn!(error = %e, "accept failed");
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    continue;
                }
            },
        };
        let Ok(permit) = total.clone().try_acquire_owned() else {
            tracing::warn!(%peer, "handshake limit reached");
            continue;
        };
        let _ = stream.set_nodelay(true);
        let app = app.clone();
        let service = hyper::service::service_fn(move |mut req: hyper::Request<Incoming>| {
            req.extensions_mut().insert(ConnectInfo(peer));
            app.clone().call(req)
        });
        let mut builder = hyper::server::conn::http1::Builder::new();
        builder
            .timer(TokioTimer::new())
            .header_read_timeout(header_read_timeout)
            .keep_alive(true);
        let conn = builder
            .serve_connection(TokioIo::new(stream), service)
            .with_upgrades();
        let mut stopping = stop_rx.clone();
        tokio::spawn(async move {
            tokio::pin!(conn);
            let stopped = async move {
                let _ = stopping.wait_for(|s| *s).await;
            };
            let result = tokio::select! {
                r = conn.as_mut() => r,
                () = stopped => {
                    conn.as_mut().graceful_shutdown();
                    conn.await
                }
            };
            if let Err(e) = result {
                tracing::debug!(%peer, error = %e, "connection ended with an error");
            }
            drop(permit);
        });
    }
    let _ = stop_tx.send(true);
    let all = u32::try_from(MAX_HANDSHAKES).unwrap_or(u32::MAX);
    let _ = total.acquire_many(all).await;
    Ok(())
}
