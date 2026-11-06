# 8.17 代码地图（workflow `projects-8-17-plan`，2026-11-06）

## Map: dispatch-grants

All paths are relative to `/home/user/Thinktin-Rust`. I changed no files.

# 8.17 dispatcher: how runs are written today, and a proposal

## A. Every place that writes runs today

All of them end in `insert_run` (`crates/store/src/runs.rs:272-322`). Its INSERT never binds `project_id`. The `fill_space` trigger fills `space_kind` and `space_id`, and only `thinktin_worker` may write a row that has `project_id` set (`migrations/0040_run_spaces.sql:7-28`, triggers at `:41-46`). **So no code path can write a project run today. Only test fixtures do, with raw worker INSERTs:**
- `store/src/tests/isolation.rs:78-104`
- `orchestrator/tests/isolation.rs:527`
- `gateway/tests/api.rs:5432`
- `orchestrator/tests/projects.rs`

| Writer | Where | Role | Owner (`user_id`) | Grant | Notes |
|---|---|---|---|---|---|
| User message (queued) | `gateway/src/routes/runs.rs:31-68` → `Tx<Tenant>::create_run` (`store/runs.rs:493-500`) | tenant | caller | `ensure_instance_grant` (`runs.rs:71-96`; tenant `run_grants()` returns private grants only, `store/grants.rs:136-147`) | A botin dedicated to a project gets 409 (`runs.rs:43-46`) |
| Urgent message | same route → `queue_urgent_run` (`store/runs.rs:644-751`) | **tenant only** | caller | as above | Calls the tenant `self.instance()`. Advisory lock `interrupts/{instance}`. No worker variant exists. |
| Vault "fulfilled" follow-up | `gateway/src/routes/vault.rs:425-447` | tenant | caller | `ensure_instance_grant` | Skipped on dedicated botins (`:431`) |
| Plan webhook | `gateway/src/routes/hooks.rs:299-334` (`create_run` at `:321-325`) | worker | `target.user_id` | `target.run_grant_id` | Private plans only |
| Scheduler (plan fires) | `orchestrator/src/scheduler.rs:110-208` (`NewRun` at `:167-184`), driven by `due_triggers` (`store/plans.rs:616-640`) | worker | `d.user_id` | the plan's grant | Plans are always private. `plan_not_on_dedicated` and `private_target_not_dedicated` refuse active plans or steps on dedicated botins (`0055:70-96`, `:158-161`). |
| Pipeline steps | `orchestrator/src/pipeline.rs:63-83` (tick), `:209-249` (`start_step`, with savepoint), `:251-301` (`create_step_run`: `create_child_grant` at `:264`, `create_run(root.user_id)` at `:295`) | worker | the root's owner | child of the root's grant | `due_pipelines` filters `project_id IS NULL` (`store/runs.rs:1723-1737`). Pipeline roots take no lease. |
| Delegate | `orchestrator/src/delegate.rs:79-188` | worker | `ctx.user` (`:170`) | `create_child_grant(ctx.grant…)` (`:138`) | Copies the parent's `plan_id` (`:164`) and `budget` (`:168`) |
| Ask | `orchestrator/src/ask.rs:52-176` | worker | `ctx.user` (`:157`) | **`run_grant_id = None`** (`:151`); the executor then uses `active_grant_for_instance` | Scrubs the question with the asker's whole vault (`:80`) |

**How teams (8.1–8.8) start work today.** Teams are solo projects with the same ids (`0039_projects.sql:124-140`).
- `/v1/teams*` is create/read/update/delete only (`gateway/src/routes/teams.rs:30-202`, `routes/mod.rs:165-175`). There is no team-run route.
- The user messages the lead's private botin through `POST /v1/instances/{id}/runs`.
- The executor gives the lead the delegate tools only when its grant contains them **and** `is_team_lead(instance)` is true (`executor.rs:783-789`). That check means a live lead in an active project created by the lead's own owner (`store/instances.rs:617-627`).
- `delegate` targets come from `delegation_targets` (`instances.rs:594-613`): same user, not dedicated, live agents in projects where the caller is the live lead and the caller's owner is the creator.
- Guards: per-user lock `run_waits/{user}` (`runs.rs:470-478`), then the `run_chain` (`:1449-1463`) and `instance_waits_for` (`:1524-1549`) checks.
- All team work runs as private runs.

## B. Grants

**Store (`crates/store/src/grants.rs`)**
- The row has no `project_id` field (`:11-44`). `insert` never binds one (`:150-174`).
- Tenant `create_run_grant` (`:67-83`) and auth `GrantService::issue` (`auth/src/grants.rs:66-87`) run in tenant transactions, so they cannot write project grants (`fill_space` refuses).
- `create_child_grant` (`:306-335`) gives the child the **parent's owner** (`:313`) and requires `p.scope.contains(scope)`.
- `ancestors_usable` (`:46-55`) checks the `parent_id` chain only.
- `touch_run_grant` (`:339-360`) auto-renews only grants with `parent_id IS NULL`.
- `active_grant_for_instance` excludes project grants (`:362-376`).
- Revocation by project already exists: `revoke_project_agent_grants`, `revoke_project_grants`, `revoke_project_member_grants` (`:233-291`).

**Scope.** `GrantScope` is `{aliases, platform_tools, max_tokens}` (`proto/src/domain.rs:422-448`).
- `max_tokens` is enforced nowhere: llm-gw has no grant-level check, and the executor uses `run.budget` instead.
- The default tools are `[api] default_platform_tools` (`server/src/config.rs:155-167`), applied through `default_scope` (`gateway/src/routes/mod.rs:296-301`).

**Constraints on grants and runs**
- Old foreign keys keyed by the same `user_id`:
  - `run_grants (parent_id, user_id)` (`0001_init.sql:174`)
  - `runs (parent_run_id, user_id)` (`:254`, unnamed)
  - `runs (plan_id, user_id)` (`:252`)
  - `runs (run_grant_id, user_id)` (`:255`)
- Same-space foreign keys from `0045_run_space_keys.sql:6-17`:
  - `runs_project_agent` and `run_grants_project_agent` reference `(project_id, instance_id, user_id)` in `project_agents`. That row must exist, **but it may have left.**
  - `runs_parent_space`, `run_grants_parent_space` and `runs_grant_space`.
- `space_matches_instance` (`0055:57-69`, triggers on INSERT at `:155-157`): a dedicated botin accepts only rows of its own project. A **mixed botin accepts a project grant or run** (the check only fires when `ws IS NOT NULL`).
- `runs_isolation` (`0055:137-153`, `:166-167`) fires only on `UPDATE OF lease_owner`. **There is no INSERT-time fence.**

**Sandbox token.** `sandbox_token` (`auth/src/grants.rs:108-130`) checks that the grant is active, that `g.instance_id == instance`, that `user == rt.user_id`, and that the account is active. It does not check the project. The `runs_grant_space` foreign key keeps run and grant in the same space.

## C. Executor start (`orchestrator/src/executor.rs:724-1016`)

1. `ensure_running`, then `rt.workspace_project_id == run.project_id`, else the run fails (`:743-748`).
2. Grant (`:752-765`):
   - `run_grant_id` if set;
   - a private run falls back to `active_grant_for_instance`;
   - a project run with no grant fails: "a project run needs its project grant".
3. Models: the instance's route aliases, filtered by `scope.aliases` (`:767-775`).
4. Lead: `is_team_lead` (`:783-789`). This is space-blind and solo-only.
5. Resume names are read through `db.tenant(rec.user_id).instance(child)` (`:822-831`). **That read is blind to another owner's children** because RLS hides them.
6. Platform tools (`:857-865`) are the tools in `grant.scope`, minus delegate unless the run is the lead's, filtered by `allowed_in_space`. `PROJECT_RUN_TOOLS` is the 4 artifact tools plus `web_search` (`tools.rs:451-467`).
7. Browser: server switch, template support, and the grant must list `browser` (`:867-875`).
8. `ToolContext.project` is set (`:970-979`). The scrubber is empty for project runs (`:995-999`).
9. Tree budget: `tree_tokens_except` sums the whole tree across **all owners** (`runs.rs:1341-1351`, `executor.rs:2426-2452`).

## D. Project actor, membership and budgets

**`ProjectActor`** (`store/src/projects.rs:84-104`, `project_actor` at `:137-183`)
- It is crate-private, so the dispatcher has to live in the store.
- Lock order: user rows `FOR KEY SHARE` (caller, creator, `also`) → project advisory lock (`:56-58`) → status in `allow` → the caller's live member row `FOR NO KEY UPDATE`.
- Non-members get NotFound. `require_creator` (`:93-102`) returns `NotPermitted`.
- It represents a **user only**. There is no agent or run actor.

**Other membership code**
- `withdraw_project_agent` (`project_members.rs:444-519`) shows the pattern for locking another owner's member row.
- `dedicate_project_agent` (`:364-420`) shows the pre-lock of egress requests, then the instance.

**Lead**
- `project_agents.is_lead` has one live lead per project (`0039:54,65,68`).
- **Nothing sets the lead in a shared project.** Only the tenant solo paths do (`projects.rs:295-300`, `:376-377`). 8.14 deferred "跨用户换负责人" to 8.17 (`projects-impl.md:92`).

**Budgets**
- `project_members.daily_token_limit` and `total_token_limit` (`0039:39-40`, commented "8.18 用"). They are set at join (`project_invites.rs:557`, `:673-684`) and by `set_project_budget` (`project_members.rs:662-711`). Members read them through `my_project_budget` (`0049:53`, `project_reads.rs:472`).
- The creator's own limits are NULL.
- **No code enforces them.** `usage_records` has `run_grant_id` (`0001:391`) and an index on `(instance_id, created_at)` (`:411`), but none on the grant.

## E. Proposal

### 1. Who may dispatch

| Who | What | Notes |
|---|---|---|
| The project creator (a person) | Give a task to any live dedicated agent in the project, or to the lead by default | `projects.md:18,80`; impl `:13`. Members get 403, outsiders 404. |
| The lead agent | `delegate` to any live dedicated project agent, whatever its owner | Lead = the live `is_lead` row in `run.project_id`, dedicated, owner a live member. Checked again on every call; never cached in the grant. |
| Other project agents | `ask`, board, `agents_list` / `agent_status` only; no delegate | |
| Member owners | No dispatch, not even to their own dedicated botin (it already refuses private messages) | They keep stop, withdraw and budget. |

Add `set_project_lead` (creator only). In shared projects the lead must be live and dedicated; otherwise 409 `agent_not_isolated`.

Interrupt rules (`projects.md:86`): the creator may interrupt any project run, the owner their own agent's runs, and the lead the subtasks it delegated. These cancels must go through a worker transaction, because tenant `cancel_run_tree` (`runs.rs:599-624`) cannot see another owner's descendants.

### 2. Which agents can receive work

