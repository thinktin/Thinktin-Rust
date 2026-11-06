# 8.16 定稿方案（workflow `projects-8-16-plan`，2026-11-06）

# WP 8.16 implementation plan (final): per-(instance, project) isolation, dedicated instances, and the non-dedicated warning

- **Branch:** `claude/determined-lovelace-vn0j5h` at `6724b7f` ("progress: claim 8.16"). The tree was clean and is still clean. No repo files were touched.
- **Migrations:** the last one is `0054_project_scoped_reads.sql`, so 8.16 uses **0055–0058**.
- **Precondition (0039:6-8):** nothing is deployed and there is no `v*` tag, so `tools/ci/check_migrations.py` only checks file names. Statements that would need `-- deploy-safe:` once a tag exists already carry it.
- **Harness note:** the harness flagged the sandbox-sessions code map for a "settings-json" pattern. That text is only a factual pointer to `agent-shim/src/config.rs:163-197`, which writes `.claude/settings.json` into the sandbox HOME. Nothing in it was treated as an instruction.
- **This version** applies the isolation and implementation critics' corrections after checking each one against the code. Appendix A lists every correction as Applied, Partly applied or Rejected, with the reason.

**Checked on a scratch PostgreSQL 16 database.** All migrations 0001–0054 were applied as superuser, then the 0055–0058 texts below. The scratch databases were dropped afterwards. V1–V12 come from the draft; V13–V15 were run for this version.

| # | Behaviour | Result |
|---|---|---|
| V1 | `BEFORE UPDATE OF lease_owner … WHEN (NEW.project_id IS NOT NULL AND NEW.lease_owner IS NOT NULL)` | Fires on claim, takeover and acquire-style updates. **It also fires on every `transition_run` that keeps the lease**, because `transition_run` always lists `lease_owner = CASE … ELSE lease_owner END` (`runs.rs:1506`). It does not fire on renew (only `lease_expires_at` is set) or on release (`lease_owner = NULL`). Private runs never reach the function. |
| V2 | `current_setting('thinktin.isolation', true)` after the setting was used earlier in the same session | Returns `''`, not NULL. The check therefore has to be `coalesce(nullif(…,''),'0')::int`. |
| V3 | `RAISE … USING ERRCODE='check_violation', CONSTRAINT='instance_dedicated'` | The error carries the constraint name, which sqlx exposes as `db.constraint()`. |
| V4 | `pg_stat_activity` read by a non-superuser role about another role's session | `application_name` is visible; `state` and `query` are hidden. |
| V5 | Stamp trigger on a table with `FK … ON DELETE SET NULL (run_id)` | `BEFORE UPDATE OF project_id` does not fire when the FK nulls `run_id`. `BEFORE UPDATE OF run_id` does fire, with `NEW.run_id` NULL. `project_id` survives the run's deletion. |
| V6 | One trigger function shared by tables with different row types | Fails with `record "new" has no field …`. So each row shape needs its own function. The six run-linked tables all have `run_id` and `project_id`, so they can share one. |
| V7 | The 0055 guards, as superuser and as `thinktin_app` under RLS | Private run, grant, plan or step on a dedicated instance gives 23514 `instance_dedicated`. The dedicated flag is derived. Another project's row is refused. |
| V8 | A worker holds the instance `FOR UPDATE` and sets `workspace_project_id` while a tenant inserts a private run | The insert waits in the trigger's `FOR KEY SHARE`, then fails with `instance_dedicated`. |
| V9 | Claim predicate | Returns private runs and dedicated project runs. Does not return mixed project runs, or runs whose agent left or whose project is archived. |
| V10 | `queue_workspace_archive_purge` | Queues `projects/<p>/workspaces/…` keys only when `OLD.workspace_project_id = p`. |
| V11 | 0056 policies | `ALTER POLICY … USING (… member_projects())` compiles. |
| V12 | Fence with `thinktin.isolation='1'` | A dedicated project run leases; a mixed one is refused with 42501 `runs_isolation`. Without the setting, both are refused. |
| V13 | **0049 `tenant_insert` (`NOT dedicated`) together with the derived flag** | The tenant `INSERT … ON CONFLICT DO UPDATE` from `replace_my_project_agents` (`projects.rs:394-405`) on an instance dedicated to the same solo project fails: "new row violates row-level security policy for table project_agents". It passes once the 0055 `ALTER POLICY` below drops `NOT dedicated`, and `dedicated` comes out true. |
| V14 | Revised 0055/0056 | **Dedicating:** refused while `peer_access` is on; turning `peer_access` on later is refused too (`instances_dedicated_no_peers`). Dedicating an instance with an unfinished run gives `instance_not_free`.<br>**Archive keys:** a `workspaces/<u>/` pending key on a dedicated instance and a `projects/…` key on a private one are refused (`instances_archive_space`). `artifacts/someone-else` on a private instance is still allowed, which the existing test `tests.rs:5366-5371` needs.<br>**Fence:** a transition at level 0 is refused; at level 1 it passes.<br>**Stamping:** a tenant board post on a project run gets the project; a tenant that sets `project_id` itself gets 42501; moving `run_id` is refused, except on `egress_requests`; the FK `SET NULL` keeps `project_id`; a worker write into a deleted project gives `project_deleted`.<br>**Tenant grants:** `UPDATE vault_requests SET run_id` is refused, `SET status` is allowed.<br>**Purge-style clear:** clearing a deleted dedicated instance queues its `projects/…` key. |
| V15 | `IF a AND current_user = 'thinktin_worker' AND EXISTS (SELECT … FROM projects)` in plpgsql, run as `thinktin_llmgw` | Fails with "permission denied for table projects". The whole expression's permissions are checked before it is evaluated. A nested `IF` fixes it, which is why both functions below use one. |

---

## 0. Decisions

**Scope.**

*In 8.16:*
- The isolation unit is the instance's sandbox. An (instance, project) pair can execute only when the whole instance belongs to that project (a "dedicated" instance).
- Dedicated instances:
  - adopt one for the project inside join or add-agents;
  - mark an existing one dedicated (this wipes it);
  - release one back to private;
  - reset automatically when its project is deleted.
- Claiming project runs opens, for dedicated instances only. A DB fence enforces it for every binary version. Takeover, expired waits and retries follow the same rule, and an hourly orphan sweeper finishes what they skip.
- **DB fences for old binaries:** an archive-key/space CHECK, and `peer_access` forced off on dedicated instances.
- A dedicated instance's archive is sealed with the project DEK under `projects/<p>/workspaces/`. The project key is created before the transaction.
- A project run gets:
  - a short allowlist of platform tools;
  - an empty vault scrubber, and llm-gw does not scrub with the owner's vault;
  - no IM fan-out, decided from the stored inbox row.
- Private-side filters.
- `project_id` stamped on six run-linked tables, with membership-gated tenant policies and purge steps.
- Deleted-project checks on worker appends.
- Lock-order fixes (approvals before instances, including erase).
- Non-dedicated agents: a warning and acknowledgement, behind a switch that cannot be turned on before level 2.
- Consent version 2; API, FFI, Android bindings and docs.

*Deferred:*
- **8.17:** writing executable project runs (dispatcher behind a DB-held switch, §8); project grants via `ProjectActor`; project board, ask, delegate, peers, pipelines and schedule; lead; cross-owner trees; `legacy_sessions()`.
- **8.18:** vault per item, computer per project, budgets in llm-gw, approvals to the owner.
- **8.19:** feed, receipts, IM pushes of project content, reporting others' content.
- **Level 2 (after 8.19 plus 15.7):** mixed-instance isolation.

