//! 在实例的沙箱里启动 `agent-shim serve`，经它的标准输入输出收发指令和事件。
//!
//! - 沙箱令牌只经环境变量交给 shim（不进命令行参数，进程列表里看不到）。
//! - shim 在工作区卷上的目录里运行，agent 的配置和会话状态（`.thinktin/home`）随卷保留，
//!   沙箱重建后用 `session/load` 接回。
//! - 平台工具清单先写进沙箱里的文件，shim 启动时就有，agent 建会话时拿到的工具列表是完整的。

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use proto::shim::{EventEnvelope, ShimCommand, ShimEvent};
use sandbox::{EnvValue, ExecSpec, ProcessControl, SandboxId, SandboxProvider};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{Mutex, mpsc};
use tracing::{debug, warn};

use crate::shim::{ConnectError, ShimConnector, ShimLaunch, ShimProcess, ShimSession};

/// shim 的一行事件最长多少字节，超过的丢弃（防止异常输出把内存撑爆）。
const MAX_EVENT_LINE: u64 = 8 << 20;

#[derive(Debug, Clone)]
pub struct ExecConfig {
    /// agent-shim 在沙箱里的路径（模板里装好的）。
    pub shim_path: String,
    /// 模型网关地址（从沙箱里看）。
    pub gateway_url: String,
    /// shim 运行的目录，相对沙箱根，在工作区卷上。
    pub workdir: String,
    /// 本地开发、测试用：用这个清单文件代替内置清单。
    pub manifest_override: Option<String>,
    pub handshake_timeout: Duration,
}

impl Default for ExecConfig {
    fn default() -> Self {
        Self {
            shim_path: "agent-shim".into(),
            gateway_url: String::new(),
            workdir: "workspace".into(),
            manifest_override: None,
            handshake_timeout: Duration::from_secs(180),
        }
    }
}

pub struct ExecConnector {
    provider: Arc<dyn SandboxProvider>,
    cfg: ExecConfig,
}

impl ExecConnector {
    pub fn new(provider: Arc<dyn SandboxProvider>, cfg: ExecConfig) -> Self {
        Self { provider, cfg }
    }

    fn argv(&self, launch: &ShimLaunch, tools_file: Option<&str>) -> Vec<String> {
        let rt = &launch.instance;
        let mut argv = vec![self.cfg.shim_path.clone(), "serve".into()];
        match &self.cfg.manifest_override {
            Some(path) => argv.extend(["--manifest".into(), path.clone()]),
            None => argv.extend(["--agent".into(), rt.agent_id.clone()]),
        }
        argv.extend([
            "--harness".into(),
            rt.harness.clone(),
            "--home".into(),
            ".thinktin/home".into(),
            "--cwd".into(),
            ".".into(),
            "--gateway".into(),
            self.cfg.gateway_url.clone(),
            "--handshake-timeout-secs".into(),
            self.cfg.handshake_timeout.as_secs().max(1).to_string(),
            "--on-unlisted".into(),
            "ask".into(),
            "--ask-timeout-secs".into(),
            launch.ask_timeout.as_secs().max(1).to_string(),
        ]);
        if !launch.allow_tools.is_empty() {
            argv.extend(["--allow-tools".into(), launch.allow_tools.join(",")]);
        }
        for m in &launch.models {
            argv.extend(["--model".into(), m.clone()]);
        }
        if let Some(file) = tools_file {
            argv.extend([
                "--platform-tools".into(),
                "--platform-tools-file".into(),
                file.into(),
            ]);
        }
        argv
    }
}

struct ExecProcess {
    control: Mutex<Box<dyn ProcessControl>>,
}

#[async_trait]
impl ShimProcess for ExecProcess {
    async fn wait(&mut self) {
        let _ = self.control.lock().await.wait().await;
    }

    async fn kill(&mut self) {
        let _ = self.control.lock().await.kill().await;
    }
}

#[async_trait]
impl ShimConnector for ExecConnector {
    async fn start(&self, launch: &ShimLaunch) -> Result<ShimSession, ConnectError> {
        let rt = &launch.instance;
        let sid = SandboxId(
            rt.sandbox_id
                .clone()
                .ok_or_else(|| ConnectError("instance has no sandbox".into()))?,
        );
        let tools_file = if launch.platform_tools.is_empty() {
            None
        } else {
            let json = serde_json::to_vec(&launch.platform_tools)
                .map_err(|e| ConnectError(e.to_string()))?;
            self.provider
                .write_file(
                    &sid,
                    &format!("{}/.thinktin/platform-tools.json", self.cfg.workdir),
                    &json,
                )
                .await
                .map_err(|e| ConnectError(format!("writing the platform tool list: {e}")))?;
            Some(".thinktin/platform-tools.json")
        };
        let spec = ExecSpec {
            argv: self.argv(launch, tools_file),
            env: [(
                "THINKTIN_SANDBOX_TOKEN".to_owned(),
                EnvValue::Secret(launch.token.clone()),
            )]
            .into(),
            cwd: Some(self.cfg.workdir.clone()),
        };
        let process = self
            .provider
            .exec(&sid, spec)
            .await
            .map_err(|e| ConnectError(e.to_string()))?;
        let (cmd_tx, mut cmd_rx) = mpsc::channel::<ShimCommand>(64);
        let (ev_tx, ev_rx) = mpsc::channel::<ShimEvent>(256);
        let run = launch.run;

        let mut stdin = process.stdin;
        tokio::spawn(async move {
            while let Some(cmd) = cmd_rx.recv().await {
                let mut line = match serde_json::to_vec(&cmd) {
                    Ok(l) => l,
                    Err(e) => {
                        warn!(error = %e, "cannot encode shim command");
                        continue;
                    }
                };
                line.push(b'\n');
                if stdin.write_all(&line).await.is_err() || stdin.flush().await.is_err() {
                    break;
                }
            }
        });

        let mut stdout = BufReader::new(process.stdout);
        tokio::spawn(async move {
            let mut buf = Vec::new();
            loop {
                buf.clear();
                let n = match (&mut stdout)
                    .take(MAX_EVENT_LINE)
                    .read_until(b'\n', &mut buf)
                    .await
                {
                    Ok(n) => n,
                    Err(_) => break,
                };
                if n == 0 {
                    break;
                }
                if buf.last() != Some(&b'\n') && n as u64 >= MAX_EVENT_LINE {
                    warn!(%run, "dropping an oversized shim event");
                    // 跳过这一行剩下的部分。
                    let mut rest = Vec::new();
                    if stdout.read_until(b'\n', &mut rest).await.unwrap_or(0) == 0 {
                        break;
                    }
                    continue;
                }
                match serde_json::from_slice::<EventEnvelope>(&buf) {
                    Ok(env) => {
                        if ev_tx.send(env.event).await.is_err() {
                            break;
                        }
                    }
                    Err(e) => debug!(%run, error = %e, "ignoring a line that is not a shim event"),
                }
            }
        });

        let stderr = BufReader::new(process.stderr);
        tokio::spawn(async move {
            let mut lines = stderr.lines();
            let mut shown = 0;
            while let Ok(Some(line)) = lines.next_line().await {
                if shown < 1000 {
                    debug!(target: "agent_shim", %run, "{line}");
                    shown += 1;
                }
            }
        });

        Ok(ShimSession {
            commands: cmd_tx,
            events: ev_rx,
            process: Box::new(ExecProcess {
                control: Mutex::new(process.control),
            }),
        })
    }
}
