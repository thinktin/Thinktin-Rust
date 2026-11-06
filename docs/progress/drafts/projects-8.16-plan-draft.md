# 8.16 方案草稿（workflow `projects-8-16-plan`）

# WP 8.16 implementation plan: per-(instance, project) isolation, dedicated instances, and the non-dedicated warning

- **Branch:** `claude/determined-lovelace-vn0j5h` at `6724b7f` ("progress: claim 8.16"). The tree was clean and is still clean; no repo files were touched.
- **Migrations:** the last one is `0054_project_scoped_reads.sql`, so 8.16 uses **0055–0058**.
- **Precondition (0039:6-8):** nothing is deployed and there is no `v*` tag, so `tools/ci/check_migrations.py` only checks file names. Statements that would need it once a tag exists still carry `-- deploy-safe:`.
- **Harness note:** the harness flagged the sandbox-sessions code map for a "settings-json" pattern. That text is only a factual pointer to `agent-shim/src/config.rs:163-197`, which writes `.claude/settings.json` into the sandbox HOME. Nothing in it was treated as an instruction.

**Checked on a scratch PostgreSQL 16.15 database.** All migrations 0001–0054 were applied as superuser, then the 0055/0056 drafts below. The scratch databases and roles were dropped afterwards.

| # | Behaviour | Result |
|---|---|---|
| V1 | `BEFORE UPDATE OF lease_owner … WHEN (NEW.project_id IS NOT NULL AND NEW.lease_owner IS NOT NULL)` | Fires on claim, takeover and acquire-style updates. Does not fire on renew (only `lease_expires_at` is set) or on release (`lease_owner = NULL`). Private runs never reach the function. |
| V2 | `current_setting('thinktin.isolation', true)` after the setting was used earlier in the same session | Returns `''`, not NULL. The check therefore has to be `coalesce(nullif(…,''),'0')::int`. |
| V3 | `RAISE … USING ERRCODE='check_violation', CONSTRAINT='instance_dedicated'` | The error carries the constraint name, which sqlx exposes as `db.constraint()`. This lets `store::Error` map it to its own variant. |
| V4 | `pg_stat_activity` read by a non-superuser role about another role's session | `application_name` is visible; `state` and `query` are hidden. |
| V5 | `BEFORE INSERT OR UPDATE OF project_id` stamp trigger on a table with `FK … ON DELETE SET NULL (run_id)` | Does not fire when the FK sets `run_id` to NULL. `BEFORE UPDATE OF run_id` does fire, with `NEW.run_id` NULL. `project_id` survives the run's deletion. |
| V6 | One trigger function shared by tables with different row types | Fails with `record "new" has no field …`, even inside `CASE` or `AND`. So each row shape needs its own function. |
| V7 | The 0055 guards, as superuser and as `thinktin_app` under RLS | Private run, grant, plan or step on a dedicated instance → 23514 `instance_dedicated`. The dedicated flag on `project_agents` is derived. Another project's row is refused. The tenant has the `FOR KEY SHARE` rights it needs. |
| V8 | Race: worker holds the instance `FOR UPDATE` and sets `workspace_project_id`; a tenant inserts a private run at the same time | The insert waits in the trigger's `FOR KEY SHARE`, then fails with `instance_dedicated` once the worker commits. |
| V9 | Proposed claim predicate | Returns private runs and dedicated project runs. Does not return mixed project runs, or runs whose agent left or whose project is archived. The plan uses a PK lookup on `instances` and a hashed SubPlan for liveness. |
| V10 | Updated `queue_workspace_archive_purge` | Queues `projects/<p>/workspaces/…` keys only when `OLD.workspace_project_id = p`. A forged project key on a private instance is not queued. |
| V11 | 0056 policies | `ALTER POLICY … USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())))` compiles. WITH CHECK is kept. |
| V12 | 0055 fence with `thinktin.isolation='1'` | Dedicated project run leases; mixed project run is refused with 42501 `runs_isolation`. Without the setting, both are refused. |

---

## 0. Decisions

**Scope.**

*In 8.16:*
- **The isolation unit is the instance's sandbox.** An (instance, project) pair is executable only when the whole instance belongs to that project (a "dedicated" instance).
- **Dedicated instances:**
  - adopt one for the project inside join or add-agents;
  - mark an existing one dedicated (this wipes its workspace);
  - release one back to private;
  - reset automatically when its project is deleted.
- **Claiming project runs opens, for dedicated instances only.** It is enforced by a DB fence that holds for every binary version. Takeover, expired waits and retries follow the same rule. An orphan sweeper frees instances.
- **Archives:** a dedicated instance's archive is sealed with the project DEK under `projects/<p>/workspaces/`.
- **What a project run gets:**
  - `ToolContext` and `ShimLaunch` carry the space;
  - a short allowlist of platform tools;
  - vault reveal, computer, delegate, board, ask, peers and schedule are refused;
  - space checks at the connector, artifact and handoff layers;
  - same-space piggyback messages;
  - a generic interrupt preface;
  - no IM fan-out.
- **Private-side filters:** peers, delegation and ask exclude dedicated instances; holder and last-run reads are per space; the private board only shows private posts.
- **Run-linked tables:** `project_id` is stamped on the six remaining tables, with membership-gated tenant policies and purge steps.
- `fill_space_from_run` refuses worker appends to deleted projects.
- **Lock order:** cancels settle approvals before bumping instances.
- **Non-dedicated agents:** a warning and acknowledgement, behind a pilot switch.
- Consent version 2.
- API, FFI, Android bindings and docs.

*Deferred:*
- **8.17:** writing executable project runs (the dispatcher, gated by §2.3), project grants via `ProjectActor`, project-scoped board/ask/delegate/peers/pipelines/schedule tools, lead, cross-owner trees, project pipelines in `due_pipelines`.
- **8.18:** vault per item, computer per project, budgets in llm-gw, approvals to the owner, tenant notice paths.
- **8.19:** feed, receipts (including "your dedicated agent was reset"), IM pushes of project content, reporting others' content.
- **After 8.19 plus 15.7:** mixed-instance isolation (level 2, §8).

