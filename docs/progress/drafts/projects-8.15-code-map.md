# 8.15 代码地图（workflow `projects-8-15-plan`，2026-11-05）

英文原样。

## Map: db-roles

Nothing in the repo was changed. To check the catalog directly, I applied migrations 0001–0048 as `thinktin_test_owner` to a scratch database on the local PostgreSQL 16.15, queried it, and dropped it afterwards. It needed one workaround: I pre-created a stand-in `_sqlx_migrations` table so 0016 could apply.

# 1. Roles

| Role | Attributes | Created at | Notes |
|---|---|---|---|
| `thinktin_app` | NOLOGIN NOBYPASSRLS | 0001:18 | Business API; RLS keyed on `app_user_id()`. |
| `thinktin_worker` | NOLOGIN BYPASSRLS | 0001:19 | All cross-user writes, background jobs, and 8.14's project reads. |
| `thinktin_llmgw` | NOLOGIN BYPASSRLS | 0001:20 | Narrow grants: 0001:485-486, 0009:63, 0032:52-53, 0034:46-49. Nothing on `project_*` (0039:226). |
| `thinktin_relay` | NOLOGIN BYPASSRLS | 0014:15 | Column grants (0014:84-92), including `runs (user_id, state, lease_owner, not_before)` with UPDATE on `(not_before, updated_at)` (0014:92). |

- **How roles get created.** Each migration checks the name first, then creates, and ignores `duplicate_object`/`unique_violation`. The migration owner has no CREATEROLE, so a role that doesn't already exist makes the migration fail (0001:8-10).
- **Production pre-creates them** with the high-privilege account: docs/deploy-checklist.md:57-64.
- **Logins** (deploy-checklist.md:66-71, release.md:73-78):
  - `thinktin_server_login` gets `thinktin_app, thinktin_worker`.
  - `thinktin_llmgw_login` gets `thinktin_llmgw`.
  - `thinktin_relay_login` gets `thinktin_relay`.
  - Logins INHERIT (release.md:81).
- **Migration owner:** `thinktin_owner` in production (deploy-checklist.md:57); `thinktin_test_owner` (LOGIN NOSUPERUSER NOCREATEROLE NOCREATEDB NOBYPASSRLS) in tests (testing.rs:95-97).
- **Trust model:** the login is a member of both app and worker. Switching role stops buggy queries, not arbitrary SQL: SQL inside a tenant transaction could run `SET ROLE thinktin_worker`. The boundary is the narrow store API.

# 2. `app_user_id()` (0001:22-25)

- Definition: `LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.user_id', true), '')::uuid $$`. It is not SECURITY DEFINER and has no `search_path`.
- If unset it returns NULL, so no policy matches.
- EXECUTE: explicitly granted to app, worker and llmgw (0001:466). PUBLIC also keeps EXECUTE (catalog shows `=X/`), so any new role can call it.
- `app.user_id` is an ordinary user-settable custom setting, so the database trusts whoever opens the transaction. "Setting another project id by hand reads nothing" therefore means policies must join live membership of `app_user_id()`. Trusting a project id the caller supplies (a parameter or an `app.project_id` setting) would break that rule.

# 3. How `Db` opens transactions (crates/store/src/lib.rs)

**Statement timeouts:** `TENANT_STATEMENT_TIMEOUT = "15s"` (lib.rs:93), `WORKER_STATEMENT_TIMEOUT = "60s"` (lib.rs:95).

**The four openers** each call `pool.begin()` and then one `SELECT set_config(..., true)`, which is transaction-local and equivalent to SET LOCAL ROLE:

| Method | Lines | Role | Also sets | Timeout |
|---|---|---|---|---|
| `tenant(user)` | 129-143 | `thinktin_app` | `app.user_id` | 15s |
| `worker()` | 146-155 | `thinktin_worker` | – | 60s |
| `llmgw()` | 158-167 | `thinktin_llmgw` | – | 15s |
| `relay()` | 171-180 | `thinktin_relay` | – | 15s |

- No `lock_timeout` or read-only setting anywhere, apart from hooks.rs:224/239.

**Types:**
- `Tx<R> { tx, role }` (lib.rs:184-187).
- Marker types: `Tenant { user }` (191-193), `Worker` (197), `Llmgw` (201), `Relay` (205).
- Trait gates: `Internal` (Worker, Llmgw; 207-210) gates `user_key` (users.rs:319-329), `sealed_credential` (credentials.rs:277) and `insert_usage` (usage.rs:35). `SessionCheck` (Worker, Relay; 213-215) gates sessions.rs:450.
- `Tx<Tenant>::user()` is at lib.rs:240-244.

**How a `Tx<Member>` / `ProjectTx` fits.** A `Db::member(user)` would follow the same pattern with `thinktin_member` plus `app.user_id`. It could be made read-only at the database level:
- either `pool.begin_with("BEGIN READ ONLY")` (sqlx 0.9 provides `Pool::begin_with`, sqlx-core pool/mod.rs:391),
- or `set_config('transaction_read_only','on',true)`.

I checked that a read-only transaction also refuses `CREATE TEMP TABLE`.

**Catch: generic `impl<R> Tx<R>` blocks would all apply to `Tx<Member>`**, including writes:
- `append_event` (events.rs:40); `events_after`/`event_range`/`recent_run_events` (events.rs:76/96/116)
- `insert_inbox` and the `settle_*` functions (inbox.rs:103-166)
- `revoke_run_grant`/`revoke_plan_grants`/`revoke_instance_grants` (grants.rs:179-212)
- `set_plan_paused`, `disable_trigger` and others (plans.rs:427-569)
- `run`/`run_tree` (runs.rs:321/330); artifact reads (artifacts.rs:161-274)
- `lock_project` (projects.rs:57-63) and `advisory_lock` (project_invites.rs:158-166)

Missing grants would refuse most of these, but `pg_advisory_xact_lock` is PUBLIC and allowed in a read-only transaction, so a member transaction could still take project locks. To keep "narrow queries" true at compile time, make `ProjectTx` a separate type, or bound the generic impls with a marker trait as `Internal`/`SessionCheck` do.

**Error mapping:**
- 42501 becomes `Error::Forbidden` (store/src/error.rs:69). The gateway's `other => Self::internal` (gateway/src/error.rs:93) turns that into 500. 8.14 plan §9 says 8.15 maps it to 404 on project paths.
- A read-only violation (25006) would become `Error::Db`, also 500.

**8.14's stand-in reads** (D9; they must keep the same JSON):
- `Tx<Worker>::my_projects` (projects.rs:260-269) filters `status='active'`.
- `project_detail` (projects.rs:272-351) filters `status <> 'deleted'`, so archived projects stay visible in the detail view.
- Both use `SUMMARY_SQL` (projects.rs:130-141).
- Callers: orchestrator/src/projects.rs:57-71, gateway routes/projects.rs:69.

**Rows those reads touch** — a member role needs all of these:
- `projects`, `project_members`, `project_agents`.
- `users.display_name` for the creator and every member.
- `instances (id, agent_id, name, state)` for other members' agents.
- The member's own budget columns, `project_members.daily_token_limit` / `total_token_limit` (projects.rs:332-339).

The invite preview's member list (project_invites.rs:668-713) is for non-members, so it cannot become a member read.

# 4. RLS, FORCE, policies and grants on project-relevant tables (all FORCE in the catalog)

Every existing policy is `TO thinktin_app`. Nothing exists for any other role.

| Table | Policy (thinktin_app) | App grants | Worker | Has project marker? |
|---|---|---|---|---|
| projects | `tenant_read` SELECT `creator_id=app_user_id()`; `tenant_insert`/`tenant_update`/`tenant_delete` require creator and `shared_at IS NULL` (0039:181-188) | SELECT, DELETE; INSERT(id, creator_id, name) + INSERT(goal); UPDATE(name, updated_at) (0039:214-216, 0047:79) | full (0039:224) | – |
| project_members | `tenant_read` own rows; `tenant_insert` creator row in own unshared project (0039:190-194) | SELECT; INSERT(project_id, user_id, role) (0039:217-218) | full | – |
| project_agents | `tenant_read` own agents; `tenant_insert`/`tenant_update` in own unshared project (0039:198-209) | SELECT; INSERT(5 columns); UPDATE(is_lead, position, left_at, added_at) (0039:219-221) | full | – |
| project_invites, project_keys | none (0039:212) | none | full (0039:224) | – |
| project_invite_sends, user_blocks | none | none | 0048:22, 0047:22 | – |
| runs | `tenant` ALL `user_id=app_user_id()` (0001:433-439) | SELECT, INSERT, UPDATE (0001:468) | full (0001:479) | `project_id`/`space_kind`/`space_id` (0040:29-30) |
| run_grants | `tenant` ALL (same) | SELECT, INSERT, UPDATE, DELETE (0001:470) | full | yes (0040:31-32) |
| events (partitioned) | `tenant` ALL | SELECT, INSERT (0001:472) | full | **no** |
| approvals | `tenant` ALL | SELECT, INSERT, UPDATE (0001:468) | full | **no** |
| tool_calls | `tenant` ALL (0012:15) | **none** | SELECT, INSERT, DELETE (0012:16) | **no** |
| artifacts | `tenant` ALL (0002:103) | SELECT, DELETE (0002:109) | full (0002:110) | **no**; blob encrypted with the user DEK (0002:72) |
| board_posts | `tenant` ALL (0025:35) | SELECT, INSERT, DELETE; UPDATE(archived_at, revived_at) (0025:38-39, 0028:9) | full | **no** (only `tags`, 0025:16-17) |
| inbox_items | `tenant` ALL | SELECT, INSERT, UPDATE, DELETE (0001:468, 471) | full | `project_id`, `project_invite_id` (0047:48) |
| instances | `tenant` ALL | column INSERT/UPDATE only (0023:24-27, 0024:9, 0032:9) | full | – |
| users | `self` ALL `id=app_user_id()` (0001:444) | SELECT, INSERT, UPDATE | full | – |
| user_keys | none | none | full | llmgw SELECT (0001:485) |

- **Exceptions to FORCE:** `blob_purge` is ENABLE without FORCE, on purpose, so its owner-run trigger can write (0007:36). `im_bot_slots` has no RLS (worker only).
- **Write guards on project rows:**
  - `fill_space` lets only `current_user = 'thinktin_worker'` write `project_id` on runs/run_grants (0040:19-22). 0040:3 says the 8.15 role gets 42501 too.
  - `inbox_project_guard` does the same for inbox project fields (0047:67-71).
  - Both freeze the space and project columns on UPDATE for everyone (0040:10-17, 0047:58-66).
- **Same-space foreign keys** (0045):
  - `runs_project_agent` is NO ACTION (0045:6-7). Deleting a project or agent must clear its runs first.
  - `run_grants_project_agent` is ON DELETE CASCADE (0045:8-9).
  - Parent run, parent grant and grant references must stay in the same space (0045:12-17); validated in 0046.
- **Project key:** `project_keys.project_id` is `ON DELETE CASCADE` from projects (0039:102). Deleting the row destroys the key (0039:99-100).

