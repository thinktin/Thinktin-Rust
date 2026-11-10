# 8.17 定稿方案（workflow `projects-8-17-plan`，2026-11-06）

# WP 8.17 implementation plan (final): in-project collaboration (dispatch, project board, project-scoped peers, ask, delegate and pipelines, the lead agent)

- **Branch:** `claude/determined-lovelace-vn0j5h` at `1afbb1a` ("progress: 8.16 done, 8.17 claimed"). The tree is clean. I changed no files.
- **Migrations:** the last one is `0059_isolation_review_fixes.sql`, so 8.17 uses **0060–0063**.
- **Nothing is deployed and there is no `v*` tag** (`git tag` is empty), so `tools/ci/check_migrations.py` only checks file names. Statements that would need `-- deploy-safe:` once a tag exists carry it anyway. Every migration is one transaction. None of them builds an index on an existing large table.
- **This version** applies the corrections from the security critic and the implementation critic. I checked each one against the code, and Appendix A lists every correction as Applied or Rejected, with the reason.
- **What I checked:**
  - every file:line reference below, against the code at `1afbb1a`;
  - the SQL in §1, on a scratch PostgreSQL 16.15 database. I applied 0001–0059 as the non-superuser owner `thinktin_test_owner`, as the test harness does, then 0060–0063 exactly as printed here. Behaviour was tested through a non-superuser login granted `thinktin_app` and `thinktin_worker`, as in production (`docs/release.md:72-75`). I dropped the scratch database and the login afterwards. The results are in §1.0.
- **What I did not check:** no Rust is written yet. RDS behaviour and pooler behaviour are the founder checks in §7.

---

## 0. Decisions

### Scope

**In 8.17:**
- **Dispatch switch.** A switch held in the database, flipped by an admin CLI command. Before flipping it, the operator reads an advisory `legacy_sessions()` count, which runs on the server login's own connection.
- **INSERT-time fences** on project runs and project grants. The lease fence also requires the 8.17 "project protocol".
- **The dispatcher** in `store` is the only writer of executable project runs and project grants. This is enforced by the DB fence and by a crate-private Rust API.
- **Standing project grants.** They are not reissued after "stop all". The owner resumes the botin's project work explicitly.
- **Cross-owner delegate child grants.**
- **Cross-owner run trees**, plus an orphan sweep every 15 s.
- **The lead:** a creator-only setter, a per-space lead check, and delegation by the lead.
- **Project-scoped tools,** each added to `PROJECT_RUN_TOOLS` and switched on `ToolContext.project`: `agents_list`, `agent_status`, `board_read`, `board_post`, `ask`, `delegate_list` and `delegate`.
- **The project board:** a new table, agent tools and App routes.
- **One-off project pipelines,** started by the creator and rooted on the creator's own dedicated botin.
- **Project cancel** across owners.
- **Deleting a project artifact** (deferred from 8.15, `projects-impl.md:148`).
- **Per-owner tree token accounting**, plus a coarse per-owner budget cap at dispatch time.
- **Fan-out caps.**
- **The llm-gw token epoch in egress asks** (the 8.16 re-check leftover, `projects-impl.md:206-207`).
- client-core, Android bindings and docs.

**Deferred:**
- **8.18:**
  - precise project budgets in llm-gw, with a per-(project, owner) reservation;
  - approvals routed to owners and shown as "waiting for owner";
  - the owner's per-agent narrowing of project scope;
  - vault per item, computer per project, and the browser per project;
  - **all interrupt rules, including the creator's urgent messages.** The draft had urgent messages in 8.17 as D15; they move here (`projects.md:86,128`, `wbs.md:221`);
  - frozen-account handling;
  - the owner's full view of its own project-run events.
- **8.19:**
  - the project feed;
  - receipts (lead changed, task finished or failed to the creator, pipeline finished);
  - board @mention pushes;
  - reporting other people's content;
  - IM pushes of project content.
- **Level 2:** mixed (non-dedicated) agents.
- **Not in any WBS package yet** (needs a new line, §7): recurring project plans (`schedule_*` in project runs) and pipelines built by the lead.

