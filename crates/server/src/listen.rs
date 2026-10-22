//! 公网入口的连接处理：限连接数、限请求头读取时间，停机时等进行中的连接处理完。
//!
//! axum 自带的 `serve` 没有装计时器，hyper 的请求头超时不生效：慢慢发请求头的连接（slowloris）
//! 能一直占着。这里自己接受连接，交给 hyper（HTTP/1.1，支持 WebSocket 升级）。
//! 请求体读得慢由 [`crate::http`] 的整体请求时限兜住。

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

#[derive(Debug, Clone)]
pub struct ListenOptions {
    /// 读完一个请求头（包括长连接上等下一个请求）的时限。
    pub header_read_timeout: Duration,
    pub max_connections: usize,
}

impl Default for ListenOptions {
    fn default() -> Self {
        Self {
            header_read_timeout: Duration::from_secs(30),
            max_connections: 16_384,
        }
    }
}

/// 在 `listener` 上服务 `app`。`draining` 完成后不再接受新连接，等已有的连接处理完再返回
/// （调用方给整体加时限）。处理函数可以用 `ConnectInfo<SocketAddr>` 取对端地址。
pub async fn serve(
    listener: TcpListener,
    app: Router,
    options: ListenOptions,
    draining: impl Future<Output = ()>,
) -> std::io::Result<()> {
    let total = Arc::new(Semaphore::new(options.max_connections));
    let (stop_tx, stop_rx) = watch::channel(false);
    tokio::pin!(draining);
    loop {
        let (stream, peer) = tokio::select! {
            () = &mut draining => break,
            accepted = listener.accept() => match accepted {
                Ok(pair) => pair,
                Err(e) => {
                    // 文件描述符用完之类的错误：稍等再接，别空转。
                    tracing::warn!(error = %e, "accept failed");
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    continue;
                }
            },
        };
        let Ok(permit) = total.clone().try_acquire_owned() else {
            tracing::warn!(%peer, "connection limit reached");
            continue;
        };
        let _ = stream.set_nodelay(true);
        let app = app.clone();
        let service = hyper::service::service_fn(move |mut req: hyper::Request<Incoming>| {
            req.extensions_mut().insert(ConnectInfo(peer));
            // Router 总是就绪，不用先 poll_ready。
            app.clone().call(req)
        });
        let mut builder = hyper::server::conn::http1::Builder::new();
        builder
            .timer(TokioTimer::new())
            .header_read_timeout(options.header_read_timeout)
            .keep_alive(true);
        let conn = builder
            .serve_connection(TokioIo::new(stream), service)
            .with_upgrades();
        let mut stop = stop_rx.clone();
        tokio::spawn(async move {
            tokio::pin!(conn);
            let stopped = async move {
                let _ = stop.wait_for(|s| *s).await;
            };
            let result = tokio::select! {
                r = conn.as_mut() => r,
                () = stopped => {
                    // 空闲的长连接马上关，正在处理的请求做完再关。
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
    // 所有连接都结束（名额全部还回来）才返回。
    let all = u32::try_from(options.max_connections).unwrap_or(u32::MAX);
    let _ = total.acquire_many(all).await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::SocketAddr;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[tokio::test]
    async fn slow_headers_are_cut_off() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let app = Router::new().route(
            "/",
            axum::routing::get(|ConnectInfo(peer): ConnectInfo<SocketAddr>| async move {
                peer.ip().to_string()
            }),
        );
        tokio::spawn(serve(
            listener,
            app,
            ListenOptions {
                header_read_timeout: Duration::from_millis(200),
                ..ListenOptions::default()
            },
            std::future::pending(),
        ));
        let mut s = tokio::net::TcpStream::connect(addr).await.unwrap();
        s.write_all(b"GET / HTTP/1.1\r\nHost: x\r\n").await.unwrap();
        let mut buf = Vec::new();
        let read = tokio::time::timeout(Duration::from_secs(5), s.read_to_end(&mut buf)).await;
        assert!(
            read.is_ok(),
            "the server must close a connection that stalls in the headers"
        );

        let mut s = tokio::net::TcpStream::connect(addr).await.unwrap();
        s.write_all(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            .await
            .unwrap();
        let mut buf = String::new();
        s.read_to_string(&mut buf).await.unwrap();
        assert!(
            buf.starts_with("HTTP/1.1 200") && buf.ends_with("127.0.0.1"),
            "{buf}"
        );
    }
}
