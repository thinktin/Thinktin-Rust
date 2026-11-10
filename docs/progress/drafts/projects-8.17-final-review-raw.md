# 8.17 收尾评审的原始输出（英文，评审和核对的原话；整理过的中文版见 projects-8.17-final-review.md）

## privacy F1 [medium -> low] real=True
### Creator-facing dispatch errors reveal another owner's frozen account and exhausted budget/limits
crates/store/src/project_dispatch.rs:427

SCENARIO: Alice creates a shared project. Bob joins and adds dedicated botin b1. Alice calls POST /v1/projects/{p}/runs with instance_id=b1. create_project_task -> project_target -> `Err(refusal) => return Err(refusal.into_error())` (line 427). into_error (lines 61-69) maps each reason to its own code, and gateway error.rs turns them into separate 409s. (a) If an admin froze Bob, Alice gets 409 `agent_unavailable`. A frozen owner is the only realistic way to hit Unavailable: an owner who leaves has their agents withdrawn, which gives Gone, and an erased owner gives Conflict. (b) If Bob's member budget or the per-botin daily/total limit he set is used up, Alice gets 409 `budget_reached`, "the owner's budget for this agent in the project is used up". By retrying over time she can also tell when the daily window resets. start_project_pipeline (project_pipelines.rs:198) leaks the same way through `refusal.into_error()`. The gateway test at crates/gateway/tests/api.rs:7075 asserts this behaviour. The agent-side path deliberately returns one identical text for these cases (projects.rs child_refusal, test refusals_do_not_tell_why_another_owner_cannot_take_work), and the product rule says another owner's budgets, limits and account state must never reach other members.

FIX: In create_project_task and start_project_pipeline, when target.owner != creator, collapse TargetRefusal::Unavailable and ::Budget into one neutral error, e.g. a single 409 "this botin can't take project work now". Keep the distinct budget_reached/agent_unavailable codes only when the creator dispatches to their own botin. Update the gateway test at api.rs:7075 to match.

VERDICT: The path is reachable as described. create_project_task (project_dispatch.rs:422-428) and start_project_pipeline (project_pipelines.rs:194-199) both return refusal.into_error(). into_error (project_dispatch.rs:61-69) keeps AgentUnavailable and BudgetReached separate, and gateway error.rs:105-116 turns them into separate 409 codes. The second one's message is "the owner's budget for this agent in the project is used up". The gateway test at api.rs:7056-7076 checks that Alice gets budget_reached once Bob's own per-botin total limit is used up.

This was a deliberate choice (plan D13 and F16, the comment at routes/project_tasks.rs:5-6), but both of its premises are now wrong:
(1) F16 says budgets are "project information the creator manages". They are not. The joining member sets the budget in JoinTerms. 0049's my_project_budget only returns the caller's own row (m.user_id = app_user_id()). The founder decided the per-botin limits (0061) are owner-only. So the creator cannot read these values, yet she is told when they run out.
(2) F16 hid a frozen owner by giving frozen, paused and inactive owners the same agent_unavailable code. Founder answer 1 changed paused owners to a held 201. Owners who leave get their agents withdrawn in the same transaction (project_members.rs:631-639), so that path ends at Gone. Deleted users are filtered out in project_actor (projects.rs:155), which makes actor.locked() return None and gives a Conflict. What is left is status Frozen: in practice, 409 agent_unavailable now means "this owner's account is frozen".

The agent side deliberately collapses these cases (projects.rs:948-950, test at :1048), so the creator route is the odd one out. Severity is lowered to low: it leaks one coarse bit, the unavailable message itself is generic, and a creator has to infer "frozen" from the code.

VFIX: In create_project_task and start_project_pipeline, when target.owner (or the step owner) is not the creator, map TargetRefusal::Unavailable and TargetRefusal::Budget to one neutral error, e.g. Error::AgentUnavailable with "this botin can't take project work now". Keep budget_reached only when the creator dispatches to her own botin. Update the comment at routes/project_tasks.rs:5-6 and the assertion at gateway tests api.rs:7071-7075, and correct the plan's F16 note.

## privacy F2 [low -> low] real=True
### ask/delegate replies tell another owner's agent that the target owner pressed "Stop all"
crates/orchestrator/src/ask.rs:289

SCENARIO: Bob presses Stop all. Alice's botin (or the lead, which belongs to Alice) calls `ask` or `delegate` targeting Bob's b1. project_child_run returns Created{held:true}. project_ask sets status "waiting_owner" and the note "B's owner paused it, so it answers once its owner confirms" (ask.rs:289-291). project_delegate prepends "B's owner paused it ..." and returns status "waiting_owner" (delegate.rs:334,343). So Alice's agent learns Bob's account-level kill-switch state. The agent can repeat this in its messages, which every member reads through project_run_events `message`. The C6 review rejected this because members "already see the coarse state waiting_owner", but that premise is wrong: held tasks stay state='queued' (hold_for_owner only sets wait_code and not_before), and 0054 project_run_state maps 'queued' to 'queued'. Members and the creator therefore see a held task as plain queued, and these tool replies are the only path that exposes the stop-all.

FIX: When `held` is true, return the same reply as a normal queued ask or delegate: status "asked"/"started" (or "queued") with neutral text such as "it will pick this up when it can". Do not mention the owner or a pause. Keep the explanation only in the owner's own owner_confirm notice.

VERDICT: Confirmed. When project_child_run returns Created{held:true}, project_ask sets status "waiting_owner" and the note "<name>'s owner paused it, so it answers once its owner confirms" (ask.rs:285-292). project_delegate prepends "<name>'s owner paused it…" and returns status "waiting_owner" (delegate.rs:331-345). These replies go to the calling agent, which can belong to another owner, and that agent's agent.message text is shown to every member (0054 project_run_events keeps 'text').

The C6 review rejected this because members "already see the coarse state waiting_owner". That premise is false:
- hold_for_owner (project_dispatch.rs:454-468) only sets wait_code, wait_deadline and not_before, so state stays 'queued';
- project_run_state in 0054:14-20 maps 'queued' to 'queued', and no later migration redefines it or looks at wait_code;
- the delegate subtasks listing uses ProjectRunState::coarse(r.state), which also gives queued;
- the creator's 201 is re-read as a plain queued ProjectRun;
- the plan itself says members see 「排队」 (queued).

So these tool replies are the only path by which another owner (and their agent's model vendor) learns that the target's owner pressed Stop all.

VFIX: In ask.rs and delegate.rs, when held is true and target.owner_id is not the caller's owner, return the normal reply: asked_reply with status "asked", or status "started" with the normal next text, optionally with a neutral "it picks this up when it can". Do not mention the owner or a pause. Keep the explanation only in notify_held to the owner. A same-owner caller may keep the current text.

## privacy F3 [low -> low] real=True
### Same-owner ask/delegate children inherit the caller's budget and skip the per-botin token limit the owner set
crates/store/src/project_dispatch.rs:895

SCENARIO: Bob's lead L and Bob's other botin B2 are both in project p. Bob sets B2's daily_token_limit to 1000 (set_project_agent_limits) so that work others dispatch cannot run B2 past 1000 tokens. Alice (creator) gives L a task, whose budget is Bob's member remaining, for example 1M. L delegates to B2, or any of Bob's botins asks B2. project_target checks B2's remaining limit only for `== Some(0)`. Then `budget = if owner == actor.owner { actor.budget }` (line 895) gives B2 the caller's ~1M budget instead of min(caller budget, B2's remaining). The executor enforces only max_tokens and the owner's tree total, so B2 can spend far beyond the limit Bob set for it. Another member's dispatch thus bypasses an owner's per-botin control (user decision 3: the remaining budget is the tightest of the member budget and the botin's limits).

FIX: For same-owner children use `max_tokens = min(actor.budget.max_tokens, target.budget_left)` (None meaning no cap) and keep the rest of actor.budget.

