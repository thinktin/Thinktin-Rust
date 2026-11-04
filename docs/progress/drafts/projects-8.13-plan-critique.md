# 8.13 方案评审（原始结果，2026-11-04）

workflow `projects-8-13-plan` 的第三步：对草稿（`projects-8.13-plan-draft.md`）逐条核对代码。英文原样。

Corrections to the 8.13 plan, most severe first. Each has the reason (with file:line) and replacement text. I changed no repo files; the two PostgreSQL checks ran in throwaway databases on local PG 16.15, which I dropped afterwards.

1. **Missing index for the new run_grants → project_agents foreign key (High).**
   - Reason: 0044 adds `run_grants_project_agent (project_id, instance_id, user_id) → project_agents` with NO ACTION. Every deleted project_agents row then triggers a lookup: `SELECT 1 FROM ONLY run_grants WHERE project_id=$1 AND instance_id=$2 AND user_id=$3 FOR KEY SHARE`.
     - Rows get deleted by `delete_solo_project` (cascade projects → project_members → project_agents), by erase's `DELETE FROM projects WHERE creator_id`, and by the instances cascade.
     - The only other run_grants index is `run_grants_instance (instance_id) WHERE revoked_at IS NULL` (0001_init.sql:174), which this query cannot use. Result: one sequential scan of run_grants per deleted agent row.
     - 0043 covers `runs` only.
   - Corrected text: add a file after 0043 and renumber the old 0044 to 0045. `0044_run_grants_project_index.sql`:
     ```
     -- no-transaction
     CREATE INDEX CONCURRENTLY run_grants_project ON run_grants (project_id, instance_id, user_id) WHERE project_id IS NOT NULL;
     ```
     Extend test #7's EXPLAIN check to this lookup.

2. **0044 validates in the same transaction that adds the constraints (High).**
   - Reason: `ADD CONSTRAINT … UNIQUE USING INDEX` takes ACCESS EXCLUSIVE, and `ADD FOREIGN KEY … NOT VALID` takes SHARE ROW EXCLUSIVE, on runs, run_grants and project_agents. Both locks are held until COMMIT.
     - So the five `VALIDATE CONSTRAINT` statements run with runs and run_grants write-blocked. `runs_parent_space` and `runs_grant_space` look up every existing child or grant.
     - NOT VALID followed by VALIDATE only helps when they are in separate transactions. As written, 0044 cancels the point of 0041–0043.
     - The `USING INDEX` step is also unnecessary. PostgreSQL accepts a foreign key to columns covered by a plain unique index; verified on PG 16.15 (an FK to `CREATE UNIQUE INDEX p_id_space ON p (id,k,s)` was created).
   - Corrected text:
     - `0045_run_space_keys.sql`: only the five `ADD CONSTRAINT … NOT VALID`; drop both `UNIQUE USING INDEX` lines.
     - New `0046_validate_run_space_keys.sql`: the five `VALIDATE CONSTRAINT` statements.
     - Alternative, since there is no production data: one file with no NOT VALID/VALIDATE, with a comment that this is acceptable only before launch.

3. **CREATE INDEX CONCURRENTLY files deadlock with a second migrator and leave an invalid index (High; ops and docs).**
   - Reason: reproduced on PG 16.15.
     - Session A holds `pg_advisory_lock(42)` and runs CREATE INDEX CONCURRENTLY. Session B is blocked in `SELECT pg_advisory_lock(42)` and holds a snapshot.
     - A fails with "deadlock detected … waits for ShareLock on virtual transaction … blocked by process B", and the index is left `indisvalid = f`.
     - sqlx 0.9 does exactly this. sqlx-postgres-0.9.0/src/migrate.rs:198 takes a session advisory lock. Lines 231-232 run no-transaction files outside a transaction, and lines 315-338 record the `_sqlx_migrations` row only on success. A rerun then fails with "relation runs_id_space already exists".
     - This contradicts deploy/k8s/migrate/job.yaml:7 and crates/store/src/schema.rs:95, which both say "多个副本同时执行时由 sqlx 的咨询锁串行化".
   - Corrected text, in C7: add to the CREATE INDEX CONCURRENTLY bullet in docs/release.md §3, and fix the schema.rs:95 and job.yaml:7 comments:
     > 带 `-- no-transaction` 的迁移只能由一个迁移进程执行（迁移 Job；`migrate_on_start` 不能在多个副本上同时开）：别的进程等 sqlx 咨询锁时持有快照，CREATE INDEX CONCURRENTLY 等它会死锁，留下无效索引。失败后先 `DROP INDEX CONCURRENTLY IF EXISTS <索引名>;` 再重跑。

