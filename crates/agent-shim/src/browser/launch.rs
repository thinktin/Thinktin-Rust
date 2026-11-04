//! 起 Chromium 和 Playwright MCP（docs/browser.md 第 2.4、2.6 节）。
//!
//! - Chromium 只开 `--remote-debugging-pipe`：在 `pre_exec` 里把两条 pipe 放到 fd 3（它读命令）和 fd 4（它写回复）；
//!   没有 TCP 调试端口。代理指向转发口，访问本机也走转发口（由转发口拒绝）。
//! - Node 启动脚本从 fd 3 读出前置口的地址和秘密，设进环境变量再加载 Playwright MCP：它们不进命令行和启动时的环境。
//!   秘密放在请求头里（不放网址里：Playwright 连不上时会把网址写进给 agent 看的错误）。
//! - 两个都用清空的环境变量加最少的几项启动（不带沙箱令牌和代理变量），单独一个进程组，`oom_score_adj=500`（内存不够时
//!   系统先杀浏览器，不杀 agent）。shim 不可转储，fork 出来到 exec 之前的子进程的 /proc/self 归 root、写不了，所以分数在
//!   exec 之后由子进程自己写（Chromium 套一层 `sh`，Node 在启动脚本里）。

use std::collections::BTreeMap;
use std::io::Write;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::{Path, PathBuf};
use std::process::Stdio;

use anyhow::Context;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::net::unix::pipe;
use tokio::process::{Child, ChildStdin, ChildStdout, Command};

use crate::process::{ProcessHandle, StderrTail};

/// 浏览器用到的路径和参数（镜像里的默认值，测试用环境变量换）。
#[derive(Debug, Clone)]
pub struct Paths {
    pub chromium: PathBuf,
    pub node: PathBuf,
    /// 放 `launch.cjs`、`tools.json` 和 `node_modules` 的目录。
    pub dir: PathBuf,
    /// 每次启动的临时配置放在这下面（不进工作区归档）。
    pub profile_root: PathBuf,
    /// Playwright 的截图、下载放这里（工作区里的 `.thinktin/browser`）。
    pub output_dir: PathBuf,
    /// Playwright MCP 的工作目录（工作区）。
    pub cwd: PathBuf,
    /// 另加给 Chromium 的参数（Phase 0 定下来要不要 `--no-sandbox`；测试里用）。
    pub extra_args: Vec<String>,
}

impl Paths {
    pub fn from_env(cwd: &Path) -> Self {
        let var = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
        Self {
            chromium: var("THINKTIN_BROWSER_CHROMIUM")
                .unwrap_or_else(|| "/usr/lib/chromium/chromium".into())
                .into(),
            node: var("THINKTIN_BROWSER_NODE")
                .unwrap_or_else(|| "/usr/local/bin/node".into())
                .into(),
            dir: var("THINKTIN_BROWSER_DIR")
                .unwrap_or_else(|| "/opt/thinktin/browser".into())
                .into(),
            profile_root: std::env::temp_dir().join("thinktin-browser"),
            output_dir: cwd.join(".thinktin").join("browser"),
            cwd: cwd.to_owned(),
            extra_args: var("THINKTIN_BROWSER_ARGS")
                .map(|a| a.split_whitespace().map(str::to_owned).collect())
                .unwrap_or_default(),
        }
    }

    pub fn tools_file(&self) -> PathBuf {
        self.dir.join("tools.json")
    }
}

/// 子进程的最小环境变量。
fn minimal_env(home: &Path) -> BTreeMap<String, String> {
    let mut env = BTreeMap::new();
    env.insert("PATH".into(), "/usr/local/bin:/usr/bin:/bin".into());
    env.insert("HOME".into(), home.display().to_string());
    env.insert("TMPDIR".into(), home.display().to_string());
    env.insert(
        "XDG_CONFIG_HOME".into(),
        home.join(".config").display().to_string(),
    );
    env.insert(
        "XDG_CACHE_HOME".into(),
        home.join(".cache").display().to_string(),
    );
    for k in ["LANG", "LC_ALL", "TZ"] {
        if let Ok(v) = std::env::var(k) {
            env.insert(k.into(), v);
        }
    }
    env.entry("LANG".into()).or_insert_with(|| "C.UTF-8".into());
    env
}

