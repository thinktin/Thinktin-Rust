//! 沙箱内守护进程：按清单启动开源 agent，用 ACP 或 Claude Code stream-json 驱动它，
//! 注入模型配置、转发权限请求、上报事件（架构方案 3.3）。

mod acp;
mod bridge;
mod claude_cli;
mod config;
mod events;
mod jsonrpc;
mod policy;
mod process;
mod shim;
mod state;

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use anyhow::{Context, bail};
use catalog::{LlmProtocol, Manifest};
use clap::{Args, Parser, Subcommand, ValueEnum};
use proto::shim::{EventEnvelope, ShimCommand, ShimEvent, StopReason};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

use crate::config::{ModelAlias, ModelRouting};
use crate::events::EventSink;
use crate::policy::{Fallback, PermissionPolicy};
use crate::shim::ShimConfig;

#[derive(Parser)]
#[command(
    name = "agent-shim",
    version,
    about = "ThinkTin 沙箱内守护进程：驱动开源 agent"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// 列出内置的 agent 清单（按接入优先级）
    Manifests,
    /// 只生成 agent 配置：写入文件，打印环境变量（令牌打码）
    RenderConfig {
        #[command(flatten)]
        agent: AgentArgs,
        #[command(flatten)]
        routing: RoutingArgs,
    },
    /// 常驻模式：从 stdin 读指令、往 stdout 写事件，都是 JSON Lines
    Serve {
        #[command(flatten)]
        common: CommonArgs,
        #[command(flatten)]
        bridge: BridgeArgs,
    },
    /// 平台工具桥：由 agent 作为 MCP 服务器启动，把工具调用转给 shim（不要手动运行）
    McpBridge {
        #[arg(long)]
        socket: PathBuf,
    },
    /// 让 agent 跑一轮任务后退出，用于本地调试和冒烟测试
    Run {
        #[command(flatten)]
        common: CommonArgs,
        #[arg(long)]
        prompt: String,
        /// 输出格式：json 每行一个事件；text 只把回复正文打到 stdout，其余事件打到 stderr
        #[arg(long, value_enum, default_value_t = Format::Json)]
        format: Format,
    },
}

#[derive(Clone, Copy, ValueEnum)]
enum Format {
    Json,
    Text,
}

#[derive(Args)]
struct AgentArgs {
    /// 内置清单的 id（claude、codex、pi、openclaw、hermes）
    #[arg(
        long,
        required_unless_present = "manifest",
        conflicts_with = "manifest"
    )]
    agent: Option<String>,
    /// 清单文件（代替内置清单）
    #[arg(long)]
    manifest: Option<PathBuf>,
    /// 接入方式，默认用清单里的第一个
    #[arg(long)]
    harness: Option<String>,
    /// agent 的 HOME，生成的配置和 agent 状态都放在这里
    #[arg(long, env = "HOME")]
    home: PathBuf,
    /// 会话工作目录，默认当前目录
    #[arg(long)]
    cwd: Option<PathBuf>,
}

impl AgentArgs {
    fn manifest(&self) -> anyhow::Result<Manifest> {
        match (&self.agent, &self.manifest) {
            (Some(id), _) => catalog::builtin(id).with_context(|| {
                let known: Vec<_> = catalog::builtin_ids().collect();
                format!("unknown agent `{id}` (built-in: {})", known.join(", "))
            }),
            (None, Some(path)) => {
                let text = std::fs::read_to_string(path)
                    .with_context(|| format!("reading {}", path.display()))?;
                Ok(Manifest::from_toml(&text)?)
            }
            (None, None) => bail!("either --agent or --manifest is required"),
        }
    }

    fn dirs(&self) -> anyhow::Result<(PathBuf, PathBuf)> {
        let home = absolute(&self.home)?;
        let cwd = match &self.cwd {
            Some(dir) => absolute(dir)?,
            None => std::env::current_dir()?,
        };
        std::fs::create_dir_all(&home)?;
        Ok((home, cwd))
    }
}

fn absolute(p: &std::path::Path) -> anyhow::Result<PathBuf> {
    std::fs::create_dir_all(p).with_context(|| format!("creating {}", p.display()))?;
    p.canonicalize()
        .with_context(|| format!("resolving {}", p.display()))
}

#[derive(Args)]
struct RoutingArgs {
    /// 模型网关地址
    #[arg(long, env = "THINKTIN_LLM_GATEWAY")]
    gateway: String,
    /// 从哪个环境变量读沙箱令牌（不走命令行参数，免得出现在进程列表里）
    #[arg(long, default_value = config::TOKEN_ENV)]
    token_env: String,
    /// 模型别名，可重复；第一个是默认模型。名为 fast 的别名用于轻量任务。
    /// 可带上下文窗口和最大输出 token：main:131072:8192
    #[arg(long = "model", default_value = "main", value_parser = parse_model)]
    models: Vec<ModelAlias>,
    #[arg(long)]
    default_model: Option<String>,
    /// 指定模型协议：anthropic-messages、openai-completions、openai-responses
    #[arg(long, value_parser = parse_protocol)]
    protocol: Option<LlmProtocol>,
}

