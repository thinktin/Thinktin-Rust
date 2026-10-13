//! 配置注入（架构方案 3.3 第 3 条）：把模型网关写成各家 agent 认识的配置。
//!
//! - base URL 指向模型网关，key 填沙箱令牌；真实的厂商 key 永远不进沙箱（5.1）。
//! - 沙箱令牌只放在环境变量 `THINKTIN_SANDBOX_TOKEN` 里，配置文件里写的是变量名，
//!   所以每次唤醒轮换令牌时不用改文件，文件里也没有任何凭证。
//! - 网关按协议分路径：Anthropic Messages 在 `{gateway}/anthropic`，
//!   OpenAI 兼容接口（Chat Completions、Responses）在 `{gateway}/openai/v1`。
//! - 关掉 agent 的自更新、遥测和启动时的联网检查（3.6）。

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};

use anyhow::{Context, bail};
use catalog::{ConfigGenerator, LlmProtocol, Manifest};
use serde_json::{Value, json};

/// 沙箱令牌所在的环境变量。
pub const TOKEN_ENV: &str = "THINKTIN_SANDBOX_TOKEN";

/// 平台给这个实例配置的模型路由（5.5）。
#[derive(Debug, Clone)]
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
    match manifest.llm.config {
        ConfigGenerator::Claude => claude(routing, home, &mut out),
        ConfigGenerator::Codex => codex(routing, home, &mut out)?,
        ConfigGenerator::Pi => pi(routing, home, &mut out),
        ConfigGenerator::Openclaw => openclaw(routing, home, cwd, &mut out)?,
        ConfigGenerator::Hermes => hermes(routing, home, &mut out),
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
}

fn codex(r: &ModelRouting, home: &Path, out: &mut RenderedConfig) -> anyhow::Result<()> {
    let codex_home = home.join(".codex");
    set(out, "CODEX_HOME", codex_home.display().to_string());
    set(out, "MODEL_PROVIDER", "thinktin");
    set(out, "NO_BROWSER", "1");
    let config = json!({
        "model": r.default_model,
        "model_provider": "thinktin",
        "check_for_update_on_startup": false,
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
    let api = pi_api(out.protocol);
    let config = json!({
        "gateway": {
            "mode": "local",
            "bind": "loopback",
            "port": OPENCLAW_GATEWAY_PORT,
            "auth": {"mode": "token", "token": "${OPENCLAW_GATEWAY_TOKEN}"},
        },
        "models": {
            "mode": "replace",
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
    });
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

fn hermes(r: &ModelRouting, home: &Path, out: &mut RenderedConfig) {
    set(
        out,
        "HERMES_HOME",
        home.join(".hermes").display().to_string(),
    );
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
    let config = json!({
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
    out.files
        .push((PathBuf::from(".hermes/config.yaml"), pretty(&config)));
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
        }
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

    #[test]
    fn claude_uses_env_only() {
        let c = render_for("claude");
        assert_eq!(c.env["ANTHROPIC_BASE_URL"], "https://gw.test/anthropic");
        assert_eq!(c.env["ANTHROPIC_AUTH_TOKEN"], "sbx-token");
        assert_eq!(c.env["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "fast");
        assert_eq!(c.env["CLAUDE_CONFIG_DIR"], "/home/agent/.claude");
        assert!(c.files.is_empty());
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
        assert_eq!(c.env["OPENCLAW_GATEWAY_TOKEN"].len(), 64);
        assert_no_token_in_files(&c);

        let c = render_for("hermes");
        let v: Value = serde_json::from_str(file(&c, ".hermes/config.yaml")).unwrap();
        assert_eq!(v["providers"]["custom"]["key_env"], TOKEN_ENV);
        assert_no_token_in_files(&c);
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
