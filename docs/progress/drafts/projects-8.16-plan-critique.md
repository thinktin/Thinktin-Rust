# 8.16 方案评审（两个角度）

## 隔离与安全

**Verdict.** The core design holds on the real backends. The isolation unit is a whole dedicated instance: separate sandbox, volume or archive, HOME, session slot and /tmp, with epoch and sandbox-bound tokens. The DB triggers close every private way to create runs or grants on a dedicated instance. But the plan has seven holes that let private and project data cross, plus several wrong factual claims. In order of severity:

## 1. HIGH: the owner's whole-vault scrubber gives project members a way to guess the owner's passwords

- **What happens.** In every run, including project runs, `executor.rs:979` builds the scrubber with `self.scrubber(rec.user_id)` from the owner's entire vault (`orchestrator/src/vault.rs:255-288`).
  - Each password is replaced with the label `[vault:<item name>]` (`keyvault/src/lib.rs:864-878`). The minimum length is 4 characters (`MIN_SCRUB_LEN`, `lib.rs:842`), so 4-digit PINs are covered.
  - It is applied to every persisted event payload (`persist_with`, `executor.rs` around line 1238).
  - llm-gw scrubs the prompt the same way before forwarding (`llm-gw/src/proxy.rs:435-463, 749-752`).
- **Why members can see it.** Members can read `agent.message` text and `agent.plan` entries (`0054_project_scoped_reads.sql:89-95`).
- **Attack.** A member gives the owner's dedicated agent a task like "print 0000…9999". The model sees, or the event log stores, `[vault:bank-pin]` at the matching position. The member learns both the PIN and the item name. Hiding the item name in the label does not help: the position of the replaced text still gives the value away.
- **Correction (add to D14):** "A project run's scrubber holds only values revealed in this run, which in 8.16 means it is empty. The Exec scrubber starts empty when `rec.run.project_id.is_some()`. llm-gw does no user-vault scrubbing for tokens of instances with `workspace_project_id` set (the directory needs that column). 8.18 scrubs only the items granted to the project."

## 2. HIGH: an 8.15 control plane can seal project plaintext with the personal DEK; the rollback is not safe

- **What happens.** 8.15 builds the archive key as `store.key(rt.user_id, …)` (`control/src/lib.rs:1480`) and commits it as pending before uploading (`:1482-1487`; `store/src/instances.rs:808-827`).
  - That only happens on backends without persistent volumes (`lib.rs:1328-1333`), which includes production ACS.
  - Archive keys are worker-only columns, so no tenant grant stops this.
- **Attack.** During the rolling deploy, or after an 8.16 → 8.15 rollback, an old replica's idle sweep archives a dedicated instance. Project plaintext ends up under `workspaces/<u>/…`, sealed with the user DEK. That breaks impl item 5. The 8.16 restore then fails `check_owner`, so the instance also stops working.
- **Second problem.** The AAD binds only the subject and the archive id (`keyvault/src/lib.rs:626-640`). The prefix check is only `workspaces/<u>/` (`orchestrator/src/workspaces.rs:185-193`). One project DEK is shared by every owner's dedicated instances, so instance A's archive would decrypt if restored into B. impl item 5 asks for an archive key per (instance, project).
- **Correction (add to 0055):**
  ```sql
  ALTER TABLE instances ADD CONSTRAINT instances_archive_scope CHECK (
    (workspace_archive_key IS NULL OR starts_with(workspace_archive_key, CASE WHEN workspace_project_id IS NULL
        THEN 'workspaces/' || replace(user_id::text,'-','') || '/' || workspace_id || '/'
        ELSE 'projects/' || replace(workspace_project_id::text,'-','') || '/workspaces/' || workspace_id || '/' END))
    AND (workspace_archive_pending IS NULL OR starts_with(workspace_archive_pending, <same CASE>)));
  ```
  - Keep the `-- deploy-safe:` comment.
  - `check_owner` also takes the workspace id and requires the `<ws>/` component.
  - Rewrite the §7 rollback paragraph: "safe only because of `instances_archive_scope`; old replicas fail to start an archive of a dedicated instance and log an error."

## 3. HIGH: the IM gate misses approval notices, so project content reaches IM group bots