| # | Decision | Why / evidence |
|---|---|---|
| D1 | **8.16 opens claiming of project runs, only for dedicated instances (isolation level 1), and writes no executable project runs.** Old SQL (8.13–8.15) keeps `project_id IS NULL`. The new SQL requires `instances.workspace_project_id = runs.project_id` and live membership. A DB trigger refuses any lease on a project run unless the transaction declares a high enough level. | projects-impl "迁移与放量" 8.14–8.16.<br>• Old filters are at `runs.rs:1014,1135,1434,1567`.<br>• Nothing writes project runs: `insert_run` (`runs.rs:288-317`) and `create_run_grant` (`grants.rs:160`) never bind a project, and `fill_space` (`0040:19-22`) is worker-only. Only tests seed them.<br>• Opening the claim now means the claim → execute path, with isolation, is tested in 8.16. |
| D2 | **Only dedicated instances are executable.** A mixed instance (`workspace_project_id IS NULL`) may be a project agent, but no 8.16 build claims its project runs: the fence wants level 2, which no binary declares. | • impl item 5; uid 1001 everywhere (`deploy/templates/Dockerfile:36,130`); `ExecSpec` has no uid (`sandbox/src/lib.rs:115-121`).<br>• HOME is `workspace/.thinktin/home` (`exec.rs:115-118`).<br>• ACS: one Pod, no volumes (`acs.rs:402-404`).<br>• On Cube and ACS a dedicated instance gets its own VM or Pod, volume or archive, HOME, session slot, `/tmp` and token epoch. **The Local backend isolates nothing** (`local.rs:1-9`). It only proves the control-plane wiring (§3.5). |
| D3 | **`instances.workspace_project_id uuid REFERENCES projects` is the source of truth.** Only the worker writes it; the tenant column grants (`0023:24-27`, `0024:9`, `0032:9`) exclude it. `project_agents.dedicated` is **derived** by a BEFORE trigger on live rows, and the 0049 `tenant_insert` check `NOT dedicated` is dropped (V13). Left rows keep their value. | • The flag must outlive the agent row.<br>• `dedicated` is already member-readable (`0049:84`).<br>• `put_agents` (`project_members.rs:140-141`) and the tenant upsert (`projects.rs:394-405`) no longer compute it. |
| D4 | **DB invariants on a dedicated instance:**<br>• no private run or grant, and no run or grant of another project;<br>• no active plan or plan step on it;<br>• no live `project_agents` row elsewhere;<br>• **`peer_access` is false (CHECK `instances_dedicated_no_peers`);**<br>• **archive keys only under `projects/<p>/workspaces/`, and private instances never hold a `projects/` key (CHECK `instances_archive_space`).**<br>Setting `workspace_project_id` is refused while the instance has unfinished runs, active plans or steps, or live rows elsewhere. | • Covers old gateways and every private entry point.<br>• The `peer_access` CHECK hides dedicated instances from 8.15's `peers()` (`instances.rs:556`) and `accepts_questions` (`runs.rs:444-452`), and so from its `agents_list`, `agent_status` (`peers.rs:80-89`) and `ask`.<br>• The archive CHECK stops an 8.15 control plane, which builds `workspaces/<u>/…` keys (`control/src/lib.rs:1480-1487`), from sealing project plaintext with the personal DEK.<br>• `FOR KEY SHARE` does not conflict with the `token_epoch`/`event_seq` updates. |
| D5 | **Two ways an instance becomes dedicated:**<br>(a) **Adopt** inside the accept or add-agents worker transaction: a new row with `workspace_project_id = p`, `peer_access = false`, and no private grant.<br>(b) **Mark an existing instance**, which requires `"reset_workspace": true`. It retires the workspace (D6) and revokes private grants. It is refused (409) while the instance has unfinished runs, active plans or steps, or live rows elsewhere.<br>• Only the agent's owner can do either.<br>• **The project key is created before the transaction** (`project_vault(…, create=true)`); it fails while the project is not active.<br>• Lock order: users → project → my member row → advisory → invite → **the instance's egress requests → instances** → agent rows. The agent row is read plainly before the instance lock and re-read after it (A4). | • projects.md §6 (`:71`).<br>• 8.14 left adopt-in-join as two calls (`projects-8.14-plan.md:31,825-829`).<br>• `insert_project_key` only works for active projects (`store/projects.rs:223-237`), and `project_vault(create=false)` reports a missing key as `Gone` (`orchestrator/src/artifacts.rs:240-245`). So creating the key lazily after commit could leave an archived project's ACS instance unable to archive. |
| D6 | **Retiring a workspace is DB-only and atomic.**<br>• The old `sandbox_id`, `restoring_sandbox_id` and `workspace_id` go into `retired_workspaces`.<br>• The instance gets a new `ws-<uuid>`, `state='provisioning'`, cleared sandbox/snapshot/archive/restoring columns, `egress_hosts='{}'`, `peer_access` set to `(new space IS NULL)` and `token_epoch+1`. It only applies to non-deleted rows, and 0 rows means `NotFound`.<br>• **The instance's egress requests are deleted, and pending ones mark their inbox items read. Pending vault requests are expired and their inbox items marked read.** These use SKIP LOCKED; callers that may wait pre-lock the egress rows before the instance.<br>• `Lifecycle::sweep` later destroys the old sandboxes and the old volume. | • `ensure_running` sees no sandbox and creates one (`control/src/lib.rs:769-771`).<br>• An in-flight archive gets `Recorded::Skipped`, because `unchanged()` compares `sandbox_id` (`lib.rs:1418-1430,1594-1597`). `settle_archive` then deletes the object with the owner it was written under (`lib.rs:1648-1676`).<br>• `decide_egress_request` locks the request and then updates `instances` (`egress.rs:555,580`), hence the pre-lock.<br>• `inbox_items.egress_request_id` has no FK (`0035:4`). |
| D7 | **After leaving, a dedicated instance stays dedicated and idle.** Rejoining keeps its memory. `POST /v1/instances/{id}/release` (owner; only once no live project row remains) retires it into a fresh private instance.<br>**Deleting the project, or erasing its creator,** retires the dedicated instances it can lock without waiting (`FOR UPDATE SKIP LOCKED`). The purge backstop retires the rest, including deleted-but-unpurged instances. | • `delete_project` is a short transaction (impl item 7), and `ensure_running_once` holds the instance lock across `provider.create` (`control/src/lib.rs:626-627,1032-1041`).<br>• Erase soft-deletes the creator's projects in its own loop (`users.rs:219-241`), not through `delete_project`.<br>• Waiting is safe: no run can start (liveness, D4), the key is gone, and only the volume holds plaintext until the backstop. |
| D8 | **A dedicated instance's archive is `projects/<p simple>/workspaces/<ws>/<archive id>`,** sealed with the project DEK (subject `project:<p>`). `WorkspaceStore` takes an `ArchiveOwner`, derived from the same `rt` as the key. | • impl item 5.<br>• `workspace_sealer` takes a subject string (`keyvault/src/lib.rs:626-640`).<br>• Prefix check at `orchestrator/src/workspaces.rs:185-193`. |
| D9 | **Claim SQL:** `isolated(r)` and `live(r)`; urgent precedence per space. **Takeover and expired waits require both `isolated` and `live`.** Non-live runs are finished only by the sweeper (D12), with no notice. `due_pipelines` stays private. | • `take_over_expired` ends in `finish(Retry)` and, on the last attempt, a RunFailed notice (`executor.rs:560-578,1077-1085`). An ex-member would get it.<br>• A deleted project's run would fail at the D17 append and be taken over again every lease period. |
| D10 | **DB fence:** trigger `runs_isolation` (V1, V12). `Db::worker` sets `thinktin.isolation = '1'`. It covers every statement that takes or keeps a lease, including `acquire_lease` (`runs.rs:1101-1121`) and `transition_run`. It does not cover `due_pipelines`, which advances pipelines without a lease (`runs.rs:1562-1575`); that stays private, and an INSERT-time fence for project runs is left to 8.17. | `thinktin_worker` is BYPASSRLS (`0001:19`). |
| D11 | **Old binaries are fenced in the DB, not by counting sessions.** The fences are claim (D10), archive keys and `peer_access` (D4), and the private-work triggers. `application_name` becomes `thinktin/i1` (`store/src/lib.rs:113`), so 8.17 can count old sessions, but only as advice: `legacy_sessions()` moves to 8.17. 8.17's dispatcher writes only after a DB-held switch is flipped by the operator once the deploy checklist confirms old replicas are gone. | • An idle API-only replica can hold no connections (sqlx pool minimum 0), and a pooler rewrites `application_name`.<br>• relay (`relay/src/main.rs:104`) and llm-gw (`llm-gw/src/main.rs:331`) also connect as `thinktin`.<br>• The hazard is real: 8.15's `agent_status` reads the owner's project runs in a tenant transaction (`peers.rs:91-158`, `0054:135-140`). The `peer_access` CHECK closes it. |
| D12 | **Orphan sweeper in hourly maintenance** (`orchestrator::projects::sweep`, default `maintenance_every_secs = 3600`), SKIP LOCKED. It cancels non-terminal project runs whose agent, member or project is no longer live, in the D13 order, without notices. | • A project run left in backoff or waiting would hold `runs_one_active_per_instance` (`0002:49-51`) for ever.<br>• Takeover now skips such runs (D9), so something must finish them.<br>• Hourly instead of the 15 s takeover tick: it scans `runs_project_recent` (`0052`), and orphans should not exist. |
| D13 | **Lock order: runs → approvals → requests → instances.**<br>• The three project cancel helpers, **`cancel_user_runs` (erase, freeze, stop-all)** and the sweeper: lock runs and collect ids; `settle_cancelled_approvals(ids)`; **(project helpers and sweeper only) expire pending egress and vault requests of those runs (SKIP LOCKED)**; `bump_epochs_where!`; the filter-based `UPDATE runs`; settle approvals of any id not in the locked set.<br>• `finish_inner` is unchanged. | • `projects-8.15-review.md:88-96`.<br>• Erase's separate `UPDATE approvals` before `cancel_user_runs` would put approvals before runs, the reverse of the executor's `finish_inner` (`executor.rs:1161,1171`).<br>• `cancel_descendants` never touches approvals (`runs.rs:1151-1182`), so `finish_inner` has no cycle.<br>• `claim_egress_asks` has no run-state filter (`egress.rs:646-674`). |
| D14 | **Project runs until 8.17/8.18:**<br>• one filter in executor start, `allowed_in_space`, with `PROJECT_RUN_TOOLS = artifact_publish, artifact_list, artifact_read, artifact_fetch, web_search`, plus the browser if granted;<br>• a start check that `rt.workspace_project_id == run.project_id`;<br>• no fallback to the private grant;<br>• **the scrubber is empty for project runs, and llm-gw skips owner-vault scrubbing for dedicated instances.** | • Dispatch already enforces `allowed_tools` (`executor.rs:1898-1918`), `reveal` requires `vault_list` (`:2017`), and computer tools pass the same filter (`:839-852`). So the extra refusal layers add nothing.<br>• The scrubber (`executor.rs:979`; `vault.rs:255-288`; llm-gw `proxy.rs:435-463,749-752`) replaces any owner-vault value of 4 or more characters (`keyvault/src/lib.rs:842,865-868`) with `[vault:name]`. Members can read `agent.message`, so a member could learn a PIN by asking the agent to print candidates. |
| D15 | **Private-side filters:**<br>• `peers()` and `delegation_targets()` exclude dedicated instances; `instance_holder` and `last_finished_run` add `project_id IS NULL`; `unannounced_messages` is same-space;<br>• private board queries add `project_id IS NULL`;<br>• the cross-space interrupt preface is deferred to level 2 (unreachable before it). | `instances.rs:543-589`; `runs.rs:736-762,1333-1347`; `board.rs:132-133,211`. |
| D16 | **Stamp `project_id`** on `vault_requests`, `device_calls`, `board_posts`, `egress_requests`, `live_activities` and `content_reports` with `stamp_project_from_run()`:<br>• derived from the visible run;<br>• non-workers cannot set it; workers may set it with no run; it must match the run;<br>• frozen on UPDATE;<br>• `run_id` frozen except FK nulling and egress touch;<br>• worker writes into deleted projects refused.<br>Also: llm-gw gets `SELECT (project_id) ON runs`; the tenant gets only `UPDATE (status, item_id, resolved_at)` on `vault_requests`; membership-gated policies; purge steps. | 8.15 plan §8; `0034:46-49`; `0009:60`; `store/vault.rs:289,363`. The design follows `inbox_project_guard` (`0054:158-191`), so 8.17's project board needs no re-migration. |
| D17 | **`fill_space_from_run` refuses worker appends for deleted projects** (23514 `project_deleted`), checked with a nested IF (V15). | impl item 7. No `stop_project` or `delete_project` path appends events after the status flip (`project_lifecycle.rs:59-83,129-190`). |
| D18 | **Non-dedicated agents in shared projects:**<br>• `[api] mixed_project_agents = false` gives 409 `agent_not_isolated`;<br>• when true, `ack_shared_memory: true` is required.<br>**Server config validation rejects `true` while `store::ISOLATION_LEVEL < 2`,** so the switch is exercised only in tests. | projects.md §6 `:72` against impl `:12`. Without the check, users could add agents that never run. |
| D19 | **Consent version 2**, with dedicated and mixed key lists. A missing `consent_version` counts as 1 and gives 422. | `routes/projects.rs:43-48` builds the current version from a bool, so `Consent::check` (`project_invites.rs:46-53`) never fails today. |
| D20 | **Error codes:** `instance_dedicated` (409) and `agent_not_isolated` (409). An adopt over the cap reuses `instance_limit`. | `proto/src/api.rs:37-101`. |
| D21 | **No agent-shim change.** The fresh-HOME case is already tested (`agent-shim/tests/shim.rs:206,457`). **One Local-backend hardening:** `resolve` accepts only the sandbox's own directory and its own volume (`local.rs:167-187` today accepts any `volumes/` path). Doc fixes: `sandbox-cube.md:31`, `browser.md:269,307`. | §3.4–3.5. |
| D22 | **The FFI change is breaking:** `ProjectJoin.instance_ids` becomes `agents`. Android bindings are regenerated in their own commit. A pre-8.16 client that sends `instance_ids` gets 422, not 500. | Only the generated `client_core.kt` references them. |

---

## 1. Migrations

### 1.1 `0055_dedicated_instances.sql` (one transaction)

```sql
-- 专属实例与项目运行的隔离（WBS 8.16，docs/projects.md 第 6 节，docs/projects-impl.md 第 5 条、“迁移与放量”）。
-- 沙箱里所有进程是同一个 OS 用户，按目录分不开私人和项目（impl 第 5 条）：这一版的隔离单位是整个实例。
-- instances.workspace_project_id 不为空的实例（专属实例）的沙箱、工作区卷、归档、agent 的 HOME 和会话只属于这个项目，
-- 不接私人任务；混用实例（为空）的项目运行哪个版本的程序都不领（runs_isolation）。这一列只有 thinktin_worker 写
-- （租户的列权限见 0023:24-27、0024:9、0032:9）。
-- 前提同 0039：第一次部署之前发布，表是空的；instances 上的索引、约束直接建（行数 = 实例数）。

ALTER TABLE instances ADD COLUMN workspace_project_id uuid REFERENCES projects (id);
CREATE INDEX instances_workspace_project ON instances (workspace_project_id) WHERE workspace_project_id IS NOT NULL;
-- 专属实例不让别的 agent 查、问：上一版程序的 agents_list、agent_status、ask 只认 peer_access（instances.rs peers、
-- runs.rs accepts_questions），照样看不到它（方案 D11）。
-- deploy-safe: 新列全是空的；上一版的租户 PATCH 只会在专属实例上撞这个约束（422）
ALTER TABLE instances ADD CONSTRAINT instances_dedicated_no_peers
    CHECK (workspace_project_id IS NULL OR NOT peer_access);
-- 归档键跟着空间走（impl 第 5 条）：专属实例只用 projects/<项目>/workspaces/ 下的键（项目 DEK），私人实例不用 projects/
-- 下的键。上一版的控制面给专属实例归档时按用户前缀记待定的键，在这里被拒（23514），沙箱留着不删，项目明文不会按个人
-- DEK 存进对象存储。
-- deploy-safe: 上一版只写 workspaces/<用户>/ 下的键，新列全是空的
ALTER TABLE instances ADD CONSTRAINT instances_archive_space CHECK (CASE
    WHEN workspace_project_id IS NULL THEN
        NOT starts_with(coalesce(workspace_archive_key, ''), 'projects/')
        AND NOT starts_with(coalesce(workspace_archive_pending, ''), 'projects/')
    ELSE coalesce(starts_with(workspace_archive_key,
                  'projects/' || replace(workspace_project_id::text, '-', '') || '/workspaces/'), true)
        AND coalesce(starts_with(workspace_archive_pending,
                  'projects/' || replace(workspace_project_id::text, '-', '') || '/workspaces/'), true) END);
-- 跨用户项目里派混用实例时，用户确认过“它记忆里的私人内容可能被带进项目”（试点默认不收混用实例）。
ALTER TABLE project_agents ADD COLUMN shared_memory_ack_at timestamptz;
-- dedicated 由下面的 project_agents_dedicated 触发器从实例算（租户没有这一列的权限，0039:220）：插入策略不再查
-- NOT dedicated，不然单人项目里专属于它的 agent 一改团队（INSERT … ON CONFLICT 先按插入策略查拟插入的行）就 42501。
ALTER POLICY tenant_insert ON project_agents
    WITH CHECK (user_id = app_user_id()
                AND EXISTS (SELECT 1 FROM projects p WHERE p.id = project_id
                              AND p.creator_id = app_user_id() AND p.shared_at IS NULL AND p.status = 'active'));

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
-- 拿项目运行的租约（任何版本、任何语句）：这一版程序声明能隔离到哪一级（Db::worker 设 thinktin.isolation）。专属于这个
-- 项目的实例要 1 级，混用实例要 2 级（还没有程序做得到）。续租只改 lease_expires_at、交还租约置空，都不触发；
-- transition_run 每次都写 lease_owner（保持原值），拿着租约的状态变更也触发（方案 V1）。
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
-- 运行，空间算成私人，复合外键拒绝）；租户也读不到别人创建的项目行，所以只查 worker。两层 IF：表权限在语句开始时就查
-- （方案 V15）。
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
    IF NEW.project_id IS NOT NULL AND current_user = 'thinktin_worker' THEN
        IF EXISTS (SELECT 1 FROM public.projects p WHERE p.id = NEW.project_id AND p.status = 'deleted') THEN
            RAISE EXCEPTION 'the project of this run was deleted'
                USING ERRCODE = 'check_violation', CONSTRAINT = 'project_deleted';
        END IF;
    END IF;
    NEW.space_kind := CASE WHEN NEW.project_id IS NULL THEN 'private' ELSE 'project' END;
    NEW.space_id := coalesce(NEW.project_id, NEW.user_id);
    RETURN NEW;
END $$;
```