| # | Decision | Why / evidence |
|---|---|---|
| D1 | **8.16 opens claiming of project runs, only for dedicated instances (isolation level 1), and writes no executable project runs.** Old SQL (8.13–8.15) keeps `project_id IS NULL`. The 8.16 SQL requires `instances.workspace_project_id = runs.project_id` and live membership. A DB trigger refuses to lease any project run unless the transaction declares a level high enough for that run. | projects-impl "迁移与放量" 8.14–8.16: workers of every version must exclude, in claim, retry and takeover, project runs they cannot isolate; executable project tasks are only written after old replicas have exited.<br>• 8.13–8.15 binaries filter at `runs.rs:1014,1135,1434,1567` (comment `:202-208`).<br>• 8.16 has no writer: `NewRun` has no project field, `insert_run` (`runs.rs:288-317`) never binds one, and `fill_space` (`0040:19-22`) is worker-only. Only tests seed project runs.<br>• 8.17 adds the writer, behind the gate in D11.<br>Opening the claim now means the real claim → execute path, with isolation, is tested in 8.16, and 8.17 only adds writes. |
| D2 | **Only dedicated instances are executable.** A mixed instance (`workspace_project_id IS NULL`) may be a project agent, but none of its project runs are claimed by any 8.16 build: the fence requires level 2, which no binary declares. | • Item 5: one OS identity that can run arbitrary shell cannot be isolated by path naming; mixed instances need a separate mount/runtime, verified before opening.<br>• Everything runs as uid 1001 (`deploy/templates/Dockerfile:36,130`); `ExecSpec` has no uid (`sandbox/src/lib.rs:115-121`).<br>• HOME is `workspace/.thinktin/home` (`exec.rs:115-118`) and is archived with the workspace (`control/src/workspace.rs:79-98`).<br>• ACS: one Pod, no volumes, no setuid (`docs/browser.md:300`). Cube: separate mounts need per-uid envd (unverified, Phase 0).<br>• impl `:12` (the pilot only admits isolable instances) and `:29-30` (dedicated first; mixed reviewed separately later).<br>• A dedicated instance gets its own sandbox, volume or archive, HOME, session slot (`agent-shim/src/state.rs:16-37`), `/tmp` browser profile, platform-tool file and token epoch on every backend, with no new code in the sandbox crate or the shim. |
| D3 | **`instances.workspace_project_id uuid REFERENCES projects` is the source of truth.** It is written by the worker only; the tenant column grants at `0023:25-27`, `0024:9`, `0032:9` do not include it. `project_agents.dedicated` is **derived** by a BEFORE trigger on live rows (`dedicated := workspace_project_id = project_id`). Left rows keep their historical value. | The flag must outlive the agent row: after leaving, the workspace still holds project content. `project_agents.dedicated` (`0039:55,69`) is already readable by members (`0049:84`). Writers such as `put_agents` (`project_members.rs:140-141` sets false) and the tenant revive in `projects.rs:394-405` no longer need to compute it. |
| D4 | **DB invariants on a dedicated instance:**<br>• no private run or private grant;<br>• no project run or grant of another project;<br>• no active plan using it, and no plan step on it;<br>• no live `project_agents` row in another project.<br>Setting `workspace_project_id` is refused while the instance has unfinished runs, active plans or steps, or live rows elsewhere. The guards take `FOR KEY SHARE` on the instance, so they serialize with the worker's `FOR UPDATE` (V8). | Covers old gateways and every private entry point (`routes/runs.rs:31-64`, `vault.rs:408-439`, `hooks.rs:312`, `scheduler.rs:167`, `pipeline.rs:250`, `delegate.rs:157`, `ask.rs:142`), and the tenant solo-project writes (`projects.rs:271-306,366-406`). `FOR KEY SHARE` does not conflict with the `token_epoch`/`event_seq` no-key updates on instances, so it adds no contention with the executor. |
| D5 | **Two ways an instance becomes dedicated:**<br>(a) **Adopt for the project** inside the accept or add-agents worker transaction: a new `instances` row with `workspace_project_id = p`, no private grant, in one transaction with the join, so a failure rolls back everything.<br>(b) **Mark an existing instance**, which requires `"reset_workspace": true`. Its workspace is retired (D6) and its private grants revoked. It is refused (409) while it has unfinished runs, active plans or steps, or live rows in other projects.<br>Only the agent's owner can do either. Dedicating in a never-shared own project is allowed; team features skip that agent (D15). | • projects.md §6 (`:71`).<br>• 8.14 left adopt-in-join as two calls (`projects-8.14-plan.md:31,825-829`); design A's compensation is not crash-safe (`projects-design-A.md:1019-1025`).<br>• "Memory holds only project content" cannot hold for an existing instance without wiping, because private HOME and project work would share the volume or archive.<br>• Refusing (instead of pausing) when plans exist avoids a plans↔instances lock cycle with the scheduler. |
| D6 | **Retiring a workspace is DB-only and atomic.**<br>• The current `sandbox_id`, `restoring_sandbox_id` and `workspace_id` go into `retired_workspaces`.<br>• The instance gets a new `ws-<uuid>`, `state='provisioning'`, cleared sandbox/snapshot/archive/restoring columns (the purge trigger queues the archive blobs), `egress_hosts='{}'` and `token_epoch+1`.<br>• Its `egress_requests` are deleted.<br>• `Lifecycle::sweep` later destroys the old sandboxes and deletes the old volume. | • The next `ensure_running` sees no sandbox and creates a fresh one (`control/src/lib.rs:769-771`).<br>• In-flight restores and archives already detect "not mine any more" (`:1078-1083`, `Recorded::Superseded`).<br>• The epoch bump kills old tokens.<br>• Same machinery as instance purge (`:1872-1890`, `instances.rs:789-803`). |
| D7 | **After leaving, a dedicated instance stays dedicated and idle.**<br>• No private runs (D4); no project runs (not live).<br>• Rejoining or re-adding keeps its memory.<br>• `POST /v1/instances/{id}/release` (owner; allowed only once it has no live project row) retires the workspace and makes it a fresh private instance.<br>• Deleting the project retires the workspaces of its dedicated instances in the delete transaction, with a backstop in purge. | • Leaving must not hand project content to private work.<br>• Delete: "删除项目后即刻不可读" (impl item 7). The project key is destroyed (`project_lifecycle.rs:159-162`), so archives are already undecryptable; Cube volumes hold plaintext and must go.<br>• The FK `workspace_project_id → projects` is NO ACTION, so purge cannot drop the project row while an instance still points at it. |
| D8 | **A dedicated instance's archive is `projects/<p simple>/workspaces/<ws>/<archive id>`,** sealed with the project DEK (`project_vault`, subject `project:<p>`, `orchestrator/src/artifacts.rs:216-260`). Private archives are unchanged (`workspaces/<u>/…`, user DEK). `WorkspaceStore` takes an `ArchiveOwner` instead of a `UserId`. The project key is created eagerly when an agent is first dedicated (outside the transaction), because `insert_project_key` only works while the project is active (`store/src/projects.rs:223-237`). | • Item 5: project artifacts use the project DEK; a private workspace archive must not carry project plaintext decryptable with the personal DEK.<br>• `workspace_sealer` takes a subject string (`keyvault/src/lib.rs:626-640`).<br>• Prefix ownership check is at `orchestrator/src/workspaces.rs:185-193`. |
| D9 | **Claim SQL:** `isolated(r)` = `EXISTS (instances i WHERE i.id = r.instance_id AND i.workspace_project_id IS NOT DISTINCT FROM r.project_id)`, and `live(r)` = project agent, member and project all live. Urgent precedence becomes per space (`u.project_id IS NOT DISTINCT FROM r.project_id`). **Takeover and expired waits** require `isolated` only, so orphans still get finished. **`due_pipelines` stays private.** | V9.<br>• One predicate gives "private runs only on private instances" and "project runs only on their dedicated instance".<br>• Liveness is read as a plain snapshot. Exits lock and cancel the runs in the same transaction (`project_members.rs` exit paths, `project_lifecycle.rs:57-83`), and SKIP LOCKED skips what they hold, so there is no lock inversion. |
| D10 | **DB fence:** trigger `runs_isolation` (V1, V12). `Db::worker` sets `thinktin.isolation = '1'`. The trigger requires level 1 for a project run on its dedicated instance and level 2 otherwise. | Covers `acquire_lease` (`runs.rs:1101-1121`, no filter, tests only), any future SQL path, and any pre-0040 build. `thinktin_worker` is BYPASSRLS (`0001:19`), so RLS cannot fence a worker. |
| D11 | **Write gate for 8.17:** `application_name` becomes `thinktin/i1` (it was the constant `"thinktin"`, `store/src/lib.rs:113`). `Tx<Worker>::legacy_sessions()` counts `pg_stat_activity` rows with `application_name = 'thinktin'`, which is visible across roles (V4). 8.17's dispatcher refuses to write while that count is above 0. | Old binaries' space-blind reads are the remaining hazard once project runs exist. The one that matters with dedicated-only execution is an 8.15 private run's `agent_status` on a dedicated peer (`peers.rs:80-158`). |
| D12 | **Orphan sweeper** on the executor's takeover tick. It cancels non-terminal project runs whose agent, member or project is no longer live (SKIP LOCKED), settling approvals before instances. | A project run left in backoff or waiting would otherwise hold `runs_one_active_per_instance` (`0002:49-51`) for ever. |
| D13 | **Lock order: approvals before instances.**<br>• `cancel_project_agent_runs`, `cancel_project_member_runs` and `cancel_project_runs` (`runs.rs:860-967`) become: lock runs and collect their ids, `settle_cancelled_approvals(ids)`, then `bump_epochs_where!`, then the filter-based `UPDATE runs`.<br>• `finish_inner` moves `cancel_run_approvals` (`executor.rs:1171`) before `cancel_descendants` (`:1163-1167`).<br>• Erase settles approvals before `cancel_user_runs` (`users.rs:251`). | `projects-8.15-review.md:88-96` ("fix before 8.16 opens claims"). `decide_approval` takes approvals FOR UPDATE and then `append_event` updates `instances.event_seq` (`gateway/routes/approvals.rs:45-46`, `events.rs:47-52`). |
| D14 | **Tools in project runs (until 8.17/8.18):** `PROJECT_RUN_TOOLS = artifact_publish, artifact_list, artifact_read, artifact_fetch, web_search`, plus the browser if the grant has it.<br>• Everything else is removed from the list and refused in `ToolSet::call`.<br>• Vault reveal, computer and delegate are off.<br>• A project run without `run_grant_id` fails; there is no fallback to the private grant.<br>• `ExecConnector`, `ArtifactTools::origin` and `HandoffCopier` refuse when `instance.workspace_project_id != run.project_id`. | Leaks per tool in the space-filters map: A1–A11 (`tools.rs:201,312-333`; `board.rs:42-125`; `vault.rs:45-197`; `executor.rs:2009-2060`; `computer.rs:217-250`; `executor.rs:744-752`, which uses `active_grant_for_instance`, private-only at `grants.rs:362-375`). |
| D15 | **Private-side filters:**<br>• `peers()` and `delegation_targets()` exclude dedicated instances (so `ask` does too, via peers);<br>• the `peers` holder subquery, `instance_holder` and `last_finished_run` take the caller's space;<br>• `unannounced_messages` is same-space;<br>• the private board queries add `project_id IS NULL`;<br>• the interrupt preface quotes the interrupted run only when it is in the same space. | `instances.rs:543-589`; `runs.rs:736-762,1332-1348`; `executor.rs:787-802,1504-1535`; `store/board.rs:118,132-133,211`. |
| D16 | **Stamp `project_id`** on `vault_requests`, `device_calls`, `board_posts`, `egress_requests`, `live_activities` and `content_reports` with a new function, `stamp_project_from_run()`:<br>• on INSERT, derived from the run the caller can see; an invisible run gives 23503;<br>• frozen on UPDATE;<br>• **not** the 0050 function, which raises on FK `SET NULL` (V5).<br>Also:<br>• `egress_requests` gets a same-space check when `run_id` moves;<br>• `thinktin_llmgw` gets `SELECT (project_id) ON runs`;<br>• the five tenant tables get the membership-gated policy;<br>• `device_calls` has no tenant access;<br>• purge steps;<br>• open `content_reports` are kept until handled. | 8.15 plan §8. C4/C5/C6/C7 in the map. `0034:46,49`. Reports carry plaintext snapshots (`0019:16`) and must still be handled by operators. |
| D17 | **`fill_space_from_run` refuses worker inserts of events, approvals and artifacts for deleted projects** (23514 `project_deleted`). Tenants are already refused, because a deleted project's runs are invisible to them and the composite FK fails. | impl item 7 ("每次解密与发事件都检查状态"); deferred by the 8.15 plan (S10). The tenant cannot read `projects` of other creators (`0039:181`), so the check is limited to `current_user = 'thinktin_worker'`. |
| D18 | **Non-dedicated agents in shared projects** (any join, or adding to a project with `shared_at`):<br>• `[api] mixed_project_agents = false` (default, pilot) → 409 `agent_not_isolated`;<br>• when true → `ack_shared_memory: true` is required (422 otherwise) and stored in `project_agents.shared_memory_ack_at`.<br>Own never-shared projects get no warning and no acknowledgement. The creator's existing mixed agents stay when the project becomes shared, but they cannot run project work. | projects.md §6 `:72` (warn, then allow) against impl `:12` (the pilot only admits isolable instances). The switch builds the warning and keeps the pilot rule; turn it on only together with mixed isolation (§8). |
| D19 | **Consent version 2.**<br>• New fixed key lists `project_consent::DEDICATED_AGENT` and `MIXED_AGENT`; preview fields `dedicated_agent`, `mixed_agent`, `mixed_agents_allowed`.<br>• Clients send `consent_version`; missing counts as 1 and gives 422.<br>• client-core sends its compiled `PROJECT_CONSENT_VERSION`. | Today `consent()` builds the current version from a bool (`routes/projects.rs:43-48`), so `Consent::check` (`project_invites.rs:40-55`) can never fail. |
| D20 | **New error codes:** `instance_dedicated` (409) and `agent_not_isolated` (409). An adopt that hits the account's instance cap reuses `instance_limit`. Other refusals are `conflict` (409) or `invalid` (422) with messages. | `proto/src/api.rs:37-101`; clients pass codes through (`client-core/src/error.rs:19-31`). |
| D21 | **No sandbox-crate or agent-shim code changes.** `--home .thinktin/home --cwd .` stays (`exec.rs:115-118`); old shims accept it (`agent-shim/src/main.rs:137-142`). Docs fixes: `sandbox-cube.md:31` (agent state is on the volume, not in `/sandbox/home`) and `browser.md:269,307` (`PR_SET_CHILD_SUBREAPER` is not set; `prctl` is at `main.rs:481`). | §3.1. |
| D22 | **The FFI change is breaking:** `ProjectJoin.instance_ids` is replaced by `agents`, and `add_project_agents` takes entries. Android bindings are regenerated in their own commit. | Only the generated `client_core.kt` references these (grep `apps/`). `cross_user_projects` is off and the App screens (12.25, 13.18) depend on 8.17 (`wbs.md:294,317`). |

---

## 1. Migrations

### 1.1 `0055_dedicated_instances.sql` (one transaction)

