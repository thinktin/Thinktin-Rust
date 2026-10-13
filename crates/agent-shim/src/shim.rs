//! 监督循环（架构方案 3.3 第 1 条）：生成配置、启动辅助进程和 agent、握手、转发指令；
//! agent 崩溃后按退避策略重启并接回会话，连续失败超过上限才放弃。

use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{Context, anyhow, bail};
use catalog::{Harness, HarnessKind, Manifest};
use proto::shim::{SHIM_PROTOCOL_VERSION, ShimCommand, ShimEvent};
use serde_json::Value;
use tokio::sync::mpsc;

use crate::acp::{self, ConnectOptions, Outcome};
use crate::claude_cli;
use crate::config::{self, ModelRouting, RenderedConfig};
use crate::events::EventSink;
use crate::jsonrpc::Peer;
use crate::policy::PermissionPolicy;
use crate::process::{self, Launch, ProcessHandle};
use crate::state::{self, SavedSession};

/// 停进程时每一步（等自行退出、SIGTERM）最多等多久。
const STOP_GRACE: Duration = Duration::from_secs(3);
/// agent 连续正常运行这么久之后，重启计数清零。
const HEALTHY_UPTIME: Duration = Duration::from_secs(300);
const MAX_BACKOFF: Duration = Duration::from_secs(30);

#[derive(Debug, Clone)]
pub struct ShimConfig {
    pub manifest: Manifest,
    pub harness_id: String,
    /// agent 的 HOME，状态目录和生成的配置都在这里（工作区卷上）。
    pub home: PathBuf,
    /// 会话的工作目录。
    pub cwd: PathBuf,
    pub routing: ModelRouting,
    /// 注入给 agent 的 MCP 服务器，格式同 ACP `session/new` 的 `mcpServers`。
    pub mcp_servers: Vec<Value>,
    pub policy: PermissionPolicy,
    pub max_restarts: u32,
    pub handshake_timeout: Duration,
}

impl ShimConfig {
    fn harness(&self) -> anyhow::Result<&Harness> {
        self.manifest.harness(&self.harness_id).with_context(|| {
            format!(
                "agent `{}` has no harness `{}`",
                self.manifest.agent.id, self.harness_id
            )
        })
    }
}

pub async fn run(
    cfg: ShimConfig,
    mut cmds: mpsc::UnboundedReceiver<ShimCommand>,
    sink: EventSink,
) -> anyhow::Result<()> {
    let harness = cfg.harness()?.clone();
    let rendered = config::render(&cfg.manifest, &cfg.routing, &cfg.home, &cfg.cwd)?;
    rendered.write_files(&cfg.home)?;
    if !cfg.mcp_servers.is_empty() && !harness.session.per_session_mcp {
        tracing::warn!(
            "harness `{}` ignores per-session MCP servers; they are not injected yet",
            harness.id
        );
    }

    let mut restarts = 0u32;
    loop {
        let started = Instant::now();
        let code = match attempt(&cfg, &harness, &rendered, &mut cmds, &sink).await {
            Ok(Outcome::Shutdown) => return Ok(()),
            Ok(Outcome::AgentGone { code }) => code,
            Err(err) => {
                sink.emit(ShimEvent::Error {
                    run_id: None,
                    message: format!("{err:#}"),
                });
                None
            }
        };
        if started.elapsed() >= HEALTHY_UPTIME {
            restarts = 0;
        }
        let will_restart = restarts < cfg.max_restarts;
        sink.emit(ShimEvent::AgentExited {
            code,
            will_restart,
            restarts,
        });
        if !will_restart {
            bail!(
                "agent `{}` kept failing; gave up after {restarts} restarts",
                cfg.manifest.agent.id
            );
        }
        restarts += 1;
        let delay = Duration::from_secs(1 << (restarts - 1).min(5)).min(MAX_BACKOFF);
        if wait_or_shutdown(delay, &mut cmds, &sink).await {
            return Ok(());
        }
    }
}

/// 一次启动：辅助进程 → agent → 握手 → 驱动，结束时把进程都停掉。
async fn attempt(
    cfg: &ShimConfig,
    harness: &Harness,
    rendered: &RenderedConfig,
    cmds: &mut mpsc::UnboundedReceiver<ShimCommand>,
    sink: &EventSink,
) -> anyhow::Result<Outcome> {
    let mut env = rendered.env.clone();
    env.extend(harness.env.clone());

    let mut sidecars = Vec::new();
    let started = start_sidecars(cfg, harness, &env, &mut sidecars).await;
    let result = match started {
        Ok(()) => {
            let launch = Launch {
                label: cfg.manifest.agent.id.clone(),
                command: harness.command.clone(),
                env,
                cwd: cfg.cwd.clone(),
            };
            match harness.kind {
                HarnessKind::Acp => run_acp(cfg, harness, &launch, cmds, sink).await,
                HarnessKind::ClaudeStreamJson => {
                    claude_cli::run(cfg, harness, &launch, cmds, sink).await
                }
            }
        }
        Err(err) => Err(err),
    };
    for mut sidecar in sidecars {
        sidecar.terminate(STOP_GRACE).await;
    }
    result
}