Checked under the locks:
- the project is active;
- the agent row is live and the instance is not deleted;
- `instances.workspace_project_id = P`. A mixed botin gets 409 `agent_not_isolated`; the fence's `need = 2` leaves room for level 2 later;
- the owner's member row is live;
- the owner's `users.status = 'active'`, because claim needs it (`runs.rs:1146-1238`);
- for delegate: the target is not the caller, is not in the chain, is not waiting for the caller, and the depth and children limits from `delegate.rs` hold.

### 3. Grants

**Standing project grant, one per (project, agent)**
- Owner = the agent's owner, `project_id = P`, `parent_id` and `plan_id` NULL, the normal TTL, auto-renewed.
- Issued lazily by an `ensure_project_agent_grant` that mirrors `routes/runs.rs:71-96`. It is revoked by the existing `revoke_project_*` helpers.
- Scope:
  - `aliases`: empty, meaning the owner's routes;
  - `max_tokens`: None (budgets come in 8.18);
  - `platform_tools`: `PROJECT_RUN_TOOLS` plus project-scoped `board_read`, `board_post`, `ask`, `agents_list`, `agent_status`, `delegate_list`, `delegate`;
  - no vault, computer or schedule until 8.18 or until project plans exist;
  - browser off by default (a decision to confirm).
- `delegate` only takes effect for the lead, through the executor filter.

**Run grants**
- Creator tasks and asks use the standing grant directly. Today an ask child gets no grant, which `executor.rs:759-764` would fail.
- A delegated or pipeline child gets a grant whose `parent_id` is the **target's** standing grant. Same owner, so the old foreign key at `0001:174` stays.
- Add a new `run_grants.via_grant_id` column for the lead's or root's grant. It needs a same-space foreign key, and `ancestors_usable` must walk it too. This gives the rule "either side's ancestor revoked invalidates it" (impl `:20`).
- The child's scope is the target's scope intersected with the lead's. `GrantScope` needs an intersection helper.

### 4. Store API (all in `Tx<Worker>`, dispatcher and lead delegate)

**`dispatch_project_task(actor, P, instance, task{prompt, delivery})`.** Lock order (D3):
1. users (actor, creator, owner);
2. project lock;
3. actor's member row;
4. owner's member row;
5. agent row;
6. urgent advisory lock;
7. runs;
8. instance `KEY SHARE`.

Then it ensures the grant and inserts the run.

**`NewRun.project_id`.** Add it and bind it in `insert_run`. Add a worker version of `queue_urgent_run`.

**Project agent actor for delegate.** Build it from `(ctx.run, ctx.instance, ctx.project)` with the same order:
- users → project lock → caller's member row → caller's agent row (live, lead) → the caller's run (`FOR NO KEY UPDATE`, not finished, same project and instance) → target rows;
- replace the per-user `lock_run_waits` with the project lock for checks that cross owners.

**Cross-owner children**
- Set `plan_id` to NULL; the `(plan_id, user_id)` foreign key requires it.
- Set `user_id` to the target's owner.
- Hand results to the lead through the member projection, not the raw `error`/`state_reason` (`results_message` in `delegate.rs`).
- Read names through the worker.
- Count tree tokens per owner (`projects.md:82`).

### 5. Migration (0060 and later)

1. **Dispatch switch.** A table `project_dispatch(enabled bool DEFAULT false, changed_at, changed_by)` with one row. The worker can SELECT it. It is flipped only by a new `thinktin-server admin project-dispatch on|off|status` (next to `admin freeze`, `server/src/main.rs:107-133`). `on` refuses while `legacy_sessions() > 0` unless `--force`, and writes an audit row.
2. **INSERT fence: trigger `runs_project_fence`**, `BEFORE INSERT ON runs WHEN (NEW.project_id IS NOT NULL)`, with nested IFs (plan V15):
   - `thinktin.isolation >= need`, where `need` is 1 if the botin is dedicated to P and 2 otherwise; parse with `coalesce(nullif(...,''),'0')` (plan V2);
   - the switch is on, else `CONSTRAINT 'project_dispatch_off'`;
   - the agent row, member row and project are live (mirror `live_space!` at `runs.rs:375-394`);
   - if the parent's owner differs from `NEW.user_id`: `source` must be `delegate`, `ask` or `pipeline`, and for `delegate` the parent's instance must be P's live lead.
   - Put the same fence on `run_grants` INSERT for project grants. Map the new constraint names in `store/src/error.rs:73-83`.
3. **Drop the old foreign key** `runs (parent_run_id, user_id)` (`0001:254`, default name `runs_parent_run_id_user_id_fkey`). `runs_parent_space` already forces the same user in the private space, because there `space_id = user_id`. Mark it `-- deploy-safe:` because it only loosens. Keep the `run_grants` parent foreign key (see section 3).
4. **Do not add a new `runs.source` value.** Rows are parsed strictly (`runs.rs:235`), and `release.md:45-48` requires two releases for a new value. Creator tasks use `source='user'`. Optionally add a nullable `runs.dispatched_by` column, which is safe because column lists are explicit (`runs.rs:193-199`).

### 6. Rolling deploy and the `legacy_sessions` advisory

**Order.** Migrate (switch off) → roll out 8.17 → `admin project-dispatch status` → turn the switch on.

**Why each older version is safe while the switch is off and the fences hold**

| Version | Why it is safe | What remains |
|---|---|---|
| 8.13–8.15 | Claim, takeover, waits and pipelines skip project runs, and the lease fence blocks them anyway. Their space-blind `agent_status` is closed by the `peer_access` CHECK (`0055:12-14`). | Their space-blind board reads. Hence a **separate project-board table**, or a tenant policy that needs `thinktin.isolation`. |
| 8.16 | Its executor can run 8.17 project runs safely (no vault, empty scrubber, needs the grant). | It is degraded: only `PROJECT_RUN_TOOLS`, so the lead has no delegate; names come out empty; the tree budget counts every owner. So wait until all replicas run 8.17. |

**`legacy_sessions()`.** A query (it can be a store method) against `pg_stat_activity`:
- `datname = current_database()`
- `usesysid = (SELECT oid FROM pg_roles WHERE rolname = session_user)`. `session_user` stays the login even after `set_config('role')` (`lib.rs:168-181`). This excludes llm-gw and relay, which also connect through `Db::connect` (`llm-gw/src/main.rs:331`, `relay/src/main.rs:104`) but with other logins.
- `pid <> pg_backend_pid()`
- `backend_type = 'client backend'`
- `application_name IS DISTINCT FROM store::APPLICATION_NAME`, grouped by name.

It is only advice:
- the pool has no minimum connections (`lib.rs:124-131`), so an idle replica can hold no connections;
- a pooler can rewrite `application_name`;
- cross-check with `thinktin_build_info`.

Bump `APPLICATION_NAME` (now `thinktin/i1`, `lib.rs:110`) in 8.17 so 8.16 replicas get counted, and fix the wording of `release.md:156-158`, which today counts only names outside `thinktin/i`.

**Kill switch and rollback.**
- With the switch off, every new project run or grant INSERT is refused in the database. That includes delegate children and pipeline steps.
- The pipeline savepoint (`pipeline.rs:230-245`) must map `project_dispatch_off` to "this pipeline failed". Otherwise the whole batch rolls back, the same failure as 8.16 review finding 0.
- Rollback to 8.16: switch off, then cancel unfinished project runs (`cancel_project_runs`, `runs.rs:990-1018`), as `release.md:164-167` says.

## F. Gaps found while mapping (none of these is on the 8.17 list)

1. **Ask scrubs the question with the owner's whole vault** (`ask.rs:80-81`). That is the same guessing oracle as D14 / review #2. Project asks must skip it.
2. **Cancel helpers miss descendants.** `cancel_project_agent_runs` and `cancel_project_member_runs` cover only trees rooted at the agent's own root runs (`runs.rs:906-910`, `951-955`). `cancel_user_runs` (`:873-895`) and tenant `cancel_run_tree` miss descendants owned by someone else. Cancel descendants recursively, or add a sweep rule "parent finished → cancel child", like `cancel_stale_asks` (`:1551-1577`).
3. **"Team runs as project runs" cannot run yet.** Solo-project botins are mostly not dedicated, and their project runs would need level 2. Keep solo/team work on private runs, and write project runs only for dedicated targets.
4. **Project pipelines and schedules need project-owned plans.** Plans cannot be active on dedicated botins, and `plans` has no `project_id`. Anchor pipeline roots on the lead's dedicated botin so `isolated!` holds in `due_pipelines`.
5. **The executor's lead check must become project-aware.** Add an `is_project_lead(instance, project)`; `is_team_lead` requires `creator_id = lead owner`.

## G. Product decisions to confirm (the defaults above)

- Only the creator dispatches; member owners cannot, not even to their own dedicated botin.
- In a shared project the lead must be dedicated.
- Project grants leave the browser off by default.
- Budgets are not checked at dispatch in 8.17; enforcement is 8.18 in llm-gw.
- Rollback cancels in-flight project runs.

Key files:
- `/home/user/Thinktin-Rust/crates/store/src/runs.rs`
- `/home/user/Thinktin-Rust/crates/store/src/grants.rs`
- `/home/user/Thinktin-Rust/crates/store/src/projects.rs`
- `/home/user/Thinktin-Rust/crates/store/src/project_members.rs`
- `/home/user/Thinktin-Rust/crates/store/src/instances.rs`
- `/home/user/Thinktin-Rust/crates/store/src/lib.rs`
- `/home/user/Thinktin-Rust/crates/store/src/error.rs`
- `/home/user/Thinktin-Rust/crates/store/migrations/0001_init.sql`
- `/home/user/Thinktin-Rust/crates/store/migrations/0039_projects.sql`
- `/home/user/Thinktin-Rust/crates/store/migrations/0040_run_spaces.sql`
- `/home/user/Thinktin-Rust/crates/store/migrations/0045_run_space_keys.sql`
- `/home/user/Thinktin-Rust/crates/store/migrations/0055_dedicated_instances.sql`
- `/home/user/Thinktin-Rust/crates/store/migrations/0059_isolation_review_fixes.sql`
- `/home/user/Thinktin-Rust/crates/auth/src/grants.rs`
- `/home/user/Thinktin-Rust/crates/orchestrator/src/executor.rs`
- `/home/user/Thinktin-Rust/crates/orchestrator/src/delegate.rs`
- `/home/user/Thinktin-Rust/crates/orchestrator/src/ask.rs`
- `/home/user/Thinktin-Rust/crates/orchestrator/src/pipeline.rs`
- `/home/user/Thinktin-Rust/crates/orchestrator/src/scheduler.rs`
- `/home/user/Thinktin-Rust/crates/orchestrator/src/tools.rs`
- `/home/user/Thinktin-Rust/crates/gateway/src/routes/runs.rs`
- `/home/user/Thinktin-Rust/crates/gateway/src/routes/hooks.rs`
- `/home/user/Thinktin-Rust/crates/gateway/src/routes/vault.rs`
- `/home/user/Thinktin-Rust/docs/release.md`

## Map: collab-tools

# 8.17 map: project collaboration tools and their stores

All references are to branch `claude/determined-lovelace-vn0j5h` at HEAD `1afbb1a`. No files were changed. Two concatenated `cat -n` reads gave wrong numbers at first; every migration line number below was re-checked with grep on the single file.

