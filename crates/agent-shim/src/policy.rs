//! 权限请求的预授权策略（架构方案 4.7）。
//!
//! 创建计划时用户给出预授权范围，比如“可以读写工作区、可以搜索网页”。范围内的请求由 shim
//! 直接批准；范围外的按策略拒绝，或者交给用户决定。工具类别取自 ACP 的 `ToolKind`
//! （read、edit、delete、move、search、execute、think、fetch、switch_mode、other），
//! 由沙箱里的 agent 自己报告，所以它只表达用户意图，不是安全边界；安全边界是 microVM。

use std::collections::BTreeSet;
use std::time::Duration;

use proto::shim::PermissionOption;

#[derive(Debug, Clone)]
pub struct PermissionPolicy {
    /// 直接批准的工具类别，`*` 表示全部。
    pub allow: BTreeSet<String>,
    pub otherwise: Fallback,
    /// 交给用户决定时最长等多久（默认 24 小时）。
    pub ask_timeout: Duration,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub enum Fallback {
    /// 交给用户决定。
    Ask,
    /// 直接拒绝。
    Reject,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    Select(String),
    /// 没有合适的选项，放弃作答。
    Cancel,
    Ask,
}

impl PermissionPolicy {
    pub fn allows(&self, kind: Option<&str>) -> bool {
        self.allow.contains("*") || kind.is_some_and(|k| self.allow.contains(k))
    }

    pub fn decide(&self, kind: Option<&str>, options: &[PermissionOption]) -> Decision {
        let pick = |pred: fn(&PermissionOption) -> bool| {
            options
                .iter()
                .find(|o| pred(o))
                .map(|o| o.option_id.clone())
        };
        if self.allows(kind) {
            // 只批准这一次，不替用户做“永久允许”的决定。
            return pick(|o| o.kind == proto::shim::PermissionKind::AllowOnce)
                .or_else(|| pick(|o| o.kind.is_allow()))
                .map_or(Decision::Cancel, Decision::Select);
        }
        match self.otherwise {
            Fallback::Ask => Decision::Ask,
            Fallback::Reject => pick(|o| o.kind == proto::shim::PermissionKind::RejectOnce)
                .or_else(|| pick(|o| o.kind.is_reject()))
                .map_or(Decision::Cancel, Decision::Select),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proto::shim::PermissionKind;

    fn options() -> Vec<PermissionOption> {
        [
            ("always", PermissionKind::AllowAlways),
            ("once", PermissionKind::AllowOnce),
            ("no", PermissionKind::RejectOnce),
        ]
        .into_iter()
        .map(|(id, kind)| PermissionOption {
            option_id: id.into(),
            name: id.into(),
            kind,
        })
        .collect()
    }

    fn policy(allow: &[&str], otherwise: Fallback) -> PermissionPolicy {
        PermissionPolicy {
            allow: allow.iter().map(|s| s.to_string()).collect(),
            otherwise,
            ask_timeout: Duration::from_secs(1),
        }
    }

    #[test]
    fn allowed_kinds_pick_allow_once() {
        let p = policy(&["read", "edit"], Fallback::Reject);
        assert_eq!(
            p.decide(Some("edit"), &options()),
            Decision::Select("once".into())
        );
        assert_eq!(
            p.decide(Some("execute"), &options()),
            Decision::Select("no".into())
        );
        assert_eq!(p.decide(None, &options()), Decision::Select("no".into()));
    }

    #[test]
    fn wildcard_and_ask() {
        let p = policy(&["*"], Fallback::Ask);
        assert_eq!(p.decide(None, &options()), Decision::Select("once".into()));
        let p = policy(&[], Fallback::Ask);
        assert_eq!(p.decide(Some("read"), &options()), Decision::Ask);
    }

    #[test]
    fn missing_options_cancel() {
        let p = policy(&["*"], Fallback::Reject);
        assert_eq!(p.decide(Some("read"), &[]), Decision::Cancel);
    }
}
