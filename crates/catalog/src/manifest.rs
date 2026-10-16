//! Agent 清单（架构方案 3.2）：告诉 shim 怎么启动、怎么接入、配置写在哪、需要多少资源。

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub agent: AgentSection,
    pub runtime: RuntimeSection,
    /// 接入方式，至少一个，第一个是默认。同一个 agent 可以有多种驱动方式，
    /// 比如 Claude 既能走 ACP 适配器，也能直接驱动 Claude Code 命令行。
    #[serde(rename = "harness")]
    pub harnesses: Vec<Harness>,
    pub llm: LlmSection,
    #[serde(default)]
    pub policy: PolicySection,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AgentSection {
    /// 目录里的唯一标识，小写字母、数字和连字符。
    pub id: String,
    pub name: String,
    pub upstream: String,
    /// 锁定的上游发布版本。
    pub version: String,
    /// SPDX 标识；非开源许可证写 `LicenseRef-...`，并在 `license_note` 说明。
    pub license: String,
    #[serde(default)]
    pub license_note: Option<String>,
    /// 只能在哪些站点上架（第 11 节）。
    pub sites: Vec<Site>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Site {
    /// 国内站：只接已备案的国内模型。
    Cn,
    /// 海外站。
    Global,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RuntimeSection {
    /// Cube 沙箱模板。
    pub template: String,
    pub vcpu: u32,
    pub memory_mb: u32,
    /// agent 的状态目录，相对于 agent 的 HOME，挂在实例的工作区卷上。
    pub state_dirs: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Harness {
    pub id: String,
    pub kind: HarnessKind,
    /// 启动命令，在沙箱里通过 PATH 查找。
    pub command: Vec<String>,
    /// 固定的环境变量。不能放凭证，也不能用 `THINKTIN_` 前缀（shim 保留）。
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    /// 先于 agent 启动的辅助进程，比如 OpenClaw 的 Gateway。
    #[serde(default, rename = "sidecar")]
    pub sidecars: Vec<Sidecar>,
    /// 经平台验证过的会话能力。shim 取它和 agent 握手时声明的能力的交集。
    #[serde(default)]
    pub session: SessionSupport,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum HarnessKind {
    /// Agent Client Protocol，JSON-RPC over stdio（3.4）。
    Acp,
    /// Claude Code 命令行的 stream-json 模式（`claude -p --input-format stream-json`）。
    ClaudeStreamJson,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Sidecar {
    pub name: String,
    pub command: Vec<String>,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    /// 就绪检查：能连上这个本机地址就算就绪。只允许回环地址（3.6）。
    pub ready_tcp: String,
    #[serde(default = "default_ready_timeout")]
    pub ready_timeout_secs: u32,
}

fn default_ready_timeout() -> u32 {
    60
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionSupport {
    /// 沙箱唤醒或 agent 重启后能否接回之前的会话。
    #[serde(default)]
    pub restore: bool,
    /// `session/new` 里传的 MCP 服务器是否生效。为假时由配置生成器写进 agent 自己的配置。
    #[serde(default)]
    pub per_session_mcp: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LlmSection {
    /// agent 能说的模型协议，按优先级排列。
    pub protocols: Vec<LlmProtocol>,
    /// shim 内置的配置生成器，负责把模型网关写成 agent 认识的配置。
    pub config: ConfigGenerator,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum LlmProtocol {
    AnthropicMessages,
    OpenaiCompletions,
    OpenaiResponses,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ConfigGenerator {
    Claude,
    Codex,
    Pi,
    Openclaw,
    Hermes,
}

impl ConfigGenerator {
    /// 这个生成器知道怎么关掉 agent 自带的定时和心跳（清单里 `heartbeat = "platform"` 时，7.14）。
    pub fn disables_scheduler(self) -> bool {
        matches!(self, Self::Openclaw | Self::Hermes)
    }

    /// 这个生成器能写出哪些协议的配置。
    pub fn supported_protocols(self) -> &'static [LlmProtocol] {
        use LlmProtocol::*;
        match self {
            Self::Claude => &[AnthropicMessages],
            Self::Codex => &[OpenaiResponses],
            Self::Pi | Self::Openclaw => &[AnthropicMessages, OpenaiCompletions, OpenaiResponses],
            Self::Hermes => &[OpenaiCompletions, AnthropicMessages],
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PolicySection {
    /// 在线技能市场，平台规定必须关闭（3.6）。
    #[serde(default)]
    pub skills_marketplace: bool,
    /// agent 自更新，平台规定必须关闭，版本由模板控制（3.6）。
    #[serde(default)]
    pub self_update: bool,
    #[serde(default = "default_idle_pause")]
    pub idle_pause_minutes: u32,
    #[serde(default)]
    pub heartbeat: Heartbeat,
}

fn default_idle_pause() -> u32 {
    10
}

impl Default for PolicySection {
    fn default() -> Self {
        Self {
            skills_marketplace: false,
            self_update: false,
            idle_pause_minutes: default_idle_pause(),
            heartbeat: Heartbeat::default(),
        }
    }
}

/// agent 自带的心跳和定时任务由谁负责（4.9）。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Heartbeat {
    /// 关掉 agent 内置的定时，交给编排服务。
    #[default]
    Platform,
    /// agent 没有内置定时，不需要处理。
    None,
}

#[derive(Debug, thiserror::Error)]
pub enum ManifestError {
    #[error("清单解析失败：{0}")]
    Parse(#[from] toml::de::Error),
    #[error("清单 `{id}` 不合法：{}", .problems.join("；"))]
    Invalid { id: String, problems: Vec<String> },
}

impl Manifest {
    pub fn from_toml(text: &str) -> Result<Self, ManifestError> {
        let manifest: Self = toml::from_str(text)?;
        manifest.validate()?;
        Ok(manifest)
    }

    /// 默认接入方式（清单里的第一个）。
    pub fn default_harness(&self) -> &Harness {
        &self.harnesses[0]
    }

    pub fn harness(&self, id: &str) -> Option<&Harness> {
        self.harnesses.iter().find(|h| h.id == id)
    }

    /// 选一个配置生成器能写、agent 也能说的协议。`preferred` 为空时按清单顺序取第一个。
    pub fn pick_protocol(&self, preferred: Option<LlmProtocol>) -> Option<LlmProtocol> {
        let usable = |p: &LlmProtocol| self.llm.config.supported_protocols().contains(p);
        match preferred {
            Some(p) if self.llm.protocols.contains(&p) && usable(&p) => Some(p),
            Some(_) => None,
            None => self.llm.protocols.iter().copied().find(usable),
        }
    }

    pub fn validate(&self) -> Result<(), ManifestError> {
        let mut problems = Vec::new();
        let mut check = |ok: bool, msg: String| {
            if !ok {
                problems.push(msg);
            }
        };

        let a = &self.agent;
        check(
            is_slug(&a.id),
            format!("agent.id `{}` 只能用小写字母、数字和连字符", a.id),
        );
        check(!a.name.trim().is_empty(), "agent.name 不能为空".into());
        check(
            a.upstream.starts_with("https://"),
            "agent.upstream 必须是 https 地址".into(),
        );
        check(
            !a.version.trim().is_empty(),
            "agent.version 不能为空".into(),
        );
        check(
            !a.license.trim().is_empty(),
            "agent.license 不能为空".into(),
        );
        check(
            !a.license.starts_with("LicenseRef-") || a.license_note.is_some(),
            "非开源许可证必须写 agent.license_note".into(),
        );
        check(!a.sites.is_empty(), "agent.sites 不能为空".into());

        let r = &self.runtime;
        check(
            !r.template.trim().is_empty(),
            "runtime.template 不能为空".into(),
        );
        check(
            (1..=16).contains(&r.vcpu),
            "runtime.vcpu 要在 1 到 16 之间".into(),
        );
        check(
            (256..=65536).contains(&r.memory_mb),
            "runtime.memory_mb 要在 256 到 65536 之间".into(),
        );
        check(
            !r.state_dirs.is_empty(),
            "runtime.state_dirs 不能为空".into(),
        );
        for dir in &r.state_dirs {
            check(
                is_safe_relative_path(dir),
                format!("runtime.state_dirs `{dir}` 必须是不含 `..` 的相对路径"),
            );
        }

        check(
            !self.harnesses.is_empty(),
            "至少要有一个 [[harness]]".into(),
        );
        let mut harness_ids = BTreeSet::new();
        for h in &self.harnesses {
            check(
                is_slug(&h.id),
                format!("harness.id `{}` 只能用小写字母、数字和连字符", h.id),
            );
            check(
                harness_ids.insert(&h.id),
                format!("harness.id `{}` 重复", h.id),
            );
            check(
                !h.command.is_empty() && h.command.iter().all(|s| !s.is_empty()),
                format!("harness `{}` 的 command 不能为空", h.id),
            );
            check(
                h.kind != HarnessKind::ClaudeStreamJson
                    || self.llm.config == ConfigGenerator::Claude,
                format!(
                    "harness `{}` 是 claude-stream-json，llm.config 必须是 claude",
                    h.id
                ),
            );
            check_env(&h.env, &format!("harness `{}`", h.id), &mut check);
            let mut sidecar_names = BTreeSet::new();
            for s in &h.sidecars {
                check(
                    is_slug(&s.name),
                    format!("sidecar.name `{}` 不合法", s.name),
                );
                check(
                    sidecar_names.insert(&s.name),
                    format!("sidecar `{}` 重复", s.name),
                );
                check(
                    !s.command.is_empty() && s.command.iter().all(|c| !c.is_empty()),
                    format!("sidecar `{}` 的 command 不能为空", s.name),
                );
                check(
                    is_loopback_addr(&s.ready_tcp),
                    format!(
                        "sidecar `{}` 只能监听回环地址，当前是 `{}`",
                        s.name, s.ready_tcp
                    ),
                );
                check(
                    (1..=600).contains(&s.ready_timeout_secs),
                    format!(
                        "sidecar `{}` 的 ready_timeout_secs 要在 1 到 600 之间",
                        s.name
                    ),
                );
                check_env(&s.env, &format!("sidecar `{}`", s.name), &mut check);
            }
        }

        check(
            !self.llm.protocols.is_empty(),
            "llm.protocols 不能为空".into(),
        );
        check(
            self.pick_protocol(None).is_some(),
            format!(
                "llm.config `{:?}` 写不出 llm.protocols 里的任何一种协议",
                self.llm.config
            ),
        );

        let p = &self.policy;
        check(
            !p.skills_marketplace,
            "平台规定关闭在线技能市场（policy.skills_marketplace）".into(),
        );
        check(
            !p.self_update,
            "平台规定禁止自更新（policy.self_update）".into(),
        );
        check(
            (1..=1440).contains(&p.idle_pause_minutes),
            "policy.idle_pause_minutes 要在 1 到 1440 之间".into(),
        );

        if problems.is_empty() {
            Ok(())
        } else {
            Err(ManifestError::Invalid {
                id: self.agent.id.clone(),
                problems,
            })
        }
    }
}

fn check_env(env: &BTreeMap<String, String>, owner: &str, check: &mut impl FnMut(bool, String)) {
    for key in env.keys() {
        check(
            !key.is_empty() && key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'),
            format!("{owner} 的环境变量名 `{key}` 不合法"),
        );
        check(
            !key.starts_with("THINKTIN_"),
            format!("{owner} 不能设置 shim 保留的环境变量 `{key}`"),
        );
    }
}

fn is_slug(s: &str) -> bool {
    (2..=32).contains(&s.len())
        && s.starts_with(|c: char| c.is_ascii_lowercase())
        && s.chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

fn is_safe_relative_path(p: &str) -> bool {
    !p.is_empty()
        && !p.starts_with('/')
        && !p.contains('\\')
        && p.split('/').all(|seg| !seg.is_empty() && seg != "..")
}

fn is_loopback_addr(addr: &str) -> bool {
    let Some((host, port)) = addr.rsplit_once(':') else {
        return false;
    };
    matches!(host, "127.0.0.1" | "localhost" | "[::1]") && port.parse::<u16>().is_ok_and(|p| p > 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    const MINIMAL: &str = r#"
        [agent]
        id = "demo"
        name = "Demo"
        upstream = "https://example.com/demo"
        version = "1.0.0"
        license = "MIT"
        sites = ["cn"]

        [runtime]
        template = "agents/demo:1.0.0"
        vcpu = 1
        memory_mb = 512
        state_dirs = [".demo"]

        [[harness]]
        id = "acp"
        kind = "acp"
        command = ["demo", "acp"]

        [llm]
        protocols = ["openai-completions"]
        config = "pi"
    "#;

    #[test]
    fn minimal_manifest_parses_with_defaults() {
        let m = Manifest::from_toml(MINIMAL).unwrap();
        assert_eq!(m.default_harness().id, "acp");
        assert_eq!(m.policy, PolicySection::default());
        assert_eq!(m.default_harness().session, SessionSupport::default());
        assert_eq!(m.pick_protocol(None), Some(LlmProtocol::OpenaiCompletions));
        assert_eq!(m.pick_protocol(Some(LlmProtocol::AnthropicMessages)), None);
    }

    #[test]
    fn unknown_fields_are_rejected() {
        let text = MINIMAL.replace("license = \"MIT\"", "license = \"MIT\"\nlicence = \"x\"");
        assert!(matches!(
            Manifest::from_toml(&text),
            Err(ManifestError::Parse(_))
        ));
    }

    #[test]
    fn platform_rules_are_enforced() {
        let text = format!("{MINIMAL}\n[policy]\nskills_marketplace = true\nself_update = true\n")
            .replace("state_dirs = [\".demo\"]", "state_dirs = [\"../etc\"]")
            .replace(
                "[\"demo\", \"acp\"]",
                "[\"demo\", \"acp\"]\nenv = { THINKTIN_SANDBOX_TOKEN = \"x\" }",
            );
        let Err(ManifestError::Invalid { problems, .. }) = Manifest::from_toml(&text) else {
            panic!("应当校验失败");
        };
        assert_eq!(problems.len(), 4, "{problems:?}");
    }

    #[test]
    fn sidecar_must_listen_on_loopback() {
        let text = format!(
            "{MINIMAL}\n[[harness.sidecar]]\nname = \"gw\"\ncommand = [\"gw\"]\nready_tcp = \"0.0.0.0:80\"\n"
        );
        let Err(ManifestError::Invalid { problems, .. }) = Manifest::from_toml(&text) else {
            panic!("应当校验失败");
        };
        assert!(problems[0].contains("回环地址"), "{problems:?}");
    }

    #[test]
    fn protocol_must_match_generator() {
        let text = MINIMAL.replace("config = \"pi\"", "config = \"codex\"");
        let Err(ManifestError::Invalid { problems, .. }) = Manifest::from_toml(&text) else {
            panic!("应当校验失败");
        };
        assert!(problems[0].contains("llm.config"), "{problems:?}");
    }

    #[test]
    fn proprietary_license_needs_note() {
        let text = MINIMAL.replace("\"MIT\"", "\"LicenseRef-Proprietary\"");
        assert!(Manifest::from_toml(&text).is_err());
        let text = text.replace(
            "sites = [\"cn\"]",
            "sites = [\"cn\"]\nlicense_note = \"上架前需法务确认\"",
        );
        assert!(Manifest::from_toml(&text).is_ok());
    }
}
