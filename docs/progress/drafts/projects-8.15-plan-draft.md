# 8.15 方案草稿（workflow `projects-8-15-plan`，2026-11-05，评审之前）

英文原样。

# WP 8.15 implementation plan: the cross-user data boundary

8.15 covers row-level security for project tables by membership, member-readable project runs, project keys and project artifacts, and "leaving makes it invisible at once".

- **Branch:** `claude/determined-lovelace-vn0j5h` at `995819c`, clean tree.
- **Migrations:** the last one is `0048_project_invite_sends.sql`, so this package uses **0049–0055**.
- **Precondition (0039:6-8):** nothing is deployed yet. There is no `v*` tag, so `tools/ci/check_migrations.py:323-325` checks only file names. Every statement that would be flagged after a tag still gets a `-- deploy-safe:` note.

**Checked on a scratch PostgreSQL 16.15 database.** Production is RDS PG16 (`docs/deploy-checklist.md:18`) and CI is `postgres:16`. I created and dropped the scratch database and roles; no repo files were touched.

| # | Behaviour | Result |
|---|---|---|
| V1 | `ADD FOREIGN KEY … NOT VALID` on the partitioned `events` table | Fails: "cannot add NOT VALID foreign key on partitioned table". A valid FK works. |
| V2 | BEFORE ROW trigger on the `events` parent | Cloned to existing and future partitions. |
| V3 | Policy that references a column the role has no SELECT on (own table) | Works. Selecting that column still gives 42501. |
| V4 | Forged `app.project_id` setting, or a project id passed as a parameter | Reads 0 rows; `member_projects()` returns only the real memberships. |
| V5 | Tenant policy `user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects()))` | Hides the project row right after `left_at` is set. The plan shows a hashed SubPlan, evaluated once per query. |
| V6 | `ALTER FUNCTION … OWNER TO thinktin_project_definer` run by the migration owner | Needs the owner to be able to SET ROLE to it, and the new owner to hold CREATE on `public` (else "permission denied for schema public"). The temporary-CREATE recipe in D2 works. `GRANT … TO owner WITH INHERIT FALSE, SET TRUE` is enough to change ownership, and the owner does not inherit the definer's privileges (`pg_has_role(...,'USAGE') = f`). |
| V7 | `pg_advisory_xact_lock` inside `BEGIN READ ONLY` | Allowed. |
| V8 | The `project_runs` / `project_run_events` bodies below | Compile. `thought` and `raw` are dropped, and `waiting_quota` becomes `waiting_owner`. |

---

## 0. Decisions

**Scope.**

*In 8.15:*
- the roles `thinktin_member` and `thinktin_project_definer`;
- `ProjectTx` and the switch of the 8.14 project reads to it, with the same JSON;
- member policies on project tables, plus the directory rows (names, agents);
- a space (project or private) on events, approvals and artifacts;
- tenant policies that hide project rows after leaving, plus private-only tenant lists;
- `inbox_project_guard` deriving the project from the run;
- member read model: project runs, a whitelisted event view, project artifacts;
- project DEK, project artifact publish/read/download;
- archive, unarchive, and soft delete of all projects;
- bounded cleanup of deleted projects;
- erase switching to soft delete;
- 42501 → 404 on project paths;
- `/v1/project-templates*`;
- client-core FFI and per-project cache forget.

*Deferred:*
- **8.16:** session/workspace isolation per (instance, project), dedicated instances, lifting the claim guard and the leak fixes that must precede it (§8).
- **8.17:** dispatch, project grants, lead changes, project board, cross-owner trees, project-wide artifact tool scope.
- **8.18:** llm-gw budgets, approvals to the owner, per-project vault/computer.
- **8.19:** full notification set and the project feed (`project_seq`).

Nothing in 8.15 lets project runs execute: the claim guard (`runs.rs:204-206`) stays. Tests seed project rows with worker SQL, as 8.14 did (`tests/projects.rs:31-58`).

| # | Decision | Why / evidence |
|---|---|---|
| D1 | **Two new NOLOGIN NOBYPASSRLS roles.**<br>• `thinktin_member`: used by `ProjectTx`. No default grants.<br>• `thinktin_project_definer`: owns every SECURITY DEFINER function. NOINHERIT, member of nothing.<br>**Who creates them:** the high-privilege account pre-creates both. The migration creates them only if missing, using the 0001 pattern.<br>**Memberships:** `GRANT thinktin_project_definer TO <migration owner> WITH INHERIT FALSE, SET TRUE`; `GRANT thinktin_member TO thinktin_server_login`. | • projects-impl item 2 (`projects-impl.md:19`).<br>• The owner has no CREATEROLE (`0001:8-10`, `testing.rs:95-97`).<br>• A role that inherits `thinktin_app` gets its `TO thinktin_app` policies (db-roles map), so the member role must stay outside app and worker. V6. |
| D2 | **Definer functions are locked down:**<br>• `SET search_path = pg_catalog, public, pg_temp` and `public.`-qualified names (as `0040:8`, `0047:56`);<br>• no free-form inputs (only uuid/int, limits clamped in SQL);<br>• `REVOKE ALL … FROM PUBLIC`;<br>• **all GRANTs come before `ALTER … OWNER TO`**: the ACL moves with ownership, and with INHERIT FALSE the migration owner cannot grant afterwards.<br>**Ownership change:** `GRANT CREATE ON SCHEMA public` to the definer just for that statement, then revoke it.<br>**Changing one later:** `GRANT CREATE` → `SET LOCAL ROLE thinktin_project_definer` → `CREATE OR REPLACE` (repeat the `SET search_path`) → `RESET ROLE` → `REVOKE`. | V6. `CREATE OR REPLACE` replaces the SET clause (db-roles map §5). |
| D3 | **Membership comes only from `app.user_id`.** A zero-argument definer function `member_projects()` returns the projects where I am a live member, the project is `active`/`archived`, and my user is not deleted.<br>• Every member and tenant policy uses `project_id IN (SELECT member_projects())`.<br>• There is no project setting. Functions take `p_project`, but it is always intersected with `member_projects()`.<br>• The definer can see only its **own** `project_members` and `users` rows. That breaks the recursion that member policies on `projects` ⇄ `project_members` would cause. | projects-impl item 2 ("手动设置另一个项目 ID 也读不到"). `app_user_id()` trusts whoever opens the transaction (`0001:22-25`). The tenant cannot see joined projects (`0039:181`). V4, V5. |
| D4 | **`ProjectTx` is its own type, not `Tx<R>`.**<br>• Opened by `Db::member(user)` with `BEGIN ISOLATION LEVEL REPEATABLE READ, READ ONLY`.<br>• Sets `role = thinktin_member`, `app.user_id` and `statement_timeout = 15s`.<br>• It has only the narrow read methods of §2.2 and `finish()` (rollback).<br>• 25006 maps to `Error::Forbidden`. | The generic `impl<R> Tx<R>` blocks contain writes and locks: `append_event` (`events.rs:37-73`), `insert_inbox` (`inbox.rs:100`), `lock_project` (`projects.rs:57-63`), `advisory_lock` (`project_invites.rs:158-167`), `revoke_*_grants`, `plans.rs:422`, and others. V7: advisory locks are allowed in READ ONLY. A separate type makes "narrow" a compile-time fact. `sqlx 0.9 Pool::begin_with` exists (sqlx-core `pool/mod.rs:391`). |
| D5 | **Directory rows (D9 of 8.14) come from member policies plus column grants**, so the SQL stays almost unchanged and the JSON is identical:<br>• projects (no budget columns);<br>• project_members (`left_reason` included, so the DTO can show "已注销");<br>• project_agents (no `allow_computer`, no `consented_at`);<br>• users `(id, display_name)`, only for **live** co-members, so left and erased members are anonymous;<br>• instances `(id, user_id, agent_id, name)`, only live agents of readable projects whose instance is not deleted. `state` is **not** granted (running/paused would leak private activity); the policy does the `state <> 'deleted'` filter.<br>Budgets come from `my_project_budget(p)` (definer, own row). | Same JSON shape as now (`projects.rs:133-142, 258-351`). `domain.rs:1026-1108`. projects-impl item 4: budgets belong to each owner. V3. |
| D6 | **Run and event content is readable only through two definer functions, `project_runs()` and `project_run_events()`.** They project a whitelist in SQL.<br>• `thinktin_member` has **no** grant on runs, events, approvals, tool_calls, usage_records, credentials, model_routes, vault_*, devices, device_*, user_keys, project_keys, project_invites, board_posts, inbox_items, plans or outbox.<br>• New event kinds and states fail closed: an unknown kind is dropped, an unknown state becomes `running`. | projects-impl item 6: a DTO per event kind, never raw args/output, thinking, private approvals or instance seq. The private/safe field split is in the runs-events map §7. V8. |
| D7 | **Member event view = the newest ≤500 whitelisted events of one run, oldest first, with `truncated`.**<br>• No `seq` and no cursor in 8.15.<br>• The live project feed with its own cursor is 8.19.<br>• Clients refetch to refresh. | The per-instance seq shows gaps, i.e. other activity on the instance (item 6). A per-run ordinal would shift when partitions are dropped (`0001:304`). |
| D8 | **`events`, `approvals` and `artifacts` get `project_id`, `space_kind` and `space_id`.**<br>• A BEFORE INSERT trigger `fill_space_from_run()` fills them from the run, as visible to the caller.<br>• They are frozen on UPDATE.<br>• A composite FK `(run_id, space_kind, space_id) → runs (id, space_kind, space_id)` (unique index `0041:3`) keeps them consistent. The old `(run_id, user_id)` FKs stay.<br>• If a tenant cannot see the run (a left project), it derives "private", and the FK rejects the row with 23503.<br>• The `events` FK is added valid, with `runs` NO FORCE in the same transaction (PG16 cannot do NOT VALID on a partitioned table). The approvals/artifacts FKs are NOT VALID, then VALIDATEd in 0051 with NO FORCE (0045/0046 pattern). | projects-impl item 1 ("保留审批与事件原来的 (run_id,user_id) 约束，再加 scope 一致性约束"). V1, V2. Under FORCE the owner's FK check sees nothing (`0046:1-2`, `release.md:54-57`). |
| D9 | **Narrowed tenant policies (`ALTER POLICY tenant … USING`):**<br>• runs, run_grants, events, approvals: private rows, plus project rows only while I am a live member;<br>• artifacts: **private only**;<br>• inbox_items: private, plus receipts by `subtype`, plus project notices while I am a live member.<br>WITH CHECK is unchanged.<br>**Tenant lists also filter `project_id IS NULL`** (instance and user run lists, the instance event page/WS, `event_range`), so old clients never write project rows into their per-instance cache.<br>Point reads (`GET /v1/runs/{id}`, `/tree`, `/cancel`, approvals) still show my own project runs while I am a member. | • projects-impl item 2: the owner's own history follows membership, and old routes cannot read around a leave.<br>• projects-impl "迁移与放量" 8.14–8.16: old clients must not cache project events.<br>• Today `tenant` is `user_id` only (`0001:438`, `0002:103`).<br>• Receipts are exempted by subtype, never by `run_id IS NULL` (`0047:52-54`; `0001:381` SET NULL).<br>• Client cache: `cache.rs:23-39`, `client.rs:111-145`. |
| D10 | **`inbox_project_guard` (CREATE OR REPLACE):** when `run_id` is set, it reads the run as the caller.<br>• Run not visible → 23503.<br>• `project_id` absent → derived from the run.<br>• Supplied value differs → 23514.<br>• The worker-only rule for project fields stays (`0047:67-71`), so a tenant notice about any project run gets 42501. | 8.14 plan §9 (`projects-8.14-plan.md:819`). Tenant notice callers are `tools.rs:187`, `vault.rs:167`, `gateway/routes/plans.rs:358`. |
| D11 | **Every `DELETE /v1/projects/{id}` is a soft delete, shared or not.** It is one short worker transaction in D3 lock order:<br>1. users;<br>2. project lock;<br>3. my member row;<br>4. status `deleted`;<br>5. `DELETE FROM project_keys`;<br>6. revoke pending invites;<br>7. lock project_agents and mark them left;<br>8. cancel project runs (lock runs → bump epochs → cancel);<br>9. revoke project grants;<br>10. `project_deleted` receipts to the live members locked in step 1.<br>**Cleanup** is bounded, retryable and try-lock only; it starts 10 minutes after the delete and finally hard-deletes the row.<br>**Status codes:** `/v1/teams/{id}` DELETE keeps 409 on shared projects. Tenant `DELETE` on projects is revoked. | • projects.md §4.6; projects-impl item 7 and test 4.<br>• `runs_project_agent` is NO ACTION (`0045:6-7`), so a hard cascade is impossible once runs exist.<br>• 8.14 D10/D12 (`projects-8.14-plan.md:24,26`).<br>• Tenant delete is dead code (`projects.rs:522-533`, `teams.rs:84-86`, only tests call it), yet still granted (`0039:187-188,214`). |
| D12 | **Archive and unarchive: creator only.**<br>• Archive: status `archived`, revoke invites, cancel project runs, revoke grants. Agents stay. No new keys, artifacts or invites.<br>• Unarchive: status `active` again.<br>• `GET /v1/projects` now lists archived projects too; `status` already carries it, so the shape is unchanged.<br>• Members can still read an archived project and leave it (`project_members.rs:302`). | projects.md §4.6 "归档（只读）"; projects-impl test 4 "归档恢复". The list is `active` only today while detail allows archived (`projects.rs:262,278`); now one rule. |
| D13 | **Erase:**<br>• soft-deletes the projects the user created, with **no receipts in 8.15** (8.19);<br>• cancels all of the user's runs and deletes only **private** runs;<br>• deletes all of the user's approvals and tool_calls;<br>• deletes non-whitelisted events of the user's project runs;<br>• keeps the user's project runs, whitelisted events and project artifacts in other people's projects (owner shown as "erased"). | • projects.md §10; projects-impl item 7.<br>• The erase SQL to change is at `users.rs:218,220,248`.<br>• **Receipts:** writing other members' inboxes during erase takes KEY SHARE on their user rows after the project locks, which deadlocks with their own erase (D3 order; cf. the 8.14 two-erase deadlock, `projects-impl.md:103-104`). |
| D14 | **Project DEK.**<br>• KMS context and AAD subject `project:<uuid>` (no keyvault change).<br>• Created lazily on first publish: KMS wrap **outside** any transaction, then `insert_project_key` under `lock_project` while active, `ON CONFLICT DO NOTHING`, winner re-read.<br>• Every read fetches the wrapped key with a status check in the same SQL.<br>• Destroyed in the delete transaction.<br>• Unwrapped only by the api and worker processes; llm-gw never gets a grant.<br>• Blob key `projects/<p>/<a>`. | • `Kms` context is a plain string (`keyvault/lib.rs:62-68`); a UUID never starts with `project:`.<br>• `user_vault` holds a transaction across KMS (`orchestrator/artifacts.rs:177-186`).<br>• The FK takes only KEY SHARE on projects, so the lock is needed (keys-artifacts map D.1).<br>• `CachingKms` entries are unreachable without the wrapped bytes (`keyvault/lib.rs:212-225`). |
| D15 | **Project artifacts only on `/v1/projects/{id}/artifacts*`.**<br>• The download re-checks membership, status and key in one worker SQL, then decrypts.<br>• Tenant artifact routes become private-only (policy), so an author who left cannot list, download or DELETE.<br>• Deleting project artifacts happens only in cleanup. | projects.md §5 (项目产出物); keys-artifacts map B/D.2. Tenant SELECT/DELETE today: `0002:103,109`. |
| D16 | **Gateway on project paths:** `store::Error::Forbidden` (42501, and 25006 via D4) → 404, logged at warn. The new routes are not behind `cross_user_projects`: solo projects use them, and nobody can join while it is off. | `gateway/src/error.rs:93` sends Forbidden to 500 today; 8.14 plan §9 (`:818`); 8.14 D13. |
| D17 | **`/v1/project-templates*` aliases `/v1/team-templates*`** (same handlers, same JSON). Adopt returns `201 ProjectDetail`. | 8.14 D16 and its open question (`projects-8.14-plan.md:30,920`). |
| D18 | **Harden the two legacy purge definer functions** (`queue_artifact_blob_purge` `0007:40-46`, `queue_workspace_archive_purge` `0023:31-58`) with `SET search_path = pg_catalog, public, pg_temp` and `public.blob_purge`. | The db-roles map reproduced a temp-table shadow of `blob_purge`. Project cleanup relies on that queue. |
| D19 | **Startup role check:** `Db::check_roles()` next to `check_migrations` (`server/src/lib.rs:57`). The service login must be able to `SET ROLE` `thinktin_app`, `thinktin_worker` and `thinktin_member`. | The test pool is a superuser (`testing.rs:12-13`), so tests never catch a missing production GRANT. |
| D20 | **`Run.project_id: Option<ProjectId>`** is added (serde default, skipped when none) and selected by `runs.rs` `columns!()`.<br>• client-core `put_runs` skips project runs.<br>• `Cache::forget_project` runs on leave, on removal/delete receipts, and on project 404s. | `columns!` omits it today (`runs.rs:192-199`); `put_runs` (`cache.rs:156-172`); projects-impl:14 ("清除可撤回的本地缓存"). |
| D21 | **`project_deleted` receipt** (Info subtype) in 8.15. `project_archived` and the rest wait for 8.19. | 8.14 plan §9 (`:820`) puts `project_deleted` in 8.15; 8.19 has the full set (`:844`). |
| D22 | **Invite previews stay worker reads** filtered by phone or token hash. The creator's invite list stays a worker read. | Their readers are not members (`project_invites.rs:144-156, 468-498, 668-721`); a definer keyed by token adds surface for no gain. |