```sql
-- 专属实例与项目运行的隔离（WBS 8.16，docs/projects.md 第 6 节，docs/projects-impl.md 第 5 条、“迁移与放量”）。
-- 沙箱里所有进程是同一个 OS 用户，按目录分不开私人和项目（impl 第 5 条）：这一版的隔离单位是整个实例。
-- instances.workspace_project_id 不为空的实例（专属实例）的沙箱、工作区卷、归档、agent 的 HOME 和会话只属于这个项目，
-- 不接私人任务；混用实例（为空）的项目运行哪个版本的程序都不领（runs_isolation）。这一列只有 thinktin_worker 写
-- （租户的列权限见 0023:25-27、0024:9、0032:9）。
-- 前提同 0039：第一次部署之前发布，表是空的；instances 上的索引直接建（行数 = 实例数）。

ALTER TABLE instances ADD COLUMN workspace_project_id uuid REFERENCES projects (id);
CREATE INDEX instances_workspace_project ON instances (workspace_project_id) WHERE workspace_project_id IS NOT NULL;
-- 跨用户项目里派混用实例时，用户确认过“它记忆里的私人内容可能被带进项目”（试点默认不收混用实例）。
ALTER TABLE project_agents ADD COLUMN shared_memory_ack_at timestamptz;

-- 换下来的工作区：沙箱、正在放回的沙箱、工作区卷由巡检销毁（不设外键：实例删了、账号注销了也要收拾）。
-- 归档对象不在这里：实例行上的键清空时由 queue_workspace_archive_purge 排进 blob_purge。
CREATE TABLE retired_workspaces (
    id           uuid PRIMARY KEY,
    instance_id  uuid NOT NULL,
    user_id      uuid NOT NULL,
    workspace_id text NOT NULL,
    sandbox_ids  text[] NOT NULL DEFAULT '{}',
    reason       text NOT NULL CHECK (reason IN ('dedicate', 'release', 'project_deleted')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    attempts     integer NOT NULL DEFAULT 0,
    retry_at     timestamptz NOT NULL DEFAULT now(),
    last_error   text CHECK (length(last_error) <= 500)
);
CREATE INDEX retired_workspaces_due ON retired_workspaces (retry_at);
ALTER TABLE retired_workspaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE retired_workspaces FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON retired_workspaces TO thinktin_worker;

-- 运行、授权：专属实例上只有它那个项目的（行类型不同的表各用一个函数，见方案 V6）。读实例时加 KEY SHARE：和标专属的
-- FOR UPDATE 排队（不和改 token_epoch、event_seq 的 NO KEY UPDATE 冲突）。
CREATE FUNCTION space_matches_instance() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    ws uuid;
BEGIN
    SELECT i.workspace_project_id INTO ws FROM public.instances i WHERE i.id = NEW.instance_id FOR KEY SHARE;
    IF ws IS NOT NULL AND ws IS DISTINCT FROM NEW.project_id THEN
        RAISE EXCEPTION 'instance % works only for its project', NEW.instance_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'instance_dedicated';
    END IF;
    RETURN NEW;
END $$;
-- 计划的步骤总是私人的。
CREATE FUNCTION private_target_not_dedicated() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    ws uuid;
BEGIN
    SELECT i.workspace_project_id INTO ws FROM public.instances i WHERE i.id = NEW.instance_id FOR KEY SHARE;
    IF ws IS NOT NULL THEN
        RAISE EXCEPTION 'instance % works only for its project', NEW.instance_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'instance_dedicated';
    END IF;
    RETURN NEW;
END $$;
-- 生效中的计划：自己的实例和步骤的实例都不能是专属的（暂停的可以留着，恢复时再查）。
CREATE FUNCTION plan_not_on_dedicated() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    PERFORM 1 FROM public.instances i WHERE i.id = NEW.instance_id FOR KEY SHARE;
    PERFORM 1 FROM public.plan_steps s JOIN public.instances i ON i.id = s.instance_id
      WHERE s.plan_id = NEW.id FOR KEY SHARE OF i;
    IF EXISTS (SELECT 1 FROM public.instances i WHERE i.id = NEW.instance_id AND i.workspace_project_id IS NOT NULL)
       OR EXISTS (SELECT 1 FROM public.plan_steps s JOIN public.instances i ON i.id = s.instance_id
                   WHERE s.plan_id = NEW.id AND i.workspace_project_id IS NOT NULL) THEN
        RAISE EXCEPTION 'plan % uses an instance that works only for a project', NEW.id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'instance_dedicated';
    END IF;
    RETURN NEW;
END $$;
-- 项目 agent：专属实例只在它那个项目里有存活的行；存活行的 dedicated 由实例算（离开的行不动：注销时会改成 false）。
CREATE FUNCTION project_agents_dedicated() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    ws uuid;
BEGIN
    IF NEW.left_at IS NOT NULL THEN
        RETURN NEW;
    END IF;
    SELECT i.workspace_project_id INTO ws FROM public.instances i WHERE i.id = NEW.instance_id FOR KEY SHARE;
    IF ws IS NOT NULL AND ws <> NEW.project_id THEN
        RAISE EXCEPTION 'instance % works only for another project', NEW.instance_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'instance_dedicated';
    END IF;
    NEW.dedicated := ws IS NOT NULL;
    RETURN NEW;
END $$;
-- 标成专属：实例上不能还有别的事（没结束的运行、生效中的计划、别的项目里存活的行）。由 worker 先锁实例再写，
-- 这里兜底（错误码 instance_not_free → 409）。
CREATE FUNCTION instances_dedicated_alone() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    IF NEW.workspace_project_id IS NULL OR NEW.workspace_project_id IS NOT DISTINCT FROM OLD.workspace_project_id THEN
        RETURN NEW;
    END IF;
    IF EXISTS (SELECT 1 FROM public.project_agents a WHERE a.instance_id = NEW.id AND a.left_at IS NULL
                 AND a.project_id <> NEW.workspace_project_id)
       OR EXISTS (SELECT 1 FROM public.runs r WHERE r.instance_id = NEW.id
                    AND r.state NOT IN ('succeeded', 'failed', 'cancelled'))
       OR EXISTS (SELECT 1 FROM public.plans p WHERE p.status = 'active'
                    AND (p.instance_id = NEW.id
                         OR p.id IN (SELECT s.plan_id FROM public.plan_steps s WHERE s.instance_id = NEW.id))) THEN
        RAISE EXCEPTION 'instance % still has other work', NEW.id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'instance_not_free';
    END IF;
    RETURN NEW;
END $$;
-- 领项目运行（任何版本、任何语句）：这一版程序声明能隔离到哪一级（Db::worker 设 thinktin.isolation）。专属于这个项目的
-- 实例要 1 级，混用实例要 2 级（还没有程序做得到）。续租只改 lease_expires_at、交还租约置空，都不触发。
CREATE FUNCTION runs_isolation_fence() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    need int := 2;
BEGIN
    IF EXISTS (SELECT 1 FROM public.instances i WHERE i.id = NEW.instance_id
                 AND i.workspace_project_id = NEW.project_id) THEN
        need := 1;
    END IF;
    IF coalesce(nullif(current_setting('thinktin.isolation', true), ''), '0')::int < need THEN
        RAISE EXCEPTION 'this worker cannot isolate project run %', NEW.id
            USING ERRCODE = 'insufficient_privilege', CONSTRAINT = 'runs_isolation';
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION space_matches_instance(), private_target_not_dedicated(), plan_not_on_dedicated(),
    project_agents_dedicated(), instances_dedicated_alone(), runs_isolation_fence() FROM PUBLIC;

CREATE TRIGGER runs_instance_space BEFORE INSERT ON runs FOR EACH ROW EXECUTE FUNCTION space_matches_instance();
CREATE TRIGGER run_grants_instance_space BEFORE INSERT ON run_grants
    FOR EACH ROW EXECUTE FUNCTION space_matches_instance();
CREATE TRIGGER plan_steps_instance_space BEFORE INSERT OR UPDATE OF instance_id ON plan_steps
    FOR EACH ROW EXECUTE FUNCTION private_target_not_dedicated();
CREATE TRIGGER plans_instance_space BEFORE INSERT OR UPDATE OF instance_id, status ON plans
    FOR EACH ROW WHEN (NEW.status = 'active') EXECUTE FUNCTION plan_not_on_dedicated();
CREATE TRIGGER project_agents_dedicated BEFORE INSERT OR UPDATE OF left_at, dedicated, instance_id, project_id
    ON project_agents FOR EACH ROW EXECUTE FUNCTION project_agents_dedicated();
CREATE TRIGGER instances_dedicated_alone BEFORE UPDATE OF workspace_project_id ON instances
    FOR EACH ROW EXECUTE FUNCTION instances_dedicated_alone();
CREATE TRIGGER runs_isolation BEFORE UPDATE OF lease_owner ON runs FOR EACH ROW
    WHEN (NEW.project_id IS NOT NULL AND NEW.lease_owner IS NOT NULL) EXECUTE FUNCTION runs_isolation_fence();

-- 专属实例的归档在 projects/<项目>/workspaces/ 下（按项目 DEK 加密）：只收这一行自己项目前缀下的键（同 0023 的规矩）。
CREATE OR REPLACE FUNCTION queue_workspace_archive_purge() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    own text := 'workspaces/' || replace(OLD.user_id::text, '-', '') || '/';
    proj text := 'projects/' || replace(OLD.workspace_project_id::text, '-', '') || '/workspaces/';
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF starts_with(OLD.workspace_archive_key, own) OR starts_with(OLD.workspace_archive_key, proj) THEN
            INSERT INTO public.blob_purge (blob_key) VALUES (OLD.workspace_archive_key) ON CONFLICT DO NOTHING;
        END IF;
        IF starts_with(OLD.workspace_archive_pending, own) OR starts_with(OLD.workspace_archive_pending, proj) THEN
            INSERT INTO public.blob_purge (blob_key) VALUES (OLD.workspace_archive_pending) ON CONFLICT DO NOTHING;
        END IF;
        RETURN OLD;
    END IF;
    IF (starts_with(OLD.workspace_archive_key, own) OR starts_with(OLD.workspace_archive_key, proj))
       AND OLD.workspace_archive_key IS DISTINCT FROM NEW.workspace_archive_key THEN
        INSERT INTO public.blob_purge (blob_key) VALUES (OLD.workspace_archive_key) ON CONFLICT DO NOTHING;
    END IF;
    -- 上传完成时待定的对象变成正式的，不删。
    IF (starts_with(OLD.workspace_archive_pending, own) OR starts_with(OLD.workspace_archive_pending, proj))
       AND OLD.workspace_archive_pending IS DISTINCT FROM NEW.workspace_archive_pending
       AND OLD.workspace_archive_pending IS DISTINCT FROM NEW.workspace_archive_key THEN
        INSERT INTO public.blob_purge (blob_key) VALUES (OLD.workspace_archive_pending) ON CONFLICT DO NOTHING;
    END IF;
    RETURN NEW;
END $$;

-- 删了的项目（impl 第 7 条：每次发事件都查状态）：worker 不再往里追加事件、审批、产出物。租户本来就加不进去（看不到
-- 运行，空间算成私人，复合外键拒绝）；租户也读不到别人创建的项目行，所以只查 worker。
CREATE OR REPLACE FUNCTION fill_space_from_run() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.project_id IS DISTINCT FROM OLD.project_id OR NEW.space_kind IS DISTINCT FROM OLD.space_kind
           OR NEW.space_id IS DISTINCT FROM OLD.space_id OR NEW.user_id IS DISTINCT FROM OLD.user_id
           OR NEW.run_id IS DISTINCT FROM OLD.run_id THEN
            RAISE EXCEPTION '% cannot move between users, runs or spaces', TG_TABLE_NAME
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    NEW.project_id := NULL;
    IF NEW.run_id IS NOT NULL THEN
        SELECT r.project_id INTO NEW.project_id FROM public.runs r WHERE r.id = NEW.run_id;
    END IF;
    IF NEW.project_id IS NOT NULL AND current_user = 'thinktin_worker' AND EXISTS (
        SELECT 1 FROM public.projects p WHERE p.id = NEW.project_id AND p.status = 'deleted') THEN
        RAISE EXCEPTION 'the project of this run was deleted'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'project_deleted';
    END IF;
    NEW.space_kind := CASE WHEN NEW.project_id IS NULL THEN 'private' ELSE 'project' END;
    NEW.space_id := coalesce(NEW.project_id, NEW.user_id);
    RETURN NEW;
END $$;
```

Notes:
- **Owner:** the migration owner already owns both replaced functions. `CREATE OR REPLACE` keeps owner, ACL and SECURITY DEFINER, and the SET clauses are repeated.
- **FK on `workspace_project_id`:** runtime RI checks bypass RLS, and validating an all-NULL column needs no rows.
- **Grants:** `thinktin_app` has UPDATE on some `instances` columns (`0023:26-27`), which `FOR KEY SHARE` requires (V7). `thinktin_member` gets no grant on the new column (`0049:87`).

### 1.2 `0056_run_linked_project_ids.sql` (one transaction; applied in V11)