- **What happens.** The plan gates IM on `notice.project.is_none()` in `outbox.rs:209-226`. Approval is an IM event (`outbox.rs:65-76`).
  - The approval notice (`executor.rs:2142-2160`) and the skipped-approval notice (`:2273-2290`) never set `project`. Their body is the agent-written tool title.
  - Egress notices (`orchestrator/src/egress.rs:27-34`) don't set it either.
  - The inbox guard fills `project_id` from the run (`0054:176-191`), but `notify` never sees that value.
- **Correction:** "`insert_inbox` returns `(id, project_id)` using the guard-filled value. `notify` and `notify_tenant` skip IM, and set the push payload's `project_id`, from the stored value, not from `Notice.project`." Add a test for an approval in a project run producing no IM outbox item.

## 4. MEDIUM-HIGH: erasing the creator's account soft-deletes projects without retiring workspaces

- **What happens.** `erase_account` soft-deletes the creator's projects in its own loop: `users.rs:219-230` sets the status, deletes the key and calls `stop_project`. The plan adds `retire_project_workspaces` only to `delete_project` (after `project_lifecycle.rs:165-166`).
- **Effect.** Other members' dedicated sandboxes and Cube volumes keep project plaintext until the purge backstop runs, at least `PROJECT_PURGE_GRACE` = 10 minutes later (`orchestrator/src/projects.rs:591`). That contradicts impl item 7.
- **Correction:** call `retire_project_workspaces(p)` inside the erase loop right after `stop_project`, or add a shared `soft_delete_project` helper used by both paths. Do not put it in `stop_project`, because archive also uses it.

## 5. MEDIUM: the D11 write gate on `pg_stat_activity` is unreliable; old binaries need DB-enforced fences

- **Missed old processes.** Replicas can run with only the API role enabled (`server/src/lib.rs:109-112`). `Db::connect` uses sqlx pool defaults: minimum 0 connections, 10-minute idle timeout (`store/src/lib.rs:107-115`). An idle old API-only replica can therefore have no connections and is not counted. A connection pooler also rewrites `application_name`.
- **False alarms.** relay (`relay/src/main.rs:104`) and llm-gw (`llm-gw/src/main.rs:331`) also connect as `thinktin`, so a lagging relay blocks the gate.
- **The hazard D11 names is real.** 8.15's `agent_status` runs in a tenant transaction (`peers.rs:91-158`). The tenant policy shows the owner's project runs and events while the owner is a member (`0054:135-140`).
- **Correction: close it in the DB.**
  - Add `CHECK (workspace_project_id IS NULL OR NOT peer_access)`, and set `peer_access = false` in `retire_workspace` when dedicating.
  - Old `peers()` filters `AND peer_access` (`instances.rs:556`) and `accepts_questions` reads `peer_access` (`runs.rs:444-452`), so old binaries never see dedicated instances.
  - Section 4 must move "PATCH peer access" from the allowed list to "409 `instance_dedicated`".
  - The 8.17 dispatcher is gated by a DB-held switch the operator flips after the deploy checklist confirms old replicas are gone. `legacy_sessions()` is advisory only.
  - For 8.17's project board, either use a separate table or hide project rows from the tenant policy unless `current_setting('thinktin.isolation', true)` is set; `Db::tenant` would set it in 8.16 and later.

## 6. MEDIUM: takeover and expired waits without liveness notify ex-members and can loop

- **What happens.** `take_over_expired` calls `finish(Retry)` (`executor.rs:560-578`). On the last attempt that becomes Failed and sends a RunFailed notice (`executor.rs:1077-1085`). `expire_waits` also ends in Failed with a notice (`:581-617`).
  - With "isolated only", an orphan from a left project sends a push to the ex-member.
  - An orphan in a deleted project fails at `append_event` (D17), which rolls back the whole finish, including the transition. It keeps the takeover lease and is taken over again every lease period until the sweeper catches it. The plan's "treated as run gone" does not make the run terminal.
- **Correction:** apply `live_space!` in `take_over_expired` and `claim_expired_waits` as well. Non-live runs are handled only by `cancel_orphaned_project_runs` (cancel, no notice). It already selects lease-expired rows, because a dead lease holds no row lock.

## 7. MEDIUM: pending side requests survive dedication and exit