---

## 1. Migrations

### 1.1 `0049_project_member_role.sql` (one transaction)

```sql
-- 项目的成员读（WBS 8.15，docs/projects.md 第 5、9 节，docs/projects-impl.md 第 2 条，progress/drafts/projects-8.15-plan.md）。
-- 两个新角色由高权限账号预先建好（属主没有 CREATEROLE，docs/deploy-checklist.md 第 3 节），这里按名字先查：
--   thinktin_member          ProjectTx 用：默认对业务表没有权限，只有下面列出的列；行只放行“我是存活成员、项目没删”。
--   thinktin_project_definer SECURITY DEFINER 函数的属主：NOLOGIN、NOBYPASSRLS、不是任何角色的成员，自己也受行级安全
--                            约束（只看得到自己的成员行、用户行）。迁移账号是它的成员（WITH INHERIT FALSE, SET TRUE）：能把
--                            函数交给它，又不继承它的权限。
-- 成员关系只按 app.user_id 算（member_projects() 没有参数）：手动传别的项目 id、设 app.project_id 之类的都读不到。
-- 定义者函数：search_path 固定、表名带 public.、撤销 PUBLIC 的 EXECUTE；先授权、再改属主（ACL 跟着过去，迁移账号不继承
-- 新属主，改完就授不了权）。以后要改：GRANT CREATE → SET LOCAL ROLE thinktin_project_definer → CREATE OR REPLACE（重写
-- SET search_path）→ RESET ROLE → REVOKE CREATE。
-- 前提同 0039：第一次部署之前发布。

DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_member') THEN CREATE ROLE thinktin_member NOLOGIN NOBYPASSRLS; END IF; EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_project_definer') THEN CREATE ROLE thinktin_project_definer NOLOGIN NOBYPASSRLS NOINHERIT; END IF; EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $$;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname IN ('thinktin_member', 'thinktin_project_definer')
                 AND (rolsuper OR rolbypassrls OR rolcanlogin OR rolcreaterole OR rolcreatedb))
       OR pg_has_role('thinktin_member', 'thinktin_app', 'MEMBER')
       OR pg_has_role('thinktin_member', 'thinktin_worker', 'MEMBER')
       OR pg_has_role('thinktin_project_definer', 'thinktin_app', 'MEMBER')
       OR pg_has_role('thinktin_project_definer', 'thinktin_worker', 'MEMBER')
       OR pg_has_role('thinktin_project_definer', 'thinktin_member', 'MEMBER') THEN
        RAISE EXCEPTION 'thinktin_member and thinktin_project_definer must be NOLOGIN NOBYPASSRLS and members of no service role';
    END IF;
    IF NOT pg_has_role(current_user, 'thinktin_project_definer', 'SET') THEN
        RAISE EXCEPTION 'grant thinktin_project_definer to the migration owner WITH INHERIT FALSE, SET TRUE (docs/deploy-checklist.md section 3)';
    END IF;
END $$;
GRANT USAGE ON SCHEMA public TO thinktin_member, thinktin_project_definer;

-- 我是存活成员、项目进行中或归档、我没注销的项目。所有成员策略、租户收窄都用它。
CREATE FUNCTION member_projects() RETURNS SETOF uuid LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, public, pg_temp AS $$
    SELECT m.project_id FROM public.project_members m
      JOIN public.projects p ON p.id = m.project_id
      JOIN public.users u ON u.id = m.user_id
     WHERE m.user_id = public.app_user_id() AND m.left_at IS NULL
       AND p.status IN ('active', 'archived') AND u.status <> 'deleted' $$;
-- 我在项目里的预算（别人的预算成员看不到：成员角色没有这两列）。
CREATE FUNCTION my_project_budget(p_project uuid)
    RETURNS TABLE (daily_token_limit bigint, total_token_limit bigint)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
    SELECT m.daily_token_limit, m.total_token_limit FROM public.project_members m
     WHERE m.project_id = p_project AND m.user_id = public.app_user_id()
       AND m.project_id IN (SELECT public.member_projects()) $$;
REVOKE ALL ON FUNCTION member_projects(), my_project_budget(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION member_projects() TO thinktin_member, thinktin_app;
GRANT EXECUTE ON FUNCTION my_project_budget(uuid) TO thinktin_member;
GRANT CREATE ON SCHEMA public TO thinktin_project_definer;   -- 只为改属主（新属主要有建对象的权限），下面就收回
ALTER FUNCTION member_projects() OWNER TO thinktin_project_definer;
ALTER FUNCTION my_project_budget(uuid) OWNER TO thinktin_project_definer;
-- deploy-safe: 只收回上面临时给的 CREATE，上一版没有用到这个角色
REVOKE CREATE ON SCHEMA public FROM thinktin_project_definer;

-- 定义者自己：只看得到自己的成员行、自己的用户行、自己（曾经）是成员的项目行。
GRANT SELECT (project_id, user_id, left_at, daily_token_limit, total_token_limit) ON project_members
    TO thinktin_project_definer;
GRANT SELECT (id, status) ON projects TO thinktin_project_definer;
GRANT SELECT (id, status) ON users TO thinktin_project_definer;
CREATE POLICY definer_own ON project_members FOR SELECT TO thinktin_project_definer
    USING (user_id = app_user_id());
CREATE POLICY definer_own ON projects FOR SELECT TO thinktin_project_definer
    USING (id IN (SELECT pm.project_id FROM project_members pm WHERE pm.user_id = app_user_id()));
CREATE POLICY definer_self ON users FOR SELECT TO thinktin_project_definer USING (id = app_user_id());

-- 成员：项目目录（列表、详情的结构和 8.14 一样）。没有预算列、allow_computer、consented_at；实例没有 state（看得出别人
-- 私下在不在忙），删掉的实例和撤下的 agent 的实例看不到；用户只看得到还在的成员的昵称（退出、注销的匿名）。
GRANT SELECT (id, creator_id, name, goal, status, shared_at, created_at, updated_at, archived_at) ON projects
    TO thinktin_member;
GRANT SELECT (project_id, user_id, role, joined_at, left_at, left_reason) ON project_members TO thinktin_member;
GRANT SELECT (project_id, instance_id, user_id, is_lead, dedicated, position, added_at, left_at) ON project_agents
    TO thinktin_member;
GRANT SELECT (id, display_name) ON users TO thinktin_member;
GRANT SELECT (id, user_id, agent_id, name) ON instances TO thinktin_member;
CREATE POLICY member_read ON projects FOR SELECT TO thinktin_member USING (id IN (SELECT member_projects()));
CREATE POLICY member_read ON project_members FOR SELECT TO thinktin_member
    USING (project_id IN (SELECT member_projects()));
CREATE POLICY member_read ON project_agents FOR SELECT TO thinktin_member
    USING (project_id IN (SELECT member_projects()));
CREATE POLICY member_read ON users FOR SELECT TO thinktin_member
    USING (id IN (SELECT m.user_id FROM project_members m
                   WHERE m.left_at IS NULL AND m.project_id IN (SELECT member_projects())));
CREATE POLICY member_read ON instances FOR SELECT TO thinktin_member
    USING (state <> 'deleted' AND id IN (SELECT a.instance_id FROM project_agents a
                                           WHERE a.left_at IS NULL AND a.project_id IN (SELECT member_projects())));

-- 删项目一律软删除（worker），租户不能再硬删单人项目（会跳过销毁密钥、后台清理）。
-- deploy-safe: 8.14 起删项目、删团队都走 worker（orchestrator::projects::delete），上一版不再用租户的删除
DROP POLICY tenant_delete ON projects;
-- deploy-safe: 同上
REVOKE DELETE ON projects FROM thinktin_app;
-- 后台清理找删了的项目（表小，按 0039 的前提没有流量）。
CREATE INDEX projects_deleted ON projects (deleted_at) WHERE status = 'deleted';

-- 加固 0007、0023 的定义者函数：search_path = public 时临时表能遮住 blob_purge（排进清理队列的键丢了）。
CREATE OR REPLACE FUNCTION queue_artifact_blob_purge() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    INSERT INTO public.blob_purge (blob_key) VALUES (OLD.blob_key) ON CONFLICT DO NOTHING;
    RETURN OLD;
END $$;
-- queue_workspace_archive_purge()：0023:31-55 的函数体原样照抄，只把三处 blob_purge 改成 public.blob_purge，
-- SET search_path 改成 pg_catalog, public, pg_temp。
```

