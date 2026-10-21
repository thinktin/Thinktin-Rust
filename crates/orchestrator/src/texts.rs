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

/// 发到 IM 群里的标题（10.5）：前面带品牌名，群机器人设了“自定义关键词”时用 ThinkTin 就能通过。
pub fn im_title(locale: Locale, title: &str) -> String {
    if title.is_empty() || title == APP_NAME {
        return APP_NAME.into();
    }
    match locale {
        Locale::ZhCn => format!("【{APP_NAME}】{title}"),
        Locale::En => format!("[{APP_NAME}] {title}"),
    }
}

/// IM 群里的审批提醒只是通知：群消息里不能批准或拒绝（要在 App 里用手机签名）。
pub fn im_approval_hint(locale: Locale) -> &'static str {
    pick(
        locale,
        "请打开 ThinkTin App 审批，群消息里不能审批。",
        "Open the ThinkTin app to approve; this group message cannot approve.",
    )
}

/// 计划到点开始、远程开启实时活动时的提醒（10.6）。
pub fn live_started(locale: Locale) -> &'static str {
    pick(locale, "计划开始运行了", "A scheduled run has started")
}

/// 绑定 IM 群机器人后的测试消息（10.5）。
pub fn im_test(locale: Locale) -> (&'static str, &'static str) {
    match locale {
        Locale::ZhCn => (
            "测试消息",
            "这个群已经绑定 ThinkTin，运行完成、需要审批、运行失败时会在这里提醒。",
        ),
        Locale::En => (
            "Test message",
            "This group is now connected to ThinkTin. You'll be notified here when a run finishes, \
             needs approval or fails.",
        ),
    }
}

/// 群机器人失效（被移出群、删掉、地址作废），渠道已停用。
pub fn im_channel_disabled(locale: Locale, label: &str) -> (&'static str, String) {
    match locale {
        Locale::ZhCn => (
            "IM 群提醒已停用",
            format!(
                "{}的机器人失效了（可能被移出群或删除），已停用这个渠道。重新添加机器人后在 App 里换上新地址。",
                if label.is_empty() {
                    "群".to_owned()
                } else {
                    quoted(locale, label)
                }
            ),
        ),
        Locale::En => (
            "Group notifications turned off",
            format!(
                "The bot for {} no longer works (it may have been removed or deleted), so this channel was turned off. \
                 Add the bot again and update the address in the app.",
                if label.is_empty() {
                    "the group".to_owned()
                } else {
                    quoted(locale, label)
                }
            ),
        ),
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

/// 电脑上的高危操作请手机批准（14.2）：通知的标题。正文是电脑写的说明。
pub fn computer_approval(locale: Locale) -> &'static str {
    pick(
        locale,
        "电脑上的操作需要你批准",
        "Your computer needs your approval",
    )
}

/// 任务要用电脑上的工具、电脑不在线（7.11、14.2）：运行的状态说明和通知正文，最多 100 个字符。
pub fn computer_offline(locale: Locale) -> &'static str {
    pick(
        locale,
        "任务要用你的电脑，但电脑不在线，任务已暂停。电脑上的 ThinkTin 连上后自动继续。",
        "This task needs your computer, which is offline. Paused; it resumes once ThinkTin is running there.",
    )
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

// ---------- 平台交给 agent 的说明（续跑、委派、交接） ----------
//
// 也按用户的语言写：会出现在用户能看到的对话里，agent 也会跟着用这种语言回复。

/// 续跑说明（7.12）：重试时加在原来的任务前面。`brief` 是会话没接回时平台整理的上次进展，
/// `has_children` 表示之前委派过子任务。
pub fn resume_note(
    locale: Locale,
    attempt: u32,
    brief: Option<&str>,
    has_children: bool,
    prompt: &str,
) -> String {
    match locale {
        Locale::ZhCn => {
            let session = if brief.is_some() {
                "之前的对话没能接回，下面是平台记录的上次进展。"
            } else {
                ""
            };
            let children = if has_children {
                "你之前委派的子任务还在，用 delegate_list 查看，不要重复委派。"
            } else {
                ""
            };
            let brief = brief.map(|b| format!("\n{b}")).unwrap_or_default();
            format!(
                "（续跑说明：这是第 {attempt} 次尝试，上一次执行中途中断了。{session}先检查工作区里已有的进度，\
                 从中断的地方继续，不要重复已经完成的对外操作。{children}）{brief}\n\n{prompt}"
            )
        }
        Locale::En => {
            let session = if brief.is_some() {
                " The earlier conversation could not be restored; the platform's record of the last progress follows."
            } else {
                ""
            };
            let children = if has_children {
                " Your earlier subtasks are still there: check them with delegate_list and don't delegate them again."
            } else {
                ""
            };
            let brief = brief.map(|b| format!("\n{b}")).unwrap_or_default();
            format!(
                "(Resume note: this is attempt {attempt}; the previous one was interrupted.{session} \
                 Check the progress already in the workspace first and carry on from where it stopped; \
                 don't repeat external actions that were already done.{children}){brief}\n\n{prompt}"
            )
        }
    }
}

/// 续跑简报（7.12）的各行：标题、没调过工具、最近的工具、最后说的话、中断原因。
pub struct BriefWords {
    locale: Locale,
}

impl BriefWords {
    pub fn new(locale: Locale) -> Self {
        Self { locale }
    }

    pub fn heading(&self) -> &'static str {
        pick(self.locale, "上次的进展：", "Last progress:")
    }

    pub fn no_tools(&self) -> &'static str {
        pick(
            self.locale,
            "\n- 还没调用过工具。",
            "\n- No tools were called yet.",
        )
    }

    pub fn tools(&self, total: usize, recent: &[&str]) -> String {
        match self.locale {
            Locale::ZhCn => format!("\n- 最近调用的工具（共 {total} 次）：{}", recent.join("、")),
            Locale::En => format!(
                "\n- Recent tool calls ({total} in total): {}",
                recent.join(", ")
            ),
        }
    }

    pub fn said(&self, said: &str) -> String {
        match self.locale {
            Locale::ZhCn => format!("\n- 最后说的话：「{said}」"),
            Locale::En => format!("\n- Last words: “{said}”"),
        }
    }

    pub fn reason(&self, reason: &str) -> String {
        match self.locale {
            Locale::ZhCn => format!("\n- 中断原因：{reason}"),
            Locale::En => format!("\n- Why it stopped: {reason}"),
        }
    }
}