| # | Decision | Why / evidence |
|---|---|---|
| D1 | **Only dedicated agents do project work (isolation level 1). Mixed agents never get a project run from any version.** Both the INSERT fence (§1.1) and the lease fence need level 2 for a mixed instance, and no binary declares level 2. "Live" also requires that the agent's instance is not deleted. This covers the window between the tenant `remove_instance` and the worker retire (`instances.rs:385-420`). | 8.16 D2/D10. `runs_isolation_fence` (`0055:137-151`). `space_matches_instance` accepts a project row on a mixed instance (`0055:63` only checks when `ws IS NOT NULL`), so the new INSERT fence must check this. Verified: §1.0 V7. |
| D2 | **Teams (solo projects) keep working unchanged.**<br>• Mixed team agents keep private runs and private delegation (`is_team_lead` `instances.rs:617-627`, `delegation_targets` `:594-612`, `delegate.rs`).<br>• `/v1/teams*`, the Team FFI and template adoption are untouched. Template adoption creates mixed instances with private grants (`routes/teams.rs:243-244`).<br>• A dedicated agent in a solo project gets project runs from the dispatcher, exactly as in a shared project.<br>• A lead and its targets must be in the same space: `runs_parent_space` and `run_grants_parent_space` (`0045:12-15`) forbid crossing. So a mixed lead cannot delegate to dedicated members. The creator tasks those members directly.<br>• The 8.16 plan §8 listed "team runs as project runs" for 8.17. That item is rejected; the rejection is recorded in `wbs.md` and the progress file. | Turning team runs into project runs would stall them on mixed agents for ever, because claims need `isolated!` (`runs.rs:361-371`). Dedicating every team agent would wipe memory and block private messages (8.16 D5, `routes/runs.rs:43-46`). A "same owner" exception would expose mixed memory once the project is shared. |
| D3 | **Who dispatches:**<br>• **The project creator, in the App:** project tasks to any live dedicated agent (default: the lead), and one-off pipelines. The creator may cancel any run of the project.<br>• **The lead agent:** `delegate` to any live dedicated project agent, whatever its owner.<br>• **Any live dedicated project agent:** may `ask` any other live dedicated agent of the same project.<br>• **Member owners:** cannot dispatch, not even to their own dedicated botin, which already refuses private messages with 409. They keep stop (cancel their own agent's runs), withdraw, budget, and the new "resume" after "stop all" (D20).<br>• **Not in 8.17:** urgent messages that interrupt a running task (D15). | `projects.md:18,80-81`; `projects-impl.md:13,20`. |
| D4 | **The dispatcher lives in `store` (`Tx<Worker>`) and is the only writer of project runs and project grants.**<br>• **Three entry points:** creator task; child of a running project run (ask or delegate); pipeline root or step. All liveness checks run after the project advisory lock.<br>• **People** go through `ProjectActor` (`projects.rs:84-183`, crate-private).<br>• **Agents** go through a new crate-private `ProjectAgentActor`. The calling run is locked and must be live. Its agent row, member row and dedication are re-read under the lock.<br>• **Lock order** (8.14 D3 plus 8.16 D13): users `FOR KEY SHARE` (`lock_users`, `projects.rs:112-118`: caller's owner, target's owner, creator) → `project/{p}` advisory → member and agent rows (plain reads; only `set_project_lead` takes `FOR NO KEY UPDATE`) → runs (`FOR NO KEY UPDATE`) → approvals → requests → INSERT grant and run. The triggers take `KEY SHARE` on the instance and `FOR SHARE` on `project_dispatch`.<br>• **The pipeline driver** takes the same order per root (D14).<br>• The per-user `lock_run_waits` is not used in projects. The project lock serializes the wait graph of `p`, which is closed because dedicated instances only run `p`'s runs.<br>• **Rust enforcement:** `NewRun.project_id` is `pub(crate)`. Only the dispatcher's crate-private `insert_project_run` sets it. `Tx<Worker>::create_run` (`runs.rs:1127-1129`) refuses a `NewRun` that carries a project. | `projects-impl.md:20`.<br>• Every writer that changes liveness already takes `project/{p}` first: withdraw, leave and remove (`project_members.rs:444-519`), archive and delete, instance delete (`lock_instance_projects` `projects.rs:414`, called from `remove_instance` `instances.rs:391-393`), and release (`instances.rs:1232`).<br>• Two users' per-user wait locks would not serialize a cross-owner cycle (`runs.rs:470-478`). |
| D5 | **Grants.**<br>**(a) Standing project grant**, one per (project, agent):<br>• owner = the agent's owner, `project_id = p`, `parent_id` and `plan_id` NULL;<br>• scope = `proto::domain::PROJECT_PLATFORM_TOOLS` (the 12 tools of D10), aliases empty (all of the instance's routes), `max_tokens` None;<br>• issued lazily by the dispatcher with the caller's configured grant TTL. The gateway and orchestrator both default to 90 days (`gateway/src/lib.rs:56`, `orchestrator/src/tools.rs:50`). Renewed by `touch_run_grant` (`grants.rs:339-360`);<br>• not reissued after "stop all" (D20).<br>**(b) Delegate children** get a child grant:<br>• `parent_id` = the caller's grant, `user_id` = the **target's owner**, `project_id = p`;<br>• scope = the target's standing scope with `platform_tools` ∩ the parent's `platform_tools`, aliases from the target only, `max_tokens` = the minimum;<br>• TTL = min(`CHILD_GRANT_TTL` = 7 days `delegate.rs:31`, the parent's remaining lifetime).<br>**(c) Ask children and pipeline steps** run on the **target's standing grant**: the answerer or step uses its own authority, as in 8.11. So another owner's "stop all", or withdrawing the pipeline's anchor, does not revoke a step's authority.<br>**Drop `run_grants (parent_id, user_id)`** (`0001:174`).<br>**Revocation, either side:**<br>• target side: `revoke_project_agent_grants`, `revoke_project_member_grants`, `revoke_user_grants` and `revoke_instance_grants` match the child directly by `instance_id`/`user_id` (`grants.rs:211-291,378-389`);<br>• lead side: the recursive `parent_id` tree, plus `ancestors_usable!` at token time (`grants.rs:46-55`, `auth/src/grants.rs:113-116`, llm-gw `store/src/llmgw.rs:128-147`).<br>**Not used:** a `via_grant_id` column. It would duplicate what the parent chain already gives. | • `sandbox_token` requires grant user = instance owner (`auth/src/grants.rs:123-126`), so the child's `user_id` must be the target's owner. The old same-owner FK forbids that.<br>• The private space stays same-owner through `run_grants_parent_space`, because `space_id = user_id` (`0040:23-24`).<br>• `active_grant_for_instance` already excludes project grants (`grants.rs:362-376`).<br>• Aliases are one instance's route names (`domain.rs:423`; the executor filters `route_aliases(instance)` at `executor.rs:767-772`), so intersecting two owners' alias lists is meaningless. |
| D6 | **DB fences in 0060, enforced for every binary version:**<br>(a) **A one-row `project_dispatch` switch, off by default.** The fence reads it `FOR SHARE`, so `off` waits for dispatches already in flight (§1.0 V10).<br>(b) **`BEFORE INSERT` fences on `runs` and `run_grants` for project rows.** They require: the worker role; the switch on; `thinktin.isolation` ≥ need (1 dedicated, 2 mixed); `thinktin.project_protocol` ≥ 2; and a live agent (agent row, owner's member row, active project, instance not deleted).<br>(c) **Tree rules on `runs`:**<br>• no `plan_id`, `trigger_id`, `fire_time` or `hook_id`, no `urgent` and no `interrupts_run_id`;<br>• agent runs carry a grant;<br>• a root is either a creator task (`user`/`agent`) or a pipeline root (`pipeline`/`pipeline`, no grant);<br>• children are `delegate`, `ask` or `pipeline` under a parent that exists and has not finished;<br>• only the lead's run may parent a `delegate` child.<br>(d) **The lease fence `runs_isolation_fence` also requires `thinktin.project_protocol` ≥ 2**, so 8.16 binaries can no longer lease project runs.<br>**Why both a fence and a switch:** the fences make correctness and privacy independent of the operator; the switch protects availability during the rolling deploy (D7). | • An 8.16 executor would run an 8.17 project run degraded: only `PROJECT_RUN_TOOLS` (`tools.rs:454-460`); names read through the lead owner's tenant (`executor.rs:819-831`, empty for other owners); a 300-character child `error` quoted into the lead's prompt (`delegate.rs:238`), which members read as `agent.message` (`0054:89`); and all owners' tokens summed into one tree (`runs.rs:1341-1351`).<br>• Pipelines take no lease (8.16 D10), hence the INSERT fence.<br>• The nested-IF style follows 8.16 V15.<br>• Verified: §1.0 V7, V10. |
| D7 | **Rolling deploy and opening the switch.**<br>1. Run migrations 0060–0063. The switch is off.<br>2. Roll out 8.17, server and llm-gw, in either order: the 0062 trigger accepts asks without an epoch.<br>3. Run `thinktin-server admin project-dispatch status`. It prints the switch state, `legacy_sessions()` and the number of unfinished project runs.<br>&nbsp;&nbsp;• **`legacy_sessions()`** runs on a plain pool connection, as the server login, with **no role switch**. Under `SET ROLE thinktin_worker`, PG 16 hides `backend_type` and `state` of other sessions, so the draft's query returned nothing (§1.0 V5).<br>&nbsp;&nbsp;• It counts sessions of the same login whose `application_name` is not the current `APPLICATION_NAME`. NULL and empty names count.<br>&nbsp;&nbsp;• Cross-check each replica's `/version` and `thinktin_build_info`.<br>4. Run `admin project-dispatch on --operator … --reason …`. It refuses while `legacy_sessions()` is non-empty unless `--force`, and writes an audit row.<br>**`off`** flips the switch and commits; the UPDATE waits for dispatches in flight. Then, for each project with unfinished runs, it runs one worker transaction: `lock_project(p)` → `cancel_project_runs(p, …)` (`runs.rs:990-1015`) → commit. It repeats until the count is 0 and prints it. Rolling back to 8.16 is `off`, then deploy.<br>**`APPLICATION_NAME`** becomes `thinktin/i1p2`. `Db::worker` also sets `thinktin.project_protocol = '2'`. | • With the switch off, an 8.16 replica never meets a project run. If one exists (premature flip, or rollback without `off`), the fence makes that replica's `claim_next_run` return `Ok(None)` on the row (`runs.rs:1222-1232`), and its takeover and expired-wait UPDATEs fail as statements. So `off` must cancel.<br>• The count is only advice: the pool keeps no minimum connections (`lib.rs:124-131`), and poolers rewrite names (8.16 D11).<br>• llm-gw and relay use other logins (`release.md:72-79`). |
| D8 | **Cross-owner run trees.**<br>• **Drop `runs (parent_run_id, user_id)`** (`0001:254`).<br>• **Keep `runs_parent_space` ON DELETE CASCADE.** User rows are never hard-deleted (no `DELETE FROM users` in `store/src`). Erase deletes only private runs (`users.rs:292`). The project purge deletes runs newest first (`project_lifecycle.rs:350-352`). So a cascade never crosses owners.<br>• **Project runs never carry `plan_id`, `trigger_id`, `fire_time` or `hook_id`** (the fence), so `runs (plan_id, user_id)` (`0001:252`) can stay.<br>• `run.user_id` = the agent's owner, always.<br>• The docs commit rewords `projects-impl.md:24`. Its "将跨主人的子运行解除父关联" becomes the mechanism actually used: no hard delete, and a cascade that never crosses owners. | `0040:4` and `0045:10-11` deferred this to 8.17. Verified: §1.0 V7 (cross-owner child accepted, private cross-owner child refused by `runs_parent_space`). |
| D9 | **Project board: a separate table `project_board_posts`.**<br>• Worker writes; members read through `member_projects()`; **no tenant privilege at all**.<br>• **Plaintext**, like run prompts, summaries and events. Deleting the project makes it unreadable at once (`member_projects()` excludes deleted projects, `0049:45-51`), and the purge removes it. `projects.md:40` ("用项目密钥加密") is updated in the docs commit (founder question).<br>• **Composite FKs, as on `board_posts` (0025):**<br>&nbsp;&nbsp;• `(project_id, author_user_id)` → `project_members`. Member rows are never deleted on leave or erase, only marked `left_at` (`users.rs:319`);<br>&nbsp;&nbsp;• `(author_instance_id, author_user_id)` → `instances`, SET NULL;<br>&nbsp;&nbsp;• `(run_id, author_user_id)` → `runs`, SET NULL.<br>A trigger requires an agent post's run to be in the project.<br>• **Limits:**<br>&nbsp;&nbsp;• at most 200 live posts per project; the oldest are archived first, binding `MAX_BOARD_LIVE_POSTS - 1` as `board.rs:136-145` does;<br>&nbsp;&nbsp;• at most 50 posts by a person per project per 24 h (429 `rate_limited`);<br>&nbsp;&nbsp;• agent posts limited by `MAX_POSTS_PER_RUN` (`board.rs:25`);<br>&nbsp;&nbsp;• archived posts are kept 30 days.<br>• Posts survive leave and erase; the author shows as left or erased (`authors()`, `project_reads.rs:177-209`).<br>• **`board_posts` gets `CHECK (project_id IS NULL)`.** | • The old space-blind board paths never see this table: the 8.15 lists, the id-based archive and delete (`board.rs:157-244`), and erase's `DELETE FROM board_posts WHERE user_id` (`users.rs:335`).<br>• The 0056 stamp would otherwise turn a tenant post with a project `run_id` into an orphan project row (`0056:26-40`).<br>• Verified: §1.0 V3, V8, V12, V13. |
| D10 | **`PROJECT_RUN_TOOLS`** becomes `proto::domain::PROJECT_PLATFORM_TOOLS`: `artifact_publish`, `artifact_list`, `artifact_read`, `artifact_fetch`, `web_search`, `agents_list`, `agent_status`, `board_read`, `board_post`, `ask`, `delegate_list`, `delegate`.<br>• Non-lead runs get 10 of them; `delegate` and `delegate_list` are for the lead only.<br>• Each tool branches on `ctx.project`; `None` behaves exactly as today.<br>• Project paths read through `Db::member(ctx.user)` (the 8.15 projection), write through the dispatcher, and never scrub with the owner's vault.<br>• **Excluded:** `schedule_*` (no project plans); vault and computer (8.18); the browser (not in the standing scope, and `executor.rs:867-875` needs it in the grant). | `tools.rs:454-465`. Only artifacts and search read `ctx.project` today (`tools.rs:507-518`, `search.rs:186`). Whitelisting alone would leak. |
| D11 | **The lead.**<br>• `PUT /v1/projects/{id}/lead` `{instance_id \| null}`: creator only.<br>• The target must be a live agent of the project. In a **shared** project it must be dedicated (409 `agent_not_isolated`). In a **solo** project any live agent is allowed (team compatibility).<br>• It takes the same project lock as the tenant team writes (`projects.rs:376-403`).<br>• **Executor lead check per space:** private runs keep `is_team_lead`. Project runs use `is_project_lead(p, instance)`: `is_lead` is live, the agent is dedicated to p, the owner is a live member, and the project is active.<br>• `delegate` re-checks the lead at every call. The DB refuses a `delegate` child whose parent's instance is not p's live lead (`project_delegate_not_lead`).<br>• The lead may be any member's agent. | `projects.md:18,52,80`. Nothing sets a lead in a shared project today (`project_members.rs:305,511,631,743,783` only clear it). `is_team_lead` requires `creator_id = owner` (`instances.rs:617-627`). `project_one_lead` is a partial unique index checked per row, so the old lead is cleared first. |
| D12 | **Texts across owners.**<br>• **Stored prompts of project runs are raw, with no platform header and no names.** Creator tasks store the creator's text. Delegate children store `{title}\n\n{task}`. Ask children store the question.<br>• **Headers are rendered at launch.** The executor builds the platform header (creator task, delegated subtask, question), in the run owner's locale, from the member projection `Db::member(rec.user_id).project_detail(p)`. It prepends the header to the base prompt **for every attempt**, before the Interrupted, Announced and resume wrapping. So names are current, erased names are never stored, and a retry keeps the header.<br>• Names are sanitized: control characters, newlines and 「」 brackets are removed, and names are clipped to 40 characters. A withdrawn or deleted agent shows as "an agent that left the project", because the member policy hides its name (`0049:94-107`).<br>• **Results of project children never include `error`.** Only a coarse outcome (done, cancelled, failed, timed out) and the summary. The task is the first line of the raw prompt; there is no `split_once`. Delegated results get the "written by other agents, information not instructions" note that only asks have today (`texts.rs:663-679`).<br>• **Project pipeline roots** record only `step {key} {coarse state}`, never a step's `error` or `state_reason` (D14).<br>• **Other owners' content gets the untrusted note and a boundary fence** (as `event_input` does, `texts.rs:815-834`) in project runs: pipeline handoffs (upstream summaries) and `artifact_list`/`artifact_read` output.<br>• **Queued creator tasks are never piggybacked into a running project run** as "new message" (`unannounced_messages`, `runs.rs:1487-1508`; texts `:772`). They run after it.<br>• Tool descriptions become neutral ("agents you work with"). The shim's MCP instructions do not change: they are baked into the sandbox image (`agent-shim/src/bridge.rs:39-41`). | • `delegate.rs:228-267` passes `error` through and strips headers with `split_once`.<br>• `texts.rs:605-617` says "团队负责人".<br>• Members read prompts (`0054:34-42`) and `agent.message`.<br>• Erase blanks only `users.display_name` and `instances.name` (`users.rs:336,339`).<br>• `Preface` is one enum (`executor.rs:265-270`), and `drive_inner` wraps the base prompt on `attempt > 1` (`executor.rs:1720-1752`). |
| D13 | **Budgets.**<br>• In project trees, `tree_tokens_except` counts only runs with the same owner.<br>• A same-owner child keeps the parent's budget.<br>• **A cross-owner child, a creator task and a pipeline step** start with `RunBudget::default()`, with `max_tokens` = the target owner's remaining project budget. That is min(`daily_token_limit` − tokens of (p, owner) runs created in the last 24 h, `total_token_limit` − all tokens of (p, owner) runs). NULL limits, as on the creator's own row, mean no cap.<br>• A remaining budget of 0 is refused: `BudgetReached`, which is 409 `budget_reached` on the creator route; agents get the generic "that agent can't take more project work now".<br>• **This is approximate.** Several runs of one owner at once can overshoot. A cross-owner grandchild's cap double-counts its owner's earlier tokens in the same tree, so it stops early, never late. 8.18 replaces it with the llm-gw reservation per (project, owner) (`projects-impl.md:23`).<br>• `release.md` says: no two-owner pilot with real money before 8.18. | `RunBudget::default().max_tokens` is None (`domain.rs:376-383`). Joining requires both limits (`JoinTerms`, `project_invites.rs:98`). `projects.md:82,113` promise "不会花超". See also `executor.rs:2424-2452`, `ask.rs:153`, `delegate.rs:168`. |
| D14 | **Project pipelines are one-off and started by the creator** (`POST /v1/projects/{id}/pipelines`).<br>• **Storage:** a new table `project_pipelines` with immutable `steps jsonb`, validated by `order_steps`. Not `plans`, `plan_steps` or `triggers`. Old schedulers and drivers never see it: 8.16's `due_pipelines` filters `project_id IS NULL` (`runs.rs:1728`).<br>• **The root** (`kind='pipeline'`, `source='pipeline'`, **no grant**) is on one of the creator's own live dedicated agents: the first ordered step whose agent is the creator's, otherwise the creator's first by position. With none, 422 "add one of your own dedicated botins to run a pipeline". So only the creator owns, and can cancel, the root, and no other member's "stop all" or withdraw touches it.<br>• **Each step** runs on the step agent's own standing grant (D5c), in the step owner's locale, with the untrusted note on the handoff.<br>• **Driver:** private roots stay in today's batch (`due_pipelines` unchanged). Project roots come from a plain read `due_project_pipelines`. Each root is advanced in its own worker transaction, in D4 order: `lock_users`(creator + step owners) → `lock_project(p)` (blocking) → root `FOR UPDATE SKIP LOCKED` (skip it if none) → advance → requeue → commit. Step creation stays in the 8.16 savepoint, and **every non-`Db` store error** rolls back to it and fails only that pipeline.<br>• **On failure:** the root records `step {key} {coarse}`; the rest of the tree is cancelled with `cancel_project_subtree` (with D13 settling), not `cancel_children` (`runs.rs:1803-1822`).<br>• Project roots send no push or live activity in 8.17 (8.19).<br>• The source is `pipeline`, not `user`, so a root is never piggybacked. | • `plan_steps` FKs are same-user (`0002:66-67`); steps on dedicated instances are refused (`0055:70-81`); plans cannot be active on dedicated instances (`0055:83-96`).<br>• The draft's batch-transaction design (roots `FOR UPDATE`, then a try-lock, then inserts taking `KEY SHARE` on users) deadlocks with `erase_account`, which takes users `FOR UPDATE` (`users.rs:186`) and then a blocking `lock_projects` (`users.rs:207`).<br>• `pipeline.rs:149-157,332-346` copy a step's `error` into the root, which belongs to another owner. `start_step`'s `Err(e) => Err(e)` (`pipeline.rs:247`) aborts the whole tick. |
| D15 | **Urgent project messages are deferred to 8.18**, together with the other interrupt rules (creator, owner, lead; `projects.md:86`). 8.17 has no `delivery: "interrupt"` and no worker `queue_urgent_run` variant, and the fence refuses project rows with `urgent` or `interrupts_run_id`. In 8.17 the creator cancels a run (D16) and sends a new task. | `wbs.md:221` and `projects.md:128` put "打断规则" in 8.18. `queue_urgent_run` (`runs.rs:644-748`) is `Tx<Tenant>`; refactoring it for half the rules would be done twice. |
| D16 | **Cancels.**<br>• `POST /v1/projects/{id}/runs/{run}/cancel`: the creator may cancel any run of p, an owner its own agent's runs, anyone else gets 403. It **cancels the subtree across owners**, as worker, in D13 order. Pipeline roots are the creator's by construction (D14).<br>• **Withdraw and leave** (`cancel_project_agent_runs`, `cancel_project_member_runs`, `runs.rs:899-988`) cancel the recursive subtree of the agent's or member's project runs. Today they only cancel trees *rooted* on the instance or user, so the children of a lead answering an ask are missed.<br>• **Orphan sweep in the executor's takeover tick** (every 15 s, `executor.rs:85,500-511`, next to `expire_asks`): project `delegate` and `pipeline` children whose parent has ended are cancelled with `SKIP LOCKED` throughout. This catches the tenant single cancel, tenant tree cancel under RLS (`runs.rs:599-624`), stop-all, freeze and erase (`cancel_user_runs` `runs.rs:873-897` touches only the user's rows). Asks already have `cancel_stale_asks` (`runs.rs:1551-1578`).<br>• **Worker cancels that skipped the D13 settling now do it** before the epoch bump: `cancel_descendants` (`runs.rs:1306-1339`), `cancel_children` (`:1803-1822`), and the ask cancels behind `cancel_stale_asks`. They settle approvals and expire egress and vault requests.<br>• The tenant `/v1/runs/{id}/cancel` on a project run stays tenant: it cancels the caller's own rows, and the sweep handles the rest within one tick. | • A parent cancelled in `waiting_children` has no executor to run `cancel_descendants` (`executor.rs:1182-1188`).<br>• `projects::sweep` runs only hourly (`server/src/config.rs:862`).<br>• Verified the recursive lock and the sweep pick parse and run: §1.0 V14. |
| D17 | **Egress.**<br>• llm-gw passes the **authenticated token epoch** (`claims.ep`, checked at `proxy.rs:425`) into the ask.<br>• The store pre-checks `instances.token_epoch` and returns `EgressAsk::Stale`.<br>• The 0062 trigger refuses a stale `asked_epoch` in the same snapshot as the workspace read.<br>• A re-ask that does not set `asked_epoch` (an 8.16 llm-gw during rollout or rollback) carries over the old value; the trigger treats a carried-over stale epoch as unknown (NULL) instead of refusing.<br>• "Always allow" on a dedicated botin stays scoped to that botin's project workspace: `egress_hosts` is reset on retire (8.16 D6).<br>• The `EgressRequest` DTO does not change: labelling asks by project is 8.18 UI. | • 8.16 re-check leftover (`projects-impl.md:206-207`; `projects-8.16-review.md` §7). The trigger reads the current workspace (`0059:40`); a cached token stays valid for the directory TTL (`proxy.rs:404-415`).<br>• `touch_request!` (`egress.rs:94-101`) is spliced into two 3-parameter UPDATEs and a 9-parameter INSERT, so it needs a parameter.<br>• Verified: §1.0 V11. |
| D18 | **Secrets in project-visible text written by people** (creator tasks, pipeline prompts, member board posts). If the text contains a value from the writer's own vault, the gateway returns **422**; this is the hard block. client-core runs `refuse_secrets` first and **keeps the `allow_secrets` override**, because that check is pattern detection with false positives (`client.rs:417-428`). There is no `[vault:name]` placeholder: it would show item names to other members. Agent-written project text is never scrubbed (8.16 D14). | `routes/vault.rs:76-82` and `client.rs:417` substitute named placeholders. |
| D19 | **No new `runs.source` value.** Creator tasks use `user`; pipeline roots use `pipeline`. An optional "requested by" field waits for the 8.19 feed. | Strict parsing (`runs.rs:235`); `release.md:45-48`. |
| D20 | **"Stop all" pauses the owner's project work until the owner resumes it.**<br>• `stop_all` already cancels the owner's runs and revokes its grants with reason `stop_all` (`account.rs:91-96`).<br>• `ensure_project_agent_grant` looks at the newest standing grant for (p, instance) created since the agent row's `added_at`. If it was revoked with `STOP_ALL_REASON`, the call refuses with `AgentUnavailable` instead of reissuing.<br>• Only the owner reissues: `POST /v1/projects/{id}/agents/{instance}/resume`. Re-adding an agent sets a new `added_at` (`project_members.rs:305-306`), so a later withdraw and re-add starts fresh.<br>• Frozen owners are refused at dispatch (`users.status = 'active'`), and claims check the status again (`runs.rs:1153`).<br>• A grant-API revoke of a standing grant (the tenant can see it, per the `run_grants` tenant policy) only stops current work; the next dispatch reissues it.<br>Founder question. | In private, `ensure_instance_grant` reissues only on the owner's own action (`routes/runs.rs:71-96`; `account.rs:88-90`). Lazy reissue by others would undo the owner's kill switch within seconds. |
| D21 | **Notices.**<br>• Owners keep the normal run notices for their own agents' project runs: inbox and push, no IM (`outbox.rs:211-231`, 8.16).<br>• **For project runs the body is platform-written**, for example "「B」 finished a project task" or "「B」's project task failed". The AI summary is not used: it was written under another member's prompt. Waits for a key or an approval are unchanged.<br>• Notices to the creator, pipeline-finished notices and receipts (including lead changes) are 8.19. | `executor.rs:1209-1250` uses the AI summary as the push body for `RunFinished`; `projects-impl.md:85-86` keeps text that other people can write off pushes. `projects.md:93`; `wbs.md:222`. |
| D22 | **FFI changes are additive only.** No App code calls the project FFI (only the generated `client_core.kt`). The Android bindings are regenerated and pushed together with the client-core commit, because CI runs `sync-core.sh --check` on every push (`.github/workflows/android.yml:59`). `apps/apple` has no committed bindings and no project UI, so it needs no change. | `git ls-files apps/apple` has no bindings; 12.25 and 13.18 do the UI. |
| D23 | **Fan-out caps**, checked under the project lock:<br>• at most 10 queued project runs per target agent, counting creator tasks, asks and delegates (`AgentBusy`, 409 `agent_busy`). Pipeline steps are not capped: the creator chose them;<br>• at most 50 board posts by a person per project per 24 h;<br>• the existing per-run caps stay: `MAX_ASKS_PER_RUN` 5, `MAX_CHILDREN_PER_RUN` 10, the depth limits, and `MAX_POSTS_PER_RUN` 20.<br>A cross-owner child waiting on its owner's approval is already bounded by approval expiry (`executor.rs:2154,2264`). | Without a per-target cap, one creator or many agents can flood a member's botin, and the budget cap only bounds the spending. |

---

## 1. Migrations

### 1.0 Checks on a scratch PostgreSQL 16 database (run; results below)

Setup: 0001–0059 applied as `thinktin_test_owner`, then the texts in §1.1–§1.4. Fixtures: users Alice, Bob and Carol; dedicated instances A (Alice, the lead), B (Bob) and C (Carol); a mixed instance M (Alice); a shared project p. The tests ran through a non-superuser login granted `thinktin_app` and `thinktin_worker` (and `thinktin_member` with `SET TRUE`, as in `release.md:73-75`).

- **V1 (trigger order). Passed.** The triggers on `runs` are `runs_instance_space`, `runs_isolation` (UPDATE only), `runs_project_fence`, `runs_project_tree` and `runs_space`, and they fire in name order. Fence errors come before `fill_space`.
- **V2 (constraint names). Passed.** The FKs are `runs_parent_run_id_user_id_fkey` and `run_grants_parent_id_user_id_fkey`.
- **V3 (CHECK under FORCE RLS). Passed.** `ADD CONSTRAINT … CHECK` validates rows that FORCE RLS hides from the owner: the owner saw 0 rows, and the constraint was still rejected.
- **V4 (missing parent). Replaced.** The draft relied on NULL fields. The trigger now uses `IF NOT FOUND`, and a missing or finished parent raises `project_run_shape`. Passed.
- **V5 (`legacy_sessions`). The draft's query fails.** Under `set_config('role','thinktin_worker',true)`, another session of the same login shows `application_name` and `usesysid`, but `backend_type` and `state` are NULL, so the draft's `backend_type = 'client backend'` matched 0 rows. As the login, with no role switch, everything is visible. The corrected query (§2.1) listed a `thinktin/i1` session and an empty-name session, and not the current one.
- **V6 (consistent read). Passed.** The new trigger reads `workspace_id` and `token_epoch` in one `SELECT … INTO`, and retire changes both in one UPDATE (`instances.rs:1160-1170`).
- **V7 (fences). Passed:**
  - a tenant INSERT of a project grant gives 42501;
  - with the switch off, an INSERT gives `project_dispatch_off`;
  - an 8.16-style connection (isolation only) with the switch on gives `runs_isolation`;
  - a mixed instance with isolation 1 gives `runs_isolation`;
  - a withdrawn agent gives `project_agent_gone`;
  - a `plan` root, an agent run with no grant, and a child of a missing or finished parent each give `project_run_shape`;
  - a non-lead's `delegate` child gives `project_delegate_not_lead`;
  - the lead's cross-owner `delegate` child and its cross-owner child grant are accepted;
  - a lease without the protocol gives `runs_isolation`, and with it the lease succeeds;
  - a private cross-owner child is refused by `runs_parent_space`.
