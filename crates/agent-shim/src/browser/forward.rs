//! 转发口（docs/browser.md 第 4.2 节）：Chromium 的代理设成 `127.0.0.1:<这里>`。只收我们起的 Chromium 发来的
//! `CONNECT host:443`；放行守门批准过的主页面网站、批准过的网页登记过的资源网站，其余的最多等 3 秒等登记，等不到就拒绝。
//! 往上连出口代理的浏览器通道，带浏览器通行证；之后两边原样转发（加密在 Chromium 和网站之间，这里看不到内容）。

use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine;
use proto::egress::{BROWSER_MAX_TUNNELS, site_of};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Notify, OwnedSemaphorePermit, Semaphore};

use super::Pass;
use super::approvals::{Approvals, Grant};

/// 资源的 CONNECT 比登记先到时最多等多久。
const ANNOUNCE_WAIT: Duration = Duration::from_secs(3);
/// 上行名额满了最多排多久。
const SLOT_WAIT: Duration = Duration::from_secs(10);
/// 名额满了时，空闲超过这么久的连接可以先关掉让位。
const EVICT_IDLE: Duration = Duration::from_secs(5);
/// 空闲多久断开。
const IDLE: Duration = Duration::from_secs(90);
const HEAD_LIMIT: usize = 8 << 10;

struct Conn {
    last: Arc<AtomicU64>,
    close: Arc<Notify>,
}

pub struct Forward {
    pub approvals: Arc<Approvals>,
    pub pass: Pass,
    /// 出口代理 `host:port`。
    pub proxy: String,
    pub insecure: bool,
    /// Chromium 主进程的 pid：只收它（和它的子进程）发来的连接。0 表示还没起。
    pub chromium: AtomicI32,
    /// 出错就关：守门出错、pipe 断开时设成 false，所有连接都拒绝。
    pub open: AtomicBool,
    slots: Arc<Semaphore>,
    conns: Mutex<HashMap<u64, Conn>>,
    next: AtomicU64,
    started: Instant,
    /// 查不到 `/proc/net/tcp`（降级成不检查来人）时只告警一次。
    warned: AtomicBool,
}

impl Forward {
    pub fn new(approvals: Arc<Approvals>, pass: Pass, proxy: String, insecure: bool) -> Arc<Self> {
        Arc::new(Self {
            approvals,
            pass,
            proxy,
            insecure,
            chromium: AtomicI32::new(0),
            open: AtomicBool::new(true),
            slots: Arc::new(Semaphore::new(BROWSER_MAX_TUNNELS as usize)),
            conns: Mutex::default(),
            next: AtomicU64::new(1),
            started: Instant::now(),
            warned: AtomicBool::new(false),
        })
    }

    /// 关掉：之后的连接都拒绝，开着的都断开。
    pub fn shut(&self) {
        self.open.store(false, Ordering::Release);
        for c in self
            .conns
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
        {
            c.close.notify_one();
        }
    }

    pub async fn serve(self: Arc<Self>, listener: TcpListener) {
        while let Ok((stream, peer)) = listener.accept().await {
            let local = stream.local_addr().ok();
            let this = self.clone();
            tokio::spawn(async move {
                if let Err(reason) = this.handle(stream, peer, local).await {
                    tracing::debug!(%peer, reason, "browser forward refused a connection");
                }
            });
        }
    }

