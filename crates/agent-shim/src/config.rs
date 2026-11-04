//! 配置注入（架构方案 3.3 第 3 条）：把模型网关写成各家 agent 认识的配置。
//!
//! - base URL 指向模型网关，key 填沙箱令牌；真实的厂商 key 永远不进沙箱（5.1）。
//! - 沙箱令牌只放在环境变量 `THINKTIN_SANDBOX_TOKEN` 里，配置文件里写的是变量名，
//!   所以每次唤醒轮换令牌时不用改文件，文件里也没有任何凭证。
//! - 网关按协议分路径：Anthropic Messages 在 `{gateway}/anthropic`，
//!   OpenAI 兼容接口（Chat Completions、Responses）在 `{gateway}/openai/v1`。
//! - 关掉 agent 的自更新、遥测和启动时的联网检查（3.6）。
//! - 清单里 `heartbeat = "platform"` 的，关掉 agent 自带的定时和心跳（7.14）：计划由编排服务调度，
//!   agent 用平台工具 `schedule_*` 登记，用户不在线时照样按时跑，也不会两边都跑。

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};

use anyhow::{Context, bail};
use catalog::{ConfigGenerator, Heartbeat, LlmProtocol, Manifest};
use serde_json::{Value, json};

/// 沙箱令牌所在的环境变量。
pub const TOKEN_ENV: &str = "THINKTIN_SANDBOX_TOKEN";

/// 平台给这个实例配置的模型路由（5.5）。
#[derive(Clone)]
pub struct ModelRouting {
    /// 模型网关的根地址。
    pub gateway_url: String,
    /// 沙箱令牌。
    pub token: String,
    /// agent 可选的模型别名，网关按“令牌 → 实例 → 别名”查出真实的厂商和模型。
    pub models: Vec<ModelAlias>,
    /// 默认模型别名，必须在 `models` 里。
    pub default_model: String,
    /// 指定协议；为空时按清单的优先级选。
    pub protocol: Option<LlmProtocol>,
    /// 平台的出口代理（2.7），`host:port`：给了就把它设进 agent 的环境变量。
    pub egress_proxy: Option<String>,
}

/// 沙箱令牌不进调试输出。
impl std::fmt::Debug for ModelRouting {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ModelRouting")
            .field("gateway_url", &self.gateway_url)
            .field("models", &self.models)
            .field("default_model", &self.default_model)
            .field("protocol", &self.protocol)
            .field("egress_proxy", &self.egress_proxy)
            .finish_non_exhaustive()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelAlias {
    pub id: String,
    pub context_window: Option<u32>,
    pub max_output_tokens: Option<u32>,
}

impl ModelAlias {
    pub fn new(id: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            context_window: None,
            max_output_tokens: None,
        }
    }
}

impl ModelRouting {
    fn base_url(&self, protocol: LlmProtocol) -> String {
        let root = self.gateway_url.trim_end_matches('/');
        match protocol {
            LlmProtocol::AnthropicMessages => format!("{root}/anthropic"),
            LlmProtocol::OpenaiCompletions | LlmProtocol::OpenaiResponses => {
                format!("{root}/openai/v1")
            }
        }
    }

    /// 轻量任务（标题生成、摘要等）用的模型：有名为 `fast` 的别名就用它，否则用默认模型。
    fn fast_model(&self) -> &str {
        self.models
            .iter()
            .find(|m| m.id == "fast")
            .map_or(&self.default_model, |m| &m.id)
    }
}

/// 生成结果：环境变量和要写入 agent HOME 的文件。
#[derive(Debug, Clone, PartialEq)]
pub struct RenderedConfig {
    pub protocol: LlmProtocol,
    pub env: BTreeMap<String, String>,
    /// 路径相对于 agent 的 HOME。
    pub files: Vec<(PathBuf, String)>,
}

impl RenderedConfig {
    pub fn write_files(&self, home: &Path) -> anyhow::Result<()> {
        for (rel, content) in &self.files {
            let path = home.join(rel);
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir)
                    .with_context(|| format!("creating {}", dir.display()))?;
            }
            std::fs::write(&path, content)
                .with_context(|| format!("writing {}", path.display()))?;
        }
        Ok(())
    }
}