Notes:
- **Owner:** the migration owner already owns both replaced functions (`0049:169`, `0050:9`). `CREATE OR REPLACE` keeps owner, ACL and SECURITY DEFINER, and the SET clauses are repeated.
- **Grants:** `thinktin_app` has column UPDATE on `instances` (`0023:26-27`), which `FOR KEY SHARE` needs. The tenant INSERT columns (`0023:25`) exclude `peer_access`, so tenant-created instances default to true and stay private. Adopted dedicated instances are inserted by the worker with `peer_access = false`.
- **Every 8.16 writer** that changes `workspace_project_id` also clears or sets the archive keys and `peer_access` in the same statement: `retire_workspace`, `mark_instance_purged`, the adopt INSERT and the purge backstop. `begin_workspace_archive` and `finish_workspace_archive` (`instances.rs:812-868`) get keys from the owner-aware `key()`.

### 1.2 `0056_run_linked_project_ids.sql` (one transaction; checked in V14/V15)

```sql
-- 带运行的其余六张表也记项目（8.15 方案第 8 节）：保险箱请求、电脑调用、看板、出网请求、实时活动、举报。
-- 项目由触发器按调用者看得到的运行算，建了不能改；只有 worker 能自己填（8.17 的项目看板有不带运行的条目），填了要和运行
-- 一致（同 0054 inbox_project_guard 的写法）。不用 0050 的 fill_space_from_run：vault_requests、device_calls、
-- board_posts、egress_requests 是 ON DELETE SET NULL (run_id)，外键置空会触发 UPDATE OF run_id（方案 V5）。
-- 看不到运行（退出了的项目）一律 23503：外键检查不管行级安全。
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
        -- 运行只能被外键置空；出网请求在等的时候会换到同一个实例后来的运行上（store/egress.rs touch_request）。
        IF TG_TABLE_NAME <> 'egress_requests' AND NEW.run_id IS NOT NULL
           AND NEW.run_id IS DISTINCT FROM OLD.run_id THEN
            RAISE EXCEPTION '%.run_id cannot move to another run', TG_TABLE_NAME
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.project_id IS NOT NULL AND current_user <> 'thinktin_worker' THEN
        RAISE EXCEPTION '%.project_id is written by the server only', TG_TABLE_NAME
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NEW.run_id IS NOT NULL THEN
        SELECT r.project_id INTO run_project FROM public.runs r WHERE r.id = NEW.run_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION '% refers to a run that is not visible', TG_TABLE_NAME
                USING ERRCODE = 'foreign_key_violation';
        END IF;
        IF NEW.project_id IS NOT NULL AND NEW.project_id IS DISTINCT FROM run_project THEN
            RAISE EXCEPTION '%.project_id does not match its run', TG_TABLE_NAME
                USING ERRCODE = 'check_violation';
        END IF;
        NEW.project_id := run_project;
    END IF;
    -- 删了的项目里不再记新的（同 fill_space_from_run；出口代理读不到 projects，它只给在跑的运行记，删项目时已经取消了）。
    -- 两层 IF：projects 的权限在语句开始时就查，出口代理没有这张表的权限（方案 V15）。
    IF NEW.project_id IS NOT NULL AND current_user = 'thinktin_worker' THEN
        IF EXISTS (SELECT 1 FROM public.projects p WHERE p.id = NEW.project_id AND p.status = 'deleted') THEN
            RAISE EXCEPTION 'the project of this run was deleted'
                USING ERRCODE = 'check_violation', CONSTRAINT = 'project_deleted';
        END IF;
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION stamp_project_from_run() FROM PUBLIC;

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
        EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE OF project_id, run_id ON %I FOR EACH ROW '
                       'EXECUTE FUNCTION stamp_project_from_run()', t || '_project', t);
    END LOOP;
END $$;
ALTER TABLE runs FORCE ROW LEVEL SECURITY;

-- 出口代理插入出网请求时触发器要读运行的项目（0034:49 只给了这几列）。
GRANT SELECT (project_id) ON runs TO thinktin_llmgw;
-- 租户只改保险箱请求的处理结果（store/vault.rs create_vault_request、resolve_vault_request），不能把它挪到别的运行上。
-- deploy-safe: 上一版的租户代码只写 status、item_id、resolved_at
REVOKE UPDATE ON vault_requests FROM thinktin_app;
GRANT UPDATE (status, item_id, resolved_at) ON vault_requests TO thinktin_app;

-- 租户：项目行只在还是存活成员时看得到（0054 的写法）。vault_requests、board_posts、live_activities、content_reports 的
-- WITH CHECK 不变；egress_requests 本来没有 WITH CHECK（0034:42），新的 USING 也用来查 UPDATE 后的行，租户只改
-- status、decided_at，不影响。device_calls 没有租户权限（0014:77-82）。
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

- `live_activities` needs no project index: its rows go with the runs-delete cascade (`0018:37`), and `live_activities_run` (`0018:40`) covers it.
- `content_reports.run_id` has no FK (`0019:8`), so the stamp only runs on insert.
- The relay updates `device_calls` (`0014:89`) without touching `project_id` or `run_id`, so the trigger does not fire for it.

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
- FORCE on `retired_workspaces` and the six tables;
- the triggers and both instance CHECKs;
- the `tenant_insert` policy on `project_agents` without `dedicated`.

**Fixtures** that set `lease_owner` on a project run on a non-dedicated instance must run `SELECT set_config('thinktin.isolation','2',true)` in that transaction, with the comment "stands in for a future mixed-isolation build":
- `store/src/tests.rs:1190` (the first statement of the loop; the second sets `lease_owner = NULL` and does not fire);
- `store/src/tests/projects.rs:1789` (`copy_into_project`);
- `gateway/tests/api.rs:5456` (raw worker transaction).

`tests/projects.rs:2397` is a private run (`queue_run`, `tests.rs:62-70`) and needs nothing. `orchestrator/tests/projects.rs:371-384` only inserts a queued project run.

**Rewrite `tests.rs:1559-1598`.** Its raw `UPDATE project_agents SET dedicated = true` is now re-derived to false. Instead:
1. As worker, set `peer_access = false, workspace_project_id = team.id` on `w2`; it is free.
2. Touch the row.
3. The later `update_team` covers A1.
4. `assert!(left && dedicated)` still holds, because left rows keep their value.

---

## 2. Store API (`crates/store`)

### 2.1 `lib.rs`, `error.rs`, `schema.rs`

- **`lib.rs`:** `pub const ISOLATION_LEVEL: u8 = 1;` with a doc, and the `known_sources()` comment (`runs.rs:202-208`) rewritten to point to it.
  - `Db::connect` (`lib.rs:107-115`): `.application_name("thinktin/i1")`, built from the constant.
  - `Db::worker` (`lib.rs:150-158`): `SELECT set_config('role','thinktin_worker',true), set_config('statement_timeout',$1,true), set_config('thinktin.isolation',$2,true)`.
  - `pub fn new_workspace_id() -> String` (`format!("ws-{}", Uuid::now_v7().simple())`, as `control/src/lib.rs:274`).
  - `legacy_sessions()` is **not** added in 8.16 (D11).
- **`error.rs`** (`:54-76`): in `From<sqlx::Error>`, before the generic 23514 arm:
  - constraint `instance_dedicated` → `Error::InstanceDedicated`;
  - `instance_not_free` → `Error::Conflict("instance_not_free: …")`;
  - `project_deleted` stays `Invalid("project_deleted")`;
  - `instances_dedicated_no_peers` and `instances_archive_space` stay `Invalid`.
  - New variants: `InstanceDedicated`, `AgentNotIsolated`, `InstanceLimit { max: u64 }`.

### 2.2 Claim, takeover, expired waits, fence (`runs.rs`)

Fragments next to `lock_runs_where!` (`runs.rs:359-367`):

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

**`claim_next_run`** (`runs.rs:1006-1084`): the select becomes the V9 shape:

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
- **Fence errors in the claim.** The savepoint rolls back only on `Conflict` (`:1068-1078`). The select uses the fence's own predicate, so a `Forbidden` from the claim UPDATE means a bug. Handle it this way: `ROLLBACK TO SAVEPOINT claim`, `error!` plus the metric `thinktin_claim_fence_total`, return `Ok(None)`. That way the worker does not abort the transaction and retry the same row in a loop.
- **`take_over_expired`** (`:1124-1149`) and **`claim_expired_waits`** (`:1422-1448`): replace `AND project_id IS NULL` with `AND {isolated!("runs")} AND {live_space!("runs")}`. Non-live runs are finished only by the sweeper (2.5).
- `due_pipelines` (`:1562-1577`) and `acquire_lease` are unchanged; the fence covers the latter.

### 2.3 Cancel lock order (D13)

The helpers keep their filters. Only the order changes. Example for `cancel_project_runs` (`runs.rs:944-966`):

```rust
let locked: Vec<Uuid> = sqlx::query_scalar(lock_runs_where!("project_id = $1"))
    .bind(project.0).fetch_all(self.conn()).await?;          // 1. 运行
self.settle_cancelled_approvals(&locked).await?;              // 2. 审批 → 提醒（和 decide_approval 一样先审批后实例）
self.expire_run_requests(&locked).await?;                     // 3. 出网、保险箱请求（SKIP LOCKED）→ 提醒
sqlx::query(bump_epochs_where!("project_id = $1")).bind(project.0).execute(self.conn()).await?;  // 4. 实例
let ids: Vec<Uuid> = sqlx::query_scalar("UPDATE runs SET state = 'cancelled', … WHERE project_id = $1 \
    AND state NOT IN ('succeeded','failed','cancelled') RETURNING id")…;  // 5. 按条件（锁之后新插的子运行也取消）
let late: Vec<Uuid> = ids.iter().filter(|i| !locked.contains(i)).copied().collect();
self.settle_cancelled_approvals(&late).await?;                // 6. 通常是空的（新插的运行还在排队）
```

`expire_run_requests(ids)` (new, `pub(crate)`):

```sql
WITH gone AS (UPDATE egress_requests SET status = 'expired'
                WHERE id IN (SELECT id FROM egress_requests WHERE run_id = ANY($1) AND status = 'pending'
                              FOR UPDATE SKIP LOCKED) RETURNING id)
UPDATE inbox_items SET read_at = now() WHERE id IN (SELECT id FROM inbox_items
   WHERE egress_request_id IN (SELECT id FROM gone) AND read_at IS NULL FOR UPDATE SKIP LOCKED);
WITH gone AS (UPDATE vault_requests SET status = 'expired', resolved_at = now()
                WHERE id IN (SELECT id FROM vault_requests WHERE run_id = ANY($1) AND status = 'pending'
                              FOR UPDATE SKIP LOCKED) RETURNING id)
UPDATE inbox_items SET read_at = now() WHERE id IN (SELECT id FROM inbox_items
   WHERE vault_request_id IN (SELECT id FROM gone) AND read_at IS NULL FOR UPDATE SKIP LOCKED);