```sql
-- 带运行的其余六张表也记项目（8.15 方案第 8 节）：保险箱请求、电脑调用、看板、出网请求、实时活动、举报。
-- 项目由触发器按调用者看得到的运行算、建了不能改；不用 0050 的 fill_space_from_run：前四张是 ON DELETE SET NULL (run_id)，
-- 外键置空会触发 UPDATE OF run_id（方案 V5）。看不到运行（退出了的项目）一律 23503：外键检查不管行级安全。
-- 回填按 0050：迁移账号受 FORCE 约束，回填时临时去掉；按 0039 的前提这几张表里没有项目运行的行。

CREATE FUNCTION stamp_project_from_run() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    run_project uuid;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.project_id IS DISTINCT FROM OLD.project_id THEN
            RAISE EXCEPTION '%.project_id comes from the run and cannot change', TG_TABLE_NAME
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    NEW.project_id := NULL;
    IF NEW.run_id IS NOT NULL THEN
        SELECT r.project_id INTO run_project FROM public.runs r WHERE r.id = NEW.run_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION '% refers to a run that is not visible', TG_TABLE_NAME
                USING ERRCODE = 'foreign_key_violation';
        END IF;
        NEW.project_id := run_project;
    END IF;
    RETURN NEW;
END $$;
-- 出网请求在等的时候会换到同一个实例后来的运行上（store/egress.rs touch_request）：只能换到同一个空间的运行。
CREATE FUNCTION egress_run_same_space() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    IF NEW.run_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.runs r WHERE r.id = NEW.run_id AND r.project_id IS NOT DISTINCT FROM NEW.project_id) THEN
        RAISE EXCEPTION 'egress request % cannot move to a run in another space', NEW.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION stamp_project_from_run(), egress_run_same_space() FROM PUBLIC;

ALTER TABLE vault_requests ADD COLUMN project_id uuid;
ALTER TABLE device_calls ADD COLUMN project_id uuid;
ALTER TABLE board_posts ADD COLUMN project_id uuid;
ALTER TABLE egress_requests ADD COLUMN project_id uuid;
ALTER TABLE live_activities ADD COLUMN project_id uuid;
ALTER TABLE content_reports ADD COLUMN project_id uuid;

ALTER TABLE runs NO FORCE ROW LEVEL SECURITY;
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['vault_requests', 'device_calls', 'board_posts', 'egress_requests', 'live_activities',
                             'content_reports'] LOOP
        EXECUTE format('ALTER TABLE %I NO FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('UPDATE %I x SET project_id = r.project_id FROM runs r '
                       'WHERE r.id = x.run_id AND r.project_id IS NOT NULL', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE OF project_id ON %I FOR EACH ROW '
                       'EXECUTE FUNCTION stamp_project_from_run()', t || '_project', t);
    END LOOP;
END $$;
ALTER TABLE runs FORCE ROW LEVEL SECURITY;

CREATE TRIGGER egress_requests_run_space BEFORE UPDATE OF run_id ON egress_requests
    FOR EACH ROW EXECUTE FUNCTION egress_run_same_space();
-- 出口代理插入出网请求时触发器要读运行的项目（0034:49 只给了这几列）。
GRANT SELECT (project_id) ON runs TO thinktin_llmgw;

-- 租户：项目行只在还是存活成员时看得到（0054 的写法；WITH CHECK 不变）。device_calls 没有租户权限（0014:77-78）。
ALTER POLICY tenant ON vault_requests
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));
ALTER POLICY tenant ON board_posts
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));
ALTER POLICY tenant ON egress_requests
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));
ALTER POLICY tenant ON live_activities
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));
ALTER POLICY tenant ON content_reports
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));

-- 删项目后清理用。这三张表很小（每人几条、24 小时保留、举报），直接建；大的两张在 0057、0058 并发建。
CREATE INDEX vault_requests_project ON vault_requests (project_id) WHERE project_id IS NOT NULL;
CREATE INDEX device_calls_project ON device_calls (project_id) WHERE project_id IS NOT NULL;
CREATE INDEX content_reports_project ON content_reports (project_id) WHERE project_id IS NOT NULL;
```

`live_activities` needs no index: project rows go with the runs-delete cascade (`0018:37`), and the existing `live_activities_run` index covers it.

### 1.3 Concurrent indexes (first bytes `-- no-transaction`, one statement each, as in 0051–0053)

`0057_egress_requests_project_index.sql`:
```sql
-- no-transaction
-- 项目运行的出网请求（8.16）：删项目后清理用。
CREATE INDEX CONCURRENTLY egress_requests_project ON egress_requests (project_id) WHERE project_id IS NOT NULL;
```

`0058_board_posts_project_index.sql`:
```sql
-- no-transaction
-- 项目运行写的看板条目（8.16；8.17 的项目看板也用）：删项目后清理用。
CREATE INDEX CONCURRENTLY board_posts_project ON board_posts (project_id, id DESC) WHERE project_id IS NOT NULL;
```

**Migration tests:** extend `migrations_run_as_a_plain_owner`. Under the non-superuser owner it must find:
- FORCE on `retired_workspaces` and on the six altered tables;
- triggers present;
- `pg_has_role`-free checks only.

The existing project fixtures that set `lease_owner` on project runs on non-dedicated instances (`store/src/tests.rs:1190`, `store/src/tests/projects.rs:1789,2397`) set `SELECT set_config('thinktin.isolation','2',true)` in that transaction. It is documented as "stands in for a future mixed-isolation build".

---

## 2. Store API (`crates/store`)

### 2.1 `lib.rs`, `error.rs`, `schema.rs`

- **`lib.rs`:** `pub const ISOLATION_LEVEL: u8 = 1;` with a doc next to it, and the `known_sources()` comment (`runs.rs:202-208`) rewritten to point to it.
  - `Db::connect` (`lib.rs:107-115`): `.application_name("thinktin/i1")`, built from the constant.
  - `Db::worker` (`lib.rs:150-158`): `SELECT set_config('role','thinktin_worker',true), set_config('statement_timeout',$1,true), set_config('thinktin.isolation',$2,true)` with `$2 = ISOLATION_LEVEL.to_string()`.
- **`Tx<Worker>::legacy_sessions() -> Result<u64>`:** `SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND application_name = 'thinktin'`. Not used in 8.16; 8.17's dispatcher calls it (D11).
- **`error.rs`** (`:57-76`): new variants, each with a gateway mapping.
  - `InstanceDedicated(String)`: 23514 with `db.constraint() == Some("instance_dedicated")`.
  - `Conflict("instance_not_free")`: 23514 with constraint `instance_not_free`.
  - `AgentNotIsolated`: raised in Rust.
  - `InstanceLimit { max: u64 }`: adopt inside a join.
  - `project_deleted`: 23514 with that constraint stays `Invalid`. The executor treats it as "run is gone".

### 2.2 Claim, takeover, expired waits, fence (`runs.rs`)

Fragments next to `lock_runs_where!` (`runs.rs:360-367`):

```rust
/// 运行和实例在同一个空间（8.16）：私人运行只在私人实例上领，项目运行只在专属于这个项目的实例上领（0055 runs_isolation）。
macro_rules! isolated { ($r:literal) => { concat!(
    "EXISTS (SELECT 1 FROM instances i WHERE i.id = ", $r, ".instance_id \
       AND i.workspace_project_id IS NOT DISTINCT FROM ", $r, ".project_id)") } }
/// 项目运行的 agent、主人的成员关系、项目都还在（只读不锁：退出在同一个事务里锁运行再取消，SKIP LOCKED 跳过它锁着的）。
macro_rules! live_space { ($r:literal) => { concat!(
    "(", $r, ".project_id IS NULL OR EXISTS (SELECT 1 FROM project_agents a \
       JOIN project_members m ON m.project_id = a.project_id AND m.user_id = a.user_id AND m.left_at IS NULL \
       JOIN projects p ON p.id = a.project_id AND p.status = 'active' \
      WHERE a.project_id = ", $r, ".project_id AND a.instance_id = ", $r, ".instance_id \
        AND a.user_id = ", $r, ".user_id AND a.left_at IS NULL))") } }
```

**`claim_next_run`** (`runs.rs:1006-1084`): the select becomes the following (the tested V9 shape):

```sql
SELECT r.id FROM runs r JOIN users u ON u.id = r.user_id AND u.status = 'active'
 WHERE r.kind = 'agent' AND r.source = ANY($1) AND {isolated!("r")} AND {live_space!("r")}
   AND r.not_before <= now() AND (
   (r.state = 'queued' AND NOT EXISTS (SELECT 1 FROM runs a WHERE a.instance_id = r.instance_id AND a.kind = 'agent'
        AND a.state IN ('starting','running','waiting_approval','waiting_device','waiting_quota','waiting_children','backoff'))
    AND (r.urgent OR NOT EXISTS (SELECT 1 FROM runs u WHERE u.instance_id = r.instance_id AND u.urgent
        AND u.state = 'queued' AND u.project_id IS NOT DISTINCT FROM r.project_id)))
   OR (r.state = 'backoff' AND (r.lease_owner IS NULL OR r.lease_expires_at < now()))
   OR (r.state IN ('waiting_quota','waiting_device') AND r.lease_owner IS NULL
       AND (r.wait_deadline IS NULL OR r.wait_deadline > now()))
   OR (r.state = 'waiting_children' AND r.lease_owner IS NULL AND NOT EXISTS (SELECT 1 FROM runs c
       WHERE c.parent_run_id = r.id AND c.state NOT IN ('succeeded','failed','cancelled'))))
 ORDER BY r.not_before, r.id LIMIT 1 FOR UPDATE OF r SKIP LOCKED
```

- `behind_urgent` (`:1040-1050`): `… AND u.project_id IS NOT DISTINCT FROM r.project_id`.
- Retries go through the backoff and waiting branches, so they get the same predicate.
- `take_over_expired` (`:1124-1149`): replace `AND project_id IS NULL` with `AND {isolated!("runs")}`.
- `claim_expired_waits` (`:1422-1448`): same.
- **No liveness in either:** an orphan is finished, and then the sweeper (2.5) or the claim's liveness stops it.
- `due_pipelines` (`:1562-1577`): unchanged (private only until 8.17).
- `acquire_lease`: unchanged. The trigger fences it.

### 2.3 Cancel lock order (D13)

The three helpers keep their filters. Only the order changes. Example for `cancel_project_runs` (`runs.rs:944-966`):

```rust
let locked: Vec<Uuid> = sqlx::query_scalar(lock_runs_where!("project_id = $1"))
    .bind(project.0).fetch_all(self.conn()).await?;          // 1. 运行
self.settle_cancelled_approvals(&locked).await?;              // 2. 审批 → 提醒（和 decide_approval 一样先审批后实例）
sqlx::query(bump_epochs_where!("project_id = $1")).bind(project.0).execute(self.conn()).await?;  // 3. 实例
let ids: Vec<Uuid> = sqlx::query_scalar("UPDATE runs SET state = 'cancelled', … WHERE project_id = $1 \
    AND state NOT IN ('succeeded','failed','cancelled') RETURNING id")…;  // 4. 按条件（锁之后新插的子运行也取消）
```

- `cancel_project_agent_runs` (`:860-898`) and `cancel_project_member_runs` (`:902-941`) change the same way. The trailing `settle_cancelled_approvals(&ids)` is removed.
- **D3 in `projects.rs:7-9`:** "… → 项目 agent 行 → 运行 → 审批 → 实例".
- **Erase** (`users.rs:243-251`): before `cancel_user_runs`, run `UPDATE approvals SET state='cancelled', decided_by='system', decided_at=now() WHERE state='pending' AND run_id IN (SELECT id FROM runs WHERE user_id=$1 AND state NOT IN ('succeeded','failed','cancelled'))`. Then mark the approval inbox items read as `settle_cancelled_approvals` does.
- **`finish_inner`** (orchestrator): `w.cancel_run_approvals(run)` moves to right after `transition_run` (`executor.rs:1161`), before `cancel_descendants`.

### 2.4 Space-aware queries

- **`unannounced_messages(instance, project: Option<ProjectId>, limit)`** (`runs.rs:1333-1347`): `… AND announced_at IS NULL AND NOT urgent AND project_id IS NOT DISTINCT FROM $3 …`.
- **`instance_holder(instance, space)` and `last_finished_run(instance, space)`** (`runs.rs:736-762`): `AND project_id IS NOT DISTINCT FROM $2`.
- **`Tx<Tenant>::peers(me)`** (`instances.rs:543-569`): `… FROM instances WHERE state <> 'deleted' AND id <> $1 AND peer_access AND workspace_project_id IS NULL …`; the holder subquery adds `AND r.project_id IS NULL`.
- **`delegation_targets(lead)`** (`instances.rs:572-589`): add `AND workspace_project_id IS NULL`.
- **`is_team_lead`:** unchanged; the executor never offers delegate in project runs.
- **Board** (`store/board.rs`): the list query (`:118`), the cap archive (`:132-133`) and the count (`:211`) add `AND p.project_id IS NULL` / `AND project_id IS NULL`.
- **`instances.rs` `columns!()` and `runtime_columns!()` (`:216-225`)** add `workspace_project_id`:
  - `Instance.dedicated_project_id: Option<ProjectId>`;
  - `InstanceRuntime.workspace_project_id: Option<ProjectId>`.
- **`mark_instance_purged`** (`instances.rs:789-803`): also `workspace_project_id = NULL`. The trigger reads `OLD`, so the project-prefixed key is still queued, and purge of the project row is no longer blocked by a deleted instance.

### 2.5 Orphan sweeper

```rust
/// 8.16：没结束、但 agent / 成员关系 / 项目已经不在的项目运行（退出、删除的事务本该取消它们；兜底，免得占着实例）。
pub async fn cancel_orphaned_project_runs(&mut self, limit: i64) -> Result<Vec<(RunId, InstanceId, bool)>>
```