async fn start_sidecars(
    cfg: &ShimConfig,
    harness: &Harness,
    env: &std::collections::BTreeMap<String, String>,
    started: &mut Vec<ProcessHandle>,
) -> anyhow::Result<()> {
    for sidecar in &harness.sidecars {
        let mut sidecar_env = env.clone();
        sidecar_env.extend(sidecar.env.clone());
        let launch = Launch {
            label: format!("{}/{}", cfg.manifest.agent.id, sidecar.name),
            command: sidecar.command.clone(),
            env: sidecar_env,
            cwd: cfg.cwd.clone(),
        };
        let mut spawned = process::spawn(&launch, false)?;
        let timeout = Duration::from_secs(sidecar.ready_timeout_secs.into());
        let ready =
            process::wait_tcp_ready(&sidecar.ready_tcp, timeout, &mut spawned.proc.child).await;
        let tail = spawned.stderr_tail.clone();
        started.push(spawned.proc);
        ready.map_err(|err| {
            anyhow!(
                "sidecar `{}` not ready: {err:#}\n{}",
                sidecar.name,
                tail.snapshot()
            )
        })?;
    }
    Ok(())
}

async fn run_acp(
    cfg: &ShimConfig,
    harness: &Harness,
    launch: &Launch,
    cmds: &mut mpsc::UnboundedReceiver<ShimCommand>,
    sink: &EventSink,
) -> anyhow::Result<Outcome> {
    let mut spawned = process::spawn(launch, true)?;
    let stdout = spawned.stdout.take().context("agent stdout not captured")?;
    let stdin = spawned.stdin.take().context("agent stdin not captured")?;
    let (peer, mut incoming) = Peer::start(stdout, stdin);

    let saved = previous_session(cfg, harness);
    let opts = ConnectOptions {
        cwd: &cfg.cwd,
        mcp_servers: &cfg.mcp_servers,
        restore_supported: harness.session.restore,
        per_session_mcp: harness.session.per_session_mcp,
        previous_session: saved.as_ref().map(|s| s.session_id.as_str()),
        handshake_timeout: cfg.handshake_timeout,
    };
    let connected = tokio::select! {
        r = acp::connect(&peer, &mut incoming, &opts) => r,
        status = spawned.proc.child.wait() => Err(anyhow!("agent exited during handshake ({status:?})")),
    };
    let connected = match connected {
        Ok(c) => c,
        Err(err) => {
            drop(peer);
            spawned.proc.terminate(STOP_GRACE).await;
            return Err(err.context(format!(
                "starting agent `{}` failed; recent stderr:\n{}",
                cfg.manifest.agent.id,
                spawned.stderr_tail.snapshot()
            )));
        }
    };
    if let (Some(reason), Some(prev)) = (&connected.restore_error, &saved) {
        sink.emit(ShimEvent::SessionLost {
            previous_session_id: prev.session_id.clone(),
            reason: reason.clone(),
        });
    }
    remember_session(cfg, harness, &connected.session_id);
    sink.emit(ShimEvent::Ready {
        protocol_version: SHIM_PROTOCOL_VERSION,
        agent_id: cfg.manifest.agent.id.clone(),
        harness: harness.id.clone(),
        agent_info: connected.agent_info.clone(),
        session_id: connected.session_id.clone(),
        session_restored: connected.restored,
    });

    let driver = acp::Driver {
        peer: peer.clone(),
        incoming,
        session_id: connected.session_id,
        sink,
        policy: &cfg.policy,
    };
    let outcome = driver.run(connected.backlog, cmds, &mut spawned.proc).await;
    // 放掉连接会关闭 agent 的 stdin，ACP agent 收到 EOF 后自行退出。
    drop(peer);
    if let Outcome::AgentGone { code } = &outcome {
        tracing::warn!(
            "agent exited (code {code:?}); recent stderr:\n{}",
            spawned.stderr_tail.snapshot()
        );
    }
    spawned.proc.terminate(STOP_GRACE).await;
    Ok(outcome)
}

/// 上次在同一 agent、同一接入方式、同一工作目录下的会话。
pub(crate) fn previous_session(cfg: &ShimConfig, harness: &Harness) -> Option<SavedSession> {
    state::load(&cfg.home).filter(|s| {
        s.agent_id == cfg.manifest.agent.id && s.harness == harness.id && s.cwd == cfg.cwd
    })
}

pub(crate) fn remember_session(cfg: &ShimConfig, harness: &Harness, session_id: &str) {
    let saved = SavedSession {
        agent_id: cfg.manifest.agent.id.clone(),
        harness: harness.id.clone(),
        cwd: cfg.cwd.clone(),
        session_id: session_id.to_owned(),
    };
    if let Err(err) = state::save(&cfg.home, &saved) {
        tracing::warn!("could not persist session state: {err}");
    }
}

/// 重启前的退避等待。期间收到的任务直接报错（编排服务会重试），收到停止指令立即返回真。
async fn wait_or_shutdown(
    delay: Duration,
    cmds: &mut mpsc::UnboundedReceiver<ShimCommand>,
    sink: &EventSink,
) -> bool {
    let sleep = tokio::time::sleep(delay);
    tokio::pin!(sleep);
    loop {
        tokio::select! {
            _ = &mut sleep => return false,
            cmd = cmds.recv() => match cmd {
                None | Some(ShimCommand::Shutdown) => return true,
                Some(ShimCommand::Prompt { run_id, .. } | ShimCommand::Cancel { run_id }) => {
                    sink.emit(ShimEvent::Error {
                        run_id: Some(run_id),
                        message: "agent is restarting".into(),
                    });
                }
                Some(ShimCommand::PermissionDecision { request_id, .. }) => {
                    sink.emit(ShimEvent::Error {
                        run_id: None,
                        message: format!("agent is restarting; permission request {request_id} is void"),
                    });
                }
            },
        }
    }
}
