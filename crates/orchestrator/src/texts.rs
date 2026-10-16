//! 服务端写给用户看的文案（1.6）：推送、收件箱、运行的状态说明，按用户的语言（[`Locale`]）输出。
//!
//! - agent 写的内容（运行摘要、工具调用的标题、计划标题、用途说明）原样转发，不翻译。
//! - 接口的错误不在这里：错误码是给客户端的契约，客户端按错误码显示自己语言的文案，
//!   `message` 只是给开发者看的英文说明。
//! - 品牌名 ThinkTin 不翻译。

use proto::domain::Locale;

/// 品牌名：没有计划名可用时当推送标题。
pub const APP_NAME: &str = "ThinkTin";

/// 按语言挑一条文案。
pub fn pick(locale: Locale, zh: &'static str, en: &'static str) -> &'static str {
    match locale {
        Locale::ZhCn => zh,
        Locale::En => en,
    }
}

/// 加引号：中文用「」，英文用 “”。
pub fn quoted(locale: Locale, text: &str) -> String {
    match locale {
        Locale::ZhCn => format!("「{text}」"),
        Locale::En => format!("“{text}”"),
    }
}

/// 账号被冻结（4.6）：标题和正文。
pub fn account_frozen(locale: Locale) -> (&'static str, &'static str) {
    match locale {
        Locale::ZhCn => (
            "账号已冻结",
            "出于安全原因，你的账号已被冻结，正在运行的任务已全部停止。如有疑问请联系客服。",
        ),
        Locale::En => (
            "Account frozen",
            "For security reasons your account has been frozen and all running tasks were stopped. \
             Contact support if you have questions.",
        ),
    }
}

/// 账号解冻（4.6）。
pub fn account_restored(locale: Locale) -> (&'static str, &'static str) {
    match locale {
        Locale::ZhCn => ("账号已恢复", "你的账号已恢复正常，计划会按时继续运行。"),
        Locale::En => (
            "Account restored",
            "Your account is back to normal and your plans will keep running on schedule.",
        ),
    }
}

/// 全部停止（4.6）。
pub fn stopped_all(locale: Locale, runs: u64, plans: u64) -> (&'static str, String) {
    match locale {
        Locale::ZhCn => (
            "已全部停止",
            format!(
                "停止了 {runs} 个运行，暂停了 {plans} 个计划。恢复计划或者重新发起运行时会重新授权。"
            ),
        ),
        Locale::En => (
            "Everything stopped",
            format!(
                "Stopped {runs} run(s) and paused {plans} plan(s). \
                 Resuming a plan or starting a new run grants access again."
            ),
        ),
    }
}

/// 运行完成、agent 没写摘要时的正文。
pub fn task_finished(locale: Locale) -> &'static str {
    pick(locale, "任务完成", "Task finished")
}

/// 运行失败的推送正文。`reason` 是平台记下的失败原因（给开发者看的诊断信息，不翻译）。
pub fn task_failed(locale: Locale, reason: &str) -> String {
    match locale {
        Locale::ZhCn => format!("任务失败：{reason}"),
        Locale::En => format!("Task failed: {reason}"),
    }
}

/// 流水线完成、没有摘要时的正文（8.3）。
pub fn pipeline_finished(locale: Locale) -> &'static str {
    pick(locale, "流水线完成", "Pipeline finished")
}

/// 审批提醒的标题（7.4）。
pub fn approval_needed(locale: Locale) -> &'static str {
    pick(locale, "需要你的批准", "Your approval is needed")
}

/// agent 没给工具调用起标题时，审批提醒的正文。
pub fn approval_untitled(locale: Locale) -> &'static str {
    pick(
        locale,
        "agent 请求执行一个操作",
        "The agent wants to perform an action",
    )
}

/// 审批超时、按策略跳过了这一步（7.10）：标题。
pub fn approval_skipped(locale: Locale) -> &'static str {
    pick(
        locale,
        "审批超时，已跳过这一步",
        "Approval timed out, step skipped",
    )
}

/// 跳过的操作没有标题时的正文。
pub fn approval_skipped_untitled(locale: Locale) -> &'static str {
    pick(
        locale,
        "agent 请求执行的操作",
        "The action the agent asked for",
    )
}

/// agent 新建还是修改了计划（9.5）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlanChange {
    Created,
    Updated,
}

impl PlanChange {
    /// 事件里记的取值。
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Created => "created",
            Self::Updated => "updated",
        }
    }
}

/// agent 改了计划、等用户确认（9.5）：标题和正文。`title` 是 agent 起的计划名。
pub fn plan_needs_confirmation(
    locale: Locale,
    change: PlanChange,
    title: &str,
) -> (&'static str, String) {
    let name = quoted(locale, title);
    match locale {
        Locale::ZhCn => {
            let what = match change {
                PlanChange::Created => "新建了计划",
                PlanChange::Updated => "修改了计划",
            };
            (
                "agent 想安排一个计划",
                format!("{what}{name}，确认后才会按时运行"),
            )
        }
        Locale::En => {
            let what = match change {
                PlanChange::Created => "Created the plan",
                PlanChange::Updated => "Changed the plan",
            };
            (
                "The agent wants to schedule a plan",
                format!("{what} {name}. It runs on schedule once you confirm it."),
            )
        }
    }
}

/// agent 请用户往保险箱里填账号密码（9.11）：标题和正文。`purpose` 是 agent 写的用途。
pub fn vault_request(locale: Locale, purpose: &str) -> (&'static str, String) {
    let purpose = quoted(locale, purpose);
    match locale {
        Locale::ZhCn => (
            "agent 需要账号密码",
            format!(
                "{purpose}：在 App 里填写后 agent 才能使用（只存进你的密码保险箱，agent 和模型都看不到明文）"
            ),
        ),
        Locale::En => (
            "The agent needs a login",
            format!(
                "{purpose}: fill it in in the app before the agent can use it \
                 (it is kept only in your password vault; neither the agent nor the model sees it in plain text)"
            ),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_text_has_both_languages() {
        for locale in Locale::ALL.iter().copied() {
            let (t, b) = account_frozen(locale);
            assert!(!t.is_empty() && !b.is_empty());
            let (t, b) = stopped_all(locale, 2, 1);
            assert!(!t.is_empty() && b.contains('2') && b.contains('1'));
            let (_, b) = plan_needs_confirmation(locale, PlanChange::Created, "Daily news");
            assert!(b.contains("Daily news"));
            let (_, b) = vault_request(locale, "GitHub");
            assert!(b.contains("GitHub"));
        }
        assert_eq!(task_finished(Locale::En), "Task finished");
        assert_eq!(task_finished(Locale::ZhCn), "任务完成");
        assert_eq!(
            plan_needs_confirmation(Locale::ZhCn, PlanChange::Updated, "早报").1,
            "修改了计划「早报」，确认后才会按时运行"
        );
        assert_eq!(
            plan_needs_confirmation(Locale::En, PlanChange::Created, "News").1,
            "Created the plan “News”. It runs on schedule once you confirm it."
        );
        assert_eq!(PlanChange::Updated.as_str(), "updated");
    }
}