4. **The project_agents CHECK will break tenant `delete_instance` once `dedicated` is used (Medium).**
   - Reason: the plan's `delete_instance` (a `Tx<Tenant>` call) sets `is_lead = false, left_at = now()`. The tenant has no UPDATE grant on `dedicated`.
     - Any dedicated agent in an unshared project therefore violates `CHECK (left_at IS NULL OR NOT (is_lead OR dedicated))`. That is 23514, mapped to 422 on `DELETE /v1/instances/{id}` (gateway/src/routes/instances.rs:383).
     - The `project_agent_dedicated` index already ignores rows that have left.
   - Corrected text: `CHECK (left_at IS NULL OR NOT is_lead)` (the form in design A).

5. **Test #8 never reaches the project step (Medium; atomicity).**
   - Reason: `harness: "no-such-harness"` fails in `control::resolve` (control/src/lib.rs:244-247) during member 2's `adopt_in`. That is before `create_team`, so asserting "0 project rows" proves nothing. No test makes adoption fail inside the project write.
   - Corrected text: add a second template `[{claude, 主编, lead}, {claude, 写手, lead}]`. `create_template` does not count leads (gateway/src/routes/teams.rs:118-160).
     - Adopt then returns 422 "a team has at most one lead" from `create_team`/`check_agents`. By then two instances, two grants, two `instance.adopt` audit rows and two `instance.state` events have been written.
     - Assert all of those are 0, `projects`, `project_members` and `project_agents` are 0, and `GET /v1/teams` returns `[]`.
     - Keep the harness case as the gate before the read switch.

6. **Test #2 seeding must use raw SQL (Medium).**
   - Reason: at `up_to(38)` there is no `projects` table. From C5 on, `Tx<Tenant>::create_team` and `create_team_template` write `projects` and `project_templates`, so the test would fail with 42P01.
   - Corrected text: "Seed `teams`, `team_members` and `team_templates` with raw INSERTs on `t.db.pool()`. Create instances with `create_instance` or raw SQL, and soft-delete D with raw `UPDATE instances SET state='deleted', deleted_at=now()`."

7. **§8 sequencing: project tagging on events, approvals and inbox is needed before project runs execute (Medium).**
   - Reason: two impl requirements need it:
     - impl item 2: "tenant 查看自己实例历史时亦受成员状态约束；退出后不能从旧接口旁路读取".
     - impl 8.14–8.16: "单独验证旧客户端不会把项目事件保存到私人缓存".
     - Both need project-run events tagged from the first project run, which happens once 8.16 lifts the claim guard.
     - Today `events` has only a `(run_id, user_id)` FK (0001_init.sql:280-281) and a user_id-only tenant policy (0001_init.sql:436). A member who leaves would keep reading project-run events through `/v1/instances/{id}/events`.
   - Corrected 8.15 row: "Add `events.project_id`, `approvals.project_id` and `inbox_items.project_id`, filled by a BEFORE INSERT trigger from `runs.project_id` so older writers are covered. Narrow the tenant policies on these tables by live membership. Must ship before 8.16 lifts the claim guard." Move "Event space consistency" out of 8.19 and the approvals space columns out of 8.18; keep only the consistency keys there.

8. **D4 needs an explicit precondition (Medium; compatibility).**
   - Reason: release.md §3 requires the previous binary to keep working during rollout and rollback. With frozen `teams`, a team adopted through an old replica after 0039 creates instances plus a `teams` row the new binary never reads. Those are orphan instances, which projects-impl "旧版领养" forbids. It is safe today only because nothing is deployed: there is no `v*` tag, and RDS is not created yet (docs/handoff.md:131).
   - Corrected text, in D4 and the 0039 header:
     > 前提：0039 在第一次部署之前发布。若已有部署过 ≤0038 的库，同一版要补拷（`INSERT … SELECT … FROM teams ON CONFLICT (id) DO NOTHING`，成员、模板同理）或改成双写一版。

9. **The `fill_space` tenant guard should be an allowlist (Low-Medium; RLS).**
   - Reason: impl item 3 says only the worker writes project runs and grants. `current_user = 'thinktin_app'` lets every other role through, including the owner and the 8.15 roles.
   - Corrected text:
     ```
     IF NEW.project_id IS NOT NULL AND current_user <> 'thinktin_worker' THEN RAISE EXCEPTION 'project rows in % are written by the server only', TG_TABLE_NAME USING ERRCODE = 'insufficient_privilege'; END IF;
     ```
     Test #7 already inserts project rows through `w.conn()`.

10. **Erase: statement order and pending phone invites (Low).**
    - Reason: the plan does not say where the new statements go, and `runs_project_agent` is NO ACTION. The phone number is overwritten at users.rs:226, and pending phone invites with `invitee_id` NULL would keep the erased user's E.164 number.
    - Corrected text: put the five statements after `DELETE FROM runs WHERE user_id = $1` (users.rs:198) and before `UPDATE instances …` (users.rs:224). Change the invite delete to:
      ```
      DELETE FROM project_invites WHERE inviter_id = $1 OR invitee_id = $1 OR invitee_phone = (SELECT phone FROM users WHERE id = $1)
      ```