Notes:
- **Checker:** `CREATE OR REPLACE FUNCTION`, `CREATE/DROP POLICY` and `ALTER FUNCTION … OWNER` are not flagged (`check_migrations.py:162-175,217-228`). `REVOKE` carries `deploy-safe`.
- **Production:** the GRANT in the precondition must exist first (§5.4 deploy docs).

### 1.2 `0050_run_scope_columns.sql` (one transaction)

```sql
-- 事件、审批、产出物的空间（docs/projects-impl.md 第 1 条：保留 (run_id, user_id) 外键，再加 scope 一致性外键）。
-- 空间不由调用方给：BEFORE INSERT 触发器按调用者看得到的运行算（租户看不到的——退出了的项目里自己的运行——算成私人，
-- 外键随即拒绝），建了不能改。项目运行的子行因此不用改写入方就带上项目。
-- 锁、前提同 0039：第一次部署之前发布，表是空的。events 是分区表：PostgreSQL 16 不支持分区表上的 NOT VALID 外键，这里
-- 直接加（扫描每个分区，events 和 runs 拿 SHARE ROW EXCLUSIVE 到提交）；有线上库时先看表多大，或者等 PostgreSQL 18。
-- 迁移账号受 FORCE 约束：回填、加外键时引用方和被引用方都临时去掉 FORCE（0040、0046 的做法）。

CREATE FUNCTION fill_space_from_run() RETURNS trigger LANGUAGE plpgsql
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
    NEW.space_kind := CASE WHEN NEW.project_id IS NULL THEN 'private' ELSE 'project' END;
    NEW.space_id := coalesce(NEW.project_id, NEW.user_id);
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION fill_space_from_run() FROM PUBLIC;

ALTER TABLE events ADD COLUMN project_id uuid, ADD COLUMN space_kind text NOT NULL DEFAULT 'private',
    ADD COLUMN space_id uuid;
ALTER TABLE approvals ADD COLUMN project_id uuid, ADD COLUMN space_kind text NOT NULL DEFAULT 'private',
    ADD COLUMN space_id uuid;
ALTER TABLE artifacts ADD COLUMN project_id uuid, ADD COLUMN space_kind text NOT NULL DEFAULT 'private',
    ADD COLUMN space_id uuid;

ALTER TABLE runs NO FORCE ROW LEVEL SECURITY;
ALTER TABLE events NO FORCE ROW LEVEL SECURITY;
ALTER TABLE approvals NO FORCE ROW LEVEL SECURITY;
ALTER TABLE artifacts NO FORCE ROW LEVEL SECURITY;
UPDATE events e SET project_id = r.project_id, space_kind = r.space_kind, space_id = r.space_id
  FROM runs r WHERE r.id = e.run_id;
UPDATE events SET space_id = user_id WHERE space_id IS NULL;            -- run_id 为空的（instance.state 等）
UPDATE approvals a SET project_id = r.project_id, space_kind = r.space_kind, space_id = r.space_id
  FROM runs r WHERE r.id = a.run_id;
UPDATE artifacts a SET project_id = r.project_id, space_kind = r.space_kind, space_id = r.space_id
  FROM runs r WHERE r.id = a.run_id;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM approvals WHERE space_id IS NULL) OR EXISTS (SELECT 1 FROM artifacts WHERE space_id IS NULL)
       OR EXISTS (SELECT 1 FROM events WHERE space_id IS NULL) THEN
        RAISE EXCEPTION 'scope backfill missed rows';
    END IF;
END $$;
ALTER TABLE events ADD CONSTRAINT events_run_space FOREIGN KEY (run_id, space_kind, space_id)
    REFERENCES runs (id, space_kind, space_id) ON DELETE CASCADE;
ALTER TABLE runs FORCE ROW LEVEL SECURITY;
ALTER TABLE events FORCE ROW LEVEL SECURITY;
ALTER TABLE approvals FORCE ROW LEVEL SECURITY;
ALTER TABLE artifacts FORCE ROW LEVEL SECURITY;

-- 回填之后才建触发器（触发器不许改 space_id）。分区表的触发器会复制到已有和以后的分区。
CREATE TRIGGER events_space BEFORE INSERT OR UPDATE OF project_id, space_kind, space_id, user_id, run_id
    ON events FOR EACH ROW EXECUTE FUNCTION fill_space_from_run();
CREATE TRIGGER approvals_space BEFORE INSERT OR UPDATE OF project_id, space_kind, space_id, user_id, run_id
    ON approvals FOR EACH ROW EXECUTE FUNCTION fill_space_from_run();
CREATE TRIGGER artifacts_space BEFORE INSERT OR UPDATE OF project_id, space_kind, space_id, user_id, run_id
    ON artifacts FOR EACH ROW EXECUTE FUNCTION fill_space_from_run();
-- deploy-safe: 上一版插入时不填 space_id，由 BEFORE INSERT 触发器 events_space 填上
ALTER TABLE events ALTER COLUMN space_id SET NOT NULL,
    ADD CONSTRAINT events_space CHECK (space_kind IN ('private', 'project') AND CASE space_kind
        WHEN 'private' THEN project_id IS NULL AND space_id = user_id
        ELSE project_id IS NOT NULL AND space_id = project_id END);
-- deploy-safe: 同上，approvals_space 触发器
ALTER TABLE approvals ALTER COLUMN space_id SET NOT NULL,
    ADD CONSTRAINT approvals_space CHECK (… same CASE …),
    ADD CONSTRAINT approvals_run_space FOREIGN KEY (run_id, space_kind, space_id)
        REFERENCES runs (id, space_kind, space_id) ON DELETE CASCADE NOT VALID;
-- deploy-safe: 同上，artifacts_space 触发器
ALTER TABLE artifacts ALTER COLUMN space_id SET NOT NULL,
    ADD CONSTRAINT artifacts_space CHECK (… same CASE …),
    ADD CONSTRAINT artifacts_run_space FOREIGN KEY (run_id, space_kind, space_id)
        REFERENCES runs (id, space_kind, space_id) ON DELETE CASCADE NOT VALID;
```

Why this is correct:
- **FK matching:** a NULL `run_id` (events) skips the FK (MATCH SIMPLE).
- **No new lock type:** the referencing side already takes KEY SHARE on the run through the old `(run_id, user_id)` FK (`runs.rs:527-529` comment).
- **Lookup indexes:** `events_run` (`0001:285`), `approvals (run_id, request_id)` (`0001:340`) and `artifacts_run` (`0007:26`) serve the RI lookups.

### 1.3 `0051_validate_run_scope_keys.sql` (one transaction)

```sql
-- 检查 0050 的 NOT VALID 外键（属主受 FORCE 约束时外键检查什么都看不到：两边都临时去掉 FORCE，同 0046）。
ALTER TABLE runs NO FORCE ROW LEVEL SECURITY;
ALTER TABLE approvals NO FORCE ROW LEVEL SECURITY;
ALTER TABLE artifacts NO FORCE ROW LEVEL SECURITY;
ALTER TABLE approvals VALIDATE CONSTRAINT approvals_run_space;
ALTER TABLE artifacts VALIDATE CONSTRAINT artifacts_run_space;
ALTER TABLE runs FORCE ROW LEVEL SECURITY;
ALTER TABLE approvals FORCE ROW LEVEL SECURITY;
ALTER TABLE artifacts FORCE ROW LEVEL SECURITY;
```

### 1.4 Concurrent indexes (one statement per file, first bytes `-- no-transaction`, as in 0041–0044)

- `0052_artifacts_project_index.sql`: `CREATE INDEX CONCURRENTLY artifacts_project ON artifacts (project_id, id DESC) WHERE project_id IS NOT NULL;` for the project artifact list and cleanup.
- `0053_runs_project_recent_index.sql`: `CREATE INDEX CONCURRENTLY runs_project_recent ON runs (project_id, id DESC) WHERE project_id IS NOT NULL;` for the project run list and newest-first cleanup. `runs_project` (`0043:3`) is ordered for the FK, not by id.
- `0054_inbox_project_index.sql`: `CREATE INDEX CONCURRENTLY inbox_project ON inbox_items (project_id) WHERE project_id IS NOT NULL;` for cleanup.
- `events` gets no new index: PG16 cannot `CREATE INDEX CONCURRENTLY` on a partitioned table, and `events_run` serves every 8.15 access (per run).

### 1.5 `0055_project_scoped_reads.sql` (one transaction)