fn parse_model(s: &str) -> Result<ModelAlias, String> {
    let mut parts = s.split(':');
    let id = parts
        .next()
        .filter(|id| !id.is_empty())
        .ok_or("empty model alias")?;
    let mut number = |what: &str| -> Result<Option<u32>, String> {
        parts
            .next()
            .map(|n| {
                n.parse()
                    .map_err(|_| format!("{what} must be a number in `{s}`"))
            })
            .transpose()
    };
    let mut alias = ModelAlias::new(id);
    alias.context_window = number("context window")?;
    alias.max_output_tokens = number("max output tokens")?;
    if parts.next().is_some() {
        return Err(format!(
            "expected alias[:context_window[:max_output_tokens]], got `{s}`"
        ));
    }
    Ok(alias)
}

fn parse_protocol(s: &str) -> Result<LlmProtocol, String> {
    serde_json::from_value(Value::String(s.into())).map_err(|_| {
        "expected anthropic-messages, openai-completions or openai-responses".to_string()
    })
}

impl RoutingArgs {
    fn routing(&self) -> anyhow::Result<ModelRouting> {
        let token = std::env::var(&self.token_env)
            .with_context(|| format!("sandbox token variable {} is not set", self.token_env))?;
        let default_model = self
            .default_model
            .clone()
            .unwrap_or_else(|| self.models[0].id.clone());
        Ok(ModelRouting {
            gateway_url: self.gateway.clone(),
            token,
            models: self.models.clone(),
            default_model,
            protocol: self.protocol,
        })
    }
}

#[derive(Args)]
struct PermissionArgs {
    /// 预授权的工具类别，逗号分隔，`*` 表示全部（如 read,search,edit）
    #[arg(long, value_delimiter = ',')]
    allow_tools: Vec<String>,
    /// 预授权范围之外的请求：ask 交给用户（只能用于 serve），reject 直接拒绝
    #[arg(long, value_enum)]
    on_unlisted: Option<Fallback>,
    /// 交给用户决定时最长等多少秒
    #[arg(long, default_value_t = 24 * 3600)]
    ask_timeout_secs: u64,
}

impl PermissionArgs {
    fn policy(&self, default: Fallback) -> PermissionPolicy {
        PermissionPolicy {
            allow: self
                .allow_tools
                .iter()
                .map(|s| s.trim().to_owned())
                .collect(),
            otherwise: self.on_unlisted.unwrap_or(default),
            ask_timeout: Duration::from_secs(self.ask_timeout_secs),
        }
    }
}

#[derive(Args)]
struct BridgeArgs {
    /// 给 agent 注入平台工具（MCP 服务器 `thinktin`），工具列表由平台用 set_platform_tools 指令下发
    #[arg(long)]
    platform_tools: bool,
    /// 启动时就有的平台工具（JSON 数组，元素是 {name, description, input_schema}）
    #[arg(long, requires = "platform_tools")]
    platform_tools_file: Option<PathBuf>,
    /// 平台工具调用最长等多久
    #[arg(long, default_value_t = 600)]
    platform_tool_timeout_secs: u64,
}

#[derive(Args)]
struct CommonArgs {
    #[command(flatten)]
    agent: AgentArgs,
    #[command(flatten)]
    routing: RoutingArgs,
    #[command(flatten)]
    permissions: PermissionArgs,
    /// MCP 服务器列表文件（JSON 数组，格式同 ACP session/new 的 mcpServers）
    #[arg(long)]
    mcp_config: Option<PathBuf>,
    /// agent 连续失败时最多重启几次；serve 默认 5，run 默认 0
    #[arg(long)]
    max_restarts: Option<u32>,
    /// 启动和握手的超时秒数
    #[arg(long, default_value_t = 120)]
    handshake_timeout_secs: u64,
}

impl CommonArgs {
    fn shim_config(
        &self,
        default_fallback: Fallback,
        default_restarts: u32,
    ) -> anyhow::Result<ShimConfig> {
        let manifest = self.agent.manifest()?;
        let harness_id = self
            .agent
            .harness
            .clone()
            .unwrap_or_else(|| manifest.default_harness().id.clone());
        let (home, cwd) = self.agent.dirs()?;
        let mcp_servers = match &self.mcp_config {
            Some(path) => {
                let text = std::fs::read_to_string(path)
                    .with_context(|| format!("reading {}", path.display()))?;
                serde_json::from_str::<Vec<Value>>(&text)
                    .with_context(|| format!("{} must be a JSON array", path.display()))?
            }
            None => Vec::new(),
        };
        Ok(ShimConfig {
            manifest,
            harness_id,
            home,
            cwd,
            routing: self.routing.routing()?,
            mcp_servers,
            policy: self.permissions.policy(default_fallback),
            max_restarts: self.max_restarts.unwrap_or(default_restarts),
            handshake_timeout: Duration::from_secs(self.handshake_timeout_secs),
        })
    }
}

fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .with_writer(std::io::stderr)
        .init();
    let cli = Cli::parse();
    let runtime = tokio::runtime::Runtime::new().expect("failed to start the tokio runtime");
    let code = match runtime.block_on(run(cli)) {
        Ok(code) => code,
        Err(err) => {
            eprintln!("agent-shim: {err:#}");
            ExitCode::FAILURE
        }
    };
    // 读 stdin 的阻塞线程可能还在等输入（平台发完 shutdown 不一定关管道），不等它。
    runtime.shutdown_background();
    code
}

async fn run(cli: Cli) -> anyhow::Result<ExitCode> {
    match cli.command {
        Command::Manifests => {
            for id in catalog::builtin_ids() {
                let m = catalog::builtin(id).expect("built-in id");
                let harnesses: Vec<_> = m
                    .harnesses
                    .iter()
                    .map(|h| format!("{}({:?})", h.id, h.kind))
                    .collect();
                println!(
                    "{id}\t{} {}\t{}\tharness: {}\tsites: {:?}",
                    m.agent.name,
                    m.agent.version,
                    m.agent.license,
                    harnesses.join(", "),
                    m.agent.sites
                );
            }
            Ok(ExitCode::SUCCESS)
        }
        Command::RenderConfig { agent, routing } => {
            let manifest = agent.manifest()?;
            let (home, cwd) = agent.dirs()?;
            let routing = routing.routing()?;
            let rendered = config::render(&manifest, &routing, &home, &cwd)?;
            rendered.write_files(&home)?;
            let env: serde_json::Map<String, Value> = rendered
                .env
                .iter()
                .map(|(k, v)| {
                    let shown = if v == &routing.token {
                        "***"
                    } else {
                        v.as_str()
                    };
                    (k.clone(), Value::from(shown))
                })
                .collect();
            let files: Vec<_> = rendered
                .files
                .iter()
                .map(|(p, _)| home.join(p).display().to_string())
                .collect();
            let out = json!({"protocol": rendered.protocol, "env": env, "files": files});
            println!("{}", serde_json::to_string_pretty(&out)?);
            Ok(ExitCode::SUCCESS)
        }
        Command::Serve { common, bridge } => {
            let cfg = common.shim_config(Fallback::Ask, 5)?;
            serve(cfg, bridge).await
        }
        Command::McpBridge { socket } => {
            bridge::run_client(&socket).await?;
            Ok(ExitCode::SUCCESS)
        }
        Command::Run {
            common,
            prompt,
            format,
        } => {
            if common.permissions.on_unlisted == Some(Fallback::Ask) {
                bail!("--on-unlisted ask needs a client to answer; use serve");
            }
            let cfg = common.shim_config(Fallback::Reject, 0)?;
            run_once(cfg, prompt, format).await
        }
    }
}

async fn serve(mut cfg: ShimConfig, args: BridgeArgs) -> anyhow::Result<ExitCode> {
    let (sink, mut events) = EventSink::new();
    let bridge = if args.platform_tools {
        let tools = match &args.platform_tools_file {
            Some(path) => {
                let text = std::fs::read_to_string(path)
                    .with_context(|| format!("reading {}", path.display()))?;
                serde_json::from_str(&text)
                    .with_context(|| format!("{} must be a JSON array of tools", path.display()))?
            }
            None => Vec::new(),
        };
        let b = bridge::Bridge::start(
            &cfg.home.join(".thinktin"),
            sink.clone(),
            tools,
            Duration::from_secs(args.platform_tool_timeout_secs),
        )?;
        tracing::info!(socket = %b.socket_path().display(), "platform tool bridge listening");
        let exe = std::env::current_exe().context("locating agent-shim")?;
        cfg.mcp_servers.push(b.mcp_server_entry(&exe));
        Some(b)
    } else {
        None
    };
    let observer = bridge.clone();
    let writer = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(env) = events.recv().await {
            // 工具桥按 agent 实际开始、结束的那一轮来归属平台工具调用。
            if let Some(b) = &observer {
                match &env.event {
                    ShimEvent::TurnStarted { run_id } => b.begin_run(run_id),
                    ShimEvent::TurnEnded { run_id, .. } => b.end_run(run_id),
                    _ => {}
                }
            }
            let mut line = serde_json::to_vec(&env).expect("events serialize");
            line.push(b'\n');
            if stdout.write_all(&line).await.is_err() || stdout.flush().await.is_err() {
                break;
            }
        }
    });
    let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
    tokio::spawn(read_commands(cmd_tx.clone(), bridge.clone()));
    tokio::spawn(forward_signals(cmd_tx));
    let result = shim::run(cfg, cmd_rx, sink).await;
    if let Some(b) = &bridge {
        b.close();
    }
    let _ = writer.await;
    result.map(|()| ExitCode::SUCCESS)
}