- **V8 (function owner). Passed.** After `CREATE OR REPLACE FUNCTION runs_isolation_fence()` the owner is still `thinktin_test_owner`.
- **V9 (cascade). Passed.** Deleting the project's runs newest first removes the `project_pipelines` row by cascade.
- **V10 (the switch and in-flight dispatches). Passed:**
  - two dispatches holding `FOR SHARE` do not wait for each other;
  - the flip waits for a dispatch in flight (`lock_timeout` hit);
  - a dispatch started during an uncommitted flip waits, then sees "off".
- **V11 (egress epoch). Passed:**
  - a re-ask without an epoch, after the epoch was bumped, is accepted, `asked_epoch` becomes NULL, and the row is recorded under the new workspace;
  - an INSERT, an `ON CONFLICT … asked_epoch = EXCLUDED.asked_epoch` and an UPDATE carrying the old epoch are each refused (`egress_stale_token`);
  - the current epoch is accepted;
  - a decision UPDATE cannot change `asked_epoch`.
- **V12 (board FKs and trigger). Passed:**
  - the composite FK `ON DELETE SET NULL (run_id)` nulls `run_id` when the run is deleted;
  - an agent post whose run belongs to another owner is refused by the FK;
  - an agent post with no run is refused by the trigger.
- **V13 (who reads). Passed.** Bob as `thinktin_member` reads p's board posts and pipelines. `thinktin_app` gets "permission denied" on `project_board_posts`. A worker `board_posts` INSERT stamped from a project run violates `board_posts_private`. A tenant one already fails earlier in 0056's stamp ("refers to a run that is not visible").
- **V14 (new store SQL parses and runs).** The recursive subtree lock for withdraw, the orphan-sweep pick (`FOR NO KEY UPDATE OF c SKIP LOCKED`), the budget-remaining query and the standing-grant lookup.

### 1.1 `0060_project_dispatch.sql` (one transaction)

```sql
-- 派单（WBS 8.17，docs/projects-impl.md 第 3 条、“迁移与放量”）：可执行的项目运行、项目授权只由 8.17 的派单写。
-- 1. 库里的开关（一行，默认关）：运维确认老副本都退出以后 `thinktin-server admin project-dispatch on` 打开。
-- 2. 写入时的栅栏：项目运行、项目授权只有 worker、开关开着、连接声明了隔离级别（专属 1、混用 2）和项目协议（2 = 8.17：
--    跨主人的运行树、项目授权、项目里的工具）时写得进；agent、主人的成员关系、项目、实例都还在；只有负责人的运行能委派；
--    父运行还没结束；agent 运行要带授权；不来自计划，不是紧急消息（打断规则在 8.18）。
-- 3. 拿租约也要项目协议 2：8.16 的程序不再执行项目运行（它按主人的租户读名字、把子运行的失败原因交还给负责人）。
-- 4. 删掉同一主人的父子外键：项目里的运行树跨主人；私人空间里 0045 的同一空间外键照样要求同一个用户（space_id = user_id）。
-- 5. 私人看板不收项目条目（项目看板是 0061 的新表）。
-- 前提同 0039：第一次部署之前发布；滚动发布时上一版（8.16）不写项目运行、项目授权、跨主人的子运行。

CREATE TABLE project_dispatch (
    id         boolean PRIMARY KEY DEFAULT true CHECK (id),
    enabled    boolean NOT NULL DEFAULT false,
    changed_at timestamptz NOT NULL DEFAULT now(),
    changed_by text NOT NULL DEFAULT 'migration' CHECK (length(changed_by) BETWEEN 1 AND 200),
    reason     text CHECK (length(reason) <= 500)
);
-- 先插再开行级安全（FORCE 下迁移账号写不进）。没有策略：只有 worker（BYPASSRLS）读写。
INSERT INTO project_dispatch (id) VALUES (true);
ALTER TABLE project_dispatch ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_dispatch FORCE ROW LEVEL SECURITY;
-- UPDATE 的列权限也让下面的栅栏能 FOR SHARE 读这一行（和关开关的 UPDATE 排队）。
GRANT SELECT, UPDATE (enabled, changed_at, changed_by, reason) ON project_dispatch TO thinktin_worker;

-- agent、主人的成员关系、项目、实例都还在（和 store runs.rs 的 live_space!、cancel_orphaned_project_runs 一样，加上实例
-- 没删：租户删实例到 worker 撤下之间的那一会儿）。
CREATE FUNCTION project_agent_live(p uuid, i uuid, u uuid) RETURNS boolean LANGUAGE sql STABLE
    SET search_path = pg_catalog, public, pg_temp AS $$
    SELECT EXISTS (SELECT 1 FROM public.project_agents a
                     JOIN public.project_members m ON m.project_id = a.project_id AND m.user_id = a.user_id
                                                  AND m.left_at IS NULL
                     JOIN public.projects pr ON pr.id = a.project_id AND pr.status = 'active'
                     JOIN public.instances ins ON ins.id = a.instance_id AND ins.state <> 'deleted'
                    WHERE a.project_id = p AND a.instance_id = i AND a.user_id = u AND a.left_at IS NULL) $$;
REVOKE ALL ON FUNCTION project_agent_live(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION project_agent_live(uuid, uuid, uuid) TO thinktin_worker;

-- runs、run_grants 共用：只引用两张表都有的列（方案 8.16 V6）。每一层 IF 单独一句（8.16 V15：别的角色读不了下面的表）。
CREATE FUNCTION project_rows_fence() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    need int := 2;
    on_ boolean;
BEGIN
    IF current_user <> 'thinktin_worker' THEN
        RAISE EXCEPTION 'project rows in % are written by the server only', TG_TABLE_NAME
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    -- FOR SHARE：关开关的 UPDATE 等已经过了这里、还没提交的派单（关了以后再取消，不会漏掉在途的）。
    SELECT d.enabled INTO on_ FROM public.project_dispatch d FOR SHARE;
    IF NOT coalesce(on_, false) THEN
        RAISE EXCEPTION 'project dispatch is switched off'
            USING ERRCODE = 'insufficient_privilege', CONSTRAINT = 'project_dispatch_off';
    END IF;
    IF EXISTS (SELECT 1 FROM public.instances i WHERE i.id = NEW.instance_id
                 AND i.workspace_project_id = NEW.project_id) THEN
        need := 1;
    END IF;
    IF coalesce(nullif(current_setting('thinktin.isolation', true), ''), '0')::int < need
       OR coalesce(nullif(current_setting('thinktin.project_protocol', true), ''), '0')::int < 2 THEN
        RAISE EXCEPTION 'this server cannot write project work on instance %', NEW.instance_id
            USING ERRCODE = 'insufficient_privilege', CONSTRAINT = 'runs_isolation';
    END IF;
    IF NOT public.project_agent_live(NEW.project_id, NEW.instance_id, NEW.user_id) THEN
        RAISE EXCEPTION 'instance % is not a live agent of project %', NEW.instance_id, NEW.project_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'project_agent_gone';
    END IF;
    RETURN NEW;
END $$;

-- 项目运行树的样子：根是创建者派的任务（user/agent）或流水线（pipeline/pipeline，不跑 agent、不带授权）；子运行是委派、
-- 提问、流水线步骤，父运行还没结束；只有负责人的运行能委派（docs/projects.md 第 7 节）。父子同一个项目由 runs_parent_space
-- 保证。
CREATE FUNCTION runs_project_tree() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    parent record;
BEGIN
    IF NEW.plan_id IS NOT NULL OR NEW.trigger_id IS NOT NULL OR NEW.fire_time IS NOT NULL
       OR NEW.hook_id IS NOT NULL OR NEW.urgent OR NEW.interrupts_run_id IS NOT NULL THEN
        RAISE EXCEPTION 'project runs do not come from plans and do not interrupt'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'project_run_shape';
    END IF;
    IF NEW.kind = 'agent' AND NEW.run_grant_id IS NULL THEN
        RAISE EXCEPTION 'a project run needs a project grant'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'project_run_shape';
    END IF;
    IF NEW.parent_run_id IS NULL THEN
        IF NOT ((NEW.source = 'user' AND NEW.kind = 'agent')
                OR (NEW.source = 'pipeline' AND NEW.kind = 'pipeline' AND NEW.run_grant_id IS NULL)) THEN
            RAISE EXCEPTION 'a project root is a task or a pipeline'
                USING ERRCODE = 'check_violation', CONSTRAINT = 'project_run_shape';
        END IF;
        RETURN NEW;
    END IF;
    SELECT r.instance_id, r.kind, r.state INTO parent FROM public.runs r WHERE r.id = NEW.parent_run_id;
    IF NOT FOUND OR parent.state IN ('succeeded', 'failed', 'cancelled') THEN
        RAISE EXCEPTION 'the parent run % is gone or over', NEW.parent_run_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'project_run_shape';
    END IF;
    IF NEW.kind <> 'agent' OR NEW.source NOT IN ('delegate', 'ask', 'pipeline')
       OR (NEW.source = 'pipeline') <> (parent.kind = 'pipeline') THEN
        RAISE EXCEPTION 'unexpected project child run'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'project_run_shape';
    END IF;
    IF NEW.source = 'delegate' THEN
        IF NOT EXISTS (SELECT 1 FROM public.project_agents l
                        WHERE l.project_id = NEW.project_id AND l.instance_id = parent.instance_id
                          AND l.is_lead AND l.left_at IS NULL) THEN
            RAISE EXCEPTION 'only the project lead delegates'
                USING ERRCODE = 'insufficient_privilege', CONSTRAINT = 'project_delegate_not_lead';
        END IF;
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION project_rows_fence(), runs_project_tree() FROM PUBLIC;
CREATE TRIGGER runs_project_fence BEFORE INSERT ON runs FOR EACH ROW
    WHEN (NEW.project_id IS NOT NULL) EXECUTE FUNCTION project_rows_fence();
CREATE TRIGGER runs_project_tree BEFORE INSERT ON runs FOR EACH ROW
    WHEN (NEW.project_id IS NOT NULL) EXECUTE FUNCTION runs_project_tree();
CREATE TRIGGER run_grants_project_fence BEFORE INSERT ON run_grants FOR EACH ROW
    WHEN (NEW.project_id IS NOT NULL) EXECUTE FUNCTION project_rows_fence();

-- deploy-safe: 收紧。8.16 的程序不再给项目运行拿租约；可执行的项目运行只在派单开关打开以后才有，开关在老副本都退出
-- 以后才开（docs/release.md）
CREATE OR REPLACE FUNCTION runs_isolation_fence() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    need int := 2;
BEGIN
    IF EXISTS (SELECT 1 FROM public.instances i WHERE i.id = NEW.instance_id
                 AND i.workspace_project_id = NEW.project_id) THEN
        need := 1;
    END IF;
    IF coalesce(nullif(current_setting('thinktin.isolation', true), ''), '0')::int < need
       OR coalesce(nullif(current_setting('thinktin.project_protocol', true), ''), '0')::int < 2 THEN
        RAISE EXCEPTION 'this worker cannot run project run %', NEW.id
            USING ERRCODE = 'insufficient_privilege', CONSTRAINT = 'runs_isolation';
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION runs_isolation_fence() FROM PUBLIC;

-- deploy-safe: 只放宽。私人空间里 runs_parent_space（0045）照样要求父子同一个 space_id（= user_id）；上一版不写跨主人的子运行
ALTER TABLE runs DROP CONSTRAINT runs_parent_run_id_user_id_fkey;
-- deploy-safe: 同上，run_grants_parent_space
ALTER TABLE run_grants DROP CONSTRAINT run_grants_parent_id_user_id_fkey;
-- runs_parent_space 的 ON DELETE CASCADE 留着：用户行从不硬删，注销只删私人运行（users.rs），项目运行只由清理按新的在前删，
-- 级联不会跨主人。
COMMENT ON CONSTRAINT runs_parent_space ON runs IS
    'same space; cascade never crosses owners: users are never hard-deleted, erase deletes private runs only';

-- deploy-safe: 哪一版都不往私人看板写项目条目（8.16 的项目运行没有看板工具；8.17 写进 project_board_posts）。0056 给
-- board_posts 加的项目标记从此只会让带项目运行的写入失败（23514），2 级时连同 0058 的索引一起删
ALTER TABLE board_posts ADD CONSTRAINT board_posts_private CHECK (project_id IS NULL);
```

### 1.2 `0061_project_board.sql` (one transaction; a new table, so plain indexes are fine)

```sql
-- 项目看板（WBS 8.17，docs/projects.md 第 3、5 节）：归项目所有，成员和成员的 agent 读写。单独一张表：私人看板的老读法
-- （8.15 不按项目过滤、按 id 归档和删除、注销按用户删）碰不到它；租户没有任何权限。正文和运行的任务一样存明文（不按
-- docs/projects.md 第 3 节说的用项目密钥加密，8.17 文档里改）；删项目时成员马上读不到（member_projects()），后台按项目清理
-- （store project_lifecycle.rs）。退出、注销以后条目留着（作者显示已退出、已注销）。0056 第 2 行说的“8.17 的项目看板”
-- 不是 board_posts 了：board_posts 从 0060 起只收私人条目。
CREATE TABLE project_board_posts (
    id                 uuid PRIMARY KEY,                                  -- UUIDv7
    project_id         uuid NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
    author_user_id     uuid NOT NULL,                                     -- 写它的人，或写它的 agent 的主人
    author_instance_id uuid,
    run_id             uuid,
    by_agent           boolean NOT NULL,
    body               text NOT NULL CHECK (length(body) BETWEEN 1 AND 2000),
    tags               text[] NOT NULL DEFAULT '{}' CHECK (cardinality(tags) <= 8),
    created_at         timestamptz NOT NULL DEFAULT now(),
    archived_at        timestamptz,
    revived_at         timestamptz,
    -- 和私人看板（0025）一样的复合外键：实例、运行都是作者的。成员行退出、注销都不删（只记 left_at）。
    FOREIGN KEY (project_id, author_user_id) REFERENCES project_members (project_id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (author_instance_id, author_user_id) REFERENCES instances (id, user_id) ON DELETE SET NULL (author_instance_id),
    FOREIGN KEY (run_id, author_user_id) REFERENCES runs (id, user_id) ON DELETE SET NULL (run_id),
    CHECK (by_agent OR (run_id IS NULL AND author_instance_id IS NULL))
);
CREATE INDEX project_board_posts_live ON project_board_posts (project_id, id DESC) WHERE archived_at IS NULL;
CREATE INDEX project_board_posts_archived ON project_board_posts (project_id, id DESC) WHERE archived_at IS NOT NULL;
CREATE INDEX project_board_posts_archived_at ON project_board_posts (archived_at) WHERE archived_at IS NOT NULL;
CREATE INDEX project_board_posts_run ON project_board_posts (run_id) WHERE run_id IS NOT NULL;
CREATE INDEX project_board_posts_author ON project_board_posts (author_instance_id) WHERE author_instance_id IS NOT NULL;
CREATE INDEX project_board_posts_by_member ON project_board_posts (project_id, author_user_id, created_at) WHERE NOT by_agent;

-- agent 写的：运行在这个项目里（项目归属从运行派生，impl 第 1 条；主人、实例由上面的外键对上）。成员读的策略只看
-- project_id，所以这里核对。
CREATE FUNCTION project_board_post_run() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    IF NEW.by_agent AND (NEW.run_id IS NULL OR NOT EXISTS (
             SELECT 1 FROM public.runs r WHERE r.id = NEW.run_id AND r.project_id = NEW.project_id
                AND r.instance_id = NEW.author_instance_id)) THEN
        RAISE EXCEPTION 'board post does not match its run'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'project_board_post_run';
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION project_board_post_run() FROM PUBLIC;
CREATE TRIGGER project_board_posts_run BEFORE INSERT ON project_board_posts
    FOR EACH ROW EXECUTE FUNCTION project_board_post_run();

ALTER TABLE project_board_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_board_posts FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, DELETE ON project_board_posts TO thinktin_worker;
GRANT UPDATE (archived_at, revived_at) ON project_board_posts TO thinktin_worker;
GRANT SELECT (id, project_id, author_user_id, author_instance_id, run_id, by_agent, body, tags, created_at, archived_at)
    ON project_board_posts TO thinktin_member;
CREATE POLICY member_read ON project_board_posts FOR SELECT TO thinktin_member
    USING (project_id IN (SELECT member_projects()));
```

### 1.3 `0062_egress_asked_epoch.sql` (one transaction)