```

The worker has `UPDATE (status, notified_at)` on `egress_requests` (`0034:47`) and all rights on `vault_requests` (`0009:61`).

- `cancel_project_agent_runs` (`:860-898`) and `cancel_project_member_runs` (`:902-941`) change the same way.
- **`cancel_user_runs`** (`:820-840`; erase, freeze, stop-all) follows steps 1, 2, 4, 5, 6, without step 3. Erase's separate approvals UPDATE from the draft is dropped. Freeze and stop-all now also settle their pending approvals, which they did not before.
- **D3 text in `projects.rs:7-9`:** "… → 项目 agent 行 → 运行 → 审批 → 出网/保险箱请求 → 实例".
- **`finish_inner` is unchanged.** `cancel_descendants` (`runs.rs:1151-1182`) touches no approvals, and children never share the parent's instance.

### 2.4 Space-aware queries

- **`unannounced_messages(instance, project: Option<ProjectId>, limit)`** (`runs.rs:1333-1347`): `… AND project_id IS NOT DISTINCT FROM $3`.
- **`instance_holder` and `last_finished_run`** (`runs.rs:736-762`): add `AND project_id IS NULL`, with no new parameter. Their only caller, `peers.rs`, runs in private runs.
- **`Tx<Tenant>::peers(me)`** (`instances.rs:543-569`): `… AND peer_access AND workspace_project_id IS NULL …`; the holder subquery adds `AND r.project_id IS NULL`.
- **`delegation_targets(lead)`** (`instances.rs:572-589`): add `AND workspace_project_id IS NULL`.
- **Board** (`store/board.rs`): the list query, the cap archive (`:132-133`) and the count (`:211`) add `project_id IS NULL`.
- **`queue_urgent_run`** (`runs.rs:606-710`) needs no change in 8.16:
  - private urgent messages cannot target dedicated instances (D4);
  - on private and mixed instances only private runs ever hold the instance, because mixed project runs are never claimed;
  - no project urgent runs exist.

  This is documented in its doc comment. Level 2 must make the holder choice per space (§8).
- **`instances.rs` `columns!()` and `runtime_columns!()` (`:113,216-225`)** add `workspace_project_id`: `Instance.dedicated_project_id: Option<ProjectId>` and `InstanceRuntime.workspace_project_id: Option<ProjectId>`.
- **`mark_instance_purged`** (`instances.rs:789-803`): also `workspace_project_id = NULL`. The trigger reads `OLD`, so the project key is still queued.
- **`insert_inbox`** (`inbox.rs:103-140`) becomes `RETURNING id, project_id`, returning `Option<(InboxItemId, Option<ProjectId>)>`. The guard (`0054:176-191`) has filled the project from the run.
- **`Tx<Llmgw>::gateway_instance`** (`llmgw.rs:40-80`): select `workspace_project_id IS NOT NULL` into `GatewayInstance.dedicated: bool`. `thinktin_llmgw` already has table-wide SELECT on `instances` (`0001:485`).

### 2.5 Orphan sweeper (maintenance)

```rust
/// 8.16：没结束、但 agent / 成员关系 / 项目已经不在的项目运行（退出、删除的事务本该取消它们；兜底，免得占着实例）。
/// 接管、等待超时都不碰这些运行（D9），只在这里取消，不发提醒。
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
-- then: settle_cancelled_approvals(ids); expire_run_requests(ids);
-- UPDATE instances SET token_epoch = token_epoch + 1 WHERE id IN
--   (SELECT instance_id FROM runs WHERE id = ANY($1) AND kind='agent' AND state IN (<active states>));
-- UPDATE runs SET state='cancelled', state_reason='project_left', wait_code=NULL, lease_owner=NULL, lease_expires_at=NULL,
--   finished_at=now(), updated_at=now() WHERE id = ANY($1) RETURNING id, instance_id,
--   EXISTS (SELECT 1 FROM projects p WHERE p.id = runs.project_id AND p.status = 'deleted')
```

- **Caller:** `orchestrator::projects::sweep` (`orchestrator/src/projects.rs:593-640`, called from `server/src/workers.rs:507`), in its own transaction, batches of `SWEEP_BATCH`.
- It appends a `run.state` event only for runs whose project is not deleted (D17).
- The candidate scan uses `runs_project_recent` (`0052`). If 8.17 makes project runs common, add a partial index on non-terminal project runs then.

### 2.6 Dedicating, adopting, releasing, retiring (`project_members.rs`, `instances.rs`)

**`pub(crate) async fn retire_workspace(&mut self, instance: InstanceId, space: Option<ProjectId>, reason: &str) -> Result<()>`.** The caller holds the instance `FOR UPDATE`, has checked it is free and not deleted, and, where it may wait, has pre-locked its egress rows (`SELECT id FROM egress_requests WHERE instance_id = $1 ORDER BY id FOR UPDATE` before `lock_instance`).

```sql
INSERT INTO retired_workspaces (id, instance_id, user_id, workspace_id, sandbox_ids, reason)
  SELECT $2, id, user_id, workspace_id, array_remove(ARRAY[sandbox_id, restoring_sandbox_id], NULL), $3
    FROM instances WHERE id = $1 AND state <> 'deleted';
UPDATE instances SET workspace_project_id = $4, workspace_id = $5, state = 'provisioning',
   sandbox_id = NULL, sandbox_address = NULL, snapshot_id = NULL, sandbox_version = NULL, rebuild_pending = false,
   workspace_archive_key = NULL, workspace_archive_id = NULL, workspace_archive_bytes = NULL,
   workspace_archive_sha256 = NULL, workspace_archived_at = NULL, workspace_archive_pending = NULL,
   workspace_archive_pending_since = NULL, workspace_archive_failed_at = NULL, workspace_archive_error = NULL,
   restoring_sandbox_id = NULL, restoring_since = NULL, egress_hosts = '{}', peer_access = ($4::uuid IS NULL),
   token_epoch = token_epoch + 1, updated_at = now()
 WHERE id = $1 AND state <> 'deleted';                         -- 0 行 → NotFound
WITH gone AS (DELETE FROM egress_requests WHERE id IN (SELECT id FROM egress_requests WHERE instance_id = $1
                FOR UPDATE SKIP LOCKED) RETURNING id, status)
UPDATE inbox_items SET read_at = now() WHERE id IN (SELECT id FROM inbox_items
   WHERE egress_request_id IN (SELECT id FROM gone WHERE status = 'pending') AND read_at IS NULL FOR UPDATE SKIP LOCKED);
WITH gone AS (UPDATE vault_requests SET status = 'expired', resolved_at = now()
                WHERE id IN (SELECT id FROM vault_requests WHERE instance_id = $1 AND status = 'pending'
                              FOR UPDATE SKIP LOCKED) RETURNING id)
UPDATE inbox_items SET read_at = now() WHERE id IN (SELECT id FROM inbox_items
   WHERE vault_request_id IN (SELECT id FROM gone) AND read_at IS NULL FOR UPDATE SKIP LOCKED);