    async fn handle(
        self: Arc<Self>,
        mut client: TcpStream,
        peer: SocketAddr,
        local: Option<SocketAddr>,
    ) -> Result<(), &'static str> {
        let (head, rest) =
            match tokio::time::timeout(Duration::from_secs(10), read_head(&mut client)).await {
                Ok(Ok(v)) => v,
                _ => return Err("bad_request"),
            };
        if !self.open.load(Ordering::Acquire) {
            return refuse(&mut client, 503, "closed").await;
        }
        if !self.peer_is_chromium(peer, local) {
            return refuse(&mut client, 403, "not_chromium").await;
        }
        let first = head.lines().next().unwrap_or_default();
        let mut parts = first.split_whitespace();
        let (Some(method), Some(target)) = (parts.next(), parts.next()) else {
            return refuse(&mut client, 400, "bad_request").await;
        };
        if method != "CONNECT" {
            return refuse(&mut client, 405, "not_https").await;
        }
        let Some((raw_host, port)) = target.rsplit_once(':') else {
            return refuse(&mut client, 400, "bad_request").await;
        };
        let port: u16 = port.parse().unwrap_or(0);
        let Ok(host) = proto::egress::normalize_host(raw_host, self.insecure) else {
            return refuse(&mut client, 403, "bad_address").await;
        };
        if port != 443 && !(self.insecure && port != 0) {
            return refuse(&mut client, 403, "bad_address").await;
        }
        let grant = match self.approvals.wait_allowed(&host, ANNOUNCE_WAIT).await {
            Some(g) => g,
            None if self.approvals.denied(&host) => {
                return refuse(&mut client, 403, "user_denied").await;
            }
            None => {
                tracing::info!(%host, "browser connection to a site no approved page asked for");
                return refuse(&mut client, 403, "not_announced").await;
            }
        };
        let Some(permit) = self.slot().await else {
            return refuse(&mut client, 429, "too_many_tunnels").await;
        };
        let (kind, page) = match grant {
            Grant::Main => ("nav", Some(site_of(&host))),
            Grant::Resource { page } => ("res", page),
        };
        let Some(pass) = super::pass_value(&self.pass) else {
            return refuse(&mut client, 503, "no_pass").await;
        };
        let mut upstream =
            match tokio::time::timeout(Duration::from_secs(10), TcpStream::connect(&self.proxy))
                .await
            {
                Ok(Ok(s)) => s,
                _ => return refuse(&mut client, 502, "proxy_unreachable").await,
            };
        let _ = upstream.set_nodelay(true);
        let cred = base64::engine::general_purpose::STANDARD.encode(format!(
            "{}:{}",
            proto::egress::BROWSER_USER,
            pass.as_str()
        ));
        let mut req = format!(
            "CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\nProxy-Authorization: Basic {cred}\r\n\
             X-Thinktin-Browser: kind={kind}{}\r\n\r\n",
            page.map(|p| format!("; page={p}")).unwrap_or_default()
        )
        .into_bytes();
        let sent = upstream.write_all(&req).await;
        zeroize::Zeroize::zeroize(&mut req);
        if sent.is_err() {
            return refuse(&mut client, 502, "proxy_unreachable").await;
        }
        let (reply, early) =
            match tokio::time::timeout(Duration::from_secs(30), read_head(&mut upstream)).await {
                Ok(Ok(v)) => v,
                _ => return refuse(&mut client, 502, "proxy_unreachable").await,
            };
        if !reply.starts_with("HTTP/1.1 200") && !reply.starts_with("HTTP/1.0 200") {
            // 代理拒绝了：原样告诉 Chromium（它只会报隧道失败，原因进 shim 日志）。
            tracing::info!(%host, reply = reply.lines().next().unwrap_or_default(), "the egress proxy refused a browser connection");
            let _ = client.write_all(reply.as_bytes()).await;
            let _ = client.write_all(&early).await;
            return Err("proxy_refused");
        }
        if client
            .write_all(b"HTTP/1.1 200 Connection established\r\n\r\n")
            .await
            .is_err()
        {
            return Err("client_gone");
        }
        if !early.is_empty() && client.write_all(&early).await.is_err() {
            return Err("client_gone");
        }
        if !rest.is_empty() && upstream.write_all(&rest).await.is_err() {
            return Err("proxy_gone");
        }
        self.splice(client, upstream, permit).await;
        Ok(())
    }

    /// 占一个上行名额：满了先关掉空闲最久的那条，再排队，最多等 10 秒。
    async fn slot(&self) -> Option<OwnedSemaphorePermit> {
        if let Ok(p) = self.slots.clone().try_acquire_owned() {
            return Some(p);
        }
        let now = self.now_ms();
        let idlest = self
            .conns
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .map(|c| {
                (
                    now.saturating_sub(c.last.load(Ordering::Relaxed)),
                    c.close.clone(),
                )
            })
            .filter(|(idle, _)| *idle >= EVICT_IDLE.as_millis() as u64)
            .max_by_key(|(idle, _)| *idle);
        if let Some((_, close)) = idlest {
            close.notify_one();
        }
        tokio::time::timeout(SLOT_WAIT, self.slots.clone().acquire_owned())
            .await
            .ok()?
            .ok()
    }

    fn now_ms(&self) -> u64 {
        u64::try_from(self.started.elapsed().as_millis()).unwrap_or(u64::MAX)
    }

    async fn splice(&self, client: TcpStream, upstream: TcpStream, permit: OwnedSemaphorePermit) {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let last = Arc::new(AtomicU64::new(self.now_ms()));
        let close = Arc::new(Notify::new());
        self.conns.lock().unwrap_or_else(|e| e.into_inner()).insert(
            id,
            Conn {
                last: last.clone(),
                close: close.clone(),
            },
        );
        let (cr, cw) = client.into_split();
        let (ur, uw) = upstream.into_split();
        let started = self.started;
        let mut a = tokio::spawn(pump(cr, uw, last.clone(), started));
        let mut b = tokio::spawn(pump(ur, cw, last.clone(), started));
        let mut tick = tokio::time::interval(Duration::from_secs(1));
        let (mut a_done, mut b_done) = (false, false);
        loop {
            tokio::select! {
                _ = close.notified() => break,
                _ = &mut a, if !a_done => { a_done = true; if b_done { break; } }
                _ = &mut b, if !b_done => { b_done = true; if a_done { break; } }
                _ = tick.tick() => {
                    if self.now_ms().saturating_sub(last.load(Ordering::Relaxed)) >= IDLE.as_millis() as u64
                        || !self.open.load(Ordering::Acquire)
                    {
                        break;
                    }
                }
            }
        }
        a.abort();
        b.abort();
        self.conns
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&id);
        drop(permit);
    }

    /// 来人是不是我们起的 Chromium（docs/browser.md 第 4.2 节第 2 条）：按对方的端口在 `/proc/net/tcp` 找到 socket，再看
    /// 这个 socket 在不在 Chromium 进程树里某个进程的 fd 下面。读不到 `/proc/net/tcp` 时降级成不检查（残余风险，写进文档）。
    fn peer_is_chromium(&self, peer: SocketAddr, local: Option<SocketAddr>) -> bool {
        let root = self.chromium.load(Ordering::Acquire);
        if root <= 0 {
            return false;
        }
        let Some(local) = local else {
            return false;
        };
        let inode = match socket_inode(peer.port(), local.port()) {
            Ok(Some(i)) => i,
            Ok(None) => return false,
            Err(()) => {
                if !self.warned.swap(true, Ordering::Relaxed) {
                    tracing::warn!(
                        "cannot read /proc/net/tcp; the browser forward does not check who connects"
                    );
                }
                return true;
            }
        };
        let needle = format!("socket:[{inode}]");
        process_tree(root).into_iter().any(|pid| {
            std::fs::read_dir(format!("/proc/{pid}/fd"))
                .into_iter()
                .flatten()
                .flatten()
                .any(|fd| {
                    std::fs::read_link(fd.path()).is_ok_and(|l| l.to_string_lossy() == needle)
                })
        })
    }
}

