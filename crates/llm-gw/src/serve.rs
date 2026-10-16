//! 入站连接：限连接数、限请求头读取时间（防慢速连接耗尽资源）。
//!
//! axum 自带的 `serve` 没有装计时器，hyper 的请求头超时不生效，也不限连接数，所以自己接受连接。
//! 只支持 HTTP/1.1（agent 都用它）。

use std::collections::HashMap;
use std::future::Future;
use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::Router;
use axum::extract::ConnectInfo;
use hyper::body::Incoming;
use hyper_util::rt::{TokioIo, TokioTimer};
use tokio::net::TcpListener;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tower::Service;

#[derive(Debug, Clone)]
pub struct ServeOptions {
    /// 读完一个请求头（包括长连接上等下一个请求）的时限。
    pub header_read_timeout: Duration,
    pub max_connections: usize,
    pub max_connections_per_ip: usize,
}

impl Default for ServeOptions {
    fn default() -> Self {
        Self {
            header_read_timeout: Duration::from_secs(30),
            max_connections: 8192,
            max_connections_per_ip: 64,
        }
    }
}

/// 每个来源地址当前的连接数。
#[derive(Default)]
struct PerIp(Mutex<HashMap<IpAddr, usize>>);

struct IpSlot {
    table: Arc<PerIp>,
    ip: IpAddr,
}

impl PerIp {
    fn take(self: &Arc<Self>, ip: IpAddr, max: usize) -> Option<IpSlot> {
        let mut map = self.0.lock().unwrap_or_else(|e| e.into_inner());
        let n = map.entry(ip).or_default();
        if *n >= max {
            return None;
        }
        *n += 1;
        Some(IpSlot {
            table: self.clone(),
            ip,
        })
    }
}

impl Drop for IpSlot {
    fn drop(&mut self) {
        let mut map = self.table.0.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(n) = map.get_mut(&self.ip) {
            *n -= 1;
            if *n == 0 {
                map.remove(&self.ip);
            }
        }
    }
}

/// 在 `listener` 上服务 `app`，直到 `shutdown` 完成（之后不再接受新连接）。
/// 处理函数可以用 `ConnectInfo<SocketAddr>` 取对端地址。
pub async fn serve(
    listener: TcpListener,
    app: Router,
    options: ServeOptions,
    shutdown: impl Future<Output = ()>,
) -> std::io::Result<()> {
    let total = Arc::new(Semaphore::new(options.max_connections));
    let per_ip = Arc::new(PerIp::default());
    tokio::pin!(shutdown);
    loop {
        let (stream, peer) = tokio::select! {
            _ = &mut shutdown => return Ok(()),
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
        let Some(slot) = per_ip.take(peer.ip().to_canonical(), options.max_connections_per_ip)
        else {
            tracing::warn!(%peer, "per-address connection limit reached");
            continue;
        };
        let _ = stream.set_nodelay(true);
        tokio::spawn(connection(
            stream,
            peer,
            app.clone(),
            options.header_read_timeout,
            permit,
            slot,
        ));
    }
}

async fn connection(
    stream: tokio::net::TcpStream,
    peer: SocketAddr,
    app: Router,
    header_read_timeout: Duration,
    _permit: OwnedSemaphorePermit,
    _slot: IpSlot,
) {
    let service = hyper::service::service_fn(move |mut req: hyper::Request<Incoming>| {
        req.extensions_mut().insert(ConnectInfo(peer));
        // Router 总是就绪，不用先 poll_ready。
        app.clone().call(req)
    });
    let mut builder = hyper::server::conn::http1::Builder::new();
    builder
        .timer(TokioTimer::new())
        .header_read_timeout(header_read_timeout)
        .keep_alive(true);
    if let Err(e) = builder
        .serve_connection(TokioIo::new(stream), service)
        .await
    {
        tracing::debug!(%peer, error = %e, "connection ended with an error");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    async fn start(options: ServeOptions) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let app = Router::new().route(
            "/",
            axum::routing::get(|ConnectInfo(peer): ConnectInfo<SocketAddr>| async move {
                peer.ip().to_string()
            }),
        );
        tokio::spawn(serve(listener, app, options, std::future::pending()));
        addr
    }

    #[tokio::test]
    async fn slow_headers_are_cut_off() {
        let addr = start(ServeOptions {
            header_read_timeout: Duration::from_millis(200),
            ..ServeOptions::default()
        })
        .await;
        let mut s = tokio::net::TcpStream::connect(addr).await.unwrap();
        s.write_all(b"GET / HTTP/1.1\r\nHost: x\r\n").await.unwrap();
        let mut buf = Vec::new();
        let read = tokio::time::timeout(Duration::from_secs(5), s.read_to_end(&mut buf)).await;
        assert!(
            read.is_ok(),
            "the server must close a connection that stalls in the headers"
        );

        // 正常请求不受影响，处理函数拿得到对端地址。
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

    #[tokio::test]
    async fn per_address_connection_cap() {
        let addr = start(ServeOptions {
            max_connections_per_ip: 2,
            ..ServeOptions::default()
        })
        .await;
        let _a = tokio::net::TcpStream::connect(addr).await.unwrap();
        let _b = tokio::net::TcpStream::connect(addr).await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        let mut c = tokio::net::TcpStream::connect(addr).await.unwrap();
        let mut buf = Vec::new();
        let n = tokio::time::timeout(Duration::from_secs(2), c.read_to_end(&mut buf)).await;
        assert!(
            matches!(n, Ok(Ok(0)) | Ok(Err(_))),
            "third connection is dropped"
        );
        drop((_a, _b));
        tokio::time::sleep(Duration::from_millis(50)).await;
        let mut d = tokio::net::TcpStream::connect(addr).await.unwrap();
        d.write_all(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            .await
            .unwrap();
        let mut buf = String::new();
        d.read_to_string(&mut buf).await.unwrap();
        assert!(buf.starts_with("HTTP/1.1 200"), "slots are released: {buf}");
    }
}