pub fn render(
    manifest: &Manifest,
    routing: &ModelRouting,
    home: &Path,
    cwd: &Path,
) -> anyhow::Result<RenderedConfig> {
    if routing.models.is_empty() {
        bail!("no model aliases configured");
    }
    if !routing.models.iter().any(|m| m.id == routing.default_model) {
        bail!(
            "default model `{}` is not in the model list",
            routing.default_model
        );
    }
    let Some(protocol) = manifest.pick_protocol(routing.protocol) else {
        bail!(
            "agent `{}` cannot use protocol {:?} (supports {:?})",
            manifest.agent.id,
            routing.protocol,
            manifest.llm.protocols
        );
    };
    let mut out = RenderedConfig {
        protocol,
        env: BTreeMap::new(),
        files: Vec::new(),
    };
    out.env.insert("HOME".into(), home.display().to_string());
    out.env.insert(TOKEN_ENV.into(), routing.token.clone());
    if let Some(addr) = &routing.egress_proxy {
        proxy_env(&mut out.env, addr, &routing.token, &routing.gateway_url);
    }
    let take_over = manifest.policy.heartbeat == Heartbeat::Platform;
    match manifest.llm.config {
        ConfigGenerator::Claude => claude(routing, home, &mut out),
        ConfigGenerator::Codex => codex(routing, home, &mut out)?,
        ConfigGenerator::Pi => pi(routing, home, &mut out),
        ConfigGenerator::Openclaw => openclaw(routing, home, cwd, take_over, &mut out)?,
        ConfigGenerator::Hermes => hermes(routing, home, take_over, &mut out),
    }
    Ok(out)
}

fn set(out: &mut RenderedConfig, key: &str, value: impl Into<String>) {
    out.env.insert(key.into(), value.into());
}

/// Claude Agent SDK 和 Claude Code 命令行共用：都读 ANTHROPIC_* 环境变量。
fn claude(r: &ModelRouting, home: &Path, out: &mut RenderedConfig) {
    set(
        out,
        "ANTHROPIC_BASE_URL",
        r.base_url(LlmProtocol::AnthropicMessages),
    );
    // 以 `Authorization: Bearer` 发出；网关同时接受 x-api-key。
    set(out, "ANTHROPIC_AUTH_TOKEN", r.token.clone());
    set(out, "ANTHROPIC_MODEL", r.default_model.clone());
    set(out, "ANTHROPIC_DEFAULT_OPUS_MODEL", r.default_model.clone());
    set(
        out,
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        r.default_model.clone(),
    );
    set(out, "ANTHROPIC_DEFAULT_HAIKU_MODEL", r.fast_model());
    set(
        out,
        "CLAUDE_CONFIG_DIR",
        home.join(".claude").display().to_string(),
    );
    set(out, "DISABLE_AUTOUPDATER", "1");
    // 关掉遥测、错误上报、反馈等非必要外联。
    set(out, "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1");
    // 用户 2026-11-04 定（docs/search.md）：搜索默认能用、不弹窗；读网页在 Claude 这层放行，只留出口代理问一次网站
    // （能连哪些网站由出口代理管）。读网页前不再先把网站名发给 api.anthropic.com 查（那个网站不在名单里，会多问一次）。
    let settings = json!({
        "skipWebFetchPreflight": true,
        "permissions": { "allow": CLAUDE_ALLOWED_TOOLS },
    });
    out.files.push((
        PathBuf::from(".claude/settings.json"),
        serde_json::to_string_pretty(&settings).unwrap_or_default(),
    ));
}

/// Claude 不用再问用户的工具：搜索、读网页（[`docs/search.md`]）、平台的搜索工具。
pub const CLAUDE_ALLOWED_TOOLS: [&str; 3] = ["WebSearch", "WebFetch", "mcp__thinktin__web_search"];

fn codex(r: &ModelRouting, home: &Path, out: &mut RenderedConfig) -> anyhow::Result<()> {
    let codex_home = home.join(".codex");
    set(out, "CODEX_HOME", codex_home.display().to_string());
    set(out, "MODEL_PROVIDER", "thinktin");
    set(out, "NO_BROWSER", "1");
    let config = json!({
        "model": r.default_model,
        "model_provider": "thinktin",
        "check_for_update_on_startup": false,
        // 插件市场会在后台连 GitHub 和 chatgpt.com 同步；apps 是 ChatGPT 的连接器。都关掉。
        "features": {"plugins": false, "apps": false},
        // 遥测：指标默认经 statsig 上报到 ab.chatgpt.com；分析事件、/feedback 也会连 OpenAI。都显式关掉。
        "analytics": {"enabled": false},
        "feedback": {"enabled": false},
        "otel": {"metrics_exporter": "none"},
        "model_providers": {
            "thinktin": {
                "name": "ThinkTin model gateway",
                "base_url": r.base_url(LlmProtocol::OpenaiResponses),
                "env_key": TOKEN_ENV,
                "wire_api": "responses",
            }
        },
    });
    let text = toml::to_string(&config).context("rendering codex config.toml")?;
    out.files.push((
        PathBuf::from(".codex/config.toml"),
        format!("# 由 agent-shim 生成，每次启动覆盖。\n{text}"),
    ));
    Ok(())
}