# 5. Functions and triggers (catalog)

| Function | SECURITY DEFINER | search_path | Owner | EXECUTE |
|---|---|---|---|---|
| app_user_id (0001:23) | no | none | migration owner | PUBLIC, app, worker, llmgw |
| ensure_event_partitions (0001:288) | yes | `public` | migration owner | worker only (0001:480-482) |
| drop_event_partitions_before (0001:304) | yes | `public` | migration owner | worker only |
| queue_artifact_blob_purge (0007:40), trigger `artifacts_blob_purge` AFTER DELETE (0007:47) | yes | `public` | migration owner | revoked from PUBLIC (0007:46) |
| queue_workspace_archive_purge (0023:32), trigger on instances (0023:59-61) | yes | `public` | migration owner | revoked from PUBLIC (0023:58) |
| fill_space (0040:7), triggers `runs_space`/`run_grants_space` (0040:41-44) | no | `pg_catalog, public, pg_temp` | migration owner | revoked (0040:27) |
| project_members_share (0039:159), AFTER INSERT WHEN role='member' (0039:166-167) | no | `pg_catalog, public, pg_temp` | migration owner | revoked (0039:165) |
| inbox_project_guard (0047:55), BEFORE INSERT/UPDATE OF (0047:75-76) | no | `pg_catalog, public, pg_temp` | migration owner | revoked (0047:74) |

**Today's definer functions are all owned by a LOGIN role** (the migration owner). None meets the 8.15 rule of a "restricted NOLOGIN NOBYPASSRLS" owner.

**Problem I reproduced in an existing trigger.** The older definer functions use `search_path = public`. PostgreSQL then searches `pg_temp` first for table names, and PUBLIC has TEMP on the database (the database has no ACL set). In a tenant transaction:
1. `CREATE TEMP TABLE blob_purge ...; GRANT ALL ON pg_temp.blob_purge TO PUBLIC;`
2. `DELETE FROM artifacts ...`

The purge trigger wrote to the temp table: the real `public.blob_purge` got 0 rows and the temp copy got 1. Without the GRANT, the DELETE fails with "permission denied for table blob_purge". New definer functions should use `SET search_path = pg_catalog, public, pg_temp` with schema-qualified names, as 0039 and later do, or `search_path = ''`.

**PostgreSQL behaviour that constrains 8.15** (checked on the scratch database):
- `ALTER FUNCTION ... OWNER TO X` run by the migration owner fails with "must be able to SET ROLE X". The owner needs membership in the new owner role, granted by the high-privilege account.
- A role that inherits `thinktin_app` picks up its grants and its `TO thinktin_app` policies (an inheriting role saw 1 project row). So `thinktin_member` must not be a member of `thinktin_app`.
- A fresh NOBYPASSRLS role gets "permission denied for table projects", so the role is deny-by-default with no grants.
- `CREATE OR REPLACE` keeps owner and ACL but replaces the `SET` clause, so it must repeat `SET search_path` (relevant to the planned `inbox_project_guard` rewrite).

# 6. Test harness (crates/store/src/testing.rs)

- The test pool connects as a superuser (`thinktin_dev`, testing.rs:12-13, 114-118). The role switch always works in tests, so they will not catch a missing `GRANT thinktin_member TO thinktin_server_login` in production.
- Migrations run through a one-connection pool as `thinktin_test_owner` (testing.rs:58-65, 107-123). The test database is created `OWNER thinktin_test_owner` (testing.rs:108).
- Cluster-wide roles are created under an advisory lock (testing.rs:81-106). New roles (member, definer owner) and the owner's membership in the definer owner have to be added here.
- Schema tests only look at `thinktin_app`:
  - `every_tenant_table_the_app_can_touch_has_rls` (tests.rs:765-829), including the `qual='true'` "allow everything" check at 795-802.
  - `migrations_run_as_a_plain_owner` (tests.rs:834-866).
  - FORCE restored after 0039 (tests.rs:1025-1040).
- They need versions for `thinktin_member` and for the definer owner: no BYPASSRLS, NOLOGIN, only policies scoped by membership, `prosecdef` functions with `proconfig` search_path and no PUBLIC EXECUTE. A blanket definer-function test would fail on the four existing functions owned by the migration owner. `ensure_event_partitions` must stay owner-owned because it runs DDL on `events`. `queue_artifact_blob_purge` relies on being the table owner of non-FORCE `blob_purge`.
- Role-switch pattern for tests: tests.rs:3718-3730; `cross_user_rows_are_worker_only` at tests/projects.rs:61.

# 7. Migration rules

- **Checker (tools/ci/check_migrations.py):**
  - Numbering must be consecutive (lines 312-321).
  - With no `v*` tag, only file names are checked (323-325). There are currently no `v*` tags.
  - After a tag, `REVOKE` on an object not created in the same file is an error unless the statement is preceded by `-- deploy-safe: <reason>` (213-216, 30, 187-188). `REVOKE ALL ON FUNCTION f() FROM PUBLIC` for a function created in the same file passes (self-test 373-374).
  - `DROP POLICY`, `CREATE POLICY`, `ALTER POLICY`, `ALTER FUNCTION … OWNER TO` and `CREATE OR REPLACE FUNCTION` are not flagged (370, 217-228, 162-175).
  - `SET NOT NULL` is flagged (240-241). `ADD COLUMN … NOT NULL` without DEFAULT is flagged (242-252). A constraint without `NOT VALID` on an existing table only warns (253-258). `CREATE INDEX` without CONCURRENTLY on an existing table only warns (260-269).
- **Policy rule (docs/release.md, §3):** tightening a constraint or revoking a privilege needs `deploy-safe` (release.md:44). This is not enforced for policies.
- **`-- no-transaction`:** sqlx checks `sql.starts_with("-- no-transaction")` (sqlx-core migrate/source.rs:234), so it must be the first bytes of the file. Use it for `CREATE INDEX CONCURRENTLY`, one statement per file (0041-0044; projects-impl "迁移与放量"; release.md:49-53). Only one migration process may run them (schema.rs:96-103).
- **FORCE and the owner:** under FORCE the owner sees 0 rows. Backfills, and `VALIDATE`/`ADD FOREIGN KEY` without `NOT VALID`, need `NO FORCE … FORCE` in the same transaction on both referencing and referenced tables (release.md:54-57; examples 0039:122-156, 0040:34-39, 0046:3-13).

# 8. What must change so a member reads exactly the project's rows

1. **Roles.** Pre-create `thinktin_member` (NOLOGIN NOBYPASSRLS) and a definer-owner role (NOLOGIN NOBYPASSRLS, not superuser) in deploy-checklist.md §3 and testing.rs:85-98, with the existence-check pattern in the migration.
   - `GRANT thinktin_member TO thinktin_server_login`.
   - `GRANT <definer owner> TO thinktin_owner` (and to `thinktin_test_owner`) so `ALTER FUNCTION … OWNER TO` works.
   - `thinktin_member` must not be in `thinktin_app` or `thinktin_worker`.
   - Grant it `USAGE ON SCHEMA public` and only SELECT (or column SELECT) on project tables, or EXECUTE on definer functions only.
2. **The tenant can't do the status check.** It cannot see `projects` rows of projects it joined (`tenant_read` is creator-only, 0039:181). A policy subquery on `projects.status` from a member's tenant transaction therefore returns nothing, so the "live membership + status" check needs a definer function such as `project_readable(project_id)`. That function's owner needs its own grants and `TO <owner>` policies, because RLS applies to a non-owner NOBYPASSRLS role. A definer function also breaks the recursion you would get if member policies on `projects` and `project_members` referenced each other.
3. **Cross-user display data.** `users.display_name` and other members' `instances (agent_id, name, state)` sit behind `self`/`tenant` policies. Expose them through definer functions that check co-membership, or through member policies with column grants, keeping `SUMMARY_SQL`'s output the same.
4. **Project marker columns.** `events`, `approvals`, `artifacts`, `tool_calls` and `board_posts` have no `project_id`/space columns (only runs, run_grants and inbox_items do).
   - Add them nullable, filled by trigger with the worker-only whitelist and frozen like `fill_space`.
   - `events` is partitioned, so new columns propagate to its partitions.
   - Artifacts also need project-DEK encryption via `project_keys`, which only the worker can reach.
5. **Narrow the tenant policies** on runs, run_grants, events, artifacts, inbox_items and board_posts to the private space (or live membership) via `ALTER POLICY` or drop-and-create. Today `tenant` lets an owner read and delete project rows on their own instance through private endpoints: `runs()`/`list_runs` (runs.rs:464/486), `events_after` (events.rs:76), `instance_artifacts`/`delete_artifact` (artifacts.rs:285/305). For inbox, exempt receipts by `subtype`, not by `run_id IS NULL` (0047:52-54); `run_id` is `ON DELETE SET NULL` (0001:381).
6. **Never give members** approvals, tool_calls, usage_records, credentials, model_routes, vault_*, devices/device_* or user_keys. Today they have no grants and no member policies; keep it that way.
7. **Deletion order.** One short worker transaction: set `projects.status = 'deleted'` and `DELETE FROM project_keys` (worker has DELETE, 0039:224). Then batch cleanup. Project runs must be cleared before `project_agents` rows go, because `runs_project_agent` is NO ACTION (0045:6-7). Every writer of `projects.status` takes `lock_project` (8.14 plan §9).

## Map: runs-events

# 8.15 code map: project/space columns, events, client cache, the private/member field split, and how board, asks and messages are scoped

All paths are relative to `/home/user/Thinktin-Rust`. Line numbers are for branch `claude/determined-lovelace-vn0j5h` (clean tree).

## Summary

- **Only `runs` and `run_grants` carry project/space columns after 0040–0046.** Events, approvals, tool_calls, artifacts and board_posts have no project column. `inbox_items.project_id` exists only for the 8.14 receipts.
- **Leaving does not hide anything today.** Tenant policies are `user_id = app_user_id()` only. An owner keeps reading their own project runs, events, approvals and artifacts through the old endpoints, and can even delete project artifacts.
- **Artifacts are sealed with the owner's DEK.** Erasing an account cascades away that owner's artifacts.
- **Three cross-space leaks** exist in today's code. Each becomes real once project runs execute:
  - Queued private messages get piggybacked into whatever run holds the instance.
  - The board tools are per user.
  - `agent_status` does not filter by space.
- **The member stream is the hard part.** It needs a new cursor (`project_seq`, in 8.19); for 8.15, per-run paging is enough. A whitelisted event projection is best built inside a SECURITY DEFINER function, so the member role never sees raw payloads.

## 1. Project and space columns after 0040–0048

**`runs` and `run_grants` only.**
- Columns: `project_id uuid`, `space_kind text NOT NULL DEFAULT 'private'`, `space_id uuid` (`crates/store/migrations/0040_run_spaces.sql:29-32`).
- `NOT NULL` and the CHECK `runs_space` / `run_grants_space`: private means `project_id IS NULL AND space_id = user_id`, project means `space_id = project_id` (`0040:46-54`).
- Backfill: `0040:34-39` (FORCE is lifted only for that step).