/// 一对 pipe：(读端, 写端)，都带 CLOEXEC。
fn pipe_pair() -> std::io::Result<(OwnedFd, OwnedFd)> {
    let mut fds = [0 as RawFd; 2];
    // SAFETY: pipe2 往数组里写两个新的 fd，成功后由 OwnedFd 接管。
    let rc = unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) };
    if rc != 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: 两个 fd 刚由 pipe2 创建，只归这里所有。
    Ok(unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) })
}

/// 复制到 10 号以上（带 CLOEXEC），子进程里 dup2 到 3、4 时不会和源 fd 撞号。
fn high(fd: &OwnedFd) -> std::io::Result<OwnedFd> {
    // SAFETY: fcntl F_DUPFD_CLOEXEC 返回一个新的 fd，由 OwnedFd 接管。
    let n = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 10) };
    if n < 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: n 是刚复制出来的 fd。
    Ok(unsafe { OwnedFd::from_raw_fd(n) })
}

/// 在子进程里（exec 之前）：把 `map` 里的 fd 放到指定的号上。只用异步信号安全的调用。
fn prepare_child(cmd: &mut Command, map: Vec<(RawFd, RawFd)>) {
    // SAFETY: 闭包在 fork 之后、exec 之前运行，只调 dup2，是异步信号安全的，不分配内存。
    unsafe {
        cmd.pre_exec(move || {
            for (from, to) in &map {
                if libc::dup2(*from, *to) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
            }
            Ok(())
        });
    }
}

/// 套在 Chromium 外面的一层 `sh`：exec 之后（这时 /proc/self 归本用户）写 `oom_score_adj`，再 exec 成 Chromium（pid 不变，
/// fd 3、4 照样在）。写不了也接着起。
const OOM_WRAPPER: &str =
    "{ echo 500 > /proc/self/oom_score_adj; } 2>/dev/null; exec \"$0\" \"$@\"";

fn spawn_stderr(child: &mut Child, label: &str) -> StderrTail {
    let tail = StderrTail::default();
    if let Some(stderr) = child.stderr.take() {
        let label = label.to_owned();
        let tail = tail.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                tracing::debug!(target: "browser", "[{label}] {line}");
                tail.push(line);
            }
        });
    }
    tail
}

pub struct Chromium {
    pub proc: ProcessHandle,
    pub pid: i32,
    /// 读回复和事件（Chromium 的 fd 4）。
    pub reader: pipe::Receiver,
    /// 写命令（Chromium 的 fd 3）。
    pub writer: pipe::Sender,
    pub stderr: StderrTail,
}