```sql
-- 项目运行对成员可读、退出即不可见（WBS 8.15，docs/projects-impl.md 第 2、6 条）。
-- 1. 运行、事件只经两个定义者函数给成员：按白名单投影（新的事件种类默认看不到），没有实例序号、失败原因、花费、审批。
-- 2. 租户读自己的运行、授权、事件、审批：项目行只在“我还是存活成员、项目没删”时看得到；产出物只看私人的（项目产出物走
--    /v1/projects/{id}/artifacts）；收件箱的项目回执按 subtype 照常看得到。
-- 3. 收件箱的 project_id 从运行算（0047 留下的 8.15 一条）。
-- 收紧策略：上一版（8.14）没有项目运行、项目产出物，不读这些行。

CREATE FUNCTION project_run_state(state text) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
    SELECT CASE state
        WHEN 'queued' THEN 'queued'
        WHEN 'waiting_approval' THEN 'waiting_owner' WHEN 'waiting_quota' THEN 'waiting_owner'
        WHEN 'waiting_device' THEN 'waiting_owner'
        WHEN 'waiting_children' THEN 'waiting_children'
        WHEN 'succeeded' THEN 'succeeded' WHEN 'failed' THEN 'failed' WHEN 'cancelled' THEN 'cancelled'
        ELSE 'running' END $$;            -- starting、running、backoff 和以后新加的状态
REVOKE ALL ON FUNCTION project_run_state(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION project_run_state(text) TO thinktin_project_definer;

GRANT SELECT (id, kind, user_id, instance_id, project_id, parent_run_id, root_run_id, step_key, source, prompt,
              state, summary, created_at, started_at, finished_at) ON runs TO thinktin_project_definer;
GRANT SELECT (run_id, project_id, seq, kind, payload, created_at) ON events TO thinktin_project_definer;
CREATE POLICY definer_project ON runs FOR SELECT TO thinktin_project_definer
    USING (project_id IN (SELECT member_projects()));
CREATE POLICY definer_project ON events FOR SELECT TO thinktin_project_definer
    USING (project_id IN (SELECT member_projects()));

-- 项目运行（成员能看的字段）：p_run 一个、p_root 一棵树、p_instance 一个 agent 的，按 id 新的在前。
CREATE FUNCTION project_runs(p_project uuid, p_run uuid, p_root uuid, p_instance uuid, p_before uuid, p_limit integer)
RETURNS TABLE (id uuid, kind text, user_id uuid, instance_id uuid, parent_run_id uuid, root_run_id uuid,
               step_key text, source text, prompt text, state text, summary text,
               created_at timestamptz, started_at timestamptz, finished_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
    SELECT r.id, r.kind, r.user_id, r.instance_id, r.parent_run_id, r.root_run_id, r.step_key, r.source, r.prompt,
           public.project_run_state(r.state), r.summary, r.created_at, r.started_at, r.finished_at
      FROM public.runs r
     WHERE r.project_id = p_project AND r.project_id IN (SELECT public.member_projects())
       AND (p_run IS NULL OR r.id = p_run) AND (p_root IS NULL OR r.root_run_id = p_root)
       AND (p_instance IS NULL OR r.instance_id = p_instance) AND (p_before IS NULL OR r.id < p_before)
     ORDER BY r.id DESC
     LIMIT least(greatest(coalesce(p_limit, 50), 1), 500) $$;

-- 一个项目运行最近的事件（白名单投影，旧的在前）。
CREATE FUNCTION project_run_events(p_project uuid, p_run uuid, p_limit integer)
RETURNS TABLE (kind text, data jsonb, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
    SELECT v.kind, v.data, v.created_at FROM (
        SELECT e.seq, e.created_at,
               CASE e.kind
                   WHEN 'agent.tool_call' THEN 'tool_call' WHEN 'agent.tool_call_update' THEN 'tool_call_update'
                   WHEN 'agent.message' THEN 'message' WHEN 'agent.plan' THEN 'plan'
                   WHEN 'agent.turn_started' THEN 'turn_started' WHEN 'agent.turn_ended' THEN 'turn_ended'
                   WHEN 'run.state' THEN 'state' WHEN 'run.log_truncated' THEN 'log_truncated'
                   WHEN 'artifact.published' THEN 'artifact' WHEN 'pipeline.step_started' THEN 'step_started'
               END AS kind,
               CASE e.kind
                   WHEN 'agent.tool_call' THEN jsonb_strip_nulls(jsonb_build_object(
                       'tool_call_id', left(e.payload->>'tool_call_id', 200),
                       'tool_kind', left(e.payload->>'kind', 64), 'status', left(e.payload->>'status', 64)))
                   WHEN 'agent.tool_call_update' THEN jsonb_strip_nulls(jsonb_build_object(
                       'tool_call_id', left(e.payload->>'tool_call_id', 200), 'status', left(e.payload->>'status', 64)))
                   WHEN 'agent.message' THEN jsonb_build_object('text', coalesce(e.payload->>'text', ''))
                   WHEN 'agent.plan' THEN jsonb_build_object('entries', (
                       SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                                  'content', left(x->>'content', 1000), 'status', left(x->>'status', 64)))), '[]'::jsonb)
                         FROM jsonb_array_elements(CASE WHEN jsonb_typeof(e.payload->'entries') = 'array'
                                                        THEN e.payload->'entries' ELSE '[]'::jsonb END) AS x
                        WHERE jsonb_typeof(x) = 'object'))
                   WHEN 'agent.turn_ended' THEN jsonb_strip_nulls(jsonb_build_object(
                       'stop_reason', left(e.payload->>'stop_reason', 64)))
                   WHEN 'run.state' THEN jsonb_build_object('state', public.project_run_state(e.payload->>'state'))
                   WHEN 'artifact.published' THEN jsonb_strip_nulls(jsonb_build_object(
                       'artifact_id', e.payload->>'artifact_id', 'name', left(e.payload->>'name', 200),
                       'version', e.payload->'version'))
                   WHEN 'pipeline.step_started' THEN jsonb_strip_nulls(jsonb_build_object(
                       'step', left(e.payload->>'step', 200)))
                   ELSE '{}'::jsonb
               END AS data
          FROM public.events e
         WHERE e.run_id = p_run AND e.project_id = p_project
           AND e.project_id IN (SELECT public.member_projects())
           AND e.kind IN ('agent.tool_call', 'agent.tool_call_update', 'agent.message', 'agent.plan',
                          'agent.turn_started', 'agent.turn_ended', 'run.state', 'run.log_truncated',
                          'artifact.published', 'pipeline.step_started')
         ORDER BY e.seq DESC
         LIMIT least(greatest(coalesce(p_limit, 200), 1), 501)) v
     ORDER BY v.seq $$;
REVOKE ALL ON FUNCTION project_runs(uuid, uuid, uuid, uuid, uuid, integer), project_run_events(uuid, uuid, integer)
    FROM PUBLIC;
GRANT EXECUTE ON FUNCTION project_runs(uuid, uuid, uuid, uuid, uuid, integer), project_run_events(uuid, uuid, integer)
    TO thinktin_member;
GRANT CREATE ON SCHEMA public TO thinktin_project_definer;
ALTER FUNCTION project_runs(uuid, uuid, uuid, uuid, uuid, integer) OWNER TO thinktin_project_definer;
ALTER FUNCTION project_run_events(uuid, uuid, integer) OWNER TO thinktin_project_definer;
-- deploy-safe: 只收回上面临时给的 CREATE
REVOKE CREATE ON SCHEMA public FROM thinktin_project_definer;

-- 项目产出物的索引（没有 blob_key：下载由 worker 在同一句 SQL 里再核对成员关系、项目状态和密钥）。
GRANT SELECT (id, user_id, instance_id, run_id, root_run_id, project_id, name, version, content_type, size, sha256,
              created_at) ON artifacts TO thinktin_member;
CREATE POLICY member_read ON artifacts FOR SELECT TO thinktin_member USING (project_id IN (SELECT member_projects()));

-- 租户收窄（WITH CHECK 不变；写项目行仍由 fill_space、inbox_project_guard 只放行 worker）。
ALTER POLICY tenant ON runs
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));
ALTER POLICY tenant ON run_grants
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));
ALTER POLICY tenant ON events
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));
ALTER POLICY tenant ON approvals
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));
ALTER POLICY tenant ON artifacts USING (user_id = app_user_id() AND project_id IS NULL);
-- 回执（proto::domain::notice_subtype::PROJECT_RECEIPTS，按 subtype，不按 run_id 为空：run_id 是 ON DELETE SET NULL）。
ALTER POLICY tenant ON inbox_items
    USING (user_id = app_user_id() AND (project_id IS NULL
           OR subtype IN ('project_invite', 'project_joined', 'project_left', 'project_removed',
                          'project_agent_left', 'project_agent_removed', 'project_deleted')
           OR project_id IN (SELECT member_projects())));

CREATE OR REPLACE FUNCTION inbox_project_guard() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    run_project uuid;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.project_id IS DISTINCT FROM OLD.project_id
           OR NEW.project_invite_id IS DISTINCT FROM OLD.project_invite_id
           OR NEW.subtype IS DISTINCT FROM OLD.subtype THEN
            RAISE EXCEPTION 'inbox_items project fields and subtype cannot change' USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.run_id IS NOT NULL THEN
        -- 按调用者看得到的运行：租户看不到（退出了的项目里自己的运行）就拒绝，免得项目运行的提醒存成私人的。
        SELECT r.project_id INTO run_project FROM public.runs r WHERE r.id = NEW.run_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'inbox item refers to a run that is not visible' USING ERRCODE = 'foreign_key_violation';
        END IF;
        IF NEW.project_id IS NULL THEN
            NEW.project_id := run_project;
        ELSIF NEW.project_id IS DISTINCT FROM run_project THEN
            RAISE EXCEPTION 'inbox item project does not match its run' USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    IF (NEW.project_id IS NOT NULL OR NEW.project_invite_id IS NOT NULL) AND current_user <> 'thinktin_worker' THEN
        RAISE EXCEPTION 'project fields in inbox_items are written by the server only'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
END $$;
```

The trigger list from `0047:75-76` is unchanged. The FK action `ON DELETE SET NULL (run_id)` does not fire it.

---

## 2. Store API (`crates/store`)

### 2.1 `lib.rs`, `error.rs`

- **New module.** `mod project_reads;` and `pub use project_reads::{ProjectTx, ProjectRunFilter};`.
- **`Db::member`.** Add it after `Db::relay` (`lib.rs:171-180`):

  ```rust
  /// 项目成员的只读事务（8.15）：thinktin_member、READ ONLY、REPEATABLE READ（详情的几句查询同一个快照）。
  /// 只设 app.user_id：哪些项目读得到由库里的 member_projects() 按它算，没有“当前项目”这种设置。
  pub async fn member(&self, user: UserId) -> Result<ProjectTx> {
      let mut tx = self.pool.begin_with("BEGIN ISOLATION LEVEL REPEATABLE READ, READ ONLY").await?;
      sqlx::query("SELECT set_config('role', 'thinktin_member', true), set_config('app.user_id', $1, true), \
                   set_config('statement_timeout', $2, true)")
          .bind(user.to_string()).bind(TENANT_STATEMENT_TIMEOUT).execute(&mut *tx).await?;
      Ok(ProjectTx::new(tx, user))
  }
  ```
- **`Db::check_roles()`** (in `schema.rs` next to `check_migrations`, `schema.rs:132`): `SELECT r FROM unnest($1::text[]) r WHERE NOT pg_has_role(session_user, r, 'SET')` with `['thinktin_app','thinktin_worker','thinktin_member']`. Anything returned is `Error::Schema("… cannot SET ROLE …; docs/deploy-checklist.md §3")`. Call it at `server/src/lib.rs:57`.
- **`error.rs:69`.** Add `Some("25006") => Error::Forbidden(db.message().to_owned())` (a write in a read-only transaction is a programming error, mapped like 42501).

### 2.2 `project_reads.rs` (new): `ProjectTx`

```rust
pub struct ProjectTx { tx: Transaction<'static, Postgres>, user: UserId }   // not Tx<R>: no generic impls apply
pub struct ProjectRunFilter { pub instance: Option<InstanceId>, pub before: Option<RunId>, pub limit: u32 }
impl ProjectTx {
    pub fn user(&self) -> UserId;
    pub async fn finish(self) -> Result<()>;            // rollback (read-only)
    pub(crate) fn conn(&mut self) -> &mut PgConnection; // crate-private, for tests
}
```

Every method below runs as `thinktin_member`, and every list method starts with `require_project`. `$` placeholders are positional.

1. **`require_project(p) -> Result<ProjectStatus>`.** `SELECT status FROM projects WHERE id = $1`. No row means NotFound. The policy covers non-member, left, deleted and erased. This keeps list endpoints at 404 for outsiders instead of an empty 200.

2. **`my_projects() -> Vec<ProjectSummary>`.** `MEMBER_SUMMARY_SQL` plus `ORDER BY p.created_at, p.id`. It now includes archived projects (D12). `SUMMARY_SQL` (`projects.rs:133-142`) is ported with `$1` replaced by `app_user_id()`, the explicit `i.state <> 'deleted'` replaced by the instances policy, and `JOIN users cu` changed to `LEFT JOIN`:

   ```sql
   SELECT p.id, p.name, p.goal, p.status, m.role, p.shared_at IS NOT NULL, p.creator_id, cu.display_name,
          (SELECT count(*) FROM project_members x WHERE x.project_id = p.id AND x.left_at IS NULL),
          (SELECT count(*) FROM project_agents a JOIN instances i ON i.id = a.instance_id
             WHERE a.project_id = p.id AND a.left_at IS NULL),
          (SELECT count(*) FROM project_agents a JOIN instances i ON i.id = a.instance_id
             WHERE a.project_id = p.id AND a.left_at IS NULL AND a.user_id = app_user_id()),
          p.created_at, m.joined_at
     FROM project_members m JOIN projects p ON p.id = m.project_id LEFT JOIN users cu ON cu.id = p.creator_id
    WHERE m.user_id = app_user_id() AND m.left_at IS NULL
   ```