## 0. How `ToolContext.project` flows today

- **Definition:** `ToolContext` (`orchestrator/src/shim.rs:69-77`) has a `project: Option<ProjectId>` field. The executor fills it from `rec.run.project_id` (`executor.rs:972-979`).
- **Tool list:** filtered at `executor.rs:857-865`, by grant, then by `lead` (`:863`), then by `allowed_in_space` (`:864`).
- **Allowlist:** `PROJECT_RUN_TOOLS` is `artifact_*` plus `web_search` (`tools.rs:454-460`). `allowed_in_space` is at `tools.rs:463-465`. The unit test at `tools.rs:754-773` asserts that `board_post`, `delegate`, `ask` and `schedule_*` are refused.
- **Lead:** computed once at start from the grant scope plus `is_team_lead` (`executor.rs:784-789`). `is_team_lead` (`store/instances.rs:617-626`) requires `p.creator_id = a.user_id`, so it means solo projects only.
- **Only two tools read `ctx.project`:**
  - `ArtifactTools::origin` refuses when `rt.workspace_project_id != ctx.project` or the run is terminal (`tools.rs:507-518`).
  - `search.rs:186` skips the owner-vault scrubber.
- **Not read anywhere else:** `peers.rs`, `board.rs`, `ask.rs`, `delegate.rs`, the `ScheduleTools` in `tools.rs`, `pipeline.rs` and `scheduler.rs` never look at `ctx.project`. Each needs a `match ctx.project { None => unchanged, Some(p) => project path }`.
- **Late tool calls:** each project path must re-run the `origin()`-style liveness check (run not terminal, instance still dedicated to `p`). The 8.16 review (`projects-8.16-review.md:164-176`) found that tool calls keep being dispatched for up to 15 s after a cancel.

## 1. Each tool: today, what happens if only whitelisted, what it must become

### `agents_list` and `agent_status` (`peers.rs`)

**Today: same user, private.**
- `peers()` is a tenant read (`peers.rs:46-51`) of `store/instances.rs:563-591`. It takes non-deleted, `peer_access`, `workspace_project_id IS NULL` instances, and the holder subquery has `r.project_id IS NULL`.
- `agent_status` reads in a tenant transaction:
  - `instance_holder` (`runs.rs:772-783`, `project_id IS NULL` at `:776`);
  - `last_finished_run` (`:786-797`);
  - raw `recent_run_events` (`peers.rs:108-115`);
  - `run_artifacts` (`:116`).

**If only whitelisted: leak.** A project run would list the owner's private botins and their task, to-do list, tools and last words. Members can read `agent.message`, so this reaches every member.

**What it must become: only the live, dedicated agents of `p`, across owners, excluding itself.** The member read model already gives the right projection:
- Read through `Db::member(ctx.user)` (`store/lib.rs:193`). The run's owner is a live member for any claimable project run (`live_space!`, `runs.rs:375-393`), and the database re-checks `member_projects()`.
- The agent list comes from `project_detail().agents` (`project_reads.rs:444-470`): name, agent kind, `is_lead`, dedicated, owner.
- Run state comes from `project_runs(p, instance=Some(t))` plus `project_run_events` (`0054:56-114`). That is the coarse state (`project_run_state`, `0054:14-21`), the 10 whitelisted event kinds, and tool kind and status only.
- Drop these fields:
  - `instance.purpose` (`peers.rs:65-67,104-106`): it is the owner's private note, and the member role has no such column (`0049:87`). Add an owner-written `project_agents.purpose` instead (design A, `projects-design-A.md:139-140`).
  - `instance.state`, used for "paused" (`peers.rs:162-173`).
  - Tool titles (`peers.rs:207-216`).
  - `last_finished.error` (`peers.rs:146-150`).
- Filter strictly on `project_id = p`. Old private runs stay on a now-dedicated instance (the 8.16 test fixture `orchestrator/tests/isolation.rs:376-377` has one), and the private `last_finished_run` would return them.
- `peer_access` cannot be the gate, because the CHECK `instances_dedicated_no_peers` (`0055:13-14`) forces it off. Project membership is the gate.
- Add a per-run artifact read to `ProjectTx`. The tenant `run_artifacts` sees only private artifacts (`0054:143`).

### `board_read` and `board_post` (`orchestrator/board.rs`, `store/board.rs`)

**Today: one private board per user.**
- Read: tenant `board_posts()` (`orch board.rs:59-68`) with `project_id IS NULL` (`store/board.rs:170,177`).
- Post:
  - scrubbed with the owner's whole vault (`orch board.rs:87`);
  - goes through tenant `post_to_board` (`store/board.rs:125-155`);
  - takes a per-user lock `board/{user}` (`:126-129`);
  - applies the cap/archive with `project_id IS NULL` (`:131-140`);
  - the INSERT binds no `project_id` (`:142-153`).

**If only whitelisted: leak plus a stray write.**
- `board_read` from a project run returns the owner's private board.
- `board_post` writes a row that the 0056 trigger stamps with `p`: the worker-only check (`0056:26`) runs before the stamp (`0056:40`), so a tenant insert with a project `run_id` comes out as a project row. That row has `user_id` = owner, no cap, and is unread by anything.
- The owner-vault scrub at `board.rs:87` is a PIN-guessing oracle, the same class as the 8.16 `web_search` finding (`8.16-review.md:92-104`).

**What it must become:**
- Read: project posts of `ctx.project` only, written by any member or any member's agent.
- Write: as worker, after checking that the calling run is a live project run of `p` on a live dedicated agent.
- Cap and lock per project (`project_board/{p}`), not per user.
- Scrubber empty for project runs (8.18 adds granted items).
- The `UNTRUSTED` notice (`orch board.rs:30`) and the tool descriptions (`:186,199`) currently say "the user's agents"; reword for project members. A post written by a member in the App currently shows as "user" (`view`, `:129-134`); show the member's display name, or "former member" via the `authors()` map (`project_reads.rs:177-209`).

### `ask` (`ask.rs`)

**Today: same user.**
- Targets come from tenant `peers()` (`ask.rs:298-301`).
- The question is scrubbed with the owner vault (`:313-314`).
- Waits use a per-user lock `run_waits/{user}` (`:316-317`, `runs.rs:470-476`).
- `accepts_questions` re-checks `peer_access` (`:319`, `runs.rs:480-488`).
- The target must have a private grant (`:364-373`, `grants.rs:363-376`, which filters `project_id IS NULL` at `:369`).
- The child run sets `run_grant_id = None` (`:384`), `budget = parent.budget` (`:386`), and is created with `create_run(ctx.user, …)` (`:389-393`), so its `user_id` is the asker's owner.

**If only whitelisted: fails closed.** The `NewRun` has no `project_id`, so the child is private and `runs_parent_space` (`0045:14-15`) rejects it. A dedicated target has no private grant and gets "the user stopped it". Even with a grant, the executor would fail the child with "a project run needs its project grant" (`executor.rs:760-763`).

**What it must become:**
- The target is any live dedicated agent of `p`, across owners.
- The child is a project run with:
  - `user_id` = the target's owner;
  - `project_id = p`;
  - `run_grant_id` = the target agent's project grant (the answerer uses its own authority, as in 8.11);
  - the prompt locale of the target's owner (today it uses the asker's, `:336`).
- Use the project lock instead of `run_waits/{user}`. Recheck "target live" under it; withdraw and leave already take `project/{p}` through `project_actor` (`project_members.rs:341,370,460,524,549,669`).
- Skip the scrubber. The child's `prompt` is member-readable (`0054:25`), so a `[vault:…]` placeholder there is an oracle.

### `delegate` and `delegate_list` (`delegate.rs`), and the lead

**Today: team lead, private.**
- Targets come from `delegation_targets()` (`instances.rs:594-611`): the same user, the lead's solo projects only, excluding dedicated instances.
- The child grant comes from `create_child_grant(ctx.grant, target, &grant.scope)` (`delegate.rs:137-143`). `grants.rs:306-335` takes `user` from the parent (`:313`), copies `p.plan_id` (`:329`), and its `insert` (`grants.rs:150-174`) binds no `project_id`.
- `new.plan_id = parent.run.plan_id` (`delegate.rs:164`); the run is created with `create_run(ctx.user, …)` (`:169-173`).

**If only whitelisted: fails closed.** For a dedicated lead, `delegation_targets` returns only mixed instances and `is_team_lead` is false outside solo projects; even then the private child grant violates `run_grants_parent_space`.

**What it must become:**
- Only the live, dedicated `is_lead` agent of `p` (`project_one_lead`, `0039:68`) gets `delegate` and `delegate_list`. The executor's lead check (`executor.rs:784-789`) becomes `is_project_lead(p, instance)` for project runs, and the tool re-checks it at call time.
- Targets: any live dedicated agent of `p`, any owner.
- Child grant: `user_id` = target owner, `project_id = p`, `parent_id` = the lead's grant. Withdraw and leave still revoke it, because `revoke_project_agent_grants` and `revoke_project_member_grants` match on `instance_id`/`user_id` and descendants (`grants.rs:234-291`). The lead's revocation is enforced by `ancestors_usable` at token touch, which runs as worker (`auth/src/grants.rs:113-116`, `grants.rs:47-55`).
- Scope: the lead's scope ∩ the target's project grant (the full intersection is 8.18).
- `delegate_list` (`delegate.rs:61-70`) shows precise states such as `waiting_approval` or `waiting_quota` for another owner's run. Show the coarse state instead.
- Missing endpoint: shared projects have no way to set a lead today. Leads are set only in tenant solo-project writes (`store/projects.rs:376-403`). Add `PUT /v1/projects/{id}/lead`, creator only via `ProjectActor::require_creator`, target live and dedicated.

### `schedule_*` (`tools.rs` `ScheduleTools`)

**Today:**
- `list` is a tenant `plans(Some(ctx.instance))` (`tools.rs:198-219`; `plans.rs:141-152`, which has no space filter).
- `create` (`:221-270`) does tenant `create_plan`, then `create_plan_child_grant` (`grants.rs:87-120`: user from the parent, no project), then confirmation (`:164-196`) through `notify_tenant`, which notifies the owner.

**If only whitelisted: fails closed.** The `plans_instance_space` trigger (`0055:160-161`) rejects an active plan on a dedicated instance and the error surfaces as an internal error.

**What it must become:** either lead-only project plans that wait for the creator's confirmation (the notice goes to the creator, not the owner), or keep `schedule_*` out of `PROJECT_RUN_TOOLS` in 8.17. Decision needed (see §6).

### Pipelines and the scheduler

**Today, scheduler:** `scheduler.rs:110-208` creates `create_run(d.user_id, …)` (`:184`). `due_triggers` (`plans.rs:616-667`) has no space awareness.