**`fill_space()` trigger** (`0040:7-27`):
- On UPDATE it raises `check_violation` if `project_id`, `user_id`, `instance_id`, `space_kind` or `space_id` changes (`:10-17`).
- On INSERT with `project_id` set and `current_user <> 'thinktin_worker'` it raises `42501` (`:19-22`). The whitelist is `thinktin_worker` only, so any new `thinktin_member` role, any definer-owner role and the tenant all get `42501`.
- It derives `space_kind` and `space_id` (`:23-24`).
- `PUBLIC` EXECUTE is revoked (`:27`). Triggers are registered at `:41-44`.

**Indexes:**
- Unique `runs_id_space (id, space_kind, space_id)`: `0041:3`.
- Unique `run_grants_id_space`: `0042:3`.
- `runs_project (project_id, instance_id, user_id) WHERE project_id IS NOT NULL`: `0043:3`.
- `run_grants_project`: `0044:3`.

**Same-space foreign keys** (`0045_run_space_keys.sql`; validated in `0046` with FORCE lifted on runs, run_grants and project_agents, `0046:3-13`):

| Constraint | Definition | Line |
|---|---|---|
| `runs_project_agent` | `(project_id, instance_id, user_id) → project_agents` | `:6-7` |

`runs_project_agent` is NO ACTION. So a project_agents row with project runs cannot be deleted, and a hard project delete must clear runs first.

| Constraint | Definition | Line |
|---|---|---|
| `run_grants_project_agent` | same columns, ON DELETE CASCADE | `:8-9` |
| `run_grants_parent_space` | `(parent_id, space_kind, space_id)` CASCADE | `:12-13` |
| `runs_parent_space` | `(parent_run_id, space_kind, space_id)` CASCADE | `:14-15` |
| `runs_grant_space` | `(run_grant_id, space_kind, space_id)` SET NULL `(run_grant_id)` | `:16-17` |

Consequence: a private child under a project parent fails with 23503, which `store/src/error.rs:67` maps to `Error::Invalid`. `insert_run` never sets `project_id` (`store/src/runs.rs:285-317`), so the ask and delegate children (worker `create_run`, `runs.rs:940-942`) are always private.

The old `(x, user_id)` foreign keys are still in place (`0001:251-255`; header note at `0040:3-4`).

**Columns not selected.** `runs.rs` `columns!()` (`:192-199`) does not select `project_id`, `space_kind` or `space_id`. So `RunRecord`, `Run` (`proto/src/domain.rs:923-947`) and `ToolContext` (`orchestrator/src/shim.rs:69-75`) do not carry the project.

**Claim guard.** Only private runs are picked up (`runs.rs:204-206` comment):
- `claim_next_run`: `r.project_id IS NULL` (`:967`); the urgent sub-checks also add `u.project_id IS NULL` (`:975`, `:996`).
- `take_over_expired`: `:1088`.
- `claim_expired_waits`: `:1387`.
- `due_pipelines`: `:1520`.
- Private grant lookups exclude project grants: `grants.rs:141`, `:353`.

**8.14 project-run teardown** (worker only):
- Cancel runs: `cancel_project_agent_runs` `runs.rs:858-897` and `cancel_project_member_runs` `:899-938`. Each locks runs, then bumps epochs, then cancels.
- Revoke grants recursively: `revoke_project_agent_grants` `grants.rs:234-253` and `revoke_project_member_grants` `:256-275`.
- Callers: `project_members.rs:279-283` and `:399-403`.
- None of these touch events, approvals, artifacts or inbox rows.

**`inbox_items.project_id` and `project_invite_id`** (`0047:48`):
- The `inbox_project_guard` trigger allows these columns to be written by the worker only and makes them immutable, along with `subtype` (`0047:55-76`).
- `0047:52-54` (and the 8.14 plan §9) say that 8.15 should derive `project_id` from `runs.project_id` inside that function. When the read policy is narrowed, receipts should be exempted by `subtype`, never by `run_id IS NULL`, because `run_id` is `ON DELETE SET NULL` (`0001:381`).

**Tables with no project or space column:**

| Table | Where defined | Keys | Tenant access |
|---|---|---|---|
| `events` | `0001:273-285` | PK `(instance_id, seq, created_at)`, partitioned by month; FKs `(instance_id, user_id)`, `(run_id, user_id)` CASCADE; index `events_run (run_id, seq)` | `SELECT, INSERT` (`0001:472`), policy `tenant` (`0001:429-440`) |
| `approvals` | `0001:325-347` | FK `(run_id, user_id)` CASCADE | `SELECT, INSERT, UPDATE` (`0001:468`) |
| `tool_calls` | `0012:3-16` | single-column `run_id REFERENCES runs (id)` CASCADE; `result jsonb` is the raw platform tool output | worker `SELECT, INSERT, DELETE` |
| `artifacts` | `0002:73-91` | FK `(run_id, user_id)` CASCADE (`:88`) | `SELECT, DELETE` (`0002:109`) |
| `board_posts` | `0025:6-40` | per user; `tags` is free text, "团队、项目标签" (`:16-17`) | tenant policy (`:35`); `SELECT, INSERT, DELETE` + `UPDATE (archived_at)` (`:38-39`), `UPDATE (revived_at)` (`0028:9`) |
| `usage_records` | `0001:388-409` | `instance_id`, `run_grant_id`, `credential_id`; no `run_id` | — |

Artifact blob cleanup runs through the trigger `artifacts_blob_purge` (`0007:40-48`).

**Roles.** `thinktin_worker` is BYPASSRLS (`0001:19`) and has every privilege on every table (`0001:479`; project tables `0039:224-225`). The tenant has no policy on `project_invites` or `project_keys` (`0039:212`). The tenant read on `projects` is creator-only (`0039:181`). The tenant read on `project_members` and `project_agents` is own rows only (`0039:190`, `:198`).

## 2. How events are written

**Shim protocol.**
- The shim numbers its own events: `EventEnvelope { seq, ts_ms, event }` (`proto/src/shim.rs:103`), emitted by `agent-shim/src/events.rs:26-33`.
- That shim seq is not stored.
- `ShimEvent` variants: `proto/src/shim.rs:116-216`. `ToolCall`, `ToolCallUpdate`, `Usage` and `AgentUpdate` carry `raw: Value` (`:155`, `:161`, `:168`, `:189`).
- `PermissionRequested` carries `title`, `options`, `tool_call` (`:171-177`).
- `PlatformToolCall` carries `name`, `arguments` (`:195-200`).
- `VaultReveal` carries `refs` (`:203-207`).

**Executor.**
- Stored kind is `agent.<variant>` (`orchestrator/src/shim.rs:122-142`).
- The payload is the whole tagged ShimEvent (`serde_json::to_value(ev)`, `executor.rs:1295-1302`). `PermissionRequested` and `PermissionResolved` also get `attempt`, `approval_id`, `approval_state` (`:1304-1316`).
- `persist_with` scrubs vault values, then bounds the payload (`:1246-1275`). `bound_payload` caps strings at 16 KiB and payloads at 256 KiB, keeping a stub with ids (`:348-350`, `:376-410`).
- Total log size per run is capped by `max_run_log_bytes` (64 MiB, `:87`); when the cap is hit it writes `run.log_truncated`.
- `write_event` opens one worker transaction per event (`:1277-1289`).
- Message and thought chunks are buffered and flushed as `agent.message` / `agent.thought` (`:1319-1336`). The flush happens at 4096 bytes or on the flush tick (`:1816-1834`).
- `run.state` events are written from `finish` (`:1175-1187`), `transition` (`:1355-1360`) and `expire_asks` (`:631-636`).

**Store** (`store/src/events.rs`):
- `append_event` (`:40-73`): `UPDATE instances SET event_seq = event_seq + 1 … RETURNING` (`:47-52`). That is a per-instance hot row lock held until commit; the counter is `instances.event_seq`, `0001:131`.
- Then `INSERT` (`:53-65`), then `pg_notify('thinktin_events', <instance id>)` (`:67-71`; channel constant `:11`).
- It is generic `impl<R> Tx<R>` (`:37`), so tenant code can append too.

**Every other writer, with payload fields:**

| Kind | Writer | Payload | Role |
|---|---|---|---|
| `plan.needs_confirmation` | `orchestrator/src/tools.rs:188` | plan_id, title, change | — |
| `plan.cancelled` | `tools.rs:317` | plan_id, title | — |
| `vault.requested` | `orchestrator/src/vault.rs:168` | request_id, name, purpose, fields | — |
| `vault.used` | `executor.rs:2092` | names | — |
| `artifact.published` | `orchestrator/src/artifacts.rs:319` | artifact_id, name, version, size | — |
| `run.state` | `pipeline.rs:122`, `:322` | state, steps / reason | — |
| `pipeline.step_started` | `pipeline.rs:264` | step, run_id, instance_id | — |
| `board.posted` | `orchestrator/src/board.rs:109` | post_id, tags | tenant |
| `ask.sent` | `orchestrator/src/ask.rs:161` | child_run_id, instance_id, to, question (first line, 80 chars) | — |
| `delegate.started` | `delegate.rs:174` | child_run_id, instance_id, to, title | — |
| `approval.decided` | `gateway/src/routes/approvals.rs:46` | approval_id, state, option_id, request_id, attempt | tenant |
| `vault.fulfilled` / `vault.declined` | `gateway/src/routes/vault.rs:388`, `:449` | — | — |
| `run.state` | `gateway/src/routes/runs.rs:51`, `:201`, `:212`; `instances.rs:155` | — | tenant |
| `hook.received` | `gateway/src/routes/hooks.rs:327` | hook_id, bytes, content_type | — |
| `instance.state` (run_id NULL) | `control/src/lib.rs:278`, `:1253`, `:1274` | — | — |

## 3. How events are read

**Store:**
- `events_after(instance, after, limit)`: `events.rs:76-92`.
- `event_range`: `:96-110`. It returns `(min seq, instances.event_seq)`.
- `recent_run_events(run, kinds, limit)` via `events_run`: `:116-134`.
- `run_event_count`: `runs.rs:771-781`.
- All are generic over the role; under the tenant, row-level security decides what is visible.

**Gateway routes** (`gateway/src/routes/mod.rs:243-244`), in `gateway/src/routes/events.rs`:

*Page endpoint* (`page`, `:56-74`):
- One tenant transaction.
- `t.instance(id)` (owner only), then `event_range`, then `events_after`.
- Returns `{events, oldest_seq, latest_seq}`.

*WebSocket endpoint* (`stream`, `:82-107`):
- Authenticates once and checks `t.instance(id)` under the tenant (`:95-97`).
- Uses the per-user stream slot (`:99`).

*WebSocket loop* (`run_stream`, `:127-218`):
- Subscribes with `hub.subscribe(instance)` (`:135`).
- Sends a `reset` when the cursor is older than retention (`:139-160`).
- Pages each fetch in a new tenant transaction (`fetch`, `:42-53`). So the database rechecks on every page, but the socket stays open.
- On heartbeat it only re-runs `auth.authenticate` (`:194-205`). Membership is not rechecked.
- Each frame is `InstanceEvent` plus `"type": "event"`, which exposes the per-instance `seq` (`:174-181`).