3. **`project_detail(p) -> ProjectDetail`.** The JSON is identical to `projects.rs:272-351`.
   - **Summary:** `MEMBER_SUMMARY_SQL AND p.id = $1` (NotFound if absent).
   - **Members:** `projects.rs:285-296` with `JOIN users` changed to `LEFT JOIN users` and the agent subquery without the `i.state` clause.
   - **Agents:** `SELECT a.instance_id, a.user_id, i.agent_id, i.name, a.is_lead, a.position, a.added_at FROM project_agents a JOIN instances i ON i.id = a.instance_id WHERE a.project_id = $1 AND a.left_at IS NULL ORDER BY a.position, a.instance_id`.
   - **Budget:** `SELECT daily_token_limit, total_token_limit FROM my_project_budget($1)`.
   - **Other fields:** `is_me` and `mine` compare against `self.user`; `limits` is `ProjectLimits::default()`.

4. **`authors(p) -> HashMap<UserId, ProjectAuthor>`** (private helper):

   ```sql
   SELECT m.user_id, CASE WHEN m.left_at IS NULL THEN u.display_name END, m.left_at IS NULL, m.left_reason = 'erased'
     FROM project_members m LEFT JOIN users u ON u.id = m.user_id WHERE m.project_id = $1
   ```

   A live member gives `{user_id, display_name, status: member}`. An erased one gives `{None, None, erased}`. Anything else, including an owner not found, gives `{None, None, left}`.

5. **Runs:**
   - **`project_runs(p, &ProjectRunFilter)`:** `require_project`, then `SELECT * FROM project_runs($1, NULL, NULL, $2, $3, $4)` with limit clamped to 1..=200, mapped through `authors`.
   - **`project_run(p, run)`:** `… project_runs($1, $2, NULL, NULL, NULL, 1)`. No row means NotFound.
   - **`project_run_tree(p, run)`:** `project_run` gives the root, then `project_runs($1, NULL, root, NULL, NULL, 500)`, sorted ascending by `(created_at, id)`.

6. **`project_run_events(p, run, limit) -> ProjectRunEvents`.** `project_run(p, run)` first (NotFound), then `SELECT kind, data, created_at FROM project_run_events($1, $2, $3)` with `$3 = limit + 1` and limit clamped to 1..=500. `truncated = rows > limit`; drop the first (oldest) extra row.

7. **Artifacts:**
   - **`project_artifacts(p, before: Option<ArtifactId>, limit)`:** `require_project`, then
     ```sql
     SELECT id, user_id, instance_id, run_id, root_run_id, name, version, content_type, size, sha256, created_at
       FROM artifacts WHERE project_id = $1 AND ($2::uuid IS NULL OR id < $2) ORDER BY id DESC LIMIT $3
     ```
     with limit clamped to 1..=200, uses `artifacts_project`, mapped through `authors`.
   - **`project_artifact(p, id)`:** same columns, `WHERE project_id = $1 AND id = $2`.

**Worker removals.** `Tx<Worker>::my_projects` / `project_detail` (`projects.rs:258-351`) are deleted. `SUMMARY_SQL` moves into `project_reads.rs`.

**Orchestrator switch.** `orchestrator::projects::my_projects` / `detail` (`orchestrator/src/projects.rs:57-70`) switch to `db.member(user)` with the same signatures. Callers stay untouched: `gateway/src/routes/projects.rs:68-71,108,112-119,143,184` and `project_invites.rs:111`.

### 2.3 Tenant changes

- **Runs** (`runs.rs`):
  - `columns!()` (`:192-199`) gains `project_id`; `Row` and `into_record` set `Run.project_id`.
  - `Tx<Tenant>::runs` (`:464-482`) adds `AND project_id IS NULL`.
  - The `list_runs` macro (`:492-504`) adds `AND project_id IS NULL`. It is a residual filter, so the index choice is unchanged.
- **Events** (`events.rs`):
  - `events_after` (`:76-92`) adds `AND project_id IS NULL`, documented as "the instance stream is the private space only".
  - `event_range` (`:96-110`) uses `(SELECT min(seq) FROM events WHERE instance_id = $1 AND project_id IS NULL)`.
  - `recent_run_events` (run-scoped) is unchanged.
- **Artifacts** (`artifacts.rs`):
  - `Row`, `columns!` and `StoredArtifact` gain `project_id: Option<ProjectId>`.
  - The tenant `artifact`, `instance_artifacts`, `run_artifacts` and `delete_artifact` need no code change: the policy makes them private-only.
- **Approvals and inbox:** the policy only.
- **Dead code:** remove `Tx<Tenant>::delete_solo_project` (`projects.rs:522-533`) and `Tx<Tenant>::delete_team` (`teams.rs:84-86`). Point their tests (`tests.rs:1362,1445`, `tests/projects.rs:138`) at the worker `delete_project`.

### 2.4 Worker: lifecycle (`project_members.rs`, `projects.rs`, `runs.rs`, `grants.rs`)

**Lock order:** every flow follows D3 (`projects-8.14-plan.md:13`).

#### Helpers

- **`runs.rs` `cancel_project_runs(p, reason) -> u64`:**
  1. `lock_runs_where!("project_id = $1")`;
  2. `bump_epochs_where!("project_id = $1")`;
  3. `UPDATE runs SET state='cancelled', state_reason=$2, wait_code=NULL, lease_owner=NULL, lease_expires_at=NULL, finished_at=now(), updated_at=now() WHERE project_id=$1 AND state NOT IN ('succeeded','failed','cancelled')`.

  Same-space FKs (`0045:12-15`) guarantee every descendant carries the same `project_id`.
- **`grants.rs` `revoke_project_grants(p, reason) -> u64`:** `revoke_project_member_grants` (`grants.rs:256-275`) with the predicate `project_id = $1`.
- **`project_members.rs` `stop_project(p, reason, mark_left: bool) -> (runs, grants)`:**
  1. `SELECT 1 FROM project_agents WHERE project_id = $1 AND left_at IS NULL ORDER BY instance_id FOR NO KEY UPDATE` (D3 step 7);
  2. `cancel_project_runs`;
  3. `revoke_project_grants`;
  4. if `mark_left`: `UPDATE project_agents SET is_lead = false, left_at = now() WHERE project_id = $1 AND left_at IS NULL`.
- **`project_invites.rs` `revoke_pending_invites(p, locked: &[UserId]) -> u64`:** factored out of `delete_unshared_project` (`:936-953`).

#### `delete_project(user, p, allow_shared) -> DeletedProject`

It replaces `delete_unshared_project` (`project_invites.rs:909-959`).

1. Pre-read, without locks, the pending invitees (`:914-923`) and the live non-creator members (`SELECT user_id FROM project_members WHERE project_id=$1 AND left_at IS NULL AND role='member'`).
2. `project_actor(user, p, &[invitees, members], &[Active, Archived])`, then `require_creator("delete the project")`.
3. If shared and `!allow_shared`, return `Conflict("project is shared")`. This is D10 for `/v1/teams`.
4. `UPDATE projects SET status='deleted', deleted_at=now(), updated_at=now() WHERE id=$1`.
5. `DELETE FROM project_keys WHERE project_id=$1`.
6. `revoke_pending_invites`.
7. `stop_project(p, "project deleted", true)`.
8. Return `{ name, creator, notify: live members that are in actor.users, invites_revoked, runs_cancelled, grants_revoked, shared }`.

Members who joined after the pre-read get no receipt, because writing their inbox now would take a users lock after the project lock (D3).

#### `archive_project(user, p) -> bool` and `unarchive_project(user, p) -> bool`

- **Archive:**
  1. `project_actor(.., &invitees, &[Active, Archived])` and `require_creator`.
  2. If already archived, return `false`.
  3. `UPDATE projects SET status='archived', archived_at=now(), updated_at=now()`.
  4. `revoke_pending_invites`.
  5. `stop_project(p, "project archived", false)`.
- **Unarchive:** `project_actor(.., &[], &[Active, Archived])`, `require_creator`, then `UPDATE projects SET status='active', archived_at=NULL, updated_at=now() WHERE id=$1 AND status='archived'`.

#### Keys and artifacts

- **`project_key(p) -> Option<(String, Vec<u8>)>`:** `SELECT k.kms_key_id, k.wrapped_dek FROM project_keys k JOIN projects p ON p.id = k.project_id WHERE k.project_id = $1 AND p.status IN ('active','archived')`.
- **`insert_project_key(p, kid, wrapped) -> (String, Vec<u8>)`:**
  1. `lock_project(p)`;
  2. `SELECT status = 'active' FROM projects WHERE id=$1` (false means NotFound);
  3. `INSERT INTO project_keys (project_id, kms_key_id, wrapped_dek) VALUES ($1,$2,$3) ON CONFLICT (project_id) DO NOTHING`;
  4. `SELECT kms_key_id, wrapped_dek FROM project_keys WHERE project_id=$1`.
- **`run_project(run) -> Option<ProjectId>`:** `SELECT project_id FROM runs WHERE id=$1`.
- **`project_artifact_blob(user, p, id) -> (StoredArtifact, String, Vec<u8>, Locale)`:** one statement.

  ```sql
  SELECT a.<columns>, k.kms_key_id, k.wrapped_dek, u.locale
    FROM artifacts a
    JOIN projects p ON p.id = a.project_id AND p.status IN ('active','archived')
    JOIN project_members m ON m.project_id = p.id AND m.user_id = $1 AND m.left_at IS NULL
    JOIN users u ON u.id = m.user_id AND u.status <> 'deleted'
    JOIN project_keys k ON k.project_id = p.id
   WHERE a.id = $3 AND a.project_id = $2
  ```
- **`insert_artifact`** (`artifacts.rs:119-156`): `NewArtifact` gains `project: Option<ProjectId>`.
  - When it is `Some(p)`, start with `lock_project(p)`, check active plus a key present (else NotFound), then take the existing `artifact:{root}:{name}` advisory lock. D3: project lock before narrower keys.
  - After the INSERT, if the returned `project_id != a.project`, fail with `Error::Invalid("artifact space")`. The trigger derived it from the run.

#### `purge_deleted_projects(batch, grace: Duration) -> u64`

One call is one transaction; it never waits.

1. Pick candidates: `SELECT id FROM projects WHERE status='deleted' AND deleted_at < now() - make_interval(secs => $1) ORDER BY deleted_at, id LIMIT 20`.
2. For each candidate, skip it unless `pg_try_advisory_xact_lock(hashtextextended('project/'||id, 0))` succeeds.
3. Run the steps below in order. The first step that deletes rows returns its count.
   1. `DELETE FROM artifacts WHERE id IN (SELECT id FROM artifacts WHERE project_id=$1 ORDER BY id LIMIT $2)`. The trigger queues `blob_purge`.
   2. `DELETE FROM inbox_items WHERE id IN (SELECT id FROM inbox_items WHERE project_id=$1 AND (subtype IS NULL OR NOT (subtype = ANY($3))) LIMIT $2 FOR UPDATE SKIP LOCKED)`, with `$3 = PROJECT_RECEIPTS`.
   3. `DELETE FROM events WHERE (instance_id, seq, created_at) IN (SELECT instance_id, seq, created_at FROM events WHERE run_id IN (SELECT id FROM runs WHERE project_id=$1) LIMIT $2)`.
   4. `DELETE FROM runs WHERE id IN (SELECT id FROM runs WHERE project_id=$1 ORDER BY id DESC LIMIT $2)`. Newest first, so children usually go before parents. The cascade also removes approvals and tool_calls.
   5. `DELETE FROM run_grants WHERE id IN (SELECT id FROM run_grants WHERE project_id=$1 ORDER BY id DESC LIMIT $2)`.
   6. When nothing is left: `DELETE FROM projects WHERE id=$1 AND status='deleted'`. It cascades to members, agents and invites (`0039:33,62,88`), which `runs_project_agent` now allows. Return 1.
