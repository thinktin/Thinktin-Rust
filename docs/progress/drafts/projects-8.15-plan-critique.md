# 8.15 方案评审（workflow `projects-8-15-plan`，2026-11-05）

两个角度：安全、实现。英文原样。

## Security

## Review of the 8.15 plan: database security and correctness

I read the plan against the code at HEAD `43f0944`. HEAD is one commit past the plan's stated `995819c`; the extra commit only adds two draft docs. Most of the plan holds up, but I found four blocking defects (one in the erase change, three in the tests and commit order) and several places where a guarantee the plan says the database enforces is actually only enforced by application code. I did not modify any files.

### Claims I checked and found correct
- **Old clients' run cache.** Only list calls write to it (`client-core/src/client.rs:111-145` → `put_runs`), and point reads are not cached. So the `project_id IS NULL` filter on tenant lists is enough to keep project runs out of old clients' caches.
- **Live event stream.** The WebSocket re-reads every page through a tenant `events_after` call (`gateway/src/routes/events.rs:42-52, 168-185`). It does not fan out from a worker read, so the filter also covers live delivery.
- **Tenant appends after leaving fail with 23503, as the plan says.** `append_event` uses `INSERT … RETURNING` (`events.rs:52-56`), so the new row must pass the SELECT policy. A row derived as private passes it, and the composite foreign key then fails with 23503. The order is the one the plan describes.
- **Artifact cascades.** `artifacts`, `approvals` and `events` all reference `runs` with `ON DELETE CASCADE` (`0002:88`, `0001:344`, `0001:283`). The `UPDATE OF run_id` branch of `fill_space_from_run` therefore never fires during purge. Every row that is set to NULL instead is outside these three tables.
- **Key separation.** llm-gw logs in separately (`docs/deploy-checklist.md:61-63`) and has no access to `project_keys` (`0039:224-226`). Its KMS credentials are useless without the wrapped bytes. The AAD is length-prefixed (`keyvault/lib.rs:768-779`), and the KMS context is `{"purpose":"thinktin-dek","user":ctx}` (`aliyun/src/kms.rs:39-41`), so `project:<uuid>` cannot collide with a user's context.
- **Policy roles.** Every policy names its role with `TO …`; none applies to PUBLIC. No table is granted to PUBLIC. The only SECURITY DEFINER functions are the four legacy ones.
- **Ownership-change recipe.** sqlx 0.9 `Pool::begin_with` exists (`sqlx-core-0.9.0/src/pool/mod.rs:391`). In tests the owner of the `public` schema is `pg_database_owner`, i.e. `thinktin_test_owner` (`testing.rs:107-108`), so the temporary `GRANT CREATE` in D2 works there.
- **Purge lock key.** `'project/'||id` produces the same text as `format!("project/{id}")`: both are lowercase hyphenated UUIDs.

### Corrections

**C1 (blocking). Erasing a creator will fail with 23514.** Today `users.rs:248` hard-deletes the creator's projects first, which cascades away the creator's member rows. The next statement, `users.rs:249-250`, then marks the erased user's remaining live member rows as left:

```sql
UPDATE project_members SET left_at = now(), left_reason = 'erased' WHERE user_id = $1 AND left_at IS NULL
```

Once `:248` is removed for soft delete, the creator's row (`role = 'creator'`, `left_at IS NULL`) survives. Setting `left_at` on it violates `CHECK (role = 'member' OR left_at IS NULL)` (`0039:44`), and the whole erase rolls back. Add this to the plan's erase change list:
> `:249` becomes `UPDATE project_members SET left_at = now(), left_reason = 'erased' WHERE user_id = $1 AND left_at IS NULL AND role = 'member'`. The creator's row stays live in the soft-deleted project; `member_projects()` already excludes it through `p.status` and `u.status`, and purge removes it.