11. **Commit-sequence fixes (Low).**
    - Test #1 in C1 checks the owner of `projects`, which 0039 only creates in C3. Corrected text: in C1, test #1 checks `runs` and `_sqlx_migrations`; C3 adds `projects` and the FORCE flags of the six new tables.
    - "C7 is independent of C3–C6" is wrong. 0044 references `project_agents` from 0039, the numbering continues from 0039, and test #7 needs `project_agents` rows. Corrected text: "C7 depends on C3 only; it can be a separate PR stacked on C3."

12. **0039 lock order (Low; no traffic yet).**
    - Reason: NO FORCE takes ACCESS EXCLUSIVE, held to commit, on teams, team_members and team_templates, then instances. App transactions touch instances first (`create_team` calls `instance()`, then inserts members whose FK locks instances). The opposite order can deadlock-abort the migration during a rollout.
    - Corrected text: run `ALTER TABLE instances NO FORCE ROW LEVEL SECURITY;` first, then teams, team_members, team_templates.

13. **Forward columns on the new tables are inconsistent (Low).**
    - Reason: the plan pre-adds 8.16/8.18 columns (`dedicated`, `allow_computer`, budgets) but not design A's:
      - `projects.policy`, which projects.md §7 needs: 项目运行范围 = 项目给的 ∩ 主人给的;
      - `project_agents.preauthorized_tools`;
      - `project_agents.approval_timeout_secs`.
    - Adding columns to these new, tiny tables later is cheap, so the point is to pick one rule.
    - Corrected text: either add `policy jsonb NOT NULL DEFAULT '{}'::jsonb` to projects, and to project_agents `preauthorized_tools text[] NOT NULL DEFAULT '{}'` and `approval_timeout_secs integer NOT NULL DEFAULT 86400 CHECK (approval_timeout_secs BETWEEN 60 AND 604800)`; or drop `allow_computer` and the budget columns until 8.18.

14. **Optional: columns and an index that 8.15/8.17/8.18 will need on runs and run_grants (Low).**
    - Reason: design A §2.3 has `runs.requested_by` and §4.2 has `run_grants.via_grant_id` (impl item 3: "授权与项目两侧任一祖先撤销均失效"). 8.15's project run list needs `runs (project_id, id DESC) WHERE project_id IS NOT NULL`, which otherwise costs another CREATE INDEX CONCURRENTLY file.
    - Corrected text: in 0040, `ADD COLUMN requested_by uuid` on runs and `ADD COLUMN via_grant_id uuid` on run_grants, nullable, no FK. In §8, note that 8.15 adds the list index. Optional, because 8.17 alters runs anyway.

15. **Wrong citation (Low).** D1 cites tools/ci/check_migrations.py:29, which is the filename regex. The contiguity check is at line 318.

16. **Over-engineering for 8.13 (optional trims).**
    - The 0044 `UNIQUE USING INDEX` step (see 2).
    - `shared_at` and the `project_members_share` trigger. No 8.13 code path can make a project shared, so 8.14 could add both together with the policy change. Keep them only if 8.13's policies should be final.
    - `ProjectRole`, `my_project_agents` and the `ProjectRecord` fields `goal`, `status` and `shared` have no 8.13 caller.
    - The `NOT dedicated` and `status='active' AND shared_at IS NULL` terms in the WITH CHECK clauses repeat what the column grants already enforce. Harmless.
    - The `project_keys` comment "业务角色没有任何权限" contradicts the grant to thinktin_worker. Reword: "thinktin_app、thinktin_llmgw 没有权限；只有 worker（8.15 建密钥、删项目）".

17. **Docs rule (Low).** Add to docs/release.md §3: "回填受 FORCE 约束的表要在同一事务里 NO FORCE / FORCE". The earlier `UPDATE run_grants` backfills would have done nothing for an owner bound by FORCE: 0024_peers.sql:13, 0025_board.sql:43, 0026_ask.sql:16, 0036_search.sql:22, 0038_browser.sql:20. That is harmless today because every database is empty.

**Checked and correct as written:**
- **0001/0014 fix is needed.** On PG 16.15, a NOCREATEROLE login running `CREATE ROLE` for a role that already exists fails with 42501 (user.c:317) before the duplicate check. So 0001_init.sql:16-18 breaks the deploy-checklist.md:56-60 flow, and D8 requires the fix.
- **sqlx support.** sqlx 0.9 has `Migrator::run_to` (sqlx-core migrator.rs:185) and honours `-- no-transaction` (source.rs:234).
- **Adoption is atomic.** It is one `Tx<Tenant>` (teams.rs:191-224), and `control::insert` (lib.rs:267-293) writes the instance, event and audit row in the caller's transaction.
- **0040 backfill fires no other triggers.** The only existing triggers are on artifacts and instances (0007:47, 0023:59), none on runs or run_grants.
- **Claim paths are complete.** The only claim and takeover queries are runs.rs:880, 997, 1295 and 1428; `acquire_lease` is used only in tests.
- **Other cited line numbers match HEAD:** teams.rs, instances.rs, users.rs, grants.rs, executor.rs, delegate.rs, store and gateway tests, client.rs:1641.