```sql
SELECT r.id FROM runs r
 WHERE r.project_id IS NOT NULL AND r.state NOT IN ('succeeded','failed','cancelled')
   AND NOT EXISTS (SELECT 1 FROM project_agents a
        JOIN project_members m ON m.project_id = a.project_id AND m.user_id = a.user_id AND m.left_at IS NULL
        JOIN projects p ON p.id = a.project_id AND p.status = 'active'
       WHERE a.project_id = r.project_id AND a.instance_id = r.instance_id AND a.user_id = r.user_id AND a.left_at IS NULL)
 ORDER BY r.id LIMIT $1 FOR NO KEY UPDATE OF r SKIP LOCKED;
-- then: settle_cancelled_approvals(ids); UPDATE instances SET token_epoch = token_epoch + 1 WHERE id IN
--   (SELECT instance_id FROM runs WHERE id = ANY($1) AND kind='agent' AND state IN (<active states>));
-- UPDATE runs SET state='cancelled', state_reason='project_left', wait_code=NULL, lease_owner=NULL, lease_expires_at=NULL,
--   finished_at=now(), updated_at=now() WHERE id = ANY($1) RETURNING id, instance_id,
--   EXISTS (SELECT 1 FROM projects p WHERE p.id = runs.project_id AND p.status = 'deleted')
```

The executor calls it on its takeover tick (`executor.rs:561-647`, next to `expire_asks`). It appends `run.state` events only for runs whose project is not deleted (D17).

### 2.6 Dedicating, adopting, releasing, retiring (`project_members.rs`, `instances.rs`)

**`pub(crate) async fn retire_workspace(&mut self, instance: InstanceId, space: Option<ProjectId>, reason: &str) -> Result<()>`.** The caller holds the instance `FOR UPDATE` and has checked it is free.

```sql
INSERT INTO retired_workspaces (id, instance_id, user_id, workspace_id, sandbox_ids, reason)
  SELECT $2, id, user_id, workspace_id, array_remove(ARRAY[sandbox_id, restoring_sandbox_id], NULL), $3
    FROM instances WHERE id = $1 AND state <> 'deleted';
UPDATE instances SET workspace_project_id = $4, workspace_id = $5, state = 'provisioning',
   sandbox_id = NULL, sandbox_address = NULL, snapshot_id = NULL, sandbox_version = NULL, rebuild_pending = false,
   workspace_archive_key = NULL, workspace_archive_id = NULL, workspace_archive_bytes = NULL,
   workspace_archive_sha256 = NULL, workspace_archived_at = NULL, workspace_archive_pending = NULL,
   workspace_archive_pending_since = NULL, workspace_archive_failed_at = NULL, workspace_archive_error = NULL,
   restoring_sandbox_id = NULL, restoring_since = NULL, egress_hosts = '{}',
   token_epoch = token_epoch + 1, updated_at = now()
 WHERE id = $1;
DELETE FROM egress_requests WHERE instance_id = $1;
```

- `$5 = format!("ws-{}", Uuid::now_v7().simple())`, the same format as `control/src/lib.rs:274`. Move it into a `store::new_workspace_id()` helper and use it in control too.
- Then `append_event(instance, None, "instance.state", {"state":"provisioning","reset":reason})`.

**`free_instance_check(instance)`** runs after `FOR UPDATE`, with plain reads:
- no unfinished runs (`runs_instance` index);
- no active plan with `instance_id` or a step on it;
- no live `project_agents` row outside the target project.

On failure it returns `Conflict("instance_not_free: …")` with a specific message. The 0055 trigger is the backstop.

**`dedicate_project_agent(user, project, instance) -> Result<()>`** (PATCH). D3 order:
1. `project_actor(user, project, &[], &[Active])` (users → project lock → my member row).
2. `SELECT … FROM project_agents WHERE project_id=$1 AND instance_id=$2 AND left_at IS NULL FOR NO KEY UPDATE`. Owner ≠ `user` → `NotPermitted`; missing → `NotFound`.
3. `lock_instance(instance)` (`FOR UPDATE`).
4. `free_instance_check`.
5. `retire_workspace(instance, Some(project), "dedicate")`.
6. `UPDATE run_grants SET revoked_at = now(), revoke_reason = 'instance_dedicated' WHERE instance_id = $1 AND project_id IS NULL AND revoked_at IS NULL` (column names as in `revoke_user_grants`).
7. `UPDATE project_agents SET dedicated = true WHERE …` (the trigger derives true).
8. Audit `project.agent.dedicate`.

**Join and add terms** (`project_invites.rs:66-73`):

```rust
pub enum JoinAgent {
    Existing { id: InstanceId, dedicate: bool, ack_shared_memory: bool },
    Adopt(NewInstance),            // 总是专属；NewInstance 由 control::new_instance(templates, spec) 生成
}
pub struct JoinTerms { pub agents: Vec<JoinAgent>, pub daily_token_limit: u64, pub total_token_limit: u64,
                       pub consent: Consent, pub mixed_allowed: bool, pub max_instances: u64 }
```

- `check_agent_ids` (`project_members.rs:51-63`) counts all entries (1–30) and checks duplicates among `Existing`.
- `put_agents(project, user, &[(Uuid, bool /*ack*/)], consented)` writes `shared_memory_ack_at = CASE WHEN ack THEN now() END` on insert and on revive. It drops `dedicated = false` (`:140-141`); the trigger derives it.

**`accept_invite`** (`project_invites.rs:503-664`). Inside the existing D3 order:
1. After the member-row lock, take `pg_advisory_xact_lock(hashtextextended('instances/'||user,0))` (step 4, a "narrow advisory lock"; the same key as `instances.rs:259-270`) when any `Adopt` is present. Count non-deleted instances against `max_instances` → `InstanceLimit`.
2. `lock_own_instances` (`project_members.rs:100-119`) walks `Existing` ids **in id order**, taking each row `FOR UPDATE` if `dedicate` and `FOR SHARE` otherwise. Deterministic order, no upgrade, no deadlock between accepts.
3. Every `Existing{dedicate:false}`: `mixed_allowed` false → `AgentNotIsolated`; `!ack_shared_memory` → `Invalid`. Every join counts as shared.
4. `Existing{dedicate:true}`: `free_instance_check`, `retire_workspace(Some(p),"dedicate")`, revoke its private grants.
5. `Adopt(n)`: `INSERT INTO instances (id, user_id, agent_id, agent_version, harness, name, workspace_id, limits, workspace_project_id) VALUES (…, $p)`, then `append_event(instance.state)`.
6. `put_agents` for all, then the invite settles as today.

`Accepted.agents` returns the new ids too.

**`add_project_agents`** (`project_members.rs:163-196`) takes `&[JoinAgent]`, `mixed_allowed` and `max_instances`. The rules are the same, and "shared" is `projects.shared_at IS NOT NULL` read under the project lock.

**`release_instance(user, instance) -> Result<Instance>`:**
1. `lock_users(&[user])`.
2. Read `workspace_project_id` (plain read; NULL → `Invalid("not dedicated")`).
3. `lock_project(p)`.
4. `lock_instance` `FOR UPDATE`.
5. A live `project_agents` row for it → `Conflict("withdraw it from the project first")`; unfinished runs → `Conflict`.
6. `retire_workspace(None, "release")`.
7. Audit `instance.release`.

The private grant is re-issued lazily by `ensure_instance_grant` (`routes/runs.rs:67-91`).

**Delete project** (`project_lifecycle.rs:129-190`): after `stop_project(…, true)` (`:165-166`), add `retire_project_workspaces(p)`:

```sql
SELECT id FROM instances WHERE workspace_project_id = $1 AND state <> 'deleted' ORDER BY id FOR UPDATE
```

For each, run `retire_workspace(id, None, "project_deleted")`. Its runs were just cancelled. The `instances_dedicated_alone` trigger does not fire, because the new value is NULL.

**Erase** already sets `dedicated = false` on the user's agent rows (`users.rs:244-250`). Their instances become deleted and are purged; `mark_instance_purged` clears `workspace_project_id`.

### 2.7 Purge (`project_lifecycle.rs:276-366`)

Add these steps to the `for sql in [...]` list, **before** the events and runs steps:

```sql
DELETE FROM egress_requests WHERE id IN (SELECT id FROM egress_requests WHERE project_id = $1 LIMIT $2 FOR UPDATE SKIP LOCKED)
DELETE FROM vault_requests WHERE id IN (SELECT id FROM vault_requests WHERE project_id = $1 LIMIT $2 FOR UPDATE SKIP LOCKED)
DELETE FROM device_calls WHERE id IN (SELECT id FROM device_calls WHERE project_id = $1 LIMIT $2 FOR UPDATE SKIP LOCKED)
DELETE FROM board_posts WHERE id IN (SELECT id FROM board_posts WHERE project_id = $1 ORDER BY id LIMIT $2 FOR UPDATE SKIP LOCKED)
DELETE FROM content_reports WHERE id IN (SELECT id FROM content_reports WHERE project_id = $1 AND state = 'closed' LIMIT $2 FOR UPDATE SKIP LOCKED)
```

- **Backstop retire** (Rust, before the leftover check): `SELECT id FROM instances WHERE workspace_project_id = $1 AND state <> 'deleted' ORDER BY id FOR UPDATE SKIP LOCKED`, then `retire_workspace(…, None, "project_deleted")` for each.
- **Leftover check** (`:343-353`): add `OR EXISTS (SELECT 1 FROM instances WHERE workspace_project_id = $1)` and the four SET NULL tables. Open `content_reports` are not counted (there is no FK to projects).
- **At the top of the function**, once per call: `DELETE FROM content_reports WHERE id IN (SELECT id FROM content_reports c WHERE c.state = 'closed' AND c.project_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM projects p WHERE p.id = c.project_id) LIMIT $2 FOR UPDATE SKIP LOCKED)`.

---

## 3. Orchestrator, control, sandbox, agent-shim

### 3.1 What each backend and harness provides

For dedicated instances there is no code change in `crates/sandbox` or `crates/agent-shim`.