/// 从 stdin 读指令；stdin 关闭视为停止。平台工具相关的指令交给工具桥。
async fn read_commands(
    tx: mpsc::UnboundedSender<ShimCommand>,
    bridge: Option<std::sync::Arc<bridge::Bridge>>,
) {
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<ShimCommand>(&line) {
            Ok(ShimCommand::SetPlatformTools { tools }) => match &bridge {
                Some(b) => b.set_tools(tools),
                None => {
                    tracing::warn!("set_platform_tools ignored: start serve with --platform-tools")
                }
            },
            Ok(ShimCommand::PlatformToolResult {
                call_id,
                content,
                is_error,
            }) => {
                let answered = bridge
                    .as_ref()
                    .is_some_and(|b| b.resolve(&call_id, bridge::ToolResult { content, is_error }));
                if !answered {
                    tracing::warn!(%call_id, "no pending platform tool call with this id");
                }
            }
            Ok(cmd) => {
                if tx.send(cmd).is_err() {
                    return;
                }
            }
            Err(err) => tracing::error!("ignoring malformed command ({err}): {line}"),
        }
    }
    let _ = tx.send(ShimCommand::Shutdown);
}

/// SIGTERM、SIGINT 转成停止指令，让 agent 有机会落盘（沙箱暂停前平台会发 SIGTERM）。
async fn forward_signals(tx: mpsc::UnboundedSender<ShimCommand>) {
    use tokio::signal::unix::{SignalKind, signal};
    let (Ok(mut term), Ok(mut int)) = (
        signal(SignalKind::terminate()),
        signal(SignalKind::interrupt()),
    ) else {
        return;
    };
    tokio::select! {
        _ = term.recv() => {}
        _ = int.recv() => {}
    }
    let _ = tx.send(ShimCommand::Shutdown);
}

async fn run_once(cfg: ShimConfig, prompt: String, format: Format) -> anyhow::Result<ExitCode> {
    const RUN_ID: &str = "run-1";
    let (sink, mut events) = EventSink::new();
    let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
    tokio::spawn(forward_signals(cmd_tx.clone()));
    let shim = tokio::spawn(shim::run(cfg, cmd_rx, sink));
    let mut prompt = Some(prompt);
    let mut code = ExitCode::FAILURE;
    while let Some(env) = events.recv().await {
        print_event(&env, format);
        match &env.event {
            ShimEvent::Ready { .. } => {
                // agent 中途重启后再次 Ready 时不重发：这一轮已经按失败处理。
                if let Some(text) = prompt.take() {
                    let _ = cmd_tx.send(ShimCommand::Prompt {
                        run_id: RUN_ID.into(),
                        text,
                    });
                }
            }
            ShimEvent::TurnEnded {
                run_id,
                stop_reason,
            } if run_id == RUN_ID => {
                code = if *stop_reason == StopReason::EndTurn {
                    ExitCode::SUCCESS
                } else {
                    ExitCode::from(2)
                };
                let _ = cmd_tx.send(ShimCommand::Shutdown);
            }
            ShimEvent::Error {
                run_id: Some(run_id),
                ..
            } if run_id == RUN_ID => {
                let _ = cmd_tx.send(ShimCommand::Shutdown);
            }
            _ => {}
        }
    }
    shim.await.context("shim task panicked")??;
    if matches!(format, Format::Text) {
        println!();
    }
    Ok(code)
}

fn print_event(env: &EventEnvelope, format: Format) {
    match format {
        Format::Json => println!("{}", serde_json::to_string(env).expect("events serialize")),
        Format::Text => match &env.event {
            ShimEvent::MessageChunk { text, .. } => {
                print!("{text}");
                use std::io::Write;
                let _ = std::io::stdout().flush();
            }
            other => {
                let mut v = serde_json::to_value(other).expect("events serialize");
                if let Some(obj) = v.as_object_mut() {
                    obj.remove("raw");
                }
                eprintln!("[{}] {v}", env.seq);
            }
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_alias_syntax() {
        assert_eq!(parse_model("main").unwrap(), ModelAlias::new("main"));
        let m = parse_model("main:131072:8192").unwrap();
        assert_eq!(
            (m.context_window, m.max_output_tokens),
            (Some(131072), Some(8192))
        );
        assert!(parse_model("main:lots").is_err());
        assert!(parse_model("main:1:2:3").is_err());
        assert!(parse_model(":1").is_err());
    }
}