**C2 (blocking). Test 12 cannot seed a project run with superuser SQL.** `fill_space` rejects any row with a `project_id` unless `current_user = 'thinktin_worker'`, and the comment says superusers are rejected too (`0040:3, 19-22`). Corrected text:
> "insert a project run with `SET LOCAL ROLE thinktin_worker`, then the approval, artifact and events for it as superuser (0050's trigger does not exist yet)."

**C3 (blocking). Three tests are scheduled before the migrations they depend on.**
- Test 1 (in C3) calls `project_runs(P2, …)` and `project_run_events(P2, …)`, which only exist from `0055` (C6). Move those two assertions to test 3 or 4.
- Test 5 (in C4) asserts that "after leaving, the same append → 23503". Before C6 the tenant runs policy is still `user_id = app_user_id()` (`0001:438`), so bob still sees R, the trigger derives "project", and the insert succeeds. Move the after-leave half to C6.
- `member_roles_are_restricted` (in C2) pins the member role's column allow-list, but `0055` adds `artifacts` columns. That test must be updated in C6.

**C4 (high). The 0049 role check misses the dangerous membership directions.**
- **What it misses.** It never checks whether `thinktin_app` is a member of `thinktin_member` or of `thinktin_project_definer`.
  - If `thinktin_app` were a member of `thinktin_member`, tenant sessions would also get the `member_read` policies.
  - Tenant code relies on `tenant_read` for scoping. For example `own_projects()` is just `SELECT … FROM projects WHERE status = 'active'` (`projects.rs:431-438`), so the old `/v1/teams` list would start showing projects the user only joined.
- **Other gaps.**
  - It checks that the definer is not a member of `thinktin_member`, but not the reverse, which is the direction that would give members the definer's grants on `runs`, `events` and `payload`.
  - It does not check `rolinherit` on the definer.
  - It does not check that the definer belongs to no role at all, which D1 states.
  - It does not check that the migration owner's grant really has `INHERIT FALSE`.

Replace the first `IF` in the 0049 DO block with:
```sql
IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname IN ('thinktin_member','thinktin_project_definer')
             AND (rolsuper OR rolbypassrls OR rolcanlogin OR rolcreaterole OR rolcreatedb))
   OR (SELECT rolinherit FROM pg_roles WHERE rolname = 'thinktin_project_definer')
   OR EXISTS (SELECT 1 FROM pg_auth_members am JOIN pg_roles r ON r.oid = am.member
               WHERE r.rolname IN ('thinktin_member','thinktin_project_definer'))      -- the two roles are members of nothing
   OR EXISTS (SELECT 1 FROM pg_auth_members am JOIN pg_roles g ON g.oid = am.roleid JOIN pg_roles m ON m.oid = am.member
               WHERE g.rolname IN ('thinktin_member','thinktin_project_definer')
                 AND m.rolname IN ('thinktin_app','thinktin_worker','thinktin_llmgw','thinktin_relay',
                                   'thinktin_member','thinktin_project_definer'))
   OR pg_has_role(current_user, 'thinktin_project_definer', 'USAGE') THEN   -- the owner's grant must be INHERIT FALSE
    RAISE EXCEPTION '…';
END IF;
```
Two related changes:
- **Startup check.** `Db::check_roles()` (D19) should also fail if `pg_has_role(session_user, 'thinktin_project_definer', 'MEMBER')`.
- **Deploy grant.** In the deploy docs (§5.4), grant the member role to the login with `GRANT thinktin_member TO thinktin_server_login WITH INHERIT FALSE, SET TRUE`. The login only ever uses the role through SET ROLE, so it has no reason to inherit its privileges or policies.

**C5 (high). Deleted projects stay readable and writable through the tenant policies.**
- **The gap.** Soft delete keeps `status = 'deleted'` rows for at least 10 minutes. The tenant policies never look at status:
  - `tenant_read` on `projects` is `creator_id = app_user_id()` (`0039:181`);
  - `tenant_update` on `projects` and the `tenant_insert` / `tenant_update` policies on `project_members` and `project_agents` check only `shared_at` (`0039:184-208`).