/// 起 Chromium：配置放在 `profile` 下，代理是 `127.0.0.1:<forward_port>`。
pub fn chromium(paths: &Paths, profile: &Path, forward_port: u16) -> anyhow::Result<Chromium> {
    let (cmd_r, cmd_w) = pipe_pair()?;
    let (ev_r, ev_w) = pipe_pair()?;
    let (cmd_r_hi, ev_w_hi) = (high(&cmd_r)?, high(&ev_w)?);
    drop((cmd_r, ev_w));
    let mut args: Vec<String> = vec![
        "--headless".into(),
        "--no-first-run".into(),
        "--no-default-browser-check".into(),
        format!("--user-data-dir={}", profile.join("profile").display()),
        "--remote-debugging-pipe".into(),
        format!("--proxy-server=http://127.0.0.1:{forward_port}"),
        "--proxy-bypass-list=<-loopback>".into(),
        "--disable-quic".into(),
        "--force-webrtc-ip-handling-policy=disable_non_proxied_udp".into(),
        "--disable-background-networking".into(),
        "--disable-component-update".into(),
        "--disable-sync".into(),
        "--disable-default-apps".into(),
        "--disable-extensions".into(),
        "--disable-features=Translate,MediaRouter,OptimizationHints".into(),
        // 后退、前进也重新请求网页（经过守门），不从缓存里直接恢复。
        "--disable-back-forward-cache".into(),
        "--disable-dev-shm-usage".into(),
        "--disable-gpu".into(),
        "--lang=zh-CN".into(),
        "--window-size=1280,800".into(),
    ];
    args.extend(paths.extra_args.iter().cloned());
    args.push("about:blank".into());
    let mut cmd = Command::new("/bin/sh");
    cmd.arg("-c")
        .arg(OOM_WRAPPER)
        .arg(&paths.chromium)
        .args(&args)
        .current_dir(profile)
        .env_clear()
        .envs(minimal_env(profile))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .process_group(0)
        .kill_on_drop(true);
    prepare_child(
        &mut cmd,
        vec![(cmd_r_hi.as_raw_fd(), 3), (ev_w_hi.as_raw_fd(), 4)],
    );
    let mut child = cmd
        .spawn()
        .with_context(|| format!("starting {}", paths.chromium.display()))?;
    // 子进程那一端交出去了，这边关掉（否则 Chromium 退出后读不到 EOF）。
    drop((cmd_r_hi, ev_w_hi));
    let stderr = spawn_stderr(&mut child, "chromium");
    let pid = child.id().context("chromium has no pid")? as i32;
    Ok(Chromium {
        proc: ProcessHandle::new(child, "chromium"),
        pid,
        reader: pipe::Receiver::from_owned_fd(ev_r)?,
        writer: pipe::Sender::from_owned_fd(cmd_w)?,
        stderr,
    })
}

pub struct Mcp {
    pub proc: ProcessHandle,
    pub stdin: ChildStdin,
    pub stdout: ChildStdout,
    pub stderr: StderrTail,
}

/// 起 Playwright MCP：`node <dir>/launch.cjs <参数>`，前置口地址 `front` 和秘密 `secret` 经 fd 3 交给启动脚本（两行）。
pub fn playwright_mcp(
    paths: &Paths,
    home: &Path,
    front: &str,
    secret: &str,
) -> anyhow::Result<Mcp> {
    let (r, w) = pipe_pair()?;
    let r_hi = high(&r)?;
    drop(r);
    {
        let mut w = std::fs::File::from(w);
        w.write_all(format!("{front}\n{secret}\n").as_bytes())?;
        // 写完就关：启动脚本读到 EOF。
    }
    std::fs::create_dir_all(&paths.output_dir).ok();
    let mut cmd = Command::new(&paths.node);
    cmd.arg(paths.dir.join("launch.cjs"))
        .args([
            "--no-webmcp",
            "--codegen",
            "none",
            "--timeout-navigation",
            "50000",
            "--console-level",
            "error",
            "--block-service-workers",
            "--output-dir",
        ])
        .arg(&paths.output_dir)
        .current_dir(&paths.cwd)
        .env_clear()
        .envs(minimal_env(home))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .kill_on_drop(true);
    prepare_child(&mut cmd, vec![(r_hi.as_raw_fd(), 3)]);
    let mut child = cmd
        .spawn()
        .with_context(|| format!("starting {}", paths.node.display()))?;
    drop(r_hi);
    let stderr = spawn_stderr(&mut child, "playwright-mcp");
    let stdin = child.stdin.take().context("no stdin")?;
    let stdout = child.stdout.take().context("no stdout")?;
    Ok(Mcp {
        proc: ProcessHandle::new(child, "playwright-mcp"),
        stdin,
        stdout,
        stderr,
    })
}

/// 32 字节随机数的十六进制（前置口的秘密路径）。
pub fn random_hex() -> anyhow::Result<String> {
    let mut b = [0u8; 32];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| std::io::Read::read_exact(&mut f, &mut b))
        .context("reading /dev/urandom")?;
    Ok(b.iter().map(|x| format!("{x:02x}")).collect())
}