**Today, pipeline driver:**
- `due_pipelines` filters `project_id IS NULL` (`runs.rs:1723-1736`, `:1728`).
- Steps get `create_child_grant` from the root's grant (`pipeline.rs:260-278`), `plan_id = root.plan_id` (`:290`), and `create_run(root.user_id, …)` (`:295`).
- `HandoffCopier` needs `plan_id` on step runs (`pipeline.rs:472-476`).
- `plan_steps` has an `(instance_id, user_id)` FK to `instances` (`0002:66-67`), and `private_target_not_dedicated` (`0055:70-81,158-159`) rejects steps on dedicated instances.

**What it must become:**
- Project plans and steps whose `instance_id` can belong to another owner.
- `due_pipelines` gains `isolated!` and `live_space!`. The root must be anchored on an instance dedicated to `p`, because `isolated!` requires it.
- Steps go through the dispatcher.

**Rollout hazard (inferred):** if project plans live in `plans`/`triggers`, an old (8.16) scheduler would fire them as private runs on a dedicated instance. `space_matches_instance` (`0055:57-68`) raises, `fire` returns `Err`, and the whole tick batch rolls back, stalling every user's schedules. This is the same class as the 8.16 high finding on pipelines. Prefer a separate `project_triggers` table (or separate project plan tables), or a rollback rule: pause project plans before any downgrade.

## 2. Cross-owner run trees

### Foreign keys that block a child run or grant owned by another user

| Constraint | Location | Effect today | Change |
|---|---|---|---|
| `runs (parent_run_id, user_id) → runs` | `0001:254` | Blocks cross-owner children | Drop (deploy-safe) |
| `run_grants (parent_id, user_id) → run_grants` | `0001:174` | Blocks cross-owner child grants | Drop |
| `runs (plan_id, user_id) → plans` | `0001:252` | Breaks a cross-owner delegate child (`delegate.rs:164`) and pipeline step (`pipeline.rs:290`) | Replace with `(plan_id) → plans(id) ON DELETE SET NULL (plan_id)`. `HandoffCopier` needs `plan_id` on steps. |

**Keep:**
- `runs (instance_id, user_id)` (`0001:251`) and `(run_grant_id, user_id)` (`0001:255`): the child row carries the target owner.
- `events (run_id, user_id)` (`0001:283`), `approvals` (`0001:344`), `artifacts` (`0002:88`), `board_posts` (`0025:22`): each child writes its own rows on its own instance, and `append_event` takes `user_id` from the instance (`events.rs:47-52`).
- `runs_project_agent (project_id, instance_id, user_id)` (`0045:6-7`): checks the child's own owner.

**Private trees stay same-owner after the drop.** `runs_parent_space` and `run_grants_parent_space` (`0045:12-15`) require equal `space_id`, and a private row's `space_id` is its `user_id` (`0040:23-24`).

**Delete action of `runs_parent_space` (CASCADE):** can be kept, and the reason should be recorded in the migration.
- Users rows are never hard-deleted.
- Erase deletes only private runs (`users.rs:292`).
- Project runs go only through the purge, which deletes newest first (`project_lifecycle.rs:350-352`).

### Code that hard-codes "same owner"

- `insert_run` (`runs.rs:274-322`) binds no `project_id`. Add `NewRun.project_id` (worker only, as `fill_space` already enforces at `0040:19-22`) and copy the parent's `project_id` when a parent is given.
- `create_run(ctx.user/root.user_id, …)` must take the target's owner: `ask.rs:390`, `delegate.rs:170`, `pipeline.rs:295`.
- `create_child_grant` and `create_plan_child_grant` take the user from the parent (`grants.rs:313,108`), and `insert` sets no project (`grants.rs:150-174`).

### Problems that appear once trees cross owners

- **Results message:** the resume message names children through a tenant `t.instance(child.instance_id)` (`executor.rs:822-831`), so another owner's agent gets an empty name. `results_message` includes 300 characters of the child's `error` (`delegate.rs:238`). For another owner's child, use member-visible names and a coarse outcome only.
- **Old executors (inferred):** an 8.16 replica claiming the parent would still leak that error text. Either the claim fence or the dispatch switch must also exclude 8.16 binaries; see P2.
- **Shared budget:** `tree_tokens_except` sums every owner's runs (`runs.rs:1341-1350`, used at `executor.rs:2424-2427`). Children inherit `parent.budget` (`ask.rs:386`, `delegate.rs:168`). So Bob's spending counts against Alice's root budget and vice versa. Count only the same owner in project trees until 8.18.
- **Cancelling a tree:** `cancel_run_tree`, `cancel_run` and `cancel_instance_runs` are tenant (`runs.rs:564-622,821-852`; route `gateway/routes/runs.rs:189-215`), so RLS hides other owners' descendants.
  - A parent cancelled while in `waiting_children` has no executor to run `cancel_descendants` (`executor.rs:1182-1188`), so delegated children of other owners keep running and their results are never delivered.
  - Asks already have a sweeper for this (`cancel_stale_asks`, `ASKER_GONE`, `runs.rs:1551-1578`). Delegates have none. Add one for terminal parents, and route project tree stops through the worker.
- **Artifacts:** they work across owners. `artifact_scope`, `tree_artifacts` and `run_artifacts` are worker reads keyed by `root_run_id` (`store/artifacts.rs:205-311`), and `root_run_id` has no FK. One caveat: `MAX_TREE_ARTIFACTS` (`artifacts.rs:153-161`) is shared, so one owner's agent can exhaust it.
- **Approvals** follow `run.user_id`, so the child's owner gets them. The "waiting for owner" display is 8.18.

## 3. Loop detection and limits

These already work across owners:
- `run_chain` (`runs.rs:1449-1464`) and `instance_waits_for` (`runs.rs:1524-1546`) are worker reads.
- The limits are per run: delegate `MAX_DEPTH` 3 and `MAX_CHILDREN_PER_RUN` 10 (`delegate.rs:27-29`); ask `MAX_DEPTH` 2 and `MAX_ASKS_PER_RUN` 5 (`ask.rs:264-267`); `ANSWER_TIMEOUT` 30 min.
- In projects only the single lead delegates, so in practice delegation is one level deep.

**Gap: the wait lock.** `lock_run_waits(ctx.user)` serializes per user. Alice's agent delegating to Bob's while Bob's agent asks Alice's takes two different advisory keys, so both checks can pass. In a project, use one key per project: either the `project/{p}` lock taken inside `project_actor`, or `run_waits/project/{p}`. The wait graph of `p` is closed, because dedicated instances only run `p`'s runs.

**Lock order:** follow 8.14 D3. Users `FOR KEY SHARE` (caller's owner, target's owner, creator), then the project lock, then the member row, then agent rows, then the calling run, then the INSERT (which takes `KEY SHARE` on the instance through `space_matches_instance`).

**No spending caps yet:** there is no per-owner cap until 8.18 (`projects.md:113`), so keep `cross_user_projects` off in production.

## 4. What the existing space-blind reads would expose once project rows exist

- **Board, if project posts go into `board_posts` with `user_id` = the author's owner:**
  - Pre-0056 (8.15) binaries read with no project filter, so the owner's own agents' project posts appear on the private board and in private `board_read`, and the 8.15 cap/archive counts them and archives them.
  - The new binary's `set_board_post_archived` (`store/board.rs:192-233`, only the count at `:211-213` filters) and `delete_board_post` (`:235-244`) work by id with no space filter. Through `/v1/board/{id}`, `/archive` and `/unarchive` (`gateway/routes/mod.rs:192-195`) an owner can archive or delete project posts.
  - Erase deletes them (`users.rs:335`), which breaks "content stays in the project" (`projects.md:53,109`).
  - The tenant policy (`0056:89-90`) only lets an owner see their own agents' project posts, so cross-owner reads through the tenant are impossible anyway.
- **Agents and runs:**
  - Dedicated instances are hidden by `workspace_project_id IS NULL` (`instances.rs:577-578`) and by the `peer_access` CHECK (also for 8.15 binaries).
  - If any project run were written on a mixed instance, 8.15's unfiltered `instance_holder` would show it to private peers. The dispatcher and the INSERT fence must require a dedicated target. `space_matches_instance` (`0055:63`) lets a project run onto a mixed instance (`ws IS NULL`).
- **`run_tree`** (`runs.rs:333-343`) has no space filter but is user-scoped by RLS: the owner sees a partial cross-owner tree, not a leak. The full tree for members is `project_run_tree` (`0054:44-54`).
- **Old binaries are already fenced elsewhere:** the event list, the runs list and the artifact list filter private only (`events.rs` around `:87,102`; `runs.rs:511,537`; `0054:143`).

## 5. Proposed changes

**Migrations (0060 onwards)**

- **P1. Cross-owner trees:**
  - drop `runs_parent_run_id_user_id_fkey` and `run_grants_parent_id_user_id_fkey`;
  - replace `runs (plan_id, user_id)` with a plain FK, `ON DELETE SET NULL (plan_id)`;
  - keep `runs_parent_space` CASCADE and document why.
- **P2. INSERT fence and dispatch switch:**
  - add `BEFORE INSERT ON runs WHEN (NEW.project_id IS NOT NULL)`: the dispatch switch row must be on, and the dedicated-versus-mixed level must hold (reuse `runs_isolation_fence`, `0055:137-151`; today it fires only on `UPDATE OF lease_owner`, `0055:166-167`);
  - also require a new worker GUC (for example `thinktin.protocol`, set in `Db::worker`, `lib.rs:166-177`) on lease and insert of project runs, so 8.16 binaries stop claiming them;
  - add `legacy_sessions()`: a definer function counting the server login role's sessions whose `application_name` is not the new `APPLICATION_NAME` (`lib.rs:110`).
- **P3. Project board.** Recommended: a separate `project_board_posts` table. Columns: `project_id`, `author_user_id`, `author_instance_id`, `run_id`, `by_agent`, `body`, `tags`, `created_at`, `archived_at`.
  - Permissions: no `thinktin_app` grants; worker writes; `thinktin_member` gets column grants and a `member_read` policy on `member_projects()`.
  - Lifecycle: survives erase; add a purge step next to `project_lifecycle.rs:341,400`.
  - Fence the private board: `CHECK (project_id IS NULL)` on `board_posts`, so the 0056 stamp cannot create private-board project rows.
  - If `board_posts` is reused instead: the tenant USING and WITH CHECK both become `project_id IS NULL`; add `AND project_id IS NULL` at `board.rs:202,224,236` and to `users.rs:335`; switch to a per-project lock and cap; old binaries' erase still deletes these rows.
  - Encryption: `projects.md:40` says the board is sealed with the project DEK. Bodies are plaintext today, as run prompts and events are. Decide.