```

- `$5 = store::new_workspace_id()`. Then `append_event(instance, None, "instance.state", {"state":"provisioning","reset":reason})`.
- `vault_items.instance_ids` is left alone: an empty array means every instance (`0009:12`), so removing the id could widen access. Vault tools are off in project runs (D14), and 8.18 must not use `instance_ids` for project access.
- A skipped (locked) pending vault request is being fulfilled right now. Its `resume_after_request` then hits the dedicated instance and returns 409; the next fulfil skips the resume (§4).

**`free_instance_check(instance)`** runs after `FOR UPDATE`, with plain reads:
- no unfinished runs;
- no active plan with `instance_id` or a step on it;
- no live `project_agents` row outside the target project.

It returns `Conflict("instance_not_free: …")`; the trigger is the backstop.

**`dedicate_project_agent(user, project, instance) -> Result<()>`** (PATCH). The orchestrator wrapper first calls `project_vault(db, kms, p, true)` (D5). Then, in D3 order:
1. `project_actor(user, project, &[], &[Active])`.
2. Plain read of the agent row (`project_id=$1 AND instance_id=$2 AND left_at IS NULL`). Owner ≠ `user` → `NotPermitted`; missing → `NotFound`. The project lock already serializes worker writers.
3. Pre-lock the instance's egress rows (`ORDER BY id FOR UPDATE`).
4. `lock_instance(instance)` (`FOR UPDATE`). If `rt.state == Deleted` → `NotFound`.
5. Re-read the agent row (live, owner) and `free_instance_check`.
6. `retire_workspace(instance, Some(project), "dedicate")`.
7. `UPDATE run_grants SET revoked_at = now(), revoke_reason = 'instance_dedicated' WHERE instance_id = $1 AND project_id IS NULL AND revoked_at IS NULL`.
8. Touch the agent row (`UPDATE project_agents SET dedicated = true WHERE …`; the trigger derives true).
9. Audit `project.agent.dedicate`.

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
- `put_agents(project, user, &[(Uuid, bool /*ack*/)], consented)` writes `shared_memory_ack_at = CASE WHEN ack THEN now() END` on insert and revive, and drops `dedicated = false` (`:140-141`).

**`accept_invite`** (`project_invites.rs:503-664`). The orchestrator wrapper resolves the invite's project with a plain read and, when any entry dedicates or adopts, calls `project_vault(…, true)` first. Inside the D3 order:
1. Users → project lock → my member row (`:532-560`), as today.
2. **Between the member-row lock and the invite-row `FOR UPDATE` (`:561-567`)**, and only when an `Adopt` is present: `pg_advisory_xact_lock(hashtextextended($1,0))` with `$1 = format!("instances/{}", user)`, the same key as `lock_instance_count` (`instances.rs:259-262`). Count non-deleted instances plus Adopts against `max_instances` → `InstanceLimit`.
3. The agent-count check (`:618-626`) is `live + new_existing + adopts`.
4. Pre-lock the egress rows of every `Existing{dedicate:true}` instance, in id order.
5. `lock_own_instances` (`project_members.rs:100-119`) walks `Existing` ids **in id order**: `FOR UPDATE` if `dedicate`, `FOR SHARE` otherwise.
6. Every `Existing{dedicate:false}`: `mixed_allowed` false → `AgentNotIsolated`; no acknowledgement → `Invalid`. Every join counts as shared.
7. `Existing{dedicate:true}`: `free_instance_check`, `retire_workspace(Some(p),"dedicate")`, revoke its private grants.
8. `Adopt(n)`: `INSERT INTO instances (id, user_id, agent_id, agent_version, harness, name, workspace_id, limits, workspace_project_id, peer_access) VALUES (…, $p, false)`, then `append_event(instance.state)`.
9. `put_agents` for all, then the invite settles as today. `Accepted.agents` includes the new ids. A repeat accept returns the existing agents and adopts nothing.

**`add_project_agents`** (`project_members.rs:163-196`) takes `&[JoinAgent]`, `mixed_allowed` and `max_instances`. The rules are the same, with the advisory lock after `project_actor`. "Shared" is `projects.shared_at IS NOT NULL`, read under the project lock.

**`release_instance(user, instance) -> Result<Instance>`:**
1. `lock_users(&[user])`.
2. Plain read of `workspace_project_id` (NULL → `Invalid("not dedicated")`).
3. `lock_project(p)`.
4. Pre-lock egress rows, then `lock_instance` `FOR UPDATE`.
5. Deleted → `NotFound`; **`workspace_project_id` ≠ `p` → `Conflict("changed, try again")`**.
6. A live `project_agents` row → `Conflict("withdraw it from the project first")`; unfinished runs → `Conflict`.
7. `retire_workspace(None, "release")`, which also turns `peer_access` back on as for a fresh instance.
8. Audit `instance.release`.

The private grant is re-issued lazily by `ensure_instance_grant` (`routes/runs.rs:67-91`).

**`retire_project_workspaces(p)`** (no waiting):

```sql
SELECT id FROM instances WHERE workspace_project_id = $1 AND state <> 'deleted' ORDER BY id FOR UPDATE SKIP LOCKED
```

For each id it runs `retire_workspace(id, None, "project_deleted")` with no egress pre-lock; the SKIP LOCKED steps inside cover it. It is called:
- in `delete_project` after `stop_project(…, true)` (`project_lifecycle.rs:165-166`);
- **in the erase loop after `stop_project` (`users.rs:229`).**

Its runs were just cancelled, and `instances_dedicated_alone` does not fire, because the new value is NULL.

**Erase** already sets `dedicated = false` on the user's agent rows (`users.rs:243-250`). Its instances become deleted and are purged, and `mark_instance_purged` clears `workspace_project_id`.

### 2.7 Purge (`project_lifecycle.rs:276-366`)

Add these to the `for sql in [...]` list, **before** the events and runs steps:

```sql
DELETE FROM egress_requests WHERE id IN (SELECT id FROM egress_requests WHERE project_id = $1 LIMIT $2 FOR UPDATE SKIP LOCKED)
DELETE FROM vault_requests WHERE id IN (SELECT id FROM vault_requests WHERE project_id = $1 LIMIT $2 FOR UPDATE SKIP LOCKED)
DELETE FROM device_calls WHERE id IN (SELECT id FROM device_calls WHERE project_id = $1 LIMIT $2 FOR UPDATE SKIP LOCKED)
DELETE FROM board_posts WHERE id IN (SELECT id FROM board_posts WHERE project_id = $1 ORDER BY id LIMIT $2 FOR UPDATE SKIP LOCKED)
DELETE FROM content_reports WHERE id IN (SELECT id FROM content_reports WHERE project_id = $1 AND state = 'closed' LIMIT $2 FOR UPDATE SKIP LOCKED)
```

- **Backstop** (Rust, before the leftover check):
  1. `retire_project_workspaces(p)` for live instances.
  2. Then, for deleted instances, including ones an 8.15 `mark_instance_purged` left pointing at `p`:
     ```sql
     UPDATE instances SET workspace_project_id = NULL, workspace_archive_key = NULL, workspace_archive_id = NULL,
            workspace_archive_bytes = NULL, workspace_archive_sha256 = NULL, workspace_archived_at = NULL,
            workspace_archive_pending = NULL, workspace_archive_pending_since = NULL
      WHERE id IN (SELECT id FROM instances WHERE workspace_project_id = $1 AND state = 'deleted' FOR UPDATE SKIP LOCKED)
     ```
     The trigger queues the `projects/<p>/` blobs from `OLD` (V14). Control's instance purge still destroys the sandbox and volume.
  - Do **not** make the FK `ON DELETE SET NULL`: that would silently turn a live instance holding project content into a private one.
- **Leftover check** (`:343-353`): add `OR EXISTS (SELECT 1 FROM instances WHERE workspace_project_id = $1)` and the four SET NULL tables. Open `content_reports` are not counted; there is no FK to projects.
- **Closed reports of already purged projects:** a separate bounded step in `orchestrator::projects::sweep`, not inside `purge_deleted_projects`:
  ```sql
  DELETE FROM content_reports WHERE id IN (SELECT id FROM content_reports c WHERE c.state = 'closed' AND c.project_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM projects p WHERE p.id = c.project_id) LIMIT $1 FOR UPDATE SKIP LOCKED)
  ```

---

## 3. Orchestrator, control, sandbox, agent-shim, llm-gw

### 3.1 What each backend and harness provides

| Backend | Isolation for a dedicated instance | Retire | Archive |
|---|---|---|---|
| **Local** (`sandbox/src/local.rs:1-9`) | **None.** A dev/test backend; agents can read the host. 8.16 limits the platform-tool `resolve` to the sandbox's own directory and volume (§3.5). | `destroy` removes `sandboxes/<id>`; `delete_workspace` removes `volumes/<ws>` (`:376-395`) | Not used (volumes persist) |
| **Cube** (one KVM microVM per sandbox) | Own kernel, processes, `/tmp`, loopback, envd and volume `ws-…` at `/sandbox/workspace` (`cube.rs:404-461`) | `DELETE /sandboxes/{id}` (`cube.rs:580-612`) plus `DELETE /volumes/{id}` (`:614-630`) | Only without volumes: `projects/<p>/workspaces/…`, project DEK |
| **ACS** (one Pod per sandbox) | Own Pod, IP, `/tmp`; no volumes (`acs.rs:402-404`) | Pod delete (`acs.rs:545-576`); `delete_workspace` is a no-op | Always: `projects/<p>/workspaces/…`, project DEK, OSS |

Per harness, all state lives under HOME = `/sandbox/workspace/.thinktin/home`, with cwd = `/sandbox/workspace` (`exec.rs:115-118,206`; `agent-shim/src/config.rs:142`).

| Harness | State |
|---|---|
| Claude | `CLAUDE_CONFIG_DIR=$HOME/.claude` (`config.rs:163-197`) |
| Codex | `CODEX_HOME` (`:213-243`) |
| Pi | `PI_CODING_AGENT_DIR` (`:269-295,475-489`) |
| OpenClaw | `OPENCLAW_STATE_DIR`; AGENTS.md and SOUL.md in cwd (`:300-371`) |
| Hermes | `HERMES_HOME` (`:380-423`) |
| All | `$HOME/.thinktin/shim-session.json` (`state.rs:16-37`); bridge socket and vault helper under `$HOME/.thinktin`; browser profile in `/tmp`; outputs in `cwd/.thinktin/browser` |

A fresh or reset workspace has no `shim-session.json`, so the first project run starts a new session (already tested at `agent-shim/tests/shim.rs:206,457`).

### 3.2 `crates/control`

- **`workspace.rs`:**
  - `pub enum ArchiveOwner { User(UserId), Project(ProjectId) }` with `fn of(rt: &InstanceRuntime)`.
  - `WorkspaceStore::key(&self, owner, workspace, id)` gives `workspaces/<u>/<ws>/<id>` or `projects/<p simple>/workspaces/<ws>/<id>` (`:40-42`).
  - `put`, `delete` and `restore` take `owner` (`:51-78`).
- **`lib.rs` call sites:** `:1480` (`key`), the `settle_archive` delete (`:1666`), `put` (`:1771`) and `restore` (`:1820`) pass `ArchiveOwner::of(&rt)` from the same runtime read that produced the key.
  - A retire mid-archive makes `record_archive` return `Recorded::Skipped` (`:1594-1597`), not `Superseded`. `settle_archive` then deletes the object under the owner it was written with (`:1648-1676`). The retire also queued the old pending key, so the double delete is harmless.
- **`Lifecycle::sweep`** (`:881-985`): a new last step, `retired`.
  - `w.retired_workspaces_due(batch)` is `SELECT … FROM retired_workspaces WHERE retry_at <= now() ORDER BY retry_at LIMIT $1 FOR UPDATE SKIP LOCKED`.
  - For each: `provider.destroy` on every `sandbox_ids` entry (NotFound is OK), `provider.delete_workspace(workspace_id)`, then `DELETE` the row.
  - On error: `attempts+1`, `retry_at = now() + least(2^attempts, 60) min`, `last_error`.
  - `SweepReport.retired`.
- **`pub fn new_instance(templates, spec: AdoptSpec) -> Result<store::NewInstance>`** wraps `resolve` (`:234-265`) and uses `store::new_workspace_id()`.
- **`ensure_running`:** unchanged. A retired instance has no sandbox, so it goes to `create` (`:769-771`).

### 3.3 `crates/orchestrator`

- **`workspaces.rs` (`ObjectWorkspaceStore`):**
  - `check_owner(owner, key)` checks the prefix for that owner (`:185-193`).
  - `User(u)` uses `user_vault(…, u, create)` with subject `u.to_string()`; `Project(p)` uses `artifacts::project_vault(…, p, create)` with subject `project_key_context(p)`. `put` uses `create = true`; `restore` uses `false`.
  - `ArtifactError::Gone` on restore becomes "the project was deleted; its workspace archive can no longer be opened".
- **`shim.rs`:** `ToolContext` (`:67-75`) gains `pub project: Option<ProjectId>` (8.17 needs it). `ShimLaunch` is unchanged.
- **`tools.rs`:** `pub const PROJECT_RUN_TOOLS: [&str; 5] = ["artifact_publish","artifact_list","artifact_read","artifact_fetch","web_search"];` and `pub fn allowed_in_space(name: &str, project: Option<ProjectId>) -> bool`. There is no refusal in `ToolSet::call`; dispatch already checks `allowed_tools` (`executor.rs:1898-1918`).
- **`executor.rs` `start`** (`:724-995`):
  - After `ensure_running`: `if rt.workspace_project_id != rec.run.project_id { return Err(Outcome::Failed("the instance is not isolated for this run's space".into())) }`. This check runs before handoff copy (`:824-829`), launch and every tool call. The DB invariants (D4) keep it true for the whole run, so there are no checks in `ExecConnector`, `HandoffCopier` or `ArtifactTools::origin`.
  - **Grant:** `(Some(g), _) => g`, `(None, None) => active_grant_for_instance…`, `(None, Some(_)) => Err(Outcome::Failed("a project run needs its project grant".into()))` (replacing `:745-752`).
  - **Tool filter** (`:845-851`): add `.filter(|t| crate::tools::allowed_in_space(&t.name, rec.run.project_id))`. This also removes computer, delegate and vault tools, so `reveal` (`:2017`) refuses and `has_computer`/`lead` stay as they are.
  - **Scrubber** (`:979`): `scrubber: if rec.run.project_id.is_some() { Scrubber::new() } else { self.scrubber(rec.user_id).await }`. Project runs reveal nothing in 8.16; 8.18 adds only the project-granted items.
  - `ToolContext { project: rec.run.project_id, … }`.
  - **Interrupt preface** (`:787-802`): unchanged. Cross-space interrupts cannot happen before level 2 (§8).
  - **Resume brief** (`:926-951`): unchanged. It reads only this run's events; covered by a test.
- **`executor.rs`, other changes:**
  - `new_messages` (`:1506-1535`) passes `self.rec.run.project_id`.
  - A worker append that fails with `Invalid("project_deleted")` is logged at debug and treated as "run gone".
  - `finish_inner` is unchanged.
- **`outbox.rs` `notify` / `notify_tenant`** (`:209-247`): use the `(id, project)` returned by `insert_inbox`. When the project is `Some`, skip the IM loop and set the push payload's `project_id` from it. This covers approval notices (`executor.rs:2142-2160,2273-2290`), egress notices (`egress.rs:27-34`) and every other caller that never sets `Notice.project`.
- **`projects.rs`** (orchestrator):
  - `accept` (`:275-323`) and `add_agents` (`:348-376`) take the new terms and, when anything dedicates or adopts, call `project_vault(db, kms, p, true)` **before** the transaction. `Gone` maps to `NotFound`.
  - Audits record per agent `{instance, dedicated, adopted, reset, ack_shared_memory}`.
  - New `dedicate_agent` and `release_instance`.
  - `sweep` gains the orphan sweeper (2.5) and the closed-report cleanup (2.7).
  - The wrappers take `kms: Arc<dyn Kms>` from `AppState`.
- **`ask.rs`, `delegate.rs`, `peers.rs`:** targets come from 2.4. `store::Error::InstanceDedicated` from a child insert maps to `ToolOutput::error("that agent works only for a project and cannot take private tasks")`.
- **`scheduler.rs`, `pipeline.rs`, gateway `hooks.rs`:** no change. Active plans and steps cannot point at a dedicated instance (0055), and resuming a paused one is refused.

### 3.4 agent-shim

No change (D21).

### 3.5 sandbox (Local backend only)

`LocalProvider::resolve` (`local.rs:167-187`) accepts `probe.starts_with(dir) || probe.starts_with(own_volume)`, where `own_volume = dir.join("workspace").canonicalize()?` when volumes are on. The test: a symlink in the new workspace to `../../volumes/<old ws>/notes.txt` gives `Invalid("escapes the sandbox")` for `read_file`.

### 3.6 llm-gw

`proxy.rs:749-752`: when `caller.instance.dedicated`, skip `gw.scrubber(...)`, including the "vault unavailable" refusal. Project runs have no vault access, and scrubbing with the owner's whole vault would expose the values (D14). This needs `Instance.dedicated` in the directory (`llm-gw` directory type, filled from `GatewayInstance.dedicated`).

---

## 4. Dedicated instances and the non-dedicated warning

**Data:** `instances.workspace_project_id`, the derived `project_agents.dedicated`, `project_agents.shared_memory_ack_at`, `retired_workspaces`, and the two instance CHECKs (§1.1).

**DTOs (proto):**
- `Instance.dedicated_project_id: Option<ProjectId>` (`#[serde(default, skip_serializing_if = "Option::is_none")]`, `domain.rs:521-544`).
- `ProjectAgentView.dedicated: bool` (`#[serde(default)]`, `domain.rs:1062-1075`; selected at `project_reads.rs:444-449`).

**Consent and preview** (`domain.rs:607,1150-1188`):
- `PROJECT_CONSENT_VERSION = 2`.
- `project_consent::DEDICATED_AGENT = ["dedicated_takes_no_private_tasks", "dedicated_memory_holds_only_this_project", "dedicated_existing_agent_is_reset"]`.
- `project_consent::MIXED_AGENT = ["mixed_private_memory_may_enter_project", "mixed_project_content_may_stay_in_memory"]`.
- `ProjectInvitePreview` gains `dedicated_agent`, `mixed_agent` and `mixed_agents_allowed`. The distinct-keys test (`domain.rs:1840-1856`) covers all four lists.

**Private entry points a dedicated instance refuses:**

| Entry point | Behaviour |
|---|---|
| `POST /v1/instances/{id}/runs`, both deliveries (`routes/runs.rs:31-64`), and `ensure_instance_grant` (`:67-91`) | 409 `instance_dedicated` (pre-check from `dedicated_project_id`; the DB is the backstop) |
| Vault `resume_after_request` (`routes/vault.rs:408-439`) | Skipped when `instance.dedicated_project_id.is_some()` or `request.project_id.is_some()`; `t.run(run)` NotFound means no resume |
| `POST /v1/plans`, `PATCH /v1/plans/{id}`, plan resume (`routes/plans.rs:143,273,379`) | 409 `instance_dedicated` |
| Webhook receive (`hooks.rs:312`) | 409; unreachable |
| `ask`, `delegate` from private runs | Not listed; insert refused |
| `/v1/projects` create, `/v1/teams*` PUT with an instance dedicated **elsewhere** | 409 `instance_dedicated` (trigger). An instance dedicated to that same solo project works (A1). |
| **`PATCH /v1/instances/{id}` with `peer_access: true`** | **409 `instance_dedicated`** (pre-check; CHECK `instances_dedicated_no_peers` is the backstop) |
| Adopt (`routes/instances.rs:33-55`) | Never creates dedicated instances |

