//! Agent 目录：模板、版本、清单、许可证

pub mod manifest;

pub use manifest::{
    AgentSection, ConfigGenerator, Harness, HarnessKind, Heartbeat, LlmProtocol, LlmSection,
    Manifest, ManifestError, PolicySection, RuntimeSection, SessionSupport, Sidecar, Site,
};

/// 内置清单，按接入优先级排列。
const BUILTIN: &[(&str, &str)] = &[
    ("claude", include_str!("../manifests/claude.toml")),
    ("codex", include_str!("../manifests/codex.toml")),
    ("pi", include_str!("../manifests/pi.toml")),
    ("openclaw", include_str!("../manifests/openclaw.toml")),
    ("hermes", include_str!("../manifests/hermes.toml")),
];

/// 内置清单的 id，按接入优先级排列。
pub fn builtin_ids() -> impl Iterator<Item = &'static str> {
    BUILTIN.iter().map(|(id, _)| *id)
}

/// 按 id 取内置清单。内置清单在测试里逐个校验过，这里解析失败属于程序错误。
pub fn builtin(id: &str) -> Option<Manifest> {
    let (_, text) = BUILTIN.iter().find(|(bid, _)| *bid == id)?;
    Some(Manifest::from_toml(text).unwrap_or_else(|e| panic!("内置清单 `{id}` 不合法：{e}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builtin_manifests_are_valid() {
        for id in builtin_ids() {
            let m = builtin(id).unwrap();
            assert_eq!(m.agent.id, id, "文件名和 agent.id 要一致");
        }
        assert!(builtin("nope").is_none());
    }

    #[test]
    fn claude_has_two_harnesses() {
        let m = builtin("claude").unwrap();
        assert_eq!(m.default_harness().kind, HarnessKind::Acp);
        assert_eq!(
            m.harness("cli").unwrap().kind,
            HarnessKind::ClaudeStreamJson
        );
        assert_eq!(m.agent.sites, [Site::Global]);
    }

    #[test]
    fn openclaw_starts_gateway_sidecar() {
        let m = builtin("openclaw").unwrap();
        let h = m.default_harness();
        assert_eq!(h.sidecars.len(), 1);
        assert!(!h.session.per_session_mcp);
    }
}