- **P4. Agent fields:** add owner-written `project_agents.purpose`, member-readable. Add an activity function for `agents_list` (coarse state of the agent's current project run).
- **P5. Project plans:** use separate trigger and plan tables, or `plans.project_id` plus a separate trigger table. Steps may name any live dedicated agent of `p`. Agents can only propose plans; the creator confirms.

**Store**

- **S1. The dispatcher is the only writer of project runs:** `Tx<Worker>::dispatch_project_run(actor, target, NewRun)`.
  - It builds a `ProjectActor` (`projects.rs:84-182`), or an agent-actor variant: calling run live and in `p`; the caller's agent live; `is_lead` for delegate.
  - It checks the target's `project_agents` row is live and the instance is dedicated to `p`.
  - It issues or reuses the target's top-level project grant, and inserts with `user_id` = the target's owner.
  - It handles the cases where the target cannot take the run: `InstanceDedicated`, a withdrawn agent, a FK violation (23503).
  - Callers: the creator's App tasks, `ask`, `delegate`, pipeline steps, project plan fires, urgent project messages. A worker variant of `queue_urgent_run` is needed; today it is tenant (`runs.rs:644-746`).
- **S2. Grants:** `insert(…, project)`; `create_project_agent_grant`; `active_project_grant(p, i)`; `create_child_grant` copies `project_id`, takes the target's owner, and intersects scope.
- **S3. Project queries:** `is_project_lead(p, i)`; `ProjectTx` reads for peers, status and the board; worker `project_agent_names(p, ids)` for the resume message.
- **S4. Pipelines and budgets:** `due_pipelines` with `isolated!` and `live_space!`; same-owner `tree_tokens_except` for project trees.
- **S5. Sweeper:** cancel delegate children whose parent is terminal. Worker tree stop for project runs.

**Orchestrator**

- **O1. Branch every tool on `ctx.project`** and add the shared liveness guard.
  - Add `agents_list`, `agent_status`, `board_read`, `board_post`, `ask`, `delegate_list` and `delegate` to `PROJECT_RUN_TOOLS`.
  - `delegate` and `delegate_list` are lead only.
  - Add `schedule_*` only if P5 is done.
  - Update `space_tests`.
- **O2. Empty scrubber** for project runs in `board.rs:87` and `ask.rs:313`.
- **O3. Results message:** coarse outcomes with no `error` for other owners' children (`delegate.rs:228-267`); names come from S3.
- **O4. Executor lead check** per space (`executor.rs:784-789`).
- **O5. Pipeline driver and scheduler:** project paths through S1; `pipeline.rs:227-248` also maps "agent left or not dedicated" to failing only this pipeline.

## 6. Decisions for the user

1. **Teams as project runs.** Teams with mixed (non-dedicated) members cannot run project runs before level 2. Proposal: keep 8.7 private team delegation for mixed teams (`delegation_targets` already excludes dedicated instances), and use project delegation only between dedicated agents. A team that mixes dedicated and mixed botins cannot delegate across the two kinds.
2. **Project board storage:** separate table (recommended) or reuse `board_posts`; and whether bodies are sealed with the project DEK.
3. **Who owns a project pipeline root.** `runs_project_agent` needs `(p, instance, owner)` to be a project agent, and `isolated!` needs that instance dedicated to `p`. Design A says the pipeline root belongs to the creator (`projects-design-A.md:1205`), but a creator who has no dedicated agent in `p` has nowhere to anchor it. Alternative: anchor on the lead and add a `runs.requested_by` column for the creator.
4. **`schedule_*` in project runs:** lead-only proposals confirmed by the creator, or deferred.
5. **Budgets:** until 8.18, a cross-owner child inherits the parent's tree budget; count per owner from now on, or accept and document.

## Map: lead-teams

# 8.17 research: the lead agent and teams

Teams need no change to keep working, and the lead in 8.17 needs to be split by run space. Today every team run is a private run (`project_id IS NULL`). Team agents are mixed instances, and their project runs can never be claimed before level 2. So **team runs must stay private runs**. Making team agents dedicated is not an acceptable default (§6). The project lead in 8.17 only works for dedicated agents inside project runs. The current private team delegation stays as it is. No files were modified.

## 1. Product rules on the lead

- `docs/projects.md:18`: the creator, plus a lead agent he designates, dispatches project tasks, builds pipelines and delegates. Other owners only control their own agents.
- `docs/projects.md:37`: `ProjectAgent` holds "是否负责人".
- `docs/projects.md:42`: teams become one-user projects. "流水线和委派的范围从'团队'改成'项目'".
- `:46`: a lead can be named when the project is created. `:52`: the creator can "更换负责人".
- `:74`: mixed agents get no warning in a user's own project. This implies solo-project mixed agents are meant to keep working normally.
- `:80`: the lead uses `delegate` towards any member agent (不分主人).
- `:82`: a run tree's shared budget is counted per owner inside a project.
- `:86` interrupts:
  - the creator can interrupt any project run;
  - an owner can interrupt his own agent;
  - the lead can interrupt members working for it.
- `docs/architecture-v3.md:429`: the lead may interrupt its members. `:434`: that is not done yet, even for same-user teams.
- `docs/wbs.md:221`: 8.18 owns "打断规则".
- `docs/projects-impl.md:13` and `:20`: the creator and the designated lead dispatch. The worker checks creator or lead through `ProjectActor`.
- `docs/projects-impl.md:92`: 8.14 left "跨用户换负责人（8.17）".
- The adopted design is A. On the lead:
  - `projects-design-A.md:957`: in private runs, delegation stays private and own-agents-only. In project runs, only the lead of **that** project gets it, targets are any live project agent, and members cannot re-delegate.
  - `:1154-1158`: migrated team runs without `project_id` keep the private session. `is_lead` stays a boolean, at most one per project, not mandatory.
  - `:960`: split `is_team_lead`.
  - `:961-962`: say whose agent it is in `delegated_task`, and mark returned results as untrusted.
  - `:963-967`: make the run-waits lock global.
  - `projects-design-C.md:1151` agrees on private sessions for team runs.
  - `projects-8.13-code-map.md:873` says the same.

## 2. Data: `project_agents.is_lead`

**Schema.**
- `0039_projects.sql:54` adds `is_lead`. `:65` has `CHECK (left_at IS NULL OR NOT is_lead)`. `:68` has the unique index `project_one_lead … WHERE is_lead AND left_at IS NULL`.
- The backfill (`0039:131-132`) sets it from `team_members.role='lead'` for non-deleted instances.
- An instance may sit in several projects, because the primary key is `(project_id, instance_id)` (`0039:56`). Only dedicated rows are unique per instance (`0039:69`).

**Who can write it.**
- The tenant can insert and update `is_lead` (`0039:220-221`), but only in its own never-shared, non-deleted project (`0049:110-119`; `0055:31-34`).
- Once a project is shared, no code path can set a lead:
  - worker `place_agents` inserts the default `false`, and a rejoin resets it (`project_members.rs:305`);
  - withdraw, leave, remove and erase clear it (`project_members.rs:511,631,743,783`);
  - so do instance delete (`instances.rs:417`) and `stop_project` (`project_lifecycle.rs:76`).
- In a shared project, therefore, only an old creator-owned lead from before sharing can exist. No member's agent can become lead.

**Who sees it.**
- Members see `is_lead` (`0049:84`; `project_reads.rs:445-462`; `ProjectAgentView.is_lead` at `proto/src/domain.rs:1073`).
- `ProjectActor` (`store/src/projects.rs:82-107`, built at `:137-183`) only covers human actors (role creator or member). It has no lead or agent-actor form.

## 3. Team lead behaviour today

**Gating in the executor.**
- `executor.rs:783-789`: `lead = grant has delegate tools && is_team_lead(instance)`.
- `:863`: the delegate tools are dropped unless `lead`.
- `:864`: `allowed_in_space` removes them from every project run, because `PROJECT_RUN_TOOLS` (`tools.rs:454-460`, `:463-464`) holds only `artifact_*` and `web_search`.
- `:815-817` and `:853-856`: `has_computer` is per user. Computer tools are also cut from project runs by `:864`.
- The default grant includes `DELEGATE_TOOLS`, `PEER_TOOLS`, `BOARD_TOOLS` and `ASK_TOOLS` (`server/src/config.rs:154-168`). So every private grant carries delegate, and `is_team_lead` is the real gate.

**`is_team_lead`** (`store/src/instances.rs:617-627`, worker).
- It requires a live `is_lead` row in an active project whose `creator_id` is the agent's owner.
- It does not check `shared_at` or dedication. A creator's lead in a project that later became shared still gets private delegate tools.
- Tested at `store/src/tests.rs:1611,1674-1675,1703`.

**`delegation_targets`** (`instances.rs:593-612`, tenant).
- Targets are the user's own non-deleted, **non-dedicated** instances (`workspace_project_id IS NULL`, line 600).
- They are the union across every active project that the lead leads and the user created. There is no single team scope.

**The `delegate` tool** (`orchestrator/src/delegate.rs`).
- The module header (`:1-10`) describes it as team-only, same user.
- Lookup is by name or id (`:75-97`). The error message is "only the lead of a team can delegate" (`:83-85`).
- Locking and guards:
  - `lock_run_waits(ctx.user)` is a per-user advisory lock (`:101`; `runs.rs:470-476`);
  - depth is at most 3 (`:103-112`); `MAX_DEPTH` is at `:27`;
  - the target must not be on the run's chain (`:113-118`) and must not be waiting for this run (`:120-129`; `runs.rs:1524-1538`);
  - at most 10 children per run (`:130-133`).
- The child grant comes from `create_child_grant(ctx.grant, target, same scope, 7 days)` (`:137-143`). That function (`grants.rs:306-335`, writing through `insert` at `grants.rs:150-174`) never binds `project_id`.
- The prompt is `texts::delegated_task(locale, lead=rt.agent_id, title, task)` (`:144-156`). Note that `lead` is the agent kind (for example `claude`), not the botin's name.
- The child itself:
  - `source=Delegate`, `parent_run_id=ctx.run`, same `plan_id`;
  - `new.budget = parent.budget` (`:157-168`); ask copies it the same way (`ask.rs:153`);
  - written with `w.create_run(ctx.user, …)` (`:169-173`);
  - event `delegate.started` (`:174-181`).
- `InstanceDedicated` maps to a friendly refusal (`:201-209`).

**Results going back to the lead.**
- `executor.rs:819-838` names each child through `db.tenant(rec.user_id).instance(child.instance_id)`, falling back to `unwrap_or_default()`. With a cross-owner child the name would silently be empty.
- Then `delegate::results_message` (`delegate.rs:228-267`) calls `texts::children_results` (`texts.rs:656-750`).
- Only the "ask" header calls the answers untrusted (`texts.rs:670-679`). The delegated-results header (`:663-667`) does not.

**Tests that pin the team semantics:**
- `orchestrator/tests/executor.rs`: environment setup at 2001-2038, plus 2048, 2111-2133 (one instance leads one team and is a member of another), 2215-2237, 2240 and 2308;
- `store/src/tests.rs:1559-1706`;
- client-core `ffi_teams_and_templates`, per the 8.13 plan at `:683`.

## 4. Teams, templates and adoption

**Team API.**
- `/v1/teams*` (`gateway/routes/teams.rs`) is a tenant view over solo projects (`store/src/teams.rs:1-82`).
- Updating or deleting a team that has been shared returns 409 (`teams.rs:1-2`; delete goes through `orchestrator::projects::delete` at `:99-112`).
- The `Team` and `TeamMember` types (`domain.rs:1009-1021`) have no `dedicated` field.

**Templates.**
- `project_templates` (`0039:108-116`) stores `TeamTemplateSpec { members: [TemplateMember { agent_id, harness, name, role }] }` (`domain.rs:1335-1360`). There is no "dedicated" flag.
- Adopting a template (`teams.rs:216-258`) runs in one tenant transaction:
  - it creates **private, mixed instances** with `control::adopt_in`;
  - for each it creates a **private** grant with `create_run_grant(instance, None, default_scope)` (`:243-244`);
  - then `create_team`.
- `/v1/project-templates/{id}/adopt` (`:202-214`) does the same adoption and returns the project detail instead.

**Solo projects through the projects API.**
- `POST /v1/projects` only accepts existing, non-dedicated botins, with `is_lead` allowed only here (`routes/projects.rs:63-81,160-178`).
- `POST /v1/projects/{id}/agents` can adopt or dedicate an agent, even in a solo project (`:289-315`; `project_members.rs:223-245`). Dedicating does three things (`project_members.rs:233-241`):
  - wipes the workspace;
  - revokes private grants;
  - requires that the instance has no live rows in other projects (`0055:116-135`).
- `PATCH /v1/projects/{id}/agents/{i}` dedicates an agent (`:327-350`). 8.16 explicitly allows dedicating a member to its own team (plan V13/A1, `projects-8.16-plan.md:27,855,1053`).

## 5. Current data: team runs are private runs with `project_id NULL`

All of the following hold:

- `NewRun` has no project field (`store/src/runs.rs:21-48`).
- `insert_run` never binds `project_id` (`runs.rs:274-320`).
- `fill_space` (`0040:7-25`) sets `space_kind='private'` and refuses any `project_id` from a non-worker role.
- Team adoption grants are private (`teams.rs:243`). Delegate and ask children are private (`delegate.rs:169`; `grants.rs:325-333`).
- `runs_parent_space` and `runs_grant_space` (`0045:12-17`) force parent, child and grant into the **same space**. A private lead run therefore cannot have a project child.
- The old same-owner foreign keys are still in place: `runs (parent_run_id, user_id)` (`0001:254`) and `run_grants (parent_id, user_id)` (`0001:174`). `0040:4` says 8.17 drops them for cross-owner trees.
- Pipelines are private too:
  - plan steps cannot target dedicated instances (`0055:69-81`, "计划的步骤总是私人的", trigger at `:158`);
  - active plans cannot run on dedicated instances (`0055:83-96`);
  - `due_pipelines` filters `project_id IS NULL` (`runs.rs:1723-1736`);
  - plans are per user, not per team (`store/plans.rs:121-128,254-271`).
- Nothing in production code writes project runs or project grants (8.16 plan D1, Appendix B). Executor start fails any project run that has no grant (`executor.rs:752-765`).
- There is no live data (`0039:6-8`; `projects.md:42`).

## 6. What happens if team runs became project runs

**On mixed instances they would never run, and team flows would stall.**
- The claim requires `isolated!`, meaning `instances.workspace_project_id IS NOT DISTINCT FROM r.project_id` (`runs.rs:361-371`, used at `:1149`).
- The fence `runs_isolation_fence` needs level 2 for mixed instances, and no binary declares it (`0055:137-151`, trigger at `:166`).
- Takeover and expired waits use the same macros (8.16 D9). The sweeper only cancels runs that are no longer live (D12).
- So a live project run on a mixed agent would stay queued for ever.
- Because of `0045`, the lead's tree would have to be entirely project runs. A mixed lead's project root would never start.

**A "same owner" exception for never-shared projects is unsafe** (the question raised at `projects-8.16-plan-draft.md:987`).
- Those runs would carry `project_id`.
- Once the project is shared, members read project runs and events through the 0054 functions.
- Earlier runs made with mixed memory would become member-visible.

**Forcing team agents to be dedicated is not acceptable either.** Dedicating:
- wipes memory and files;
- revokes private grants;
- removes the agent from every other team (`instances_dedicated_alone`);
- blocks private messages: the route returns 409 (`routes/runs.rs:42-46`) and the trigger backs it (`0055:57-68`);
- hides the agent from peers (`peer_access` CHECK, `instances.rs:576-577`).

**Existing gaps today.**
- A team member dedicated to its team is listed by `GET /v1/teams` (`store/teams.rs:31-52`), but:
  - it is not a delegation target (`instances.rs:600`);
  - it cannot receive private messages;
  - it gets no project runs, because nothing writes them.

  It is dead weight until the 8.17 dispatcher exists.
- A dedicated lead gets no delegation at all. It runs no private runs, and project runs filter `delegate` out (`tools.rs:463`).
- In a shared project whose lead is the creator's mixed agent, the lead still delegates privately, but only to the creator's own mixed agents. It can never reach members' agents, which are dedicated and in another space.

## 7. Project context an agent receives today

- **There is none.** No project name, goal, member list, lead, or board is given to project runs.
  - Project goal (`0039:20`, at most 4000 characters) is never read by the orchestrator. The only "goal" is a plan goal, in pipeline handoff notes (`pipeline.rs:421-429`; `texts.rs:865-868`).
  - The prompt is assembled at `executor.rs:1718-1757`, using only the interrupt or announced preface and the resume note.
- The MCP instructions are static (`agent-shim/src/bridge.rs:39-41`, applied at `:540-545`). They mention "delegation, the user's other agents, their shared board", which is wrong for project runs.
- `ShimLaunch` carries no project field (`executor.rs:877-886`).
- Agent-facing texts in `orchestrator/src/texts.rs`, all written for same-user teams:
  - `delegated_task` (`:605-617`, "团队负责人（{lead}）");
  - `ask_question` (`:628-643`, "你的队友");
  - `children_results` (`:656-750`);
  - `interrupted` (`:757-769`);
  - `announced` (`:772-784`);
  - `interrupted_work` (`:787-794`);
  - `new_messages` (`:797-812`);
  - `resume_note` (`:499-556`, which mentions `delegate_list` and asks).
- These notes appear in user-visible conversations (`texts.rs:495`). The user-facing project receipts already say "botin" (`:236-336`).
- `delegate.started` is not in the member event whitelist `PROJECT_RUN_EVENT_KINDS` (`domain.rs:1312-1323`). Members would not see a project delegation unless 0054's functions and that constant change.

## 8. Urgent and interrupt rules today

- `queue_urgent_run` (`runs.rs:644-746`) is `Tx<Tenant>`, so it cannot write project runs (`fill_space`).
  - It chooses the run currently holding the instance without regard to space (`:663-676`). This is a level-2 prerequisite (8.16 §8) and harmless at level 1, because a dedicated instance has only one space.
  - It cancels the holder's tree under tenant RLS (`:710-736`), which would miss other owners' children.
- The claim gives urgent runs precedence per space (`runs.rs:1163-1165,1183-1192`).
- Piggybacked messages stay within one space and only take `source='user'` (`runs.rs:1487-1504`; `executor.rs:1531-1538`).
- `interrupt_pending` keys only on `interrupts_run_id` (`runs.rs:1476-1484`).
- The interrupt preface does not quote other agents' text (`executor.rs:795-813`).
- The private message route refuses dedicated botins (`routes/runs.rs:42-46`).
- So a project run cannot be interrupted at all today, and "lead interrupts a member" does not exist.
- `known_sources()` (`runs.rs:209-211`) means a new `RunSource` is never claimed by old binaries.

## 9. Proposal

**How teams keep working (no change):**
- Mixed team agents keep private runs and private delegation: `is_team_lead`, `delegation_targets` and `delegate.rs` stay as they are.
- `/v1/teams*`, Team FFI, templates and adoption (mixed instances with private grants) stay as they are.
- The 8.16 §8 item "team runs as project runs" should be resolved as **"only for dedicated agents"**. A solo project's dedicated agents get project runs from the dispatcher, exactly like a shared project. Mixed agents never do before level 2.
- Optional:
  - add `#[serde(default)] dedicated` to `TeamMember`, so the App can show which members a mixed lead cannot reach;
  - document that a mixed lead and dedicated members cannot work together (the `0045` same-space rule).

**What the lead does in 8.17 (project runs only):**

1. **Setting the lead.** Add a creator-only worker write, for example `PATCH /v1/projects/{id}/agents/{i}` with `{is_lead}`, or `PUT /v1/projects/{id}/lead`.
   - Use `ProjectActor` plus `require_creator`. Clear the old lead, then set the new one in the same transaction, which `project_one_lead` requires.
   - The target must be a live agent with a live owner-member.
   - In a shared project, require the lead to be dedicated (409 `agent_not_isolated` otherwise). In a solo project, allow any agent, for team compatibility.
2. **Dispatch to the lead.** The creator's project task, for example `POST /v1/projects/{id}/runs` with `to` defaulting to the lead, is written by the dispatcher.
   - `user_id` = the target's owner, plus the project grant.
   - Writes happen only to dedicated, live targets, behind the DB switch.
   - Consider a new `RunSource` such as `project`, which old binaries will not claim.
3. **Lead check by space.** At `executor.rs:784-789`:
   - private runs keep `is_team_lead`;
   - project runs use a new `is_project_lead(instance, project)`: a live `is_lead` row, a live owner-member, an active project, and the instance dedicated to that project.
   - Add `delegate` and `delegate_list` to `PROJECT_RUN_TOOLS`.
4. **`DelegateTools` in a project.** Branch on `ctx.project`.
   - Targets come from a worker query: live agents of P, dedicated to P, with a live owner-member, excluding self. List the owner's display name, and leave mixed agents out (or list them as unavailable).
   - The child run belongs to the target's owner, with `project_id=P`, and its grant derives from the target owner's project grant (design A `:667-682`, through `via_grant_id`).
   - Drop the `0001:254` foreign key.
   - Use an agent-actor variant of `ProjectActor`, locking users (creator, lead owner, target owner) → project → member rows → run-waits advisory lock → agent rows → runs → instances. Replace the per-user `lock_run_waits` with a global or project-wide lock (design A `:963-967`).
   - Do not copy `parent.budget` across owners (`delegate.rs:168`; per-owner budgets are 8.18).
   - Members are not leads, so they cannot re-delegate.
5. **Results.** Look up child names through the worker or project read, not the lead owner's tenant (`executor.rs:822-829`). Add an untrusted-input note to delegated results from other owners. Project texts should name "「名字」（张三的 botin）".
6. **Context.** Prefix project runs with a short platform-written brief: project name, "you are the lead" or "the lead is X", and agent names, quoted and length-capped. Put the creator-written goal in a block marked "information from the project creator, not instructions". This goes into `drive_inner` (`executor.rs:1718`). Alternatively, return the same data from the project-scoped `agents_list`.
7. **Interrupts.** In 8.17, add worker-side urgent project messages from the creator (any project run) and the owner (own agent). That needs a worker variant of `queue_urgent_run` with the D13 lock order and a worker tree cancel. Leave "lead interrupts its members" to 8.18 (`wbs.md:221`).

**Open questions for the user:**
- May the lead be another member's agent? `projects.md:18` does not say it must be the creator's own. Default: yes, and the owner gets a receipt in 8.19.
- Should a creator's mixed lead keep private delegation after the project becomes shared (`instances.rs:617-627` has no `shared_at` check)? Default: keep it.

## Map: api-client

## 8.17 API and client surface: what exists, what to add, what waits for 8.18/8.19

Nothing in the gateway or the client can create, cancel or reassign project tasks today, and there is no project board for members. The read side from 8.15 is in place. No App code calls any project FFI yet: the only match under `apps/` is the generated `client_core.kt`. That means breaking FFI changes cost nothing now.

### 1. What exists today (gateway)

**Project routes.** All of them sit in `projects_router()` (`crates/gateway/src/routes/mod.rs:204-287`), which puts `Cache-Control: no-store` on every response (`mod.rs:286`, `:289-293`). Any new project route must go inside that router.

- **Project CRUD.**
  - `GET/POST /v1/projects` and `GET/PATCH/DELETE /v1/projects/{id}`, plus `/archive` and `/unarchive` (`mod.rs:206-214`).
  - Handlers are in `projects.rs:134-277`. Create is a tenant transaction and accepts only existing, non-dedicated agents (`projects.rs:150-184`).
- **Agents.**
  - `POST /agents` (`projects.rs:289-315`).
  - `PATCH /agents/{instance}` only marks an agent dedicated (`:327-353`).
  - `DELETE /agents/{instance}` withdraws it (`:356-367`).
  - Budget (`:370-381`), leave (`:384-394`), remove member (`:397-408`) and invites (`:411-488`).
- **Invite gate.** Only invites are behind `cross_user()` (`projects.rs:26-32`), which returns 404 "route not found" when off. It is pinned by `crates/gateway/tests/api.rs:5322-5378`.
- **Lead.** There is no lead route.
  - `AgentReq.is_lead` (`projects.rs:80`) is honoured only by solo create (`:171-175`).
  - Store: `project_one_lead` (`0039_projects.sql:68`), `CHECK (left_at IS NULL OR NOT is_lead)` (`0039:65`).
  - Withdraw, leave and remove clear `is_lead` (`store/src/project_members.rs:511,631,743,783`).
  - No worker function sets a lead. "Changing the lead across users (`PUT /v1/projects/{id}/lead`)" was deferred to 8.17 (`drafts/projects-8.14-plan.md:832`, `drafts/projects-8.15-plan.md:1306`).
- **Member reads** (`project_runs.rs`, member transaction only; the module doc says "成员只读", `:1-2`):
  - `GET /v1/projects/{id}/runs?instance_id&before&limit` (`:33-57`);
  - `GET /runs/{run_id}`, `/runs/{run_id}/tree`, `/runs/{run_id}/events?limit` (`:59-108`);
  - `GET /artifacts`, `/artifacts/{a}`, `/artifacts/{a}/content` (`:117-172`);
  - nothing on this surface writes.
- **Teams.** `/v1/teams*` (`teams.rs`) is tenant-only. Shared projects are read-only through it and edits return 409 (`teams.rs:1-2`). Adopting from a template issues **private** grants to the team's instances (`teams.rs:243-244`).
- **Private runs** (`runs.rs`).
  - `POST /v1/instances/{id}/runs` refuses dedicated botins with 409 `instance_dedicated` (`runs.rs:43-46`). It checks the prompt is 1–32000 characters (`:38`) and scrubs the owner's vault (`:40`). `delivery: "interrupt"` uses the tenant-only `queue_urgent_run` (`:49-65`, store `runs.rs:644`).
  - `POST /v1/runs/{id}/cancel?tree=` is a tenant transaction (`runs.rs:189-225`).
- **Private board.** `/v1/board*` (`mod.rs:192-195`, `board.rs`) is tenant-only. Writes scrub the vault (`board.rs:72`).
- **Errors.**
  - `ErrorCode` and HTTP statuses: `proto/src/api.rs:38-109`. `instance_dedicated` and `agent_not_isolated` are 409.
  - `From<store::Error>`: `gateway/src/error.rs:67-108`. `NotPermitted` gives 403; `InvalidTransition` gives 409 conflict.
  - `project_error` turns a DB `Forbidden` into a counted 404 (`error.rs:112-121`).

### 2. The 8.15 member read model (what 8.17 extends)

- **Roles and visibility.**
  - `Db::member` runs as `thinktin_member`, read-only (`store/src/project_reads.rs:1-5`, `:82-174`).
  - Visibility follows `member_projects()` (`0049:45-63`). Grants are column-level (`0049:81-98`).
  - There is **no member grant or policy on `board_posts`**. Only `0025`, `0028`, `0056` and `0058` touch that table.
- **Definer functions** (`0054_project_scoped_reads.sql`):
  - `project_run`, `project_run_tree` and `project_runs(p_project, p_instance, p_before, p_limit)` are at `:34-68`, each with one fixed WHERE.
  - The state is coarsened by `project_run_state` (`:14-21`): waiting on approval, quota or device all become `waiting_owner`.
  - Event projection is in `project_run_events` (`:71-114`). Grants and owner are set at `:115-125`; the artifact member policy at `:128-130`.
- **Event whitelist** (`PROJECT_RUN_EVENT_KINDS`, 10 kinds, `proto/src/domain.rs:1312-1323`). Member-facing names: `tool_call`, `tool_call_update`, `message`, `plan`, `turn_started`, `turn_ended`, `state`, `log_truncated`, `artifact`, `step_started`. It is pinned in three places:
  - `store/src/tests/boundary.rs:986-989`, which reads only the 0054 file;
  - account erase, which keeps only these kinds (`store/src/users.rs:258-265`) and re-projects their fields (`users.rs:277-290`);
  - the FFI doc (`client-core/src/ffi.rs:1239-1242`).
- **Not projected today.** The collaboration events `ask.sent` (`{child_run_id, instance_id, to, question}`, `orchestrator/src/ask.rs:164-170`), `delegate.started` (`{child_run_id, instance_id, to, title}`, `delegate.rs:177-178`) and `board.posted` (`{post_id, tags}`, `board.rs:112-113`).
- **`ProjectRunFilter`** has only `instance`, `before` and `limit` (`project_reads.rs:21-27`). There is no `roots` or `active` filter, unlike the private `/v1/runs` (`runs.rs:124-134`).
- **`ProjectRun`** (`domain.rs:1251-1273`) has no `requested_by` or initiator field. `RunSource` is user / plan / pipeline / delegate / ask (`domain.rs:223-231`), and the DB CHECK matches (`0026_ask.sql:7`). Run authors come from `authors()` as member, left or erased (`project_reads.rs:177-209`).
- **Tenant visibility of the owner's own project rows.**
  - The owner sees their own project runs and can cancel them through tenant policies while a live member (`0054:135-142`).
  - The private lists exclude project runs: per instance (`store/runs.rs:511`), `/v1/runs` (`:537`) and the instance event stream (`store/events.rs:88,102`).

### 3. Latent problems 8.17 must handle (API side)

1. **The private board's single-post operations ignore projects.** These are the "space-blind" reads 8.16 §8 warns about.
   - Lists filter `project_id IS NULL` (`store/src/board.rs:170,177`).
   - But `board_post(id)` (`:157-163`), `set_board_post_archived` (`:192-233`) and `delete_board_post` (`:235-244`) do not.
   - The tenant policy shows project rows to their owner while a live member (`0056:89-90`). So once project posts exist, `POST /v1/board/{id}/archive|unarchive` and `DELETE /v1/board/{id}` would act on the owner's project posts. Unarchive would also apply the private 200-post cap.
   - Fix: add `AND project_id IS NULL` to those three, or apply 8.16's alternative and hide project rows unless `thinktin.isolation` is set.
2. **Erase deletes every board post.** `DELETE FROM board_posts WHERE user_id = $1` (`users.rs:335`) also removes posts in other people's projects. `projects.md:109` says those stay, with the author shown as erased. Needs `AND project_id IS NULL`.
3. **Vault scrubbing leaks item names.** It replaces secrets with `[vault:<item name>]` (`routes/vault.rs:76-82`, `client.rs:401-412`). In a project prompt or board post the item name becomes visible to other members, though the vault is listed as private (`domain.rs` `KEPT_PRIVATE`). Use an unnamed placeholder for project-visible text.
4. **Cancelling a tree only reaches the caller's own rows.**
   - `cancel_run_tree` runs under tenant RLS (`store/runs.rs:599-622`), so once trees span owners, `/v1/runs/{id}/cancel?tree=true` silently skips other owners' rows.
   - The private `/v1/runs/{id}/tree` (`routes/runs.rs:227-238`) also returns only the owner's rows. Project trees must use `/v1/projects/{id}/runs/{r}/tree` (definer `0054:44-54`).
   - Cross-owner children are blocked today by `FOREIGN KEY (parent_run_id, user_id)` (`0001_init.sql:254`).
5. **The schema blocks project pipelines.**
   - `plan_steps` has `FOREIGN KEY (instance_id, user_id)` and `(plan_id, user_id)` (`0002_collaboration.sql:66-67`), and runs have `(plan_id, user_id)` (`0001:252`).
   - The pipeline driver reads steps from `plan_steps` of the root's plan (`orchestrator/src/pipeline.rs:97`, `:482`).
   - Active plans cannot use dedicated instances (`0055:83-92`, `:158-161`).
   - So a project pipeline needs a project-owned plan or step store before any App route can exist.
6. **Mixed instances never take project runs.** That includes solo projects, i.e. the old teams (`projects-impl.md:168-170`). A creator's mixed agents can also remain in a project that later becomes shared (8.16 plan §8, level-2 prerequisites). So dispatch must check `dedicated` per target, and the App needs `ProjectAgentView.dedicated` (`domain.rs:1080-1081`) to grey out "assign".
7. **`NewRun` has no project field** (`store/src/runs.rs:21-48`). A project run's `project_id` can only be written by the worker (trigger, `projects-impl.md:45-46`). The gateway must go through a worker/dispatcher function, not `Tx<Tenant>::create_run` (`runs.rs:493-499`).

### 4. Endpoints to add

All of these go in `projects_router` (inherits `no-store`) and are **not** behind `cross_user()`, because solo projects need them too. Writes run in a worker transaction through `ProjectActor` (`store/src/projects.rs:84-104`, `project_actor` at `:137`, allow `[Active]` so archived projects give 404 on writes). Shared status rules:

- not a member, project deleted or archived (writes) → 404;
- member calling a creator-only route → 403 `forbidden`;
- bad body → 422 `invalid`;
- DB-level refusal → 404 via `project_error`.

**Tasks**

- **`POST /v1/projects/{id}/runs`** (creator only, `projects.md:18,80`)
  - Body: `{"prompt": "…", "instance_id": "<uuid>"?, "delivery": "queue"|"interrupt"?}`
  - Behaviour:
    - `instance_id` omitted means the task goes to the lead.
    - The prompt is 1–32000 characters, scrubbed against the creator's vault with an unnamed placeholder.
  - Returns **201 `ProjectRun`**, re-read in a member transaction, since the creator may not own the target agent.
  - Errors:
    - 422 if there is no lead and no `instance_id`, or if the instance is not a live agent of this project (same convention as "picked someone else's or a deleted agent", `projects-impl.md:108`);
    - 409 `agent_not_isolated` if the target is not dedicated;
    - 503 `unavailable` while the DB-held dispatch switch is off (alternative: 404 "route" like `cross_user()`).
  - Data choices: keep `source: "user"` and add a `requested_by` column, and `ProjectRun.requested_by: Option<ProjectAuthor>` with a serde default. A new `RunSource` value would need the CHECK changed (`0026:7`) and would fail the non-lenient single-run decode in old clients. Lists tolerate unknown values (`client-core/src/lenient.rs:1-26`).
  - Interrupt: allow `delivery: interrupt` from the creator only. It needs a worker variant of `queue_urgent_run` (tenant-only at `runs.rs:644`).
- **`GET /v1/projects/{id}/runs`**: add `roots=true` and `active=true` (`project_runs.rs:33-38`). This needs new definer functions in a new migration. Changing `RETURNS TABLE` (for `requested_by`) means dropping and re-creating, then repeating the `ALTER … OWNER TO thinktin_project_definer` / `REVOKE` / `GRANT` pattern (`0054:115-125`) and the column grant (`0054:25-26`).
- **`POST /v1/projects/{id}/runs/{run_id}/cancel?tree=bool`** returns 200 `ProjectRun`.
  - The creator can cancel any project run or tree; the owner can cancel their own agent's runs (`projects.md:86`).
  - Others get 403; a run not in the project gets 404; an already finished run gets 409 `conflict` (`InvalidTransition`, `error.rs:73-75`).
  - Owners can already cancel single runs through `/v1/runs/{id}/cancel`. This route is needed for the creator and for trees spanning owners.
  - The full interrupt rules (the lead interrupting members, stop-all cascading) are 8.18 (`wbs.md:221`).

**Lead**

- **`PUT /v1/projects/{id}/lead`** with `{"instance_id": "<uuid>"|null}` returns 200 `ProjectDetail`.
  - Creator only (403 otherwise). The lead can be any member's live agent (`projects.md:18,52,80`).
  - 422 if the agent is not live in the project. Recommend 409 `agent_not_isolated` for a non-dedicated agent in a shared project.
  - Take the project lock, clear the old lead first because the unique index is checked per row (as at `store/projects.rs:375-380`), and write one audit row per affected user. The receipt to the lead's owner is 8.19.

**Project board** (stored as `board_posts` with `project_id`, as `0058:2` intends; the worker may stamp `project_id` without a run, `0056:2-3,26-29`)

- **`GET /v1/projects/{id}/board?tag&archived&before&limit`** returns `{"posts":[ProjectBoardPost]}`.
  - Any live member, archived projects included.
  - Needs `GRANT SELECT (id,user_id,project_id,author_instance_id,run_id,by_agent,body,tags,created_at,archived_at) ON board_posts TO thinktin_member` plus a `member_read` policy (pattern `0054:128-130`).
- **`POST /v1/projects/{id}/board`** with `{"body","tags"}` returns 201.
  - Any live member. Body and tags validated as on the private board (`board.rs:65-82`, `:42-62`).
  - Scrubbed with an unnamed placeholder. Capped per project, using the advisory lock `board/project/<id>`.
- **`POST /v1/projects/{id}/board/{post}/archive|unarchive`** (200) and **`DELETE /v1/projects/{id}/board/{post}`** (204).
  - Allowed: the creator, or the post's owner (the human who wrote it, or the owner of the agent that wrote it).
  - Others 403; a post not in the project 404.
- **`ProjectBoardPost` JSON:** `{id, project_id, author: ProjectAuthor, author_instance_id?, author_name?, run_id?, mine, can_manage, body, tags, ai_generated, created_at, archived_at?}`.
  - The name of a withdrawn agent drops out, because `instances` is member-visible only for live agents (`0049:94-98`).
- **Encryption decision.** `projects.md:40` says the board uses the project key, but `board_posts.body` is plaintext (`0025:15`). Choose between plaintext with soft-delete plus purge (`project_lifecycle.rs:341`, same as run prompts and summaries today) and project-DEK encryption with worker-side decryption (as `read_for_member` does for artifacts).

**Artifact delete** (8.15 deferred it to 8.17, `projects-impl.md:148`)

- **`DELETE /v1/projects/{id}/artifacts/{a}`** returns 204: the creator or the author's owner.
- The private `DELETE /v1/artifacts/{id}` cannot reach project artifacts, because the tenant artifact policy is `project_id IS NULL` (`0054:143`).

**Optional**

- `ProjectDetail.tasks_enabled` (switch on, caller is creator, project active) so the App knows whether to show "assign".
- `project_id` on `EgressRequest` (`domain.rs:679-688`) so the App can label asks raised during project work.

**Pipelines from the App.** Don't add a route until §3.5 is solved. Then either a creator-only `POST /v1/projects/{id}/runs` with `"steps":[PlanStep]` (`domain.rs:1364-1370`; root on a creator-owned project agent, since roots don't hold an instance, `0002:49-51`), or `/v1/projects/{id}/plans` (design A, `drafts/projects-design-A.md:1097`).