fn pi_api(protocol: LlmProtocol) -> &'static str {
    match protocol {
        LlmProtocol::AnthropicMessages => "anthropic-messages",
        LlmProtocol::OpenaiCompletions => "openai-completions",
        LlmProtocol::OpenaiResponses => "openai-responses",
    }
}

fn model_entries(r: &ModelRouting) -> Vec<Value> {
    r.models
        .iter()
        .map(|m| {
            let mut v = json!({"id": m.id, "name": m.id});
            if let Some(n) = m.context_window {
                v["contextWindow"] = n.into();
            }
            if let Some(n) = m.max_output_tokens {
                v["maxTokens"] = n.into();
            }
            v
        })
        .collect()
}

fn pi(r: &ModelRouting, home: &Path, out: &mut RenderedConfig) {
    let dir = home.join(".pi/agent");
    set(out, "PI_CODING_AGENT_DIR", dir.display().to_string());
    set(out, "PI_OFFLINE", "1");
    set(out, "PI_SKIP_VERSION_CHECK", "1");
    set(out, "PI_TELEMETRY", "0");
    let models = json!({
        "providers": {
            "thinktin": {
                "baseUrl": r.base_url(out.protocol),
                "api": pi_api(out.protocol),
                "apiKey": format!("${TOKEN_ENV}"),
                "models": model_entries(r),
            }
        }
    });
    let settings = json!({
        "defaultProvider": "thinktin",
        "defaultModel": r.default_model,
        "quietStartup": true,
        "enableInstallTelemetry": false,
    });
    out.files
        .push((PathBuf::from(".pi/agent/models.json"), pretty(&models)));
    out.files
        .push((PathBuf::from(".pi/agent/settings.json"), pretty(&settings)));
}

/// OpenClaw Gateway 监听的端口，和清单里 sidecar 的 `ready_tcp`、桥的 `--url` 一致。
const OPENCLAW_GATEWAY_PORT: u16 = 18789;

fn openclaw(
    r: &ModelRouting,
    home: &Path,
    cwd: &Path,
    take_over: bool,
    out: &mut RenderedConfig,
) -> anyhow::Result<()> {
    let state = home.join(".openclaw");
    set(out, "OPENCLAW_STATE_DIR", state.display().to_string());
    set(
        out,
        "OPENCLAW_CONFIG_PATH",
        state.join("openclaw.json").display().to_string(),
    );
    // Gateway 和 ACP 桥之间的共享令牌，每次启动随机生成，只在本机回环上使用。
    set(out, "OPENCLAW_GATEWAY_TOKEN", random_hex(32)?);
    set(out, "OPENCLAW_NO_AUTO_UPDATE", "1");
    set(out, "OPENCLAW_DISABLE_BONJOUR", "1");
    // Gateway 会在后台访问 ClawHub（推荐、推广、插件目录等），配置里没有总开关。
    // 指向本机一个没有服务的端口，所有 ClawHub 请求在沙箱内直接失败。
    // 以后平台有了审核过的技能源，改指向它（3.6）。
    set(out, "OPENCLAW_CLAWHUB_URL", "http://127.0.0.1:9");
    set(out, "CLAWHUB_DISABLE_TELEMETRY", "1");
    let api = pi_api(out.protocol);
    let mut config = json!({
        "gateway": {
            "mode": "local",
            "bind": "loopback",
            "port": OPENCLAW_GATEWAY_PORT,
            "auth": {"mode": "token", "token": "${OPENCLAW_GATEWAY_TOKEN}"},
        },
        "models": {
            "mode": "replace",
            // 不从 catalog.openclaw.ai 拉模型目录和价格。
            "catalogRefresh": {"enabled": false},
            "providers": {
                "thinktin": {
                    "baseUrl": r.base_url(out.protocol),
                    "apiKey": format!("${{{TOKEN_ENV}}}"),
                    "api": api,
                    "models": model_entries(r),
                }
            }
        },
        "agents": {
            "defaults": {
                "workspace": cwd.display().to_string(),
                "model": {"primary": format!("thinktin/{}", r.default_model)},
            }
        },
        // 执行命令要人审批，审批经 ACP 转给平台的预授权策略（默认是不审批的 full）。
        "tools": {"exec": {"mode": "ask"}},
        // 启用安装策略但不配审批命令：技能、插件的安装（含 ClawHub）一律失败关闭（3.6）。
        "security": {"installPolicy": {"enabled": true}},
        // 不检查更新（版本、插件版本漂移），不发遥测。
        "update": {"checkOnStart": false},
        "telemetry": {"enabled": false},
    });
    if take_over {
        // 定时归平台（7.14）：关掉 Gateway 的定时任务和心跳（`every = 0m` 关心跳，心跳提示也不再进上下文）。
        set(out, "OPENCLAW_SKIP_CRON", "1");
        config["cron"] = json!({"enabled": false});
        config["agents"]["defaults"]["heartbeat"] = json!({"every": "0m"});
    }
    out.files
        .push((PathBuf::from(".openclaw/openclaw.json"), pretty(&config)));
    Ok(())
}