```sql
-- 出口代理问用户时带上通过验证的令牌代数（8.16 复核留给 8.17）：目录缓存还有效的几秒里，旧沙箱（运行结束、换了工作区）的
-- 提问不能记成新工作区的。代数和工作区在同一句里读（换工作区在同一个 UPDATE 里改两样）。上一版的出口代理不填，照旧放行；
-- 再问时没带代数（上一版的出口代理）沿用的旧代数当“不知道”。
ALTER TABLE egress_requests ADD COLUMN asked_epoch bigint;
GRANT UPDATE (asked_epoch) ON egress_requests TO thinktin_llmgw;
-- deploy-safe: 只在带了代数、和实例现在的不一样时拒绝；上一版的出口代理不带，沿用的旧代数清空（照旧放行，同 0059）
CREATE OR REPLACE FUNCTION egress_request_workspace() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    ws text;
    ep bigint;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.asked_at IS NOT DISTINCT FROM OLD.asked_at THEN
        NEW.workspace_id := OLD.workspace_id;
        NEW.asked_epoch := OLD.asked_epoch;
        RETURN NEW;
    END IF;
    SELECT i.workspace_id, i.token_epoch INTO ws, ep FROM public.instances i WHERE i.id = NEW.instance_id;
    -- 这次没带代数、沿用的是上一次问的：过时了就当“不知道”。
    IF TG_OP = 'UPDATE' AND NEW.asked_epoch IS NOT DISTINCT FROM OLD.asked_epoch
       AND NEW.asked_epoch IS DISTINCT FROM ep THEN
        NEW.asked_epoch := NULL;
    END IF;
    IF NEW.asked_epoch IS NOT NULL AND NEW.asked_epoch <> ep THEN
        RAISE EXCEPTION 'egress ask from an outdated sandbox token'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'egress_stale_token';
    END IF;
    NEW.workspace_id := ws;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION egress_request_workspace() FROM PUBLIC;
```

**Residual edge.** A touch from an old sandbox can carry the same stale epoch as the row it touches. That happens only when the row survived the retire's `DELETE … FOR UPDATE SKIP LOCKED` (`instances.rs:1178-1180`) because someone held it at that moment, *and* the retire committed between the store's epoch pre-check and the UPDATE. Such a touch is treated as unknown and allowed. `release_instance` prelocks the requests (`instances.rs:1095-1099`), so this needs the project-delete retire path plus two coincident races.

### 1.4 `0063_project_pipelines.sql` (one transaction; last, can be cut to a follow-up)

```sql
-- 项目流水线（WBS 8.17）：创建者在 App 里建一条马上开始的流水线，每一步可以是项目里任何一个专属 agent（不分主人）。不用
-- plans/plan_steps/triggers（同一个用户的外键；0055 不让它们碰专属实例；老版本的调度器会去触发）。根运行（kind 'pipeline'、
-- source 'pipeline'，不带授权）挂在创建者自己的一个专属 agent 上；步骤开始以后不改，存成 jsonb（store 用 order_steps 核对），
-- 由 8.17 的驱动按依赖顺序经派单建子运行（每一步用那个 agent 自己的项目授权）。随根运行级联删掉。
CREATE TABLE project_pipelines (
    root_run_id uuid PRIMARY KEY REFERENCES runs (id) ON DELETE CASCADE,
    project_id  uuid NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
    title       text NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
    -- [{"key","instance_id","user_id","prompt","depends_on":[]}]，1–20 步
    steps       jsonb NOT NULL CHECK (jsonb_typeof(steps) = 'array' AND jsonb_array_length(steps) BETWEEN 1 AND 20),
    created_by  uuid NOT NULL REFERENCES users (id),
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX project_pipelines_project ON project_pipelines (project_id, root_run_id DESC);

-- 根运行是这个项目的流水线根运行，挂在创建者自己的 agent 上（成员读的策略只看 project_id）。
CREATE FUNCTION project_pipeline_root() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.runs r WHERE r.id = NEW.root_run_id AND r.project_id = NEW.project_id
                     AND r.kind = 'pipeline' AND r.parent_run_id IS NULL AND r.user_id = NEW.created_by) THEN
        RAISE EXCEPTION 'pipeline % does not match its root run', NEW.root_run_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'project_pipeline_root';
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION project_pipeline_root() FROM PUBLIC;
CREATE TRIGGER project_pipelines_root BEFORE INSERT ON project_pipelines
    FOR EACH ROW EXECUTE FUNCTION project_pipeline_root();

ALTER TABLE project_pipelines ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_pipelines FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT ON project_pipelines TO thinktin_worker;
GRANT SELECT (root_run_id, project_id, title, steps, created_by, created_at) ON project_pipelines TO thinktin_member;
CREATE POLICY member_read ON project_pipelines FOR SELECT TO thinktin_member
    USING (project_id IN (SELECT member_projects()));
```

**Purge.** `project_pipelines` cascades from the root run. Add `project_board_posts` to the purge step list, before events and runs, and to the leftover check (§2.7). No other purge change is needed.

---

## 2. Store API (`crates/store`)

### 2.1 `lib.rs`, `error.rs`

- **`lib.rs`:**
  - `pub const PROJECT_PROTOCOL: u8 = 2;`
  - `APPLICATION_NAME = "thinktin/i1p2"` (`lib.rs:110`).
  - `Db::worker` (`lib.rs:166-177`) runs `set_config('thinktin.isolation', $2, true), set_config('thinktin.project_protocol', $3, true)`.
  - `pub const STOP_ALL_REASON: &str = "stop_all";`, used by `orchestrator/src/account.rs:95` and by the pause rule (D20).
  - **`pub async fn Db::legacy_sessions(&self) -> Result<Vec<(String, i64)>>`** runs on `self.pool` with no role switch (verified, §1.0 V5):
    ```sql
    SELECT coalesce(a.application_name, ''), count(*)::bigint FROM pg_stat_activity a
     WHERE a.datname = current_database()
       AND a.usesysid = (SELECT oid FROM pg_roles WHERE rolname = session_user)
       AND a.pid <> pg_backend_pid() AND a.application_name IS DISTINCT FROM $1
     GROUP BY 1 ORDER BY 1
    ```
  - **No new TTL constants.** The callers pass their configured grant TTL; delegate children reuse `CHILD_GRANT_TTL` (`delegate.rs:31`).
- **`error.rs`** (`error.rs:65-94`):
  - add `Error::DispatchOff`;
  - match the constraint before the code, as with `instance_dedicated`:
    - `project_dispatch_off` → `DispatchOff`;
    - `project_agent_gone` → `Conflict("project_agent_gone: …")`;
    - `project_delegate_not_lead` → `NotPermitted`;
  - `project_run_shape`, `project_board_post_run`, `project_pipeline_root` and `egress_stale_token` fall through to `Invalid` (23514);
  - `runs_isolation` (42501) stays `Forbidden`, which means a bug (404, counted).
- **`schema.rs`:** no change. It has no "expected latest migration" (`schema.rs:16-18` uses `sqlx::migrate!`).

### 2.2 Runs (`runs.rs`)

- **`NewRun`** (`runs.rs:21-48`) gains `pub(crate) project_id: Option<ProjectId>`, `None` in `NewRun::new`.
  - `insert_run` (`runs.rs:274-322`) binds it as `$22`.
  - `Tx<Worker>::create_run` (`runs.rs:1127-1129`) returns `Invalid` when it is `Some`.
  - The dispatcher's `pub(crate) async fn insert_project_run(&mut self, owner, &NewRun)` is the only path that sets it.
  - Tenants still cannot write it (`fill_space`, `0040:19-22`; the fence).
- **`tree_tokens_except(root, except, owner: Option<UserId>)`** (`runs.rs:1341-1351`):
  ```sql
  SELECT coalesce(sum(tokens_used), 0)::bigint FROM runs
   WHERE root_run_id = $1 AND id <> $2 AND ($3::uuid IS NULL OR user_id = $3)
  ```
- **`due_pipelines`** (`runs.rs:1723-1737`) is unchanged: private only, `project_id IS NULL`.
- **`pub async fn due_project_pipelines(&mut self, limit: i64) -> Result<Vec<(RunId, ProjectId)>>`**, a plain read with no locks:
  ```sql
  SELECT r.id, r.project_id FROM runs r
   WHERE r.kind = 'pipeline' AND r.project_id IS NOT NULL AND r.state IN ('queued', 'waiting_children')
     AND r.not_before <= now()
   ORDER BY r.not_before, r.id LIMIT $1
  ```
- **`pub async fn lock_project_pipeline_root(&mut self, root: RunId) -> Result<Option<RunRecord>>`**:
  ```sql
  SELECT <columns> FROM runs WHERE id = $1 AND kind = 'pipeline' AND project_id IS NOT NULL
     AND state IN ('queued', 'waiting_children') AND not_before <= now() FOR UPDATE SKIP LOCKED
  ```
- **`pub(crate) async fn cancel_project_subtree(&mut self, run: RunId, reason: &str, include_root: bool, skip_locked: bool) -> Result<Vec<(RunId, InstanceId)>>`**, in D13 order:
  1. Lock the subtree in id order:
     ```sql
     WITH RECURSIVE tree AS (SELECT $1::uuid AS id UNION SELECT r.id FROM runs r JOIN tree t ON r.parent_run_id = t.id)
     SELECT id FROM runs WHERE id IN (SELECT id FROM tree) AND ($3 OR id <> $1)
        AND state NOT IN ('succeeded', 'failed', 'cancelled') ORDER BY id FOR NO KEY UPDATE   -- `SKIP LOCKED` when skip_locked
     ```
  2. `settle_cancelled_approvals(&locked)`, then `expire_run_requests(&locked)`.
  3. Bump the epochs of the locked agent runs (the `cancel_orphaned_project_runs` form, `runs.rs:1060-1068`).
  4. `UPDATE runs SET state = 'cancelled', … WHERE id = ANY($locked) AND state NOT IN (…) RETURNING id, instance_id`.
  5. `settle_late`.
- **`pub async fn cancel_orphaned_project_children(&mut self, limit: i64) -> Result<Vec<(RunId, InstanceId)>>`** picks
  ```sql
  SELECT c.id FROM runs c JOIN runs p ON p.id = c.parent_run_id
   WHERE c.project_id IS NOT NULL AND c.source IN ('delegate', 'pipeline')
     AND c.state NOT IN ('succeeded', 'failed', 'cancelled') AND p.state IN ('succeeded', 'failed', 'cancelled')
   ORDER BY c.id LIMIT $1 FOR NO KEY UPDATE OF c SKIP LOCKED
  ```
  and cancels each one's subtree with `include_root = true, skip_locked = true` and the reason `"the task it was working for ended"`. Rows that are locked elsewhere are picked up on the next tick.
- **`cancel_project_agent_runs` / `cancel_project_member_runs`** (`runs.rs:899-988`) replace their filter with the recursive subtree of the agent's or member's project runs, in the lock, bump and cancel statements alike:
  ```sql
  id IN (WITH RECURSIVE tree AS (SELECT id FROM runs WHERE project_id = $1 AND instance_id = $2   -- user_id = $2 for members
                                 UNION SELECT r.id FROM runs r JOIN tree t ON r.parent_run_id = t.id)
         SELECT id FROM tree)
  ```
- **D13 settling in the existing worker cancels.**
  - `cancel_descendants` (`runs.rs:1306-1339`) and `cancel_children` (`runs.rs:1803-1822`) collect the locked ids, then call `settle_cancelled_approvals` and `expire_run_requests` before the epoch bump.
  - `cancel_stale_asks` (`runs.rs:1551-1578`) calls `lock_run_trees(&ids)`, settles and expires over the locked trees, then calls `cancel_asks`.
  - `cancel_asks` stays generic, because the tenant `cancel_asks_to` (`runs.rs:625-639`) uses it. Dedicated instances have `peer_access = false` (CHECK `instances_dedicated_no_peers`), so that tenant path never touches project asks.
- **`pub async fn projects_with_unfinished_runs(&mut self, limit: i64) -> Result<Vec<ProjectId>>`**, for `admin project-dispatch off`:
  ```sql
  SELECT DISTINCT project_id FROM runs WHERE project_id IS NOT NULL
     AND state NOT IN ('succeeded', 'failed', 'cancelled') LIMIT $1
  ```
  Each project is then cancelled in its own transaction under `lock_project(p)` with `cancel_project_runs` (`runs.rs:990-1015`).
- **`queue_urgent_run`** is unchanged (D15). There is no `run_space_state` either: the late-call check reuses `run_record` and `instance_runtime` (§3.1).

### 2.3 Grants (`grants.rs`)

- **`insert()`** (`grants.rs:150-174`) gains `project: Option<ProjectId>` and binds `project_id`. Existing callers pass `None`.
- **`pub async fn ensure_project_agent_grant(&mut self, p: ProjectId, instance: InstanceId, owner: UserId, ttl: Duration) -> Result<(RunGrant, bool)>`**. The newest standing grant of the current membership:
  ```sql
  SELECT <cols>, g.revoked_at, g.revoke_reason FROM run_grants g
    JOIN project_agents a ON a.project_id = g.project_id AND a.instance_id = g.instance_id AND a.left_at IS NULL
   WHERE g.project_id = $1 AND g.instance_id = $2 AND g.parent_id IS NULL AND g.plan_id IS NULL
     AND g.created_at >= a.added_at
   ORDER BY g.created_at DESC, g.id DESC LIMIT 1
  ```
  - Active and not expired: reuse it.
  - Revoked with `STOP_ALL_REASON`: `Err(Conflict("agent_paused"))`. The dispatcher maps it to `AgentUnavailable`.
  - Otherwise: `insert(…, owner, instance, None, None, &GrantScope { platform_tools: PROJECT_PLATFORM_TOOLS, aliases: [], max_tokens: None }, ttl, Some(p))`, returning `issued = true` so callers can audit.