### 5. client-core

- **`api.rs`** (project section `:1934-2420`; patterns: `create_run` `:1249-1256`, `cancel_run` `:1320-1327`, `board` `:1485-1541`):
  - add `create_project_task(id, instance: Option<InstanceId>, prompt, urgent) -> ProjectRun`;
  - add `cancel_project_run(id, run, tree) -> ProjectRun` and `set_project_lead(id, Option<InstanceId>) -> ProjectDetail`;
  - add `project_board(id, tag, archived, before, limit)`, `post_to_project_board(id, body, tags)`, `set_project_board_post_archived(id, post, archived)`, `delete_project_board_post(id, post)` and `delete_project_artifact(id, a)`;
  - extend `project_runs` (`:2237-2270`) with `roots` and `active`;
  - use `lenient::vec` for the new lists.
- **`client.rs`:**
  - wrap task creation and board posting with `refuse_secrets` (`:417`, as `send_message` and `post_to_board` do, `:369-399`);
  - decide whether `allow_secrets` may override for project text;
  - route the board list and task creation through `project_read` (`:225-233`) so a 404 forgets the project.
- **`ffi.rs`:**
  - New record `ProjectBoardPost`.
  - New fields, all `#[uniffi(default …)]`: `ProjectRun.requested_by: Option<ProjectAuthor>` (`:1191-1233`), optionally `ProjectDetail.tasks_enabled` (`:1015-1024`).
  - Update the `ProjectRunEvent` kind doc (`:1239-1242`) when the whitelist grows.
  - New methods, string ids as elsewhere:
    - `create_project_task(project_id, instance_id: Option<String>, prompt, urgent, allow_secrets) -> ProjectRun`;
    - `cancel_project_run(project_id, run_id, whole_tree) -> ProjectRun`;
    - `set_project_lead(project_id, instance_id: Option<String>) -> ProjectDetail`;
    - `project_board(project_id, tag, archived, before_id, limit) -> Vec<ProjectBoardPost>`;
    - `post_to_project_board(project_id, body, tags, allow_secrets)`;
    - `set_project_board_post_archived(project_id, post_id, archived)`;
    - `delete_project_board_post(project_id, post_id)`;
    - `delete_project_artifact(project_id, artifact_id)`.
  - Change `project_runs` (`:3565-3586`) to add `roots, active` (no App callers, so the break is free).