fn default_alias(r: &ModelRouting) -> &ModelAlias {
    r.models
        .iter()
        .find(|m| m.id == r.default_model)
        .expect("render() checked the default model")
}

fn hermes(r: &ModelRouting, home: &Path, take_over: bool, out: &mut RenderedConfig) {
    set(
        out,
        "HERMES_HOME",
        home.join(".hermes").display().to_string(),
    );
    // 缺 Node 时不在运行时自动下载安装（模板里该有的都装好了）。
    set(out, "HERMES_SKIP_NODE_BOOTSTRAP", "1");
    let transport = match out.protocol {
        LlmProtocol::AnthropicMessages => "anthropic_messages",
        _ => "chat_completions",
    };
    // YAML 是 JSON 的超集，直接写 JSON，省一个 YAML 依赖。
    // 供应商条目必须就叫 `custom`：Hermes 接回会话时按裸的 `custom` 重新解析供应商，
    // 叫别的名字会找不到 key_env，导致会话接不回来。
    let mut model = json!({"provider": "custom", "default": r.default_model});
    // 不给上下文长度时 Hermes 会去探测网关，探不到就按 256K 算。
    if let Some(n) = default_alias(r).context_window {
        model["context_length"] = n.into();
    }
    let mut config = json!({
        // 加固基线（15.3）：技能里的内联命令不执行；agent 自己写的技能也过安全扫描；
        // 不在后台跑技能整理（会起额外的模型调用、改动技能库）。
        "skills": {"inline_shell": false, "guard_agent_created": true},
        "curator": {"enabled": false},
        "model": model,
        "providers": {
            "custom": {
                "name": "custom",
                "base_url": r.base_url(out.protocol),
                "key_env": TOKEN_ENV,
                "transport": transport,
                "default_model": r.default_model,
            }
        },
    });
    if take_over {
        // 定时归平台（7.14）：Hermes 的定时任务只在它自己的 gateway 守护进程里触发，沙箱里只跑 ACP 入口，
        // 不起那个守护进程，所以 agent 自己登记的定时任务不会跑。再明确禁止定时运行里改定时任务。
        config["cron"] = json!({"allow_agent_scheduling": false});
    }
    out.files
        .push((PathBuf::from(".hermes/config.yaml"), pretty(&config)));
}

/// Pi 只拿到这几个平台工具：它没有权限系统，给它的工具都直接执行（docs/search.md）。
pub const PI_PLATFORM_TOOLS: [&str; 1] = ["web_search"];

/// 不支持按会话给 MCP 服务器的 agent（Pi、OpenClaw）：把平台工具桥写进它们自己的配置文件。`servers` 是 ACP
/// `session/new` 的条目（`name`、`command`、`args`、`env` 是 `[{name, value}]`）。别的 agent 什么都不做。
pub fn inject_mcp(
    manifest: &Manifest,
    out: &mut RenderedConfig,
    servers: &[Value],
) -> anyhow::Result<()> {
    if servers.is_empty() {
        return Ok(());
    }
    let entry = |s: &Value| -> anyhow::Result<(String, Value)> {
        let name = s["name"]
            .as_str()
            .context("MCP server entry has no name")?
            .to_owned();
        let env: serde_json::Map<String, Value> = s["env"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|e| Some((e["name"].as_str()?.to_owned(), e["value"].clone())))
            .collect();
        Ok((
            name,
            json!({ "command": s["command"], "args": s["args"], "env": env }),
        ))
    };
    match manifest.llm.config {
        ConfigGenerator::Pi => {
            let mut map = serde_json::Map::new();
            for s in servers {
                let (name, mut e) = entry(s)?;
                if let Some(args) = e["args"].as_array_mut() {
                    for tool in PI_PLATFORM_TOOLS {
                        args.push(json!("--only"));
                        args.push(json!(tool));
                    }
                }
                // 直接给模型看（默认的 codemode 只能在脚本里调，模型看不到）。
                e["exposure"] = json!("direct");
                e["description"] = json!("ThinkTin platform tools: web search");
                map.insert(name, e);
            }
            out.files.push((
                PathBuf::from(".pi/agent/mcp.json"),
                pretty(&json!({ "mcpServers": map })),
            ));
        }
        ConfigGenerator::Openclaw => {
            let path = PathBuf::from(".openclaw/openclaw.json");
            let file = out
                .files
                .iter_mut()
                .find(|(p, _)| *p == path)
                .context("openclaw.json was not rendered")?;
            let mut config: Value =
                serde_json::from_str(&file.1).context("parsing the rendered openclaw.json")?;
            for s in servers {
                let (name, mut e) = entry(s)?;
                e["enabled"] = json!(true);
                e["transport"] = json!("stdio");
                config["mcp"]["servers"][name] = e;
            }
            file.1 = pretty(&config);
        }
        _ => {}
    }
    Ok(())
}