4. If no candidate could be locked, return 0.

Because each batch commits, a crash at any point resumes from the remaining rows.

#### Erase (`users.rs:183-274`)

After `lock_projects` (`:207`):

1. `cancel_user_runs(id, "account_deleted")` (`runs.rs:835`).
2. For each project with `creator_id = id AND status <> 'deleted'`:
   - `UPDATE projects SET status='deleted', deleted_at=now(), updated_at=now()`;
   - `DELETE FROM project_keys`;
   - `stop_project(p, "account_deleted", true)`;
   - no receipts (D13).
3. Changes to the SQL list:
   - `:218` becomes `DELETE FROM runs WHERE user_id = $1 AND project_id IS NULL`.
   - Add `DELETE FROM approvals WHERE user_id = $1` and `DELETE FROM tool_calls WHERE user_id = $1`.
   - `:220` becomes `DELETE FROM events WHERE instance_id IN (SELECT id FROM instances WHERE user_id = $1) AND (project_id IS NULL OR NOT (kind = ANY($2)))`, where `$2` is the whitelisted stored kinds (`PROJECT_RUN_EVENT_KINDS`). This needs its own `.bind` outside the loop.
   - Remove `:248` (`DELETE FROM projects WHERE creator_id`).

The erased user's project runs keep `user_id`. `instances` and `users` rows are never hard-deleted (grep: no `DELETE FROM instances|users`), so the FKs hold.

---

## 3. Project DEK and project artifacts

**`orchestrator/src/artifacts.rs`:**

- **`project_key_context(p) -> String`** returns `format!("project:{p}")`.
- **`project_vault(db, kms, p, create) -> Result<(KeyVault<Arc<dyn Kms>, MemoryKeyStore>, String), ArtifactError>`:**
  1. Worker `project_key(p)`, then rollback. If found, wrap it in a `MemoryKeyStore` keyed by the context (same shape as `user_vault`, `:158-211`).
  2. If not found and `!create`, return the new `ArtifactError::Gone` (no key, or the project is deleted).
  3. Otherwise, with **no transaction open**: `KeyVault::new(kms, MemoryKeyStore::default()).create_user_key(&ctx)` (`keyvault/lib.rs:497-505`; the context goes into the KMS wrap).
  4. Worker `insert_project_key`, commit, and build the vault from the returned winner.
- **`Origin`** (`:267-272`) is unchanged. `publish` (`:280-338`) derives the space itself:
  1. Worker `run_project(origin.run)`.
  2. Project space: `project_vault(.., true)`, `seal_bytes(&ctx, &id, bytes)` (AAD `thinktin/blob/v1/` + `project:<p>` + id, `keyvault/lib.rs:768-770`), blob key `projects/{p.simple()}/{id.simple()}`, then `insert_artifact(NewArtifact { project: Some(p), .. })`.
  3. Private space: unchanged.
  4. Failure after `put` deletes the blob, as now (`:330-336`).
- **`read(&StoredArtifact)`** (`:341-347`): if `a.project_id = Some(p)`, use `project_vault(.., false)` and `open_bytes(&ctx, ..)`; otherwise unchanged. Tools and pipeline readers (8.16/8.17) therefore get the status check for free.
- **`read_for_member(user, p, id) -> (StoredArtifact, Vec<u8>, Locale)`:**
  1. Worker `project_artifact_blob`, then rollback.
  2. Blob `get`.
  3. `KeyVault` from the returned wrapped key, then `open_bytes`.
  4. No row means NotFound.
- **`ArtifactError::Gone`** maps to 404 in the gateway.

**Who unwraps:**
- The api process (download) and the worker process (tools). Both use DB role `thinktin_worker`.
- `thinktin_llmgw` has no grant on `project_keys` (`0039:226`), and the member and definer roles get none (checked by tests).

**Scope:**
- The project space is decided by the run (D8).
- Private runs publish into the owner's space as before. Tool listing stays run-tree/ask scoped (`store/artifacts.rs:173-264`) until 8.17.

**List and download:**
- Members list through `ProjectTx`. The download goes through the member read (for the 404) and `read_for_member` (re-check plus decrypt).
- Tenant artifact routes are private-only through the policy.

**Destroy and cleanup:**
- The key row is deleted in the delete transaction (§2.4).
- Ciphertext is removed by the `purge_deleted_projects` artifact step → `blob_purge` → `purge_blobs` (`server/src/workers.rs:437-454`).
- Unversioned S3 deletes (`s3.rs:236-242`) leave old versions on a versioned bucket. Key destruction is the protection; deploy note in §8.

---

## 4. Member-readable project runs

**DTOs (`proto/src/domain.rs`, after `ProjectDetail` at `:1100`).** The JSON field names are the serde names.

```rust
str_enum!(ProjectAuthorStatus { Member = "member", Left = "left", Erased = "erased" });
pub struct ProjectAuthor { pub user_id: Option<UserId>, pub display_name: Option<String>, pub status: ProjectAuthorStatus }
str_enum!(ProjectRunState { Queued = "queued", Running = "running", WaitingOwner = "waiting_owner",
    WaitingChildren = "waiting_children", Succeeded = "succeeded", Failed = "failed", Cancelled = "cancelled" });
pub struct ProjectRun { pub id: RunId, pub project_id: ProjectId, pub instance_id: InstanceId, pub owner: ProjectAuthor,
    pub mine: bool, pub kind: RunKind, pub source: RunSource, pub parent_run_id: Option<RunId>, pub root_run_id: RunId,
    pub step_key: Option<String>, pub prompt: String, pub state: ProjectRunState, pub summary: Option<String>,
    pub created_at: DateTime<Utc>, pub started_at: Option<DateTime<Utc>>, pub finished_at: Option<DateTime<Utc>> }
pub struct ProjectRunEvent { pub run_id: RunId, pub kind: String, pub data: Value, pub created_at: DateTime<Utc> }
pub struct ProjectRunEvents { pub events: Vec<ProjectRunEvent>, pub truncated: bool }
pub struct ProjectArtifact { pub id: ArtifactId, pub project_id: ProjectId, pub instance_id: InstanceId, pub run_id: RunId,
    pub root_run_id: RunId, pub author: ProjectAuthor, pub mine: bool, pub name: String, pub version: u32,
    pub content_type: String, pub size: u64, pub sha256: String, pub created_at: DateTime<Utc> }
pub const PROJECT_RUN_EVENT_KINDS: [&str; 10] = ["agent.tool_call", "agent.tool_call_update", "agent.message",
    "agent.plan", "agent.turn_started", "agent.turn_ended", "run.state", "run.log_truncated",
    "artifact.published", "pipeline.step_started"];
// notice_subtype: PROJECT_DELETED = "project_deleted"; PROJECT_RECEIPTS: [&str; 7] (the six from 8.14 + deleted)
// Run: #[serde(default, skip_serializing_if = "Option::is_none")] pub project_id: Option<ProjectId>
```

**Fields kept and dropped.**
- **Runs keep:** `id, kind, instance_id, owner, parent/root, step_key, source, prompt, coarse state, summary, times`.
- **Runs drop:** `state_reason, error, wait_code, tokens_used, attempt, plan_id, trigger_id, fire_time, agent_version, run_grant_id, budget, max_attempts, steps, lease_*, interrupts_run_id, announced_at, urgent, answer_deadline, hook_id`.
- **Event view:** the 10 kinds in `project_run_events`. Each emitted kind carries only these fields:

  | Kind | Fields |
  |---|---|
  | `tool_call` | `tool_call_id`, `tool_kind`, `status` (**no `title`, no `raw`**) |
  | `tool_call_update` | `tool_call_id`, `status` |
  | `message` | `text` |
  | `plan` | `entries[{content, status}]` |
  | `turn_started` | none |
  | `turn_ended` | `stop_reason` |
  | `state` | coarse `state` |
  | `log_truncated` | none |
  | `artifact` | `artifact_id`, `name`, `version` |
  | `step_started` | `step` |

- **Events always dropped:** `agent.thought`, `agent.usage`, `agent.permission_*`, `agent.platform_tool_call`, `agent.vault_reveal`, `vault.*`, `agent.update`, `agent.error`, `agent.ready`, `agent.session_lost`, `agent.exited`, `approval.decided`, `plan.*`, `hook.received`, `board.posted`, `instance.state`, `ask.sent`, `delegate.started` (the last two until 8.17), and `seq`.

**Owner extras.** The owner of a run sees its private fields (error, wait_code, tokens) through the tenant `GET /v1/runs/{id}`. That read is membership-gated by the policy in D9 and now carries `project_id`.

**How this stays correct once project runs execute (8.16/8.17):**
1. Executors and tools need no change to classify rows. Every child row's space is derived from its run by trigger and enforced by the composite FKs (D8). Tenant writes into left projects fail with 23503.
2. New event kinds and run states fail closed in SQL (D6). Adding a kind to the member view is a reviewed migration (D2 recipe) plus a `PROJECT_RUN_EVENT_KINDS` change, checked by a test (§6).
3. The private instance stream and lists never return project rows (D9), so private caches and the private event hub path stay project-free.
4. Membership is re-evaluated on every request (a new `ProjectTx` each time). There is no project stream to revoke in 8.15; the live feed and revocation are 8.19.
5. The claim-guard-lift checklist that must pass first is in §8 (8.16).

---

## 5. Gateway, templates, client-core

### 5.1 Routes (`gateway/src/routes/mod.rs`, after the 8.14 block at `:171-197`; handlers in a new `routes/project_runs.rs`; lifecycle in `routes/projects.rs`)

| Method and path | Body / query | Success | Errors |
|---|---|---|---|
| `GET /v1/projects` | — | 200 `{"projects":[ProjectSummary]}` (now includes archived) | — |
| `GET /v1/projects/{id}` | — | 200 `ProjectDetail` (member transaction) | 404 not member, left or deleted |
| `DELETE /v1/projects/{id}` | — | 204 soft delete, shared or not | 404 outsider or already deleted; 403 member |
| `POST /v1/projects/{id}/archive` | — | 200 `ProjectDetail` (idempotent) | 404 / 403 |
| `POST /v1/projects/{id}/unarchive` | — | 200 `ProjectDetail` (idempotent) | 404 / 403 |
| `GET /v1/projects/{id}/runs` | `?instance_id=&before=&limit=` (1–200, default 50) | 200 `{"runs":[ProjectRun]}` | 404; 422 bad id or limit |
| `GET /v1/projects/{id}/runs/{run_id}` | — | 200 `ProjectRun` | 404 |
| `GET /v1/projects/{id}/runs/{run_id}/tree` | — | 200 `{"runs":[ProjectRun]}` | 404 |
| `GET /v1/projects/{id}/runs/{run_id}/events` | `?limit=` (1–500, default 200) | 200 `{"events":[ProjectRunEvent],"truncated":bool}` | 404 |
| `GET /v1/projects/{id}/artifacts` | `?before=&limit=` (1–200, default 50) | 200 `{"artifacts":[ProjectArtifact]}` | 404 |
| `GET /v1/projects/{id}/artifacts/{artifact_id}` | — | 200 `ProjectArtifact` | 404 |
| `GET /v1/projects/{id}/artifacts/{artifact_id}/content` | — | 200 bytes; headers and labels identical to `artifacts::content` (`routes/artifacts.rs:93-135`), via a helper `download_response(s, locale, &StoredArtifact, bytes)` factored out of it | 404 (including key gone) |
| `GET`/`POST /v1/project-templates`, `DELETE /v1/project-templates/{id}` | same as team-templates | same JSON (`teams::templates`, `create_template`, `delete_template`) | same |
| `POST /v1/project-templates/{id}/adopt` | `{"name"?}` | 201 `ProjectDetail` | same as team adopt (409 `instance_limit`) |