- **What protects it today.** Only application code: `own_project`'s `status <> 'deleted'` (`projects.rs:422`) and `writable_solo` (`:555-566`). That contradicts "the database itself checks … project status". Add to 0049:
```sql
ALTER POLICY tenant_read ON projects USING (creator_id = app_user_id() AND status <> 'deleted');
ALTER POLICY tenant_update ON projects
    USING (creator_id = app_user_id() AND shared_at IS NULL AND status = 'active')
    WITH CHECK (creator_id = app_user_id() AND shared_at IS NULL AND status = 'active');
-- same AND p.status = 'active' inside the EXISTS of tenant_insert ON project_members,
-- tenant_insert ON project_agents and tenant_update ON project_agents (USING and WITH CHECK)
```
- **Exception.** Leave `tenant_update ON project_agents` without the status condition only if deleting an instance in an archived solo project must still mark its agent as left (`instances.rs:397`). In that case use `p.status <> 'deleted'` instead of `= 'active'`.

**C6 (high). Tenants can repoint an inbox item's `run_id` without the guard re-deriving the project.**
- **The gap.** Tenants have UPDATE on every column of `inbox_items` (`0001:468`), but `inbox_project_guard` only fires on `UPDATE OF project_id, project_invite_id, subtype` (`0047:75`).
- **Consequence.** A tenant can set `run_id` to one of its own project runs while `project_id` stays NULL. The item is then never hidden on leave, which breaks D10's "derived from the run".
- **Why the fix is safe.** Every tenant UPDATE of `inbox_items` writes only `read_at` (`inbox.rs:245, 253, 265`).
- **Same pattern on `approvals`.** Tenants hold INSERT although only the worker inserts (`approvals.rs:100-103`), and their UPDATEs write only `state`, `decided_option`, `decided_by` and `decided_at` (`approvals.rs:273`).

Add to 0055:
```sql
-- deploy-safe: tenant code only writes read_at (inbox.rs mark_inbox_read / mark_inbox_unread)
REVOKE UPDATE ON inbox_items FROM thinktin_app;
GRANT UPDATE (read_at) ON inbox_items TO thinktin_app;
-- deploy-safe: approvals are inserted only by the worker; the tenant only decides them
REVOKE INSERT, UPDATE ON approvals FROM thinktin_app;
GRANT UPDATE (state, decided_option, decided_by, decided_at) ON approvals TO thinktin_app;
```

**C7 (medium). The guard should enforce what the receipt exemption assumes.** The policy exempts receipts from the membership check by `subtype` alone. If a worker bug ever wrote a run notice with a receipt subtype, it would stay visible after leaving. Add to the 0055 `inbox_project_guard`, before the worker-only check:
```sql
IF NEW.subtype IN ('project_invite','project_joined','project_left','project_removed',
                   'project_agent_left','project_agent_removed','project_deleted')
   AND (NEW.run_id IS NOT NULL OR NEW.project_id IS NULL) THEN
    RAISE EXCEPTION 'project receipts carry a project and no run' USING ERRCODE = 'check_violation';
END IF;
```
Extend test 4 so it also pins this list against `PROJECT_RECEIPTS`.