- **Unread inbox items after the delete.** `retire_workspace` runs `DELETE FROM egress_requests`. `inbox_items.egress_request_id` has no FK (`0035:4`), so those inbox items stay unread forever.
- **Pending vault requests.** Private `vault_requests` stay pending. Fulfilling one lets the now-dedicated instance use that item ("填好后允许这个实例使用", `orchestrator/src/vault.rs:111-125`).
- **Push to ex-members.** `claim_egress_asks` has no run-state filter (`store/src/egress.rs:646-674`). Pending egress requests of project runs cancelled at exit are still pushed to the ex-member.
- **Correction:**
  - In `retire_workspace`, expire pending `egress_requests` and `vault_requests` for the instance and mark their inbox items read, using the `delete_instance` pattern (`instances.rs:409-417`). Also remove the instance from `vault_items.instance_ids`.
  - In `cancel_project_*` and the sweeper, expire pending egress and vault requests whose `run_id` is among the cancelled ids.
  - Note for 8.18: an empty `instance_ids` means every instance (`vault.rs:52`), so it must never decide vault access for project runs.

## 8. MEDIUM: the purge leftover check can block project purge forever

- **What happens.** The plan's backstop retire only selects `state <> 'deleted'`. The 8.15 `mark_instance_purged` (`instances.rs:791-803`) doesn't clear `workspace_project_id`. The new leftover check `EXISTS (instances WHERE workspace_project_id=$1)` is therefore true forever for deleted or old-purged instances.
- **Correction (in purge):**
  - `UPDATE instances SET workspace_project_id = NULL WHERE workspace_project_id = $1 AND purged_at IS NOT NULL`.
  - Extend the backstop retire to deleted-but-unpurged rows, so their keys are cleared and the blobs queued.
  - The leftover check counts only `purged_at IS NULL`.
  - Do not make the FK `ON DELETE SET NULL`: that would silently turn a live instance holding project content into a private one.

## 9. LOW-MEDIUM: `stamp_project_from_run` has no deleted-project check

D17 covers events, approvals and artifacts only. The worker and llm-gw can still insert `board_posts`, `live_activities`, `egress_requests` and `device_calls` rows for a deleted project's runs. **Correction:** add the same check as `fill_space_from_run` for `current_user IN ('thinktin_worker','thinktin_llmgw')`.

## 10. LOW: the tenant can repoint `vault_requests.run_id` across spaces

The tenant has table-wide UPDATE on `vault_requests` (`0009:60`), and the stamp trigger only freezes `project_id`. The tenant code only writes `status`, `item_id` and `resolved_at` (`store/src/vault.rs:289, 363`). **Correction:** `REVOKE UPDATE ON vault_requests FROM thinktin_app; GRANT UPDATE (status, item_id, resolved_at) …`. Also freeze `run_id` in `stamp_project_from_run`, except the FK action that sets it to NULL, on every table except `egress_requests`.

## 11. LOW: the Local backend test proves nothing

`local.rs:178-181` accepts any canonical path under `volumes/`. A symlink in the new workspace pointing to `../../volumes/<old ws>` lets `read_file` and `artifact_publish path=` read the retired private workspace until the sweep runs. **Correction:** limit `resolve` to `volumes/<own workspace>`, a one-line sandbox change, and add the symlink case to `project_session_cannot_see_private_files`. Otherwise drop the claim that this test shows isolation.

## Factual corrections to the plan

- **V1 is incomplete.** `transition_run` always sets `lease_owner = CASE … ELSE lease_owner END` (`runs.rs:1506`), so the fence also fires on every transition that keeps the lease. Document this and test it.
  - The claim savepoint rolls back only on `Conflict` (`runs.rs:1068-1078`), so a 42501 aborts the whole claim. Map the `runs_isolation` constraint to rollback-to-savepoint.