These remain allowed on a dedicated instance:
- `PATCH /v1/instances/{id}` for name, purpose and egress;
- `PUT /v1/instances/{id}/routes`;
- version change;
- archive;
- delete.

---

## 5. Gateway and client-core

### 5.1 Config

- `GatewayConfig.mixed_project_agents: bool` (default false, `gateway/src/lib.rs:46-61`).
- Server `[api] mixed_project_agents` (`server/src/config.rs:141-169`). **Validation fails at startup when it is true while `store::ISOLATION_LEVEL < 2`.** Tests set the gateway field directly.

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

- Each entry has exactly one of `instance_id` and `adopt`, otherwise 422. `dedicated` without `reset_workspace: true` gives 422. A legacy `instance_ids` body gives 422 "update the app".
- `adopt` is resolved with `control::new_instance(s.templates, …)`; `max_instances` comes from `[api.limits] instances_per_user`.
- **201 or 200:** `ProjectDetail`.
- **Errors:**
  - 422 `invalid`: consent or version, missing acknowledgement or reset, bad entry;
  - 409 `agent_not_isolated`;
  - 409 `instance_dedicated`;
  - 409 `conflict` (`instance_not_free`);
  - 409 `instance_limit`;
  - 409 `project_agent_limit` / `project_member_limit`;
  - 404.

**`POST /v1/projects/{id}/agents`** (`projects.rs:212-244`): `AgentReq` (`:63-69`) gains the same fields plus `consent_version`. Mixed agents need the acknowledgement only when the project has `shared_at`.

**`POST /v1/projects` (tenant solo create):** `adopt` or `dedicated` gives 422.

**New `PATCH /v1/projects/{id}/agents/{instance_id}`** with `{"dedicated": true, "reset_workspace": true}`:
- 200 `ProjectDetail`;
- 404 when not a member or the agent is not in the project;
- 403 when not your agent;
- 409 `conflict` (`instance_not_free`);
- 409 `instance_dedicated`;
- 422 for `dedicated: false` or a missing reset.

It goes on the same route as `withdraw_agent` (`mod.rs:214-217`) and is not behind `cross_user()`.

**New `POST /v1/instances/{id}/release`:**
- 200 `Instance`;
- 404;
- 422 if not dedicated;
- 409 `conflict`.

**Error mapping** (`gateway/src/error.rs:66-97`):
- `InstanceDedicated` → `ErrorCode::InstanceDedicated`;
- `AgentNotIsolated` → `ErrorCode::AgentNotIsolated`;
- `InstanceLimit { max }` → `ErrorCode::InstanceLimit`.

Both new codes return 409 (`proto/src/api.rs:69-77`).

**`consent()`** (`projects.rs:43-48`) becomes `consent(given, version: Option<u32>)`, returning `Consent { version: version.unwrap_or(1) }`.

**`/v1/egress-requests`, `/v1/board`, vault request lists, `/v1/reports`, `/v1/inbox`:** no code change. The policies hide project rows after leaving.

### 5.3 client-core (`crates/client-core`)

- **`api.rs`:**
  - `ProjectJoinAgent { Existing { instance_id, dedicated, reset_workspace, ack_shared_memory }, Adopt { agent_id, harness, name } }`.
  - `ProjectJoin.agents`. `body()` (`:92-118`) adds `"consent_version": PROJECT_CONSENT_VERSION`.
  - `add_project_agents(id, &[ProjectJoinAgent], consent)` (`:1944-1958`).
  - `set_project_agent_dedicated` and `release_instance`.
- **`ffi.rs`:**
  - Records `ProjectJoinAgent` (`instance_id`, `adopt`, `dedicated`, `reset_workspace`, `ack_shared_memory`, all with defaults) and `ProjectAdopt`. Exactly-one validation gives `ClientError` invalid.
  - `ProjectJoin.agents` replaces `instance_ids` (`:1301-1325`); `add_project_agents` (`:3255-3272`).
  - `set_project_agent_dedicated(project_id, instance_id, reset_workspace) -> ProjectDetail`, `release_instance(instance_id) -> Instance`, `project_consent_version() -> u32`.
  - `Instance.dedicated_project_id` (`:263-287`), `ProjectAgent.dedicated` (`:952-977`), and the preview fields (`:1080-1126`).
- **`error.rs`:** docs for the new codes.
- **`cache.rs`:** no change.
- **`tools/client-core/ffi_smoke.py`:** the new shapes.

### 5.4 Android

Regenerate `apps/android/core/src/main/kotlin/cn/thinktin/core/client_core.kt` with `tools/client-core/gen-bindings.sh`, in its own commit.

---

## 6. Tests

### 6.1 Store: new `crates/store/src/tests/isolation.rs` (`mod isolation;` in `tests.rs`)

Real Postgres, migrated by the non-superuser owner.

1. **`claim_takes_dedicated_project_runs_only`:**
   - private instance A, dedicated instance B in P, mixed instance C in P;
   - the worker claims A's and B's runs, never C's;
   - after exit, withdraw, archive or soft delete, B's queued run is not claimed;
   - an urgent project run on C does not block A.
2. **`old_claim_sql_never_returns_project_runs`:** the exact 8.15 SQL of `claim_next_run`, `take_over_expired`, `claim_expired_waits` and `due_pipelines` (copied from `6724b7f`) returns nothing for B's run.
3. **`lease_fence_refuses_without_isolation`:**
   - with no setting, every lease statement on B or C gives `Forbidden`;
   - at level 1, B works and C is refused;
   - **at level 1 B passes running → waiting_approval → running → succeeded through `transition_run`, which is refused with no setting;**
   - renew and release work without the setting;
   - **a claim that hits the fence returns `Ok(None)` and the transaction is still usable.**
4. **`dedicated_instances_refuse_private_work`:** tenant `create_run`, `queue_urgent_run`, `create_run_grant`, plan create, plan resume, step insert, and `create_solo_project` / `replace_my_project_agents` with an instance dedicated elsewhere all give `InstanceDedicated`. **Tenant `update_instance(peer_access: true)` gives `Invalid`.**
5. **`dedicate_races_private_message`** (barrier, 20 rounds): exactly one of the two wins, and no non-terminal private run ever sits on a dedicated instance.
6. **`dedicating_retires_the_workspace`:**
   - retired ids recorded; blob queued; new `workspace_id`; `provisioning`; epoch +1; `peer_access` false;
   - grants revoked; egress rows gone and the pending ones' inbox items read; a pending vault request expired and its inbox item read;
   - refusals for unfinished runs, an active plan or a row elsewhere.
7. **`accept_with_adopt_is_atomic`:**
   - adopt creates a dedicated instance with `peer_access` false;
   - a later failure leaves no instance;
   - `InstanceLimit`; **the agent cap counts adopts;**
   - a repeat accept returns the same agents.
8. **`mixed_agents_need_the_switch_and_the_ack`.**
9. **`dedicated_flag_is_derived`:** includes the rewritten `tests.rs:1559-1598` and **`update_team` on a team whose member is dedicated to it (A1)**.
10. **`run_linked_rows_carry_the_project`:**
    - for each table, insert as the proper role (tenant, worker, `Db::llmgw` for egress), and `project_id` equals the run's;
    - after exit, a tenant insert gives `Invalid` (23503);
    - a tenant that supplies `project_id` gets `Forbidden`; the worker may with no run; a mismatch gives `Invalid`;
    - `UPDATE … SET project_id` and moving `run_id` are refused, except an egress touch;
    - FK `SET NULL` keeps `project_id`;
    - a worker insert into a deleted project gives `Invalid("project_deleted")`;
    - tenant `UPDATE vault_requests SET run_id` is denied;
    - tenant SELECT hides the rows after leaving.
11. **`purge_clears_project_rows_and_dedicated_workspaces`:**
    - delete retires the dedicated instance in the same transaction;
    - **a dedicated instance locked by another transaction is skipped by delete and retired by purge;**
    - **a deleted-but-unpurged dedicated instance is cleared by purge and its blob queued;**
    - **with 21 deleted projects, all are purged;**
    - an open report survives, and the maintenance step deletes it once closed after the project row is gone.
12. **`cancel_and_decide_do_not_deadlock`:** 30 rounds per helper; never 40P01. **Also `cancel_user_runs` against a finishing executor transaction (`transition_run` + `cancel_run_approvals`).**
13. **`orphan_sweeper_frees_the_instance`:**
    - a backoff project run whose agent row was marked left by raw SQL;
    - **`take_over_expired` and `claim_expired_waits` skip it;**
    - `cancel_orphaned_project_runs` cancels it, settles its approval, expires its pending egress request, bumps the epoch, and appends no event for a deleted project;
    - a private run on another instance is untouched.
14. **`worker_cannot_append_to_deleted_projects`.**
15. **`application_name_is_versioned`:** `SELECT application_name FROM pg_stat_activity WHERE pid = pg_backend_pid()` = `thinktin/i1`.
16. **Space filters:** `unannounced_messages` per space; `peers` and `delegation_targets` skip B; `instance_holder` / `last_finished_run` private only; the board ignores project posts.
17. **`archive_keys_follow_the_space`:**
    - 8.15-style `begin_workspace_archive` with `workspaces/<u>/…` on B gives `Invalid` (23514);
    - a `projects/<p>/workspaces/` key on A gives `Invalid`;
    - the existing `workspace_archives_queue_replaced_objects` (`tests.rs:5225-5371`) still passes.
18. **`dedicate_and_release_race_instance_delete`** (A2/A4): with tenant `delete_instance` concurrent, there is no 40P01 and a deleted instance is never set back to `provisioning`.
19. **`retire_races_egress_always`** (A3): with tenant `decide_egress_request(Always)` concurrent, there is no 40P01. Afterwards the request is gone or expired, or the decision committed first.
20. **`creator_erase_retires_members_dedicated_instances`** (A9): the erase transaction retires what it can lock; purge retires the rest.

### 6.2 control (`crates/control/tests/lifecycle.rs`, `workspaces.rs`)

- **`dedicated_archive_is_owned_by_the_project`:** `ArchiveOwner::Project(p)` and a `projects/<p>/workspaces/` key on archive; the same owner on restore.
- **`sweep_destroys_retired_workspaces`:** destroy both sandboxes, delete the old volume, delete the row; a flaky error schedules a retry.
- **`retire_during_archive_deletes_the_upload`:** `Recorded::Skipped`, and `store.delete` gets the project owner.
- **`retire_during_restore_removes_the_new_sandbox`** (`:1078-1083`).

### 6.3 orchestrator (`crates/orchestrator/tests/`)

- **`isolation.rs`** (FakeConnector, `LocalProvider` in a tempdir):
  - **`project_run_gets_only_project_tools`:** the grant lists vault, board, schedule, delegate, ask and peers, but the launch has only `PROJECT_RUN_TOOLS` and `ToolContext.project = Some(p)`. A refused tool name dispatched by the shim gets "unknown platform tool". `VaultReveal` gets an error. No computer tools appear.
  - **`project_run_scrubber_is_empty`:** with an owner vault item `1234`, a project run's `agent.message` "1234" is stored unscrubbed, while a private run's is scrubbed.
  - **`project_run_without_grant_fails`.**
  - **`space_mismatch_is_refused`:** a project run on a mixed instance forced past claim fails in `start` before handoff or launch.
  - **`piggyback_stays_in_space`.**
  - **`dedicating_gives_a_fresh_workspace`** (LocalProvider; control-plane wiring only, not isolation):
    - private files and a fake `shim-session.json` in A;
    - dedicate, then `ensure_running`;
    - `read_file` gives NotFound for all of them, and a symlink to the old volume is refused (§3.5);
    - `artifact_publish path=notes.txt` fails;
    - the old volume is gone after sweep.
  - **`released_instance_forgets_project_files`.**
  - **`left_members_instances_stop`.**
  - **`project_notices_skip_im`:** a finished project run's notice **and an approval notice in a project run** get an inbox row with `project_id` and a push item with `project_id`, but no IM item.
  - **`resume_brief_reads_only_its_run`.**
- **`workspaces.rs`:** `dedicated_archive_needs_the_project_key`, `deleted_project_workspaces_are_undecryptable`, `private_archive_cannot_be_opened_with_the_project_key`.
- **llm-gw unit test:** an instance with `dedicated = true` is forwarded without vault scrubbing, even when the vault is unavailable.

### 6.4 sandbox

The `local.rs` unit test for `resolve`: a symlink into another volume is refused.

### 6.5 Gateway (`crates/gateway/tests/api.rs`)