fn pretty(v: &Value) -> String {
    let mut s = serde_json::to_string_pretty(v).expect("JSON values always serialize");
    s.push('\n');
    s
}

pub(crate) fn random_bytes(n: usize) -> anyhow::Result<Vec<u8>> {
    let mut buf = vec![0u8; n];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut buf))
        .context("reading /dev/urandom")?;
    Ok(buf)
}

fn random_hex(bytes: usize) -> anyhow::Result<String> {
    Ok(random_bytes(bytes)?
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect())
}

/// 出网走平台的出口代理（2.7，docs/egress.md）：代理地址的密码是沙箱令牌（代理按它认是哪个实例、能上哪些网站），
/// 本机和模型网关不走代理。大小写两套都设（curl 只认小写的 `http_proxy`）；Node 自带的 fetch 要
/// `NODE_USE_ENV_PROXY` 才认代理变量，Yarn Berry 只认自己的变量。不认代理的程序连不上外网（沙箱本来就不许直连）。
fn proxy_env(env: &mut BTreeMap<String, String>, addr: &str, token: &str, gateway_url: &str) {
    let url = format!("http://thinktin:{}@{addr}", userinfo_encode(token));
    for key in [
        "http_proxy",
        "https_proxy",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "YARN_HTTP_PROXY",
        "YARN_HTTPS_PROXY",
    ] {
        env.insert(key.into(), url.clone());
    }
    // 不走代理的：本机（agent 起的开发服务器常打印 0.0.0.0、本机名、本机地址的网址）和模型网关。
    let gateway = url_host(gateway_url);
    let mut direct: Vec<String> = ["localhost", "127.0.0.1", "::1", "0.0.0.0", "::"]
        .iter()
        .map(|s| (*s).to_owned())
        .collect();
    direct.extend(local_names(gateway.as_deref()));
    direct.extend(gateway);
    let mut seen = std::collections::HashSet::new();
    direct.retain(|h| seen.insert(h.clone()));
    let direct = direct.join(",");
    env.insert("no_proxy".into(), direct.clone());
    env.insert("NO_PROXY".into(), direct);
    env.insert("NODE_USE_ENV_PROXY".into(), "1".into());
    // 代理每个实例同时只给几条隧道（多的排队等）：包管理器默认同时开十几条连接，压到同样的数。
    let n = proto::egress::MAX_TUNNELS.to_string();
    for key in [
        "npm_config_maxsockets",
        "npm_config_network_concurrency",
        "YARN_NETWORK_CONCURRENCY",
        "UV_CONCURRENT_DOWNLOADS",
    ] {
        env.insert(key.into(), n.clone());
    }
}

/// 沙箱自己的名字和地址：主机名，和连模型网关时用的本机地址（UDP 的 connect 只选路由、不发包）。
fn local_names(gateway: Option<&str>) -> Vec<String> {
    let mut out = Vec::new();
    if let Ok(name) = std::fs::read_to_string("/proc/sys/kernel/hostname") {
        let name = name.trim().to_ascii_lowercase();
        if !name.is_empty() {
            out.push(name);
        }
    }
    if let Some(gw) = gateway.and_then(|g| g.parse::<std::net::IpAddr>().ok()) {
        let bind = if gw.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" };
        if let Ok(sock) = std::net::UdpSocket::bind(bind)
            && sock.connect((gw, 9)).is_ok()
            && let Ok(local) = sock.local_addr()
            && !local.ip().is_unspecified()
        {
            out.push(local.ip().to_string());
        }
    }
    out
}