**`EventHub`** (`gateway/src/hub.rs`):
- A map from instance id to a broadcast sender (`:16-31`).
- `PgListener` on `store::EVENTS_CHANNEL`; the payload is parsed as an `InstanceId` (`:63`, `:80-84`); `notify_all` runs on reconnect.
- Wakeups are per instance and carry no space. A member subscribed to another owner's instance would be woken by that owner's private activity, which is a timing side channel even if fetches filter rows.

## 4. client-core local cache

**Schema** (SQLite, `crates/client-core/src/cache.rs:23-39`):
- `runs (id, instance_id, json)`.
- `cursors (instance_id, last_seq)`.
- `events (instance_id, seq, json)` with PK `(instance_id, seq)`.
- Instances and inbox tables.
- There is no project dimension and no project tables. `projects()` and `project()` FFI are not cached (`ffi.rs:3041-3057`).

**Lifecycle:**
- The cache is bound to one user: `bind_user` wipes everything on a user change (`cache.rs:88-108`).
- `clear()` runs only on sign-out, erase or revoke (`:110-122`).
- `leave_project` FFI (`ffi.rs:3142-3146`) only calls the API. Nothing purges project events or runs.

**Writes:**
- `put_runs` upserts by id under `instance_id` (`cache.rs:156-172`).
- Callers: `client.rs:111-145` (`runs`, `older_runs`, `list_runs`).
- `put_events` keeps 2000 per instance (`cache.rs:205-236`; constant `:19`).
- The stream writes to the cache before the sink (`events.rs:375`, `:387`; cursor from cache `:181`).

So any client subscribed to its own instance stores that instance's project-run events in the private, per-instance cache. This is the "old client must not save project events to the private cache" condition (`projects-impl.md:29`). Lenient decoding of runs and items: `client-core/src/lenient.rs:1-26`.

## 5. Scoping of board (8.10), asks (8.11), messages (8.12), peers and delegation today

**Board.**
- One board per user. Store reads and writes use the tenant with `app_user_id()` (`store/src/board.rs:122-243`, e.g. `:133`, `:143`, `:169`, `:176`).
- The tools open a tenant transaction as `ctx.user`: `orchestrator/src/board.rs:94`. Vault values are scrubbed with the owner's scrubber (`:88-89`).
- The gateway routes are tenant-only (`gateway/src/routes/board.rs:42`, `:74`, `:110`, `:122`).
- No space filter. A project run calling `board_read` or `board_post` would read and write the owner's private board.

**Asks.**
- Targets come from tenant `peers(ctx.instance)`: own non-deleted instances with `peer_access` (`orchestrator/src/ask.rs:65-77`; `store/src/instances.rs:543-569`, where RLS supplies the user filter).
- The child is a private worker run (`ask.rs:144-160`), so `runs_parent_space` rejects it under a project parent.
- Wait lock is per user: `lock_run_waits(ctx.user)` (`ask.rs:84`).

**Delegation.** Targets come from `delegation_targets` (`instances.rs:572-583`): same user, live agent rows, in projects where the lead is `is_lead`, `p.creator_id = app_user_id()` and `p.status = 'active'`.

**Peers and `agent_status`.**
- The tool reads with the tenant: `instance_holder` (`runs.rs:734-746`), `last_finished_run` (`:748-759`), `recent_run_events` over plan, tool_call and message (`orchestrator/src/peers.rs:93-111`), and `run_artifacts` (`:112`).
- No space filter. A private agent would see a same-owner instance's project run, and the reverse.

**Messages.**
- `queue_urgent_run` locks and interrupts the instance holder regardless of space (`runs.rs:606-710`, query `:627-635`).
- `unannounced_messages` (`runs.rs:1285-1302`) has no `project_id` filter. The executor piggybacks queued private user prompts (truncated `r.prompt`) into whatever run holds the instance (`executor.rs:1506-1529`). That is a private-to-project leak once project runs execute.
- `claim_next_run`'s urgent gate is already private-only (`runs.rs:975`, `:996`).

## 6. Artifacts and keys

**Sealing.** `ArtifactStore::publish` seals with the owner's DEK: `user_vault(origin.user)` then `seal_bytes(user_id, artifact_id)` (`orchestrator/src/artifacts.rs:280-339`). The blob key is `{user}/{artifact}` (`:300`). The origin comes from `ctx.user` (`orchestrator/src/tools.rs:480-506`).

**Reading.** `read` opens with `a.user_id`'s DEK (`artifacts.rs:341-347`). `user_vault` re-reads `user_keys` through the worker on every call (`:159-212`).

**KMS cache.** `CachingKms` caches unwrapped DEKs keyed by the wrapped ciphertext and context (`keyvault/src/lib.rs:195-240`; server TTL from `cfg.kms.cache_secs`, `server/src/lib.rs:203-206`).

**Inference: deleting a project key works at once.** Deleting a `project_keys` row makes the content undecryptable straight away, as long as the read path re-fetches the wrapped key each time. Nothing can find the cached entry without that row.

**AAD and context:**
- `blob_aad` is `thinktin/blob/v1/` + id + object (`keyvault/lib.rs:768-770`).
- The KMS context string is "user id" (`:62-68`; local AAD `:121`, `:136`).
- A project DEK would reuse `MemoryKeyStore` keyed by a string. Prefix the context, e.g. `project:<id>`, for domain separation.

**`project_keys` table** (`0039:101-106`): worker only, `ON DELETE CASCADE` from projects; "deleting the row destroys the key". The table exists, but no code writes or reads it yet.

**Scope.** `artifact_scope`, `tree_artifacts` and `named_artifact` are run-tree and ask scoped, not space scoped (`store/src/artifacts.rs:179-264`). The tenant has `instance_artifacts` and `delete_artifact` (`:283-312`) and routes `gateway/src/routes/artifacts.rs:28-62`, `:64-74`, `:95-135`, `:137`. So the owner can list, download and delete their agent's project artifacts after leaving. The tenant `DELETE` grant is at `0002:109`.

**Erase** (`store/src/users.rs:183-230`):
- `DELETE FROM runs WHERE user_id` (`:220` area) cascades artifacts, approvals and events through `(run_id, user_id)`.
- `runs_parent_space` CASCADE would also delete other owners' child runs.
- This conflicts with projects.md §4.5 / §10 and impl item 7 (keep records other owners still need).

## 7. Private vs member-safe fields (proposed whitelist; product rules in `projects-impl.md:13`, `:21`, `:23`)

### Run (`proto/src/domain.rs:923-947`; `RunRecord` extras `runs.rs:239-262`)

