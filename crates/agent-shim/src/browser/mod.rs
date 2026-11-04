//! agent 的浏览器（docs/browser.md “实现设计与验收”）：Chromium + Playwright MCP 由 shim 运行，浏览器工具经 `thinktin` 桥
//! 交给五种 agent。打开一个没批准的网站时经出口代理问用户（访问一次 / 一直允许 / 拒绝），页面顺带加载的东西不问。
//!
//! ```text
//! agent ─MCP─▶ 桥 ─▶ BrowserService（工具层）─▶ Playwright MCP ─ws─▶ 前置口 ─┐
//!                                                    守门 ◀── CDP pipe ──▶ Chromium ─CONNECT─▶ 转发口 ─▶ 出口代理
//! ```
//!
//! - 编排服务开了浏览器时 shim 带着 `THINKTIN_BROWSER=1` 启动，`Ready` 之后经 stdin 发 [`ShimCommand::EnableBrowser`]
//!   交浏览器通行证；通行证只在 shim 内存里，不交给 agent、Chromium 和 Playwright。
//! - 一开始只列工具（`tools.json`），第一次调用浏览器工具才起 Chromium；拦截装好之前任何网页都打不开。
//! - 出错就关：pipe 断开、守门出错时马上杀掉 Chromium 的进程组、转发口拒绝所有连接；下次调用重新启动，最多重启 3 次。
//!
//! [`ShimCommand::EnableBrowser`]: proto::shim::ShimCommand::EnableBrowser

mod approvals;
mod cdp;
mod forward;
mod front;
mod gate;
mod launch;
mod mcp;
mod pages;
mod tools;

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use anyhow::Context;
use serde_json::Value;
use tokio::net::TcpListener;
use zeroize::Zeroizing;

use crate::bridge::ToolResult;
use approvals::Approvals;

pub use launch::Paths;
pub use tools::KEEP as TOOLS;

/// 浏览器通行证（只在内存里）。
pub(crate) type Pass = Arc<RwLock<Option<Zeroizing<String>>>>;

pub(crate) fn pass_value(p: &Pass) -> Option<Zeroizing<String>> {
    p.read().unwrap_or_else(|e| e.into_inner()).clone()
}

/// 一次工具调用的总时限（docs/browser.md 第 3.4 节：代理 40 秒 < 守门 42 秒 < Playwright 50 秒 < 这里 55 秒）。
const CALL_TIMEOUT: Duration = Duration::from_secs(55);
/// 起浏览器最多等多久。
const START_TIMEOUT: Duration = Duration::from_secs(20);
/// 起来以后又挂了，最多重启几次。
const MAX_RESTARTS: u32 = 3;
const STOP_GRACE: Duration = Duration::from_secs(1);

/// 浏览器的设置。
#[derive(Debug, Clone)]
pub struct BrowserOptions {
    pub paths: Paths,
    /// 出口代理 `host:port`（浏览器通道和问询都在这里）。
    pub proxy: String,
    /// 只用于本地测试：本机名、任意端口也能打开（出口代理那边照样要开 `--insecure-egress`）。
    pub insecure: bool,
}

impl BrowserOptions {
    /// 编排服务开了浏览器（`THINKTIN_BROWSER=1`）、沙箱经出口代理上网时才有。
    pub fn from_env(cwd: &Path, egress_proxy: Option<&str>) -> Option<Self> {
        if std::env::var("THINKTIN_BROWSER").ok().as_deref() != Some("1") {
            return None;
        }
        let Some(proxy) = egress_proxy else {
            tracing::warn!(
                "THINKTIN_BROWSER is set but the sandbox has no egress proxy; no browser"
            );
            return None;
        };
        Some(Self {
            paths: Paths::from_env(cwd),
            proxy: proxy.to_owned(),
            insecure: std::env::var("THINKTIN_BROWSER_INSECURE").ok().as_deref() == Some("1"),
        })
    }
}

/// 起来的一套：Chromium、守门、转发口、前置口、Playwright MCP。
struct Session {
    chromium: crate::process::ProcessHandle,
    mcp_proc: crate::process::ProcessHandle,
    mcp: Arc<mcp::McpClient>,
    forward: Arc<forward::Forward>,
    failed: Arc<AtomicBool>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
    dir: PathBuf,
    /// 前置口的秘密：万一出现在工具结果里就抹掉。
    secret: String,
}