VERDICT: Confirmed:
- project_target (project_dispatch.rs:363-366) computes budget_left as the minimum of the member budgets and the target botin's own daily and total limits (owner_budget_left, :269-308), but only refuses when it is Some(0).
- For a same-owner child, :895-896 then uses actor.budget, the caller's RunBudget. For a creator task to Bob's lead L, that is L's budget_left, which includes L's limits, not B2's.
- The executor only enforces tokens + tree_tokens_except(root, run, owner) > budget.max_tokens (executor.rs:2612-2647). Nothing else applies B2's per-botin limit in 8.17.

So when L delegates to, or any of Bob's botins asks, a B2 whose daily limit Bob set to 1000, B2 can spend up to L's much larger remaining budget. This is a structural bypass, not the concurrent overshoot the plan accepts. It contradicts founder answer 3 and the impl note "派单时取最紧的那个挡" (block at dispatch with the tightest one). D13's "a same-owner child keeps the parent's budget" predates the per-botin limits in 0061. Severity stays low: budget enforcement, no data leak, and real-money two-owner pilots wait for 8.18.

VFIX: In project_child_run's same-owner branch, use RunBudget { max_tokens: match (actor.budget.max_tokens, target.budget_left) { (Some(a), Some(b)) => Some(a.min(b)), (a, b) => a.or(b) }, ..actor.budget }. Because the tree total counts the parent's tokens too, this stops early, never late, the same trade-off D13 accepts for cross-owner grandchildren.

## privacy F4 [low -> low] real=True
### Standing grants issued in another owner's name by ask, delegate and pipelines are never audited
crates/store/src/project_dispatch.rs:863

SCENARIO: In project_child_run (line 863), project_target -> ensure_project_agent_grant may issue a new standing project grant (user_id = Bob) when Alice's botin asks or the lead delegates to Bob's b1. Target.issued is dropped: ProjectChildResult does not carry it, and ask.rs and delegate.rs write no audit row. start_project_pipeline (project_pipelines.rs:194) calls project_target for every step only to validate, which issues standing grants for every step's owner at start, including issue-then-revoke grants for paused owners. project_step_run issues them again later. Neither writes an audit row. Only create_task (project_tasks.rs:79) and confirm (:199) record grant.issue/grant.reissue. So the owner's audit trail misses grants created in their name by other members' actions, contrary to the `Dispatched.grant_issued` / `Target.issued` ("记审计") contract.

FIX: Return `issued` in ProjectChildResult::Created and ProjectStepStart::Started, and write a `grant.issue` audit row for the target owner (actor "system", project_id, reason ask/delegate/pipeline step) in ask.rs, delegate.rs and pipeline.rs. In start_project_pipeline, validate steps without issuing grants, for example with a check that does not call ensure_project_agent_grant.

VERDICT: Confirmed:
- project_target calls ensure_project_agent_grant, which issues a new standing grant in the target owner's name (grants.rs:513-532) when no usable one exists, for example on the first ask to a botin that never had a task.
- StandingGrant::Active.issued and Target.issued are documented as "调用方记审计" / "记审计" (the caller writes the audit row).
- project_child_run (project_dispatch.rs:862-921) drops target.issued: ProjectChildResult::Created has no such field. ask.rs, delegate.rs and pipeline.rs contain no audit call at all.
- start_project_pipeline (project_pipelines.rs:194-199) calls project_target for every step only to validate. That issues standing grants for every step's owner at start, including issue-then-revoke rows for paused owners, and the caller orchestrator start_pipeline only audits project.pipeline.
- Every other grant issuance in the codebase is audited: auth grants.rs:79, routes/runs.rs:88, plans.rs:395, project_tasks.rs:79-89 and :199-207.

The reviewer overstates one point: project_step_run reuses an existing unexpired grant and only issues again after expiry or a non-stop-all revoke. Impact is limited to audit completeness. The grant rows, with project_id, stay visible to the owner through the tenant grants policy, and nothing leaks. So severity is low.

VFIX: Add issued: bool to ProjectChildResult::Created and ProjectStepStart::Started. Write a grant.issue audit row for the target owner (actor "system", detail {grant_id, project_id, reason: "ask"/"delegate"/"pipeline step"}) in ask.rs, delegate.rs and pipeline.rs. In start_project_pipeline, either audit the grants issued during validation or validate without calling ensure_project_agent_grant (for example a project_target variant that skips grant issuance), so grants are issued only when a step actually starts.

## database F1 [medium -> low] real=True
### Freeze does not lock the user row, so project dispatch races past it and leaves a live run for a frozen owner
crates/orchestrator/src/account.rs:38

SCENARIO: All 8.17 dispatch paths read the target owner's status under a FOR KEY SHARE lock on the users row and rely on that lock to keep freeze out (create_project_task, project_child_run, start_project_pipeline, lock_project_pipeline then project_step_run). freeze() does a plain read and then UPDATE users SET status='frozen'. Status is not a key column (users_phone_live is a partial unique index), so that UPDATE takes FOR NO KEY UPDATE, which does not conflict with FOR KEY SHARE. Path: ops freezes member B while creator C dispatches to B's botin, B's botin is asked or delegated to, or the pipeline driver starts a step on it. The dispatch transaction has already read status='active'. Freeze's cancel_user_runs cannot see the uncommitted run. The dispatch then commits a queued run, sometimes with a newly issued active standing grant (freeze never revokes grants). claim_next_run skips frozen users, so the run sits for the whole freeze and then executes after unfreeze. If it is a delegate child or a pipeline step, the other owner's lead run (waiting_children) or pipeline root waits for the whole freeze: neither has a deadline, and the orphan sweeper only acts once the parent has ended. The C6 fix comment says stop_all 'locks like freeze'. freeze does lock the row, but in a mode the dispatch lock does not block, so the serialization 8.17 relies on is missing.

FIX: Start freeze() (and set_user_status callers generally) with `SELECT 1 FROM users WHERE id = $1 FOR UPDATE`, as erase_account and mark_stopped_all already do. Read the status after taking that lock. In-flight dispatches then commit first and freeze's cancel_user_runs sees their runs; later dispatches see 'frozen'.

VERDICT: The mechanism is real. freeze() (crates/orchestrator/src/account.rs:37-46) reads the account with a plain select (users.rs:80), then runs set_user_status (users.rs:89-99), an UPDATE of status, frozen_at and deleted_at. The only unique index on users other than the primary key is the partial users_phone_live (0001_init.sql:39), and PostgreSQL does not count partial indexes as key columns. So this UPDATE takes FOR NO KEY UPDATE, which does not conflict with FOR KEY SHARE. No trigger exists on users. Every dispatch path takes FOR KEY SHARE through lock_users (projects.rs:112-118): create_project_task via project_actor, project_child_run via project_agent_actor (project_dispatch.rs:764), and start_project_pipeline and lock_project_pipeline (project_pipelines.rs:303). Worker transactions are READ COMMITTED (lib.rs:187-198), so a dispatch that overlaps an uncommitted freeze reads status='active' without waiting. Freeze's cancel_user_runs (runs.rs:891) cannot see the uncommitted run, and the fence (0060) does not check owner status. The leftover queued run is then skipped by claim_next_run, which requires u.status='active' (runs.rs:1277). waiting_children has no deadline (claim_expired_waits covers only waiting_quota and waiting_device), and cancel_orphaned_project_children acts only after the parent has ended. So a delegating lead or a pipeline root owned by someone else waits through the freeze, and the run executes after unfreeze. mark_stopped_all says it locks 'like freeze', but freeze takes no explicit FOR UPDATE. I downgrade from medium to low. Freeze is a rare ops CLI action, the window is only the overlap of two millisecond-scale transactions, the stray run spends only the frozen owner's own budget after unfreeze, and the creator or the lead's owner can cancel the waiting tree. Granting the standing grant is not an issue, because freeze revokes nothing by design.

VFIX: In account::freeze, take the row lock before reading the status, the same way mark_stopped_all and erase_account do: `SELECT status FROM users WHERE id = $1 FOR UPDATE`, for example through a small store helper, then branch on that status and call set_user_status and cancel_user_runs. The lock order (user row, then runs) matches stop_all and the dispatchers (KEY SHARE on user rows, then project lock, then runs), so it cannot deadlock. In-flight dispatches commit first and their runs get cancelled; later dispatches see 'frozen'. Add a test like stop_all_waits_for_an_in_flight_dispatch for freeze.