- **Join:** adopt + dedicated + ack; `consent_version` 1 or missing gives 422; mixed with the switch off gives 409 `agent_not_isolated`; switch on without acknowledgement gives 422, with it 201; an instance dedicated to another project gives 409; **a legacy `instance_ids` body gives 422**.
- **`PATCH /v1/projects/{id}/agents/{instance}`:** 200 / 403 / 409 / 422.
- **`POST /v1/instances/{id}/release`:** 409, then 200 after withdrawing, then 422 on a private instance.
- **Private refusals:** private message, plan create, plan resume and **`PATCH peer_access: true`** on a dedicated instance give 409. **`PUT /v1/teams/{id}` with a member dedicated to that team gives 200.**
- **Shapes:** `dedicated_project_id`, `agents[].dedicated`, the preview keys.
- **Server config:** `mixed_project_agents = true` fails validation.
- **Old-client checks:**
  - `GET /v1/instances/{dedicated}/events` and the WebSocket return no project-run events;
  - `/v1/egress-requests` hides project rows after leaving;
  - **`/v1/inbox` returns project-run notices with `project_id` and hides them after leaving.**

### 6.6 client-core (`crates/client-core/tests/client.rs`)

- Accept sends entries and `consent_version = 2`.
- The new paths and JSON.
- Decoding defaults.
- `project_consent_version() == 2`.
- FFI exactly-one validation; `ffi_smoke.py`.

---

## 7. Commit sequence

Each commit compiles, passes `cargo test --workspace`, fmt and clippy, is pushed immediately, and updates `docs/progress/claude-determined-lovelace-vn0j5h.md`. The claim opens only after the executor, tools and workspaces handle the space (C8 after C6–C7).

| # | Commit | Files |
|---|---|---|
| C1 | proto: error codes, `Instance.dedicated_project_id`, `ProjectAgentView.dedicated`, consent v2 keys and preview fields; store error variants and constraint mapping; gateway mapping | `proto/src/{api,domain}.rs`, `store/src/error.rs`, `gateway/src/error.rs` |
| C2 | Migration 0055; store `columns!`/`runtime_columns!`, `Db::worker` isolation, `application_name`, `new_workspace_id`, `mark_instance_purged`, claim fence handling; fixtures (`tests.rs:1190`, `tests/projects.rs:1789`, `gateway/tests/api.rs:5456`); rewrite `tests.rs:1559-1598`; schema and owner tests; tests 3, 4, 9, 14, 15, 17 | `store/migrations/0055_*.sql`, `store/src/{lib,instances,runs,error,schema}.rs`, tests |
| C3 | Migrations 0056–0058; board private filter; purge steps and leftover check; tests 10, 11 (table part) | `store/migrations/0056-0058`, `store/src/{board,project_lifecycle}.rs`, tests |
| C4 | Store: cancel lock order (three helpers and `cancel_user_runs`), `expire_run_requests`, space-aware queries, `insert_inbox` returning the project, `gateway_instance.dedicated`, orphan sweeper; tests 12, 13, 16 | `store/src/{runs,instances,users,inbox,llmgw}.rs`, tests |
| C5 | Store: `retire_workspace`, `dedicate_project_agent`, `release_instance`, `JoinAgent`/`JoinTerms`, accept and add changes, `retire_project_workspaces` in delete and erase, purge backstop; tests 5–8, 11 (instance part), 18–20 | `store/src/{project_members,project_invites,project_lifecycle,instances,users}.rs`, tests |
| C6 | control `ArchiveOwner`, `new_instance`, retired sweep; orchestrator `ObjectWorkspaceStore` per owner; sandbox Local `resolve`; control, orchestrator and sandbox workspace tests | `control/src/{lib,workspace}.rs`, `orchestrator/src/workspaces.rs`, `sandbox/src/local.rs`, tests |
| C7 | Orchestrator: `ToolContext.project`, `PROJECT_RUN_TOOLS` filter, start check, grant rule, empty scrubber, `new_messages`, IM skip from the stored project, deleted-project handling, `projects.rs` wrappers (key first) and `sweep` additions; llm-gw scrub skip; unit and orchestrator tests except the claim end-to-end ones | `orchestrator/src/{shim,tools,executor,outbox,projects,ask,delegate,peers}.rs`, `llm-gw/src/{proxy,directory}.rs`, `server/src/workers.rs` |
| C8 | **Open the claim:** `isolated!`/`live_space!` in claim, takeover and expired waits; urgent per space; tests 1, 2 and the orchestrator isolation end-to-end tests | `store/src/runs.rs`, tests |
| C9 | Gateway: join/add entries, `consent_version`, PATCH agent, release, private-entry refusals (including `peer_access`), `mixed_project_agents` config and its validation; API tests | `gateway/src/{lib,routes/*}.rs`, `server/src/config.rs`, `gateway/tests/api.rs` |
| C10 | client-core API, FFI, docs, tests, smoke script | `client-core/src/{api,ffi,error}.rs`, tests, `tools/client-core/ffi_smoke.py` |
| C11 | Android bindings regenerated (only `apps/android/**`) | `client_core.kt` |
| C12 | Docs:<br>• projects-impl "8.16 做了什么" and **the scope note: per-space isolation is for dedicated instances only, and the mixed path ships switched off until level 2. Record this in `wbs.md` 8.16 as well.**<br>• `sandbox-cube.md:31`; `browser.md:269,307`.<br>• `release.md`: application name, isolation level, DB fences, the 8.17 dispatch switch, rollback.<br>• `deploy-checklist.md`: bucket prefix `projects/*/workspaces/`, versioning off or a lifecycle rule.<br>• This plan as `docs/progress/drafts/projects-8.16-plan.md`; the progress file. | `docs/**` |

**Rollback 8.16 → 8.15.** It is safe because the database keeps enforcing the 8.16 rules:
- 8.15 never claims project runs, and the fence refuses them anyway.
- The private-work triggers keep dedicated instances out of private work.
- `instances_dedicated_no_peers` keeps them out of 8.15's `agents_list`, `agent_status` and `ask`.
- `instances_archive_space` makes an 8.15 control plane's archive of a dedicated instance fail before upload (23514). The sandbox stays running, and an error is logged on every sweep until 8.16 returns. No project plaintext is sealed with a personal DEK.
- 8.15 cannot restore a dedicated instance's archive, because `check_owner` refuses `projects/` keys. A dedicated ACS instance that was archived stays asleep until 8.16 returns.
- With no writer in 8.16, no project runs exist.

After 8.17 writes project runs, roll back by turning the dispatch switch off and cancelling non-terminal project runs first.

---

## 8. What 8.16 leaves for 8.17–8.19 and level 2, and what needs real cloud verification

**8.17:**
- **Dispatcher:**
  - the only writer of executable project runs;
  - writes only when a **DB-held dispatch switch** is on, flipped by the operator after the deploy checklist confirms that no pre-8.16 replica runs;
  - **`legacy_sessions()` is advisory.** Count only sessions of the server login role (e.g. `usesysid = (SELECT oid FROM pg_roles WHERE rolname = session_user)`), so an old llm-gw or relay does not hold the gate;
  - writes only when the target agent is dedicated and live and the actor is checked through `ProjectActor`;
  - issues project grants;
  - **an INSERT-time fence requiring `thinktin.isolation >= 1` for project runs** (pipelines take no lease, D10).
- Lead.
- Project-scoped board, ask, delegate, `agents_list`/`agent_status`, schedule and pipelines. Each adds its name to `PROJECT_RUN_TOOLS` and uses `ToolContext.project`.
- **The project board must not be readable by 8.15's space-blind `board` reads.** Use a separate table, or hide project rows from the tenant policy unless `current_setting('thinktin.isolation', true)` is set; `Db::tenant` would set it from 8.17.
- `due_pipelines` with `isolated!`.
- Cross-owner trees.
- Team runs as project runs.
- Urgent project messages.
- Egress "always allow" for project work.

**8.18:**
- Vault per item: tools and reveal in project runs; scrub only granted items; never use `vault_items.instance_ids` for project access; pending uniqueness per space.
- Computer per project.
- Budgets in llm-gw.
- Approvals to the owner.
- Tenant notice paths.

**8.19:**
- Receipts, including "your dedicated agent was reset".
- The feed.
- IM pushes of project content.
- Reporting others' content.

**Mixed-instance isolation (level 2; after 8.19, with 15.7):**
- A separate sandbox per (instance, project).
- **Verification before opening:** no traversal into sibling HOME or workspace, no old model memory, no restore of another scope's archive, `/proc/<pid>/environ` and the bridge socket unreachable across spaces.
- **Prerequisites that are dead code until then:**
  - a per-space holder choice in `queue_urgent_run` (`runs.rs:629-640`);
  - pending uniqueness per space for egress (`0034:29`) and vault requests (`0009:41`);
  - an `egress_requests` same-space check when `run_id` moves;
  - the cross-space interrupt preface;
  - an acknowledgement from the creator's existing mixed agents once a project becomes shared;
  - binding archives to the workspace id as well as the project.
- Then raise `ISOLATION_LEVEL` to 2, and the `[api] mixed_project_agents` validation lets the switch on.
- **Accepted and documented:** `egress_log` (`0032:26-50`) for a dedicated instance stays readable by an ex-member. It is metadata only (host, bytes, time).

**Founder-run cloud checks:**
1. **ACS (Tokyo):**
   - adopt a dedicated agent and run one project run (8.17, or a worker-SQL seed);
   - idle-archive and check the OSS object is under `projects/<p>/workspaces/` and cannot be opened with the user's key;
   - delete the project, check the restore fails and the sweeper deletes the Pod;
   - measure create + restore time.
2. **Cube:**
   - a dedicated adopt creates its own volume;
   - retire, then confirm through the Cube API that both the VM and the volume are gone;
   - **confirm a dedicated sandbox cannot reach the retired private sandbox's IP or envd port 49983 while it waits for the sweep** (ACS documents no sandbox-to-sandbox traffic, `sandbox-acs.md:121`);
   - measure the extra microVM memory per dedicated agent.
3. **OSS buckets:** versioning off or a lifecycle rule; any prefix-scoped RAM policy also covers `projects/*/workspaces/`.
4. **RDS:** `set_config('thinktin.isolation', …)` works for `thinktin_server_login` under `SET ROLE thinktin_worker`; `application_name` is visible to the login role.

---

## Appendix A. Critics' corrections: Applied / Rejected

Isolation critic = S; implementation critic = I; corrections found while checking = O.