- **D6/§3.2.** After a retire, an in-flight archive gets `Recorded::Skipped`, because `unchanged()` compares `sandbox_id` (`lib.rs:1418-1430`), not `Superseded`. `settle_archive` then deletes the object (`lib.rs:1648-1676`). The behaviour is fine, but `ArchiveOwner` must come from the same `rt`.
- **Fixtures.** `tests/projects.rs:2397` is a private run (`queue_run`, `tests.rs:62-70`) and needs no isolation setting. `tests.rs:1190` and `tests/projects.rs:1789` do need it.
- **D10 "any future SQL path".** `due_pipelines` advances pipelines without taking a lease (`runs.rs:1562-1575`), so the fence doesn't cover it. For 8.17, also require `thinktin.isolation >= 1` on INSERT of project runs.
- **D2/D21 are confirmed.**
  - uid 1001 everywhere (`Dockerfile:36,130`); `ExecSpec` has no uid (`sandbox/src/lib.rs:115-121`).
  - HOME is `.thinktin/home` (`exec.rs:113-118`), so `sandbox-cube.md:31` is wrong.
  - Only `PR_SET_DUMPABLE` is set (`agent-shim/src/main.rs:481`); `browser.md:269` (subreaper) and `:307` (`main.rs:450`) are stale.

## Smaller items

- **D13:** runs cancelled by the filter UPDATE but not in the locked set still need their approvals settled.
- **D8:** `insert_project_key` works only while the project is active (`store/projects.rs:223-237`). Creating the key "best effort" can leave an archived project's dedicated instance unable to archive or rebuild on ACS. Create it before the API returns, or allow it while archived.
- **`release_instance`:** re-check `workspace_project_id == p` after `lock_instance`.
- **Before mixed isolation (level 2) opens:**
  - make `queue_urgent_run`'s holder choice space-aware (`runs.rs:629-640`);
  - make pending uniqueness per space for egress requests (`0034:29`, per instance) and vault requests (`0009:41`, per user name);
  - require the creator's existing mixed agents to acknowledge once the project becomes shared.
- **Old-client checks (§6.5) should include `/v1/inbox`.** It returns project-run notices (`store/inbox.rs:203`), and pre-8.15 clients cache them (`client-core/src/cache.rs:300-375`) and never forget them on leave.
- **`egress_log` (`0032:26-50`)** for a dedicated instance stays readable by an ex-member. It is metadata only; accept it and document it.
- **Founder cloud check to add:** confirm that a dedicated Cube sandbox cannot reach the retired private sandbox's IP or envd port 49983 while it waits for the sweep. ACS already documents no sandbox-to-sandbox traffic (`sandbox-acs.md:121`).

## Verified as correct

- **Private entry points.** The DB triggers cover every private path that creates runs, grants, plans or steps on a dedicated instance. They also cover the `FOR KEY SHARE` and `FOR UPDATE` serialization, because the FK on `runs → instances` already takes `KEY SHARE`.
- **Cube volume.** A new `workspace_id` gives a new volume (`cube.rs:404-461`).
- **Old tokens.** Tokens are bound to the sandbox id and epoch (`llm-gw/src/proxy.rs:404-431`), so old ones die on retire.
- **Create race.** The no-restore create holds the instance lock (`control/src/lib.rs:1032-1060`), and the restore path re-checks `restoring_sandbox_id` (`lib.rs:1078-1083`).
- **Tool reads.** Artifact scope follows the run tree (`store/src/artifacts.rs:205-231`). Handoff copies only from sibling runs, which share the space. Reveal is also gated on `vault_list` (`executor.rs:2017`).
- **Old-client events.** `events_after` and the WebSocket stream filter `project_id IS NULL` (`store/src/events.rs:88, 102`; `gateway/routes/events.rs:150-170`).
- **`ensure_instance_grant`** ignores project grants (`grants.rs:140-141`).

## 实现

The plan holds up on the main mechanisms (dedicated instance as the isolation unit, the claim predicate, the lease fence, the per-owner archive key), but several steps fail as written. The worst is a tenant policy that turns `PUT /v1/teams/{id}` into a 500 (A1). Corrections follow, most severe first.

# A. Must fix (wrong or blocked as written)