| Backend | Isolation for a dedicated instance | Retire | Archive |
|---|---|---|---|
| **Local** (`sandbox/src/local.rs:1-9`) | Host directory and process groups only. A dev/test backend; no boundary even between private instances. `resolve` accepts any path under `volumes/` (`local.rs:178-181`). | `destroy` removes `sandboxes/<id>`; `delete_workspace` removes `volumes/<ws>` (`:376-395`) | Not used (volumes persist) |
| **Cube** (one KVM microVM per sandbox) | Own kernel, processes, `/tmp`, loopback (OpenClaw's fixed `127.0.0.1:18789` is fine), envd and volume `ws-…` mounted at `/sandbox/workspace` (`cube.rs:404-461`) | `DELETE /sandboxes/{id}` (`cube.rs:580-612`) plus `DELETE /volumes/{id}` (`:614-630`). Snapshots are unused by control (no `snapshot(` call in `control/src/lib.rs`). | Only without volumes: `projects/<p>/workspaces/…`, project DEK |
| **ACS** (one Pod per sandbox) | Own Pod, IP (the token binds `net`), `/tmp`; no volumes (`acs.rs:402-404`) | Pod delete (`acs.rs:545-576`); `delete_workspace` is a no-op | Always: `projects/<p>/workspaces/…`, project DEK, OSS |

Per harness, all state is under HOME = `/sandbox/workspace/.thinktin/home` and cwd = `/sandbox/workspace` (`exec.rs:115-118,206`; `agent-shim/src/config.rs:142`). For a dedicated instance that is project-only:

| Harness | State |
|---|---|
| Claude | `CLAUDE_CONFIG_DIR=$HOME/.claude`, project memory under it (`config.rs:163-197`) |
| Codex | `CODEX_HOME` (`:213-243`) |
| Pi | `PI_CODING_AGENT_DIR` with models, settings and MCP config (`:269-295,475-489`) |
| OpenClaw | `OPENCLAW_STATE_DIR` with session key `agent:main:thinktin`; AGENTS.md and SOUL.md in cwd (`:300-371`) |
| Hermes | `HERMES_HOME` with skills and memory (`:380-423`) |
| All | Shim session slot `$HOME/.thinktin/shim-session.json` (`state.rs:16-37`); bridge socket and vault helper under `$HOME/.thinktin` (`bridge.rs:105-134`, `main.rs:521-530`); browser profile in the sandbox's `/tmp`; outputs in `cwd/.thinktin/browser` (`browser/launch.rs:31-36`) |

A fresh dedicated workspace has no `shim-session.json`, so `session/load` is not attempted and the first project run starts a new session. A reset workspace is the same.

### 3.2 `crates/control`

- **`workspace.rs`:**
  - `pub enum ArchiveOwner { User(UserId), Project(ProjectId) }` and `fn of(rt: &InstanceRuntime) -> ArchiveOwner`, from `rt.workspace_project_id` and else `rt.user_id`.
  - `WorkspaceStore::key(&self, owner, workspace, id)` gives `workspaces/<u>/<ws>/<id>` or `projects/<p simple>/workspaces/<ws>/<id>` (`:40-42`).
  - `put`, `delete` and `restore` take `owner` instead of `user` (`:37-78`).
- **`lib.rs` call sites:** `:1480` (`key`), `:1671` (`delete`), `:1771` (`put`), `:1820` (`restore`) pass `ArchiveOwner::of(&rt)` from the runtime read under the instance lock.
  - **Races are covered by existing logic:** a retire in the middle makes the commit `Superseded`, and the object is deleted under the owner it was written with.
- **`Lifecycle::sweep`** (`:881-985`): a new last step, `retired`.
  - `w.retired_workspaces_due(batch)` is `SELECT … FROM retired_workspaces WHERE retry_at <= now() ORDER BY retry_at LIMIT $1 FOR UPDATE SKIP LOCKED`.
  - For each: `provider.destroy` on every `sandbox_ids` entry (NotFound is OK), then `provider.delete_workspace(workspace_id)`, then `DELETE` the row.
  - On error: `attempts+1`, `retry_at = now() + least(2^attempts, 60) min`, `last_error`.
  - `SweepReport.retired += 1`.
- **`pub fn new_instance(templates, spec: AdoptSpec) -> Result<store::NewInstance>`** wraps `resolve` (`:234-265`) and uses `store::new_workspace_id()`. The gateway uses it for `adopt` entries.
- **`ensure_running`:** unchanged. A retired instance is `Provisioning` with no sandbox, so it goes to `create` (`:769-771`).

### 3.3 `crates/orchestrator`

- **`workspaces.rs` (`ObjectWorkspaceStore`):**
  - `check_owner(owner, key)` checks the prefix for that owner (`:185-193`).
  - The vault and subject come from the owner: `User(u)` uses `user_vault(db, kms, u, create)` with subject `u.to_string()`; `Project(p)` uses `artifacts::project_vault(db, kms, p, create)` with subject `project_key_context(p)`. `put` uses `create = true`, `restore` uses `create = false`.
  - `ArtifactError::Gone` on restore becomes "the project was deleted; its workspace archive can no longer be opened".
- **`shim.rs`:**
  - `ToolContext` (`:67-75`) gains `pub project: Option<ProjectId>` (Copy).
  - `ShimLaunch` (`:16-30`) gains `pub space: Option<ProjectId>`.
- **`exec.rs` `start`** (`:162`): before anything, `if launch.space != launch.instance.workspace_project_id { return Err(ConnectError("the sandbox belongs to another space".into())) }`. The argv is unchanged.
- **`tools.rs`:**
  - `pub const PROJECT_RUN_TOOLS: [&str; 5] = ["artifact_publish","artifact_list","artifact_read","artifact_fetch","web_search"];` and `pub fn allowed_in_space(name: &str, project: Option<ProjectId>) -> bool`.
  - `ToolSet::call` (`:433-440`) returns `ToolOutput::error("{name} is not available in project work yet")` when `!allowed_in_space`.
  - `ArtifactTools::origin` (`:481-506`): `if rt.workspace_project_id != ctx.project { return Err(Fail("this agent's workspace belongs to another space".into())) }`. This covers publish `path=` (`:508-535`) and `fetch` (`:639-659`).
  - The single `workdir` stays, because the sandbox is per space.
- **`pipeline.rs` `HandoffCopier::copy`** (`:438-479`): the same space check at the top.
- **`executor.rs` `start`** (`:724-995`):
  - After `ensure_running`: `if rt.workspace_project_id != rec.run.project_id { return Err(Outcome::Failed("the instance is not isolated for this run's space".into())) }`.
  - **Grant:** `(Some(g), _) => g`, `(None, None) => active_grant_for_instance…`, `(None, Some(_)) => Err(Outcome::Failed("a project run needs its project grant".into()))` (replacing `:744-752`).
  - `lead = rec.run.project_id.is_none() && …` (`:771-776`).
  - `has_computer = rec.run.project_id.is_none() && …` (`:803-804`).
  - **Preface** (`:787-802`): when `h.project_id != rec.run.project_id`, use `texts::interrupted_project_work(locale)` (new: "项目里的一项任务" / "a task in a project") and do not quote `task_title`.
  - **Tool filter** (`:839-852`): add `.filter(|t| crate::tools::allowed_in_space(&t.name, rec.run.project_id))`.
  - `ShimLaunch { space: rec.run.project_id, … }` and `ToolContext { project: rec.run.project_id, … }`.
  - **Resume brief** (`:926-951`): unchanged. It reads only this run's events, so it is same-space by construction; covered by a test.
- **`executor.rs`, other changes:**
  - `new_messages` (`:1506-1535`) passes `self.rec.run.project_id`.
  - `reveal` (`:2009`): `if self.ctx.project.is_some() { return Err("the password vault is not available in project work yet".into()) }`.
  - The takeover tick calls `cancel_orphaned_project_runs(20)` and logs `run.state` for each cancelled run.
  - Run notices set `Notice.project = rec.run.project_id` (the inbox guard accepts a worker-written project equal to the run's project, `0054:176-191`).
  - A worker append that fails with `Invalid("project_deleted")` is logged at debug and treated as "run gone".
- **`outbox.rs` `notify`** (`:209-226`): `if notice.project.is_none()` around the IM channel loop. Project notices go to the inbox and push only, until 8.19.
- **`projects.rs`** (orchestrator):
  - `accept` (`:275-323`) and `add_agents` (`:348-376`) take the new terms. The audits `project.join` and `project.agents.add` record per agent `{instance, dedicated, adopted, reset, ack_shared_memory}`.
  - New `dedicate_agent` (audit `project.agent.dedicate`) and `release_instance` (audit `instance.release`).
  - After commit, when anything was dedicated, call `artifacts::project_vault(db, kms, p, true)` as a best effort (warn on failure). This eagerly creates the project DEK (D8). The wrappers take `kms: Arc<dyn Kms>` from `AppState`.
- **`ask.rs`, `delegate.rs`, `peers.rs`:** their target lists come from 2.4. `store::Error::InstanceDedicated` from a child insert maps to `ToolOutput::error("that agent works only for a project and cannot take private tasks")`.
- **`scheduler.rs:184`, `pipeline.rs:250-262`, `gateway hooks.rs:312`:** the 0055 plans and steps triggers make these unreachable. As a backstop, `InstanceDedicated` on a scheduler fire pauses the plan (`w.set_plan_status(plan, Paused)` plus audit) instead of failing the tick.

### 3.4 agent-shim

No code change (D21). One regression test in `crates/agent-shim/tests/shim.rs` if it is missing: a HOME with no `shim-session.json` gives `Ready{session_restored:false}`, and the fake agent receives no `previous_session`.

---

## 4. Dedicated instances and the non-dedicated warning

**Data:** `instances.workspace_project_id`, the derived `project_agents.dedicated`, `project_agents.shared_memory_ack_at`, `retired_workspaces` (§1.1).

**DTOs (proto):**
- `Instance.dedicated_project_id: Option<ProjectId>` (`#[serde(default, skip_serializing_if = "Option::is_none")]`, `domain.rs:521-544`).
- `ProjectAgentView.dedicated: bool` (`#[serde(default)]`, `domain.rs:1062-1075`). It is selected as `a.dedicated` at `project_reads.rs:444-449`; the member grant already exists (`0049:84`).

**Consent and preview** (`domain.rs:607,1150-1188`):
- `PROJECT_CONSENT_VERSION = 2`.
- `project_consent::DEDICATED_AGENT = ["dedicated_takes_no_private_tasks", "dedicated_memory_holds_only_this_project", "dedicated_existing_agent_is_reset"]`.
- `project_consent::MIXED_AGENT = ["mixed_private_memory_may_enter_project", "mixed_project_content_may_stay_in_memory"]`.
- `ProjectInvitePreview` gains `#[serde(default)] dedicated_agent: Vec<String>`, `mixed_agent: Vec<String>` and `mixed_agents_allowed: bool`. The store fills the keys (`project_invites.rs:712-719`); the gateway sets `mixed_agents_allowed` from config.
- The distinct-keys test at `domain.rs:1840-1856` covers all four lists.

**Private entry points a dedicated instance refuses:**

| Entry point | Behaviour |
|---|---|
| `POST /v1/instances/{id}/runs`, both deliveries (`routes/runs.rs:31-64`), and `ensure_instance_grant` (`:67-91`) | 409 `instance_dedicated`, checked first from `instance.dedicated_project_id`; the DB is the backstop (D4) |
| Vault `resume_after_request` (`routes/vault.rs:408-439`) | Skipped when `instance.dedicated_project_id.is_some()` or `request.project_id.is_some()`. `t.run(run)` NotFound means no resume instead of an error |
| `POST /v1/plans` and `PATCH /v1/plans/{id}` (instance or steps), plan resume (`routes/plans.rs:143,273,379`) | 409 `instance_dedicated` (pre-check plus trigger) |
| Webhook receive (`hooks.rs:312`) | 409; unreachable because active plans cannot point at a dedicated instance |
| `ask`, `delegate` from private runs | Not listed as targets; insert refused |
| `/v1/projects` create, `/v1/teams*` PUT with an instance dedicated elsewhere | 409 `instance_dedicated` (trigger) |
| Adopt (`routes/instances.rs:33-55`) | Never creates dedicated instances; dedicated ones are only created by join/add `adopt` |

These remain allowed on a dedicated instance:
- `PATCH /v1/instances/{id}` (name, purpose, peer access, egress);
- `PUT /v1/instances/{id}/routes`;
- version change;
- archive;
- delete.

---

## 5. Gateway and client-core

### 5.1 Config

- `GatewayConfig.mixed_project_agents: bool` (default false, `gateway/src/lib.rs:46-61`).
- Server `[api] mixed_project_agents` (`server/src/config.rs:141-169`). The doc says: turn on only with a release whose isolation level is at least 2.

### 5.2 Routes

**`POST /v1/project-invites/{id}/accept` and `POST /v1/project-invites/accept`** (`project_invites.rs:72-146`; still behind `cross_user()`):

```json
{ "agents": [
    { "adopt": { "agent_id": "claude", "harness": "acp", "name": "项目助手" } },
    { "instance_id": "0195…", "dedicated": true, "reset_workspace": true },
    { "instance_id": "0195…", "ack_shared_memory": true } ],
  "daily_token_limit": 200000, "total_token_limit": 2000000,
  "consent": true, "consent_version": 2, "token": "tpi1_…" }
```

- `JoinAgent` (`:72-75`) becomes `{ instance_id: Option<InstanceId>, adopt: Option<AdoptReq>, #[serde(default)] dedicated, reset_workspace, ack_shared_memory }`. Exactly one of `instance_id` and `adopt`, otherwise 422. `dedicated` without `reset_workspace: true` gives 422.
- `adopt` is resolved with `control::new_instance(s.templates, …)`, with the same errors as `instances::adopt`.
- `max_instances` comes from `[api.limits] instances_per_user`.
- **201 or 200:** `ProjectDetail` (agents carry `dedicated`).
- **Errors:**
  - 422 `invalid`: consent or version, missing acknowledgement, missing reset, bad entry;
  - 409 `agent_not_isolated`;
  - 409 `instance_dedicated` (dedicated to another project);
  - 409 `conflict` (`instance_not_free`: unfinished work, active plans, other projects);
  - 409 `instance_limit`;
  - 409 `project_agent_limit` / `project_member_limit`;
  - 404 for the invite.

**`POST /v1/projects/{id}/agents`** (`projects.rs:212-244`): `AgentReq` (`:63-69`) gains the same `adopt`, `dedicated`, `reset_workspace` and `ack_shared_memory`, plus `consent_version`. Same errors, plus 403 / 404 as today. Mixed agents need the acknowledgement only when the project has `shared_at`.

**`POST /v1/projects` (tenant solo create):** `adopt` or `dedicated` gives 422 ("add dedicated agents with POST /v1/projects/{id}/agents").

**New `PATCH /v1/projects/{id}/agents/{instance_id}`** with `{"dedicated": true, "reset_workspace": true}`:
- 200 `ProjectDetail`;
- 404 when not a member or the agent is not in the project;
- 403 when not your agent;
- 409 `conflict` (`instance_not_free`);
- 409 `instance_dedicated`;
- 422 for `dedicated: false` or a missing `reset_workspace`.

It goes on the same route as `withdraw_agent` (`mod.rs:214-217`, `patch(projects::set_agent)`) and is not behind `cross_user()`.

**New `POST /v1/instances/{id}/release`** (instances router, `mod.rs:69-89`):
- 200 `Instance`;
- 404;
- 422 if not dedicated;
- 409 `conflict` ("withdraw it from the project first", or unfinished work).

**Instance JSON:** `"dedicated_project_id": "<uuid>"` is present when set.

**Error mapping** (`gateway/src/error.rs:66-97`):
- `InstanceDedicated` → `ErrorCode::InstanceDedicated`;
- `AgentNotIsolated` → `ErrorCode::AgentNotIsolated`;
- `InstanceLimit { max }` → `ErrorCode::InstanceLimit`.

`ErrorCode::http_status` returns 409 for both new codes (`proto/src/api.rs:69-77`).

**`consent()`** (`projects.rs:43-48`) becomes `consent(given, version: Option<u32>)`, returning `Consent { version: version.unwrap_or(1) }`.

**`/v1/egress-requests`, `/v1/board`, vault request lists, `/v1/reports`:** no code change; the 0056 policies hide project rows after leaving.

### 5.3 client-core (`crates/client-core`)

- **`api.rs`:**
  - `pub enum ProjectJoinAgent { Existing { instance_id, dedicated, reset_workspace, ack_shared_memory }, Adopt { agent_id, harness: Option<String>, name } }` with `fn json()`.
  - `ProjectJoin.agents: Vec<ProjectJoinAgent>`. `body()` (`:92-118`) adds `"consent_version": PROJECT_CONSENT_VERSION` when consenting.
  - `add_project_agents(id, &[ProjectJoinAgent], consent)` (`:1944-1958`).
  - New `set_project_agent_dedicated(id, instance)` (PATCH) and `release_instance(instance) -> Instance`.
- **`ffi.rs`:**
  - `#[derive(uniffi::Record)] ProjectJoinAgent { #[uniffi(default = None)] instance_id: Option<String>, #[uniffi(default = None)] adopt: Option<ProjectAdopt>, #[uniffi(default = false)] dedicated: bool, #[uniffi(default = false)] reset_workspace: bool, #[uniffi(default = false)] ack_shared_memory: bool }` and `ProjectAdopt { agent_id: String, #[uniffi(default = None)] harness: Option<String>, name: String }`. Exactly-one validation gives `ClientError` invalid.
  - `ProjectJoin { agents: Vec<ProjectJoinAgent>, daily_token_limit, total_token_limit, consent }` (replacing `instance_ids`, `:1301-1325`).
  - `add_project_agents(project_id, agents: Vec<ProjectJoinAgent>, consent)` (`:3255-3272`).
  - New `set_project_agent_dedicated(project_id, instance_id, reset_workspace) -> ProjectDetail`, `release_instance(instance_id) -> Instance`, and `#[uniffi::export] fn project_consent_version() -> u32`.
  - `Instance.dedicated_project_id: Option<String>` `#[uniffi(default = None)]` (`:263-287`).
  - `ProjectAgent.dedicated: bool` `#[uniffi(default = false)]` (`:952-977`).
  - `ProjectInvitePreview.dedicated_agent` / `mixed_agent` (`#[uniffi(default = [])]`) and `mixed_agents_allowed` (`#[uniffi(default = false)]`) (`:1080-1126`).
- **`error.rs`:** docs for `instance_dedicated` and `agent_not_isolated`.
- **`cache.rs`:** no change. Instances are stored as JSON (`:29`); project runs are already skipped.
- **`tools/client-core/ffi_smoke.py`:** the new shapes.

### 5.4 Android

Regenerate `apps/android/core/src/main/kotlin/cn/thinktin/core/client_core.kt` with `tools/client-core/gen-bindings.sh`, in its own commit.

---

## 6. Tests

### 6.1 Store: new `crates/store/src/tests/isolation.rs` (`mod isolation;` in `tests.rs`)

Real Postgres, migrated by the non-superuser owner.

1. **`claim_takes_dedicated_project_runs_only`:**
   - private instance A, dedicated instance B in P, mixed instance C in P;
   - queued runs: private on A, project on B, project on C;
   - the worker claims A and B, never C;
   - after `exit_member` / `withdraw` / archive / soft delete of P, B's queued project run is not claimed;
   - urgent precedence: a queued urgent project run on C does not block A's private run.
2. **`old_claim_sql_never_returns_project_runs`:** the exact 8.15 SQL of `claim_next_run`, `take_over_expired`, `claim_expired_waits` and `due_pipelines` (copied from `6724b7f`, `runs.rs:1013-1031,1131-1139,1429-1437,1564-1569`) returns nothing for B's live dedicated project run.
3. **`lease_fence_refuses_without_isolation`:**
   - in a `SET ROLE thinktin_worker` transaction **without** the setting, every lease-acquiring statement (the four above with the filter removed, plus `acquire_lease`) on B's or C's project run gives `Forbidden`;
   - with level 1, B works and C is refused;
   - renew and release work without the setting.
4. **`dedicated_instances_refuse_private_work`:** tenant `create_run`, `queue_urgent_run`, `create_run_grant`, plan create, plan resume, step insert, and `create_solo_project` / `replace_my_project_agents` with B give `InstanceDedicated`. The same inserts as worker are refused too.
5. **`dedicate_races_private_message`** (barrier, 20 rounds): `dedicate_project_agent(A)` against tenant `create_run(A)`. Exactly one succeeds, and there is never a non-terminal private run on a dedicated instance (`SELECT … JOIN instances WHERE workspace_project_id IS NOT NULL AND r.project_id IS NULL`).
6. **`dedicating_retires_the_workspace`:**
   - with a fake `workspace_archive_key` and `sandbox_id` on A: dedicate;
   - `retired_workspaces` has the old ids;
   - `blob_purge` has the old key;
   - new `workspace_id`, `state = 'provisioning'`, epoch +1;
   - private grants revoked, `egress_requests` gone, `egress_hosts` empty;
   - refusals: unfinished runs, an active plan, a live row in another project (each `Conflict("instance_not_free…")`).
7. **`accept_with_adopt_is_atomic`:**
   - `JoinAgent::Adopt` creates the instance with `workspace_project_id = p` and a dedicated row, and no private grant;
   - a join that fails afterwards (agent limit, consent version 1) leaves no instance;
   - `max_instances` gives `InstanceLimit`;
   - a repeat accept returns the same agents.
8. **`mixed_agents_need_the_switch_and_the_ack`:**
   - shared project with `mixed_allowed = false` → `AgentNotIsolated`;
   - true without the acknowledgement → `Invalid`;
   - true with it → `shared_memory_ack_at` set;
   - solo never-shared add → no acknowledgement needed.
9. **`dedicated_flag_is_derived`:** `put_agents` revive keeps `dedicated`; erase sets false on left rows; the old test at `tests.rs:1559-1598` keeps passing.
10. **`run_linked_rows_carry_the_project`:**
    - for each of the six tables: insert as the proper role (tenant / worker / `Db::llmgw` for `egress_requests`) and `project_id` equals the run's;
    - after `exit_member`, a tenant insert with that run gives `Invalid` (23503);
    - `UPDATE … SET project_id` is refused;
    - deleting the run keeps `project_id` with `run_id` NULL;
    - `touch_request` to a run of another space is refused;
    - tenant SELECT hides the rows after leaving.
11. **`purge_clears_project_rows_and_dedicated_workspaces`:**
    - P with rows in all six tables and a dedicated instance: `delete_project` retires it in the same transaction (instance private, archive key queued);
    - `purge_deleted_projects` deletes the rows and the project row;
    - an open content report survives, and after it is closed the next purge call deletes it.
12. **`cancel_and_decide_do_not_deadlock`:** run in `waiting_approval` with a pending approval; barrier between tenant `decide_approval` + `append_event` and worker `cancel_project_runs`; 30 rounds, never 40P01. Repeat with the member and agent variants.
13. **`orphan_sweeper_frees_the_instance`:** a backoff project run whose agent row was marked left by raw SQL, so the exit's cancel is skipped. `cancel_orphaned_project_runs` cancels it, settles its approval, bumps the epoch, and a private run on another instance is untouched.
14. **`worker_cannot_append_to_deleted_projects`:** `append_event` on a run of a deleted project gives `Invalid("project_deleted")`; the tenant gets `Invalid(reference …)`.
15. **`legacy_sessions_counts_old_application_names`:** a second pool with `application_name = "thinktin"` gives `legacy_sessions() >= 1`; with `"thinktin/i1"` it gives 0.
16. **Space filters:** `unannounced_messages` per space; `peers` and `delegation_targets` skip B; `instance_holder` / `last_finished_run` per space; the private board list and cap ignore project posts.

### 6.2 control (`crates/control/tests/lifecycle.rs`, `workspaces.rs`)

- **`dedicated_archive_is_owned_by_the_project`:** `PodProvider` + `MemStore`. Archiving B records `ArchiveOwner::Project(p)` and a `projects/<p>/workspaces/` key; restore passes the same owner.
- **`sweep_destroys_retired_workspaces`:** after `retire_workspace`, `sweep` calls `destroy` for both sandbox ids and `delete_workspace(old ws)`, then deletes the row. A `Flaky` provider error schedules a retry.
- **`retire_during_restore_removes_the_new_sandbox`:** with a restore in flight, retire; the restore's bind sees the mismatch and removes the orphan (`:1078-1083`).

### 6.3 orchestrator (`crates/orchestrator/tests/`)

- **`projects.rs` / new `isolation.rs`** (FakeConnector from `executor.rs:54-90`, `LocalProvider` in a tempdir):
  - **`project_run_gets_only_project_tools`:** the grant lists vault, board, schedule, delegate, ask and peers. The launch has only `PROJECT_RUN_TOOLS`, `ShimLaunch.space = Some(p)` and `ToolContext.project = Some(p)`. `ToolSet::call` of each refused tool returns an error. A `VaultReveal` event gets an error. Computer tools are absent even with a computer.
  - **`project_run_without_grant_fails`:** `run_grant_id = None` gives `Failed`; `active_grant_for_instance` is never used.
  - **`space_mismatch_is_refused`:** a project run on a mixed instance forced past claim fails in `start`; `ExecConnector::start` refuses (unit test in `exec.rs`); `ArtifactTools` fetch and publish refuse; `HandoffCopier` refuses.
  - **`piggyback_and_preface_stay_in_space`:** a queued private message on a mixed instance is not piggybacked onto a project run, and the reverse. An interrupt across spaces uses the generic preface.
  - **`project_session_cannot_see_private_files`** (LocalProvider):
    - write `workspace/.thinktin/home/.claude/memory.md`, `workspace/notes.txt` and a fake `shim-session.json` into A;
    - dedicate A, then `ensure_running`;
    - in the new sandbox `read_file` gives NotFound for all three, and `artifact_publish path=notes.txt` in a project run gives an error;
    - after `sweep`, `volumes/<old ws>` is gone.
  - **`released_instance_forgets_project_files`:** the reverse. Project files in B, `release_instance`, the private run's fresh workspace lacks them, and the old volume is swept.
  - **`left_members_instances_stop`:** a running dedicated project run (fake shim blocking). `leave` in parallel → renew false → `Outcome::Cancelled`, shim killed, epoch bumped (`grants.sandbox_token` with the old epoch is rejected by `llm-gw/src/proxy.rs:404-431` logic in an llm-gw unit), queued project runs of that member no longer claimed. The instance keeps `workspace_project_id`, and a private message gets 409.
  - **`project_notices_skip_im`:** a finished project run's notice is in the inbox with `project_id`, and the outbox has a push item but no IM item.
  - **`resume_brief_reads_only_its_run`:** two runs on B; the brief of run 2 contains only run 2's tool titles.
- **`workspaces.rs`** (real `ObjectWorkspaceStore`, local blob store and KMS):
  - **`dedicated_archive_needs_the_project_key`:** put with `Project(p)`; restore with `User(owner)` fails (prefix and key); restore with `Project(p)` works.
  - **`deleted_project_workspaces_are_undecryptable`:** after `delete_project` (key destroyed), restore gives the "project was deleted" error; the blob is queued once the instance is retired.
  - **`private_archive_cannot_be_opened_with_the_project_key`.**

### 6.4 agent-shim

`serve_with_empty_home_starts_a_new_session` (§3.4).

### 6.5 Gateway (`crates/gateway/tests/api.rs`)

- Join with `adopt` + `dedicated` + `ack`; `consent_version` 1 or missing gives 422; mixed with the switch off gives 409 `agent_not_isolated`; switch on without acknowledgement gives 422, with it 201; an instance dedicated to another project gives 409 `instance_dedicated`.
- `PATCH /v1/projects/{id}/agents/{instance}`: 200; 403 for someone else's agent; 409 while it has a queued run; 422 without `reset_workspace`.
- `POST /v1/instances/{id}/release`: 409 while it is in the project; 200 after withdrawing; 422 on a private instance.
- Private message, plan create and plan resume on a dedicated instance give 409 `instance_dedicated`; `Instance` JSON carries `dedicated_project_id`; `ProjectDetail.agents[].dedicated`; the preview has the new keys and `mixed_agents_allowed`.
- **Old-client checks:** `GET /v1/instances/{dedicated}/events` and the WS return no project-run events; `/v1/egress-requests` hides project rows after leaving.

### 6.6 client-core (`crates/client-core/tests/client.rs`)

- Accept sends per-agent entries and `consent_version = 2`; `add_project_agents` entries; `set_project_agent_dedicated` and `release_instance` paths and JSON.
- `Instance` decodes with and without `dedicated_project_id`; `ProjectAgent.dedicated` defaults to false; `project_consent_version() == 2`.
- FFI validation of "exactly one of `instance_id` or `adopt`"; `tools/client-core/ffi_smoke.py`.

---

## 7. Commit sequence

Each commit compiles, passes `cargo test --workspace`, fmt and clippy, is pushed immediately, and updates `docs/progress/claude-determined-lovelace-vn0j5h.md`. The claim opens only after the executor, tools and workspaces handle the space (C8 comes after C6–C7).

| # | Commit | Files |
|---|---|---|
| C1 | proto: `ErrorCode::{InstanceDedicated, AgentNotIsolated}`, `Instance.dedicated_project_id`, `ProjectAgentView.dedicated`, consent v2 keys and preview fields; store error variants; gateway error mapping | `proto/src/{api,domain}.rs`, `store/src/error.rs`, `gateway/src/error.rs` |
| C2 | Migration 0055; store `columns!`/`runtime_columns!`, `Db::worker` isolation setting, `application_name`, `legacy_sessions`, `mark_instance_purged`; fixture updates (`tests.rs:1190`, `tests/projects.rs:1789,2397`); schema and owner tests; isolation tests 3, 4, 14, 15 | `store/migrations/0055_*.sql`, `store/src/{lib,instances,schema}.rs`, tests |
| C3 | Migrations 0056–0058; board private filter; purge steps and leftover check; content-report cleanup; tests 10, 11 (table part) | `store/migrations/0056_*.sql`, `0057_*.sql`, `0058_*.sql`, `store/src/{board,project_lifecycle}.rs`, tests |
| C4 | Store: cancel lock order (three helpers and erase), space-aware `unannounced_messages`/holder/peers/delegation, orphan sweeper; tests 12, 13, 16 | `store/src/{runs,instances,users}.rs`, tests |
| C5 | Store: `retire_workspace`, `dedicate_project_agent`, `release_instance`, `JoinAgent`/`JoinTerms`, `accept_invite`/`add_project_agents` changes, delete-time retire; tests 5–9, 11 (instance part) | `store/src/{project_members,project_invites,project_lifecycle,instances}.rs`, tests |
| C6 | control `ArchiveOwner`, `new_instance`, retired sweep; orchestrator `ObjectWorkspaceStore` per owner; control and orchestrator workspace tests | `control/src/{lib,workspace}.rs`, `orchestrator/src/workspaces.rs`, `control/tests/*`, `orchestrator/tests/workspaces.rs` |
| C7 | Orchestrator: `ToolContext.project`, `ShimLaunch.space`, `PROJECT_RUN_TOOLS`, `ToolSet` refusal, executor start changes, reveal/computer gating, preface text, `new_messages`, IM skip, `finish_inner` order, artifact/handoff/connector checks, `projects.rs` wrappers and audits; unit and orchestrator tests (except the claim end-to-end ones) | `orchestrator/src/{shim,exec,tools,executor,pipeline,outbox,texts,projects,ask,delegate,peers,scheduler}.rs`, `server/src/workers.rs` |
| C8 | **Open the claim:** `isolated!`/`live_space!` in claim, takeover and expired waits; urgent per space; wire the orphan sweeper; tests 1, 2 and the orchestrator isolation end-to-end tests | `store/src/runs.rs`, `orchestrator/src/executor.rs`, tests |
| C9 | Gateway: join/add entries, `consent_version`, PATCH agent, release, private-entry refusals, `mixed_project_agents` config (gateway and server); API tests | `gateway/src/{lib,routes/*}.rs`, `server/src/config.rs`, `gateway/tests/api.rs` |
| C10 | client-core API, FFI, docs, tests, smoke script | `client-core/src/{api,ffi,error}.rs`, `client-core/tests/client.rs`, `tools/client-core/ffi_smoke.py` |
| C11 | Android bindings regenerated (only `apps/android/**`) | `apps/android/core/src/main/kotlin/cn/thinktin/core/client_core.kt` |
| C12 | agent-shim regression test | `agent-shim/tests/shim.rs` |
| C13 | Docs: projects-impl "8.16 做了什么"; `sandbox-cube.md:31`; `browser.md:269,307`; `release.md` (application name, isolation level, the 8.17 write gate, rollback note); `deploy-checklist.md` (bucket prefix `projects/*/workspaces/`, versioning off or a lifecycle rule); this plan as `docs/progress/drafts/projects-8.16-plan.md`; progress file | `docs/**` |

**Rollback:** an 8.16 → 8.15 rollback is safe. 8.15 never claims project runs. Dedicated instances keep refusing private work through the DB triggers. Project runs with expired leases are not taken over by 8.15; with no writer in 8.16, none exist. After 8.17 writes project runs, roll back by turning dispatch off and cancelling non-terminal project runs first.

---

## 8. What 8.16 leaves for 8.17–8.19, and what needs real cloud verification

**8.17:**
- **Dispatcher:**
  - the only writer of executable project runs;
  - writes only when `legacy_sessions() == 0`, a DB-held dispatch switch is on, the target agent is dedicated and live, and the actor is checked through `ProjectActor`;
  - issues project grants (`run_grant_id` is required, D14).
- Lead changes.
- Project-scoped board, ask, delegate, `agents_list`/`agent_status`, schedule and pipelines. Each removes its name from the D14 deny set and uses `ToolContext.project`.
- `due_pipelines` with `isolated!`.
- Cross-owner trees.
- Whether team runs become project runs. If they do, decide whether mixed agents in never-shared own projects get a same-owner exception or wait for level 2.
- Urgent project messages and a worker-side cross-space interrupt helper with the D13 lock order.
- Egress "always allow" for project work (project scope ∩ owner scope).

**8.18:**
- Vault per item: vault tools and reveal in project runs, plus `vault_requests` pending uniqueness per space.
- Computer per project (`project_agents.allow_computer`).
- Budgets in llm-gw.
- Approvals to the owner.
- Tenant notice paths for project runs.

**8.19:**
- Receipts, including "your dedicated agent was reset because the project was deleted".
- The project feed.
- IM pushes of project content (8.16 skips them).
- Reporting content written by others.

**Mixed-instance isolation (level 2; after 8.19, with 15.7):**
- A separate sandbox per (instance, project): either an `instance_spaces` table carrying the lifecycle columns of `instances.rs:28-55`, or a hidden per-space instance row. The shim stays unchanged.
- **Verification before opening:** no traversal into sibling HOME or workspace, no old model memory, no restore of another scope's snapshot or archive, `/proc/<pid>/environ` and the bridge socket unreachable across spaces.
- Then raise `ISOLATION_LEVEL` to 2 and turn on `[api] mixed_project_agents`.

**Founder-run cloud checks:**
1. **ACS (Tokyo):**
   - adopt a dedicated agent and run one project run (8.17, or a worker-SQL seed);
   - idle-archive and check the OSS object is under `projects/<p>/workspaces/` and cannot be opened with the user's key;
   - delete the project and check the restore fails and the sweeper deletes the Pod;
   - measure create + restore time.
2. **Cube:**
   - a dedicated adopt creates its own volume;
   - retire, then confirm through the Cube API that both the VM and the volume are gone and never reattached;
   - measure extra microVM memory per dedicated agent.
3. **OSS buckets:** versioning off or a lifecycle rule, and any prefix-scoped RAM policy also covering `projects/*/workspaces/`.
4. **RDS:** `application_name` of other sessions is visible to the production login role (V4 was local PG16); `set_config('thinktin.isolation', …)` works for `thinktin_server_login` under `SET ROLE thinktin_worker`.

## Open questions

- Pilot rule for non-dedicated (mixed) agents in shared projects: the plan refuses them with 409 agent_not_isolated (switch [api] mixed_project_agents off). The warning-and-confirm flow is built and tested behind the switch. The alternative was to let them join after the warning even though they could not do any project work until mixed isolation exists. Default chosen: refuse during the pilot.
- Marking an existing agent as dedicated wipes its memory and files: it gets a fresh workspace, its old sandbox and archive are destroyed, and its private plans must be removed first. The App must send reset_workspace: true after showing that warning. Is wiping acceptable, or should only freshly adopted agents be allowed to be dedicated?
- When a member leaves or withdraws a dedicated agent, the plan keeps the agent dedicated and idle. It takes no private tasks and keeps its project memory in case it rejoins, until the owner taps 'release', which wipes it back to a normal agent. When the project is deleted, the agent is wiped and becomes a normal agent automatically, with no notice until 8.19. OK?
- Resetting an agent (dedicate, release, project deleted) also clears its 'always allow' website list, so project approvals don't leak into private work and the reverse. OK, or should the list be kept?
- A newly adopted dedicated agent starts with no model routes, like a normal adoption, and the App sets them right after joining. Should joining instead copy the routes from one of the user's existing agents?
- Dedicated agents are also allowed in your own never-shared projects (teams). Legacy team pipelines and delegation run as private work, so they skip such agents until 8.17. Allow it, or only allow dedicated agents in shared projects?
- Other members can see which agents in the project are dedicated (a yes/no per agent). OK to show, or keep it to the owner (for the 15.7 review)?
- Raising the join-terms version to 2 means the 8.14/8.15 client-core join and add-agent calls now fail with 422 until the App updates. This is acceptable only because cross-user projects are switched off and the App screens are not built yet. Confirm?