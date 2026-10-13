//! 启动和停止 agent 及其辅助进程。
//!
//! 子进程的环境变量从空白开始，只放行白名单里的系统变量，再加上配置生成器和清单给的变量，
//! 免得 shim 自己环境里的东西（比如别的凭证）漏给 agent。每个子进程单独一个进程组，
//! 停止时连同它派生的进程（Claude Code、Codex App Server、`pi --mode rpc` 等）一起结束。

use std::collections::{BTreeMap, VecDeque};
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, bail};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};

/// 从 shim 的环境里放行给 agent 的变量。
const INHERITED_ENV: &[&str] = &[
    "PATH",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "TZ",
    "TERM",
    "USER",
    "LOGNAME",
    "SHELL",
    "TMPDIR",
    // 沙箱出网走出口代理，证书由代理签发。
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "http_proxy",
    "https_proxy",
    "no_proxy",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "NODE_EXTRA_CA_CERTS",
    "REQUESTS_CA_BUNDLE",
    "CURL_CA_BUNDLE",
];

const STDERR_TAIL_LINES: usize = 40;

#[derive(Debug, Clone)]
pub struct Launch {
    /// 日志里用的名字。
    pub label: String,
    pub command: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub cwd: PathBuf,
}

pub struct Spawned {
    pub proc: ProcessHandle,
    pub stdin: Option<ChildStdin>,
    pub stdout: Option<ChildStdout>,
    pub stderr_tail: StderrTail,
}

/// 最近几行 stderr，agent 异常退出时放进错误信息。
#[derive(Clone, Default)]
pub struct StderrTail(Arc<Mutex<VecDeque<String>>>);

impl StderrTail {
    fn push(&self, line: String) {
        let mut lines = self.0.lock().unwrap();
        if lines.len() == STDERR_TAIL_LINES {
            lines.pop_front();
        }
        lines.push_back(line);
    }

    pub fn snapshot(&self) -> String {
        let lines = self.0.lock().unwrap();
        lines.iter().cloned().collect::<Vec<_>>().join("\n")
    }
}

/// 启动子进程。`stdio` 为真时接管 stdin/stdout（ACP、stream-json 用），否则丢弃 stdout。
pub fn spawn(launch: &Launch, stdio: bool) -> anyhow::Result<Spawned> {
    let (program, args) = launch.command.split_first().context("empty command")?;
    let mut cmd = Command::new(program);
    cmd.args(args)
        .current_dir(&launch.cwd)
        .env_clear()
        .envs(
            INHERITED_ENV
                .iter()
                .filter_map(|k| std::env::var(k).ok().map(|v| (*k, v))),
        )
        .envs(&launch.env)
        .stdin(if stdio { Stdio::piped() } else { Stdio::null() })
        .stdout(if stdio { Stdio::piped() } else { Stdio::null() })
        .stderr(Stdio::piped())
        .process_group(0)
        .kill_on_drop(true);
    let mut child = cmd
        .spawn()
        .with_context(|| format!("failed to start {} ({program})", launch.label))?;
    let stderr_tail = StderrTail::default();
    if let Some(stderr) = child.stderr.take() {
        let label = launch.label.clone();
        let tail = stderr_tail.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                tracing::info!(target: "agent", "[{label}] {line}");
                tail.push(line);
            }
        });
    }
    let pgid = child.id().context("child has no pid")? as libc::pid_t;
    tracing::info!("started {} (pid {pgid})", launch.label);
    Ok(Spawned {
        stdin: child.stdin.take(),
        stdout: child.stdout.take(),
        proc: ProcessHandle {
            child,
            pgid,
            label: launch.label.clone(),
        },
        stderr_tail,
    })
}

/// 子进程和它所在的进程组（组 id 就是启动时的 pid）。
pub struct ProcessHandle {
    pub child: Child,
    pgid: libc::pid_t,
    label: String,
}

impl ProcessHandle {
    /// 停止进程及其进程组：先等它自己退出（调用方应已关闭它的 stdin），再 SIGTERM，最后 SIGKILL。
    pub async fn terminate(&mut self, grace: Duration) {
        if !matches!(self.child.try_wait(), Ok(Some(_)))
            && tokio::time::timeout(grace, self.child.wait())
                .await
                .is_err()
        {
            self.signal_group(libc::SIGTERM);
            if tokio::time::timeout(grace, self.child.wait())
                .await
                .is_err()
            {
                self.signal_group(libc::SIGKILL);
                let _ = self.child.wait().await;
            }
        }
        // 主进程退出后，组里可能还留着它派生的进程。
        self.signal_group(libc::SIGKILL);
        tracing::info!("stopped {}", self.label);
    }

    fn signal_group(&self, signal: libc::c_int) {
        // SAFETY: killpg 只发信号，组 id 是我们启动子进程时创建的。组里没有进程时返回 ESRCH，忽略即可。
        unsafe {
            libc::killpg(self.pgid, signal);
        }
    }
}

/// 等辅助进程监听到指定的回环地址。进程提前退出则失败。
pub async fn wait_tcp_ready(
    addr: &str,
    timeout: Duration,
    child: &mut Child,
) -> anyhow::Result<()> {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        if tokio::net::TcpStream::connect(addr).await.is_ok() {
            return Ok(());
        }
        if let Some(status) = child.try_wait()? {
            bail!("exited with {status} before listening on {addr}");
        }
        if tokio::time::Instant::now() >= deadline {
            bail!("not listening on {addr} after {timeout:?}");
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}