**C8 (medium). Hidden unread items will inflate the badge permanently.**
- **The cause.** The worker's `unread_inbox_count` counts every unread row for the user, with no project condition (`inbox.rs:180-187`). After leaving, a tenant's "mark all read" cannot reach the hidden rows.
- **Fix.** Inside `exit_member` (`project_members.rs:357-424`, where the member's user row is already locked) and inside `delete_project` (for the locked live members), run:
```sql
UPDATE inbox_items SET read_at = now() WHERE user_id = $2 AND project_id = $1 AND read_at IS NULL
   AND (subtype IS NULL OR NOT (subtype = ANY($3)))   -- $3 = PROJECT_RECEIPTS
```
  This follows the D3 rule for writing another user's inbox. Test 3 should assert it.

**C9 (medium). D18 and test 11 disagree about the legacy definer functions.**
- **The mismatch.** D18 hardens two of the four. Test 11 says all four have their `search_path` "checked too after D18". §8 defers `ensure_event_partitions` and `drop_event_partitions_before` (`0001:289, 305`).
- **Why it matters.** With `search_path = public` and no `pg_temp` listed, temporary tables are searched before everything else for relation names.
- **Recommendation.** Harden all four in 0049: `SET search_path = pg_catalog, public, pg_temp`, `PARTITION OF public.events`, `'public.events'::regclass`. Then test 11 can check all four.

**C10 (medium). The plan needs a list of every other tenant-readable table that references a run (add to §8, 8.16 must-do).** The plan narrows six tables, but these also hold run references:
- `vault_requests` (`0009:26, 38`);
- `device_calls` (`0014:34, 46`);
- `board_posts` (`0025:12, 22`);
- `egress_requests` (`0034:16, 26`);
- `live_activities` (`0018:12, 37`, CASCADE);
- `content_reports` (`0019:9`, no foreign key).

The first four use `ON DELETE SET NULL (run_id)`. Rows written by project runs would therefore become untagged "private" rows after purge, and before purge an ex-member could still read them through the old routes. Corrected §8 bullet:
> "Before lifting the claim guard: every tenant-readable table with a `run_id` gets a stamped `project_id` (derived as for inbox), the same membership-gated tenant policy, and a purge step."

**C11 (low). Comment correction in 0055.** The line "写项目行仍由 fill_space、inbox_project_guard 只放行 worker" is false for `events` and `approvals`. `fill_space_from_run` derives project space for tenant inserts as well. The tenant routes that do this are cancel (`gateway/routes/runs.rs:201-218`), interrupt (`:51`), `instances.rs:155` and `approvals.rs:46`. Corrected wording:
> "Tenants may append events to their own project runs only while they are live members; the member view shows only whitelisted kinds."

**C12 (low). Smaller fixes.**
- **Erase performance.** `DELETE FROM tool_calls WHERE user_id = $1` and `DELETE FROM approvals WHERE user_id = $1` run without a usable index (`tool_calls` only has its primary key `(run_id, key)`, `0012:4-10`; `approvals` only has the partial `approvals_pending`). They would seq-scan while erase holds the user and project locks. Use `run_id IN (SELECT id FROM runs WHERE user_id = $1 AND project_id IS NOT NULL)`; the private ones already cascade.
- **Purge lock key.** Bind `format!("project/{}", ProjectId(id))` from Rust, as `project_members.rs:541-545` already does, so the key has a single spelling.
- **Generic event reads.** `events_after` and `event_range` are `impl<R> Tx<R>` (`events.rs:37`), so the new `project_id IS NULL` filter silently applies to worker callers too. Document that, or move the tenant variants into `impl Tx<Tenant>`.
- **Definer owns no tables.** Add "`thinktin_project_definer` owns no relations" to test 11. The temporary `GRANT CREATE` in D2 makes it possible for a table to end up owned by the definer, and an owner bypasses RLS unless FORCE is set.
- **Caching headers.** Add `Cache-Control: no-store` to `/v1/projects/*` responses and downloads. The gateway sets no Cache-Control header anywhere today.
- **Reporting.** Members have no way to report project content they did not author: `/v1/reports` is tenant-only (`routes/mod.rs:146`). This is a 5.5 compliance gap; note it for 8.19.

## Implementation

The plan holds up, but erase breaks as written, and several commits would not compile or pass. Everything below was checked against the code at HEAD `43f0944` (the branch is clean but one commit past the `995819c` the plan names). I also ran a few checks on the local PostgreSQL 16.15, using a scratch database and roles that I dropped afterwards. No repo files were changed.

## Blocking (must fix before implementing)

**B1. Erase fails for every user who created a project.**
- The plan removes the hard delete at `users.rs:248` (`DELETE FROM projects WHERE creator_id`) and keeps `users.rs:249-250`: `UPDATE project_members SET left_at = now(), left_reason = 'erased' WHERE user_id = $1 AND left_at IS NULL`.
- Today the hard delete cascades the creator's own member row away before that UPDATE runs. With a soft delete the row stays, so the UPDATE hits it.
- That violates `0039:44` `CHECK (role = 'member' OR left_at IS NULL)` (23514). Every adopted team is a solo project, so nearly every erase fails.
- Tests that will fail: `tests/projects.rs:1886` (and its assertion at `:1993`, "alice's projects are gone"), `:2086`, `:2296`.
- Fix: `"UPDATE project_members SET left_at = now(), left_reason = 'erased' WHERE user_id = $1 AND left_at IS NULL AND role = 'member'"`. The creator's row stays until the purge's `DELETE FROM projects` cascades it.
- Also change `:1993` to assert `status = 'deleted'`, and `:2117` (`gone == 0`): invites now stay `revoked` until the purge.

**B2. The new `inbox_project_guard` breaks the 8.14 test and changes the tenant's error code.**
- In the plan's 0055 body, the run-derivation and mismatch check run before the worker-only check.
- The 8.14 test `inbox_project_fields_are_server_only` (`tests/projects.rs:275`) uses a fixture with `run_id: Some(run.id)` on a private run (`:299`) plus a `project_id`.
  - The tenant insert at `:306-309` would now get 23514 (`Invalid`) instead of `Forbidden`.
  - The worker insert at `:315` would now fail with 23514.
- Corrected order:
  ```sql
  IF (NEW.project_id IS NOT NULL OR NEW.project_invite_id IS NOT NULL) AND current_user <> 'thinktin_worker' THEN
      RAISE EXCEPTION 'project fields in inbox_items are written by the server only' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NEW.run_id IS NOT NULL THEN
      SELECT r.project_id INTO run_project FROM public.runs r WHERE r.id = NEW.run_id;
      IF NOT FOUND THEN RAISE EXCEPTION 'inbox item refers to a run that is not visible' USING ERRCODE = 'foreign_key_violation'; END IF;
      IF NEW.project_id IS NULL THEN NEW.project_id := run_project;
      ELSIF NEW.project_id IS DISTINCT FROM run_project THEN
          RAISE EXCEPTION 'inbox item project does not match its run' USING ERRCODE = 'check_violation';
      END IF;
      IF NEW.project_id IS NOT NULL AND current_user <> 'thinktin_worker' THEN
          RAISE EXCEPTION 'project fields in inbox_items are written by the server only' USING ERRCODE = 'insufficient_privilege';
      END IF;
  END IF;
  ```
- Update that test: the receipt fixture uses `run_id: None`. The "run deleted → `run_id` NULL, `project_id` kept" check at `:351-366` needs a project run (`copy_into_project`, `:1737`).

**B3. Passing the limit as bigint makes the function calls fail.**
- `project_runs(..., p_limit integer)` and `project_run_events(..., p_limit integer)`: sqlx sends the parameter types from the Rust values, and PostgreSQL has no implicit bigint→integer cast.
- Checked on PG 16.15: `ERROR: function pr(uuid, unknown, unknown, bigint) does not exist`.
- Bind `i32` (u32 has no Postgres encoder), or write `$4::int` / `$3::int` in the call.

**B4. Optional filters make every project-run read scan the whole project.**
- SQL-language functions are not inlined, and PG16 plans their bodies with generic parameters. So `(p_run IS NULL OR r.id = p_run)` and `(p_root IS NULL OR r.root_run_id = p_root)` cannot use an index.
- Checked: a point lookup and a tree lookup each did `Index Scan using runs_project_recent … Filter … Rows Removed by Filter: 199999`.
- `(p_before IS NULL OR r.id < p_before)` likewise scans everything newer than the cursor.
- Replace the one 6-argument function with three:
  ```sql
  project_run(p_project uuid, p_run uuid)        -- WHERE r.id = p_run AND r.project_id = p_project AND r.project_id IN (SELECT public.member_projects())
  project_run_tree(p_project uuid, p_root uuid)  -- WHERE r.root_run_id = p_root AND … ORDER BY r.created_at, r.id LIMIT 500   (runs_tree, 0001:263)
  project_runs(p_project uuid, p_instance uuid, p_before uuid, p_limit integer)
      -- WHERE r.project_id = p_project AND r.project_id IN (SELECT public.member_projects())
      --   AND r.id < coalesce(p_before, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)
      --   AND (p_instance IS NULL OR r.instance_id = p_instance)
      -- ORDER BY r.id DESC LIMIT least(greatest(coalesce(p_limit, 50), 1), 200)
  ```
- Checked: the `coalesce` form gives `Index Cond: ((project_id = $1) AND (id < COALESCE($2, …)))`. This is the same trick `list_runs` already uses (`runs.rs:499`).
- The 0055 REVOKE/GRANT/ALTER OWNER lines, test 1, and `ProjectTx` §2.2 item 5 change to match.

**B5. Some commits would not compile or pass as listed ("each commit compiles and passes").**
- **C4:** `NewArtifact` gains `project`, but the struct is built at `orchestrator/src/artifacts.rs:306` and `store/src/tests.rs:1686`. C4 does not list the orchestrator file, so the workspace build fails. Add `project: None` in C4.
- **C3, test 1:** it calls `project_runs()` and `project_run_events()`, which only exist after 0055 (C6). Move those assertions to C6.
- **C4, test 5:** "after leaving, the same append → 23503" depends on the tenant narrowing in 0055 (C6). At C4 the append succeeds.
- **Key fixtures:** "keys via `insert_project_key`" (C7) are used by tests 3 (C6) and 5 (C4). Either insert keys with raw worker SQL until C7, or move `project_key` / `insert_project_key` into C4.
- **Test 12:** "raw superuser SQL" cannot insert a project run, because `fill_space` lets only `thinktin_worker` write `project_id` (`0040:19-22`); a superuser gets 42501. Use `db.worker()`, as `join_raw` (`tests/projects.rs:31`) and `copy_into_project` (`:1737`) do.
- **Test 5:** "raw worker insert of an approval whose space disagrees" cannot be built, because the trigger overwrites the space (`NEW.project_id := NULL`, then derives it). Run `ALTER TABLE approvals DISABLE TRIGGER approvals_space` on the superuser pool first, expect `Invalid` (23503), then re-enable.
- **`api.rs:5020-5029`:** `:5020` is the creator's leave → 409, which must stay. Only `:5029` (DELETE of a shared project) changes. A 204 there would delete the project before the PATCH at `:5031-5039`, which expects 200. Move the delete to the end of the test, or into the new `deleting_a_shared_project_over_http`.
- **FFI `Run.project_id`:** it needs `#[uniffi(default = None)]` (precedent: `ffi.rs:448-449`, `wait_code`). Without it the Swift tests that build `ThinktinCore.Run(...)` without trailing defaulted fields stop compiling: `apps/apple/ThinktinKit/Tests/ThinktinCoreAdapterTests/ConversionTests.swift:18,51` and `CoreClient118Tests.swift:51`. C11 only covers Android.
- **`authors()`:** `m.left_reason = 'erased'` is NULL for live members, so decoding it as `bool` fails with "unexpected null". Use `coalesce(m.left_reason = 'erased', false)`.

## Important

**I1. Erase leaves the owner's private data on the project runs it keeps.**
- Before, `DELETE FROM runs` cascaded these tables; now project runs survive.
- `live_activities` (`0018:37`, holds `push_token`) is not in the erase list. Add `DELETE FROM live_activities WHERE user_id = $1` (uses `live_activities_user`, `0018:41`).
- `DELETE FROM approvals/tool_calls WHERE user_id = $1` scans whole tables: `tool_calls` has no `user_id` index (`0012`), and `approvals` only has the partial `approvals_pending` (`0001:346`). This happens while erase holds the users and project locks. Private runs already cascade, so use:
  - `DELETE FROM approvals WHERE run_id IN (SELECT id FROM runs WHERE user_id = $1 AND project_id IS NOT NULL)`
  - the same for `tool_calls` (its primary key starts with `run_id`).
- Kept whitelisted events still hold raw content:
  - `agent.tool_call` keeps `raw` and `title` (`proto/src/shim.rs:148-156`);
  - `run.state` keeps `reason`, `attempt` and `wait_code` (`executor.rs:1178-1185`);
  - `pipeline.step_started` keeps `run_id` and `instance_id` (`pipeline.rs:267`).

  projects-impl item 7 says keep only what other owners need. Scrub them, e.g. `UPDATE events SET payload = payload - 'raw' - 'title' WHERE instance_id IN (…) AND project_id IS NOT NULL AND kind IN ('agent.tool_call','agent.tool_call_update')`, plus the other kinds. This does not fire the space trigger, because `payload` is not in its column list. Also `UPDATE runs SET error = NULL, state_reason = NULL WHERE user_id = $1 AND project_id IS NOT NULL`.

**I2. Notices that 0055 hides still count in the push badge.**
- `unread_inbox_count` (`inbox.rs:180-190`, worker, no RLS) feeds the badge (`outbox.rs:557`).
- After 0055 a tenant can neither see nor mark read the non-receipt project notices of a left or deleted project.
- `cancel_project_member_runs` / `cancel_project_agent_runs` (`runs.rs:858,899`) and the new `cancel_project_runs` never call what `cancel_run_approvals` (`approvals.rs:183-200`) does. So pending approvals and their unread `approval` notices stay forever. This only bites once project runs execute (8.16+), but 0055's policy creates the problem.
- Fix: in `exit_member` and `stop_project`, run `UPDATE approvals SET state='cancelled', decided_by='system', decided_at=now() WHERE run_id IN (<cancelled>) AND state='pending'`. Then mark the affected users' non-receipt project notices read.
  - Delete and exit already lock those users (D3 step 1).
  - Archive locks only invitees, so either add the members to `also` or use `FOR UPDATE SKIP LOCKED`.

**I3. The role check in 0049 misses the dangerous direction.**
- If any service role were a member of `thinktin_project_definer` with inherit, it would get the definer's policies and column grants on `runs` and `events.payload`. That means raw events of every co-member's project runs.
- Add to the DO block:
  ```sql
  OR pg_has_role('thinktin_member', 'thinktin_project_definer', 'MEMBER')
  OR EXISTS (SELECT 1 FROM unnest(ARRAY['thinktin_app','thinktin_worker','thinktin_llmgw','thinktin_relay']) r
              WHERE pg_has_role(r, 'thinktin_project_definer', 'USAGE') OR pg_has_role(r, 'thinktin_member', 'USAGE'))
  ```
- Test 11 should also assert that the `pg_auth_members` rows for the definer are exactly the migration owner, with `inherit_option = false`.

**I4. The purge can get stuck and fail maintenance every round.**
- If anything remains, step 6 `DELETE FROM projects` hits the `runs_project_agent` NO ACTION FK (`0045:6-7`).
- The error goes through the `?` at `workers.rs:507`, so `maintain` fails on every round for that project.
- The inbox step's `SKIP LOCKED` can also skip rows that have no FK; they become orphaned and invisible.
- Gate step 6 on `NOT EXISTS (runs WHERE project_id=$1) AND NOT EXISTS (artifacts …) AND NOT EXISTS (non-receipt inbox_items …)`, checked without `SKIP LOCKED`.
- Build the try-lock key in Rust (`format!("project/{}", ProjectId(..))`, as `project_members.rs:544` does), not as `'project/'||id` in SQL.

## Simplifications and minor corrections

1. **Drop 0051.** 0050 already holds ACCESS EXCLUSIVE on approvals and artifacts (ADD COLUMN plus full-table UPDATE) with `runs` NO FORCE. Add `approvals_run_space` and `artifacts_run_space` valid in 0050, like `events_run_space`, and renumber 0052–0055 to 0051–0054.
2. **D18 count and header.** `queue_workspace_archive_purge` has four `blob_purge` references (`0023:39,42,47,53`), not three. The replacement must keep `SECURITY DEFINER`. Otherwise a tenant `DELETE FROM artifacts` fires the trigger as the invoker, and `thinktin_app` has no grant on `blob_purge` (`0007:36-38`).
3. **D16 scope.** It maps `Forbidden`→404 on every `/v1/projects/{id}/*` handler, including worker writes, so a missing production GRANT would become a silent 404. Apply `project_error` only to the `ProjectTx` handlers, or log at `error!` with a metric rather than `warn!`.
4. **Erase order.** The plan calls `cancel_user_runs` (D3 steps 8–9) before `stop_project` (step 7). That is safe only because erase already holds the project locks. Call `stop_project` for the created projects first.
5. **One membership rule.** `project_artifact_blob` repeats the membership check as a worker JOIN, beside `member_projects()`. 8.18's frozen-account rule would then have to be added in two places. Instead, `GRANT EXECUTE ON FUNCTION member_projects() TO thinktin_worker`, set `app.user_id` in the download transaction, and use `a.project_id IN (SELECT member_projects())`.
6. **Test 11's FORCE list.** `tests.rs:1024-1043` belongs to the 0039 copy test. `migrations_run_as_a_plain_owner` (`tests.rs:836-865`) already fails if any app-reachable table lacks FORCE. Drop that item.
7. **`check_roles`.** `pg_has_role(session_user, r, 'SET')` raises 42704 when a role is missing, so the friendly `Error::Schema` message never appears. Check `pg_roles` first, via a CASE.
8. **`events_after` / `event_range`.** They are `impl<R>` (`events.rs:37,76,96`), so the private-only filter also applies to worker callers. Today those are tests only; move them to `impl Tx<Tenant>`.
9. **Hard-coded receipt subtypes.** The list in the inbox policy (and the purge, and the Rust constant) means every 8.19 receipt needs another `ALTER POLICY`. Optional: an IMMUTABLE `public.project_receipt(text) RETURNS boolean`, used by the policy and the purge.
10. **Add to §8 (8.16).** projects-impl item 7 says every decrypt and every event append checks project status. `fill_space_from_run` does not; 8.16 must add it before lifting the claim guard.
11. **Line references.** D3 is at `projects-8.14-plan.md:17`, not `:13`; the 8.19 bullet is at `:843`, not `:844`.

## Checked and correct
- **sqlx and PostgreSQL behaviour:**
  - `Pool::begin_with` exists (sqlx-core 0.9 `pool/mod.rs:391`), and `&'static str` implements `SqlSafeStr`.
  - A policy can reference a column the role cannot select, while selecting that column still gives 42501 (re-checked, V3).
  - The `jsonb_array_elements(...) AS x` idiom works.
- **The plan's reasons hold:**
  - Forbidden → 500 today (`gateway/error.rs:93`).
  - Tenant delete is dead code (`projects.rs:523`, `teams.rs:84`; only tests call it).
  - No `v*` tag exists.
  - `pg_database_owner` lets the owner grant CREATE on `public` in tests and in prod (`deploy-checklist.md:58`).
  - Every Row query in `runs.rs` goes through `columns!()`.
  - The blob key `projects/<p>/<a>` passes the key check at `artifacts.rs:76-91`.
  - Aliyun KMS accepts any context string (`aliyun/kms.rs:39-41`).
- **Locks:** delete, archive and publish follow D3, and purge vs erase cannot deadlock (purge only try-locks and never takes users rows).