**A1. Deriving `dedicated` in a trigger breaks tenant team writes.**
- 0049 sets `ALTER POLICY tenant_insert ON project_agents WITH CHECK (user_id = app_user_id() AND NOT dedicated AND …)` (`0049_project_member_role.sql:110-113`).
- The new BEFORE trigger runs before the RLS check, so on a tenant insert it sets `dedicated := true` for an instance dedicated to that same solo project.
- `replace_my_project_agents` re-inserts every agent with `INSERT … ON CONFLICT DO UPDATE` (`store/src/projects.rs:394-405`). PostgreSQL checks the INSERT WITH CHECK on the proposed row even when the conflict path is taken. Result: 42501 → `Error::Forbidden` (`error.rs:69`) → 500 on `PUT /v1/teams/{id}` once a team agent is dedicated. D5 explicitly allows that ("dedicating in a never-shared own project is allowed").
- Fix: add to 0055 (the tenant still has no column grant on `dedicated`, `0039:220`):
```sql
-- dedicated 由 project_agents_dedicated 触发器从实例算（租户没有这一列的权限，0039:220）：插入策略不再查 NOT dedicated，
-- 不然单人项目里专属于它的 agent 一改团队（INSERT … ON CONFLICT 先按插入策略查拟插入的行）就 42501。
ALTER POLICY tenant_insert ON project_agents
    WITH CHECK (user_id = app_user_id()
                AND EXISTS (SELECT 1 FROM projects p WHERE p.id = project_id
                              AND p.creator_id = app_user_id() AND p.shared_at IS NULL AND p.status = 'active'));
```
- The other option is to forbid dedicating inside never-shared projects. Either way, add a test that runs `update_team` on a team that has a dedicated member.

**A2. `retire_workspace` can bring a deleted instance back.**
- `lock_instance` returns deleted rows (`instances.rs:667-677`, no state filter).
- The plan's `UPDATE instances SET … state = 'provisioning' … WHERE id = $1` has no state guard; only the `INSERT INTO retired_workspaces … WHERE state <> 'deleted'` has one.
- A PATCH dedicate or a release racing the tenant's `delete_instance` (`instances.rs:384-391`) would set a deleted instance back to provisioning. It would keep its `deleted_at`, and the purge would never pick it up (`instances.rs:779`).
- Corrected text:
  - Callers return `NotFound` when `rt.state == Deleted` after the lock.
  - `retire_workspace` uses `UPDATE … WHERE id = $1 AND state <> 'deleted'` and errors if 0 rows.