async fn pump<R, W>(mut from: R, mut to: W, last: Arc<AtomicU64>, started: Instant)
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let mut buf = vec![0u8; 16 << 10];
    loop {
        match from.read(&mut buf).await {
            Ok(0) | Err(_) => {
                let _ = to.shutdown().await;
                return;
            }
            Ok(n) => {
                if to.write_all(&buf[..n]).await.is_err() {
                    return;
                }
                last.store(
                    u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
                    Ordering::Relaxed,
                );
            }
        }
    }
}

/// 读到 `\r\n\r\n` 为止：返回头（文本）和多读进来的字节。
async fn read_head<S: AsyncRead + Unpin>(s: &mut S) -> std::io::Result<(String, Vec<u8>)> {
    let mut buf = Vec::with_capacity(1024);
    let mut chunk = [0u8; 1024];
    loop {
        let n = s.read(&mut chunk).await?;
        if n == 0 {
            return Err(std::io::ErrorKind::UnexpectedEof.into());
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            let rest = buf.split_off(end + 4);
            return Ok((String::from_utf8_lossy(&buf).into_owned(), rest));
        }
        if buf.len() > HEAD_LIMIT {
            return Err(std::io::ErrorKind::InvalidData.into());
        }
    }
}

async fn refuse(
    client: &mut TcpStream,
    status: u16,
    reason: &'static str,
) -> Result<(), &'static str> {
    let text = match status {
        400 => "Bad Request",
        403 => "Forbidden",
        405 => "Method Not Allowed",
        429 => "Too Many Requests",
        502 => "Bad Gateway",
        _ => "Service Unavailable",
    };
    let body = format!("thinktin browser: {reason}\n");
    let _ = client
        .write_all(
            format!(
                "HTTP/1.1 {status} {text}\r\nX-Thinktin-Egress: {reason}\r\nContent-Type: text/plain\r\n\
                 Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .as_bytes(),
        )
        .await;
    Err(reason)
}