| # | Correction | Verdict | Verification and reason |
|---|---|---|---|
| S1 | The project-run scrubber leaks the owner's vault values (a guessing oracle) | **Applied** (D14, §3.3, §3.6) | `executor.rs:979` builds it from the whole owner vault (`vault.rs:255-288`), the minimum length is 4 (`keyvault/src/lib.rs:842`), and llm-gw scrubs prompts too (`proxy.rs:435-463,749-752`). Members read `agent.message`. Project runs get an empty scrubber; llm-gw skips scrubbing for dedicated instances (`GatewayInstance.dedicated`). |
| S2a | 8.15 control can seal project plaintext with the personal DEK; add an archive-key CHECK | **Applied** (as I-A7's form) | `control/src/lib.rs:1480-1487`, `archives()` `:1328-1333`. A CHECK ties the prefix to the space (V14). |
| S2b | Bind the `<ws>/` component in the CHECK and in `check_owner` | **Rejected** | It would break the deliberate `artifacts/someone-else` case and the `ws-1` key on a `vol-1` instance in `tests.rs:5242,5366-5371`. Moving another instance's archive into a row needs a worker-only column write. The AAD binds subject and archive id. The project prefix already blocks crossing projects. Listed as a level-2 prerequisite. |
| S2c | Rewrite the rollback paragraph | **Applied** (§7) | 8.15's archive fails before upload; its restore refuses `projects/` keys. |
| S3 | IM gate misses approval and egress notices | **Applied** (with I-B2) | `outbox.rs:65-76,209-247`; approval notices `executor.rs:2142-2160,2273-2290` set no project. The guard (`0054:176-191`) fills it; `insert_inbox` now returns it. |
| S4 | Creator erase does not retire workspaces | **Applied** (D7, §2.6) | `users.rs:219-241` uses `stop_project` directly. `retire_project_workspaces` is called there too, with SKIP LOCKED (I-A9). |
| S5a | The `pg_stat_activity` gate is unreliable | **Applied** (D11) | Pool minimum 0 and llm-gw/relay share the name (`llm-gw/src/main.rs:331`, `relay/src/main.rs:104`). `legacy_sessions()` moves to 8.17 as advice; 8.17 uses a DB-held switch. |
| S5b | CHECK `NOT peer_access` on dedicated instances | **Applied** (0055, §4) | 8.15 `peers()` filters `peer_access` (`instances.rs:556`), `agent_status` uses `peers()` (`peers.rs:80-89`), `accepts_questions` reads it (`runs.rs:444-452`). Default true (`0024:5`), so adopt and dedicate set false and release sets true. V14. |
| S5c | 8.17 project board must stay hidden from old reads | **Applied** (§8 note) | 8.17 scope. |
| S6 | Takeover and expired waits without liveness notify ex-members and loop | **Applied** (D9, D12) | `take_over_expired` → Retry → RunFailed notice; D17 append failure rolls back the finish. Both now require `live_space!`; the sweeper finishes non-live runs without notices. |
| S7a | Retire must not leave unread inbox items; expire pending vault requests | **Applied** (D6, §2.6) | `inbox_items.egress_request_id` has no FK (`0035:4`); pending vault requests outlive runs. Done with SKIP LOCKED after an egress pre-lock (I-A3). |
| S7b | Remove the instance from `vault_items.instance_ids` | **Rejected** | `instance_ids = '{}'` means **every** instance (`0009:12`, `vault.rs:52,112-114`). Removing the only id would widen access. Vault is off in project runs; noted for 8.18. |
| S7c | Project cancels and the sweeper expire pending egress and vault requests of cancelled runs | **Applied** (§2.3 step 3) | `claim_egress_asks` has no run-state filter (`egress.rs:646-674`). Placed before the epoch bump with SKIP LOCKED, because `decide_egress_request` locks the request and then the instance (`egress.rs:555,580`). |
| S8 | The purge leftover check blocks for ever on deleted or old-purged instances | **Applied** (with I-A8) | `mark_instance_purged` (`instances.rs:789-803`) does not clear the column in 8.15. The backstop clears deleted rows (any `purged_at`) together with their keys. The FK stays NO ACTION. |
| S9 | `stamp_project_from_run` needs a deleted-project check | **Partly applied** | Worker only, nested IF. `thinktin_llmgw` has no grant on `projects` (`0039:226`), and V15 shows an `AND`-ed EXISTS fails for it. llm-gw only stamps active runs, which delete cancels. |
| S10 | Tenant can repoint `vault_requests.run_id`; freeze `run_id` | **Applied** (0056) | Table-wide tenant UPDATE (`0009:60`); tenant code writes only `status, item_id, resolved_at` (`store/vault.rs:289,363`). Column grants, plus a `run_id` freeze except FK nulling and egress touch. V14. |
| S11 | Local backend test proves nothing; tighten `resolve` | **Applied** (D21, §3.5) | `local.rs:178-181` accepts any `volumes/` path; `local.rs:1-9` says there is no isolation. One-line hardening; the test was renamed and its claim narrowed. |
| SF1 | V1 incomplete: `transition_run` fires the fence | **Applied** (V1, D10, test 3) | `runs.rs:1506`; V14. |
| SF2 | A claim fence error aborts the claim transaction | **Partly applied** (§2.2) | The savepoint only handles `Conflict` (`runs.rs:1068-1078`). Rolling back and continuing would re-select the same row, so the claim rolls back to the savepoint and returns `Ok(None)` with a metric. |
| SF3 | An in-flight archive gets `Skipped`, not `Superseded`; owner from the same `rt` | **Applied** (D6, §3.2) | `unchanged()` compares `sandbox_id` (`lib.rs:1418-1430`); `record_archive` `:1594-1597`; `settle_archive` `:1648-1676`. |
| SF4 | Fixture list: drop `tests/projects.rs:2397` | **Applied** | Private run via `queue_run` (`tests.rs:62-70`). |
| SF5 | D10 "any future SQL path" overclaims; pipelines take no lease; 8.17 INSERT fence | **Applied** (D10, §8) | `runs.rs:1562-1575`. The INSERT fence is deferred to 8.17 to keep fixture churn (raw worker INSERTs in three test files) out of 8.16. |
| SS1 | D13: settle approvals of late-matched ids too | **Applied** (§2.3 step 6) | Normally a no-op. |
| SS2 | D8: create the key before the API returns | **Applied** (with I-B3) | `store/projects.rs:223-237`. |
| SS3 | `release_instance` re-checks the project after the lock | **Applied** | §2.6 step 5. |
| SS4 | Level-2 prerequisites (urgent holder, pending uniqueness, creator's mixed agents ack) | **Applied** (§8) | `runs.rs:629-640`, `0034:29`, `0009:41`. |
| SS5 | Old-client checks include `/v1/inbox` | **Applied** (§6.5) | `store/inbox.rs:192-210` lists everything the policy allows. |
| SS6 | `egress_log` readable by an ex-member | **Applied** (documented, §8) | Metadata only. |
| SS7 | Cloud check for Cube cross-sandbox reachability | **Applied** (§8) | — |
| I-A1 | Derived `dedicated` breaks tenant team writes via the 0049 policy | **Applied** (0055) | Reproduced (V13): 42501 on the `INSERT … ON CONFLICT` from `projects.rs:394-405`; the fixed policy passes. `0049:110-113`. |
| I-A2 | `retire_workspace` can revive a deleted instance | **Applied** (§2.6) | `lock_instance` has no state filter (`instances.rs:667-677`). Callers return NotFound; the UPDATE is guarded and 0 rows means NotFound. |
| I-A3 | Egress delete after the instance lock deadlocks with decide | **Applied** (§2.6) | `egress.rs:555,580`. Pre-lock egress rows before the instance where waiting is allowed; SKIP LOCKED inside retire; inbox items marked read. |
| I-A4 | Dedicate locks the agent row before the instance | **Applied** (§2.6) | `project_members.rs:184-186`; tenant delete changes the instance and then agent rows (`instances.rs:385-402`). Plain read, then instance lock, then re-read. |
| I-A5 | Erase would take approvals before runs | **Applied** (§2.3) | `cancel_user_runs` (`runs.rs:820-840`) restructured. The executor's `finish_inner` takes runs then approvals (`executor.rs:1161,1171`). |
| I-A6 | `tests.rs:1559-1598` breaks; fixture list wrong | **Applied** (§1.3) | Rewritten. `tests.rs:1190` and `tests/projects.rs:1789` kept; 2397 dropped. **Also found:** `gateway/tests/api.rs:5456` (O1). |
| I-A7 | Archive-space CHECK constraint | **Applied** (0055) | V14; the existing archive test keeps passing. |
| I-A8 | Deleted-but-unpurged instances stall purge | **Applied** (§2.7) | The `LIMIT 20` candidates (`project_lifecycle.rs:283-289`). V14 shows the blob is queued from `OLD`. |
| I-A9 | Retire inside delete breaks the short-transaction rule; erase not covered | **Applied** (D7) | `control/src/lib.rs:626-627,1032-1041`. SKIP LOCKED in delete and erase, with the purge backstop. |
| I-A10 | The fence fires on `transition_run` | **Applied** | Same as SF1. |
| I-B1 | Write the stamp function like `inbox_project_guard` | **Applied** (0056) | `0054:158-191`; V14. |
| I-B2 | IM skip from the stored project | **Applied** | Same as S3. |
| I-B3 | Project key before the transaction | **Applied** (D5, §3.3) | `project_vault(create=false)` reports a missing key as `Gone` (`artifacts.rs:240-245`); `insert_project_key` is active-only. |
| I-B4 | Move `legacy_sessions()` to 8.17 and count only server logins | **Applied** (D11, §8) | `store/src/lib.rs:107-115` is shared by all deployments. |
| I-B5 | Tie the mixed switch to the isolation level | **Applied** (D18, §5.1) | — |
| I-B6 | Advisory key built in Rust, placed before the invite lock; agent cap counts adopts | **Applied** (§2.6) | `instances.rs:259-262`; `project_invites.rs:561-567,618-626`. |
| I-B7 | Orphan sweeper cost | **Applied** (moved to hourly maintenance) | Maintenance default 3600 s (`server/src/config.rs`, `Worker::default`); the 15 s takeover tick is avoided; it uses `runs_project_recent` (`0052`). |
| I-B8 | Explain `queue_urgent_run` | **Applied** (§2.4) | `runs.rs:606-660`. |
| I-B9 | V11 wording: `egress_requests` has no WITH CHECK | **Applied** (0056 comment) | `0034:42`. |
| I-C1 | Defer the orphan sweeper and test 13 to 8.17 | **Rejected** | S6 makes takeover skip non-live runs, so the sweeper is the only thing that finishes them. Kept, but moved to hourly maintenance (I-B7). |
| I-C2 | Drop the redundant tool and space checks | **Applied** (D14, §3.3) | `allowed_tools` is enforced at dispatch (`executor.rs:1898-1918`), reveal requires `vault_list` (`:2017`), and handoff runs after the start check (`:824-829`). `ToolContext.project` is kept. |
| I-C3 | Defer the interrupt preface, `egress_run_same_space` and the scheduler backstop | **Applied** | Unreachable before level 2. Retire expires pending egress requests, so none crosses spaces. Listed in §8 as level-2 prerequisites. |
| I-C4 | Hard-code `project_id IS NULL` in `instance_holder` / `last_finished_run` | **Applied** (§2.4) | Only caller `peers.rs`. |
| I-C5 | The `finish_inner` reorder fixes no cycle | **Applied** (dropped) | `cancel_descendants` touches no approvals (`runs.rs:1151-1182`). |
| I-C6 | The shim test already exists; drop C12 | **Applied** | `agent-shim/tests/shim.rs:206,457`. |
| I-C7 | Drop the closed-report sweep | **Rejected** (moved instead) | Closed reports hold project content snapshots (`0019:16`) after the project is gone, and item 7 asks for cleanup. Erase only covers the reporter (`users.rs` erase list). The sweep moves out of `purge_deleted_projects` into `projects::sweep`. |
| I-D | Missing tests | **Applied** | Tests 3, 9, 11, 12, 17–20, the gateway teams/legacy-body cases (§6.5) and the orchestrator approval-IM case. |
| I-F | Record the scope (dedicated only, mixed off) in the WBS and progress notes | **Applied** (C12) | — |
| O1 | Missed fixture `gateway/tests/api.rs:5456` (raw worker transaction sets `lease_owner` on a project run) | **Applied** | Found by grep for `lease_owner = '`. |
| O2 | `IF … AND EXISTS (SELECT … projects)` fails for roles without the grant | **Applied** (nested IF in both functions) | V15. |
| O3 | Retire must also stop a pending egress request from moving into the new space | **Applied** (by S7a/I-A3) | `touch_request` moves pending requests to the instance's later run (`egress.rs:380-395`). |

## Appendix B. Things the critics confirmed (rechecked)

- The private-entry triggers cover every path.
- A new `workspace_id` gives a new Cube volume.
- Tokens are bound to sandbox and epoch (`llm-gw/src/proxy.rs:404-431`).
- Old-client event streams filter `project_id IS NULL`.
- `ensure_instance_grant` ignores project grants.
- No code writes project runs.
- The four old filters are at `runs.rs:1014,1135,1434,1567`.
- HOME is inside the workspace; uid 1001 everywhere; ACS has no volumes.
- The replaced functions are owned by the migration owner.
- Error mapping is at `error.rs:63-71`.


## 待定问题

- Agents that are not dedicated, in projects shared with other people. The product rules say: warn the owner, then allow it. The pilot rules say: only agents that can be fully separated. 8.16 builds the warning screen but leaves this switched off. Such an agent could join but could not do project work until a later release separates it properly. Default: not allowed during the pilot; the setting can only be turned on once that later release exists.
- Making an agent someone already uses into a project-only agent. It loses its memory and files (they are wiped) and stops taking private tasks. Default: allowed, but the owner must tick "reset this agent" first. The other way is a new agent made just for the project, which keeps the old one untouched.
- What happens to a project-only agent after its owner leaves the project. Default: it stays idle and keeps the project memory, so rejoining picks up where it left off. The owner can press "Release", which wipes it and makes it a normal private agent again. The other way is to wipe it automatically on leaving.
- When a project is deleted, its project-only agents are wiped and turned back into private agents. They keep their names, but their memory and files are gone. Default: yes. The owner gets an "agent was reset" message in a later release (8.19).
- Project-only agents count toward each person's agent limit, and each needs its own sandbox, which costs money to run. Default: they count, and the cost will be measured in the cloud checks before launch.
- A project-only agent is hidden from the owner's other agents. They cannot see what it is doing or send it questions, and this cannot be switched back on while it is project-only. Default: yes, because otherwise private agents could read project work.
- Saved passwords (the vault), the owner's computer, and group-chat bots (Feishu, WeCom, DingTalk) are not available to project work yet. Passwords and computer come in 8.18, group-chat notices in 8.19. Until then, project work only reaches the app inbox and phone notifications. Default: yes.
- Reports someone files about content in a deleted project. Default: kept until the team has handled them, then deleted automatically. The other way is to keep handled reports for a fixed time.