**Handler notes:**
- **Errors.** `pub(crate) fn project_error(e: store::Error) -> ApiError` in `routes/projects.rs`: `Forbidden` → `warn!` and `ApiError::not_found("project")`; everything else → `e.into()`. It is used by every handler in the table and by the existing `/v1/projects/{id}/*` handlers. The global mapping (`gateway/src/error.rs:66-95`) is unchanged.
- **Orchestrator calls:**
  - Archive and unarchive call `orchestrator::projects::{archive, unarchive}` (worker transaction plus `project.archive` / `project.unarchive` audit), then `projects::detail`.
  - `projects::delete` (`gateway/src/routes/projects.rs:147-156`) calls `orchestrator::projects::delete(.., allow_shared = true)`.
  - `teams::delete` (`routes/teams.rs:97-110`) passes `false`, which keeps the 409 and the `NotPermitted`→404 mapping.
- **Adopt.** Move the body of `teams::adopt_template` (`teams.rs:187-230`) into `fn adopt(s, who, id, name) -> ApiResult<TeamId>`. The team route returns `Team`; the project route returns `projects::detail`.
- **Tenant routes:** no code change. Stores and policies make them private-only or membership-gated (D9, D15).

### 5.2 Orchestrator (`orchestrator/src/projects.rs`)

- **`delete(db, user, actor, p, allow_shared)`:** worker `delete_project`, then:
  - audit `project.delete` `{project, shared, invites_revoked, runs_cancelled, grants_revoked}`;
  - for each `notify` member, `notify(w, member, project_notice(p, title, body, notice_subtype::PROJECT_DELETED))` with `dedupe_key = "project_deleted:{p}"`;
  - commit.
- **`archive`, `unarchive`:** the same pattern, audit only.
- **`texts.rs`:** `project_deleted(locale, project_name) -> (&'static str, String)`.
- **`sweep`** (`:537-563`): add a loop of up to `SWEEP_BATCHES` calls to `w.purge_deleted_projects(SWEEP_BATCH, PROJECT_PURGE_GRACE)` (10 min), one transaction each, stopping at 0. It is already called from `server/src/workers.rs:507`.
- **`docs/push.md`:** add `project_deleted`.

### 5.3 client-core

**`api.rs`:** `project_runs`, `project_run`, `project_run_tree`, `project_run_events`, `project_artifacts`, `project_artifact`, `project_artifact_content`, `archive_project`, `unarchive_project`, `project_templates`, `create_project_template`, `delete_project_template`, `adopt_project_template`.

**`ffi.rs`:**
- **Records:** `ProjectAuthor`, `ProjectRun`, `ProjectRunEvent { run_id, kind, data_json: String, created_at }`, `ProjectRunEvents`, `ProjectArtifact`.
- **`Run`** (`:423`, `From` at `:453`) gains `project_id: Option<String>`.
- **Methods** in the 8.14 block (`:3038-3262`):
  - `project_runs(project_id, instance_id: Option<String>, before: Option<String>, limit: u32)`
  - `project_run`, `project_run_tree`, `project_run_events(project_id, run_id, limit)`
  - `project_artifacts(project_id, before, limit)`, `project_artifact_content(project_id, artifact_id) -> Vec<u8>`
  - `archive_project`, `unarchive_project`
  - `project_templates`, `create_project_template`, `delete_project_template`, `adopt_project_template -> ProjectDetail`
  - the doc of `delete_project` (`:3092`) changes to "shared projects are soft-deleted".
- **No local cache of project content in 8.15.** Project data is network-only.

**`cache.rs`:**
- `forget_project(project)` selects `id, json FROM inbox`, deletes items whose `project_id == project` and whose `subtype` is not in `PROJECT_RECEIPTS` (through `remove_inbox`, `:377`), and deletes `runs` rows whose JSON `project_id == project` (defensive).
- `put_runs` (`:156-172`) skips `run.project_id.is_some()`.

**`client.rs` and `ffi.rs` call sites:**
- `forget_project` runs after a successful `leave_project` (`ffi.rs:3142-3146`) and `delete_project`.
- It runs after inbox sync (`reconcile_inbox_page`, `cache.rs:305-355`) sees a `project_removed` or `project_deleted` item for that project.
- It runs when any project-path call returns `ClientError::NotFound`. The app shows "已退出" (12.25/13.18).

**Other files:** `tools/client-core/ffi_smoke.py` covers the new methods.

**Bindings:** Android is regenerated with `apps/android/scripts/sync-core.sh --bindings-only` in its own commit, as in `d4d1f18`. Apple bindings are generated at build (`tools/client-core/build-apple.sh:85`); nothing to commit.

### 5.4 Deploy docs

**`docs/deploy-checklist.md:57-71`** gains:

```sql
CREATE ROLE thinktin_member NOLOGIN NOBYPASSRLS;
CREATE ROLE thinktin_project_definer NOLOGIN NOBYPASSRLS NOINHERIT;
GRANT thinktin_project_definer TO thinktin_owner WITH INHERIT FALSE, SET TRUE;   -- PostgreSQL 16 语法
GRANT thinktin_app, thinktin_worker, thinktin_member TO thinktin_server_login;
```

**`docs/release.md:73-78`:** the same login grant. **`testing.rs:85-98`:** create both roles if missing, then `GRANT thinktin_project_definer TO thinktin_test_owner WITH INHERIT FALSE, SET TRUE`, still inside the advisory-locked block.

---

## 6. Tests

All store tests use `TestDb::new()` (real Postgres; migrations run as the non-superuser `thinktin_test_owner` with FORCE in effect; `testing.rs:58-65,107-123`).

**Cast and fixtures:**
- **People and projects:** alice (creator) and bob (member) share P1; alice alone has P2; carol is an outsider. Joining uses `join_raw` (`tests/projects.rs:31-58`) or the real accept.
- **Project runs:** inserted with worker SQL (`INSERT INTO runs … project_id`; `fill_space` allows the worker).
- **Events and approvals:** events via worker `append_event`, approvals via worker SQL.
- **Keys and artifacts:** keys via `insert_project_key`, artifacts via `insert_artifact { project: Some(..) }`.

### 6.1 Store, new `crates/store/src/tests/boundary.rs` (`mod boundary;` in `tests.rs`)

1. **`member_reads_only_live_projects`.**
   - **Bob:** `db.member(bob)` → `my_projects` = [P1]; `project_detail(P2)` → NotFound.
   - **Carol:** sees nothing; `require_project(P1)` → NotFound.
   - **Forged id and setting:** in bob's ProjectTx, raw `SELECT set_config('app.project_id', P2, true)`, then `SELECT count(*) FROM projects WHERE id = P2` = 0; `SELECT * FROM member_projects()` = {P1}; `project_runs(P2, …)` returns no rows; `project_run_events(P2, run_in_P2, 10)` returns no rows.
   - **42501 (`Error::Forbidden`) for every one of:** `approvals`, `tool_calls`, `usage_records`, `credentials`, `model_routes`, `vault_items`, `vault_requests`, `devices`, `user_keys`, `project_keys`, `project_invites`, `user_blocks`, `events`, `runs`, `inbox_items`, `board_posts`, `plans`, `outbox`, `audit_log`, `project_members.daily_token_limit`, `instances.state`, `artifacts.blob_key`.
   - **Writes:** `INSERT INTO projects …` and `SELECT pg_advisory_xact_lock(1)` are not callable through the API. A raw INSERT gives 25006 → `Forbidden`.
   - **Budget:** `my_project_budget` returns only bob's own row.
2. **`detail_json_is_unchanged`.** Port `project_reads_follow_membership` (`tests/projects.rs:146`) to `db.member` and assert `serde_json::to_value` equality with the 8.14 expectations.
   - **Edge cases:** deleted instance not counted, left agent hidden, member order, `my_budget`.
   - **Archived:** an archived P1 appears in `my_projects` with `status = archived`.
3. **`leaving_hides_project_rows_everywhere`.** Bob's instance b1 has a project run R in P1 with tool_call, thought and message events, an approval, a project artifact, a run notice (worker insert) and a private run on b1.
   - **Before leaving (bob as tenant):** `run(R)` ok; `runs(b1)` and `list_runs` exclude R; `events_after(b1)` excludes R's events; `instance_artifacts(b1)` excludes the project artifact; `pending_approvals` includes R's approval.
   - **Leaving:** `leave_project(bob, P1)`.
   - **After leaving (bob as tenant):** `run(R)` → NotFound; approvals hide it; the inbox hides the run notice but shows the `project_left` receipt; `delete_artifact(project artifact)` → NotFound.
   - **After leaving (bob as member):** P1 → NotFound.
   - **Alice as member:** sees R with `owner.status = left` and no name; sees the artifact with `author.status = left`.
   - **Private run:** never visible to alice through any method.
4. **`project_view_is_whitelisted`.**
   - Events of every stored kind, including `agent.permission_requested`, `agent.usage`, `agent.vault_reveal`, `approval.decided` and `agent.platform_tool_call`, each with a `raw` field holding a marker string.
   - Alice's `project_run_events` returns only the 10 mapped kinds, exactly the fields in §4, and the marker string appears nowhere in the serialized output.
   - States: `waiting_quota` → `waiting_owner`, `backoff` → `running`.
   - `truncated` is true at limit 3.
   - `PROJECT_RUN_EVENT_KINDS` and `PROJECT_RECEIPTS` match the text of `include_str!("../../migrations/0055_project_scoped_reads.sql")`.
5. **`scope_follows_the_run`.**
   - Worker-appended events, approvals and artifacts of R get `space_kind = 'project'`.
   - A tenant (bob, a live member) appending an event on R gets the project derived. After leaving, the same append → `Error::Invalid` (23503).
   - `UPDATE events SET project_id = NULL` → `Invalid` (23514).
   - A raw worker insert of an approval whose space disagrees fails.
6. **`inbox_project_is_derived`.**
   - A worker run notice without `project_id` is stored with P1.
   - A mismatched `project_id` → `Invalid`.
   - Bob as tenant: `insert_inbox(run_id = R)` while a member → `Forbidden`; after leaving → `Invalid`.
   - Extends `inbox_project_fields_are_server_only` (`tests/projects.rs:275`).
7. **`deleting_makes_unreadable_then_purges`.**
   - `delete_project(alice, P1, true)`: bob's member reads → NotFound; tenant `run(R)` → NotFound; `project_key(P1)` → None and the `project_keys` row is gone; runs are cancelled with epochs bumped (`epoch` helper, `tests/projects.rs:1789`); agents are left; invites are revoked.
   - Purge loop with batch 2 and grace 0: commit each call, roll one back midway, and continue until 0.
   - At the end: no runs, events, artifacts, run_grants or non-receipt inbox rows for P1; receipts remain; the `blob_purge` table holds every artifact `blob_key`; the `projects` row is gone.
   - Bob's receipt is asserted at HTTP level (§6.2), because store tests do not run `notify` (8.14 A3-5).
8. **`archive_is_read_only`.** After archiving:
   - runs are cancelled and invites revoked;
   - members still read detail, runs and artifacts;
   - `insert_project_key` → NotFound and `insert_artifact` into P1 → NotFound;
   - `add_project_agents` and `update_project` → NotFound;
   - leave still works.

   `unarchive` restores `active`, and member reads are unchanged.
9. **`erase_keeps_others_records`.**
   - **Bob (member) erased:** R stays visible to alice with `owner.status = erased`, and its whitelisted events remain. R's thought events, its approval and bob's tool_calls are gone. Bob's private runs are gone.
   - **Alice (creator) erased:** P1 is soft-deleted, its key is gone, bob's project runs are cancelled, and there is no 23503.
   - Purge then removes P1. Extends `erase_and_project_flows_do_not_deadlock` (`tests/projects.rs:1886`).
10. **`delete_races`.** With a `tokio::sync::Barrier`:
    - delete vs `insert_project_key`: no key survives on a deleted project;
    - delete vs accept: the accept loses with NotFound;
    - delete vs leave;
    - delete vs erase of a member: no 40P01.
