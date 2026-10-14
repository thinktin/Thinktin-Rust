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

/// 已经被新版本替换、但还保留的旧版本（WBS 6.7）。实例锁定在领养时的版本上：升级内置清单时，
/// 把旧文件移到 `manifests/archive/<id>-<版本>.toml` 并登记在这里，锁定旧版本的实例照常运行、
/// 也能回滚到它；没有实例再用时删掉。
const ARCHIVED: &[(&str, &str)] = &[];

/// 内置清单的 id，按接入优先级排列。
pub fn builtin_ids() -> impl Iterator<Item = &'static str> {
    BUILTIN.iter().map(|(id, _)| *id)
}

/// 按 id 取内置清单。内置清单在测试里逐个校验过，这里解析失败属于程序错误。
pub fn builtin(id: &str) -> Option<Manifest> {
    let (_, text) = BUILTIN.iter().find(|(bid, _)| *bid == id)?;
    Some(Manifest::from_toml(text).unwrap_or_else(|e| panic!("内置清单 `{id}` 不合法：{e}")))
}

fn parse_archived(text: &str) -> Manifest {
    Manifest::from_toml(text).unwrap_or_else(|e| panic!("保留的旧版清单不合法：{e}"))
}

fn find_version(
    current: Option<Manifest>,
    archived: &[(&str, &str)],
    id: &str,
    version: &str,
) -> Option<Manifest> {
    if let Some(m) = current.filter(|m| m.agent.version == version) {
        return Some(m);
    }
    archived
        .iter()
        .filter(|(aid, _)| *aid == id)
        .map(|(_, text)| parse_archived(text))
        .find(|m| m.agent.version == version)
}

fn list_versions(current: Option<Manifest>, archived: &[(&str, &str)], id: &str) -> Vec<String> {
    let mut out: Vec<String> = current.map(|m| m.agent.version).into_iter().collect();
    out.extend(
        archived
            .iter()
            .filter(|(aid, _)| *aid == id)
            .map(|(_, text)| parse_archived(text).agent.version),
    );
    out
}

/// 内置清单的指定版本（当前的或保留的旧版本）。
pub fn builtin_version(id: &str, version: &str) -> Option<Manifest> {
    find_version(builtin(id), ARCHIVED, id, version)
}

/// 可以用的版本，当前版本在前（升级、回滚时选）。
pub fn builtin_versions(id: &str) -> Vec<String> {
    list_versions(builtin(id), ARCHIVED, id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn archived_versions_are_valid_and_distinct() {
        for (id, text) in ARCHIVED {
            let m = parse_archived(text);
            assert_eq!(&m.agent.id, id);
            let cur = builtin(id).expect("archived versions belong to a built-in agent");
            assert_ne!(m.agent.version, cur.agent.version, "{id}");
        }
        for id in builtin_ids() {
            let v = builtin_versions(id);
            let mut dedup = v.clone();
            dedup.dedup();
            assert_eq!(v, dedup, "{id}: versions are unique");
        }
    }

    #[test]
    fn older_versions_stay_reachable() {
        let cur = include_str!("../manifests/pi.toml");
        let current = builtin("pi").unwrap();
        let old_text = cur.replacen(
            &format!("version = \"{}\"", current.agent.version),
            "version = \"0.0.1-old\"",
            1,
        );
        let archived = [("pi", old_text.as_str())];
        assert_eq!(
            list_versions(Some(current.clone()), &archived, "pi"),
            [current.agent.version.clone(), "0.0.1-old".into()]
        );
        let old = find_version(Some(current.clone()), &archived, "pi", "0.0.1-old").unwrap();
        assert_eq!(old.agent.version, "0.0.1-old");
        assert!(find_version(Some(current), &archived, "pi", "9.9.9").is_none());
        assert_eq!(
            builtin_version("pi", &builtin("pi").unwrap().agent.version)
                .unwrap()
                .agent
                .id,
            "pi"
        );
    }

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
    }

    #[test]
    fn openclaw_starts_gateway_sidecar() {
        let m = builtin("openclaw").unwrap();
        let h = m.default_harness();
        assert_eq!(h.sidecars.len(), 1);
        assert!(!h.session.per_session_mcp);
    }
}