## database F2 [medium -> low] real=True
### The creator's task and pipeline APIs reveal another owner's budget exhaustion and frozen account through distinct 409 codes
crates/store/src/project_dispatch.rs:427

SCENARIO: create_project_task (and start_project_pipeline, project_pipelines.rs:198) return refusal.into_error(), which maps to AgentUnavailable, AgentBusy or BudgetReached. gateway/src/error.rs:105-116 turns these into separate 409 codes: `agent_unavailable` and `budget_reached`, with the message "the owner's budget for this agent in the project is used up". Creator C dispatches to member B's botin and gets `budget_reached`, so C learns that B's private member budget or per-botin token limit is exhausted. By retrying over the day, C can watch when it resets. A departed owner's agent is refused as Gone instead, so `agent_unavailable` effectively means B's account is frozen. The agent-facing path deliberately merges these three cases (child_refusal, and the test refusals_do_not_tell_why_another_owner_cannot_take_work says other people's account and budget are private), but the human API does not. Budgets/limits and account state are on the 'never reach other members' list.

FIX: When the target's owner is not the caller, return one neutral code and message for Unavailable, Busy and Budget, e.g. 409 `agent_unavailable` "this botin can't take project work now". Map it in create_project_task and start_project_pipeline by comparing target.owner with the creator. Keep the distinct codes only when the creator dispatches to their own botin. Update the documented codes in the route docs and client-core to match.

VERDICT: Confirmed. create_project_task (project_dispatch.rs:427) and start_project_pipeline (project_pipelines.rs:198) return refusal.into_error(). gateway/src/error.rs:105-116 turns that into separate 409s, including `budget_reached` with the text "the owner's budget for this agent in the project is used up". The route doc (routes/project_tasks.rs:5-6) even states that `agent_unavailable` means the owner is frozen or has left. The budget behind Budget is the minimum of two things. The first is the member budget, which the member sets at join (JoinTerms, project_invites.rs:96-99); 0049 says "别人的预算成员看不到" (other members can't see someone's budget). The second is the per-botin limit, which 0061 and the plan record as owner-only. Plan F16 kept budget_reached for the creator on the grounds that 'budgets are project information the creator manages'. That premise does not hold: the creator neither sets nor can read another member's budget, and the botin limits were added after F16. After the user's answer #1, stop-all no longer refuses (the task is held instead). Leaving the project withdraws the agent rows in the same transaction (project_members.rs:630-646), so that case is refused as Gone. So `agent_unavailable` on the creator route now in practice means 'the owner's account is frozen', which defeats F16's own intent of a generic code. The agent path deliberately merges all three cases (child_refusal and the test refusals_do_not_tell_why_another_owner_cannot_take_work, 'other people's account and budget are private'), and the pipeline driver uses one generic text (project_step_run). The human creator route is the only leak. Impact is limited: the creator learns one bit (frozen, or budget used up), not any numbers, so severity is low.

VFIX: In create_project_task and start_project_pipeline, when target.owner != creator, map TargetRefusal::Unavailable and TargetRefusal::Budget to one neutral error, for example Error::AgentUnavailable with the message "this botin can't take project work now". Busy can stay distinct, since the queued runs it counts are visible to the creator. Keep the distinct codes only when the target is the creator's own botin. Update the code docs in routes/project_tasks.rs, client-core error.rs and api.rs, and the FFI to match.

## database F3 [low -> low] real=True
### owner_confirm reminders stay unread when a held run is ended by the stale-ask sweep, the orphan sweep, stop_all or dispatch-off
crates/orchestrator/src/executor.rs:679

SCENARIO: settle_owner_confirm_inbox runs only after confirm, project cancel_run and the 24-hour unconfirmed sweep. Owner A has pressed stop all. B's botin asks A's botin: the ask is held and A gets an owner_confirm reminder. Held asks keep their 30-minute answer_deadline, so cancel_stale_asks (runs.rs:1688, through expire_asks) cancels the ask after 30 minutes but never settles the reminder. Each held ask therefore leaves a permanent unread item that counts toward A's badge. If A taps 'do it', confirm_project_task returns 409 ("not waiting for your confirmation") before the settle runs, so the item stays. The same happens for held delegate or pipeline children cancelled by cancel_orphaned_project_children (sweep_project_runs settles only the `unconfirmed` list, executor.rs:741), for held runs cancelled by stop_all or freeze (cancel_user_runs), and for the admin project-dispatch off loop (cancel_project_runs).

FIX: After cancel_stale_asks, call settle_owner_confirm_inbox for each cancelled run's instance_id, and do the same for the orphan list in sweep_project_runs. Also call it in stop_all and the dispatch-off loop. Alternatively, have the sweeper periodically run one set-based UPDATE that marks every unread owner_confirm item read when its run is no longer queued with wait_code='owner_confirm'.

VERDICT: Confirmed. settle_owner_confirm_inbox (project_dispatch.rs:536) runs only from project_tasks::cancel_run, from confirm_task (project_tasks.rs:190, reached only after confirm_project_task succeeds; a run that is no longer held returns Conflict at :499 first), and for the `unconfirmed` list in sweep_project_runs (executor.rs:740-742). A held ask keeps the answer_deadline set at ask.rs:241, because hold_for_owner changes only not_before, wait_code and wait_deadline. So cancel_stale_asks (runs.rs:1688, called from expire_asks at executor.rs:681) cancels it after 30 minutes and never settles the reminder. That is the common path, and the tool reply even says 'or the question times out'. The same gap applies to held children cancelled by cancel_orphaned_project_children (executor.rs:737, orphans not settled), to cancel_user_runs from stop_all and freeze, and to the dispatch-off cancel loop. The settle is scoped to the instance, so a later confirm, cancel or 24-hour expiry on the same botin would clean the item up. If none happens, the owner keeps an unread owner_confirm item that counts toward the badge, and its 'do it' button returns 409. This contradicts the C6 fix's stated rule that reminders count as read once a task stops waiting (confirm, decline, cancel, expire). It is a UX and badge glitch only, with no data exposure.

VFIX: In Executor::expire_asks, collect the distinct instance_ids of the runs returned by cancel_stale_asks and call settle_owner_confirm_inbox for each before w.commit(). Do the same for `orphans` in sweep_project_runs. To also cover stop_all, freeze and dispatch-off without touching each path, add one bounded set-based statement to sweep_project_runs: `UPDATE inbox_items SET read_at = now() WHERE id IN (SELECT i.id FROM inbox_items i WHERE i.subtype = 'owner_confirm' AND i.read_at IS NULL AND NOT EXISTS (SELECT 1 FROM runs r WHERE r.id = i.run_id AND r.state = 'queued' AND r.wait_code = 'owner_confirm') LIMIT 100 FOR UPDATE SKIP LOCKED)`.

## database F4 [low -> none] real=False
### The egress trigger treats a stale epoch equal to OLD.asked_epoch as 'old proxy' and nulls it instead of raising
crates/store/migrations/0064_egress_asked_epoch.sql:21

SCENARIO: egress_ask first compares token_epoch in a separate SELECT (egress.rs:391), then touches the pending row with asked_epoch=$4 (egress.rs:405, 501). The store comment says the trigger rejects an epoch that changes between those two statements. But when the same sandbox re-asks a host it already has pending, NEW.asked_epoch equals OLD.asked_epoch. If the epoch was bumped in between (run ended, or the workspace changed with an epoch bump in one UPDATE), the trigger takes the 'old proxy didn't set it' branch: it sets asked_epoch to NULL, sets workspace_id to the NEW workspace, and does not raise. The stale sandbox's ask is then recorded against the new workspace, and 'always allow' adds the host there. That second line of defence fails exactly in the common re-ask case. Only the ON CONFLICT insert path is still protected.

FIX: Let the trigger tell epoch-aware callers apart. For example, in Tx<Llmgw>::egress_ask, `set_config('thinktin.egress_epoch','1',true)` whenever meta.epoch is Some. In the trigger, skip the 'IS NOT DISTINCT FROM OLD then NULL' branch when that setting is '1' and raise egress_stale_token whenever NEW.asked_epoch <> ep. Also map egress_stale_token to EgressAsk::Stale instead of a generic error.

VERDICT: The trigger branch does behave as described. When a touch carries the same epoch as OLD.asked_epoch and the instance epoch has moved, 0064:21-24 nulls the epoch instead of raising. But no realistic harmful path reaches it. (1) Run ended with no workspace change: workspace_id is reassigned to the same workspace, so nothing is recorded against a new workspace. This is exactly the compat fallback 0064 allows for old proxies. (2) Dedicate and release: retire_workspace runs after prelock_egress (instances.rs:1094-1100, called at project_members.rs:184 and 387 and instances.rs:1252). prelock_egress locks every egress_request of the instance FOR UPDATE, then they are all deleted (instances.rs:1177-1186). A stale sandbox's in-flight touch either finishes before the instance update, when its trigger still sees the old epoch and workspace, or finds the row deleted and falls to the INSERT. The BEFORE INSERT trigger raises egress_stale_token even for ON CONFLICT. (3) Only the project-deleted path (retire_project_workspaces, no prelock, SKIP LOCKED) can leave a pending row. Even then, the stale sandbox must read token_epoch before the workspace change commits and run its UPDATE after it, a window of a few statements, while another transaction happens to hold that row's lock at the moment of the DELETE. That is a double race. The worst outcome is that the owner's own explicit 'always allow' click adds a host to the owner's own new private workspace. No cross-user data is involved.

VFIX: 

## database F5 [low -> none] real=False
### `admin project-dispatch off` can be starved by the fence's FOR SHARE lockers and hit the 60 s statement timeout
crates/store/src/project_dispatch.rs:189

SCENARIO: Every project run or grant insert runs `SELECT ... FROM project_dispatch FOR SHARE` (0060:50) and holds that lock until commit. set_project_dispatch(false) is a plain UPDATE that needs FOR NO KEY UPDATE on the same row. In PostgreSQL, a FOR SHARE request on a tuple held only by share lockers does not sleep, even when an updater is waiting (heap_lock_tuple sets require_sleep=false). New dispatch transactions (creator tasks, agents' ask/delegate, pipeline steps, confirms) keep joining the multixact. Under sustained project traffic, the off UPDATE waits until there is a moment with no share lockers at all. It can hit the worker's 60 s statement_timeout, so the emergency switch fails exactly when activity is high.

FIX: Use a fairly queued heavyweight lock for the hand-off: in the fence, take `pg_advisory_xact_lock_shared(<constant key>)` before reading the row. In set_project_dispatch, take `pg_advisory_xact_lock(<same key>)` before the UPDATE. New shared requests then queue behind the waiting exclusive one. Alternatively, grant the worker table-level UPDATE and run `LOCK TABLE project_dispatch IN EXCLUSIVE MODE` before the UPDATE.

VERDICT: In theory, PostgreSQL can let FOR SHARE requesters join a share-only multixact past a waiting FOR NO KEY UPDATE, because heap_lock_tuple skips sleeping for LockTupleShare when only share locks are present. But starving `off` for the 60 s statement_timeout requires that at every instant for a full minute, at least one dispatch transaction holds the fence's share lock. Each holder holds it only from its runs or run_grants INSERT (the fence trigger, 0060:50) until commit, which is a few statements in create_project_task, project_child_run, hold_for_owner/notify_held, pipeline steps and confirm. That means hundreds of overlapping project dispatches per second, sustained. 8.17 cross-user projects stay off in production until 8.18, which makes this unrealistic. And a timed-out `admin project-dispatch off` can simply be rerun. This is not a concrete defect at the code's actual load.

VFIX: 

## database F6 [low -> low] real=True
### project_board_posts has no full index on project_id, so purge and FK cascades scan the whole table
crates/store/migrations/0062_project_board.sql:24

SCENARIO: Every index that leads with project_id is partial (archived_at IS NULL, archived_at IS NOT NULL, NOT by_agent). A query or RI check that only has `project_id = $1` cannot use any of them, which leads to the following scans. (1) purge_deleted_projects runs `DELETE ... WHERE project_id = $1 ORDER BY id LIMIT $2 FOR UPDATE SKIP LOCKED` (project_lifecycle.rs:344) and the `left` EXISTS check for every candidate project on every round. Both scan the whole table, and the EXISTS scans all of it when the project has no posts left. (2) The final DELETE FROM projects cascades through project_board_posts.project_id, and each project_members row it cascades runs the (project_id, author_user_id) FK check. Both are sequential scans: N members means N+1 full scans per purged project. The table grows across all projects (200 live posts each plus 30 days of auto-archived ones).

FIX: Add `CREATE INDEX project_board_posts_member ON project_board_posts (project_id, author_user_id);` in a new migration. It serves the purge, the EXISTS check and both FK cascades.

VERDICT: Confirmed. Every index on project_board_posts that starts with project_id is partial (0062:24, 25 and 29), and PostgreSQL will not use a partial index unless the query implies its predicate, nor will it union complementary partial indexes. These queries carry only project_id or (project_id, author_user_id): the purge batch DELETE (project_lifecycle.rs:344-345), the `left` EXISTS (:404), the RI cascade when DELETE FROM projects runs (:416, FK at 0062:8), and the composite FK cascade from each deleted project_members row (0062:19). Each one is a full table or PK-order scan. project_members rows are never hard-deleted except through this cascade (leave and erase only set left_at), so the cost lands on the background purge: about (rounds × 2) + 1 + N_members full scans per purged project, up to 20 candidates per call. Live posts are capped at 200 per project plus 30 days of archived ones, so the table grows with the total number of projects. Correctness is unaffected, so severity is low, but this is a missing FK-supporting index on a growing table.

VFIX: Add a new migration: `CREATE INDEX project_board_posts_member ON project_board_posts (project_id, author_user_id);`. It serves the purge DELETE, the EXISTS check, the project_id cascade (as the leading column) and the (project_id, author_user_id) cascade.

## database F7 [low -> none] real=False
### The archived project-board purge is an unbounded DELETE inside the daily maintenance transaction
crates/server/src/workers.rs:473

SCENARIO: maintain() runs ensure_event_partitions and then, in the same worker transaction, purge_archived_project_board_posts. That is a single DELETE of every project post archived more than 30 days ago, with no LIMIT (project_board.rs:194). Projects auto-archive past 200 live posts, and agents can post on every run, so the backlog can be large: for example on the first run after 30 days, or after a burst of agent posts. If that DELETE exceeds the 60 s worker statement_timeout or hits a lock, the whole maintain transaction rolls back every tick. That includes creating upcoming event partitions, so later event inserts can fail once the month rolls over.

FIX: Purge in bounded batches in separate transactions, like purge_egress: `DELETE ... WHERE id IN (SELECT id FROM project_board_posts WHERE archived_at < ... ORDER BY archived_at LIMIT $n FOR UPDATE SKIP LOCKED)`, looping until a batch comes back short. Move it out of the transaction that creates event partitions.

VERDICT: maintain() runs hourly (maintenance_every_secs default 3600, config.rs:862; workers.rs:402-407). So each tick deletes only the posts whose archived_at crossed 30 days during the last hour, using the partial index project_board_posts_archived_at (0062:26). Nothing references project_board_posts, so there are no cascades. For a single tick's DELETE to pass the 60 s statement_timeout, millions of posts would have to be archived within one hour. Live posts are capped at 200 per project, members at 50 manual posts a day and runs at 20 posts each, so that is not realistic. The DELETE mirrors the private-board purge_archived_board_posts (board.rs:249), which has run in the same transaction since 8.10. And ensure_event_partitions creates partitions 3 months ahead, so an occasional failed tick cannot break event inserts. It would take continuous failures for months.

VFIX: 

## pipelines P1 [medium -> medium] real=True
### Pipeline steps skip the 10-queued cap, and each step gets the owner's full remaining budget
crates/store/src/project_pipelines.rs:344

SCENARIO: `project_step_run` (and the start-time check at :194) calls `project_target(..., check_queue=false, ...)`. Nothing limits how many pipelines a creator can start. Tasks, asks and delegates are capped at MAX_QUEUED_PROJECT_RUNS = 10 per botin (user decision 8: 'each botin queues at most 10 project tasks'). Example: the creator POSTs 10 pipelines, each with 20 independent steps on member B's dedicated botin. On the first ticks the driver inserts 200 queued runs on B's botin. Each one is inserted before anything has run, so `owner_budget_left` returns the same full remainder every time, and every run gets `max_tokens` = B's whole remaining daily/total limit. Nothing re-checks the owner budget at claim time. The botin runs them one after another, each up to the full limit, so B can be charged up to 200 times the limit they set. The user only accepted a 'slight' overshoot, bounded by the queue cap. The roots also flood the global project-pipeline batch (20 roots per 2s tick, round-robin), which delays every other project's pipelines. D23's reason for exempting pipelines ('the creator chose them') is exactly the fan-out the cap exists to bound.

FIX: In `project_step_run`, call `project_target` with `check_queue = true`. Map `TargetRefusal::Busy` to a new `ProjectStepStart::Deferred`: the driver leaves that step unstarted and tries again on a later tick instead of failing the pipeline. In `start_project_pipeline`, reject (`AgentBusy`) when the steps on one botin plus that botin's queued project runs exceed MAX_QUEUED_PROJECT_RUNS. Optionally cap unfinished pipelines per project or creator.

VERDICT: Confirmed. project_step_run (project_pipelines.rs:343-345) and the start-time check (:193-195) call project_target with check_queue=false. Nothing else bounds pipelines: there is no per-project or per-creator cap in 0065 or the fences, no rate limit on POST /v1/projects/{id}/pipelines, and project_tasks::start_pipeline only audits. advance_project (pipeline.rs:188-214) inserts every step whose deps are met in the same tick. Each step gets max_tokens = owner_budget_left at insert time (project_pipelines.rs:360-362). Nothing re-checks the owner's budget at claim or lease time. The only runtime check is executor.rs:2614-2645, which compares this run's tokens plus the same owner's tokens in the same run tree.

The finding overstates the impact. Inside one pipeline, B's steps share one tree, so tree_tokens_except(root, id, Some(owner)) keeps B's spend in that pipeline near one remainder R. The 20 steps of one pipeline do not cost 20R. Separate pipelines are separate trees, though. A creator who starts N pipelines with steps on B's botin before they run makes B pay up to about N x R, plus up to 10R from capped tasks, asks and delegates. N has no limit. The user accepted only a 'slight' overshoot, and D23's own reason for the cap ('one creator ... can flood a member's botin') applies to pipelines just as much: creator tasks, which the creator also chooses, are capped. The global driver batch (20 roots per tick, round-robin via requeue) is also slowed for every project.

Severity stays medium: owners' limits can be overrun without bound across owners. It is somewhat mitigated by the dispatch switch staying off in production until 8.18.

VFIX: In project_step_run, call project_target with check_queue = true. Map TargetRefusal::Busy to a new ProjectStepStart::Deferred, and have advance_project `continue` on it, so the step stays unstarted and is retried on a later tick instead of failing the pipeline. Optionally also use check_queue = true in start_project_pipeline, so a pipeline is refused (agent_busy) when a step's botin already has 10 queued project runs.

## pipelines P2 [medium -> low] real=True
### Upstream artifacts are copied raw into the downstream workspace, so CLAUDE.md-style files from another owner's botin become agent instructions
crates/orchestrator/src/pipeline.rs:788

SCENARIO: For a project step, `HandoffCopier::copy` writes every upstream artifact to `{workdir}/handoff/{name}`. The workdir is the agent's cwd (exec.rs:206). `check_name` allows names like `CLAUDE.md` or `AGENTS.md`. Example: owner B's upstream botin (steered by B, or injected through web content) publishes an artifact named `CLAUDE.md` with instructions. When D's downstream step starts, it lands in D's workspace as `handoff/CLAUDE.md`. Claude Code (claude.toml) loads nested CLAUDE.md files as memory when it reads files in that subtree, and the handoff note tells the agent to read handoff/. B's text then arrives as trusted instructions, outside the `<<<UPSTREAM-…>>>` fence and the 'not instructions' note. The dedicated workspace persists, so the file keeps affecting D's botin on later project tasks from anyone. (`artifact_fetch` has the same default path, but there the agent chooses to fetch.)

FIX: When `rec.run.project_id` is set, copy into a fresh per-run directory (e.g. `handoff/<run-id>/`). Rename or skip names that agent harnesses auto-load, matched case-insensitively: CLAUDE.md, CLAUDE.local.md, AGENTS.md, AGENT.md, GEMINI.md and similar, e.g. by appending `.upstream.txt`. Alternatively, refuse those names in `artifact_publish` for project runs.

VERDICT: The path is confirmed. check_name (artifacts.rs:270-285) accepts 'CLAUDE.md' or 'AGENTS.md': no leading dot, allowed characters only. A step on B's botin can publish such an artifact, and run_artifacts(dep_ids) returns it for the downstream step. HandoffCopier::copy (pipeline.rs:786-792) writes it raw to {workdir}/handoff/{name}. workdir is 'workspace', the same path the agent uses as cwd (exec.rs:89,206). Nothing in the repo disables project setting sources for the claude harness (claude.toml, no settingSources or CLAUDE.md handling). Claude Code loads nested CLAUDE.md files lazily when it reads files in that subtree, and the handoff note tells the agent to look in handoff/. So B's text reaches D's botin as memory-level instructions, outside the <<<UPSTREAM>>> fence, and stays in D's dedicated workspace for later runs.

Severity is low, not medium. The author has to be a co-member's botin, or content injected into it. The damage stays inside project scope: D's dedicated botin has only project memory and project tools, project runs get no vault or computer in 8.17, and its spend stays within D's limits. Any file content is untrusted anyway; this raises how much the agent trusts it rather than opening a new channel. artifact_fetch (tools.rs:690) has the same default path.

VFIX: In HandoffCopier::copy, when rec.run.project_id.is_some(), map names that agent harnesses auto-load to something inert before writing. Match case-insensitively: CLAUDE.md, CLAUDE.local.md, AGENTS.md, AGENT.md, GEMINI.md. For example, write handoff/<name>.upstream.txt. Use the same mapping in project_handoff_prompt's artifact list, and in artifact_fetch's default path for artifacts from another member.

## pipelines P3 [low -> low] real=True
### Held pipeline steps cancelled by the driver or the orphan sweep leave the owner's confirmation reminder unread
crates/orchestrator/src/pipeline.rs:179

SCENARIO: Owner B pressed stop all, so B's step S1 is created held (queued, `wait_code = owner_confirm`) and B gets a reminder. Then a parallel step fails, or a later step is refused (:209). `cancel_project_subtree` cancels S1, but the driver never calls `settle_owner_confirm_inbox`; it also writes no `run.state` event for the steps it cancels. The orphan sweep has the same gap: if the creator presses stop all, the root is cancelled, and `sweep_project_runs` (executor.rs:737) cancels S1, but it settles only the `unconfirmed` list. B's reminder stays unread, the badge counts it, and tapping 'do it' returns 409 'not waiting for your confirmation'. This contradicts the C6 fix ('confirmed, declined, cancelled, expired reminders are marked read').

FIX: In `advance_project`, keep the `(run, instance)` list that `cancel_project_subtree` returns. Call `settle_owner_confirm_inbox` for each distinct instance and append `run.state` events, as `project_tasks::cancel_run` does. In `sweep_project_runs`, also settle the instances of `orphans`.

VERDICT: Confirmed. Only three places call settle_owner_confirm_inbox: project_tasks::cancel_run (:154), confirm_task (:190), and the unconfirmed-expiry branch of sweep_project_runs (executor.rs:740-742). Two cancel paths skip it. advance_project's cancel_project_subtree calls (pipeline.rs:179, :209) cancel held steps (queued with wait_code owner_confirm; the subtree query takes any non-terminal run and clears wait_code), but never settle. cancel_orphaned_project_children (runs.rs:1096) cancels held steps or delegate children whose parent ended, for example after the creator's stop-all cancels the root, and sweep_project_runs does not settle those instances either. The reminder only gets marked read if some later settle happens to run on the same instance. Until then it counts toward the badge, and tapping 'do it' hits confirm_project_task's Conflict 'this task is not waiting for your confirmation' (project_dispatch.rs:499-503). The driver's own cancels also write no run.state events. The impact is UI and badge only.

VFIX: In advance_project, keep the Vec<(RunId, InstanceId)> that cancel_project_subtree returns. Call w.settle_owner_confirm_inbox for each distinct instance in the same transaction, and append a run.state Cancelled event for each run, as project_tasks::cancel_run/log_cancelled do. In sweep_project_runs, also call settle_owner_confirm_inbox for each instance in `orphans` before committing.

## pipelines P4 [low -> none] real=False
### Pipeline steps start without the platform header saying who dispatched them
crates/orchestrator/src/executor.rs:272

SCENARIO: `project_prompt` adds a header only for `RunSource::User` (from creator X of project P), `Delegate` and `Ask`. For `RunSource::Pipeline` it falls to `_ => None`. Owner B's botin therefore receives the creator-written step prompt plus only '[Handoff note] This is step k of the pipeline T'. Nothing says the work comes from another member, the project creator, so a step prompt phrased as 'your owner asks you to …' reads as if it came from B. docs/projects-impl.md says every attempt carries a platform note naming who dispatched it.

FIX: Add a `(RunSource::Pipeline, _)` arm that prepends `project_task_header` (project name, creator label), or a pipeline variant of it.

VERDICT: The missing header is a documented design decision. Plan §3.3 item 3 says: 'Pipeline steps: none, because the handoff carries its own heading'. The project_prompt doc comment says the same. The handoff heading names the pipeline and the step, and the fence names the upstream content as another botin's. No security boundary depends on the creator header. project_task_header is purely informational: it has no 'don't do risky operations' clause, unlike the delegate header. A creator task that contains 'your owner asks you to…' runs with exactly the same grant, budget and approvals as a pipeline step. Approvals for risky tools still go to B, and project runs get no vault or computer in 8.17. Adding attribution could still be a small improvement, but there is no concrete wrong outcome.

VFIX: None

## pipelines P5 [low -> none] real=False
### Grants issued for other owners' botins by pipelines are never audited for the owner
crates/store/src/project_pipelines.rs:193

SCENARIO: `start_project_pipeline` (:193-199) and `project_step_run` (:343-349) call `project_target` and drop `Target.issued`. The start-time check alone can issue standing grants via `ensure_project_agent_grant` on every step botin, B's included. For the same grant issued through a creator task, `project_tasks::create_task` writes `grant.issue` to the owner's audit log (plan §4.1 'Audit rows'). B's audit log never shows that a standing grant on their botin was issued because of the creator's pipeline.

FIX: Return the issued grant ids from `start_project_pipeline` and from `ProjectStepStart::Started`. Audit `grant.issue` for each owner (reason 'project pipeline') in `project_tasks::start_pipeline` and in `start_project_step`.

VERDICT: This matches the plan. The plan's 'Audit rows' (§4.1) list grant.issue only for creator tasks. Asks also issue standing grants lazily, through project_target and ensure_project_agent_grant in project_child_run (project_dispatch.rs:862-893), and nothing audits those either, so pipelines are consistent with the rest. No product rule requires an owner-side audit row for each standing grant issued, and the pipeline itself is audited as project.pipeline. At most this is an audit-completeness nicety, not a defect.

VFIX: None

## pipelines P6 [low -> low] real=True
### The creator's anchor botin shows as busy, with the pipeline as its current task, for the whole pipeline
crates/orchestrator/src/peers.rs:192

SCENARIO: The root (kind `pipeline`) sits in `waiting_children` on the creator's anchor botin until the last step ends. `project_list` computes `busy = runs.any(!terminal)` and `project_status` picks the first Running/WaitingOwner/WaitingChildren run as `current`. Both count the root, so agents_list and agent_status report the anchor botin as 'busy', working on the pipeline goal, even when it runs nothing. A lead looking for an idle teammate skips the creator's botin.

FIX: In the project modes of agents_list and agent_status, ignore runs with `kind == RunKind::Pipeline` when computing busy and current (the `ProjectRun.kind` field is available).

VERDICT: Confirmed. The pipeline root (kind pipeline) sits on the creator's anchor botin in waiting_children until the pipeline finishes. A pipeline root does not occupy the instance (pipeline.rs header: 'pipeline runs don't take the instance'). project_list (peers.rs:192) sets busy = any non-terminal run among the botin's project runs, so the root counts. project_status picks the newest Running/WaitingOwner/WaitingChildren run as current, so the root shows as the current task, with the goal as the prompt. The private mode deliberately excludes these runs: instance_holder filters kind = 'agent' (runs.rs:805). So agents_list and agent_status report the anchor as busy on the pipeline for its whole length, even while it is idle. Leads may skip it. Delegation is not blocked, so the impact is only misleading information.

VFIX: In project_list and project_status (peers.rs), ignore runs with r.kind == RunKind::Pipeline when computing busy and current. This matches the private mode's kind = 'agent' filter.

## pipelines P7 [low -> low] real=True
### GET pipeline returns the title as the goal when no goal was given
crates/store/src/project_pipelines.rs:389

SCENARIO: When the creator starts a pipeline with an empty goal, `start_project_pipeline` stores the title as the root prompt (:238). `ProjectTx::project_pipeline` returns `goal: run.prompt`, so GET /pipelines/{root} reports goal = title. Clients show a goal that was never set, and every step's handoff says 'Overall goal: <title>'.

FIX: Store the goal separately: a `goal` column in project_pipelines (new migration), or keep the root prompt empty-safe. Return that column, so an empty goal comes back as "".

VERDICT: Confirmed. With an empty goal, start_project_pipeline stores the trimmed title as the root prompt (project_pipelines.rs:237-238). ProjectTx::project_pipeline returns goal: run.prompt (:389). So GET /pipelines/{root} reports goal = title, and the handoff says 'Overall goal: <title>'. The impact is cosmetic, an API field returning a value the creator never set, and needs no migration.

VFIX: In ProjectTx::project_pipeline, return an empty goal when the root prompt equals the stored title: `goal: if run.prompt == row.0 { String::new() } else { run.prompt }`. Both values are stored trimmed, so they compare exactly. Optionally pass the empty goal through to project_handoff_prompt so it omits the 'Overall goal' line.

## contract F1 [medium -> medium] real=True
### Dispatch 409 codes tell the creator about another owner's budget and frozen account
crates/store/src/project_dispatch.rs:427

SCENARIO: Alice creates the project and Bob's botin b1 is in it. In one case Bob's own limit on b1 (or his member budget) runs out: Alice's POST /v1/projects/{id}/runs with instance_id=b1 returns 409 `budget_reached` ("the owner's budget for this agent in the project is used up"; error.rs:113; gateway test api.rs:7075 asserts this for Alice). In the other case Bob's account is frozen: project_target returns Unavailable (project_dispatch.rs:342, owner_status != Active) and Alice gets 409 `agent_unavailable`. For a botin still listed in the project, that can only mean the owner's account is not active. POST /pipelines leaks the same way (project_pipelines.rs:198). So Alice learns Bob's budget state and account state, which the product rules say must never reach other members. The agent-facing path hides exactly this on purpose: child_refusal gives one text for Unavailable, Busy and Budget, and the test `refusals_do_not_tell_why_another_owner_cannot_take_work` says that is because another owner's account and budget are private. The App-facing path breaks that rule.

FIX: In create_project_task and start_project_pipeline, when target owner != creator, map TargetRefusal::Unavailable and ::Budget (and ::Busy, if it should match the agent path) to a single code with a generic message, e.g. 409 `agent_unavailable` "this botin cannot take project work now". Keep the precise codes only when the creator is the botin's owner. Update the doc comments in gateway project_tasks.rs, client-core api.rs and error.rs, and the gateway test.

VERDICT: Confirmed. create_project_task (project_dispatch.rs:421-428) and start_project_pipeline (project_pipelines.rs:193-198) pass TargetRefusal::into_error straight through, so Alice gets 409 budget_reached when Bob's botin limit or member budget is used up. The gateway test at api.rs:7059-7077 asserts exactly this. The plan (F16, plan.md:1182) kept budget_reached distinct on the creator route "because budgets are project information the creator manages", but that reason does not hold in the code. set_project_budget (project_members.rs:661) lets each member set only their own budget, my_project_budget shows a member only their own, and the user's answer #3 says botin limits are owner-only ("限额只有主人看得到、改得了"). The same design hides tokens_used and failure reasons from ProjectRun, and the agent path returns one text on purpose. agent_unavailable is now a precise signal too. F16 called it generic when it covered frozen, paused and left owners. After D20 changed, paused owners no longer refuse (they get owner_confirm). Leaving withdraws the botins, and a deleted owner is filtered out of the locked users and gets Conflict. Freezing (account.rs:36-48) leaves the botins in the project. So for a listed botin, 409 agent_unavailable now means Bob's account is frozen. Alice can tell the two apart and learns Bob's account state or budget state. Busy is not private: members can already see queued project runs.

VFIX: In create_project_task and start_project_pipeline, when the target's owner != creator, map TargetRefusal::Budget to Error::AgentUnavailable ("this agent cannot take project work now"), so frozen and budget-exhausted give the same code. Keep budget_reached only when the creator owns the botin. Update the docs in gateway routes/project_tasks.rs, error.rs, client-core api.rs, ffi.rs and error.rs, and the gateway test (Alice should now expect agent_unavailable; Bob dispatching to his own botin still gets budget_reached).

## contract F2 [medium -> low] real=True
### Owner-confirm reminders stay unread when a held task is cancelled any way other than confirm, cancel route or expiry
crates/store/src/runs.rs:1127

SCENARIO: settle_owner_confirm_inbox has only three callers: project_tasks::cancel_run, project_tasks::confirm_task, and executor::sweep_project_runs, which settles only the `unconfirmed` list (executor.rs:737-742) and not `orphans`. Five paths cancel held runs (queued with wait_code=owner_confirm) without settling: (a) the lead's run ends and cancel_orphaned_project_children cancels its held delegate or pipeline-step child; (b) the creator archives the project (archive_project -> stop_project -> cancel_project_runs; unlike delete, archive does not call read_project_notices); (c) Bob withdraws b1 (cancel_project_agent_runs); (d) Bob presses stop-all again (cancel_user_runs); (e) the operator runs `admin project-dispatch off`, which is step one of the documented 8.17->8.16 rollback (cancel_project_runs). In each case Bob keeps an unread `owner_confirm` inbox item, so his badge stays up. Tapping "做" returns 409 "this task is not waiting for your confirmation" (404 on an archived project).

FIX: Every cancel path already calls settle_cancelled_approvals(runs). Extend it with `UPDATE inbox_items SET read_at = now() WHERE run_id = ANY($1) AND subtype = 'owner_confirm' AND read_at IS NULL` (FOR UPDATE SKIP LOCKED, like the approval branch). The orchestrator's per-instance settle calls can then stay or go.

VERDICT: Confirmed. Only three callers settle owner_confirm reminders: project_tasks::cancel_run, project_tasks::confirm_task and executor::sweep_project_runs. The sweep settles only the `unconfirmed` list, not `orphans` (executor.rs:737-742). Several paths cancel held runs (queued with wait_code owner_confirm) without settling: archive_project -> stop_project -> cancel_project_runs (project_lifecycle.rs:196-222; delete calls read_project_notices, archive does not); withdraw_project_agent -> cancel_project_agent_runs (project_members.rs:505; orchestrator withdraw_agent does not settle); stop_all/freeze -> cancel_user_runs; admin project-dispatch off -> cancel_project_runs (admin.rs:320); and cancel_orphaned_project_children. All of these call settle_cancelled_approvals, which only touches approval inbox items. Archived projects are still in member_projects(), so the item stays visible and unread, and unread_inbox_count counts it in the badge. Tapping 做 hits the 409 "not waiting for your confirmation" (or 404 once archived). settle_owner_confirm_inbox works per instance, so it heals itself on the next confirm, cancel or expiry on that botin, but after archive or withdraw nothing comes next. This is only a stale unread badge, so severity is low, not medium.

VFIX: In settle_cancelled_approvals (runs.rs:1127), also run `UPDATE inbox_items SET read_at = now() WHERE id IN (SELECT id FROM inbox_items WHERE run_id = ANY($1) AND subtype = 'owner_confirm' AND read_at IS NULL FOR UPDATE SKIP LOCKED)`. Every cancel path passes the locked held runs through it.

## contract F3 [low -> low] real=True
### client-core wipes a project's cached inbox and runs when a write to an archived project returns 404
crates/client-core/src/client.rs:428

SCENARIO: Client::post_to_project_board, create_project_task and start_project_pipeline send the write's result through project_read (client.rs:415/428/449). project_read calls forget_project(project, None) on any `not_found`. The store answers every write to an archived project with NotFound (project_actor with only Active allowed; documented as "归档了的项目写也 404"), but the user is still a member and GET /board still works on an archived project. A member who opens an archived project's board and tries to post gets a 404. client-core then deletes every cached non-receipt inbox item for that project (unread ones too, including owner_confirm) and all cached runs of that project. That cache is the project_read docstring's "whole-project reads", which this write is not. The next sync_inbox brings back only the newest page, so older items and their local read state are lost.

FIX: Return the write results through signed_out_clears instead of project_read, which is what the 8.15 writes (update, archive, budget) already do. Or forget only after a follow-up GET /v1/projects/{id} also returns 404.

VERDICT: Confirmed. Client::create_project_task, post_to_project_board and start_project_pipeline (client.rs:415/428/449) route their results through project_read. project_read's own doc says it is for whole-project reads, and it calls forget_project on any not_found. These writes call project_actor(..., &[Active]) (project_board.rs:64, project_dispatch.rs:394, project_pipelines.rs:177), which returns NotFound for an archived project. member_projects() still includes archived projects, so the user is still a member and the board GET works. forget_project (cache.rs:402-425) deletes every non-receipt cached inbox item of that project, their pending_reads rows (unflushed local reads are lost), and all cached runs of the project. The server copy is authoritative, and sync_inbox/older_inbox refetch what is missing, so nothing is lost on the server. The trigger needs a write on an archived project, for example the creator archiving while a member is posting. Low.

VFIX: Return these three write results through signed_out_clears, as the 8.15 writes (update, archive, budget) do. Keep project_read for the whole-project GETs.

## contract F4 [low -> none] real=False
### With dispatch off, outsiders and removed members get 503 instead of 404 on POST /runs and /pipelines
crates/store/src/project_dispatch.rs:389

SCENARIO: create_project_task checks project_dispatch_enabled() before project_actor and require_creator (project_dispatch.rs:388-390); start_project_pipeline does the same (project_pipelines.rs:163). While the switch is off, which is the default after migration 0060 and the state during a rollback, every caller gets 503 `unavailable` "project tasks are not switched on yet". That includes non-members, removed members and callers using a deleted project's id. This breaks the documented rule (not a member or deleted -> 404; member -> 403). A removed member's app also never gets the 404 that would make project_read forget the project.

FIX: Move the DispatchOff check after project_actor(...) and require_creator(...) in both functions. The database fence still catches a switch-off that races the insert.

VERDICT: The code does check the switch first (project_dispatch.rs:388, project_pipelines.rs:162), so everyone gets 503 while dispatch is off. That is not a defect with an impact. The 503 is the same for every caller and every project id, including nonexistent ones, so it reveals nothing about whether a project exists or who is a member. The gateway docs list 404/403/503 without saying which wins, and the plan does not either. A non-member or removed member learns nothing beyond "the feature is off", which is true. Every read endpoint still returns 404 for them, so client-core's forget logic still fires on reads (and per F3, writes should not trigger it anyway). Moving the check is optional cleanup.

VFIX: None

## contract F5 [low -> low] real=True
### Documented 8.17->8.16 rollback command leaves out the required --operator
docs/release.md:176

SCENARIO: The rollback step says to run `thinktin-server admin project-dispatch off --reason "…"`. DispatchCommand::Off declares `operator: String` with `#[arg(long, env = "THINKTIN_OPERATOR")]` and no default (server/src/main.rs). An operator who pastes the documented command in a pod without THINKTIN_OPERATOR set gets a clap error, so the switch is not turned off as the first rollback step. The rollout step in the same doc and the deploy checklist do include --operator.

FIX: Change the line to `thinktin-server admin project-dispatch off --reason "…" --operator <你>`, or say that THINKTIN_OPERATOR must be set.

VERDICT: Confirmed. docs/release.md:176 shows `admin project-dispatch off --reason "…"` without --operator. DispatchCommand::Off requires `operator: String` with `#[arg(long, env = "THINKTIN_OPERATOR")]` and no default (server/src/main.rs:119-126). No deploy doc or manifest sets THINKTIN_OPERATOR, while the rollout line (release.md:165) and deploy-checklist.md:134 do pass --operator. Clap fails at once with a clear 'required argument --operator' message, so the operator loses seconds, not the rollback. Still a concrete error in a rollback runbook.

VFIX: In release.md:176, change the command to `thinktin-server admin project-dispatch off --reason "…" --operator <你>`.

## contract F6 [low -> low] real=True
### GET /pipelines/{root} returns the title as `goal` when the pipeline was started without a goal
crates/store/src/project_pipelines.rs:389

SCENARIO: project_pipelines has no goal column. start_project_pipeline sets the root prompt to the goal, or to the title when the goal is empty (line 238). The member read then returns `goal: run.prompt`. A creator who starts a pipeline with goal "" (allowed; the FFI smoke test does this) reads back {title: "t", goal: "t"}, so the App shows the title a second time as the goal. The client cannot tell "no goal" from "goal equals title".

FIX: Store the goal: add a nullable `goal` column in a new migration and return it. Failing that, return an empty goal when run.prompt == title and the stored goal was empty.

VERDICT: Confirmed. project_pipelines has no goal column (0065). start_project_pipeline stores the root prompt as goal, or as the title when goal is empty (project_pipelines.rs:237-238). ProjectTx::project_pipeline returns `goal: run.prompt` (around line 389). A pipeline started with goal "" (allowed by check_project_pipeline; the FFI smoke test does this) reads back goal == title, so the App shows the title twice. The client cannot tell that from a real goal. The only effect is what the App displays.

VFIX: In project_pipeline, return an empty goal when run.prompt == title. The rare case of a goal identical to the title then shows nothing, which is harmless. Or add a nullable goal column in a new migration and return it.

## contract F7 [low -> low] real=True
### Board 429 always says Retry-After 3600 although the cap is a rolling 24-hour window
crates/store/src/project_board.rs:75

SCENARIO: A member posts 50 board entries in a burst. The 51st returns 429 with retry_after_secs=3600 and the Retry-After header set. The count is `created_at > now() - interval '1 day'`, so a retry after an hour is refused again, and that repeats for up to about 23 hours. The client-core and FFI docs tell apps to use retry_after_secs, so an app that shows or schedules the retry misleads the user.

FIX: Compute the wait from the window: the created_at of the post that will drop out first (ORDER BY created_at DESC OFFSET 49 LIMIT 1) + 1 day - now(), clamped to at least 1 second, and pass that to Error::RetryAfter.

VERDICT: Confirmed. project_board.rs:66-75 counts member posts with `created_at > now() - interval '1 day'` but always returns Error::RetryAfter(3600). If 50 posts were made in a burst, a retry after an hour is refused again, for up to about 23 hours. The client docs (ffi.rs:3891, error.rs) tell apps to use retry_after_secs. The same crate already computes this correctly for invites (project_invites.rs:361-375: min(created_at) + 24h - now()). The wait value is wrong. Nothing else breaks.

VFIX: Use the same query as invite_caps: `SELECT count(*), ceil(extract(epoch FROM min(created_at) + interval '1 day' - now()))::bigint FROM project_board_posts WHERE project_id=$1 AND author_user_id=$2 AND NOT by_agent AND created_at > now() - interval '1 day'`, and return RetryAfter(wait.max(1)).

## contract F8 [low -> none] real=False
### The own-vault-value hard block on project board posts skips the tags
crates/orchestrator/src/project_tasks.rs:304

SCENARIO: post_to_board checks only `body` with contains_own_secret. Client::post_to_project_board likewise runs refuse_secrets on the body only. Tags are stored and shown to every member and their botins. A valid tag is up to 32 letters, digits, `-` or `_`, which fits typical passwords and short keys. A member who tags a post with a saved vault value (for example "Abc12345") gets it published to the whole project, although the module doc promises that member-written board entries containing one's own vault values are refused (422).

FIX: Pass the tags to contains_own_secret too (`texts = [&body] + tags`), and run refuse_secrets on each tag in Client::post_to_project_board.

VERDICT: The gap exists in code: post_to_board (project_tasks.rs:304) checks only the body, and the client checks only the body, the same as the private board. There is no realistic path, though. The hard block is a guard against pasting a saved secret by accident into free text. Tags are short labels the user types on purpose, 1-32 chars of [a-z0-9-_], and the gateway lowercases them before the orchestrator sees them (normalize_board_tags, board.rs:45; project_board.rs:90). A user would have to deliberately type their own password or key as a tag. Because of the lowercasing, the suggested fix (scrubbing the stored tags) would also miss most mixed-case secrets. The only exposure is the user's own value, which they typed themselves.

VFIX: None

## contract F9 [low -> low] real=True
### Standing project grants issued by pipelines, asks and delegations get no grant.issue audit row
crates/store/src/project_pipelines.rs:189

SCENARIO: project_target -> ensure_project_agent_grant issues a new standing grant for another owner's botin when it has none or the old one expired. Only create_task writes `grant.issue` for the owner (project_tasks.rs:79). start_project_pipeline calls project_target for every step during validation (project_pipelines.rs:189-198), project_step_run calls it again later, and project_child_run (ask/delegate) does the same. None of these record the issuance, so Bob's audit trail shows a 90-day standing grant on his botin with no row saying who caused it or why. That misleads an operator investigating his grants.

FIX: Return `issued` from project_target through start_project_pipeline, ProjectStepStart and the project_child_run result. Have the orchestrator callers write `grant.issue` for the owner, with reason "project pipeline", "project ask" or "project delegate", as create_task does.

VERDICT: Confirmed. project_target -> ensure_project_agent_grant issues a new 90-day standing grant on the target owner's botin when there is none, or it expired or was revoked for a reason other than stop_all. It returns `issued` (grants.rs:466-520). The plan (plan.md:531) says it returns issued=true "so callers can audit". Only create_task writes `grant.issue` (project_tasks.rs:79-87). start_project_pipeline discards the result (project_pipelines.rs:193-197). project_step_run (around :344) and project_child_run (project_dispatch.rs:862-867, asks and delegates) do not pass it back. ask.rs, delegate.rs and pipeline.rs write no grant audit. In a project where the creator only uses pipelines, or the lead only delegates or asks, Bob's botin gets a standing grant with no audit row. The run_grants row itself still exists, so this is an incomplete audit trail, not a security hole.

VFIX: Return the issued grant id from start_project_pipeline (or a ProjectStepStart field) and from ProjectChildResult::Created. In the orchestrator callers, write `grant.issue` for the owner (actor "system", reason "project pipeline", "project ask" or "project delegate"), the same way create_task does.