/// 委派给成员的子任务（8.7）：说明 + 空行 + 任务（交还结果时按空行取出任务）。
pub fn delegated_task(locale: Locale, lead: &str, title: &str, task: &str) -> String {
    match locale {
        Locale::ZhCn => format!(
            "（这是团队负责人（{lead}）委派给你的子任务「{title}」。做完后用几句话总结结果，\
             要交给负责人的文件用 artifact_publish 发布。）\n\n{task}"
        ),
        Locale::En => format!(
            "(This is the subtask “{title}” delegated to you by your team lead ({lead}). \
             When you are done, sum up the result in a few sentences and publish any files \
             for the lead with artifact_publish.)\n\n{task}"
        ),
    }
}

/// 一个子任务的结局（交还给负责人时）。
pub enum ChildOutcome<'a> {
    Done(Option<&'a str>),
    Cancelled,
    Failed(Option<&'a str>),
}

/// 子任务都结束后交还给负责人的消息（8.7）：`children` 是（成员名，任务，结局）。
pub fn delegation_results(
    locale: Locale,
    children: &[(&str, &str, ChildOutcome<'_>)],
    original: &str,
) -> String {
    let mut out = pick(
        locale,
        "（你委派的子任务都结束了，结果如下。据此继续完成原来的任务；需要的话可以再委派。）\n",
        "(All the subtasks you delegated have finished; the results follow. \
         Carry on with the original task, and delegate again if you need to.)\n",
    )
    .to_owned();
    for (i, (name, task, outcome)) in children.iter().enumerate() {
        let n = i + 1;
        let line = match (locale, outcome) {
            (Locale::ZhCn, ChildOutcome::Done(s)) => {
                format!("完成。{}", s.unwrap_or("（没有总结）"))
            }
            (Locale::ZhCn, ChildOutcome::Cancelled) => "被取消了。".to_owned(),
            (Locale::ZhCn, ChildOutcome::Failed(e)) => {
                format!("失败：{}", e.unwrap_or("原因不明"))
            }
            (Locale::En, ChildOutcome::Done(s)) => {
                format!("Done. {}", s.unwrap_or("(no summary)"))
            }
            (Locale::En, ChildOutcome::Cancelled) => "Cancelled.".to_owned(),
            (Locale::En, ChildOutcome::Failed(e)) => {
                format!("Failed: {}", e.unwrap_or("unknown reason"))
            }
        };
        out.push_str(&match locale {
            Locale::ZhCn => format!("\n{n}. 交给「{name}」的「{task}」：{line}"),
            Locale::En => format!("\n{n}. “{task}” for {name}: {line}"),
        });
    }
    out.push_str(&match locale {
        Locale::ZhCn => {
            format!("\n\n产出物用 artifact_list、artifact_read 查看。\n\n原来的任务（供参考）：\n{original}")
        }
        Locale::En => format!(
            "\n\nUse artifact_list and artifact_read to see their artifacts.\n\n\
             The original task, for reference:\n{original}"
        ),
    });
    out
}

/// 流水线一步的交接说明（8.5）的各行。
pub struct HandoffWords {
    locale: Locale,
}

impl HandoffWords {
    pub fn new(locale: Locale) -> Self {
        Self { locale }
    }

    /// 分隔线和标题，后面接“这是哪条流水线的哪一步”。
    pub fn heading(&self, pipeline: &str, step: &str) -> String {
        match (self.locale, pipeline.is_empty()) {
            (Locale::ZhCn, true) => {
                format!("\n\n---\n【交接说明】这是一条流水线中的一步（{step}）。")
            }
            (Locale::ZhCn, false) => {
                format!("\n\n---\n【交接说明】这是流水线「{pipeline}」中的一步（{step}）。")
            }
            (Locale::En, true) => {
                format!("\n\n---\n[Handoff note] This is step {step} of a pipeline.")
            }
            (Locale::En, false) => {
                format!("\n\n---\n[Handoff note] This is step {step} of the pipeline “{pipeline}”.")
            }
        }
    }

    pub fn goal(&self, goal: &str) -> String {
        match self.locale {
            Locale::ZhCn => format!("\n整体目标：{goal}"),
            Locale::En => format!("\nOverall goal: {goal}"),
        }
    }

    pub fn upstream(&self) -> &'static str {
        pick(
            self.locale,
            "\n上游步骤的结果：",
            "\nResults of the upstream steps:",
        )
    }

    pub fn upstream_step(&self, key: &str, summary: Option<&str>) -> String {
        match self.locale {
            Locale::ZhCn => format!("\n- {key}：{}", summary.unwrap_or("（没有摘要）")),
            Locale::En => format!("\n- {key}: {}", summary.unwrap_or("(no summary)")),
        }
    }

    pub fn artifacts(&self) -> &'static str {
        pick(
            self.locale,
            "\n上游产出物（开始前已复制到工作区的 handoff/ 目录；也可以用 artifact_list、artifact_read 查看）：",
            "\nUpstream artifacts (copied into handoff/ in your workspace before you started; \
             artifact_list and artifact_read work too):",
        )
    }

    pub fn artifact(&self, name: &str, version: impl std::fmt::Display, size: u64) -> String {
        match self.locale {
            Locale::ZhCn => format!("\n- handoff/{name} （v{version}，{size} 字节）"),
            Locale::En => format!("\n- handoff/{name} (v{version}, {size} bytes)"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agent_notes_in_both_languages() {
        let zh = resume_note(Locale::ZhCn, 2, Some("上次的进展：…"), true, "写周报");
        assert!(zh.starts_with("（续跑说明：这是第 2 次尝试"), "{zh}");
        assert!(
            zh.contains("没能接回") && zh.contains("delegate_list") && zh.ends_with("\n\n写周报")
        );
        let en = resume_note(Locale::En, 3, None, false, "Write the report");
        assert!(en.starts_with("(Resume note: this is attempt 3;"), "{en}");
        assert!(!en.contains("could not be restored") && !en.contains("delegate_list"));
        assert!(en.ends_with(".)\n\nWrite the report"), "{en}");

        let task = delegated_task(Locale::En, "claude", "Survey", "Compare three rivals");
        assert_eq!(task.split_once("\n\n").unwrap().1, "Compare three rivals");
        let msg = delegation_results(
            Locale::En,
            &[
                (
                    "Researcher",
                    "Survey",
                    ChildOutcome::Done(Some("Table ready")),
                ),
                ("Coder", "Build", ChildOutcome::Failed(None)),
            ],
            "Write a report",
        );
        assert!(
            msg.contains("\n1. “Survey” for Researcher: Done. Table ready"),
            "{msg}"
        );
        assert!(
            msg.contains("\n2. “Build” for Coder: Failed: unknown reason"),
            "{msg}"
        );
        assert!(msg.ends_with("for reference:\nWrite a report"), "{msg}");

        let words = HandoffWords::new(Locale::En);
        assert_eq!(
            words.heading("", "fetch"),
            "\n\n---\n[Handoff note] This is step fetch of a pipeline."
        );
        assert_eq!(
            words.artifact("a.md", 2, 10),
            "\n- handoff/a.md (v2, 10 bytes)"
        );
        let brief = BriefWords::new(Locale::En);
        assert_eq!(
            brief.tools(3, &["Read", "Edit"]),
            "\n- Recent tool calls (3 in total): Read, Edit"
        );
    }

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
            // 推送正文最多 100 个字符：等电脑的说明要完整放得下。
            assert!(computer_offline(locale).chars().count() <= 100, "{locale}");
        }
        assert_ne!(computer_offline(Locale::ZhCn), computer_offline(Locale::En));
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