- **`cache.rs`:** no change. Project content stays network-only:
  - `put_runs` skips project runs (`cache.rs:158-175`);
  - the instance event stream never carries project events (`store/events.rs:88,102`);
  - the board is not cached at all;
  - the FFI comment says so (`ffi.rs:3548`);
  - `forget_project` (`cache.rs:402-428`) needs no new table.
- **`error.rs`:** update the 409 docs (`:21-24`) for `agent_not_isolated` on assignment and `unavailable` while dispatch is off.
- **Tests and smoke:**
  - `tools/client-core/ffi_smoke.py:51-106`;
  - `client-core/tests/client.rs:1642`, `:2266`;
  - gateway: add the new paths to `project_paths` (`tests/api.rs:5528-5541`) for the outsider and Forbidden-to-404 tests, and replace the worker-SQL `project_run` helper (`:5430-5469`) with the real endpoint.

### 6. Android

Regenerate `apps/android/core/src/main/kotlin/cn/thinktin/core/client_core.kt` with `apps/android/scripts/sync-core.sh --bindings-only`, in its own commit (precedent `3c78ed7`). CI runs `--check` (`sync-core.sh:7`). No Kotlin app code changes, because the app does not call project APIs; the UI is 13.18.

### 7. UI notes from the docs

- **Who commands (`projects.md`):**
  - only the creator assigns tasks and builds pipelines in the App; the lead delegates to any member's agent (`:18`, `:80`);
  - owners stop and withdraw their own agents (`:81`); the creator can interrupt any project run (`:86`);
  - the creator changes the lead (`:52`).