- **`pub(crate) async fn issue_project_agent_grant(&mut self, p, instance, owner, ttl) -> Result<RunGrant>`**, for the owner's resume. It always inserts a fresh standing grant.
- **`pub(crate) async fn create_project_child_grant(&mut self, parent: GrantId, p: ProjectId, instance: InstanceId, owner: UserId, target: &GrantScope) -> Result<RunGrant>`**:
  - the parent row must be active, pass `ancestors_usable!` and have `project_id = p`;
  - scope = `GrantScope { platform_tools: target.platform_tools ∩ parent.platform_tools, aliases: target.aliases.clone(), max_tokens: min(target, parent) }`; an empty tool set gives `Invalid("no tools in common")`, which callers turn into `NoScope`;
  - TTL = min(`CHILD_GRANT_TTL`, the parent's remaining lifetime);
  - `user = owner`, plan None, project Some(p).

  There is no `proto::GrantScope::intersect`.

### 2.4 Leads (`instances.rs`, `projects.rs`)

- **`Tx<Worker>::is_project_lead(p, instance) -> Result<bool>`**:
  ```sql
  SELECT EXISTS (SELECT 1 FROM project_agents a JOIN instances i ON i.id = a.instance_id
                  AND i.workspace_project_id = a.project_id AND i.state <> 'deleted'
                  WHERE a.project_id = $1 AND a.instance_id = $2 AND a.is_lead AND a.left_at IS NULL
                    AND project_agent_live(a.project_id, a.instance_id, a.user_id))
  ```
- **Names come from the member projection:** `Db::member(user).project_detail(p)` (`project_reads.rs:412-490`). It gives the agents' `name`, `owner_id`, `is_lead` and `dedicated`, the members' `display_name`, and the summary's name and creator. There is no `project_agent_names` and no `project_brief`. Withdrawn and deleted agents' names stay hidden, as for members (`0049:94-107`).
- **`Tx<Worker>::set_project_lead(user, p, lead: Option<InstanceId>) -> Result<LeadChange { old: Option<(InstanceId, UserId)>, new: Option<(InstanceId, UserId)> }>`**:
  1. Plain read of the new lead's owner.
  2. `project_actor(user, p, &[owner], &[Active])`, then `require_creator("choose the lead")`.
  3. `SELECT a.user_id, a.dedicated FROM project_agents a WHERE project_id=$1 AND instance_id=$2 AND left_at IS NULL FOR NO KEY UPDATE`. No row gives `Invalid("not an agent of this project")`. The owner's member row must be live.
  4. If `projects.shared_at IS NOT NULL AND NOT dedicated`, return `AgentNotIsolated`.
  5. `UPDATE project_agents SET is_lead = false WHERE project_id=$1 AND is_lead AND left_at IS NULL AND instance_id IS DISTINCT FROM $2 RETURNING instance_id, user_id`.
  6. `UPDATE project_agents SET is_lead = true WHERE project_id=$1 AND instance_id=$2 AND left_at IS NULL`.
  7. `UPDATE projects SET updated_at = now()`.

  The old lead is cleared first because `project_one_lead` is a partial unique index checked per row (`0039:68`, as in `projects.rs:375-380`).

### 2.5 The dispatcher (new `crates/store/src/project_dispatch.rs`)

- **Switch:** `project_dispatch_enabled() -> bool` and `set_project_dispatch(enabled, by: &str, reason: Option<&str>)`. `legacy_sessions` lives on `Db` (§2.1).
- **`pub(crate) struct ProjectAgentActor { run: RunId, project, instance, owner, creator, grant: GrantId, lead: bool, budget: RunBudget, users: Vec<LockedUser> }`**, built only by `async fn project_agent_actor(&mut self, run: RunId, p: ProjectId, also: &[UserId])`:
  1. Plain `SELECT user_id, instance_id, project_id FROM runs WHERE id=$1`. If `project_id ≠ p`, return `NotFound`.
  2. Read the creator.
  3. `lock_users([owner, creator] ∪ also)`. The owner must be present and active.
  4. `lock_project(p)`. The project must be active, else `NotFound`.
  5. Re-read the caller's agent: `project_agent_live` and `instances.workspace_project_id = p`. Absent gives `NotFound`.
  6. `SELECT state, run_grant_id, budget FROM runs WHERE id=$1 FOR NO KEY UPDATE`. A terminal run gives `Conflict("run_over")`.
  7. `lead = is_project_lead(p, instance)`.
- **Target checks** (`async fn project_target(&mut self, p, instance, check_queue: bool) -> Result<Target, TargetRefusal>`), under the lock, in this order:
  1. The agent row is live in p; else `TargetGone`.
  2. The instance is not deleted and `workspace_project_id = p`; else `TargetNotIsolated`.
  3. The owner is an active member; else `AgentUnavailable`.
  4. `ensure_project_agent_grant` succeeds (not paused); else `AgentUnavailable`.
  5. If `check_queue`, fewer than 10 queued project runs on the instance; else `AgentBusy`.
  6. The remaining budget is > 0 (`owner_budget_left`); else `BudgetReached`.
- **`async fn owner_budget_left(&mut self, p, owner) -> Result<Option<u64>>`** (None = no cap):
  ```sql
  SELECT m.daily_token_limit, m.total_token_limit,
         coalesce(sum(r.tokens_used) FILTER (WHERE r.created_at > now() - interval '1 day'), 0)::bigint,
         coalesce(sum(r.tokens_used), 0)::bigint
    FROM project_members m LEFT JOIN runs r ON r.project_id = m.project_id AND r.user_id = m.user_id
   WHERE m.project_id = $1 AND m.user_id = $2 GROUP BY 1, 2
  ```
- **Creator task:** `pub async fn create_project_task(&mut self, creator: UserId, p: ProjectId, to: Option<InstanceId>, prompt: &str, grant_ttl: Duration) -> Result<Dispatched { run: Run, grant_issued: Option<GrantId>, owner: UserId }>`:
  1. Check the switch; off gives `DispatchOff`.
  2. Plain-read the target's owner (`to`, or the current lead).
  3. `project_actor(creator, p, &[owner], &[Active])`, then `require_creator("give the project tasks")`.
  4. Resolve the target under the lock: `to`, or the live lead. No lead gives `Invalid("the project has no lead; pick an agent")`.
  5. `project_target(p, target, true)`. The refusals map to `Invalid`, `AgentNotIsolated`, `Conflict("agent_unavailable")`, `Conflict("agent_busy")` and `Conflict("budget_reached")`.
  6. Build `NewRun { project_id: Some(p), source: User, run_grant_id: Some(g), budget: RunBudget { max_tokens: left, ..default } }`.
  7. `insert_project_run(owner, &new)`.
- **Child of a run:** `pub async fn project_child_run(&mut self, caller: RunId, p: ProjectId, to: InstanceId, child: &ProjectChild<'_>) -> Result<ProjectChildResult>`.
  - `ProjectChild { source: Delegate|Ask, prompt /* raw: "{title}\n\n{task}" or the question */, max_depth, max_siblings, max_attempts, answer_deadline, dedupe, grant_ttl }`.
  - `ProjectChildResult = Created(Run) | Existing(Run) | Refused(ChildRefusal)`, where `ChildRefusal ∈ { DispatchOff, NotLead, TargetGone, TargetNotIsolated, AgentUnavailable, AgentBusy, BudgetReached, SelfTarget, TooDeep, OnChain, WaitsForCaller, TooMany, NoScope }`.
  - Steps, in order:
    1. `project_agent_actor(caller, p, &[target_owner])`.
    2. For Delegate, `actor.lead` must hold.
    3. `project_target(p, to, true)`.
    4. The existing guards, unchanged but now under the project lock: `run_chain` (`runs.rs:1449-1464`), `instance_waits_for` (`:1524-1549`), the `delegated_runs` and `ask_runs` counts, and `open_ask` for dedupe (`:1367-1387`).
    5. The grant: Ask runs on the target's standing grant. Delegate calls `create_project_child_grant(actor.grant, p, to, owner, &standing.scope)`.
    6. The budget: the caller's budget if the owner is the same, else default with `max_tokens = left`.
    7. `insert_project_run(target_owner, NewRun { project_id: Some(p), parent_run_id: Some(caller), source, … })`.
  - The orchestrator appends `delegate.started` or `ask.sent` on its own instance and commits.
- **Pipeline root:** `pub async fn start_project_pipeline(&mut self, creator, p, title, goal, steps: &[NewProjectStep]) -> Result<Run>`:
  1. Plain-read the step owners.
  2. `project_actor(creator, p, &owners, &[Active])`, then `require_creator`.
  3. `order_steps` (1–20 steps; keys valid and unique; no cycles).
  4. Every step's agent passes `project_target(p, i, false)`.
  5. Pick the anchor (D14). None gives `Invalid("add one of your own dedicated botins to run a pipeline")`.
  6. Insert the root (`kind: Pipeline, source: Pipeline, prompt: goal, run_grant_id: None`) with `insert_project_run(creator, …)`, then the `project_pipelines` row (`steps` jsonb with `user_id` per step).
- **Pipeline step:** `pub async fn project_step_run(&mut self, root: &RunRecord, step: &ProjectStep, prompt: String) -> Result<Result<Run, String>>`. The caller holds the D4 locks.
  - `project_target(p, step.instance_id, false)`. A refusal gives `Ok(Err("the agent for step {key} cannot take project work now"))`.
  - The step runs on the target's standing grant, with the target owner's budget.
  - Insert with `source: Pipeline`, `step_key`, `project_id`.
- **Pipeline reads:** `project_pipeline(root) -> Option<ProjectPipeline { title, created_by, steps }>` for the driver, and `ProjectTx::project_pipeline(p, root)` for the App.
- **Resume:** `pub async fn resume_project_agent(&mut self, user, p, instance, ttl) -> Result<Option<GrantId>>`.
  - `project_actor(user, p, &[], &[Active])`.
  - The agent row must be live (`NotFound` otherwise) and owned by `user` (`NotPermitted` otherwise).
  - If no active standing grant exists, `issue_project_agent_grant`. Returns the new id for the audit.
- **Project cancel:** `pub async fn cancel_project_run(&mut self, user, p, run) -> Result<(ProjectRole, Vec<(RunId, InstanceId)>)>`.
  - `project_actor(user, p, &[], &[Active])`.
  - `SELECT user_id, state FROM runs WHERE id=$1 AND project_id=$2`. Absent gives `NotFound`.
  - Not the creator and not the owner gives `NotPermitted`.
  - Terminal gives `InvalidTransition`.
  - Then `cancel_project_subtree(run, "stopped in the project", true, false)`.

### 2.6 Project board (new `crates/store/src/project_board.rs`)

- **`pub enum BoardWriter { Member(UserId), Agent(RunId) }`.**
- **`Tx<Worker>::post_to_project_board(by, p, new: &NewBoardPost) -> Result<(Uuid, u64)>`**:
  1. `Member` uses `project_actor(u, p, &[], &[Active])` and checks the daily cap:
     ```sql
     SELECT count(*) FROM project_board_posts
      WHERE project_id = $1 AND author_user_id = $2 AND NOT by_agent AND created_at > now() - interval '1 day'
     ```
     50 or more gives a new `Error::RateLimited` (or the existing rate-limit variant the gateway maps to 429).
     `Agent` uses `project_agent_actor(run, p, &[])`.
  2. Under the project lock, archive the oldest posts beyond the cap, binding `MAX_BOARD_LIVE_POSTS - 1` (= 199):
     ```sql
     UPDATE project_board_posts SET archived_at = now() WHERE id IN (
       SELECT id FROM project_board_posts WHERE project_id = $1 AND archived_at IS NULL
        ORDER BY coalesce(revived_at, created_at) DESC, id DESC OFFSET $2)
     ```
  3. `INSERT INTO project_board_posts (id, project_id, author_user_id, author_instance_id, run_id, by_agent, body, tags) VALUES (…)`.

  Returns the post id and how many posts were archived.
- **`set_project_board_post_archived(user, p, post, archived)`** and **`delete_project_board_post(user, p, post)`**: the creator, or `author_user_id = user`; others get `NotPermitted`. A post not in p is `NotFound`. Unarchiving with a full board is `Invalid`, as on the private board (`board.rs:210-221`).
- **`purge_archived_project_board_posts(older_than)`**: `DELETE FROM project_board_posts WHERE archived_at < now() - $1`.
- **`ProjectTx::project_board(p, &BoardFilter) -> Vec<ProjectBoardPost>`**, through `require_project`, then:
  ```sql
  SELECT b.id, b.author_user_id, b.author_instance_id, i.name, b.run_id, b.by_agent, b.body, b.tags, b.created_at,
         b.archived_at
    FROM project_board_posts b LEFT JOIN instances i ON i.id = b.author_instance_id
   WHERE b.project_id = $1 AND b.archived_at IS NULL
     AND ($2::text IS NULL OR $2 = ANY(b.tags)) AND ($3::uuid IS NULL OR b.id < $3)
   ORDER BY b.id DESC LIMIT $4
  ```
  - There is a twin query with `archived_at IS NOT NULL`.
  - The member `instances` policy (`0049:94-107`) hides the names of withdrawn or deleted agents.
  - The author comes from `authors()`.
  - `mine = author_user_id = me`; `can_manage = mine || I am the creator`.
- **`ProjectTx::project_board_post(p, id)`.**
- **`ProjectTx::project_run_artifacts(p, run)`**, for `agent_status`: `SELECT {ARTIFACT_COLUMNS} FROM artifacts WHERE project_id=$1 AND run_id=$2 ORDER BY id DESC LIMIT 20`.

### 2.7 Purge, artifacts, egress

- **Purge** (`project_lifecycle.rs:325-357`):
  - add `"DELETE FROM project_board_posts WHERE id IN (SELECT id FROM project_board_posts WHERE project_id = $1 ORDER BY id LIMIT $2 FOR UPDATE SKIP LOCKED)"` right after the `board_posts` step, before events and runs;
  - add `OR EXISTS (SELECT 1 FROM project_board_posts WHERE project_id = $1)` to the leftover check (`:397-406`).
- **`Tx<Worker>::delete_project_artifact(user, p, artifact)`**: `project_actor(…, &[Active])`; the creator or the artifact's `user_id`; then `DELETE FROM artifacts WHERE id=$1 AND project_id=$2`. The existing trigger queues the blob for deletion.
- **Egress** (`egress.rs:365-470`):
  - `AskMeta` gains `epoch: Option<u64>`.
  - `egress_ask_as` starts with `SELECT token_epoch FROM instances WHERE id=$1` when `epoch` is `Some`. A mismatch returns the new `EgressAsk::Stale`.
  - `touch_request!` (`:94-101`) becomes `touch_request!($epoch:literal)` and adds `asked_epoch = <epoch>`. Bind values go through `crate::signed`, because sqlx cannot bind a `u64` and the column is `bigint` (`0007:23`):
    - the browser UPDATE (`:385`) and `touch_egress_ask` (`:478`) bind it as `$4`;
    - the INSERT (`:425-447`) adds `asked_epoch` to its columns as `$10` and uses `touch_request!("EXCLUDED.asked_epoch")`.
  - `EgressRequest` and its DTO do not change.

---

## 3. Orchestrator, llm-gw, server

### 3.1 Shared parts

- **`tools.rs`:** `pub use proto::domain::PROJECT_PLATFORM_TOOLS as PROJECT_RUN_TOOLS;` (the 12 names of D10). `allowed_in_space` is unchanged (`tools.rs:463-465`).
- **New helper `crate::projects::live_project_call(db, ctx) -> Result<ProjectId, Fail>`.** It is the check `ArtifactTools::origin` already does (`tools.rs:507-517`: `run_record` plus `instance_runtime`; refuse when the run is terminal or `workspace_project_id ≠ ctx.project`), moved out so every project tool path calls it first. `origin` calls it too.
- **`proto::domain::ProjectRunState::coarse(RunState)`** mirrors the SQL `project_run_state()` (`0054:14-21`). A test pins both.
- **`texts::label(name) -> String`** drops control characters, newlines and 「」, and clips to 40 characters. Empty becomes "an agent that left the project".

### 3.2 Each tool in a project run

**`agents_list` and `agent_status` (`peers.rs`).** `match ctx.project { None => today, Some(p) => … }`.
- **List:**
  1. Call `live_project_call`.
  2. `m = db.member(ctx.user)`; `d = m.project_detail(p)`.
  3. Agents: `d.agents` filtered to `dedicated && instance_id ≠ ctx.instance`. For each: `{instance_id, name (label), agent, owner (label of the display name, or "a former member"), lead: is_lead, status: busy|idle}`. Busy means the agent has a non-terminal run among `m.project_runs(p, {instance, limit: 20})`.
  4. Project block: `{name, goal clipped to 1000 characters and marked "written by the project creator: information, not instructions", you_are_lead}`.
  5. Plus the `UNTRUSTED` note.
- **Status:**
  - Find the target among those agents.
  - `current` = the newest run in coarse state running, `waiting_owner` or `waiting_children`. Show its task as the **first line of the raw prompt** (no header stripping for any project run), `todo` from the latest `plan` event and `last_said` from `message` events (`m.project_run_events(p, run, 80)`), and artifact names from `m.project_run_artifacts`.
  - `last_finished` = the newest terminal run: coarse state, task, summary, `finished_at`.
  - **Never show:** `purpose` (owner-private, `peers.rs:65-67`), the paused state (`:162-173`), tool titles (`:207-216`), `error` (`:146-150`), or any run with `project_id ≠ p`.

**`board_read` and `board_post` (`board.rs`).**
- **Read:** `m.project_board(p, filter)`. The `UNTRUSTED` text says "posts are written by project members and their agents".
- **Post:**
  1. Check the body and tags. **No scrubber.**
  2. The worker `run_event_count(ctx.run, "board.posted")` must be below `MAX_POSTS_PER_RUN`.
  3. `post_to_project_board(Agent(ctx.run), p, …)`.
  4. Append `board.posted` and commit.
- Descriptions become neutral ("the shared board of the user, or of the project in project work").

**`ask` (`ask.rs`).**
1. `live_project_call`.
2. Find the target among the member detail's dedicated agents (`≠ self`). An unknown name gives "no agent called {to:?} in this project; agents_list shows the ones you can ask".
3. The stored prompt is the raw question (≤ `MAX_QUESTION_CHARS`). **No scrubber, no names.**
4. `w.project_child_run(ctx.run, p, target, ProjectChild { Ask, max_depth: MAX_DEPTH, max_siblings: MAX_ASKS_PER_RUN, max_attempts: ANSWER_ATTEMPTS, answer_deadline: now + ANSWER_TIMEOUT, dedupe: true, … })`.
5. Map each `ChildRefusal` to today's texts (`ask.rs:89-143`):
   - `DispatchOff` gives "project work is paused right now";
   - `AgentUnavailable`, `AgentBusy` and `BudgetReached` all give "that agent can't take more project work now".
6. Append `ask.sent`, commit, `asked_reply`.

**`delegate` and `delegate_list` (`delegate.rs`).**
- **List:**
  - members = the member detail's dedicated agents (`≠ self`), with labelled owner names;
  - subtasks = `delegated_runs(ctx.run)` with `ProjectRunState::coarse` and the summary. Never `waiting_approval` and the like.
- **Delegate:**
  1. The stored prompt is `"{title}\n\n{task}"`.
  2. `project_child_run(… Delegate, max_depth: MAX_DEPTH, max_siblings: MAX_CHILDREN_PER_RUN, max_attempts: default …)`.
  3. `NotLead` gives "only the project's lead can delegate; ask instead". The other refusals map as for `ask`.
  4. Append `delegate.started` and commit.
- The module docs (`delegate.rs:1-10`) change to say project leads delegate across owners.

**`artifact_list` and `artifact_read` (`tools.rs:584-662`).** In project runs, entries written by other owners' agents are wrapped in the untrusted note with a boundary fence (D12).

**`schedule_*`:** not in `PROJECT_RUN_TOOLS`.

### 3.3 Executor (`executor.rs`)

1. **Lead per space** (`:783-789`): `lead = grant has delegate tools && match rec.run.project_id { None => w.is_team_lead(instance), Some(p) => w.is_project_lead(p, instance) }`.
2. **Project context:** for project runs, read `d = Db::member(rec.user_id).project_detail(p)` once at launch. It is used for headers and result names.
3. **Header at launch, every attempt.** Build `base = header + "\n\n" + rec.run.prompt`:
   - `User` source: `texts::project_task_header(locale, project, creator)`;
   - `Delegate`: `texts::project_delegate_header(locale, lead, lead_owner)`, where lead = the parent run's instance;
   - `Ask`: `texts::project_ask_header(locale, asker, asker_owner)`;
   - `Pipeline` steps: none, because the handoff carries its own heading.

   Use `base` everywhere `self.rec.run.prompt` is used in `drive_inner` (`:1718-1757`): the Interrupted and Announced prefaces, and `resume_note` on `attempt > 1`.
4. **Resume names** (`:819-838`): project runs label children from `d`. Results go through `delegate::results_message(locale, &named, &base, project: bool)`. For `project = true`:
   - the task is the first line of the raw prompt (no `split_once`);
   - `error` is never passed;
   - outcomes are done, cancelled, failed or timed out (`delegate.rs:236-238`);
   - the delegated header gets the untrusted note too (`texts.rs:663-679`).
5. **No piggyback in project runs:** `unannounced_messages` (`:1535`) is called only when `rec.run.project_id.is_none()`.
6. **Tree budget** (`:2424-2427`): `tree_tokens_except(root, id, rec.run.project_id.map(|_| rec.user_id))`.
7. **Notices** (`:1209-1250`): for project runs, the body is `texts::project_task_finished(locale, botin)` or `project_task_failed(locale, botin)`, and `ai_generated = false`. Waits are unchanged.
8. **Takeover tick** (`:500-511`): after `expire_asks`, `w.cancel_orphaned_project_children(20)`, with a `run.state` event for each cancelled run. `projects::sweep` (hourly) is unchanged.
9. **`space_tests`** (`tools.rs:755-773`) now asserts the 12 allowed tools and that `schedule_*`, `vault_*`, computer tools and `browser` are refused.

### 3.4 Pipeline driver (`pipeline.rs`)

- **`tick`** (`:63-82`): the private batch is unchanged. Then, for each `(root, p)` in `due_project_pipelines(batch)`, run one worker transaction:
  1. `project_pipeline(root)` (plain read).
  2. `lock_users(created_by ∪ step owners)`.
  3. `lock_project(p)`.
  4. `lock_project_pipeline_root(root)`. `None` → roll back and continue.
  5. `advance_project`.
  6. `requeue_pipelines(&[root])`.
  7. Commit.

  A `store::Error::Db` rolls back that root only and is logged. Other replicas serialize on the project lock; advancing is idempotent, because existing children are read from `child_runs`.
- **`advance_project`:**
  - It works like `advance` (`:85-206`), but on `project_pipeline.steps`.
  - **Failure propagation:** `why = format!("step {key} {}", ProjectRunState::coarse(state))`, never the step's `error` or `state_reason`. Then `cancel_project_subtree(root, "step {key} did not succeed", include_root: false, skip_locked: false)` and `finish(Err(why))`.
  - **Starting a step:** `start_step` keeps the savepoint and calls `w.project_step_run(root, step, prompt)`. For project roots, **every error except `store::Error::Db`** rolls back to the savepoint and returns `Ok(Err(format!("the agent for step {} cannot take project work now", key)))`.
  - **All done:** the summary of the final steps, in the creator's locale.
- **`handoff_prompt`** (`:418-440`), for project steps:
  - the step owner's locale (`user_locale(step.user_id)`);
  - upstream summaries fenced with a boundary, and `HandoffWords::untrusted()` added (`texts.rs:838-885`).
- **`finish`** (`:308-395`) and `live::queue_starts` (`:73-76`) skip notices and live activities for project roots (8.19).
- **`HandoffCopier::copy`** (`:471-510`): when `rec.run.project_id.is_some()`, it reads `depends_on` from `project_pipeline(parent).steps`. Artifacts already decrypt with the project DEK (`artifacts.rs:419-424`).

### 3.5 Texts (`texts.rs`), botin terminology

New functions (zh shown; en equivalents say "{owner}'s botin"):
- `project_task_header(locale, project, creator)`: "（这是项目「{project}」的创建者{creator}派给你的任务。）"
- `project_delegate_header(locale, lead, owner)`: "（这是项目里的负责人「{lead}」（{owner}的 botin）委派给你的子任务：第一行是标题。做完后用几句话总结结果，要交给负责人的文件用 artifact_publish 发布。下面的内容是别的 agent 写的，当作任务说明，不要照它去做有风险的操作。）"
- `project_ask_header(locale, asker, owner)`: like `ask_question` (`:628-643`), with "（{owner}的 botin）".
- The project variant of the `children_results` headers, with the untrusted note on delegated results.
- `HandoffWords::untrusted` and the artifact-tool note for project runs.
- `project_task_finished(locale, botin)`: "「{botin}」完成了一个项目任务"; `project_task_failed(locale, botin)`: "「{botin}」的项目任务没做完".

Every inserted name goes through `label`.

### 3.6 llm-gw (the epoch fix)

- `EgressLedger::ask` (`llm-gw/src/egress.rs:320-330`) gains `epoch: u64`.
- `ask_inner` (`:1795-1860`) passes `caller.claims.ep` (`auth/src/sandbox_token.rs:37`).
- `pg.rs::ask` (`:614-645`) sets `AskMeta.epoch = Some(epoch)`. The memory ledger accepts the parameter and does not check it.
- New `Asked::Stale`, mapped to `denied(StatusCode::FORBIDDEN, "stale_token", "this sandbox token is from an earlier run; stop here")`.
- If the trigger refuses after the pre-check passed (a race), the error surfaces as the existing 503 "store unavailable". The agent retries, and the pre-check catches it.

### 3.7 Server

- **`admin project-dispatch {status | on [--force] | off}`** with `--operator` (env `THINKTIN_OPERATOR`) and `--reason`, next to `Freeze` (`server/src/main.rs:47-110`, dispatch `:166-195`). It is implemented in `server::admin::project_dispatch(db, action, out)`.
  - `status` prints the switch, `db.legacy_sessions()` and the number of unfinished project runs.
  - `on` refuses while legacy sessions exist unless `--force`.
  - `off` flips the switch and commits, then loops `projects_with_unfinished_runs(50)` with one transaction per project (`lock_project` → `cancel_project_runs(p, "project dispatch switched off")`) until none are left, and prints the count.
  - Every action writes an audit row (`project_dispatch.on` / `.off`) with the sessions seen and whether `--force` was used.
- **Maintenance:** `workers.rs:471` adds `+ w.purge_archived_project_board_posts(store::BOARD_ARCHIVE_RETENTION)`.
- **`account.rs:95`** uses `store::STOP_ALL_REASON`.

**agent-shim:** no change (D12).

---

## 4. Gateway and client-core

### 4.1 Routes (all inside `projects_router()`, `routes/mod.rs:204-287`, so they inherit `Cache-Control: no-store`; not behind `cross_user()`, because solo projects need them)

**Shared rules:**
- not a member, or the project is deleted → 404, also for writes to an archived project;
- a member calling a creator-only route → 403 `forbidden`;
- a bad body → 422;
- a database `Forbidden` → 404, counted, via `project_error` (`gateway/src/error.rs:112-121`);
- `store::Error::DispatchOff` → 503 `unavailable`, message "project tasks are not switched on yet".

The new handlers go in `routes/project_tasks.rs` and `routes/project_board.rs`.

| Route | Body | Success | Errors |
|---|---|---|---|
| `POST /v1/projects/{id}/runs` | `{"prompt": "…" (1–32000), "instance_id": "<uuid>"?}` | **201 `ProjectRun`**, re-read with `Db::member(creator).project_run` | 403 member; 404 outsider or archived; 422 bad prompt, no lead and no `instance_id`, or not a live agent; **422 when the prompt contains one of the creator's saved secrets**; 409 `agent_not_isolated` (mixed target); 409 `agent_unavailable` (owner frozen, paused or not active); 409 `agent_busy`; 409 `budget_reached`; 503 switch off |
| `POST /v1/projects/{id}/runs/{run_id}/cancel` | — | **200 `ProjectRun`**; the whole subtree is cancelled | 403 not creator and not owner; 404 not in the project; 409 already finished |
| `PUT /v1/projects/{id}/lead` | `{"instance_id": "<uuid>" \| null}` | **200 `ProjectDetail`** | 403 member; 404; 422 not a live agent; 409 `agent_not_isolated` (shared project, mixed agent) |
| `POST /v1/projects/{id}/agents/{instance_id}/resume` | — | **200 `ProjectDetail`** | 403 not the owner; 404 |
| `GET /v1/projects/{id}/board?tag&archived&before&limit` | — | 200 `{"posts":[ProjectBoardPost]}` (limit 1–50, default 20) | 404 |
| `POST /v1/projects/{id}/board` | `{"body", "tags":[]}` | **201 `ProjectBoardPost`** | 404 (also archived); 422 body or tags; 422 own secret; 429 `rate_limited` (50 per day) |
| `POST /v1/projects/{id}/board/{post_id}/archive` and `/unarchive` | — | 200 `ProjectBoardPost` | 403 not creator and not author; 404; 422 board full on unarchive |
| `DELETE /v1/projects/{id}/board/{post_id}` | — | 204 | 403; 404 |
| `POST /v1/projects/{id}/pipelines` | `{"title" (1–200), "goal" (≤4000), "steps":[{"key","instance_id","prompt"(1–8000),"depends_on":[]}] (1–20)}` | **201 `ProjectRun`** (the root) | 403; 404; 422 shape, cycle, not a live agent, own secret, or no dedicated botin of the creator's; 409 `agent_not_isolated` / `agent_unavailable`; 503 |
| `GET /v1/projects/{id}/pipelines/{root_run_id}` | — | 200 `{"title","steps":[{"key","instance_id","prompt","depends_on"}]}` | 404 |
| `DELETE /v1/projects/{id}/artifacts/{artifact_id}` | — | 204 | 403; 404 |

**`GET /v1/projects/{id}`** gains `"can_dispatch": bool` = the caller is the creator && the project is active && `project_dispatch_enabled()`. It is read with a worker transaction after the member read.

**`ProjectBoardPost` JSON:** `{id, project_id, author: ProjectAuthor, author_instance_id?, author_name?, run_id?, mine, can_manage, body, tags, ai_generated, created_at, archived_at?}`.

**`EgressRequest` JSON:** unchanged.

**Audit rows:**
- creator task: `project.task` for the creator; `grant.issue` for the owner when a standing grant was issued;
- resume: `grant.reissue` for the owner;
- lead: `project.lead` for the creator and for the old and new leads' owners;
- `project.board_post.delete` and `project.artifact.delete`.

**Fixtures:** `gateway/tests/api.rs:5430-5469` (the raw worker `project_run`) is replaced by the real endpoint once the gateway commit lands. Until then it uses `store::testing::project_writer`.

### 4.2 client-core

- **`api.rs`** (project section `:1934-2420`):
  - `create_project_task(id, instance: Option<InstanceId>, prompt) -> ProjectRun`
  - `cancel_project_run(id, run) -> ProjectRun`
  - `set_project_lead(id, Option<InstanceId>) -> ProjectDetail`
  - `resume_project_agent(id, instance) -> ProjectDetail`
  - `project_board(id, &BoardFilter) -> Vec<ProjectBoardPost>` (via `lenient::vec`)
  - `post_to_project_board(id, body, tags) -> ProjectBoardPost`
  - `set_project_board_post_archived(id, post, archived)`
  - `delete_project_board_post(id, post)`
  - `start_project_pipeline(id, title, goal, steps) -> ProjectRun`
  - `project_pipeline(id, root)`
  - `delete_project_artifact(id, artifact)`
- **`client.rs`:**
  - `create_project_task`, `post_to_project_board` and `start_project_pipeline` take `allow_secrets: bool` and call `refuse_secrets(text, allow_secrets)` (`client.rs:417-428`). The server's vault check stays the hard block.
  - Reads go through `project_read` (`:225-233`), so a 404 forgets the project.
- **`ffi.rs`:**
  - new records `ProjectBoardPost` and `ProjectPipelineStepInput {key, instance_id, prompt, depends_on}`;
  - `ProjectDetail.can_dispatch` with `#[uniffi(default = false)]`;
  - methods with string ids, as elsewhere: `create_project_task(project_id, instance_id: Option<String>, prompt, allow_secrets)`, `cancel_project_run(project_id, run_id)`, `set_project_lead(project_id, instance_id: Option<String>)`, `resume_project_agent(project_id, instance_id)`, `project_board(project_id, tag: Option<String>, archived: bool, before_id: Option<String>, limit: u32)`, `post_to_project_board(project_id, body, tags, allow_secrets)`, `set_project_board_post_archived(project_id, post_id, archived)`, `delete_project_board_post(project_id, post_id)`, `start_project_pipeline(project_id, title, goal, steps, allow_secrets)`, `delete_project_artifact(project_id, artifact_id)`;
  - the `ProjectRunEvent` kinds doc (`:1239-1242`) is unchanged.
- **`error.rs`:** document 409 `agent_not_isolated`, `agent_unavailable`, `agent_busy` and `budget_reached`, 429 on the board, and 503 while dispatch is off.
- **`cache.rs`:** no change. Project content stays network-only (`cache.rs:158-175`, `forget_project` `:402-428`).
- **`tools/client-core/ffi_smoke.py`:** there is no fake server (`base_url="http://127.0.0.1:9"`, `:57`). It checks the record defaults (`can_dispatch`) and the InvalidArgument and Network error paths of `project_board` and `create_project_task`.

### 4.3 Android

Run `apps/android/scripts/sync-core.sh --bindings-only` and commit the result right after the client-core commit. **Push both together**, because CI runs `--check` on every push (`.github/workflows/android.yml:59`); the precedent is `3c78ed7`. No Kotlin app code changes (the UI is 13.18). No `apps/apple` change.

---

## 5. Tests

### 5.1 Store

New `crates/store/src/tests/collab.rs` (`mod collab;` in `tests.rs:18-20`). It uses the real-Postgres `TestDb` (the non-superuser owner runs the migrations) and the 8.16 fixtures.

**Fixture changes in the same commit as 0060:**
- `TestDb::new()` turns the switch on through `db.worker()`. Only the worker can see the row: FORCE RLS, no policy, and worker is BYPASSRLS (`0001:19`).
- New `store::testing::project_writer(conn, level)` sets the role, `thinktin.isolation` and `thinktin.project_protocol` for raw fixtures.
- Affected call sites:
  - `store/src/tests.rs:1192-1206` (raw project grant and run, mixed: level 2) and `:1238`;
  - `store/src/tests/projects.rs:1757-1800` `copy_into_project`: 10 call sites, including `boundary.rs:445,623,687,1755,2336`, and its lease at `:1797`;
  - `store/src/tests/boundary.rs:2410-2422` `seed_run`;
  - `store/src/tests/isolation.rs:78-104,544,1171`;
  - `orchestrator/tests/isolation.rs:324-334` (`as_worker`) and `orchestrator/tests/projects.rs:429`;
  - `gateway/tests/api.rs:5430-5469`;
  - `client-core/tests/client.rs:2316-2331`.
- `isolation.rs:476` changes to `format!("thinktin/i{}p{}", ISOLATION_LEVEL, PROJECT_PROTOCOL)`. The `Db::connect` path is already tested (`isolation.rs:456-477`).
- `boundary.rs:2078` (`run_linked_rows_carry_the_project`) and `:2255` (`purge_clears_run_linked_project_rows`) insert project-stamped `board_posts`, and their worker insert at `:2114-2121` is commented "8.17 的项目看板". They are rewritten to assert `board_posts_private`, and `board_posts` is dropped from their stamp and purge tables.

1. `dispatch_switch_gates_project_writes`:
   - the default is off on `TestDb::up_to(63)`;
   - a tenant INSERT gives 42501;
   - an 8.16-style connection (role and isolation only) gives `Forbidden` (`runs_isolation`);
   - `isolation=1` on a mixed instance is refused;
   - a withdrawn agent gives `project_agent_gone`, and so does a deleted instance;
   - `plan_id` set, or `urgent`, gives `project_run_shape`; so does an agent run with no grant, and a missing or finished parent.
2. `lease_fence_needs_project_protocol`: a project run leased by a transaction with `isolation=1` but no protocol is refused; with both it succeeds. This simulates an 8.16 claim, takeover and `transition_run`.
3. `creator_task_rules`:
   - the creator succeeds: `user_id` = the target's owner, `project_id`, `run_grant_id` = the standing grant, and the grant scope equals `PROJECT_PLATFORM_TOOLS`;
   - member → `NotPermitted`; outsider → `NotFound`; archived → `NotFound`;
   - mixed target → `AgentNotIsolated`; withdrawn target → `Invalid`;
   - no lead and no instance → `Invalid`;
   - target owner frozen → `Conflict("agent_unavailable")`;
   - 10 queued → `agent_busy`;
   - budget used up → `budget_reached`, and `max_tokens` equals the remaining budget;
   - the second task reuses the grant; `active_grant_for_instance` never returns it.
4. `lead_delegates_across_owners`:
   - Alice's dedicated lead delegates to Bob's dedicated agent. The child's `user_id` is Bob. Its grant has parent = the lead's grant, user Bob and project p; its platform tools = Bob's standing tools ∩ the lead's; its aliases are Bob's;
   - a non-lead's `project_child_run(Delegate)` → `Refused(NotLead)`, and a raw worker INSERT with a non-lead parent → `project_delegate_not_lead`;
   - chain, waits-for, sibling-limit and self-target refusals.
5. `ask_across_owners`: the child runs on Bob's standing grant; its stored prompt is the raw question; dedupe returns `Existing`; ask limit and depth.
6. `revocation_either_side`:
   - withdraw the lead: the child grant's `touch_run_grant` is None and the child run is cancelled;
   - withdraw the target: the child grant is revoked;
   - Bob leaves: Bob's child run is cancelled and Alice's root becomes claimable;
   - `revoke_user_grants(Bob)` revokes the child.
7. `private_trees_stay_same_owner`: a private child under another user's private parent is refused by `runs_parent_space`; a project cross-owner child succeeds.
8. `project_cancel_rules`: the creator cancels a subtree including Bob's rows; the owner cancels its own; another member → `NotPermitted`; a barrier race against `withdraw_project_agent` gives no 40P01.
9. `orphaned_children_swept`:
   - the lead's root is cancelled through the tenant `cancel_run`: Bob's delegate child is cancelled by `cancel_orphaned_project_children`;
   - a pipeline root tree-cancelled by the tenant: Carol's step is cancelled;
   - a row locked by another transaction is skipped and picked up on the next call.
10. `tree_tokens_per_owner`.
11. `set_project_lead_rules`: creator only; shared project + mixed → `AgentNotIsolated`; solo + mixed succeeds; the old lead is cleared; withdraw clears the lead; the tenant team write still works under the project lock.
12. `project_board_isolation`:
    - members read; ex-members and outsiders get `NotFound`;
    - tenant `board_posts()`, `board_post(id)` and `delete_board_post(id)` never see or touch project posts;
    - `thinktin_app` gets "permission denied" on `project_board_posts`;
    - erasing the author keeps the posts (author erased);
    - the per-project cap keeps 200 live posts (binding 199);
    - the per-member daily cap;
    - archive and delete permissions;
    - an agent post whose run is in another project is refused;
    - the `board_posts_private` CHECK refuses a stamped worker insert, and a tenant insert with a project `run_id` errors.
13. `project_pipeline_driver_order`:
    - `erase_account(Bob)` racing step creation for Bob's step gives no 40P01; one side waits;
    - a root that is locked elsewhere is skipped;
    - a `project_run_shape` error from a step fails only that pipeline, and a private pipeline in the same tick still advances.
14. `legacy_sessions_as_login`: a non-superuser login granted `thinktin_worker` with a second pool named `thinktin/i1` and one with an empty name: both are listed, the current name is not, and the call is made from inside an open `db.worker()` transaction on another connection.
15. `egress_ask_stale_epoch`:
    - after `bump_token_epoch` the old epoch gives `EgressAsk::Stale`;
    - a direct INSERT with a stale `asked_epoch` gives 23514 `egress_stale_token`;
    - a touch through `egress_ask` with `AskMeta::default()` on a request whose `asked_epoch` is stale still returns `Asked`.
16. `boundary.rs`: the member privilege list includes exactly the new column grants; tenants have no privilege on `project_board_posts`, `project_dispatch` or `project_pipelines`; the definer functions are unchanged; `ProjectRunState::coarse` matches the SQL `project_run_state`.
17. `purge_removes_board_and_pipelines`.
18. A migration test: `TestDb::up_to(59)`, seed a private tree, `migrate_rest`; the FKs are gone (`pg_constraint`) and the private tree is intact.
19. `stop_all_pauses_project_work`:
    - after `revoke_user_grants(Bob, STOP_ALL_REASON)`, creator tasks, asks, delegates and pipeline steps to Bob's agent are refused as `AgentUnavailable`;
    - `resume_project_agent` by Bob reissues the grant; by Alice it gives `NotPermitted`;
    - withdraw and re-add resets the pause.
20. `cancels_settle_approvals`: `cancel_descendants`, `cancel_children`, `cancel_stale_asks` and `cancel_project_subtree` cancel other owners' pending approvals and expire their egress requests.
21. `off_waits_for_in_flight_dispatch`: a barrier holds a dispatch after its INSERT; `set_project_dispatch(false)` waits; after both commit, `projects_with_unfinished_runs` finds the run, and the off loop cancels it.
22. `withdraw_lead_mid_answer`: the lead answers Bob's ask and delegates to Carol; withdrawing the lead cancels Carol's grandchild in the same transaction.

### 5.2 Orchestrator

New `crates/orchestrator/tests/collab.rs`, with fake shims as in `tests/isolation.rs`. The cast: two users, project p, Alice's dedicated A (the lead), Bob's dedicated B, Alice's private botin X and a mixed solo agent M.

1. `project_run_tools`: the shim launch for a project run on B lists the 10 non-delegate tools; on A (the lead) the list adds `delegate` and `delegate_list`; never vault, computer, schedule or browser.
2. `agents_list_sees_only_project`: A's list shows B with "Bob's botin", never X or M; after Bob withdraws B it disappears; a name with control characters is labelled.
3. `agent_status_projection`:
   - an old private run on B (the 8.16 fixture) is not shown;
   - no `error`, tool titles or purpose;
   - a `waiting_approval` run shows as `waiting_owner`;
   - a creator task whose first line is the creator's text shows that line.
4. `board_tools_project`:
   - a post lands in `project_board_posts`, not Alice's private board;
   - `board_read` returns only project posts;
   - a body equal to one of Alice's vault values is posted unchanged, with no refusal (no oracle);
   - after leaving, the tool refuses.
5. `ask_across_owners_end_to_end`:
   - A asks B; B's fake shim answers;
   - B's shim received the header "「A」（Alice 的 botin）" in Bob's locale; the stored prompt is raw;
   - A resumes with the answer, the untrusted note and the label;
   - B's child used Bob's grant.
6. `lead_delegates_end_to_end`: B's child fails with an error containing `sk-test-…`; A's resume message has no such text (asserted on the shim's received prompt).
7. `late_tool_calls_after_withdraw_refused`: withdraw B mid-run; a `board_post`, `ask` or `artifact_publish` from B's still-running shim is refused.
8. `pipeline_across_owners`:
   - steps on A and B; the root is on A, and A's grant is not the parent of B's step grant;
   - the handoff copies artifacts and carries the untrusted note, in Bob's locale; tree tokens are counted per owner;
   - switching the dispatch off between steps fails that pipeline, and a private pipeline in the same tick still advances;
   - **8b:** B's step error contains `sk-test-…`, and neither the root row nor any root event contains it;
   - **8c:** a creator with no dedicated botin gets `Invalid`.
9. `old_protocol_cannot_execute`: a raw claim UPDATE in a transaction with `isolation=1` only → the fence refuses; the executor proper claims the run.
10. `creator_task_not_piggybacked`: a creator task queued while B answers an ask is not announced into that run; it runs afterwards.
11. `executor_lead_check_per_space`: X as the team lead keeps private delegate tools; A as the project lead gets project delegate; demote A while it runs → the next `delegate` gives `NotLead`.
12. `header_survives_retry`: a project delegate child on attempt 2 still starts with the header; renaming the lead between attempts changes the name in the header.
13. `project_notices_platform_written`: Bob's push and inbox body for a finished creator task is "「B」 finished a project task", not the summary.
14. `orphan_sweep_in_takeover_tick`: after a tenant cancel of A's root, B's delegate child is cancelled within one takeover tick, with a `run.state` event.

### 5.3 Gateway (`crates/gateway/tests/api.rs`)

- **Tasks:**
  - every status in §4.1, including 503 with the switch off, the 409 codes, and `Cache-Control: no-store`;
  - Bob's `/v1/runs/{id}` shows the private fields of the creator's task on his botin; Alice's `/v1/runs/{id}` gives 404;
  - `can_dispatch` flips with the switch and the role;
  - the prompt-secret 422.
- **Lead, resume, board (including 429), pipelines, cancel and artifact delete:** each status listed.
- `GET /v1/board` never contains project posts; `DELETE /v1/board/{project post id}` gives 404.
- Add the new paths to `project_paths` (`api.rs:5528-5541`) for the outsider and Forbidden→404 sweeps.

### 5.4 client-core (`crates/client-core/tests/client.rs`)

- Mock-server tests check the paths, methods and JSON of every new call.
- `refuse_secrets` on project text, and the `allow_secrets` override.
- A 404 from `project_board` forgets the project's cached notices.
- Update `ffi_smoke.py` (§4.2).

### 5.5 llm-gw

- A stale-epoch ask is denied with `stale_token` (pg ledger test; the memory ledger does not check epochs).
- An existing ask flow still passes with the right epoch, on both ledgers.

### 5.6 Mutation checks

After the gateway commit, break each rule on purpose and confirm that at least one test fails, as 8.16 did.

| Rule broken | Test that must fail |
|---|---|
| Remove `current_user <> 'thinktin_worker'` | S1 tenant insert |
| Remove the switch check | S1 |
| Remove `FOR SHARE` from the switch read | S21 |
| Remove the protocol check from the lease fence | S2, O9 |
| Remove the delegate-lead check in `runs_project_tree` | S4 raw insert |
| Remove the finished-parent check | S1 |
| `is_project_lead` → `true` | O11 |
| Drop the `ctx.project` branch in `peers`, `board`, `ask` or `delegate` | O2, O4, O5 |
| Make `member_read` on `project_board_posts` `USING (true)` | S12 ex-member |
| Remove the `board_posts_private` CHECK | S12 |
| Remove the owner filter in `tree_tokens_except` | S10 |
| Pass `error` in `results_message`, or copy it into the pipeline root | O6, O8b |
| Remove the epoch check, or the carried-over NULL rule | S15 |
| Remove the target liveness check in the dispatcher (the fence alone must still refuse) | S3 |
| Remove the savepoint mapping | O8, S13 |
| Remove `live_project_call` | O7 |
| Reissue grants after stop-all | S19 |
| Drop the settling from `cancel_descendants` | S20 |
| Run `legacy_sessions` inside `db.worker()` | S14 |
| Store names in project prompts | O12 |
| Remove the recursive subtree in `cancel_project_agent_runs` | S22 |

---

## 6. Commit sequence

Every commit compiles and passes `cargo test --workspace`. Push after each one, and update `docs/progress/claude-determined-lovelace-vn0j5h.md` with it.

1. **docs:** save the final plan as `docs/progress/drafts/projects-8.17-plan.md` and update the progress "进行中" entry.
2. **proto:** `PROJECT_PLATFORM_TOOLS`, `ProjectRunState::coarse`, `ProjectBoardPost`, pipeline DTOs (all new types, serde defaults), and unit tests. `ProjectDetail.can_dispatch` waits for commit 8, because adding it now breaks the struct literals at `store/src/project_reads.rs:478` and `proto/src/domain.rs:1957`.
3. **store, migration 0060:**
   - `PROJECT_PROTOCOL`, `APPLICATION_NAME`, the `Db::worker` GUC, `Db::legacy_sessions`, `STOP_ALL_REASON`;
   - the error mapping; `NewRun.project_id` (`pub(crate)`) and `insert_project_run`; the `create_run` refusal; `insert(project)` for grants;
   - all fixture updates of §5.1 (`TestDb::new` switch, `project_writer`, the `boundary.rs` board tests);
   - tests S1, S2, S7, S14, S18, S21.
4. **store, the dispatcher:**
   - `project_dispatch.rs`: actors, target checks, budget, creator task, child runs, resume, cancel, switch;
   - grants: ensure (pause), issue, child; `is_project_lead`, `set_project_lead`; per-owner tree tokens;
   - recursive withdraw and leave cancels, `cancel_project_subtree`, the orphan sweep, settling in the worker cancels;
   - tests S3–S11, S19, S20, S22.
5. **store, migration 0061 and the project board:** board store and member reads, purge, `delete_project_artifact`, `boundary.rs`; tests S12, S16, S17.
6. **orchestrator:**
   - project modes of `peers`, `board`, `ask`, `delegate` and the artifact tools; `PROJECT_RUN_TOOLS`; `live_project_call`; texts and `label`;
   - executor: lead, member projection, headers at launch, results, budget, no piggyback, notices, the orphan sweep in the takeover tick; `account.rs` reason constant;
   - tests O1–O7, O9–O14.
7. **server:** `admin project-dispatch` and the maintenance board purge, with tests.
8. **gateway:** task, cancel, lead, resume, board and artifact-delete routes; `ProjectDetail.can_dispatch`; the 422 for secrets; replace the raw fixture; gateway tests. Then the mutation pass of §5.6 for everything so far.
9. **store and llm-gw, migration 0062:** the egress epoch; S15 and the llm-gw tests.
10. **store, orchestrator and gateway, migration 0063:** project pipelines (store, per-root driver, handoff, routes); S13, O8 and the gateway pipeline tests. This line can be cut to a follow-up without blocking 8.18.
11. **client-core:** API, FFI and tests, plus `ffi_smoke.py`.
12. **apps/android:** regenerate `client_core.kt` with `sync-core.sh --bindings-only`. **Push 11 and 12 together.**
13. **docs:**
    - `projects-impl.md`: a "8.17 做了什么" section; reword rule 7 (`:24`);
    - `projects.md`: the status line; `:40` (the board is stored like run content, not with the project key);
    - `wbs.md`: the 8.17 scope note (urgent messages move to 8.18; the team-runs-as-project-runs rejection) and a new line for project schedules and lead-built pipelines;
    - `release.md`: the dispatch switch, `legacy_sessions` with `thinktin/i1p2` run as the server login, rollback via `admin project-dispatch off`, "no real-money two-owner pilot before 8.18"; reword `:155-158` and `:164-167`;
    - `deploy-checklist.md`: the post-rollout step;
    - `architecture-v3.md` 4.11: a pointer.
14. **Mutation pass on the rest and the test gaps it finds,** then the adversarial review (as for 8.16).

---

## 7. What 8.17 leaves, and founder-run cloud checks

**8.18:**
- project budgets (`project_members.*_token_limit`) enforced in llm-gw, with a per-(project, owner) reservation, replacing the coarse dispatch cap;
- approvals routed and shown as "waiting for owner";
- the owner's per-agent narrowing of the project scope (the real "project ∩ owner" intersection);
- vault per item, computer per project, and the browser per project;
- **all interrupt rules:** the creator's urgent messages (with a worker `queue_urgent_run` variant and a new `runs_project_tree` that allows them), the lead interrupting members, and "stop all" cascading into other owners' subtrees;
- frozen accounts;
- the owner's full event view of its agents' project runs.

**8.19:**
- the project feed with `project_seq`;
- receipts (lead changed, task finished or failed to the creator, pipeline finished, "your dedicated botin was reset");
- board @mention pushes;
- reporting other people's project content: needed before `cross_user_projects` is turned on in production (`projects-impl.md:149-150`);
- IM pushes of project content;
- "requested by" on project runs, if still wanted;
- `delegate.started`, `ask.sent` and `board.posted` in the member event whitelist.

**Not in any package yet (add a WBS line):**
- recurring project plans (project triggers, `schedule_*` in project runs, creator confirmation);
- pipelines built by the lead.

**Level 2:**
- mixed agents;
- the prerequisites in the 8.16 plan §8;
- dropping the now-unused `board_posts.project_id` stamp and the `board_posts_project` index (0058).

**Founder-run cloud checks:**
1. **RDS:**
   - `set_config('thinktin.project_protocol','2',true)` works for `thinktin_server_login` under `SET ROLE thinktin_worker`;
   - `admin project-dispatch status`, run as `thinktin_server_login` with no role switch, lists the other replicas by `application_name`. Run it during a real rolling update: old `thinktin/i1` sessions are listed, then disappear;
   - check whether a connection pooler sits in front of RDS and rewrites names.
2. **ACS (Tokyo), with two real accounts and small test keys:**
   - Alice creates a shared project, and Bob joins with an adopted dedicated botin and a small budget;
   - Alice sets a lead and tasks it; the lead delegates to Bob's botin, and Bob's botin asks Alice's;
   - check that each owner's `usage_records` and costs land on that owner, and that dispatch stops at Bob's budget;
   - Bob withdraws mid-task: Bob's work stops within a renew period and Alice's lead resumes with "cancelled";
   - members never see Bob's failure reasons;
   - Bob presses "stop all": nothing restarts on Bob's botin until Bob resumes it.
3. **llm-gw:** release a dedicated botin right after a run ends, and confirm that an egress ask from the old sandbox's still-cached token is denied with `stale_token`, not recorded under the new workspace.
4. **Rollback drill:** run `admin project-dispatch off` (project runs cancelled, count 0), redeploy 8.16, confirm its claim loop is healthy (`thinktin_claim_fence_total` stays 0), then roll forward and turn it back on.
5. **Capacity:** measure the `project/{p}` lock wait with 30 agents asking and delegating at once, and with the pipeline driver advancing project roots, to confirm the advisory lock is not a hot spot.

---

## Appendix A. Critics' corrections: Applied or Rejected

### A.1 Security critic

| # | Correction | Verdict | Reason / where |
|---|---|---|---|
| F1 | A pipeline root must not copy a child's `error` | **Applied** | Confirmed at `pipeline.rs:149-157,332-346`. The root records `step {key} {coarse}` (D12, D14, §3.4); test O8b. |
| F2 | `legacy_sessions()` returns nothing under `Db::worker` | **Applied** | Reproduced on PG 16.15 (§1.0 V5). Now `Db::legacy_sessions` on the pool, with no `backend_type` filter; NULL and empty names count (§2.1); S14 uses a non-superuser login. |
| F3 | No spending cap on cross-owner dispatch | **Applied (coarse)** | A dispatch-time cap per (p, owner) with `max_tokens` = the remaining budget (D13, §2.5); precise reservation stays 8.18; plus a release note. |
| F4a | Withdraw and leave cancels miss subtrees not rooted on the agent | **Applied** | Confirmed at `runs.rs:899-988`; recursive subtree (§2.2); test S22. |
| F4b | `cancel_user_runs` should cancel cross-owner subtrees | **Rejected** | The 15 s orphan sweep (F4d) cancels them with D13 settling. The child grants already fail `ancestors_usable!` after stop-all or erase revoke the parent's grants. Freeze revokes nothing, but the cancelled parent makes the children orphans. Adding cross-owner locks to stop-all, freeze and erase, which do not hold project locks, buys at most 15 s. |
| F4c | Route the tenant `/v1/runs/{id}/cancel` of project runs to the worker cancel | **Rejected** | The tenant cancel cancels the caller's own rows, and the sweep cancels the rest within one tick. The project cancel route (D16) is the immediate path. |
| F4d | Sweep `delegate` and `pipeline` orphans in the takeover tick | **Applied** | `executor.rs:85,500-511` (15 s); `cancel_orphaned_project_children` with `SKIP LOCKED` (§2.2, §3.3). |
| F5 | Anchor the pipeline on the creator's own agent; steps on their own authority; only the creator cancels the root | **Applied (simplified)** | Steps run on the target's standing grant (no child grant at all); the root carries no grant (D5c, D14); the 0063 trigger requires the root's owner = `created_by`. |
| F6 | Others must not undo "stop all" | **Applied** | Confirmed at `account.rs:91-96`. The pause rule reads the newest standing grant's revoke reason, plus an owner-only resume route (D20, §2.3, §2.5); S19; founder question. A grant-API revoke still only stops current work (stated in D20). |
| F7 | Missing untrusted notes; the creator shown as "the user"; names unsanitized | **Applied** | Notes on handoffs and artifact tools; no piggyback in project runs; `label()` (D12, §3.1–§3.5). The interrupt wording is moot because urgent messages move to 8.18 (D15). |
| F8 | A dispatch in flight survives `off` | **Applied** | `FOR SHARE` read in the fence; `off` flips, commits, then cancels until the count is 0 (D6, D7). Verified (§1.0 V10); S21. |
| F9 | Savepoint error mapping incomplete | **Applied** | Every non-`Db` error rolls back the step savepoint (§3.4), inside a per-root transaction (H1). |
| F10 | Worker cancels skip D13 settling | **Applied (generalized)** | `cancel_descendants`, `cancel_children` and the `cancel_stale_asks` path settle approvals and expire requests (§2.2); S20. The urgent part is moot (D15). |
| F11a | Caps: queued project runs per target agent | **Applied** | ≤10, covering creator tasks, asks and delegates (D23). |
| F11b | Caps: open cross-owner asks per target | **Applied via F11a** | Asks to a busy agent are queued runs, so the per-target queue cap covers them. |
| F11c | Caps: 30 creator tasks per project per hour | **Rejected** | Bounded by the queue cap and the budget cap. |
| F11d | Caps: 50 member posts per day | **Applied** | D9, §2.6; index `project_board_posts_by_member`. |
| F11e | Caps: 2-hour deadline on cross-owner delegate children | **Rejected** | Approvals already expire (`approvals.expires_at` from `policy.approval_timeout_secs`, `executor.rs:2154,2264`); routing them to owners is 8.18. |
| F12 | Push notices carry AI text that the creator steers | **Partly applied** | The body is platform-written for project runs (D21, §3.3). **Rejected:** "inbox only", because the owner still needs to learn that its botin finished or failed, and the push no longer carries writer-controlled text. |
| F13 | Names stored in prompts survive erase | **Applied** | Stored project prompts are raw; headers are rendered at launch (D12, §3.3); O12. |
| F14 | Plan inconsistencies (header stripping on User runs; V4) | **Applied** | No header stripping for project runs. V4 is replaced by `IF NOT FOUND` (§1.0, §1.1). |
| F15 | Withdrawn or deleted agents' names | **Applied via impl Low 11** | Names come from the member projection, whose policy hides them (§2.4). |
| F16 | Errors reveal another member's account state | **Applied** | Generic 409 `agent_unavailable` for frozen, paused or inactive owners. `budget_reached` stays distinct on the creator route only, because budgets are project information the creator manages; agents get one generic text (§2.5, §3.2). **Corrected by final review #1:** the creator can neither set nor read another member's budget or botin limits, so for another owner's botin a used-up budget is now the same 409 `agent_unavailable`; only the creator's own botin keeps `budget_reached`. |
| F17 | Target checks do not reject deleted instances | **Applied** | In `project_agent_live` (0060) and in the dispatcher's target checks. |
| F18 | `GrantScope::intersect` mixes owners' aliases | **Applied** | Same as impl M5 (D5b, §2.3). |
| F19 | 0062 refuses legitimate re-asks mid-rollout | **Applied** | Same fix as impl H2 (verified, §1.0 V11). |
| F20 | DB backstops | **Applied** | Parent not finished, agent runs need a grant, no urgent or interrupt rows (0060); `project_board_post_run` and `project_pipeline_root` triggers (0061, 0063). There is no step table to guard, because steps are jsonb. |
| — | "Checked and correct": update `projects-impl.md:24` | **Applied** | Docs commit 13 (D8). |
| — | Tests to add | **Applied** | S13, S14, S19–S22; O8b, O10, O12–O14; §5.6 rows. |

### A.2 Implementation critic

| # | Correction | Verdict | Reason / where |
|---|---|---|---|
| H1 | The pipeline driver deadlocks against erase | **Applied** | Confirmed at `users.rs:186,207` and `runs.rs:1723-1737`. Private `due_pipelines` is unchanged; project roots advance one per transaction in D4 order (D14, §2.2, §3.4); S13. No `try_lock_project`. |
| H2 | The 0062 trigger refuses re-asks; `touch_request!` cannot take a fixed `$n` | **Applied** | Confirmed at `egress.rs:94-101,385,425-447,478`. Trigger rule, parameterized macro and `crate::signed` (§1.3, §2.7); verified (§1.0 V11); S15. The residual edge is documented (§1.3). |
| H3 | `legacy_sessions()` returns nothing in production | **Applied** | Same as F2 (verified). |
| H4 | Commit 3 fixtures incomplete | **Applied** | Full list in §5.1, plus `TestDb::new` turning the switch on, `project_writer`, and the `isolation.rs:476` and `boundary.rs:2078,2255` rewrites. |
| H5 | Pipelines leak failure text; `cancel_children` skips settling; handoff unmarked and in the wrong locale | **Applied** | Confirmed at `pipeline.rs:149-157,281,418-436` and `runs.rs:1803-1822` (D14, §3.4). |
| M1 | Orphan sweep too narrow and too slow | **Applied** | Same as F4d. |
| M2 | Owner cancel crosses owners | **Partly applied** | With F5 the pipeline root always belongs to the creator, so a non-creator owner never owns a root. **Rejected:** limiting an owner's cancel to its own rows. A run's subtree is that run's work, and the sweep would cancel the orphaned children within one tick anyway; cancelling at once is the same outcome, sooner and with settling. |
| M3 | D20 contradicts the private "stop all" semantics | **Applied** | Same as F6; founder question. |
| M4 | Preface wiring drops the header on retries; `agent_status` cuts the creator's first paragraph | **Applied** | Confirmed at `executor.rs:265-270,1720-1752` and `peers.rs:176-185`. The header is prepended to the base prompt on every attempt, and project runs never strip (D12, §3.3); O3, O12. |
| M5 | Intersecting aliases is meaningless | **Applied** | Confirmed at `domain.rs:415-425` and `executor.rs:767-772`. Target aliases, tool intersection, minimum `max_tokens`, done inline; no proto `intersect` (D5b, §2.3). |
| M6 | Composite FKs on the board; cap binding | **Applied** | Confirmed against `board_posts` (0025) and `board.rs:136-145` (§1.2, §2.6); verified (§1.0 V12). |
| M7 | Decide board encryption now | **Applied** | Plaintext; `projects.md:40` updated in docs commit 13; founder question to confirm. |
| M8 | Race on `off` | **Applied** | Same as F8. |
| M9 | Urgent creator messages belong to 8.18 | **Applied** | `projects.md:86,128` and `wbs.md:221` put interrupt rules in 8.18. No `queue_urgent_inner`, no `delivery`, no `urgent` in the API or FFI; the fence refuses urgent project rows; draft test O10 dropped (D15). |
| L1 | `schema.rs` item spurious | **Applied** | `schema.rs:16-18`; item dropped. |
| L2 | 8.16 review #15 already fixed | **Applied** | `isolation.rs:456-477` uses `Db::connect`; only `:476` changes. |
| L3 | The late-call check already exists | **Applied** | `tools.rs:507-517` is extracted into `live_project_call`; no `run_space_state`. |
| L4 | V4 expectation wrong | **Applied** | Replaced by `IF NOT FOUND`. |
| L5 | O1 count | **Applied** | 10 tools for non-leads. |
| L6 | No fake server for `ffi_smoke.py` | **Applied** | `ffi_smoke.py:57`; it tests defaults and error paths (§4.2). |
| L7 | §3.6 vs §5.5 contradiction | **Applied** | Stale asks are tested on the pg ledger only (§5.5). |
| L8 | Commit 2 will not compile | **Applied** | `can_dispatch` moves to commit 8; `EgressRequest.project_id` dropped (L12). Confirmed literals at `egress.rs:75-83`, `project_reads.rs:478`, `domain.rs:1957`. |
| L9 | Android CI fails on commit 11 alone | **Applied** | Commits 11 and 12 are pushed together (`.github/workflows/android.yml:59`). |
| L10 | Keep `allow_secrets` for project text | **Applied** | `client.rs:417-428` is pattern detection (D18, §4.2). |
| L11 | Use the member projection for names | **Applied** | Drops `project_agent_names` and `project_brief` (§2.4, §3.3). |
| L12a | Steps as jsonb | **Applied** | §1.4. |
| L12b | Reuse the configured TTLs | **Applied** | `gateway/src/lib.rs:56`, `tools.rs:50`, `delegate.rs:31`. |
| L12c | Drop the shim change | **Applied** | Baked into the sandbox image, `bridge.rs:39-41`. |
| L12d | Drop `EgressRequest.project_id` | **Applied** | 8.18 UI. |
| L13 | Dispatcher-only is not enforced in Rust | **Applied** | `pub(crate)` field, `insert_project_run`, `create_run` refusal (D4, §2.2). |
| L14 | Budget inheritance across owners | **Applied** | Cross-owner children get the owner's remaining budget, read fresh; the over-count is conservative and documented (D13). |
| L15 | Cross-owner children uncapped until 8.18 | **Applied** | Coarse cap (F3), plus the release note. |
| L16a | Record the rejection of "team runs as project runs" | **Applied** | D2; `wbs.md` and the progress file. |
| L16b | Fix the stale comment at `0056:2` | **Rejected** | Editing an applied migration changes its sqlx checksum and breaks every database that ran it (`schema.rs` `MigrationStatus.modified`). The 0061 header records that the comment no longer applies. |
| — | Missing tests | **Applied** | S13 (erase race), S15 (epoch-less touch), S14 (non-superuser login), O8b (root error), S9 (tenant-cancelled pipeline root), S8 (non-creator scope), S19 (stop-all), O3/O12 (preface and first paragraph), S21 (`off` race), S12 (tenant insert with a project `run_id`). |


## 待定问题（默认做法照写，用户没反对就按这个）

- 「全部停止」和项目：你按了「全部停止」以后，你的 botin 在所有项目里的活都会停下。别人（项目创建者、负责人 agent、其他 agent）能不能马上又给它派新活？默认：不能。要等你自己在那个项目里点「恢复」，它才重新接项目里的活。
- 项目看板怎么存：默认和项目任务、运行记录一样处理。项目一删除，所有人马上都看不到，随后后台彻底删掉，但不再单独用项目密钥加一层密。产品文档原来写的是“用项目密钥加密”，会跟着改。默认：按这个做。
- 花费上限：从 8.17 开始，别人可以让你的 botin 干活、花你的 token，而精确的扣费和预留要到下一步（8.18）才做。8.17 先在派活时按你设的每天和总预算粗略挡一下，可能略微超出。默认：先这样做；8.18 做完之前，跨用户项目在正式环境里保持关闭，试点只用测试账号和小额的 key。
- 紧急消息（打断正在做的事）：项目创建者给项目里的 botin 发紧急消息、打断它手上的活，默认放到 8.18，和其他打断规则（比如负责人 agent 打断成员）一起做。8.17 里创建者可以先停掉那个任务，再派新的。
- 流水线挂在谁名下：项目流水线默认要求创建者自己在项目里至少有一个专属 botin，流水线记在它名下，只有创建者能停掉整条流水线。没有的话，App 提示“先派一个你自己的专属 botin 进来”。默认：这样做。
- 别人派的活做完时的推送：别人给你的 botin 派的项目任务做完或失败时，手机推送默认只写平台的话，比如“「botin 名」完成了一个项目任务”，不显示 botin 写的总结（总结可能被派活的人引导成广告）。点开能看全文。默认：这样做。
- 跨用户委派要不要主人逐个确认：负责人 agent 把子任务交给别人的 botin、或者 agent 之间互相提问时，默认不用主人逐个点确认。在主人设的预算内自动执行，主人看得到，可以随时停或撤回（产品文档第 11 节的默认）。默认：不用确认。
- 上限：默认每个项目最多 200 条在用的看板条目，满了自动归档最旧的，归档 30 天后删除；每个成员每天最多手动发 50 条；每个 botin 最多排 10 个还没开始的项目任务，再多就提示“这个 botin 正忙”。默认：用这些数字。
- 定时的项目任务、负责人 agent 自己编排流水线：8.17 不做，任务分解里也还没有对应的工作包。默认：新加一个工作包，排在 8.19 之后。
- 共享项目的负责人：有别的用户加入的项目里，负责人默认只能是专属 botin（只做这个项目的事、记忆里只有项目的东西）；只有你自己一个人的项目（原来的团队）里，任何 botin 都能当负责人。默认：这样做。

## 用户的回答（2026-11-07，定了）

1. 「全部停止」以后：不做「恢复」按钮。别人照样能派活，botin 先给主人发消息问要不要做，主人点「做」才开始、点「不做」就取消；
   **主人确认过一次以后恢复正常**，之后派来的不再问（直到下次按「全部停止」）。
   改动：D20 不再拒绝派单（不报 `agent_unavailable`），改成建一个等主人确认的任务（审批类，主人在收件箱里点「做」或「不做」）；
   确认时重新签发常设授权。
2. 项目看板：按建议，和任务、运行记录一样存在库里、按成员关系挡住、删项目时一起删，不单独用项目密钥加密（D9 不变；
   docs/projects.md 第 3 节跟着改）。以后要更严就把项目里的文字一起加密。
3. 花费上限：主人给派进项目的每个 botin 设 token 限额（每天和总的）。8.17 派活时按它粗略挡（D13 的余量 = 成员预算和这个
   botin 的限额取小的），8.18 在模型网关里精确扣。
4. 紧急消息放到 8.18。
5. 流水线挂在创建者自己的专属 botin 名下。
6. 推送只写平台的话。
7. 跨用户委派、互相提问不逐个问主人（按建议）：在主人给 botin 设的限额内自动做，主人看得到、随时能停或撤下；按了
   「全部停止」以后照第 1 条先问一次。
8. 上限数字照默认。
9. 定时的项目任务、负责人编排流水线放到新工作包。
10. 共享项目的负责人只能是专属 botin，只有自己的项目里任何 botin 都能当（D11 不变）。


## 按用户的回答改的实现（2026-11-09）

- **迁移重新编号：** 0060 派单（已提交）；**0061 botin 的 token 限额**（新）；0062 项目看板；0063 出网令牌代数；0064 项目流水线。
  （2026-11-09 再改：**0063 `users.stopped_all_at`**（按“全部停止”时 botin 还没有常设授权的也要等确认，编排层测试发现的），
  出网令牌代数顺延到 0064，项目流水线 0065。）
- **D13 预算：** 余量 = min(成员每天的预算剩下的、成员总预算剩下的、这个 botin 每天的限额剩下的、这个 botin 总限额剩下的)，
  空的不算。botin 用掉的 = 它在这个项目里所有运行的 `tokens_used`（每天的按最近 24 小时）。限额只有主人看得到、改得了
  （`Tx<Worker>::set_project_agent_limits`，成员的投影里没有这两列）。
- **D20 全部停止：** 没有「恢复」。常设授权因为 `stop_all` 被吊销的（暂停），派单照样写，运行还是 `queued`，但
  `wait_code = 'owner_confirm'`、`not_before` 推到一百年后（领不到；不用 `waiting_approval`：它算占着实例，
  `runs_one_active_per_instance`，确认之前别的任务也跑不了）、`wait_deadline = now() + 24 小时`，`run_grant_id` 指着那个被吊销的
  授权（栅栏只要求有授权）；成员看到的粗略状态是「排队」。主人确认（`confirm_project_task(owner, p, run, true)`）时签发新的常设授权、
  把这个 botin 在这个项目里所有等确认的任务换上新授权、改回排队（暂停解除，之后派来的不再问）；拒绝的只取消这一个，暂停
  继续。过了期限没人确认的由兜底取消（“主人没有确认”）。提醒主人在编排层那一步做。
- **D23 排队上限** 把等确认的也算进去。