/// URL 的用户信息部分里，非保留字符以外的都按百分号编码。
fn userinfo_encode(s: &str) -> String {
    s.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

/// `http://10.0.1.10:8790/x` 里的主机（`10.0.1.10`）；IPv6 去掉方括号。
fn url_host(url: &str) -> Option<String> {
    let rest = url.split_once("://").map_or(url, |(_, r)| r);
    let authority = rest.split(['/', '?', '#']).next()?;
    let authority = authority.rsplit_once('@').map_or(authority, |(_, a)| a);
    let host = if let Some(v6) = authority.strip_prefix('[') {
        v6.split_once(']')?.0
    } else {
        authority.split(':').next()?
    };
    (!host.is_empty()).then(|| host.to_ascii_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn routing() -> ModelRouting {
        ModelRouting {
            gateway_url: "https://gw.test/".into(),
            token: "sbx-token".into(),
            models: vec![ModelAlias::new("main"), ModelAlias::new("fast")],
            default_model: "main".into(),
            protocol: None,
            egress_proxy: None,
        }
    }

    /// 配了出口代理（2.7）：代理变量带令牌，模型网关和本机直连；没配就什么都不设。
    #[test]
    fn egress_proxy_goes_into_the_environment() {
        let m = catalog::builtin("claude").unwrap();
        let plain = render(&m, &routing(), Path::new("/h"), Path::new("/w")).unwrap();
        assert!(!plain.env.contains_key("https_proxy"));
        let mut r = routing();
        r.gateway_url = "http://10.0.1.10:8790".into();
        r.token = "tts1.k1.a_b-c.d".into();
        r.egress_proxy = Some("10.0.1.10:8791".into());
        let c = render(&m, &r, Path::new("/h"), Path::new("/w")).unwrap();
        let url = "http://thinktin:tts1.k1.a_b-c.d@10.0.1.10:8791";
        for k in [
            "http_proxy",
            "https_proxy",
            "HTTP_PROXY",
            "HTTPS_PROXY",
            "YARN_HTTPS_PROXY",
        ] {
            assert_eq!(c.env[k], url, "{k}");
        }
        let direct: Vec<&str> = c.env["no_proxy"].split(',').collect();
        for h in [
            "localhost",
            "127.0.0.1",
            "::1",
            "0.0.0.0",
            "::",
            "10.0.1.10",
        ] {
            assert!(direct.contains(&h), "{h} in {direct:?}");
        }
        assert_eq!(c.env["npm_config_maxsockets"], "4");
        assert_eq!(c.env["npm_config_network_concurrency"], "4");
        assert_eq!(c.env["NO_PROXY"], c.env["no_proxy"]);
        assert_eq!(c.env["NODE_USE_ENV_PROXY"], "1");
        assert_no_token_in_files(&c);
        assert_eq!(userinfo_encode("a:b@c/d"), "a%3Ab%40c%2Fd");
        assert_eq!(url_host("https://[::1]:443/x").as_deref(), Some("::1"));
        assert_eq!(url_host("http://Gw.Test/").as_deref(), Some("gw.test"));
    }

    fn render_for(id: &str) -> RenderedConfig {
        let m = catalog::builtin(id).unwrap();
        render(&m, &routing(), Path::new("/home/agent"), Path::new("/work")).unwrap()
    }

    fn file<'a>(c: &'a RenderedConfig, rel: &str) -> &'a str {
        &c.files.iter().find(|(p, _)| p == Path::new(rel)).unwrap().1
    }

    /// 令牌只能出现在环境变量里，不能写进任何文件。
    fn assert_no_token_in_files(c: &RenderedConfig) {
        for (path, content) in &c.files {
            assert!(
                !content.contains("sbx-token"),
                "{} 里有令牌",
                path.display()
            );
        }
    }

    /// 加固基线（15.3）：每个内置 agent 都关掉自更新、遥测和技能 / 插件市场，控制台只听回环地址。
    /// 新接一个 agent 时这里会因为没有登记而失败，逼着先把它的加固项想清楚。
    #[test]
    fn every_builtin_agent_meets_the_hardening_baseline() {
        for id in catalog::builtin_ids() {
            let c = render_for(id);
            assert_no_token_in_files(&c);
            match id {
                "claude" => {
                    assert_eq!(c.env["DISABLE_AUTOUPDATER"], "1");
                    assert_eq!(c.env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"], "1");
                }
                "codex" => {
                    let t: toml::Table = toml::from_str(file(&c, ".codex/config.toml")).unwrap();
                    assert_eq!(t["check_for_update_on_startup"].as_bool(), Some(false));
                    assert_eq!(t["features"]["plugins"].as_bool(), Some(false));
                    assert_eq!(t["features"]["apps"].as_bool(), Some(false));
                    assert_eq!(t["analytics"]["enabled"].as_bool(), Some(false));
                    assert_eq!(t["feedback"]["enabled"].as_bool(), Some(false));
                }
                "pi" => {
                    assert_eq!(c.env["PI_OFFLINE"], "1");
                    assert_eq!(c.env["PI_SKIP_VERSION_CHECK"], "1");
                    assert_eq!(c.env["PI_TELEMETRY"], "0");
                }
                "openclaw" => {
                    let v: Value =
                        serde_json::from_str(file(&c, ".openclaw/openclaw.json")).unwrap();
                    assert_eq!(v["gateway"]["bind"], "loopback");
                    assert_eq!(v["update"]["checkOnStart"], false);
                    assert_eq!(v["telemetry"]["enabled"], false);
                    assert_eq!(v["security"]["installPolicy"]["enabled"], true);
                    assert_eq!(c.env["OPENCLAW_NO_AUTO_UPDATE"], "1");
                    assert!(c.env["OPENCLAW_CLAWHUB_URL"].starts_with("http://127.0.0.1:"));
                }
                "hermes" => {
                    let v: Value = serde_json::from_str(file(&c, ".hermes/config.yaml")).unwrap();
                    assert_eq!(v["skills"]["inline_shell"], false);
                    assert_eq!(v["curator"]["enabled"], false);
                    assert_eq!(c.env["HERMES_SKIP_NODE_BOOTSTRAP"], "1");
                }
                other => panic!("no hardening baseline recorded for {other}"),
            }
        }
    }

    /// Pi、OpenClaw 不支持按会话给 MCP 服务器：平台工具桥写进它们自己的配置；Pi 只给搜索。
    #[test]
    fn platform_tools_go_into_pi_and_openclaw_configs() {
        let bridge = json!({
            "name": "thinktin",
            "command": "/opt/thinktin/agent-shim",
            "args": ["mcp-bridge", "--socket", "/h/.thinktin/b.sock", "--egress"],
            "env": [],
        });
        let m = catalog::builtin("pi").unwrap();
        let mut c = render(&m, &routing(), Path::new("/h"), Path::new("/w")).unwrap();
        inject_mcp(&m, &mut c, std::slice::from_ref(&bridge)).unwrap();
        let v: Value = serde_json::from_str(file(&c, ".pi/agent/mcp.json")).unwrap();
        let s = &v["mcpServers"]["thinktin"];
        assert_eq!(s["command"], "/opt/thinktin/agent-shim");
        assert_eq!(
            s["args"],
            json!([
                "mcp-bridge",
                "--socket",
                "/h/.thinktin/b.sock",
                "--egress",
                "--only",
                "web_search"
            ])
        );
        assert_eq!(s["exposure"], "direct");

        let m = catalog::builtin("openclaw").unwrap();
        let mut c = render(&m, &routing(), Path::new("/h"), Path::new("/w")).unwrap();
        inject_mcp(&m, &mut c, std::slice::from_ref(&bridge)).unwrap();
        let v: Value = serde_json::from_str(file(&c, ".openclaw/openclaw.json")).unwrap();
        let s = &v["mcp"]["servers"]["thinktin"];
        assert_eq!(s["args"], bridge["args"]);
        assert_eq!(
            (s["enabled"].clone(), s["transport"].clone()),
            (json!(true), json!("stdio"))
        );
        // 原来的设置还在。
        assert_eq!(v["gateway"]["bind"], "loopback");

        // 支持按会话给的 agent 不改配置。
        let m = catalog::builtin("claude").unwrap();
        let mut c = render(&m, &routing(), Path::new("/h"), Path::new("/w")).unwrap();
        let before = c.files.clone();
        inject_mcp(&m, &mut c, &[bridge]).unwrap();
        assert_eq!(c.files, before);
    }

    #[test]
    fn claude_uses_env_and_settings() {
        let c = render_for("claude");
        assert_eq!(c.env["ANTHROPIC_BASE_URL"], "https://gw.test/anthropic");
        assert_eq!(c.env["ANTHROPIC_AUTH_TOKEN"], "sbx-token");
        assert_eq!(c.env["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "fast");
        assert_eq!(c.env["CLAUDE_CONFIG_DIR"], "/home/agent/.claude");
        let v: Value = serde_json::from_str(file(&c, ".claude/settings.json")).unwrap();
        assert_eq!(v["skipWebFetchPreflight"], true);
        assert_eq!(
            v["permissions"]["allow"],
            json!(["WebSearch", "WebFetch", "mcp__thinktin__web_search"])
        );
    }

    #[test]
    fn codex_config_points_at_gateway() {
        let c = render_for("codex");
        assert_eq!(c.protocol, LlmProtocol::OpenaiResponses);
        let parsed: toml::Table = toml::from_str(file(&c, ".codex/config.toml")).unwrap();
        let p = &parsed["model_providers"]["thinktin"];
        assert_eq!(p["base_url"].as_str(), Some("https://gw.test/openai/v1"));
        assert_eq!(p["env_key"].as_str(), Some(TOKEN_ENV));
        assert_eq!(p["wire_api"].as_str(), Some("responses"));
        assert_eq!(parsed["model_provider"].as_str(), Some("thinktin"));
        assert_eq!(parsed["features"]["plugins"].as_bool(), Some(false));
        assert_eq!(parsed["analytics"]["enabled"].as_bool(), Some(false));
        assert_eq!(parsed["otel"]["metrics_exporter"].as_str(), Some("none"));
        assert_eq!(c.env[TOKEN_ENV], "sbx-token");
        assert_no_token_in_files(&c);
    }

    #[test]
    fn pi_models_json() {
        let c = render_for("pi");
        let v: Value = serde_json::from_str(file(&c, ".pi/agent/models.json")).unwrap();
        let p = &v["providers"]["thinktin"];
        assert_eq!(p["api"], "openai-completions");
        assert_eq!(p["apiKey"], "$THINKTIN_SANDBOX_TOKEN");
        assert_eq!(p["models"][1]["id"], "fast");
        assert_no_token_in_files(&c);
    }

    #[test]
    fn protocol_override() {
        let m = catalog::builtin("pi").unwrap();
        let mut r = routing();
        r.protocol = Some(LlmProtocol::AnthropicMessages);
        let c = render(&m, &r, Path::new("/h"), Path::new("/w")).unwrap();
        let v: Value = serde_json::from_str(file(&c, ".pi/agent/models.json")).unwrap();
        assert_eq!(
            v["providers"]["thinktin"]["baseUrl"],
            "https://gw.test/anthropic"
        );

        let m = catalog::builtin("codex").unwrap();
        assert!(render(&m, &r, Path::new("/h"), Path::new("/w")).is_err());
    }

    #[test]
    fn openclaw_and_hermes_reference_token_env() {
        let c = render_for("openclaw");
        let v: Value = serde_json::from_str(file(&c, ".openclaw/openclaw.json")).unwrap();
        assert_eq!(
            v["models"]["providers"]["thinktin"]["apiKey"],
            "${THINKTIN_SANDBOX_TOKEN}"
        );
        assert_eq!(v["gateway"]["bind"], "loopback");
        assert_eq!(v["security"]["installPolicy"]["enabled"], true);
        assert_eq!(v["update"]["checkOnStart"], false);
        assert_eq!(v["models"]["catalogRefresh"]["enabled"], false);
        assert!(c.env["OPENCLAW_CLAWHUB_URL"].starts_with("http://127.0.0.1:"));
        assert_eq!(c.env["OPENCLAW_GATEWAY_TOKEN"].len(), 64);
        // 定时归平台（7.14）：定时任务和心跳都关掉。
        assert_eq!(v["cron"]["enabled"], false);
        assert_eq!(v["agents"]["defaults"]["heartbeat"]["every"], "0m");
        assert_eq!(c.env["OPENCLAW_SKIP_CRON"], "1");
        assert_no_token_in_files(&c);

        let c = render_for("hermes");
        let v: Value = serde_json::from_str(file(&c, ".hermes/config.yaml")).unwrap();
        assert_eq!(v["providers"]["custom"]["key_env"], TOKEN_ENV);
        assert_eq!(v["cron"]["allow_agent_scheduling"], false);
        assert_no_token_in_files(&c);
    }

    /// 清单说 agent 没有自带定时的，不加这些设置；说归平台的才关（7.14）。
    #[test]
    fn scheduler_settings_follow_the_manifest() {
        let mut m = catalog::builtin("openclaw").unwrap();
        m.policy.heartbeat = Heartbeat::None;
        let c = render(&m, &routing(), Path::new("/h"), Path::new("/w")).unwrap();
        let v: Value = serde_json::from_str(file(&c, ".openclaw/openclaw.json")).unwrap();
        assert!(v.get("cron").is_none());
        assert!(v["agents"]["defaults"].get("heartbeat").is_none());
        assert!(!c.env.contains_key("OPENCLAW_SKIP_CRON"));
    }

    #[test]
    fn context_window_reaches_agent_configs() {
        let mut r = routing();
        r.models[0].context_window = Some(131072);
        r.models[0].max_output_tokens = Some(8192);
        let render = |id| {
            let m = catalog::builtin(id).unwrap();
            render(&m, &r, Path::new("/h"), Path::new("/w")).unwrap()
        };
        let c = render("hermes");
        let v: Value = serde_json::from_str(file(&c, ".hermes/config.yaml")).unwrap();
        assert_eq!(v["model"]["context_length"], 131072);
        let c = render("pi");
        let v: Value = serde_json::from_str(file(&c, ".pi/agent/models.json")).unwrap();
        let main = &v["providers"]["thinktin"]["models"][0];
        assert_eq!(
            (main["contextWindow"].as_u64(), main["maxTokens"].as_u64()),
            (Some(131072), Some(8192))
        );
    }

    #[test]
    fn default_model_must_exist() {
        let m = catalog::builtin("claude").unwrap();
        let mut r = routing();
        r.default_model = "nope".into();
        assert!(render(&m, &r, Path::new("/h"), Path::new("/w")).is_err());
    }
}