- **What members see (`projects-impl.md:13`):**
  - owners' waits show only as "等待主人处理" (`waiting_owner`);
  - no failure reasons, costs or tool details from other people's work.
- **Leaving (`projects.md:53`, `projects-impl.md:14`):** content stays with "已退出的成员" as author; an open project page switches to "已退出".
- **Consent:** the keys `project_goal_and_tasks` and `project_board` are already in the join consent (`domain.rs:1186-1192`), so the board and tasks need no consent version bump.
- **Scope:** WBS 12.25 and 13.18 cover list, detail, members, agents, board, tasks and artifacts (`wbs.md:294,317`).
- **Naming:** user-facing text says botin (`CLAUDE.md` 术语).
- **Where tasks appear:** a dedicated botin's project tasks are not in the private run lists or the "进行中" drawer (`store/runs.rs:511,537`). The project page has to show them.

### 8. Left for later

- **8.18:**
  - budgets enforced in llm-gw;
  - approvals routed to the owner;
  - vault and computer per project;
  - interrupt rules, including the lead interrupting members and stop-all cascading into project subtrees;
  - frozen accounts;
  - the owner's full view of their own project-run events (`projects.md:81`; the private event stream excludes them today).
- **8.19:**
  - the project feed (`GET /v1/projects/{id}/events` and `/events/ws`, per-project sequence, live revocation; `projects-impl.md:23`);
  - pushes when a task finishes or fails, to the creator and the contributing owners (`projects.md:93`);
  - @mention pushes from the board (`projects.md:95`), so `mentions` can be stored now but nothing is sent;
  - an "event stream filtered by project" (`:96`);
  - new receipts (lead changed, `project_archived`, botin reset), each needing `project_receipt()` (`0054:10-12`) and `PROJECT_RECEIPTS` (`domain.rs:1492-1500`) updated;
  - IM pushes of project content;
  - reporting other people's project content, which must exist before `cross_user_projects` is turned on in production (`projects-impl.md:149-150`).