11. **Schema** (in `tests.rs`):
    - generalize `every_tenant_table_the_app_can_touch_has_rls` (`:765-829`) to each of `thinktin_app`, `thinktin_member` and `thinktin_project_definer`: every table the role can touch has RLS, FORCE and at least one policy for that role, and none has `qual = 'true'`;
    - new `member_roles_are_restricted`: both roles NOLOGIN, NOBYPASSRLS, not superuser, members of nothing; `thinktin_member`'s table and column privileges equal the allow-list exactly (from `information_schema.column_privileges`);
    - new `definer_functions_are_locked_down`: every `prosecdef` function is either owned by `thinktin_project_definer` (with `proconfig` containing `search_path=pg_catalog, public, pg_temp`, no PUBLIC EXECUTE, EXECUTE only for the allow-listed roles) or is one of the four legacy ones (`ensure_event_partitions`, `drop_event_partitions_before`, `queue_artifact_blob_purge`, `queue_workspace_archive_purge`), whose search_path is checked too after D18;
    - extend the FORCE list (`:1024-1043`) with `runs`, `events`, `approvals` and `artifacts`.
12. **Migration backfill.** `TestDb::up_to(49)`; insert a project run plus an approval, an artifact and events for it with raw superuser SQL; `migrate_rest()`. The rows now carry project scope and the FKs validated (pattern from the 0046 test, `tests.rs:868`).

### 6.2 Gateway (`crates/gateway/tests/api.rs`)

- **`project_runs_and_artifacts_over_http`.** Alice and bob join via HTTP; carol is an outsider. Seed R and its events with worker SQL; publish a project artifact through the harness `ArtifactStore`, as `teams_pipelines_and_artifacts` does (`:1267`).
  - **Bob:** `GET /v1/projects/{p}/runs` → 200 with `owner`, `mine` and coarse state and no `error`, `tokens_used` or `wait_code` keys; `/events` contains no thought, usage, permission or `raw` content and no `seq`; `/artifacts/{a}/content` → bytes plus the label footer and the `x-aigc` header.
  - **Carol:** every project path → 404.
  - **Bob, after `POST /leave`:** every project path → 404; `GET /v1/runs/{R}`, `/tree` and `/cancel` → 404; `GET /v1/instances/{b1}/events` has no project events; `GET` and `DELETE /v1/artifacts/{a}` → 404; `GET /v1/inbox` shows `project_left` but not the run notice.
- **`deleting_a_shared_project_over_http`.**
  - Replace the 409 assertion at `:5020-5029` with 204.
  - Bob's inbox has a `project_deleted` receipt; all project paths → 404; the artifact content is 404.
  - A second DELETE → 404.
  - `DELETE /v1/teams/{id}` on a shared project still → 409 (`:2905-2915`, `:5257-5284` unchanged).
- **`archive_and_unarchive_over_http`.** Member → 403; outsider → 404; creator → 200 with `status`. The list shows the archived project. `PATCH` and `POST /invites` → 404 while archived. Unarchive → 200.
- **`project_templates_alias_over_http`.** CRUD through `/v1/project-templates`; adopt → 201 `ProjectDetail`, and the same template is visible through `/v1/team-templates`.
- **`forbidden_is_404_on_project_paths`.** Unit test of `project_error(store::Error::Forbidden(..))`, plus one HTTP case: revoke the column grant inside the test database, call the route and expect 404.

### 6.3 client-core (`crates/client-core/tests/client.rs`; harness `:64-67` already turns the switch on)

- **`ffi_project_content_and_forget`.** Cover runs, events and artifacts through the FFI.
  - Seed a cached inbox item with `project_id = P` plus a `project_joined` receipt.
  - After `leave_project`, the item is gone and the receipt stays.
  - `project_runs` → NotFound.
  - `put_runs` with a run whose `project_id` is set stores nothing.
- **Unit test** in `cache.rs` for `forget_project`.

### 6.4 Other

`cargo test --workspace`, plus orchestrator unit tests:
- `project_vault` creates the key once under concurrency (two tasks; `LocalKms`);
- `publish` into a project run seals with the `project:<p>` context and a user DEK cannot open it;
- `read` after a delete → `Gone`.

---

## 7. Commit sequence

Each commit compiles and passes `cargo test --workspace`, is pushed immediately, and updates `docs/progress/claude-determined-lovelace-vn0j5h.md` (CLAUDE.md "防止工作丢失").

| # | Commit | Files |
|---|---|---|
| C1 | proto: `ProjectRun`, `ProjectRunState`, `ProjectAuthor(Status)`, `ProjectRunEvent(s)`, `ProjectArtifact`, `PROJECT_RUN_EVENT_KINDS`, `PROJECT_DELETED`, `PROJECT_RECEIPTS`, `Run.project_id`; store selects `project_id` | `proto/src/domain.rs`, `store/src/runs.rs`, `orchestrator/src/delegate.rs` (test literals `:316,371`) |
| C2 | Migration 0049; test roles; deploy docs; error 25006; schema tests 11 (roles, definer, RLS per role) | `migrations/0049_project_member_role.sql`, `store/src/{testing,error}.rs`, `store/src/tests.rs`, `docs/deploy-checklist.md`, `docs/release.md` |
| C3 | store `ProjectTx` and `Db::member`, `project_reads.rs` (directory reads), `Db::check_roles`; orchestrator reads switched; worker reads removed; tests 1 and 2 | `store/src/{lib,schema,project_reads,projects}.rs`, `store/src/tests/{boundary,projects}.rs`, `orchestrator/src/projects.rs`, `server/src/lib.rs` |
| C4 | Migrations 0050 and 0051; `StoredArtifact.project_id`, `NewArtifact.project`; tests 5 and 12 | `migrations/0050_*.sql`, `0051_*.sql`, `store/src/artifacts.rs`, tests |
| C5 | Migrations 0052–0054 (indexes) | `migrations/0052_*.sql`, `0053_*.sql`, `0054_*.sql` |
| C6 | Migration 0055; tenant list filters; `ProjectTx` run, event and artifact reads; tests 3, 4 and 6 | `migrations/0055_*.sql`, `store/src/{runs,events,project_reads}.rs`, tests |
| C7 | store lifecycle: `delete_project` (replacing `delete_unshared_project`), archive and unarchive, `stop_project`, `cancel_project_runs`, `revoke_project_grants`, `purge_deleted_projects`, keys, `project_artifact_blob`, `run_project`, erase changes; tenant delete code removed; tests 7–10 | `store/src/{project_invites,project_members,projects,teams,runs,grants,users,artifacts}.rs`, tests |
| C8 | orchestrator: `project_vault`, publish and read branches, `read_for_member`; delete, archive and unarchive wrappers; `project_deleted` receipt; sweep purge; unit tests; push doc | `orchestrator/src/{artifacts,projects,texts}.rs`, `docs/push.md` |
| C9 | gateway: `project_runs.rs` routes, `project_error`, archive routes, delete semantics, template alias, download helper; API tests | `gateway/src/routes/{mod,projects,project_runs,teams,artifacts}.rs`, `gateway/tests/api.rs` |
| C10 | client-core: API, FFI, cache forget and skip, tests, smoke script | `client-core/src/{api,ffi,cache,client}.rs`, `client-core/tests/client.rs`, `tools/client-core/ffi_smoke.py` |
| C11 | Android bindings regenerated (own commit, `apps/android/**` only) | `apps/android/core/src/main/kotlin/cn/thinktin/core/client_core.kt` |
| C12 | Docs: projects-impl "8.15 做了什么", projects.md status line, the plan in `docs/progress/drafts/projects-8.15-plan.md`, progress file | `docs/**` |

After merging, delete `autosave/<branch>` as CLAUDE.md says.

---

## 8. What 8.15 leaves for 8.16–8.19

**8.16 (must be done before lifting the claim guard, `runs.rs:204-206`):**
- **Per-space session and storage:** `ToolContext` (`orchestrator/src/shim.rs:69-75`) carries the run's space; a per-(instance, project) session, HOME, cwd and workspace archive key; `artifact_fetch` and pipeline handoff (`tools.rs:644-666`, `pipeline.rs:246-249`) write project plaintext only into the project workspace; dedicated instances (`project_agents.dedicated`).
- **Space filters:** `unannounced_messages` (`runs.rs:1285-1302`) and `queue_urgent_run` (`:606-710`); peers / `agent_status` (`orchestrator/src/peers.rs:93-112`); the board tools (`orchestrator/src/board.rs:94`); the executor resume brief (`executor.rs:295-320`).
- **Claims:** check live agents and live membership.

**8.17:**
- project board (`board_posts.project_id`, member policy, cleanup step);
- dispatch and project grants through an exposed `ProjectActor`;
- `PUT /v1/projects/{id}/lead`;
- cross-owner run trees: drop the old `(x, user_id)` FKs (`0001:251-255`) and detach cross-owner children on erase or withdraw;
- the artifact tool scope widened to the project;
- `ask.sent` / `delegate.started` in the member view when the target is in the project;
- a member-facing artifact delete (worker, `ProjectActor`).

**8.18:**
- llm-gw enforcement of `project_members` budgets;
- approvals to the owner (rows are already owner-private and the member view shows `waiting_owner`);
- per-project vault and computer;
- frozen accounts and membership (`member_projects()` only excludes `deleted`);
- tenant notice paths (`tools.rs:187`, `vault.rs:167`, `routes/plans.rs:358`) for project runs, which D10 now rejects.

**8.19:**
- the project feed (`project_seq`, outbox sequencer, cursor) and live revocation of open project streams;
- receipts: `project_archived`, member erased, erase-triggered `project_deleted` (D13), task results;
- possibly a project `PushKind`;
- inbox FK for cross-owner notices.

**15.7 / 16.6 / deploy:**
- the legacy `ensure_event_partitions` / `drop_event_partitions_before` with `search_path = public` (`0001:289,305`);
- review of `left_reason` exposure to members;
- object-store bucket versioning must be off (or have a lifecycle rule), since deletes are unversioned;
- personal data inside kept project content after erase (16.6).

## Open questions

- Should the member event view include agent.message text and agent.plan entries? The plan says yes, because they are the project's work output, and keeps tool-call titles hidden because they can contain paths and commands. Alternatively drop messages and plans too and show only tool ids, kinds and statuses.
- Should members see the prompt and summary of other owners' project runs? The plan says yes: it is the project task and its result. For ask runs the prompt embeds the asker's question.
- GET /v1/projects now lists archived projects too, with status=archived and the same JSON shape. Alternatively keep the list active-only and add ?status=archived.
- Tenant list endpoints (runs per instance, GET /v1/runs, the instance event page and WebSocket) exclude even the owner's own project runs, so old clients never cache project data. The owner reaches them through /v1/projects/{id}/runs and the membership-gated GET /v1/runs/{id}. Is that acceptable, or should the owner's instance history show own project runs while they are a member?
- When a creator erases their account, their projects are soft-deleted without project_deleted receipts to the other members in 8.15. Writing those inboxes inside erase would deadlock with the members' own erase under the D3 lock order. The receipts come in 8.19 via the sweep. Acceptable?
- The member event view returns the newest 500 whitelisted events per run, with no cursor and no seq, until the 8.19 project_seq feed. Acceptable for the read model?
- thinktin_member can read project_members.left_reason so the UI can show 已注销的用户 separately from 已退出的成员. That also lets server code tell 'removed' from 'left', though the DTO collapses both to 'left'. Alternatively show every former member as 已退出的成员 and skip the grant.
- POST /v1/project-templates/{id}/adopt returns 201 with a ProjectDetail, while /v1/team-templates/{id}/adopt keeps returning a Team. Confirm.
- The cleanup grace period after a delete is 10 minutes before content is purged (unreadable immediately either way). Confirm the value.
- Every DELETE /v1/projects/{id} becomes a soft delete, including never-shared solo projects, and the old tenant hard-delete grant is revoked. /v1/teams/{id} DELETE keeps 409 on shared projects. Confirm.