/// 起到一半出错、或者起的时候被取消（超时）：已经起来的东西都收掉。起好了就 [`StartGuard::disarm`]。
#[derive(Default)]
struct StartGuard {
    forward: Option<Arc<forward::Forward>>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
    groups: Vec<i32>,
    dir: Option<PathBuf>,
}

impl StartGuard {
    fn disarm(&mut self) -> Vec<tokio::task::JoinHandle<()>> {
        self.forward = None;
        self.groups.clear();
        self.dir = None;
        std::mem::take(&mut self.tasks)
    }
}

impl Drop for StartGuard {
    fn drop(&mut self) {
        if let Some(f) = &self.forward {
            f.shut();
        }
        for t in &self.tasks {
            t.abort();
        }
        for g in &self.groups {
            kill_group(*g);
        }
        if let Some(d) = &self.dir {
            let _ = std::fs::remove_dir_all(d);
        }
    }
}

impl Session {
    async fn stop(mut self) {
        self.forward.shut();
        for t in &self.tasks {
            t.abort();
        }
        self.mcp_proc.terminate(STOP_GRACE).await;
        self.chromium.kill_group();
        self.chromium.terminate(STOP_GRACE).await;
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

pub struct BrowserService {
    opts: BrowserOptions,
    tools: Vec<Value>,
    pass: Pass,
    approvals: Arc<Approvals>,
    navigating: Arc<AtomicBool>,
    run: Mutex<Option<String>>,
    session: tokio::sync::Mutex<Option<Session>>,
    /// 一次只跑一个工具调用：Claude 见到只读的工具会并行调，几个调用同时点同一个标签页会互相打断，结果第一行也会串。
    calls: tokio::sync::Mutex<()>,
    /// 起过几次（第一次不算重启）。
    starts: AtomicU32,
    /// 起不来（连试两次都失败）：之后的调用直接告诉 agent 用别的办法。
    unavailable: AtomicBool,
    attempt: String,
}

impl BrowserService {
    pub fn new(opts: BrowserOptions) -> Arc<Self> {
        let tools = std::fs::read_to_string(opts.paths.tools_file())
            .map(|t| tools::load(&t))
            .unwrap_or_else(|e| {
                tracing::warn!(error = %e, path = %opts.paths.tools_file().display(), "no browser tool list; no browser");
                Vec::new()
            });
        let attempt = launch::random_hex()
            .map(|h| h[..12].to_owned())
            .unwrap_or_else(|_| std::process::id().to_string());
        Arc::new(Self {
            opts,
            tools,
            pass: Arc::default(),
            approvals: Arc::default(),
            navigating: Arc::default(),
            run: Mutex::default(),
            session: tokio::sync::Mutex::default(),
            calls: tokio::sync::Mutex::default(),
            starts: AtomicU32::new(0),
            unavailable: AtomicBool::new(false),
            attempt,
        })
    }

    /// 给 agent 列的工具（MCP 格式）。
    pub fn tools(&self) -> &[Value] {
        &self.tools
    }

    pub fn has_tool(&self, name: &str) -> bool {
        self.tools.iter().any(|t| t["name"] == name)
    }

    /// 编排服务交来浏览器通行证（`EnableBrowser`）。
    pub fn enable(&self, pass: String) {
        *self.pass.write().unwrap_or_else(|e| e.into_inner()) = Some(Zeroizing::new(pass));
    }

    /// 一轮开始、结束：清掉这次任务的批准记录（docs/browser.md 第 3.1 节第 8 条）。
    pub fn begin_run(&self, run_id: &str) {
        *self.run.lock().unwrap_or_else(|e| e.into_inner()) = Some(run_id.to_owned());
        self.approvals.clear();
    }

    pub fn end_run(&self, run_id: &str) {
        let mut run = self.run.lock().unwrap_or_else(|e| e.into_inner());
        if run.as_deref() == Some(run_id) {
            *run = None;
        }
        drop(run);
        self.approvals.clear();
    }

    /// shim 退出：浏览器和辅助进程一起停。
    pub async fn stop(&self) {
        if let Some(s) = self.session.lock().await.take() {
            s.stop().await;
        }
        *self.pass.write().unwrap_or_else(|e| e.into_inner()) = None;
    }

    pub async fn call(&self, name: &str, mut args: Value) -> ToolResult {
        if !self.has_tool(name) {
            return ToolResult::error(format!("unknown tool `{name}`"));
        }
        if self.run.lock().unwrap_or_else(|e| e.into_inner()).is_none() {
            return ToolResult::error("the browser is only available while a task is running");
        }
        if pass_value(&self.pass).is_none() {
            return ToolResult::error(
                "the browser is not enabled for this task; use web_search instead",
            );
        }
        if let Err(e) = tools::check(name, &mut args) {
            return ToolResult::error(e);
        }
        let _one_at_a_time = self.calls.lock().await;
        // 排队的时间不算进这次调用的 55 秒。
        let started = Instant::now();
        let deadline = tokio::time::Instant::now() + CALL_TIMEOUT;
        let (client, failed, secret) = match tokio::time::timeout(CALL_TIMEOUT, self.ensure()).await
        {
            Ok(Ok(c)) => c,
            Ok(Err(e)) => return ToolResult::error(e),
            Err(_) => return ToolResult::error("the browser did not start in time; try again"),
        };
        let navigating = matches!(name, "browser_navigate" | "browser_navigate_back")
            || (name == "browser_tabs" && args.get("url").is_some());
        if navigating {
            self.navigating.store(true, Ordering::Release);
        }
        let left = CALL_TIMEOUT.saturating_sub(started.elapsed());
        let result = tokio::time::timeout(left, client.call(name, args)).await;
        if navigating {
            self.navigating.store(false, Ordering::Release);
        }
        // 点了链接、提交了表单：Playwright 先回来了，问用户的还在等。等它问完（在 55 秒以内），结果算进这次调用。
        self.approvals.wait_asks(started, deadline).await;
        let mut outcomes = self.approvals.outcomes_since(started);
        let now = Instant::now();
        outcomes.extend(
            self.approvals
                .asking_since(started)
                .into_iter()
                .map(|host| approvals::Outcome {
                    at: now,
                    host,
                    result: "pending".into(),
                    asked: true,
                }),
        );
        let mut r = Self::result(result, &outcomes, &failed);
        // 万一前置口的秘密出现在结果里（Playwright 的错误会带上连接地址），抹掉。
        for item in &mut r.content {
            if let Some(t) = item["text"].as_str()
                && t.contains(secret.as_str())
            {
                item["text"] = Value::from(t.replace(secret.as_str(), "<redacted>"));
            }
        }
        r
    }

    fn result(
        result: Result<Result<Value, crate::jsonrpc::RpcError>, tokio::time::error::Elapsed>,
        outcomes: &[approvals::Outcome],
        failed: &AtomicBool,
    ) -> ToolResult {
        match result {
            Ok(Ok(v)) => tools::finish(v, outcomes),
            Ok(Err(e)) => {
                // Playwright MCP 退出了：下次调用重新起整套。
                if e.code == crate::jsonrpc::RpcError::CLOSED {
                    failed.store(true, Ordering::Release);
                }
                let mut r = ToolResult::error(format!("browser error: {}", e.message));
                if let Some(line) = tools::status(outcomes) {
                    r.content
                        .insert(0, serde_json::json!({"type": "text", "text": line}));
                }
                r
            }
            Err(_) => {
                let mut r = ToolResult::error(
                    "the browser did not finish in 55 seconds; check the page with browser_snapshot",
                );
                if let Some(line) = tools::status(outcomes) {
                    r.content
                        .insert(0, serde_json::json!({"type": "text", "text": line}));
                }
                r
            }
        }
    }

    /// 拿到能用的一套：没有、挂了就（重新）起。
    async fn ensure(&self) -> Result<(Arc<mcp::McpClient>, Arc<AtomicBool>, String), String> {
        if self.unavailable.load(Ordering::Acquire) {
            return Err(UNAVAILABLE.into());
        }
        let mut guard = self.session.lock().await;
        if let Some(s) = guard.as_ref()
            && !s.failed.load(Ordering::Acquire)
        {
            return Ok((s.mcp.clone(), s.failed.clone(), s.secret.clone()));
        }
        if let Some(old) = guard.take() {
            tracing::warn!("the browser failed; restarting it");
            old.stop().await;
        }
        let starts = self.starts.load(Ordering::Acquire);
        if starts > MAX_RESTARTS {
            self.unavailable.store(true, Ordering::Release);
            return Err(UNAVAILABLE.into());
        }
        // 起不来的重试一次；还不行就标成不可用。
        let mut last = None;
        for _ in 0..2 {
            let n = self.starts.fetch_add(1, Ordering::AcqRel);
            match tokio::time::timeout(START_TIMEOUT, self.start(n)).await {
                Ok(Ok(s)) => {
                    let client = (s.mcp.clone(), s.failed.clone(), s.secret.clone());
                    *guard = Some(s);
                    return Ok(client);
                }
                Ok(Err(e)) => last = Some(format!("{e:#}")),
                Err(_) => last = Some("timed out".into()),
            }
        }
        tracing::error!(error = ?last, "the browser could not start");
        self.unavailable.store(true, Ordering::Release);
        Err(UNAVAILABLE.into())
    }

    async fn start(&self, n: u32) -> anyhow::Result<Session> {
        use std::os::unix::fs::DirBuilderExt;
        let dir = self
            .opts
            .paths
            .profile_root
            .join(format!("{}-{n}", self.attempt));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir)
            .with_context(|| format!("creating {}", dir.display()))?;
        // 出错、或者被取消（外面的超时）时，下面起来的都由它收掉。
        let mut guard = StartGuard::default();
        guard.dir = Some(dir.clone());
        let failed = Arc::new(AtomicBool::new(false));

        // 1. 转发口。
        let fwd_listener = TcpListener::bind("127.0.0.1:0").await?;
        let fwd_port = fwd_listener.local_addr()?.port();
        let forward = forward::Forward::new(
            self.approvals.clone(),
            self.pass.clone(),
            self.opts.proxy.clone(),
            self.opts.insecure,
        );
        guard.forward = Some(forward.clone());
        guard
            .tasks
            .push(tokio::spawn(forward.clone().serve(fwd_listener)));

        // 2. Chromium。
        let chromium = launch::chromium(&self.opts.paths, &dir, fwd_port)?;
        guard.groups.push(chromium.pid);
        forward.chromium.store(chromium.pid, Ordering::Release);
        let (cdp, events) = cdp::Cdp::start(chromium.reader, chromium.writer);
        let chromium_proc = chromium.proc;
        let chromium_err = chromium.stderr;

        // 3. 守门：自动接上、先停住所有新页面。装好之前任何网页都打不开。
        let gate = gate::Gate::new(
            cdp.clone(),
            self.approvals.clone(),
            gate::Asker {
                proxy: self.opts.proxy.clone(),
                pass: self.pass.clone(),
            },
            self.navigating.clone(),
            self.opts.insecure,
        );
        gate.install().await.with_context(|| {
            format!(
                "the browser did not accept the gate; recent output:\n{}",
                chromium_err.snapshot()
            )
        })?;
        {
            let failed = failed.clone();
            let forward = forward.clone();
            let pid = chromium.pid;
            guard.tasks.push(tokio::spawn(async move {
                gate.run(events).await;
                // pipe 断了：出错就关。
                failed.store(true, Ordering::Release);
                forward.shut();
                kill_group(pid);
            }));
        }
        // 4. 前置口：秘密放在请求头里。
        let front_listener = TcpListener::bind("127.0.0.1:0").await?;
        let front_port = front_listener.local_addr()?.port();
        let secret = launch::random_hex()?;
        let url = format!("ws://127.0.0.1:{front_port}/");
        guard.tasks.push(tokio::spawn(front::serve(
            front_listener,
            secret.clone(),
            cdp.clone(),
        )));
        // 5. Playwright MCP。
        let m = launch::playwright_mcp(&self.opts.paths, &dir, &url, &secret)?;
        if let Some(pid) = m.proc.child.id() {
            guard.groups.push(pid as i32);
        }
        let mut mcp_proc = m.proc;
        let client = match mcp::McpClient::connect(m.stdout, m.stdin, START_TIMEOUT).await {
            Ok(c) => c,
            Err(e) => {
                let tail = m.stderr.snapshot();
                mcp_proc.terminate(STOP_GRACE).await;
                return Err(e.context(format!("recent output:\n{tail}")));
            }
        };
        let tasks = guard.disarm();
        Ok(Session {
            chromium: chromium_proc,
            mcp_proc,
            mcp: Arc::new(client),
            forward,
            failed,
            tasks,
            dir,
            secret,
        })
    }
}

const UNAVAILABLE: &str =
    "browser unavailable in this sandbox; use web_search and plain fetches instead";

fn kill_group(pid: i32) {
    if pid > 0 {
        // SAFETY: 只发信号；组 id 是我们用 process_group(0) 起 Chromium 时建的。
        unsafe {
            libc::killpg(pid, libc::SIGKILL);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn text(r: &ToolResult) -> String {
        r.content
            .iter()
            .filter_map(|c| c["text"].as_str())
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// 真的起 Chromium 和 Playwright MCP（本机冒烟，docs/browser.md 第 8.2 节）：要先起假出口代理和测试网站
    /// （`THINKTIN_BROWSER_SMOKE_PROXY`、`THINKTIN_BROWSER_SMOKE_PORT`），并设好 `THINKTIN_BROWSER_CHROMIUM`、
    /// `THINKTIN_BROWSER_NODE`、`THINKTIN_BROWSER_DIR`、`THINKTIN_BROWSER_ARGS=--ignore-certificate-errors`。
    #[tokio::test]
    #[ignore = "needs Chromium, Node, Playwright MCP and the local harness"]
    async fn browser_smoke() {
        let proxy = std::env::var("THINKTIN_BROWSER_SMOKE_PROXY").expect("proxy");
        let port: u16 = std::env::var("THINKTIN_BROWSER_SMOKE_PORT")
            .expect("port")
            .parse()
            .unwrap();
        let work = tempfile::tempdir().unwrap();
        let svc = BrowserService::new(BrowserOptions {
            paths: Paths::from_env(work.path()),
            proxy,
            insecure: true,
        });
        assert!(svc.has_tool("browser_navigate"));
        assert!(!svc.has_tool("browser_evaluate"));
        svc.begin_run("run-1");
        let r = svc
            .call(
                "browser_navigate",
                json!({"url": format!("https://site.test:{port}/")}),
            )
            .await;
        assert!(r.is_error, "no pass yet");
        svc.enable("pass-123".into());
        let r = svc
            .call(
                "browser_navigate",
                json!({"url": format!("https://site.test:{port}/")}),
            )
            .await;
        let t = text(&r);
        assert!(!r.is_error, "{t}");
        assert!(t.starts_with("approved: the user allowed site.test"), "{t}");
        assert!(t.contains("Page Title: Site"), "{t}");
        // 打开网页时快照存成工作区里的文件；browser_snapshot 直接返回。
        let r = svc.call("browser_snapshot", json!({})).await;
        let snap = text(&r);
        assert!(snap.contains("Hello from site"), "{snap}");
        // 点网页里去没批准网站的链接：Playwright 先回来，问询还在等；结果照样写在这次调用的第一行。
        let link = snap
            .split("link \"other\" [ref=")
            .nth(1)
            .and_then(|r| r.split(']').next())
            .expect("a link to other.test");
        let r = svc
            .call("browser_click", json!({"element": "other", "target": link}))
            .await;
        assert!(
            text(&r).starts_with("pending_approval: opening other.test"),
            "{}",
            text(&r)
        );
        let r = svc
            .call(
                "browser_navigate",
                json!({"url": format!("https://site.test:{port}/")}),
            )
            .await;
        assert!(!r.is_error, "{}", text(&r));
        // 同一个网站不用再问。
        let r = svc
            .call(
                "browser_navigate",
                json!({"url": format!("https://site.test:{port}/again")}),
            )
            .await;
        assert!(!text(&r).starts_with("approved"), "{}", text(&r));
        // 代理直接放行的（开发网站这类）：不说“用户允许了”。
        let r = svc
            .call(
                "browser_navigate",
                json!({"url": format!("https://dev.test:{port}/")}),
            )
            .await;
        assert!(!text(&r).starts_with("approved"), "{}", text(&r));
        // 没人答的网站：说明页，第一行 pending_approval。
        let r = svc
            .call(
                "browser_navigate",
                json!({"url": format!("https://other.test:{port}/")}),
            )
            .await;
        let t = text(&r);
        assert!(t.starts_with("pending_approval: opening other.test"), "{t}");
        assert!(t.contains("needs the user's approval"), "{t}");
        // 拒绝的网站。
        let r = svc
            .call(
                "browser_navigate",
                json!({"url": format!("https://deny.test:{port}/")}),
            )
            .await;
        assert!(text(&r).starts_with("user_denied:"), "{}", text(&r));
        // 不收的网址、被去掉的工具。
        let r = svc
            .call("browser_navigate", json!({"url": "file:///etc/passwd"}))
            .await;
        assert!(r.is_error);
        let r = svc
            .call("browser_evaluate", json!({"function": "() => 1"}))
            .await;
        assert!(r.is_error);
        let r = svc.call("browser_snapshot", json!({})).await;
        assert!(!r.is_error, "{}", text(&r));
        svc.end_run("run-1");
        svc.stop().await;
    }
}