**A3. Deleting `egress_requests` after the instance lock deadlocks with the tenant's egress decision.**
- `decide_egress_request` locks the request row (`egress.rs:555`), then runs `UPDATE instances SET egress_hosts` (`egress.rs:580`).
- `retire_workspace` (in dedicate, accept, release, delete and purge) holds the instance `FOR UPDATE`, then runs `DELETE FROM egress_requests WHERE instance_id`. That is the opposite order, so 40P01.
- Also, deleting rows leaves their inbox items unread: there is no FK from `inbox_items` (`0035:4`).
- Corrected text:
  - Callers take `SELECT id FROM egress_requests WHERE instance_id = $1 ORDER BY id FOR UPDATE` immediately before `lock_instance`.
  - `retire_workspace` copies `delete_instance` (`instances.rs:408-417`): expire the pending rows and mark their inbox items read (`FOR UPDATE SKIP LOCKED` when the owner's users row is not locked), then delete the decided rows.

**A4. `dedicate_project_agent` locks the agent row before the instance.**
- Plan step 2 takes the agent row `FOR NO KEY UPDATE`, then step 3 takes the instance `FOR UPDATE`.
- 8.14 deliberately avoids this (`project_members.rs:184-186`). Tenant `delete_instance` updates the instance first and the `project_agents` rows second (`instances.rs:385-402`).
- `lock_instance_projects` only pre-locks the projects the instance was in at read time (`projects.rs:410-414`), so an add that commits in between leaves a deadlock window.
- Corrected steps:
  1. `project_actor`.
  2. Plain read of the agent row; the project lock already serializes worker writers.
  3. `lock_instance` `FOR UPDATE`; refuse if deleted.
  4. Re-read the agent row (live, owner).
  5. Free check, then the rest as planned.

**A5. Erase would take approvals before runs.**
- Plan 2.3 puts `UPDATE approvals … WHERE run_id IN (…)` before `cancel_user_runs`. The three project cancel helpers and the orphan sweeper use runs → approvals.
- The sweeper takes no project lock, so erase (approval A, then run R) against the sweeper (R, then A) can deadlock.
- Corrected text: restructure `cancel_user_runs` (`runs.rs:820-840`) like the project helpers:
  1. `lock_runs_where!("user_id = $1")` and collect the ids.
  2. `settle_cancelled_approvals(&ids)`.
  3. `bump_epochs_where!`.
  4. `UPDATE runs`.

  Freeze and stop-all get the same fix.

**A6. An existing test breaks, and the fixture list is wrong.**
- `tests.rs:1559` runs a raw `UPDATE project_agents SET dedicated = true` on a live row. The trigger now forces it to false, so `assert!(left && dedicated)` at `tests.rs:1598` fails. The plan's test 9 says this test keeps passing; it does not.
  - Rewrite: set `instances.workspace_project_id = team.id` as worker, then touch the row.
- Fixtures that lease project runs on non-dedicated instances inside `db.worker()`:
  - `tests.rs:1190` (also 1191 is in the same loop),
  - `tests/projects.rs:1789` (via `copy_into_project`).
- `tests/projects.rs:2397` is a private run (`queue_run` → tenant `create_run`, `tests.rs:62-70`), so the fence never applies. Drop it from the list.

**A7. Rolling back to 8.15 could seal project plaintext with the personal DEK.**
- 8.15's control still idle-archives running sandboxes. It builds `workspaces/<u>/…` keys with the user DEK (`control/src/lib.rs:1480`; `orchestrator/src/workspaces.rs:185-193,232-238`).
- Harmless while no project run has executed, but the plan's rollback paragraph calls 8.16→8.15 "safe" without that condition.
- Fence it in the database, the same way the plan fences claims. Add to 0055:
```sql
ALTER TABLE instances ADD CONSTRAINT instances_archive_space CHECK (CASE
    WHEN workspace_project_id IS NULL THEN
        NOT starts_with(coalesce(workspace_archive_key, ''), 'projects/')
        AND NOT starts_with(coalesce(workspace_archive_pending, ''), 'projects/')
    ELSE coalesce(starts_with(workspace_archive_key,
                  'projects/' || replace(workspace_project_id::text, '-', '') || '/workspaces/'), true)
        AND coalesce(starts_with(workspace_archive_pending,
                  'projects/' || replace(workspace_project_id::text, '-', '') || '/workspaces/'), true) END);
```
- Every 8.16 writer already sets the project and clears the keys in one statement:
  - `retire_workspace`;
  - `mark_instance_purged`;
  - `begin_workspace_archive` / `finish_workspace_archive` (`instances.rs:812-868`).

  So the constraint costs nothing. An 8.15 binary gets 23514 and records an archive failure instead.

**A8. Deleted-but-unpurged instances can stall project purge, and the purge can starve.**
- The new leftover check `EXISTS (SELECT 1 FROM instances WHERE workspace_project_id = $1)` also matches `state = 'deleted'` instances. Those are only cleared by `mark_instance_purged`, after the provider calls succeed (`control/src/lib.rs:1872-1887`).
- Candidates are always the 20 oldest (`project_lifecycle.rs:283-289`). Twenty blocked projects stop every later deleted project from being purged.
- Backstop fix: also clear deleted instances, archive keys included, so the trigger still queues the `projects/<p>/` blobs from `OLD`:
```sql
UPDATE instances SET workspace_project_id = NULL, workspace_archive_key = NULL, workspace_archive_id = NULL,
       workspace_archive_bytes = NULL, workspace_archive_sha256 = NULL, workspace_archived_at = NULL,
       workspace_archive_pending = NULL, workspace_archive_pending_since = NULL
 WHERE id IN (SELECT id FROM instances WHERE workspace_project_id = $1 AND state = 'deleted' FOR UPDATE SKIP LOCKED)
```

**A9. Retiring inside `delete_project` breaks the short-transaction rule, and erase is not covered.**
- impl item 7 requires the delete to be a short transaction. `ensure_running_once` holds `lock_instance` `FOR UPDATE` (`control/src/lib.rs:626-627`) across `provider.create` (`:1032-1041`). The delete would wait on other owners' instances while holding the project lock and the run locks.
- Erase soft-deletes the creator's projects through `stop_project` directly (`users.rs:220-246`), not through `delete_project`, so plan 2.6 does not retire those instances.
- Corrected D7: "Delete retires the dedicated instances it can lock without waiting (`FOR UPDATE SKIP LOCKED`). The purge backstop retires the rest, including projects deleted by erasing their creator."
- Waiting until purge is acceptable: no run can start (claim liveness, D4), and the archive key is already destroyed.

**A10. The lease fence also fires on `transition_run`.**
- `transition_run` keeps `lease_owner = CASE WHEN $8 THEN NULL ELSE lease_owner END` in its SET list (`runs.rs:1506`). So `BEFORE UPDATE OF lease_owner … WHEN (NEW.lease_owner IS NOT NULL)` fires on every transition that keeps the lease (for example running → waiting_approval).
- At level 1 this is correct, but V1 is incomplete: it also costs one instance lookup per transition. Add it to test 3: a dedicated project run passes running → waiting_approval → running → succeeded at level 1, and fails with no setting.

# B. Design corrections

- **B1. `stamp_project_from_run` will need re-migrating in 8.17.**
  - It forces `project_id := NULL` whenever `run_id IS NULL`, so 8.17's project board posts (written by members, no run) cannot be stamped without a `CREATE OR REPLACE`.
  - Write it now like `inbox_project_guard` (`0054:158-191`):
    - a non-worker that sets `project_id` gets 42501;
    - the worker may set it when `run_id IS NULL`;
    - when `run_id` is set, the project is derived, and a different explicit value gives 23514.
- **B2. The IM skip should not depend on `notice.project`.** The inbox guard already derives `project_id` from `run_id` (`0054:177-185`), but many callers will not set `Notice.project` (approvals, for example). Change `insert_inbox` to `RETURNING id, project_id` (`inbox.rs:113-136`). `notify` then skips IM when it is Some, and fills `PushTarget.project_id` from it.
- **B3. The project key should not be best-effort after commit.**
  - `project_vault(…, create=true)` fails for archived projects (`store/projects.rs:229-237`). An ACS Pod whose archive fails stays alive and retries after `archive_retry_after` (6 h, `control/src/lib.rs:151`).
  - Call `project_vault(db, kms, p, true)` before the accept or add transaction when any entry dedicates or adopts; a leftover key is harmless. Optionally let `insert_project_key` accept `status <> 'deleted'`.
- **B4. Simplify the D11 write gate.**
  - Keep only the `application_name` change in 8.16; move `legacy_sessions()` to 8.17, its only user.
  - Four deployments (api, worker, llm-gw, relay; `docs/release.md:93`) share `Db::connect` (`server/src/lib.rs:49`, `llm-gw/src/main.rs:331`, `relay/src/main.rs:104`). Have 8.17 count only server-login sessions, e.g. `AND usesysid = (SELECT oid FROM pg_roles WHERE rolname = session_user)`, so an old llm-gw or relay does not hold the gate.
- **B5. Tie the mixed-agent switch to the isolation level.** Make server config validation reject `[api] mixed_project_agents = true` while `store::ISOLATION_LEVEL < 2`; otherwise users can add agents that can never run.
- **B6. Accept's instance-count advisory lock.**
  - Build the key in Rust exactly like the tenant does: `format!("instances/{}", user)` (`instances.rs:259-262`).
  - Take it before the invite-row `FOR UPDATE` (`project_invites.rs:567-573`). D3 step 4 requires every advisory key before step 5; the plan says only "after the member-row lock".
  - The agent-count check `live + new.len()` (`project_invites.rs:618-626`) must include the Adopt entries.
- **B7. Orphan sweeper cost.** It runs every 15 s on every replica (`server/src/config.rs:861`) and scans every non-terminal project run, with no suitable partial index. Either add `CREATE INDEX CONCURRENTLY runs_project_live ON runs (id) WHERE project_id IS NOT NULL AND state NOT IN ('succeeded','failed','cancelled')`, or defer the sweeper (C1).
- **B8. `queue_urgent_run` (`runs.rs:606-710`) is not addressed.** The 8.15 plan listed it. State why it needs no change: private urgent messages cannot target dedicated instances (D4), and project runs never become holders on mixed instances. At level 2 it would cancel a waiting project holder.
- **B9. Small wording fix (V11).** "WITH CHECK is kept" is false for `egress_requests`: its policy has no WITH CHECK (`0034:42`), so the new USING also becomes the UPDATE check. Harmless, but correct the text.

# C. Over-engineering, or work that belongs later

1. **Orphan sweeper (D12) and test 13.** Every exit, archive, delete, withdraw and erase path cancels runs in the same transaction; the test has to build an orphan with raw SQL; 8.16 has no writer. Move to 8.17.
2. **Redundant checks.** The executor already enforces `allowed_tools` on every dispatch (`executor.rs:1898-1918`). `reveal` already requires `vault_list` (`executor.rs:2017`). Filtering `platform_tools` at `:839-852`, plus the start check, covers everything. These add nothing:
   - `ToolSet::call` refusal;
   - the `reveal` special case;
   - the `has_computer` gate;
   - `ShimLaunch.space` plus the `ExecConnector` check;
   - the `HandoffCopier` check (the start check runs before `h.copy`, `:824-829`);
   - `ArtifactTools::origin` check.

   Keep `ToolContext.project`, since 8.17 needs it.
3. **Unreachable before level 2:** the generic interrupt preface, `egress_run_same_space`, and the scheduler pause backstop.
4. **Space parameters on `instance_holder` / `last_finished_run`.** Their only caller, `peers.rs`, never runs in project runs (D14). Hardcode `project_id IS NULL`.
5. **The `finish_inner` reorder is not fixing a cycle.** `cancel_descendants` never touches approvals (`runs.rs:1151-1182`), and children cannot share the parent's instance. Optional.
6. **C12 / §3.4 shim test already exists.** `agent-shim/tests/shim.rs:206,457` assert `session_restored == false` on a fresh HOME. Drop C12.
7. **Content reports.** Drop the closed-report sweep at the top of the purge. Reports have no FK, so they never block the purge, and erase already deletes them (`users.rs:290`).

# D. Missing tests

- `update_team` on a team that has a dedicated member (A1).
- Dedicate or release racing tenant `delete_instance`: no 40P01, and the instance is not brought back (A2, A4).
- Retire racing `decide_egress_request(always)` (A3).
- A 8.15-style `begin_workspace_archive` with a `workspaces/<u>/` key on a dedicated instance gives 23514 (A7).
- Purge with a deleted, unpurged dedicated instance, plus more than 20 deleted projects (A8).
- Creator erase → members' dedicated instances are retired by the purge backstop (A9).
- The `transition_run` fence (A10).
- Gateway: `PUT /v1/teams/{id}` with a dedicated member, and old clients (8.15 FFI `instance_ids`) get 422, not 500.

# E. Claims checked and correct

- No code writes project runs today: `insert_run` (`runs.rs:288-317`) and `create_run_grant` (`grants.rs:160`) are the only inserts.
- The four 8.15 filters are at `runs.rs:1014,1135,1434,1567`.
- HOME is `.thinktin/home` inside the workspace (`exec.rs:115-118`).
- uid 1001 (`Dockerfile:36,130`); `ExecSpec` has no uid (`sandbox/lib.rs:115-121`); ACS has no volumes (`acs.rs:402-404,578-581`).
- In-flight archives and restores detect a retire (`control/src/lib.rs:1078-1083,1418-1428`; `instances.rs:852-858`).
- `queue_workspace_archive_purge` and `fill_space_from_run` are owned by the migration owner (`0049:169`, `0050:9`; no `OWNER TO`).
- `thinktin_app` has UPDATE on some `instances` columns (`0023:26-27`); `thinktin_llmgw` has only `SELECT (id, user_id, instance_id, kind, state)` on runs (`0034:49`).
- 23514/23503/42501 mapping (`error.rs:63-71`).
- Lock order of `decide_approval` (`approvals.rs:239-283`, `gateway/routes/approvals.rs:45-46`, `events.rs:47-52`).
- `pg_stat_activity.application_name` is readable by any role.
- The FKs on runs, plans, plan_steps and project_agents already take KEY SHARE on the instance, so the triggers' extra `FOR KEY SHARE` adds no contention but is needed for a consistent read (`0001:251`, `0002:67`, `0039:62`).
- Sharing `stamp_project_from_run` across the six tables is fine: all have `run_id` and `project_id`. V6 applies only to plans vs plan_steps.

# F. Scope note

WBS 8.16 (`wbs.md:219`) promises "每个（实例，项目）一个会话和工作区目录". Product §6 bullet 3 says "warn, then still allow" mixed agents. The plan delivers per-space isolation only for dedicated instances and ships the mixed path switched off. That matches impl `:12`, item 5 and "迁移与放量" 8.17-8.19, but record it in the WBS and progress notes. Otherwise a mixed agent that can never run a project task will look like a bug.