/// 本机 `127.0.0.1:<peer_port>` → `127.0.0.1:<local_port>` 这条连接在 Chromium 那一端的 socket inode。读不到文件返回 Err。
fn socket_inode(peer_port: u16, local_port: u16) -> Result<Option<u64>, ()> {
    let mut readable = false;
    for path in ["/proc/net/tcp", "/proc/net/tcp6"] {
        let Ok(text) = std::fs::read_to_string(path) else {
            continue;
        };
        readable = true;
        for line in text.lines().skip(1) {
            let cols: Vec<&str> = line.split_whitespace().collect();
            if cols.len() < 10 {
                continue;
            }
            let port_of = |addr: &str| {
                addr.rsplit_once(':')
                    .and_then(|(_, p)| u16::from_str_radix(p, 16).ok())
            };
            if port_of(cols[1]) == Some(peer_port) && port_of(cols[2]) == Some(local_port) {
                return Ok(cols[9].parse().ok());
            }
        }
    }
    if readable { Ok(None) } else { Err(()) }
}

/// `root` 和它所有的子孙进程。
fn process_tree(root: i32) -> Vec<i32> {
    let mut parent: HashMap<i32, i32> = HashMap::new();
    for entry in std::fs::read_dir("/proc").into_iter().flatten().flatten() {
        let Ok(pid) = entry.file_name().to_string_lossy().parse::<i32>() else {
            continue;
        };
        let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) else {
            continue;
        };
        // 第 2 列是放在括号里的进程名（可能带空格），父进程是括号后面的第 2 列。
        let Some(after) = stat.rsplit_once(')').map(|(_, a)| a) else {
            continue;
        };
        if let Some(ppid) = after.split_whitespace().nth(1).and_then(|p| p.parse().ok()) {
            parent.insert(pid, ppid);
        }
    }
    let mut tree: HashSet<i32> = HashSet::from([root]);
    loop {
        let before = tree.len();
        for (pid, ppid) in &parent {
            if tree.contains(ppid) {
                tree.insert(*pid);
            }
        }
        if tree.len() == before {
            break;
        }
    }
    tree.into_iter().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn this_process_owns_its_own_connection() {
        // 本进程连自己监听的口：/proc/net/tcp 里找得到发起方的 socket，它在本进程的 fd 下面。
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let c = std::net::TcpStream::connect(addr).unwrap();
        let (_s, peer) = l.accept().unwrap();
        let inode = socket_inode(peer.port(), addr.port()).unwrap().unwrap();
        let me = std::process::id() as i32;
        let needle = format!("socket:[{inode}]");
        let found = std::fs::read_dir(format!("/proc/{me}/fd"))
            .unwrap()
            .flatten()
            .any(|fd| std::fs::read_link(fd.path()).is_ok_and(|l| l.to_string_lossy() == needle));
        assert!(found);
        assert!(process_tree(me).contains(&me));
        drop(c);
    }
}