| Class | Fields |
|---|---|
| Safe | `id`, `kind`, `instance_id` (project agents are already listed in `ProjectAgentView`), owner as `owner_id`, `parent_run_id`, `root_run_id`, `step_key`, `source`, coarse `state` (`waiting_approval`, `waiting_quota`, `waiting_device` collapse to "waiting for owner"), `created_at`, `started_at`, `finished_at`, `summary` (vault-scrubbed, `executor.rs:1974-1977`) |
| Product decision | `prompt` (project task text; for `ask` it embeds the asker's name and question via `texts::ask_question`) |
| Private | `state_reason` and `error` (failure reasons, e.g. key or budget timeouts, `executor.rs:589-593`), `wait_code` (`invalid`, `no_balance` and so on reveal the owner's key or billing state; `domain.rs:950-974`), `tokens_used`, `attempt`, `plan_id` (until project plans exist, 8.17) |
| Private (internal) | `trigger_id`, `fire_time`, `agent_version`, `run_grant_id`, `budget`, `max_attempts`, `steps`, `lease_*`, `interrupts_run_id`, `announced_at`, `urgent`, `answer_deadline`, `hook_id` |

### Event kinds

**Member DTO:**

| Kind | Fields kept |
|---|---|
| `agent.tool_call` | `tool_call_id`, `kind`, `status` (`title` is a decision: it can contain paths or commands) |
| `agent.tool_call_update` | `tool_call_id`, `status` |
| `agent.turn_started` | marker only |
| `agent.turn_ended` | `stop_reason` |
| `run.state` | `state` only, coarsened as above |
| `run.log_truncated` | — |
| `artifact.published` | full payload, but only once project artifacts live in project space |
| `pipeline.step_started` | `step`, `run_id`, `instance_id` |
| `delegate.started` / `ask.sent` | when the target is in the project |

**Product decision:** `agent.message` text and `agent.plan` entries. These are project content; the impl only forbids raw args/output, thinking, private approvals and instance seq.

**Private, drop:**
- `agent.thought` (thinking).
- Every `raw` payload.
- `agent.usage` (costs and context).
- `agent.permission_requested` and `agent.permission_resolved` (approval text and options; members see only "waiting for owner").
- `agent.platform_tool_call` (raw `arguments`; at most `name`).
- `agent.vault_reveal` and all `vault.*`.
- `agent.update`.
- `agent.error` (free text).
- `agent.ready`, `agent.session_lost` (session ids, harness info).
- `agent.exited`.
- `approval.decided`.
- `plan.*`.
- `hook.received`.
- `board.posted` (private board until 8.17).
- `instance.state`.
- `seq` itself: the per-instance counter exposes gaps (impl item 6).

**Other private data:** approvals rows (`domain.rs:976-998`: `title`, `options`, `tool_call`), `tool_calls.result`, `usage_records`, credentials, routes, vault and computer data.

**Existing precedent for whitelisting event payloads:**
- `peers.rs` `brief()` `:188` and `task()` `:176`.
- `executor.rs` `resume_brief` `:295-320` (tool titles plus the last 300 chars of messages).

## 8. What "project runs readable by members" requires (each item traced to the code above)

**1. Space columns on the dependent tables.**
- Add `project_id`, `space_kind`, `space_id` to `events`, `approvals`, `artifacts`, `tool_calls`, and `inbox_items` (where not already set).
- Derive them by trigger from `runs` (extend `fill_space` or add a "derive from run" function).
- Add same-space foreign keys `(run_id, space_kind, space_id) → runs_id_space` (`0041`), keeping the old `(run_id, user_id)` foreign keys (impl item 1).
- `events` is partitioned (`0001:284`). New columns propagate to future partitions from `ensure_event_partitions` (`0001:288-301`).
- `events` with `run_id` NULL stay private.

**2. Narrower tenant policies.**
- Today's `tenant` policies on runs, events, approvals and artifacts (`0001:429-440`, `0002:95-105`) must also require `project_id IS NULL OR <live member AND project readable>`.
- Without this, leaving is bypassed by the endpoints `GET /v1/runs`, `/v1/instances/{id}/runs`, `/v1/runs/{id}`, `/v1/runs/{id}/tree` (`gateway/src/routes/runs.rs:99-258`), `/v1/instances/{id}/events{,/ws}`, and `/v1/instances/{id}/artifacts`, `/v1/runs/{id}/artifacts`, `/v1/artifacts/{id}{,/content}`.
- Decide whether the tenant instance stream excludes project events outright. That is the safe choice for old clients that cache per instance and never purge (section 4).

**3. `thinktin_member` and the definer-owner role.**
- Both are new roles. The migration owner has no CREATEROLE: follow the pattern in `0001:18-20` / `0014:15` and pre-create them in `docs/deploy-checklist.md:57-71`.
- Add them to the test role bootstrap (`store/src/testing.rs:85-98`).
- The definer owner must be NOLOGIN NOBYPASSRLS. Because FORCE applies only to table owners, a NOBYPASSRLS non-owner needs its own policies keyed on `app_user_id()` plus a live member row (`project_members.left_at IS NULL`) and `projects.status`.
- Existing definer functions use `SET search_path = public` (`0001:289`, `:305`). New ones should use `pg_catalog, public, pg_temp`, as `0040:8` and `0047:56` do, with `REVOKE … FROM PUBLIC` and a GRANT to `thinktin_member` only.
- Extend `every_tenant_table_the_app_can_touch_has_rls` (`store/src/tests.rs:765-805`) to cover the new roles: no permissive policies, no bypass.

**4. Rust side (`store/src/lib.rs`).**
- Add `Db::member` and a role struct next to `Tenant`/`Worker` (`:128-205`).
- Caveat: generic `impl<R> Tx<R>` blocks would make every raw query callable on a member transaction. They are at `events.rs:37`, `:113`; `runs.rs:269`, `:368`, `:428`; `artifacts.rs:160`, `:266`; `inbox.rs:100`; `grants.rs:177`; `plans.rs:422`; `project_invites.rs:158`; `projects.rs:57`; `users.rs:308`; `device_relay.rs:107`; `im_channels.rs:281`.
- If the member role has no table grants these calls fail with 42501, which maps to `Error::Forbidden` (`error.rs:69`) and today becomes a 500 (`gateway/src/error.rs:66-95`).
- So `ProjectTx` should be a separate type exposing only the narrow calls. The 8.14 plan §9 asks for 42501 to be mapped to 404 on project paths.

**5. D9 swap without JSON changes.**
- `my_projects` filters `status = 'active'`; `project_detail` filters `status <> 'deleted'`, so archived projects are readable in detail but not listed.
- `SUMMARY_SQL` counts exclude deleted instances (`projects.rs:126-140`, `:260-352`). Members are ordered creator first, then `joined_at`, then `user_id`; agents are live only with `mine`, ordered by `position, instance_id`.
- `my_budget` comes from the caller's own row only; `limits` is `ProjectLimits::default()`.
- Shapes: `proto/src/domain.rs:1026-1110`.
- Callers: `orchestrator/src/projects.rs:57-70` (worker transactions), `gateway/src/routes/projects.rs:68-71`, `:112-119`.
- The invite preview member list is `project_invites.rs:668-700`.

**6. Where to build the member DTO.**
- Proto: new `ProjectRun` / `ProjectRunEvent` types next to `ProjectDetail` (`domain.rs:1100`), leaving `Run` and `InstanceEvent` untouched for old clients.
- Projection: preferably inside the definer function itself (`jsonb_build_object` per kind via `CASE`), so raw `payload` never reaches the member role. Second best is a Rust mapper in a new store module behind `ProjectTx`.
- Paging: per run via `events_run`, with a cursor that is not the instance seq (for example a per-run ordinal or `(created_at, seq)` kept opaque). The live member feed with `project_seq` and an outbox-based sequencer is 8.19 (impl item 6; 8.14 plan §9).
- Gateway: new routes under `/v1/projects/{id}/…`, each opening its own member transaction so membership is re-checked by the database on every page.

**7. Project artifacts.**
- Store `project_id` on the row and seal with a DEK created by the worker in `project_keys`. Do not cascade from the owner's runs or erase.
- Drop the tenant `DELETE` grant for project rows.
- Deletion: a short transaction sets the status, deletes `project_keys` and revokes. Then bounded, retryable batches clean up blobs through `blob_purge` (`0007:32-48`). A blob-key prefix per project would help.

**8. Leaks to close before 8.16 lifts the claim guard.** Space-filter `unannounced_messages` (`runs.rs:1285`), `peers`/`agent_status` (`peers.rs:93-111`), and the board tools (`orchestrator/src/board.rs:94`). The artifact `origin` uses `ctx.user` (`tools.rs:497`); `ToolContext` needs the run's space.

## Map: keys-artifacts

# 8.15 research: keyvault (9.1), artifact service (8.4) and `project_keys`

Nothing was modified. Branch `claude/determined-lovelace-vn0j5h`, HEAD `995819c`.

## A. Keyvault and envelope encryption (9.1), as it is now

**Primitives** (`crates/keyvault/src/lib.rs`)
- Each user has one 256-bit DEK, wrapped by a KMS master key.
- Data is sealed with AES-256-GCM. A 12-byte random nonce goes first, then the ciphertext (`seal_raw` 797-808, `open_raw` 810-821).
- Every AAD is a domain prefix plus a length-prefixed `user_id` and `object_id` (`domain_aad` 777-784). The domains are:
  - `thinktin/secret/v1/` (786-795)
  - `thinktin/blob/v1/`, used for artifacts (768-770)
  - `thinktin/vault/v1/` (772-774)
  - `thinktin/im/v1/` (595-623)
  - `thinktin/workspace/v1/`, chunked (625-640, 672-765)

**`Kms` trait** (63-70)
- Methods: `current_key_id()`, `wrap(dek, context)`, `unwrap(wrapped, context)`.
- `context` is a plain string, documented as "the user id" (62).

**Adapters**
- `LocalKms` (91-145), dev and test only:
  - wraps with AES-GCM, AAD `thinktin/dek/{key_id}/{context}` (121, 136);
  - refuses a wrapped key whose `kms_key_id` does not match its own.
- `AliyunKms` (`crates/aliyun/src/kms.rs:21-122`):
  - uses Encrypt/Decrypt, API version 2016-01-20;
  - stored key id is `aliyun:<KeyId>` (31-33);
  - EncryptionContext is `{"purpose":"thinktin-dek","user":<context>}` (39-41);
  - stores the CiphertextBlob string as bytes (77-81);
  - `Rejected*` / `*Ciphertext*` errors map to `Decrypt`; anything else maps to `Kms`, which can be retried (44-51).
- `KmsRing` (147-191) wraps with the current master key and unwraps with whichever ring member has the stored `kms_key_id`. This handles master-key rotation and the move from local to aliyun.
  - Aliyun aliases also allow key-version rotation without a config change (`server/src/config.rs:672-676`).
  - **There is no DEK rotation or re-wrap job anywhere.** Grep for re-wrapping or `UPDATE user_keys` found nothing.
- `CachingKms` (193-268) caches unwrapped DEKs:
  - keyed by SHA-256 of (`kms_key_id`, `context`, ciphertext) (212-225);
  - expired entries are swept on a miss (255), and the whole cache is cleared at 10,000 entries (257);
  - there is no way to evict an entry.

**`KeyStore`, `MemoryKeyStore`, `KeyVault`**
- `KeyStore` (370-377) is keyed by `user_id: &str`. `MemoryKeyStore` is at 441-461. There is no Postgres `KeyStore`: callers copy the wrapped key into a `MemoryKeyStore`.
- `KeyVault` (470-670) has its own DEK cache keyed by user id, default 300 s (483).
  - `create_user_key` (496-505): random DEK, wrapped with context = user id; `insert_new` never overwrites.
  - `destroy_user_key` (507-511).
  - `dek()` (642-670): cache, then `store.get`, then `kms.unwrap(wrapped, user_id)`, else `NoUserKey`.
- `SecretOpener::forget_user` is at 411-412 and 435-437.

**`user_keys` table** (`0001_init.sql:87-94`)
- Columns: `user_id` (PK, FK to users ON DELETE CASCADE), `kms_key_id`, `wrapped_dek`, `created_at`.
- RLS is ENABLE + FORCE with no policy (451-456).
- Worker has all rights via the ON ALL TABLES grant (481). `thinktin_llmgw` has SELECT (485).
- Store methods:
  - `Tx<Worker>::insert_user_key` (`store/src/users.rs:161-175`) is a plain INSERT with no `users.status` check, so a late `create=true` after erase can mint a new DEK.
  - `user_key()` is on `R: Internal`, i.e. Worker and Llmgw (`users.rs:319-329`, `lib.rs:197-200`).

**How a DEK gets created**
- Lazily, by `orchestrator::artifacts::user_vault(db, kms, user, create)` (`orchestrator/src/artifacts.rs:158-211`):
  1. A worker transaction reads `user_keys`.
  2. If there is none and `create` is set, it generates and wraps a DEK. **The KMS call happens while that worker transaction is open** (177, 185-186).
  3. It INSERTs. A 23505 becomes `Conflict` (`store/src/error.rs:65`), and it then re-reads in a new transaction and uses the winner (199-208).
- Each call returns a fresh `KeyVault` + `MemoryKeyStore`, so caching across calls happens only in `CachingKms`.
- Callers with `create=true`:
  - `ArtifactStore::publish` (`artifacts.rs:296`)
  - workspace put (`workspaces.rs:239`)
  - `gateway/routes/credentials.rs:26`
  - `vault.rs:91`
  - `im_channels.rs:91`
- Callers with `create=false`:
  - `ArtifactStore::read` (343)
  - `workspaces.rs:310`
  - `executor.rs:2052`
  - `orchestrator/vault.rs:272`
  - `outbox.rs:680`

**Where KMS lives**
- Server `kms()` (`server/src/lib.rs:172-210`):
  - `local` gives a bare `LocalKms` with no caching (209);
  - `aliyun` gives `CachingKms(KmsRing(Aliyun).with_older(local))` with `cache_secs`, default 300 (`config.rs:651, 661`).
- The api and worker processes each build their own instance (`server/src/api.rs:54-55`; `workers.rs:98-99, 146`). Both read keys through DB role `thinktin_worker`.
- The comment on gateway `Inner.kms` ("decryption only happens in llm-gw", `gateway/src/lib.rs:69-70`) is out of date: the gateway decrypts artifacts (`routes/artifacts.rs:105`) and vault items (`routes/vault.rs:100-113`).
- llm-gw:
  - builds its own `CachingKms`, fixed at 300 s (`llm-gw/src/main.rs:363-369`);
  - `PgDirectory` fills a shared `Arc<MemoryKeyStore>` from `tx.user_key` under `thinktin_llmgw` (`pg.rs:138, 201`); `remember_user_key` replaces the entry or drops it when the row is gone (171-189);
  - `KeyVault::new(kms, keys)` (`main.rs:382`) adds the 300 s per-user DEK cache.

**Destroy on erase**
- `erase_account` (`users.rs:183-284`) runs `DELETE FROM user_keys` (212) in its worker transaction.
- In the same transaction it:
  - blanks `credentials.sealed` (213-215);
  - deletes runs (218), which cascades to artifacts and so into `blob_purge`;
  - runs `DELETE FROM projects WHERE creator_id` (248), which cascades to `project_keys`.
- `destroy_user_key` and `forget_user` have **no callers** outside the keyvault crate.
  - llm-gw's `KeyVault` cache can hold an erased user's DEK for up to 300 s.
  - `CachingKms` entries stay until their TTL, but cannot be reached without the wrapped bytes.

## B. Artifact service (8.4), as it is now

**Table `artifacts`** (`0002_collaboration.sql:71-91`)
- Columns: `id`, `user_id`, `instance_id`, `run_id`, `root_run_id`, `name` (1-200 chars), `version`, `content_type`, `size`, `sha256`, `blob_key`, `created_at`.
- `UNIQUE (root_run_id, name, version)` (86).
- FK `(instance_id, user_id)` to instances CASCADE; FK `(run_id, user_id)` to runs ON DELETE CASCADE (88).
- Indexes: `artifacts_tree`, `artifacts_instance`, and `artifacts_run` (`0007:26`).
- Tenant policy `user_id = app_user_id()` (103). App has SELECT and DELETE (109); worker has all (110).
- No other migration touches this table, and it has **no project or space column**.

**`blob_purge`** (`0007:32-48`)
- RLS is enabled but not forced (36). Worker has SELECT, UPDATE, DELETE.
- An AFTER DELETE trigger calls `queue_artifact_blob_purge`: SECURITY DEFINER, owned by the migration account, `SET search_path = public`.
- Workspace archives use their own purge trigger (`0023:29-55`).

**Store API** (`store/src/artifacts.rs`)
- Types and limits:
  - `StoredArtifact {artifact, user_id, blob_key}` (25-31)
  - `NewArtifact` (65-78)
  - `MAX_TREE_ARTIFACTS` = 1000 (81), `MAX_LISTED_ARTIFACTS` = 500 (83)
  - `ArtifactScope` (87-96) is the 8.11 ask/tree scope, not projects.
- Worker:
  - `blob_purge_batch` uses `FOR UPDATE SKIP LOCKED` (99-107); `forget_blob_purge` (109-116).
  - `insert_artifact` (118-156): advisory lock `artifact:{root}:{name}`, the tree cap, version = max + 1.
- Generic `Tx<R>`:
  - `artifact(id)` (161-171)
  - `artifact_scope` (173-200)
  - `tree_artifacts` (202-226)
  - `named_artifact` (228-250)
  - `scoped_artifact` (252-263)
  - `run_artifacts` (266-281)
- Tenant: `instance_artifacts` (284-302); `delete_artifact`, which returns the `blob_key` (304-312).

**`ArtifactStore` and blob stores** (`orchestrator/src/artifacts.rs`)
- Limit: 20 MiB per artifact (16).
- `BlobStore` trait (30-55).
  - `LocalBlobStore` (64-156) validates key characters (76-92) and writes a temp file then renames.
  - `S3BlobStore` (`s3.rs`) covers AWS, OSS, COS and MinIO through the S3 API with SigV4. Its `delete` is a plain DELETE with no versionId and treats 200, 204 and 404 as success (236-242).
- `check_name` (213-229), `check_content_type` (231-257).
- `publish` (279-338):
  1. `user_vault(create=true)`;
  2. `seal_bytes(user, artifact_id)`;
  3. blob key `{user}/{artifact}` (300);
  4. `put` (301);
  5. a separate worker transaction runs `insert_artifact` and appends the `artifact.published` event (303-329);
  6. if the index write fails, it deletes the blob (330-336).
- `read` (340-347): `get`, then `user_vault(create=false)` and `open_bytes(a.user_id, id)`. `delete_blob` (349-351).
- Server wiring:
  - `blob_store` picks s3 or local (`server/src/lib.rs:212-233`);
  - one `ArtifactStore` is shared by api and workers (235-238);
  - `purge_blobs` (`workers.rs:436-454`) handles up to 1000 keys per tick, retries failures, and holds one transaction across the object-store calls.

**`thinktin.artifacts` tools** (`orchestrator/src/tools.rs:443-735`)
- Tools: publish, list, read, fetch (445-450). `artifact_publish` is a side-effect tool (`executor.rs:283-291`).
- `origin()` gets the scope from worker `artifact_scope(ctx.run)` and uses `ctx.user` as the owner (486-506).
- `ToolContext` is `{user, instance, run, plan, grant}`, with no project (`shim.rs:69-75`).
- `publish` (511-559); `list` (561-581); `find` (583-624); `read`, inline up to 64 KiB (626-642); `fetch` writes `handoff/<name>` into the workspace (644-666).
- Other readers:
  - pipeline handoff (`pipeline.rs:246-249` and 461-474);
  - `peers.rs:116`, a tenant `run_artifacts` call.

**Gateway** (`gateway/src/routes/artifacts.rs`; routes registered in `mod.rs:223-229`)
- Instance list (28-42), run-tree list (44-62), metadata (64-74).
- Content download (93-135):
  1. tenant `artifact(id)` and `user_locale`;
  2. `ArtifactStore::read`;
  3. if `label_downloads` is on and the file is text/plain or text/markdown, or ends in .txt/.md/.markdown (78-91), append `text_footer_in(locale, content_producer)` (106-108);
  4. headers: Content-Type, `Content-Disposition: attachment`, `nosniff`, `x-aigc` (109-133).
- DELETE (137-152): tenant `delete_artifact`, then a best-effort `delete_blob`.

**client-core**
- `api.rs:2245-2290` and `ffi.rs:2620-2661`: `run_artifacts`, `instance_artifacts`, `delete_artifact`, `artifact_content`.
- The FFI `Artifact` record (`ffi.rs:1633-1658`) has no `root_run_id`, author or project. The proto `Artifact` is at `proto/src/domain.rs:1273-1287`.
- `cache.rs` caches no artifacts.

## C. `project_keys` (0039)

- Table at `0039_projects.sql:99-106`: `project_id` (PK, FK to projects ON DELETE CASCADE), `kms_key_id`, `wrapped_dek`, `created_at`.
- RLS is ENABLE + FORCE (171-178) with no app policy (212). Worker has CRUD (224-225); llmgw and relay have nothing (226).
- **No Rust code reads or writes it.** It appears only in tests: `tests.rs:1024-1043` checks FORCE, and `tests.rs:1413-1424` checks that the tenant gets 42501.
- Every hard delete of a project already destroys its key by cascade:
  - `delete_solo_project` (`projects.rs:522-535`)
  - `delete_unshared_project` (`project_invites.rs:905-958`, delete at 954)
  - erase (`users.rs:248`)

## D. What 8.15 has to change

### 1. Project DEK

**Store** (`Tx<Worker>` only)
- `project_key(p)` should return the row only when `projects.status IN ('active','archived')`, checked in the same SQL. This is the "every decrypt checks status" rule in projects-impl item 7.
- `insert_project_key` must:
  - require status `'active'`;
  - be serialized against delete with `lock_project` (`projects.rs:59-62`) or `SELECT … FROM projects … FOR SHARE`.

  **Why the lock is needed:** the FK check on `project_keys` takes FOR KEY SHARE on the projects row, and that does not conflict with the FOR NO KEY UPDATE taken by `UPDATE projects SET status='deleted'`. Without the lock, a concurrent create can commit a fresh key after delete has destroyed the old one.
- Do the KMS wrap **outside** the locked transaction. `user_vault` holds its transaction across the KMS call (`artifacts.rs:177-186`); the KMS timeout is 10 s (`server/src/lib.rs:191`).
- Then `INSERT … ON CONFLICT DO NOTHING` and re-read, with the same winner logic as `artifacts.rs:191-208`.

**Orchestrator**
- Add `project_vault(db, kms, project, create)` next to `user_vault`.

**KMS context must never collide with a user's.** Two options:
- **Option (a): no keyvault change.** Pass `project:<uuid>` everywhere a user id string goes today. A UUID string never starts with `project:`, so nothing collides. That makes:
  - LocalKms AAD `thinktin/dek/{kid}/project:<uuid>`;
  - Aliyun EncryptionContext `{"purpose":"thinktin-dek","user":"project:<uuid>"}`;
  - blob AAD `thinktin/blob/v1/` + `project:<uuid>` + artifact id.

  The only cost is the misleading `NoUserKey` error text (`lib.rs:34-35`).
- **Option (b): typed project API.** Add project methods with their own AAD domain and Aliyun context. The user context format must stay byte-identical (`kms.rs:39-41`, `lib.rs:121/136`), or existing wrapped DEKs stop decrypting.

**Who may unwrap**
- The worker process (tools, pipeline) and the api process (download). Both use DB role `thinktin_worker` and already hold KMS credentials.
- llm-gw: **no**. It only decrypts model keys and vault items, which stay on owner DEKs (projects-impl item 4). Give it no `project_keys` grant.
- `thinktin_member` and the definer-owner role: no access to `project_keys`.

**Rotation:** `KmsRing` works unchanged because the `kms_key_id` column is the same as in `user_keys`.

### 2. Project-scoped artifacts

**Schema**
- Add `project_id`, `space_kind`, `space_id` (as in `0040:29-32`), derived from `runs` by a BEFORE INSERT trigger and immutable afterwards.
  - `fill_space` cannot be reused as is: it computes from `NEW.project_id` and whitelists `current_user` (`0040:7-27`).
- Add FK `(run_id, space_kind, space_id)` referencing `runs (id, space_kind, space_id)`, using index `runs_id_space` from 0041.
  - First NOT VALID, then VALIDATE in a separate transaction with FORCE dropped (the 0045/0046 pattern).
- Add `CREATE INDEX CONCURRENTLY (project_id, created_at DESC) WHERE project_id IS NOT NULL`, alone in a no-transaction file.
- Possibly a per-project cap.

**Which DEK**
- The project DEK, with an AAD that binds the project and the artifact.
- `StoredArtifact`, `Row` and `columns!` (`store/artifacts.rs:9-63`) need `project_id`, so that `read` (`artifacts.rs:340-347`) picks the key from the artifact instead of from `a.user_id`.
- Blob key prefix `projects/<p>/<a>` instead of `<user>/<a>` (300). It passes `LocalBlobStore` validation (76-92).

**Publish**
- The project is derived from `runs.project_id` inside the worker transaction; `Origin` and `ToolContext` carry none.
- `insert_artifact` must re-check `status='active'` under the lock, because the blob is put (301) before the index transaction (303-329). Archived projects are read-only (`projects.md:51`).

**Who can list and download**
- Live members, while the project is not deleted, through new narrow ProjectTx/`thinktin_member` queries.
- The content route then needs a worker read of `project_keys` that re-checks status (and membership) in the same SQL.
- Keep the labelling code (`routes/artifacts.rs:78-133`) identical.
- Map 42501 to 404 on project paths (8.14 plan section 9).

**Tenant hole**
- The current policy `user_id = app_user_id()` with SELECT and DELETE (`0002:103, 109`) lets an author who has left still list, download and **DELETE** their project artifacts. Affected routes: `/v1/artifacts/{id}`, `/v1/instances/{id}/artifacts`, `/v1/runs/{id}/artifacts`.
- Narrow the tenant policy to `project_id IS NULL`. Deleting project artifacts becomes worker-only, through `ProjectActor`.

**Erase**
- `DELETE FROM runs WHERE user_id` (`users.rs:218`) cascades through the `(run_id, user_id)` FK (`0002:88`) and deletes a member's project artifacts. That contradicts `projects.md:106` and projects-impl item 7.
- Erase must limit this to private runs or detach project runs, or the FK must change for project rows.

**Other places**
- Content reports (`reports.rs:151-158`) are tenant-only.
- Workspace: `artifact_fetch` and the pipeline handoff copy project plaintext into a workspace whose archive is sealed with the owner's DEK (`workspaces.rs:239-245`). Projects-impl item 5 forbids this; the per-(instance, project) archive key is 8.16. Claims already skip project runs (`runs.rs:204-206`).
- API and FFI: proto and FFI `Artifact` need project and author fields. Adding fields to the UniFFI record changes the generated initializers.

### 3. Destroying the key on project delete

**Short worker transaction** (D3 lock order):
1. `status='deleted', deleted_at=now()`;
2. `DELETE FROM project_keys`;
3. cancel runs, bump epochs and revoke grants, as `exit_member` does (`project_members.rs:357-433`; `runs.rs:899`; `grants.rs:256`);
4. revoke invites and mark the invite notices read, as `delete_unshared_project` does (931-952).

**Background cleanup**
- Extend `orchestrator::projects::sweep` (`orchestrator/src/projects.rs:537-563`; called from `workers.rs:507`) to work in bounded, retryable batches:
  1. artifacts rows (the trigger queues `blob_purge`, which `purge_blobs` drains);
  2. project runs, events and approvals;
  3. finally the `projects` row, which cascades to members, agents and invites.
- The hard-cascade paths become unbounded transactions, and `runs_project_agent` NO ACTION (`0045:9-10`) blocks them. Erase of a creator (`users.rs:248`) must switch to this flow.

**Caches:** stale `CachingKms` entries cannot be reached without the wrapped bytes, so no eviction is needed for correctness.

**Leftovers:**
- S3 deletes are unversioned (`s3.rs:236-242`), so on a versioned bucket older object versions remain.
- Database backups keep wrapped DEKs.
- In both cases, key destruction is the only protection, as with user erase today.

### 4. Roles and tests

- `thinktin_member` and the definer-owner role (NOLOGIN, NOBYPASSRLS) must be pre-created in two places, because the owner has no CREATEROLE (`testing.rs:15, 96`):
  - `testing.rs:85-98`;
  - `docs/deploy-checklist.md:57-71`.
- `ALTER FUNCTION … OWNER TO` that role requires the migrating owner to be a member of it. GRANT it to `thinktin_test_owner` and `thinktin_owner`.
- A definer function owned by a NOBYPASSRLS non-owner is subject to RLS, so it needs its own policies (`TO <role>`). Existing definer functions run as the table owner (`0007:40-46`).
- Use `search_path = pg_catalog, public, pg_temp` (`0039:162`, `0040:8`), not the older `public` (`0001:289, 305`; `0007:41`; `0023:33`).

## Map: lifecycle-api

I mapped the project lifecycle and API surface as of HEAD `995819c`, on branch `claude/determined-lovelace-vn0j5h`. I changed no files.

## 1. Status column, writers and readers

**The column.** `projects.status` accepts active/archived/deleted (`0039:20`). Two CHECKs require `archived_at` or `deleted_at` to match the status (`0039:27-28`). `ProjectStatus` is defined at `proto/src/domain.rs:546-555`; its `Deleted` doc says "后台清理（8.15）" (`:552`).

**Nothing writes `archived` or `deleted` today.**
- `update_project` changes only name and goal (`store/src/projects.rs:365-373`).
- `update_solo_project` changes only the name (`:463-470`).
- The tenant has column grants only on `name` and `updated_at`, plus INSERT on `id, creator_id, name, goal` (`0039:215-216`, `0047:79`).
- The worker has full rights on the table (`0039:224-225`).
- The 8.14 rule for 8.15 is that every writer of `projects.status` takes `lock_project` first (`projects-8.14-plan.md:820`). The lock is defined at `projects.rs:60-62`.
- `project_actor` reads the status again after taking the lock (`projects.rs:234-241`), so new status writers will be serialized against it.

**Readers filter status inconsistently.**

| Status filter | Where |
|---|---|
| `active` only | `my_projects` (`projects.rs:262`)<br>`own_projects` (`:433`)<br>`update_solo_project` (`:465`)<br>`writable_solo` (`:559`)<br>invite SQL `for_me_sql` (`project_invites.rs:149`), link preview (`:487`), decline (`:757`), accept (`:545`)<br>delegation and lead checks (`instances.rs:581,598`) |
| `<> 'deleted'` | `project_detail` (`projects.rs:278`)<br>`own_project`, used by `/v1/teams/{id}` (`projects.rs:422`)<br>creator's invite list `project_invites` (`project_invites.rs:381`) |
| allow-list passed to `project_actor` | Active only: create invite (`project_invites.rs:183,284`), revoke (`:419`), `delete_unshared_project` (`:925`), `add_project_agents` (`project_members.rs:172`), `remove_project_member` (`:323`), `set_project_budget` (`:441`), `update_project` (`projects.rs:362`)<br>Active + Archived: `withdraw_project_agent` (`project_members.rs:238`), `leave_project` (`:302`) |

So an archived project would drop out of `GET /v1/projects` but still open in `GET /v1/projects/{id}` and `/v1/teams/{id}`. 8.15 has to pick one rule. `ProjectSummary.status` (`domain.rs:1030`) can already carry `archived`, so listing archived projects would not change the JSON.

## 2. Delete paths

**`DELETE /v1/projects/{id}`**
- Route at `gateway/src/routes/mod.rs:175-178`; handler `projects::delete` at `gateway/src/routes/projects.rs:147-156`.
- It calls `orchestrator::projects::delete` (`orchestrator/src/projects.rs:42-54`): one worker transaction that runs `delete_unshared_project` and writes the `project.delete` audit row.

**`DELETE /v1/teams/{id}`**
- Route at `mod.rs:163-164`; handler at `gateway/src/routes/teams.rs:97-110`.
- It calls the same orchestrator function and maps `NotPermitted` to 404 to keep the old API's status codes (`:105-108`).

**Store: `Tx<Worker>::delete_unshared_project`** (`store/src/project_invites.rs:909-959`)
1. Pre-reads the users who received pending invites (`:914-923`).
2. Calls `project_actor(.., &[Active])`, then `require_creator` (`:924-927`).
3. A shared project returns `Conflict("project is shared")`, which is the 409 (`:928-935`).
4. Revokes pending invites and marks their inbox items read (`:936-953`).
5. Hard-deletes the project: `DELETE FROM projects` (`:954-957`). Members, agents, invites and `project_keys` go with it by cascade (`0039:33,62,88,102`).

**Tenant `delete_solo_project` is now dead code in production.**
- It is at `projects.rs:522-533`, with a comment saying 8.15 should turn it into mark-deleted plus background cleanup. It is reached only through `delete_team` (`teams.rs:84-86`).
- Only tests call it (`store/src/tests.rs:1362,1445`, `store/src/tests/projects.rs:138`). The client-core `delete_team` goes over HTTP to the worker path.
- But the tenant can still hard-delete an unshared project: the `tenant_delete` policy (`0039:187-188`) and `GRANT … DELETE ON projects TO thinktin_app` (`0039:214`) are still in place. Once project keys and content exist, that would skip the soft-delete and key-destroy flow.
- 8.15 should revoke that DELETE and remove the dead code. `tools/ci/check_migrations.py:213-216` flags any REVOKE as breaking, so the migration needs a `deploy-safe:` note.

**Tests that assert the 409 and will change:**
- `gateway/tests/api.rs:2911-2915` (team path), `:5020-5029` (`DELETE /v1/projects`), `:5257-5284` (old teams API on a shared project);
- `store/src/tests/projects.rs:2147-2150`.

**Plan bindings:**
- D10 (`projects-8.14-plan.md:24`): the old `/v1/teams*` writes keep returning 409 on shared projects.
- D12 (`:26`) and §9 (`:820`): soft-delete and archive shared projects via `DELETE /v1/projects/{id}`, add a `project_deleted` receipt, and switch erase to soft delete.

There is no archive route, store function or FFI anywhere.

## 3. `erase_account` and projects (`store/src/users.rs:183-274`)

**Call path:** `auth/src/service.rs:554-573` (the worker erase is at `:561`), from `gateway/src/routes/account.rs:230-237`.

**Order of operations:**
1. Locks the user row `FOR UPDATE` (`:186-189`).
2. Locks every related project in id order (`:194-207`): ones the user created, joined, put agents in, or has invites in.
3. `DELETE FROM runs WHERE user_id` (`:218`). This cascades the user's approvals, artifacts and events.
4. `DELETE FROM events` by instance (`:220`) and `DELETE FROM inbox_items` (`:224`).
5. Marks every `project_agents` row of the user as left (`:246-247`).
6. **Hard-deletes the user's own projects: `DELETE FROM projects WHERE creator_id = $1` (`:248`).** This cascades to the members, agents, invites and keys of the other members as well.
7. Marks the user's membership in other people's projects `erased` (`:249-250`) and deletes invites (`:251-252`).

**Precondition (8.14 §9, `projects-8.14-plan.md:821`):**
- `runs_project_agent` is NO ACTION (`0045:6-7`). Grants are CASCADE (`0045:8-9`).
- The cascade from step 6 goes `projects` → `project_members` (`0039:33`) → `project_agents` (`0039:62`). Any project run another member has in the deleted project would hit the NO ACTION key and fail with 23503.
- 23503 maps to `Error::Invalid` (`store/src/error.rs:67`), then to 422 through `AuthError::Store` (`gateway/src/error.rs:113`). Erase would just fail.
- Today nothing writes project runs: the 8.13 claim guard is described at `runs.rs:204-206`.

**Other conflicts with the plan:**
- Step 3 (`:218`) also deletes the erased user's own project runs in other people's projects, and their artifacts cascade with them (`0002:88`). This contradicts projects.md §10 (`:106`, "他在别人项目里留下的内容保留") and impl item 7 (`projects-impl.md:24`, "保留其他主人仍需的记录…解除父关联").
- The CHECK `role = 'member' OR left_at IS NULL` (`0039:44`) means a creator's member row can never be marked left. After a soft delete that row stays live, so member reads must also gate on project status (and on users.status).

## 4. `inbox_project_guard` (0047)

**What exists:**
- Columns: `ALTER TABLE inbox_items ADD COLUMN project_id, project_invite_id`, with no foreign keys (`0047:48`).
- The 8.15 note in the migration is at `0047:52-54`.
- The function is at `0047:55-73`; REVOKE PUBLIC at `:74`; the trigger at `:75-76`.
- On UPDATE it refuses any change to `project_id`, `project_invite_id` or `subtype`, for every role (`:58-65`).
- On INSERT it refuses non-NULL project fields unless the current user is `thinktin_worker` (`:67-71`).

**8.15 work (§9 bullet, `projects-8.14-plan.md:819`):**
- CREATE OR REPLACE the function so it derives `project_id` from `runs.project_id` through `run_id`, and raises when a supplied value disagrees.
- Exempt receipts by `subtype`, never by `run_id IS NULL`, because `run_id` is `ON DELETE SET NULL` (`0001:381`).

**Receipt subtypes today:** `project_invite`, `project_joined`, `project_left`, `project_removed`, `project_agent_left`, `project_agent_removed` (`proto/src/domain.rs:1321-1332`). A new `project_deleted` has to go there, into the exemption list, into `orchestrator/src/texts.rs`, and into `docs/push.md`.

**Trap — derivation must not trip the worker-only check.** Tenant code inserts inbox items through `notify_tenant` (`orchestrator/src/outbox.rs:230-…`). Callers are `orchestrator/src/tools.rs:187`, `orchestrator/src/vault.rs:167` and `gateway/src/routes/plans.rs:358`. If the derived `project_id` is checked by that same worker-only rule (`:67-68`), every tenant notice about a project run will fail with 42501.

**Inbox reads and writes:**
- The tenant inbox policy is the generic `user_id = app_user_id()` (`0001:438`).
- Inbox-writing code: `store/src/inbox.rs:12-37,94-135`.
- Project notices are built by `project_notice` in `orchestrator/src/projects.rs:24-28`.

## 5. Templates

**What exists:**
- `/v1/team-templates*` routes at `mod.rs:166-171`.
- Handlers: `templates` (`teams.rs:112-117`), `create_template` (`:127-166`), `delete_template` (`:168-178`), `adopt_template` (`:187-230`).
- `adopt_template` creates the instances and their grants, then calls `create_team` in the same tenant transaction (`:227`) and returns `Team`.
- Store: `teams.rs:88-152` reads and writes `project_templates` (table at `0039:109-117`; tenant policy at `0039:210-211`).
- Client-core: `api.rs:1831-1875`; FFI `ffi.rs:2970-3036`.

**8.15 work (D16, `projects-8.14-plan.md:30`; §9 `:822`; open question at the end of the plan):**
- Add a `/v1/project-templates*` alias and its FFI. Nothing exists yet.
- Decide whether the alias's adopt returns `ProjectDetail` (through `projects::detail`) or `Team`.

## 6. The 8.14 worker reads that 8.15 must move to member reads

D9 (`projects-8.14-plan.md:23`) and §9 (`:817`) say the JSON must not change.

**Store:**
- `my_projects` (`projects.rs:258-268`) and `project_detail` (`:270-351`), both built on `SUMMARY_SQL` (`:133-142`).
- `project_detail`'s members query (`:285-296`), agents query (`:310-317`) and `my_budget` (`:333-340`).
- The invite previews: `invites_for` (`project_invites.rs:451-464`), `invite_preview` (`:468-498`) and the member list in `preview` (`:668-721`). These are non-member reads, so they need a definer function keyed by phone match or token hash.
- Possibly also the creator's invite list `project_invites` (`:374-400`).

**Orchestrator wrappers:** `my_projects` (`orchestrator/src/projects.rs:57-62`), `detail` (`:65-70`), `invites` (`:165-174`), `invites_for` (`:199-204`), `preview` (`:207-216`).

**Gateway callers of `detail`:**
- `projects::list` (`gateway/src/routes/projects.rs:68-71`), `create` (`:108`), `get` (`:112-119`), `update` (`:143`), `add_agents` (`:184`);
- `project_invites::join` (`project_invites.rs:111`).

**Fixed shapes:**
- Proto: `ProjectSummary` (`domain.rs:1026-1043`), `ProjectDetail` (`:1100-1108`), `ProjectMemberView` (`:1047-1056`), `ProjectAgentView` (`:1059-…`).
- FFI records `ffi.rs:870-1160`.

**There is no member role or member transaction yet.**
- `Db` has only `tenant`, `worker`, `llmgw` and `relay` (`store/src/lib.rs:129-180`); the role markers are at `:189-205`.
- 8.15 needs a `Db::member()` and `ProjectTx`, plus a `thinktin_member` role (NOLOGIN, no default grants) and a NOLOGIN NOBYPASSRLS role to own the definer functions.
- The existing precedent for SECURITY DEFINER is `0001:289,305` (`SET search_path = public`).

## 7. Gateway error mapping

- Postgres 42501 becomes `store::Error::Forbidden` (`store/src/error.rs:22-24,69`).
- The gateway has no arm for `Forbidden`, so it falls into `other => Self::internal(other)` and returns **500** (`gateway/src/error.rs:93`).
- `NotPermitted` maps to 403 (`:92`).
- 8.15 must map 42501 to 404 on project paths (`projects-8.14-plan.md:818`). That matters once `thinktin_member` and the guards (`0040:19-21`, `0047:67-70`) can raise it.

## 8. client-core: FFI and local cache

**The project FFI calls the network directly and caches nothing.**
- Methods are at `ffi.rs:3038-3262`, each `self.run(|c| c.api.…)` (for example `projects` `:3041-3051`, `delete_project` `:3092-3095`, `leave_project` `:3142-3145`). The API side is `api.rs:1876-…`.
- `leave`, `remove` and `withdraw` do not touch the cache.

**The cache has no project tables.**
- Tables: `cache.rs:23-50` holds instances, runs, cursors, events, inbox, pending reads and totals.
- The cache is cleared only on user switch (`bind_user` `:90-111`) and sign-out (`clear` `:114-124`).

**What could hold project data that must be cleared on leave:**
- **Inbox:** items now carry `project_id` (`domain.rs:1403-1406`, cache literal `cache.rs:582-583`). `reconcile_inbox_page` replaces only the id range a page covers and keeps older cached pages (`cache.rs:305-355`). Server-side narrowing therefore will not remove older cached project-run notices.
- **Runs and events:** `put_runs` is called from `client.rs:111-117`, `120-131` and `134-145` (`list_runs`); `put_events` from `events.rs:375`. Both are keyed by instance only. `proto::Run` has no `project_id` (`domain.rs:923-948`), so cached project runs cannot be cleared per project.

**What 8.15 needs on the client:**
- a per-project forget, run when you leave, are removed, or the project is deleted (impl `projects-impl.md:14`);
- `project_id` on `Run`, or project runs kept out of the private cache entirely (`projects-impl.md:29`).
- Members must not see costs: today `Run` exposes `tokens_used` and `error` (`domain.rs:940,942`).

## 9. Product requirements for leave, delete and archive

**`docs/projects.md`:**
- §4.5 (`:50`): when a member leaves, their agents stop and leave the project. Their board posts and artifacts stay, shown as "已退出的成员". Today the member list shows only live members (`projects.rs:291`), and nothing anonymizes authors.
- §4.6 (`:51`): archive is read-only. Delete destroys the project key, so board, artifacts and project-run content become unreadable.
- §5 (`:55-63`):
  - membership-based RLS on the project tables;
  - members can read runs that have a `project_id`;
  - runs without one stay owner-only;
  - artifacts from project runs go into the project space under the project key;
  - vault, computer, model keys, private artifacts and the private board never appear in the project.
- §9 (`:98`): RLS and the API both check membership, and visibility ends at the instant of leave or removal.
- §10 (`:106`): erase removes the user's agents from all projects and deletes the projects they created, destroying the keys. Their content in others' projects stays, shown as "已注销的用户".

**`docs/projects-impl.md`:**
- `:14`: leaving disconnects the project stream at once; an open project page switches to "已退出" and clears revocable local cache. Deletion is unreadable at once and cleanup can be retried.
- Item 2 (`:19`): `thinktin_member`, a read-only `ProjectTx`, and database-side checks of user, membership and status. The owner's own instance history is also limited by membership, so the old routes cannot be used to read around a leave. Today the tenant run policy is only `user_id = app_user_id()` (`0001:438`).
- Item 7 (`:24`) covers the delete and erase sequence; test 4 (`:126`) covers archive restore, downloads and offline cache using the same scope check.

## 10. Everything 8.15 must touch

**Migrations (new 0049+):**
- `thinktin_member` and the definer-owner role, using the create-if-missing pattern of `0001:18-20` and `0014:15`.
- Member SELECT policies on `projects`, `project_members` and `project_agents`, or definer functions over them.
- Project-row conditions on the runs, events, approvals and artifacts policies (`0001:433-441`; artifacts at `0002:73-94`).
- A project scope column and same-space foreign key on artifacts (impl item 1).
- CREATE OR REPLACE `inbox_project_guard`.
- REVOKE the tenant DELETE on `projects` (`0039:187-188,214`, with `deploy-safe:`).
- Use `project_keys` (`0039:101-106`), which nothing writes yet.

**Store:**
- `lib.rs`: `Db::member`, the `Member` role, `ProjectTx`.
- `projects.rs`: move the reads; add archive and soft delete under `lock_project`; drop or redirect `delete_solo_project`.
- `project_invites.rs`: `delete_unshared_project` gets a shared-project branch and maybe a soft delete; move the previews.
- `users.rs`: erase switches to soft delete, keeps others' records and detaches cross-owner runs.
- `inbox.rs`: carry the derived `project_id`.
- `artifacts.rs`: the project space.
- New bounded cleanup batches for deleted projects.
- `testing.rs:87-97`: add the new roles to the test bootstrap.
- `tests.rs:3718`: add the new roles to this role loop.

**Orchestrator:**
- `projects.rs`: delete and archive wrappers, the `project_deleted` receipt, the move to member reads, and adding cleanup to `sweep` (`:537-563`).
- `artifacts.rs`: seal and open with the project DEK and check project status on every read (`:159-184,296-300,341-347`).
- `outbox.rs` and `texts.rs`: the new receipt and its text.

**Server:** `workers.rs:507`, the cleanup hook in `maintain`.

**Gateway:**
- `error.rs:92-93`: map 42501 to 404.
- `routes/projects.rs:147-156`: delete for shared projects, plus an archive route.
- `routes/mod.rs:161-197`: register the archive route and the `/v1/project-templates*` alias.
- `routes/teams.rs`: keep the 409s per D10.
- Member endpoints for project runs and artifacts.
- `tests/api.rs`, at the lines listed in section 2.

**Proto:** `domain.rs`, for `notice_subtype` (`:1303-1333`), a member-facing run DTO or a `project_id` on `Run`, and the `ProjectStatus` docs.

**Client-core:**
- archive, delete-shared and template FFI;
- a per-project cache forget (`cache.rs`, `client.rs`);
- regenerated Android bindings (`apps/android/core/.../client_core.kt`).

**Keyvault:** a project-keyed `KeyStore`, or an adapter over `project_keys`. Today `KeyStore` and the DEK cache are keyed by user id (`keyvault/src/lib.rs:371-377,642-…`), and blob AAD is per user (`:768-770`).

**Docs and deploy:**
- `docs/deploy-checklist.md:57-71` and `docs/release.md:73-78`: create the roles and `GRANT thinktin_member TO thinktin_server_login`.
- `docs/push.md`: the new subtype.
- `docs/projects-impl.md` and `docs/projects.md`: status lines.
- The progress file.