# 8.15 定稿方案（workflow `projects-8-15-plan`，2026-11-05）

草稿加两份评审改出来的。英文原样。

# WP 8.15 implementation plan: the cross-user data boundary (final)

8.15 covers four things: row-level security on project tables by membership, project runs that members can read, project keys and project artifacts, and making a project invisible as soon as someone leaves.

- **Branch:** `claude/determined-lovelace-vn0j5h` at `43f0944`, clean tree. That is one commit past `995819c` and only adds two draft docs.
- **Migrations:** the last one is `0048_project_invite_sends.sql`, so this package uses **0049–0054**. The draft had 0049–0055; 0051 is gone, see D8.
- **Precondition (0039:6-8):** nothing is deployed yet. There is no `v*` tag, so `tools/ci/check_migrations.py:323-325` checks only file names. Every statement that would be flagged once a tag exists still carries a `-- deploy-safe:` note.

**Checked on a scratch PostgreSQL 16.15 database.** Production is RDS PG16 (`docs/deploy-checklist.md:18`) and CI uses `postgres:16`. The scratch databases and roles were created and then dropped. No repo files were touched.

| # | Behaviour | Result |
|---|---|---|
| V1 | `ADD FOREIGN KEY … NOT VALID` on the partitioned `events` table | Fails with "cannot add NOT VALID foreign key on partitioned table". A valid FK works. |
| V2 | BEFORE ROW trigger on the `events` parent | Cloned to existing and future partitions. |
| V3 | Policy that references a column the role cannot SELECT (same table) | Works. Selecting that column still gives 42501. |
| V4 | Forged `app.project_id` setting, or a project id passed as a parameter | Reads 0 rows. `member_projects()` returns only the real memberships. |
| V5 | Tenant policy `user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects()))` | Hides the row as soon as `left_at` is set. The plan uses a hashed SubPlan, evaluated once per query. |
| V6 | `ALTER FUNCTION … OWNER TO thinktin_project_definer`, run by the migration owner | The owner must be able to SET ROLE to the definer, and the definer needs CREATE on `public`. The temporary-CREATE recipe in D2 works. `GRANT … WITH INHERIT FALSE, SET TRUE` is enough, and the owner does not inherit (`pg_has_role(...,'USAGE') = f`). |
| V7 | `pg_advisory_xact_lock` inside `BEGIN READ ONLY` | Allowed. |
| V8 | The run/event function bodies in 0054 | Compile. |
| V9 | `CREATE TABLE %I PARTITION OF public.events` in a function with `SET search_path = pg_catalog, public, pg_temp` | Fails: "permission denied to create "pg_catalog.events_202601"". The first schema listed is the creation target. `public.%I` works. |
| V10 | `pg_has_role(current_user, <role it is not in>, 'USAGE')` as superuser; `pg_has_role(name, NULL::oid, 'SET')` | `t` (superusers pass every role check), and NULL. |
| V11 | An IMMUTABLE SQL `project_receipt(text)` inside a policy; `ALTER POLICY … USING` on a FOR ALL policy | The function is inlined (`Filter: … subtype = ANY ('{…}')`). WITH CHECK is kept. |
| V12 | (impl critic) a `bigint` argument to an `integer` parameter; `(p IS NULL OR col = p)` inside a SQL definer function | `function … does not exist`. The OR form is not usable as an index condition (generic parameters). The `coalesce` bound gives `Index Cond`. |

---

## 0. Decisions

**Scope.**

*In 8.15:*
- the roles `thinktin_member` and `thinktin_project_definer`;
- `ProjectTx`, with the 8.14 project reads moved onto it and their JSON unchanged;
- member policies on project tables, plus the directory rows (names, agents);
- a space (project or private) on events, approvals and artifacts;
- tenant policies that hide project rows after leaving, plus tenant lists limited to private rows;
- tenant project policies that also check status;
- `inbox_project_guard` deriving the project from the run;
- the member read model: project runs, a whitelisted event view, project artifacts;
- the project DEK, and publishing, reading and downloading project artifacts;
- archive, unarchive, and soft delete of every project;
- bounded cleanup of deleted projects;
- erase switching to soft delete;
- exits that settle the approvals and notices they hide;
- 42501 → 404 on project paths;
- `/v1/project-templates*`;
- client-core FFI and forgetting a project's cache.

*Deferred:*
- **8.16:** session and workspace isolation per (instance, project), dedicated instances, lifting the claim guard, and the leak fixes that must come first (§8).
- **8.17:** dispatch, project grants, lead changes, the project board, cross-owner trees, and a project-wide artifact tool scope.
- **8.18:** llm-gw budgets, approvals to the owner, per-project vault and computer.
- **8.19:** the full notification set and the project feed (`project_seq`).

Nothing in 8.15 lets project runs execute: the claim guard (`runs.rs:201-206` and the four claim queries) stays. Tests seed project rows with worker SQL, as 8.14 did (`tests/projects.rs:31-58`, `:1737`).

| # | Decision | Why / evidence |
|---|---|---|
| D1 | **Two new NOLOGIN NOBYPASSRLS roles.**<br>• `thinktin_member` is used by `ProjectTx`. It has no default grants.<br>• `thinktin_project_definer` owns every SECURITY DEFINER function. It is NOINHERIT and a member of nothing.<br>**Creation:** the high-privilege account pre-creates both. The migration creates them only if missing (0001 pattern).<br>**Memberships:** `GRANT thinktin_project_definer TO <migration owner> WITH INHERIT FALSE, SET TRUE` and `GRANT thinktin_member TO thinktin_server_login WITH INHERIT FALSE, SET TRUE`.<br>**0049 refuses to run when:**<br>• either role can log in, bypass RLS, create roles or databases, or is superuser;<br>• the definer inherits;<br>• either role is a member of anything;<br>• any service role is a member of either;<br>• (non-superuser owners only) the owner cannot SET ROLE to the definer, or inherits it. | • projects-impl item 2 (`projects-impl.md:19`).<br>• The owner has no CREATEROLE (`0001:8-10`, `testing.rs:95-97`).<br>• Policies apply through inherited membership, so `thinktin_app` ∈ `thinktin_member` would give tenants the `member_read` rows. The tenant code relies on `tenant_read` alone, e.g. `own_projects()` (`projects.rs:431-438`).<br>• Superusers pass every `pg_has_role` (V10), and dev and loadtest migrate as superuser (`tools/dev/setup-db.sh:17`, `server/src/lib.rs:53`, `loadtest/src/scratch.rs:36`). |
| D2 | **Definer functions are locked down:**<br>• `SET search_path = pg_catalog, public, pg_temp`, with `public.`-qualified names, including the names of objects they create (V9);<br>• no free-form inputs: only uuid/int, with limits clamped in SQL;<br>• `REVOKE ALL … FROM PUBLIC`;<br>• **every GRANT comes before `ALTER … OWNER TO`**: the ACL moves with ownership, and with INHERIT FALSE the owner cannot grant afterwards.<br>**Changing owner:** grant `CREATE ON SCHEMA public` to the definer for that statement only.<br>**Changing a function later:** `GRANT CREATE` → `SET LOCAL ROLE thinktin_project_definer` → `CREATE OR REPLACE` (repeat the SET clause) → `RESET ROLE` → `REVOKE`. | V6, V9. `CREATE OR REPLACE` replaces the SET clause. |
| D3 | **Membership comes only from `app.user_id`.** The zero-argument definer function `member_projects()` returns the projects where I am a live member, the project is `active` or `archived`, and my user is not deleted.<br>• Every member, tenant and worker-download check uses `project_id IN (SELECT member_projects())`.<br>• EXECUTE is granted to member, app and worker.<br>• There is no project setting. Functions take `p_project`, but it is always intersected with `member_projects()`.<br>• The definer sees only its **own** `project_members` and `users` rows. That breaks the recursion between `projects` and `project_members` policies. | projects-impl item 2. `app_user_id()` trusts whoever opens the transaction (`0001:22-25`). One rule, so 8.18's frozen-account check is added in one place. V4, V5. |
| D4 | **`ProjectTx` is its own type, not `Tx<R>`.**<br>• `Db::member(user)` opens it with `BEGIN ISOLATION LEVEL REPEATABLE READ, READ ONLY`.<br>• It sets `role = thinktin_member`, `app.user_id` and `statement_timeout = 15s`.<br>• It offers only the narrow reads in §2.2 and `finish()`.<br>• 25006 maps to `Error::Forbidden`. | The generic `impl<R> Tx<R>` blocks contain writes and locks: `append_event` (`events.rs:37-73`), `insert_inbox` (`inbox.rs:100`), `lock_project` (`projects.rs:57-63`), and others. A separate type makes "narrow" a compile-time fact. `Pool::begin_with` exists (sqlx-core 0.9 `pool/mod.rs:391`). V7. |
| D5 | **Directory rows come from member policies plus column grants**, so the SQL barely changes and the JSON is identical:<br>• projects, without budget columns;<br>• project_members, including `left_reason` for the author status;<br>• project_agents, without `allow_computer` and `consented_at`;<br>• users `(id, display_name)`, for **live** co-members only;<br>• instances `(id, user_id, agent_id, name)`, for live agents of readable projects whose instance is not deleted. `state` is not granted; the policy filters on it.<br>Budgets come from the definer function `my_project_budget(p)`, which returns my own row. | `projects.rs:132-142, 258-351`. projects-impl item 4. V3. |
| D6 | **Run and event content reaches members only through four definer functions**: `project_run(p, run)`, `project_run_tree(p, root)`, `project_runs(p, instance, before, limit)` and `project_run_events(p, run, limit)`. Each projects a whitelist in SQL, and each has its own index-friendly WHERE (V12).<br>• `thinktin_member` has **no** grant on runs, events, approvals, tool_calls, usage_records, credentials, model_routes, vault_*, devices, user_keys, project_keys, project_invites, board_posts, inbox_items, plans or outbox.<br>• An unknown event kind is dropped; an unknown state becomes `running`. | projects-impl item 6. The impl critic measured `Rows Removed by Filter: 199999` for the single six-argument draft (B4). |
| D7 | **Member event view: the newest ≤500 whitelisted events of one run, oldest first, with `truncated`.** No `seq` and no cursor; the live feed is 8.19. | The per-instance seq would reveal other activity on the instance (item 6). |
| D8 | **`events`, `approvals` and `artifacts` get `project_id`, `space_kind` and `space_id`.**<br>• A BEFORE INSERT trigger, `fill_space_from_run()`, fills them from the run as the caller sees it. They are frozen on UPDATE.<br>• A composite FK `(run_id, space_kind, space_id) → runs (id, space_kind, space_id)` keeps them consistent. The old `(run_id, user_id)` FKs stay.<br>• All three FKs are added **valid in 0050**, with `runs` and the three tables set to NO FORCE in the same transaction. 0050 already holds ACCESS EXCLUSIVE on all three, so a separate VALIDATE migration gains nothing; the draft's 0051 is dropped. | projects-impl item 1. V1, V2. Under FORCE, the owner's FK validation sees nothing (`0046:1-2`). |
| D9 | **Narrowed tenant policies.** `ALTER POLICY … USING`; WITH CHECK is unchanged.<br>• runs, run_grants, events, approvals: private rows, plus project rows while I am a live member.<br>• artifacts: **private only**.<br>• inbox_items: private rows, plus receipts (`project_receipt(subtype)`), plus project notices while I am a live member.<br>• **Project tables (0049):** deleted projects are hidden; only active solo projects can be updated or receive members and agents. An instance delete can still mark its agent left in an archived solo project.<br>• **Column grants (0054):** tenants may UPDATE only `inbox_items.read_at`. They may not INSERT approvals, and may UPDATE only the four decision columns.<br>**Tenant lists also filter `project_id IS NULL`:** instance and user run lists, the instance event page and WS, and `event_range`. `events_after` and `event_range` move to `impl Tx<Tenant>`. | • projects-impl item 2 and "迁移与放量" 8.14–8.16.<br>• `tenant_read` is creator-only and status-blind (`0039:181-208`); only `own_project`/`writable_solo` (`projects.rs:420-428, 555-566`) checked status before.<br>• Tenant inbox UPDATEs write only `read_at`: `inbox.rs:145,157,168,245,253,265` and `instances.rs:412`.<br>• Approvals are inserted only by the worker (`approvals.rs:100-103`); the tenant UPDATE is at `:273`.<br>• `events_after`/`event_range` are `impl<R>` (`events.rs:37,76,96`), and all their callers are tenant. |
| D10 | **`inbox_project_guard` (CREATE OR REPLACE).** Checks run in this order:<br>1. Supplied project fields from a non-worker → 42501.<br>2. With `run_id` set, it reads the run as the caller. Not visible → 23503. Project absent → derived from the run. Different → 23514.<br>3. A derived project for a non-worker → 42501.<br>4. A receipt subtype with a run or without a project → 23514. | 8.14 plan §9 (`projects-8.14-plan.md:819`). Putting the worker-only check first keeps 8.14's `inbox_project_fields_are_server_only` (`tests/projects.rs:275-366`) returning `Forbidden` for tenants (impl B2). |
| D11 | **Every `DELETE /v1/projects/{id}` is a soft delete, shared or not.** It is one short worker transaction in D3 lock order (`projects-8.14-plan.md:17`):<br>1. users;<br>2. the project lock;<br>3. my member row;<br>4. status `deleted`;<br>5. `DELETE FROM project_keys`;<br>6. revoke pending invites;<br>7. lock project_agents and mark them left;<br>8. cancel project runs and settle their approvals;<br>9. revoke project grants;<br>10. mark the hidden notices read;<br>11. `project_deleted` receipts to the locked live members.<br>**Cleanup** is bounded, retryable and try-lock only. It starts 10 minutes after the delete, and it deletes the row only once nothing references it.<br>`/v1/teams/{id}` DELETE keeps 409 on shared projects. Tenant DELETE on projects is revoked. | • projects.md §4.6; projects-impl item 7.<br>• `runs_project_agent` is NO ACTION (`0045:6-7`).<br>• Tenant delete is dead code (`projects.rs:523`, `teams.rs:84-86`; only tests call it). |
| D12 | **Archive and unarchive are creator only.**<br>• Archive sets status `archived`, revokes invites, cancels project runs (settling approvals) and revokes grants. Agents stay. No new keys, artifacts or invites.<br>• Unarchive sets `active`.<br>• `GET /v1/projects` now lists archived projects, which `status` already shows. | projects.md §4.6; projects-impl test 4. The list (`projects.rs:262`) and the detail (`:278`) disagreed; now one rule applies. |
| D13 | **Erase, in D3 order after `lock_projects` (`users.rs:207`):**<br>1. For each project the user created: soft delete, key delete, `stop_project`, and other members' hidden notices marked read with SKIP LOCKED. **No receipts in 8.15.**<br>2. The user's own `project_agents` rows are marked left.<br>3. `cancel_user_runs`.<br>4. Delete only the **private** runs.<br>5. Delete the approvals and tool_calls of the user's project runs, by run_id; private ones cascade.<br>6. Delete `live_activities`.<br>7. Delete non-whitelisted events of project runs, and **whitelist-scrub** the payloads of the kept ones.<br>8. Null `runs.error` and `runs.state_reason` on kept project runs.<br>9. Mark only `role = 'member'` rows as erased.<br>The user's project runs and whitelisted events stay in other people's projects, with the owner shown as erased. | • projects.md §10; projects-impl item 7.<br>• The creator's surviving member row would violate `CHECK (role = 'member' OR left_at IS NULL)` (`0039:44`) under `users.rs:249-250` (security C1, impl B1).<br>• `tool_calls` has only PK `(run_id, key)` (`0012:4-10`); `approvals` has only the partial `approvals_pending` (`0001:346`).<br>• `live_activities` holds `push_token` (`0018:15,37`).<br>• Kept payloads hold `raw` and `title` (`proto/src/shim.rs:148-162`) and `reason`/`attempt`/`wait_code` (`executor.rs:1178-1185`).<br>• Receipts: inserting into other members' inboxes takes KEY SHARE on their user rows after the project locks (`projects-impl.md:103-104`). |
| D14 | **Project DEK.**<br>• The KMS context and AAD subject is `project:<uuid>`.<br>• It is created lazily on the first publish: the KMS wrap happens **outside** any transaction, then `insert_project_key` runs under `lock_project` while the project is active, with `ON CONFLICT DO NOTHING`, and the winner is re-read.<br>• Every read checks status in the same SQL.<br>• The key is destroyed in the delete transaction.<br>• Only the api and worker processes unwrap it.<br>• Blob key: `projects/<p>/<a>`. | • `keyvault/lib.rs:62-68, 497-505, 768-779`; `aliyun/src/kms.rs:39-41`.<br>• `user_vault` holds a transaction across KMS (`orchestrator/artifacts.rs:158-211`).<br>• The FK takes only KEY SHARE on projects, so the lock is needed. |
| D15 | **Project artifacts are served only on `/v1/projects/{id}/artifacts*`.** The download re-checks `member_projects()` (with `app.user_id` set in that worker transaction) and the key in one SQL statement, then decrypts. The tenant artifact routes become private-only. Project artifacts are deleted only by cleanup. | projects.md §5; `0002:103,109`; impl simplification 5. |
| D16 | **Gateway on project paths:** `store::Error::Forbidden` (42501, and 25006 through D4) → 404. It is logged at **`error!`** and counted in `thinktin_project_forbidden_total`, so a missing production GRANT is not silent.<br>Every `/v1/projects*` and `/v1/project-templates*` response, and the project download, carry `Cache-Control: no-store`.<br>The new routes are not behind `cross_user_projects`. | `gateway/src/error.rs:66-95` sends Forbidden to 500 today. 8.14 plan §9 (`:818`). The gateway sets no Cache-Control anywhere today (grep). |
| D17 | **`/v1/project-templates*` aliases `/v1/team-templates*`.** Same handlers and JSON; adopt returns `201 ProjectDetail`. | 8.14 D16 (`projects-8.14-plan.md:30,920`). |
| D18 | **Harden all four legacy SECURITY DEFINER functions in 0049**, keeping them SECURITY DEFINER:<br>• `ensure_event_partitions` and `drop_event_partitions_before` (`0001:288-321`): `public.%I`, `public.events`, `'public.events'::regclass`;<br>• `queue_artifact_blob_purge` (`0007:40-46`) and `queue_workspace_archive_purge` (`0023:31-58`, **four** `blob_purge` references at `:39,42,47,53`): `public.blob_purge`.<br>All four get `SET search_path = pg_catalog, public, pg_temp`. | With `search_path = public` and no `pg_temp`, temporary relations come first. `thinktin_app` has no grant on `blob_purge` (`0007:36-38`), so the purge triggers must stay definer. V9. |
| D19 | **Startup role check:** `Db::check_roles()` next to `check_migrations` (`server/src/lib.rs:57`).<br>• The service login must be able to SET ROLE to `thinktin_app`, `thinktin_worker` and `thinktin_member`. Missing roles are reported, not raised as 42704.<br>• The login must not be a member of `thinktin_project_definer`.<br>• Superuser sessions (dev) skip the check. | The test pool is superuser (`testing.rs:12-13`). V10. |
| D20 | **`Run.project_id: Option<ProjectId>`** (serde default, skipped when none) is selected by `runs.rs` `columns!()`. The FFI `Run.project_id` is `#[uniffi(default = None)]`.<br>• `put_runs` skips project runs.<br>• `Cache::forget_project` runs on leave, on removal or delete receipts, and on project 404s. | `runs.rs:192-199`; `cache.rs:156-172`. Precedent `ffi.rs:448-449`, so the Swift `ThinktinCore.Run(...)` calls (`ConversionTests.swift:18,51`, `CoreClient118Tests.swift:51`) still compile. |
| D21 | **`project_deleted` receipt** (Info subtype). `project_archived` and the rest wait for 8.19. | 8.14 plan §9 (`:820`); 8.19 (`:843`). |
| D22 | **Invite previews stay worker reads**, filtered by phone or token hash. So does the creator's invite list. | Preview readers are not members (`project_invites.rs:144-156, 468-498, 668-721`), so `ProjectTx` cannot serve them. This is a deliberate exception to the 8.14 §9 bullet "(and the preview's member list)" (`projects-8.14-plan.md:817`). |
| D23 | **Exits settle what they hide.**<br>• Cancelling project runs (on leave, remove, withdraw, delete, archive or erase) also cancels their pending approvals and marks the approval notices read with SKIP LOCKED.<br>• Leave and remove mark the leaver's non-receipt notices for that project read.<br>• Delete does the same for every live member: locked users directly, the rest with SKIP LOCKED. | `unread_inbox_count` (`inbox.rs:178-189`) feeds the badge (`outbox.rs:557`) and has no project filter. Hidden rows cannot be marked read by the tenant. The cancel helpers (`runs.rs:858, 899`) never did what `cancel_run_approvals` (`approvals.rs:183-200`) does. |

---

## 1. Migrations

### 1.1 `0049_project_member_role.sql` (one transaction)

```sql
-- 项目的成员读（WBS 8.15，docs/projects.md 第 5、9 节，docs/projects-impl.md 第 2 条，progress/drafts/projects-8.15-plan.md）。
-- 两个新角色由高权限账号预先建好（属主没有 CREATEROLE，docs/deploy-checklist.md 第 3 节），这里按名字先查：
--   thinktin_member          ProjectTx 用：默认对业务表没有权限，只有下面列出的列；行只放行“我是存活成员、项目没删”。
--   thinktin_project_definer SECURITY DEFINER 函数的属主：NOLOGIN、NOBYPASSRLS、NOINHERIT、不是任何角色的成员，自己也受
--                            行级安全约束（只看得到自己的成员行、用户行）。迁移账号是它的成员（WITH INHERIT FALSE,
--                            SET TRUE）：能把函数交给它，又不继承它的权限。服务角色都不能是这两个角色的成员（继承了就拿到
--                            成员读策略，或者定义者对 runs、events.payload 的列权限）。
-- 成员关系只按 app.user_id 算（member_projects() 没有参数）：手动传别的项目 id、设 app.project_id 之类的都读不到。
-- 定义者函数：search_path 固定、表名（包括要建的表名）带 public.、撤销 PUBLIC 的 EXECUTE；先授权、再改属主（ACL 跟着过去，
-- 迁移账号不继承新属主，改完就授不了权）。以后要改：GRANT CREATE → SET LOCAL ROLE thinktin_project_definer →
-- CREATE OR REPLACE（重写 SET search_path）→ RESET ROLE → REVOKE CREATE。
-- 另外：项目软删除以后（后台清理之前）租户策略也挡住删了的项目；四个旧的定义者函数固定 search_path。
-- 前提同 0039：第一次部署之前发布。

DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_member') THEN CREATE ROLE thinktin_member NOLOGIN NOBYPASSRLS; END IF; EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_project_definer') THEN CREATE ROLE thinktin_project_definer NOLOGIN NOBYPASSRLS NOINHERIT; END IF; EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $$;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname IN ('thinktin_member', 'thinktin_project_definer')
                 AND (rolsuper OR rolbypassrls OR rolcanlogin OR rolcreaterole OR rolcreatedb))
       OR (SELECT rolinherit FROM pg_roles WHERE rolname = 'thinktin_project_definer')
       -- 这两个角色不是任何角色的成员。
       OR EXISTS (SELECT 1 FROM pg_auth_members am JOIN pg_roles r ON r.oid = am.member
                   WHERE r.rolname IN ('thinktin_member', 'thinktin_project_definer'))
       -- 服务角色都不是这两个角色的成员（迁移账号、登录账号不在这张单子里：它们只 SET ROLE）。
       OR EXISTS (SELECT 1 FROM pg_auth_members am JOIN pg_roles g ON g.oid = am.roleid
                    JOIN pg_roles m ON m.oid = am.member
                   WHERE g.rolname IN ('thinktin_member', 'thinktin_project_definer')
                     AND m.rolname IN ('thinktin_app', 'thinktin_worker', 'thinktin_llmgw', 'thinktin_relay')) THEN
        RAISE EXCEPTION 'thinktin_member and thinktin_project_definer must be NOLOGIN NOBYPASSRLS (the definer NOINHERIT), members of no role, and no service role may be their member';
    END IF;
    -- 超级用户（开发库、压测的临时库）跳过：pg_has_role 对它总是真。
    IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
        IF NOT pg_has_role(current_user, 'thinktin_project_definer', 'SET') THEN
            RAISE EXCEPTION 'grant thinktin_project_definer to the migration owner WITH INHERIT FALSE, SET TRUE (docs/deploy-checklist.md section 3)';
        END IF;
        IF pg_has_role(current_user, 'thinktin_project_definer', 'USAGE') THEN
            RAISE EXCEPTION 'the migration owner must not inherit thinktin_project_definer (GRANT ... WITH INHERIT FALSE, SET TRUE)';
        END IF;
    END IF;
END $$;
GRANT USAGE ON SCHEMA public TO thinktin_member, thinktin_project_definer;

-- 我是存活成员、项目进行中或归档、我没注销的项目。所有成员策略、租户收窄、worker 的下载核对都用它。
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
GRANT EXECUTE ON FUNCTION member_projects() TO thinktin_member, thinktin_app, thinktin_worker;
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

-- 租户的项目策略也看状态（之前只有 own_project、writable_solo 在代码里查）：删了的（清理之前）看不到；只有进行中的单人
-- 项目改得了名、加得进成员和 agent；删实例时归档的单人项目里自己的 agent 照样能标成离开（共享项目的由 worker 撤下）。
ALTER POLICY tenant_read ON projects USING (creator_id = app_user_id() AND status <> 'deleted');
ALTER POLICY tenant_update ON projects
    USING (creator_id = app_user_id() AND shared_at IS NULL AND status = 'active')
    WITH CHECK (creator_id = app_user_id() AND shared_at IS NULL AND status = 'active');
ALTER POLICY tenant_insert ON project_members
    WITH CHECK (user_id = app_user_id() AND role = 'creator' AND left_at IS NULL
                AND EXISTS (SELECT 1 FROM projects p WHERE p.id = project_id
                              AND p.creator_id = app_user_id() AND p.shared_at IS NULL AND p.status = 'active'));
ALTER POLICY tenant_insert ON project_agents
    WITH CHECK (user_id = app_user_id() AND NOT dedicated
                AND EXISTS (SELECT 1 FROM projects p WHERE p.id = project_id
                              AND p.creator_id = app_user_id() AND p.shared_at IS NULL AND p.status = 'active'));
ALTER POLICY tenant_update ON project_agents
    USING (user_id = app_user_id()
           AND EXISTS (SELECT 1 FROM projects p WHERE p.id = project_id
                         AND p.creator_id = app_user_id() AND p.shared_at IS NULL AND p.status <> 'deleted'))
    WITH CHECK (user_id = app_user_id()
                AND EXISTS (SELECT 1 FROM projects p WHERE p.id = project_id
                              AND p.creator_id = app_user_id() AND p.shared_at IS NULL AND p.status <> 'deleted'));

-- 删项目一律软删除（worker），租户不能再硬删单人项目（会跳过销毁密钥、后台清理）。
-- deploy-safe: 8.14 起删项目、删团队都走 worker（orchestrator::projects::delete），上一版不再用租户的删除
DROP POLICY tenant_delete ON projects;
-- deploy-safe: 同上
REVOKE DELETE ON projects FROM thinktin_app;
-- 后台清理找删了的项目（表小，按 0039 的前提没有流量）。
CREATE INDEX projects_deleted ON projects (deleted_at) WHERE status = 'deleted';

-- 加固四个旧的定义者函数（0001、0007、0023）：search_path = public 且没写 pg_temp 时临时表排在最前，能遮住 events、
-- blob_purge。要建、要删的表名也带 public.（search_path 第一项是 pg_catalog，不带就建到 pg_catalog 里去，报错）。
CREATE OR REPLACE FUNCTION ensure_event_partitions(start_month date, months integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    m date := date_trunc('month', start_month)::date;
    name text;
BEGIN
    FOR i IN 0..months - 1 LOOP
        name := format('events_%s', to_char(m, 'YYYYMM'));
        EXECUTE format('CREATE TABLE IF NOT EXISTS public.%I PARTITION OF public.events FOR VALUES FROM (%L) TO (%L)',
                       name, m, (m + interval '1 month')::date);
        m := (m + interval '1 month')::date;
    END LOOP;
END $$;
CREATE OR REPLACE FUNCTION drop_event_partitions_before(before date) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    part text;
    dropped integer := 0;
BEGIN
    FOR part IN
        SELECT c.relname FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = 'public.events'::regclass AND c.relname ~ '^events_[0-9]{6}$'
    LOOP
        IF (to_date(substr(part, 8), 'YYYYMM') + interval '1 month')::date <= before THEN
            EXECUTE format('DROP TABLE public.%I', part);
            dropped := dropped + 1;
        END IF;
    END LOOP;
    RETURN dropped;
END $$;
CREATE OR REPLACE FUNCTION queue_artifact_blob_purge() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    INSERT INTO public.blob_purge (blob_key) VALUES (OLD.blob_key) ON CONFLICT DO NOTHING;
    RETURN OLD;
END $$;
CREATE OR REPLACE FUNCTION queue_workspace_archive_purge() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    own text := 'workspaces/' || replace(OLD.user_id::text, '-', '') || '/';
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF starts_with(OLD.workspace_archive_key, own) THEN
            INSERT INTO public.blob_purge (blob_key) VALUES (OLD.workspace_archive_key) ON CONFLICT DO NOTHING;
        END IF;
        IF starts_with(OLD.workspace_archive_pending, own) THEN
            INSERT INTO public.blob_purge (blob_key) VALUES (OLD.workspace_archive_pending) ON CONFLICT DO NOTHING;
        END IF;
        RETURN OLD;
    END IF;
    IF starts_with(OLD.workspace_archive_key, own)
       AND OLD.workspace_archive_key IS DISTINCT FROM NEW.workspace_archive_key THEN
        INSERT INTO public.blob_purge (blob_key) VALUES (OLD.workspace_archive_key) ON CONFLICT DO NOTHING;
    END IF;
    -- 上传完成时待定的对象变成正式的，不删。
    IF starts_with(OLD.workspace_archive_pending, own)
       AND OLD.workspace_archive_pending IS DISTINCT FROM NEW.workspace_archive_pending
       AND OLD.workspace_archive_pending IS DISTINCT FROM NEW.workspace_archive_key THEN
        INSERT INTO public.blob_purge (blob_key) VALUES (OLD.workspace_archive_pending) ON CONFLICT DO NOTHING;
    END IF;
    RETURN NEW;
END $$;
```

Notes:
- **Checker.** `CREATE OR REPLACE FUNCTION`, `CREATE/DROP/ALTER POLICY` and `ALTER FUNCTION … OWNER` are not flagged (`check_migrations.py:162-175, 217-228`). The `REVOKE`s carry `deploy-safe`. `REVOKE … ON FUNCTION member_projects()` is exempt because the function is created in the same file. `CREATE OR REPLACE` keeps owner and ACL, so `0001:476-478` still holds.
- **Production.** The GRANT from §5.4 must exist before this migration runs.

### 1.2 `0050_run_scope_columns.sql` (one transaction)

```sql
-- 事件、审批、产出物的空间（docs/projects-impl.md 第 1 条：保留 (run_id, user_id) 外键，再加 scope 一致性外键）。
-- 空间不由调用方给：BEFORE INSERT 触发器按调用者看得到的运行算（租户看不到的——退出了的项目里自己的运行——算成私人，
-- 外键随即拒绝），建了不能改。项目运行的子行因此不用改写入方就带上项目。
-- 锁、前提同 0039：第一次部署之前发布，表是空的。三个外键都在这里直接加（不用 NOT VALID 再单独检查）：审批、产出物加列、
-- 回填已经拿着 ACCESS EXCLUSIVE 到提交；events 是分区表，PostgreSQL 16 本来就不支持分区表上的 NOT VALID 外键（扫描每个
-- 分区，events 和 runs 拿 SHARE ROW EXCLUSIVE 到提交）。有线上库时先看表多大，或者等 PostgreSQL 18。
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
ALTER TABLE approvals ADD CONSTRAINT approvals_run_space FOREIGN KEY (run_id, space_kind, space_id)
    REFERENCES runs (id, space_kind, space_id) ON DELETE CASCADE;
ALTER TABLE artifacts ADD CONSTRAINT artifacts_run_space FOREIGN KEY (run_id, space_kind, space_id)
    REFERENCES runs (id, space_kind, space_id) ON DELETE CASCADE;
ALTER TABLE runs FORCE ROW LEVEL SECURITY;
ALTER TABLE events FORCE ROW LEVEL SECURITY;
ALTER TABLE approvals FORCE ROW LEVEL SECURITY;
ALTER TABLE artifacts FORCE ROW LEVEL SECURITY;

-- 回填之后才建触发器（触发器不许改 space_id）。分区表的触发器会复制到已有和以后的分区。payload 等别的列不在 UPDATE OF 里。
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
    ADD CONSTRAINT approvals_space CHECK (space_kind IN ('private', 'project') AND CASE space_kind
        WHEN 'private' THEN project_id IS NULL AND space_id = user_id
        ELSE project_id IS NOT NULL AND space_id = project_id END);
-- deploy-safe: 同上，artifacts_space 触发器
ALTER TABLE artifacts ALTER COLUMN space_id SET NOT NULL,
    ADD CONSTRAINT artifacts_space CHECK (space_kind IN ('private', 'project') AND CASE space_kind
        WHEN 'private' THEN project_id IS NULL AND space_id = user_id
        ELSE project_id IS NOT NULL AND space_id = project_id END);
```

Why this is correct:
- **NULL run ids.** A NULL `run_id` on events skips the FK (MATCH SIMPLE).
- **No new lock type.** The referencing side already takes KEY SHARE on the run through the old `(run_id, user_id)` FK.
- **Lookup indexes.** `events_run` (`0001:285`), `approvals (run_id, request_id)` (`0001:340`) and `artifacts_run` (`0007:26`) serve the RI lookups.
- **Purge does not trip the UPDATE branch.** All three tables reference runs with `ON DELETE CASCADE` (`0001:283,344`, `0002:88`), so a purge never produces an `UPDATE OF run_id`.
- **The checker** only warns ("slow") on the valid FKs.

### 1.3 Concurrent indexes (one statement per file, first bytes `-- no-transaction`, as in 0041–0044)

- `0051_artifacts_project_index.sql`: `CREATE INDEX CONCURRENTLY artifacts_project ON artifacts (project_id, id DESC) WHERE project_id IS NOT NULL;` Serves the project artifact list and cleanup.
- `0052_runs_project_recent_index.sql`: `CREATE INDEX CONCURRENTLY runs_project_recent ON runs (project_id, id DESC) WHERE project_id IS NOT NULL;` Serves `project_runs` and newest-first cleanup. `runs_project` (`0043:3`) is ordered for the FK.
- `0053_inbox_project_index.sql`: `CREATE INDEX CONCURRENTLY inbox_project ON inbox_items (project_id) WHERE project_id IS NOT NULL;` Serves cleanup and the D23 mark-read.
- `events` gets no new index: PG16 cannot run `CREATE INDEX CONCURRENTLY` on a partitioned table, and `events_run` serves every per-run access.

### 1.4 `0054_project_scoped_reads.sql` (one transaction)

```sql
-- 项目运行对成员可读、退出即不可见（WBS 8.15，docs/projects-impl.md 第 2、6 条）。
-- 1. 运行、事件只经四个定义者函数给成员：按白名单投影（新的事件种类默认看不到），没有实例序号、失败原因、花费、审批。
-- 2. 租户读自己的运行、授权、事件、审批：项目行只在“我还是存活成员、项目没删”时看得到；产出物只看私人的（项目产出物走
--    /v1/projects/{id}/artifacts）；收件箱的项目回执按 subtype 照常看得到。
-- 3. 收件箱的 project_id 从运行算（0047 留下的 8.15 一条）；租户对收件箱只改 read_at，审批只做决定。
-- 收紧策略：上一版（8.14）没有项目运行、项目产出物，不读这些行。

-- 项目回执的子类型（proto::domain::notice_subtype::PROJECT_RECEIPTS，测试核对两边一样）：租户策略、守卫、后台清理共用。
-- 不是定义者函数，没有 SET（内联进策略）；8.19 加回执时 CREATE OR REPLACE 这一个函数。
CREATE FUNCTION project_receipt(subtype text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT subtype IN ('project_invite', 'project_joined', 'project_left', 'project_removed',
                       'project_agent_left', 'project_agent_removed', 'project_deleted') $$;

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

-- 项目运行（成员能看的字段）。三个函数各一条固定的 WHERE（SQL 函数按通用参数规划，“p IS NULL OR 列 = p”用不上索引）。
CREATE FUNCTION project_run(p_project uuid, p_run uuid)
RETURNS TABLE (id uuid, kind text, user_id uuid, instance_id uuid, parent_run_id uuid, root_run_id uuid,
               step_key text, source text, prompt text, state text, summary text,
               created_at timestamptz, started_at timestamptz, finished_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
    SELECT r.id, r.kind, r.user_id, r.instance_id, r.parent_run_id, r.root_run_id, r.step_key, r.source, r.prompt,
           public.project_run_state(r.state), r.summary, r.created_at, r.started_at, r.finished_at
      FROM public.runs r
     WHERE r.id = p_run AND r.project_id = p_project AND r.project_id IN (SELECT public.member_projects()) $$;
-- 一棵树（同一空间的外键保证子孙都在这个项目里），先建的在前，最多 500 个（runs_tree）。
CREATE FUNCTION project_run_tree(p_project uuid, p_root uuid)
RETURNS TABLE (id uuid, kind text, user_id uuid, instance_id uuid, parent_run_id uuid, root_run_id uuid,
               step_key text, source text, prompt text, state text, summary text,
               created_at timestamptz, started_at timestamptz, finished_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
    SELECT r.id, r.kind, r.user_id, r.instance_id, r.parent_run_id, r.root_run_id, r.step_key, r.source, r.prompt,
           public.project_run_state(r.state), r.summary, r.created_at, r.started_at, r.finished_at
      FROM public.runs r
     WHERE r.root_run_id = p_root AND r.project_id = p_project AND r.project_id IN (SELECT public.member_projects())
     ORDER BY r.created_at, r.id
     LIMIT 500 $$;
-- 项目的运行，新的在前，p_before 往下翻（runs_project_recent），p_instance 只看一个 agent 的。
CREATE FUNCTION project_runs(p_project uuid, p_instance uuid, p_before uuid, p_limit integer)
RETURNS TABLE (id uuid, kind text, user_id uuid, instance_id uuid, parent_run_id uuid, root_run_id uuid,
               step_key text, source text, prompt text, state text, summary text,
               created_at timestamptz, started_at timestamptz, finished_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
    SELECT r.id, r.kind, r.user_id, r.instance_id, r.parent_run_id, r.root_run_id, r.step_key, r.source, r.prompt,
           public.project_run_state(r.state), r.summary, r.created_at, r.started_at, r.finished_at
      FROM public.runs r
     WHERE r.project_id = p_project AND r.project_id IN (SELECT public.member_projects())
       AND r.id < coalesce(p_before, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)
       AND (p_instance IS NULL OR r.instance_id = p_instance)
     ORDER BY r.id DESC
     LIMIT least(greatest(coalesce(p_limit, 50), 1), 200) $$;

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
REVOKE ALL ON FUNCTION project_run(uuid, uuid), project_run_tree(uuid, uuid),
    project_runs(uuid, uuid, uuid, integer), project_run_events(uuid, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION project_run(uuid, uuid), project_run_tree(uuid, uuid),
    project_runs(uuid, uuid, uuid, integer), project_run_events(uuid, uuid, integer) TO thinktin_member;
GRANT CREATE ON SCHEMA public TO thinktin_project_definer;
ALTER FUNCTION project_run(uuid, uuid) OWNER TO thinktin_project_definer;
ALTER FUNCTION project_run_tree(uuid, uuid) OWNER TO thinktin_project_definer;
ALTER FUNCTION project_runs(uuid, uuid, uuid, integer) OWNER TO thinktin_project_definer;
ALTER FUNCTION project_run_events(uuid, uuid, integer) OWNER TO thinktin_project_definer;
-- deploy-safe: 只收回上面临时给的 CREATE
REVOKE CREATE ON SCHEMA public FROM thinktin_project_definer;

-- 项目产出物的索引（没有 blob_key：下载由 worker 在同一句 SQL 里按 member_projects() 再核对，并取密钥）。
GRANT SELECT (id, user_id, instance_id, run_id, root_run_id, project_id, name, version, content_type, size, sha256,
              created_at) ON artifacts TO thinktin_member;
CREATE POLICY member_read ON artifacts FOR SELECT TO thinktin_member USING (project_id IN (SELECT member_projects()));

-- 租户收窄（WITH CHECK 不变）。项目行只有 worker 写得出（运行、授权：fill_space；收件箱：inbox_project_guard）；租户还是
-- 存活成员时，可以往自己的项目运行上追加事件（取消、打断），空间由 fill_space_from_run 从运行算，成员视图只显示白名单
-- 种类；退出以后看不到运行，追加被外键拒绝。
ALTER POLICY tenant ON runs
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));
ALTER POLICY tenant ON run_grants
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));
ALTER POLICY tenant ON events
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));
ALTER POLICY tenant ON approvals
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));
ALTER POLICY tenant ON artifacts USING (user_id = app_user_id() AND project_id IS NULL);
-- 回执按 subtype（不按 run_id 为空：run_id 是 ON DELETE SET NULL）；守卫保证回执带项目、不带运行。
ALTER POLICY tenant ON inbox_items
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_receipt(subtype)
           OR project_id IN (SELECT member_projects())));

-- 租户对收件箱只改 read_at，改不了一条提醒指向的运行（守卫只在插入时从运行算项目）。
-- deploy-safe: 上一版的租户代码只写 read_at（inbox.rs mark_inbox_read / mark_inbox_unread / settle_*，instances.rs 删实例）
REVOKE UPDATE ON inbox_items FROM thinktin_app;
GRANT UPDATE (read_at) ON inbox_items TO thinktin_app;
-- 审批只由 worker 插入（approvals.rs create_approval）；租户只做决定（SELECT … FOR UPDATE 有列的 UPDATE 权限就够）。
-- deploy-safe: 上一版的租户代码不插审批，UPDATE 只写这四列（approvals.rs decide_approval）
REVOKE INSERT, UPDATE ON approvals FROM thinktin_app;
GRANT UPDATE (state, decided_option, decided_by, decided_at) ON approvals TO thinktin_app;

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
    -- 先挡租户自己填的项目字段（错误码和 8.14 一样）。
    IF (NEW.project_id IS NOT NULL OR NEW.project_invite_id IS NOT NULL) AND current_user <> 'thinktin_worker' THEN
        RAISE EXCEPTION 'project fields in inbox_items are written by the server only'
            USING ERRCODE = 'insufficient_privilege';
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
        -- 项目运行的提醒（算出来的）也只有 worker 写得出。
        IF NEW.project_id IS NOT NULL AND current_user <> 'thinktin_worker' THEN
            RAISE EXCEPTION 'project fields in inbox_items are written by the server only'
                USING ERRCODE = 'insufficient_privilege';
        END IF;
    END IF;
    -- 回执按 subtype 绕过成员检查，所以必须带项目、不带运行（不然 worker 写错一条运行提醒，退出以后还看得到）。
    IF public.project_receipt(NEW.subtype) AND (NEW.run_id IS NOT NULL OR NEW.project_id IS NULL) THEN
        RAISE EXCEPTION 'project receipts carry a project and no run' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
```

- **Trigger list unchanged.** The trigger list from `0047:75-76` stays as it is. The FK action `ON DELETE SET NULL (run_id)` does not fire the trigger.
- **Repointing `run_id`.** Tenants can no longer change `run_id` (column grant), and the worker never does.
- **EXECUTE on `project_receipt`.** It stays with PUBLIC because the function is pure. Tenants need EXECUTE for the inlined policy (V11).

---

## 2. Store API (`crates/store`)

### 2.1 `lib.rs`, `schema.rs`, `error.rs`

- **New module.** Add `mod project_reads;` and `pub use project_reads::{ProjectTx, ProjectRunFilter};`.
- **`Db::member`**, after `Db::relay` (`lib.rs:171-180`):

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

- **`Db::check_roles()`** goes in `schema.rs`, next to `check_migrations` (`schema.rs:132`), and is called at `server/src/lib.rs:57`.
  - It returns nothing when `session_user` is a superuser.
  - Otherwise it runs:

    ```sql
    SELECT w.name FROM unnest($1::text[]) AS w(name) LEFT JOIN pg_roles r ON r.rolname = w.name
     WHERE NOT coalesce(pg_has_role(session_user, r.oid, 'SET'), false)
    ```

    with `['thinktin_app','thinktin_worker','thinktin_member']`. A missing role gives a NULL oid, so `pg_has_role` returns NULL instead of raising 42704 (V10).
  - It also runs `SELECT pg_has_role(session_user, 'thinktin_project_definer', 'MEMBER')`.
  - Any finding becomes `Error::Schema("… ; docs/deploy-checklist.md §3")`.
- **`error.rs:69`.** Add `Some("25006") => Error::Forbidden(db.message().to_owned())`.

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

Every method runs as `thinktin_member`, and every list method starts with `require_project`. **Integer arguments to the SQL functions are bound as `i32`**: `u32` has no encoder, and `bigint` does not resolve to `integer` (V12).

1. **`require_project(p) -> Result<ProjectStatus>`.** `SELECT status FROM projects WHERE id = $1`. No row means NotFound.
2. **`my_projects() -> Vec<ProjectSummary>`.** `MEMBER_SUMMARY_SQL` plus `ORDER BY p.created_at, p.id`; it includes archived projects. This is `SUMMARY_SQL` (`projects.rs:132-142`) with three changes: `$1` becomes `app_user_id()`, the `i.state <> 'deleted'` clauses move into the instances policy, and the creator join is `LEFT JOIN users cu`.

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
   - **Summary:** `MEMBER_SUMMARY_SQL AND p.id = $1`; NotFound if absent.
   - **Members:** `projects.rs:285-296`, with `LEFT JOIN users` and the agent subquery without `i.state`.
   - **Agents:**

     ```sql
     SELECT a.instance_id, a.user_id, i.agent_id, i.name, a.is_lead, a.position, a.added_at
       FROM project_agents a JOIN instances i ON i.id = a.instance_id
      WHERE a.project_id = $1 AND a.left_at IS NULL ORDER BY a.position, a.instance_id
     ```

   - **Budget:** `SELECT daily_token_limit, total_token_limit FROM my_project_budget($1)`.
   - `is_me` and `mine` compare against `self.user`. `limits` is the default.
4. **`authors(p) -> HashMap<UserId, ProjectAuthor>`** (private):

   ```sql
   SELECT m.user_id, CASE WHEN m.left_at IS NULL THEN u.display_name END, m.left_at IS NULL,
          coalesce(m.left_reason = 'erased', false)
     FROM project_members m LEFT JOIN users u ON u.id = m.user_id WHERE m.project_id = $1
   ```

   A live member maps to `{user_id, display_name, member}`, an erased one to `{None, None, erased}`, and anything else (including an owner with no row) to `{None, None, left}`.
5. **Runs:**
   - `project_runs(p, &ProjectRunFilter)`: `require_project`, then `SELECT * FROM project_runs($1, $2, $3, $4)`, binding `(p, instance, before, limit.clamp(1, 200) as i32)`. Rows go through `authors`.
   - `project_run(p, run)`: `SELECT * FROM project_run($1, $2)`. No row means NotFound.
   - `project_run_tree(p, run)`: `project_run` gives the root, then `SELECT * FROM project_run_tree($1, $2)`, which is already in ascending order.
6. **`project_run_events(p, run, limit) -> ProjectRunEvents`.**
   - Call `project_run(p, run)` first (NotFound if absent).
   - Run `SELECT kind, data, created_at FROM project_run_events($1, $2, $3)` with `$3 = (limit.clamp(1, 500) + 1) as i32`.
   - `truncated` is `rows > limit`; drop the oldest extra row.
7. **Artifacts:**
   - `project_artifacts(p, before, limit)`: `require_project`, then:

     ```sql
     SELECT id, user_id, instance_id, run_id, root_run_id, name, version, content_type, size, sha256, created_at
       FROM artifacts WHERE project_id = $1 AND ($2::uuid IS NULL OR id < $2) ORDER BY id DESC LIMIT $3
     ```

     with limit 1..=200. Uses `artifacts_project`; rows go through `authors`.
   - `project_artifact(p, id)`: the same columns with `WHERE project_id = $1 AND id = $2`.

**Worker removals.** `Tx<Worker>::my_projects` and `project_detail` (`projects.rs:258-351`) are deleted, and `SUMMARY_SQL` moves into `project_reads.rs`.

**Orchestrator switch.** `orchestrator::projects::my_projects` and `detail` (`orchestrator/src/projects.rs:57-70`) switch to `db.member(user)` with the same signatures. Callers are unchanged: `gateway/src/routes/projects.rs:68-71, 112-119, 143` and `project_invites.rs:111`.

### 2.3 Tenant changes

- **`runs.rs`.**
  - `columns!()` (`:192-199`) gains `project_id`; `Row` and `into_run` set `Run.project_id`.
  - `Tx<Tenant>::runs` (`:464-482`) and the `list_runs` macro (`:492-504`) add `AND project_id IS NULL`. It is a residual filter.
- **`events.rs`.**
  - `events_after` and `event_range` move from `impl<R>` (`:37, 76, 96`) into `impl Tx<Tenant>`. All callers are tenant: `gateway/routes/events.rs:50,66-67,141` and the test helpers in `orchestrator/tests/{e2e_shim,executor}.rs` and `control/tests/lifecycle.rs`.
  - `events_after` adds `AND project_id IS NULL`.
  - `event_range` uses `(SELECT min(seq) FROM events WHERE instance_id = $1 AND project_id IS NULL)`.
  - `recent_run_events` is unchanged.
- **`artifacts.rs`.** `Row`, `columns!` and `StoredArtifact` gain `project_id: Option<ProjectId>`. The tenant reads and `delete_artifact` are private-only through the policy.
- **Approvals and inbox.** Policy and column grants only.
- **Dead code.** Remove `Tx<Tenant>::delete_solo_project` (`projects.rs:522-533`) and `delete_team` (`teams.rs:84-86`). Point their tests (`tests.rs:1362,1445`, `tests/projects.rs:138`) at the worker `delete_project`.
- **Test that changes with 0049.** In `tests.rs:1452-1460`, `DELETE FROM projects WHERE id = $1` as a tenant now raises 42501 (no grant). It moves out of the "0 rows" loop into a `Forbidden` assertion.

### 2.4 Worker: lifecycle (`project_members.rs`, `projects.rs`, `runs.rs`, `grants.rs`, `approvals.rs`)

Every flow follows the D3 lock order (`projects-8.14-plan.md:17`).

#### Helpers

- **`runs.rs` `settle_cancelled_approvals(ids: &[Uuid])`** (crate-private, D23):

  ```sql
  WITH gone AS (UPDATE approvals SET state = 'cancelled', decided_by = 'system', decided_at = now()
                 WHERE run_id = ANY($1) AND state = 'pending' RETURNING id)
  UPDATE inbox_items SET read_at = now() WHERE id IN (
      SELECT id FROM inbox_items WHERE approval_id IN (SELECT id FROM gone) AND kind = 'approval'
         AND read_at IS NULL FOR UPDATE SKIP LOCKED)
  ```

  It is called by `cancel_project_agent_runs` (`:858`), `cancel_project_member_runs` (`:899`) and the new `cancel_project_runs`. Their final `UPDATE runs` gains `RETURNING id`, and they still return the count.
- **`runs.rs` `cancel_project_runs(p, reason) -> u64`:**
  1. `lock_runs_where!("project_id = $1")`;
  2. `bump_epochs_where!("project_id = $1")`;
  3. `UPDATE runs SET state='cancelled', state_reason=$2, wait_code=NULL, lease_owner=NULL, lease_expires_at=NULL, finished_at=now(), updated_at=now() WHERE project_id=$1 AND state NOT IN ('succeeded','failed','cancelled') RETURNING id`;
  4. `settle_cancelled_approvals`.
- **`grants.rs` `revoke_project_grants(p, reason) -> u64`.** `revoke_project_member_grants` (`grants.rs:256-275`) with the predicate `project_id = $1`.
- **`project_members.rs` `read_project_notices(p, users: &[UserId], nowait: bool)`:**

  ```sql
  UPDATE inbox_items SET read_at = now() WHERE id IN (
      SELECT id FROM inbox_items WHERE project_id = $1 AND user_id = ANY($2) AND read_at IS NULL
         AND NOT coalesce(project_receipt(subtype), false) /* nowait: FOR UPDATE SKIP LOCKED */)
  ```

  It uses `inbox_project`. Users locked in step 1 use `nowait = false`; everyone else uses `true` (D3 "a user's inbox rows …").
- **`stop_project(p, reason, mark_left: bool) -> (runs, grants)`:**
  1. `SELECT 1 FROM project_agents WHERE project_id = $1 AND left_at IS NULL ORDER BY instance_id FOR NO KEY UPDATE`;
  2. `cancel_project_runs`;
  3. `revoke_project_grants`;
  4. if `mark_left`, `UPDATE project_agents SET is_lead = false, left_at = now() WHERE project_id = $1 AND left_at IS NULL`.
- **`project_invites.rs` `revoke_pending_invites(p, locked: &[UserId]) -> u64`.** Factored out of `delete_unshared_project` (`:936-953`).
- **`exit_member`** (`project_members.rs:357-424`). After marking the member row left, call `read_project_notices(project, &[member], false)`. The member is locked through `project_actor`.

#### `delete_project(user, p, allow_shared) -> DeletedProject`

This replaces `delete_unshared_project` (`project_invites.rs:909-959`).

1. Pre-read, without locks, the pending invitees (`:914-923`) and the live non-creator members.
2. `project_actor(user, p, &[invitees, members], &[Active, Archived])`, then `require_creator("delete the project")`.
3. If the project is shared and `!allow_shared`, return `Conflict("project is shared")`.
4. `UPDATE projects SET status='deleted', deleted_at=now(), updated_at=now() WHERE id=$1`.
5. `DELETE FROM project_keys WHERE project_id=$1`.
6. `revoke_pending_invites`.
7. `stop_project(p, "project deleted", true)`.
8. Run `read_project_notices` for the live members: those in `actor.users` with `false`, the rest with `true`.
9. Return `{ name, creator, notify: live non-creator members in actor.users, invites_revoked, runs_cancelled, grants_revoked, shared }`.

Members who joined after the pre-read get no receipt (D3).

#### `archive_project(user, p) -> bool` and `unarchive_project(user, p) -> bool`

- **Archive:**
  1. `project_actor(.., &invitees, &[Active, Archived])`, then `require_creator`.
  2. If already archived, return false.
  3. `UPDATE projects SET status='archived', archived_at=now(), updated_at=now()`.
  4. `revoke_pending_invites`.
  5. `stop_project(p, "project archived", false)`. Approval notices use SKIP LOCKED.
- **Unarchive:** `project_actor(.., &[], &[Active, Archived])`, `require_creator`, then `UPDATE projects SET status='active', archived_at=NULL, updated_at=now() WHERE id=$1 AND status='archived'`.

#### Keys and artifacts (moved into C4 so later tests can use them)

- **`project_key(p) -> Option<(String, Vec<u8>)>`:**

  ```sql
  SELECT k.kms_key_id, k.wrapped_dek FROM project_keys k JOIN projects p ON p.id = k.project_id
   WHERE k.project_id = $1 AND p.status IN ('active','archived')
  ```

- **`insert_project_key(p, kid, wrapped)`:**
  1. `lock_project(p)`;
  2. `SELECT status = 'active' FROM projects WHERE id=$1` (false means NotFound);
  3. `INSERT … ON CONFLICT (project_id) DO NOTHING`;
  4. re-read the winner.
- **`run_project(run) -> Option<ProjectId>`.** `SELECT project_id FROM runs WHERE id=$1`.
- **`project_artifact_blob(user, p, id) -> (StoredArtifact, String, Vec<u8>, Locale)`.** Called in its own worker transaction, then rolled back. It first runs `SELECT set_config('app.user_id', $1, true)`, then:

  ```sql
  SELECT a.<columns>, k.kms_key_id, k.wrapped_dek, u.locale
    FROM artifacts a
    JOIN project_keys k ON k.project_id = a.project_id
    JOIN users u ON u.id = $1
   WHERE a.id = $3 AND a.project_id = $2 AND a.project_id IN (SELECT member_projects())
  ```

- **`insert_artifact`** (`artifacts.rs:119-156`). `NewArtifact` gains `project: Option<ProjectId>`.
  - With `Some(p)`: `lock_project(p)`, check that the project is active and has a key (else NotFound), then take the existing `artifact:{root}:{name}` advisory lock.
  - After the INSERT, a returned `project_id` that differs from `a.project` is `Error::Invalid("artifact space")`.

#### `purge_deleted_projects(batch, grace) -> u64`

One call is one transaction, and it never waits.

1. Find candidates:

   ```sql
   SELECT id FROM projects WHERE status='deleted' AND deleted_at < now() - make_interval(secs => $1)
    ORDER BY deleted_at, id LIMIT 20
   ```

2. Skip a candidate unless `SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))` succeeds, with `$1 = format!("project/{}", ProjectId(id))` built in Rust (as `project_members.rs:541-545` does).
3. Run these steps in order. The first step that deletes rows returns its count:
   1. `DELETE FROM artifacts WHERE id IN (SELECT id FROM artifacts WHERE project_id=$1 ORDER BY id LIMIT $2)`. The trigger queues `blob_purge`.
   2. `DELETE FROM inbox_items WHERE id IN (SELECT id FROM inbox_items WHERE project_id=$1 AND NOT coalesce(project_receipt(subtype), false) LIMIT $2 FOR UPDATE SKIP LOCKED)`.
   3. `DELETE FROM events WHERE (instance_id, seq, created_at) IN (SELECT instance_id, seq, created_at FROM events WHERE run_id IN (SELECT id FROM runs WHERE project_id=$1) LIMIT $2)`.
   4. `DELETE FROM runs WHERE id IN (SELECT id FROM runs WHERE project_id=$1 ORDER BY id DESC LIMIT $2)`. This cascades approvals, tool_calls and live_activities.
   5. `DELETE FROM run_grants WHERE id IN (SELECT id FROM run_grants WHERE project_id=$1 ORDER BY id DESC LIMIT $2)`.
   6. **Gate:** delete the project only when no runs, artifacts, run_grants or non-receipt inbox rows remain, checked without SKIP LOCKED. Then run `DELETE FROM projects WHERE id=$1 AND status='deleted'`, which cascades members, agents and invites (`0039:33,62,88`), and return 1. If the gate fails because inbox rows were skipped, try the next candidate.
4. Return 0 if nothing was done.

Each batch commits, so a crash resumes from what is left. The NO ACTION `runs_project_agent` FK can no longer fail the final delete.

#### Erase (`users.rs:183-274`), right after `lock_projects` (`:207`)

1. For each `id IN (SELECT id FROM projects WHERE creator_id = $1 AND status <> 'deleted')`:
   - soft delete;
   - `DELETE FROM project_keys`;
   - `stop_project(p, "account_deleted", true)`;
   - `read_project_notices(p, <other live members>, true)`;
   - no receipts.
2. Move `:246` (`UPDATE project_agents SET is_lead = false, dedicated = false, left_at = coalesce(left_at, now()) WHERE user_id = $1`) here, before any runs lock (D3 step 7 before 8).
3. `cancel_user_runs(id, "account_deleted")` (`runs.rs:835`).
4. Changes to the SQL list:
   - New: `DELETE FROM approvals WHERE run_id IN (SELECT id FROM runs WHERE user_id = $1 AND project_id IS NOT NULL)`.
   - New: the same for `tool_calls`; its PK starts with `run_id`.
   - New: `DELETE FROM live_activities WHERE user_id = $1` (`live_activities_user`, `0018:41`).
   - New: `UPDATE runs SET error = NULL, state_reason = NULL WHERE user_id = $1 AND project_id IS NOT NULL`. This does not fire `runs_space`, whose column list is `0040:42-43`.
   - `:218` becomes `DELETE FROM runs WHERE user_id = $1 AND project_id IS NULL`.
   - `:220` becomes a statement of its own, bound with `$2 = PROJECT_RUN_EVENT_KINDS`: `DELETE FROM events WHERE instance_id IN (SELECT id FROM instances WHERE user_id = $1) AND (project_id IS NULL OR NOT (kind = ANY($2)))`.
   - New: whitelist-scrub the kept events. `payload` is not in the `events_space` trigger's column list, so this does not fire it.

     ```sql
     UPDATE events SET payload = CASE kind
         WHEN 'agent.tool_call' THEN jsonb_strip_nulls(jsonb_build_object('tool_call_id', payload->'tool_call_id',
              'kind', payload->'kind', 'status', payload->'status'))
         WHEN 'agent.tool_call_update' THEN jsonb_strip_nulls(jsonb_build_object('tool_call_id', payload->'tool_call_id',
              'status', payload->'status'))
         WHEN 'agent.message' THEN jsonb_strip_nulls(jsonb_build_object('text', payload->'text'))
         WHEN 'agent.plan' THEN jsonb_strip_nulls(jsonb_build_object('entries', payload->'entries'))
         WHEN 'agent.turn_ended' THEN jsonb_strip_nulls(jsonb_build_object('stop_reason', payload->'stop_reason'))
         WHEN 'run.state' THEN jsonb_strip_nulls(jsonb_build_object('state', payload->'state'))
         WHEN 'artifact.published' THEN jsonb_strip_nulls(jsonb_build_object('artifact_id', payload->'artifact_id',
              'name', payload->'name', 'version', payload->'version'))
         WHEN 'pipeline.step_started' THEN jsonb_strip_nulls(jsonb_build_object('step', payload->'step'))
         ELSE '{}'::jsonb END
      WHERE instance_id IN (SELECT id FROM instances WHERE user_id = $1) AND project_id IS NOT NULL
     ```

   - Remove `:248` (`DELETE FROM projects WHERE creator_id`).
   - `:249-250` becomes `UPDATE project_members SET left_at = now(), left_reason = 'erased' WHERE user_id = $1 AND left_at IS NULL AND role = 'member'`. The creator row stays live in the soft-deleted project; `member_projects()` excludes it, and the purge removes it.

`instances` and `users` rows are never hard-deleted, so the kept rows' FKs hold.

---

## 3. Project DEK and project artifacts

**`orchestrator/src/artifacts.rs`:**

- **`project_key_context(p)`** is `format!("project:{p}")`.
- **`project_vault(db, kms, p, create)`:**
  1. Worker `project_key(p)`, then rollback. If found, wrap it in a `MemoryKeyStore` keyed by the context, the same shape as `user_vault` (`:158-211`).
  2. If not found and `!create`, return the new `ArtifactError::Gone`.
  3. Otherwise, with no transaction open, run `KeyVault::new(kms, MemoryKeyStore::default()).create_user_key(&ctx)` (`keyvault/lib.rs:497-505`).
  4. Worker `insert_project_key`, commit, and build the vault from the winner.
- **`publish`** (`:280-338`):
  1. Worker `run_project(origin.run)`.
  2. **Project space:**
     - `project_vault(.., true)`;
     - `seal_bytes(&ctx, &id, bytes)` (AAD `thinktin/blob/v1/` + `project:<p>` + id, `keyvault/lib.rs:768-779`);
     - blob key `projects/{p.simple()}/{id.simple()}`;
     - `insert_artifact(NewArtifact { project: Some(p), .. })`.
  3. **Private space:** unchanged, with `project: None` (`:306`).
  4. A failure after `put` deletes the blob, as today (`:330-336`).
- **`read(&StoredArtifact)`** (`:341-347`). With `a.project_id = Some(p)`, it uses `project_vault(.., false)` and `open_bytes(&ctx, ..)`.
- **`read_for_member(user, p, id)`:**
  1. Worker `project_artifact_blob` (D15), then rollback.
  2. Blob `get`.
  3. `KeyVault` from the returned wrapped key, then `open_bytes`.
  4. No row means NotFound.
- **`ArtifactError::Gone`** maps to 404.

**Who unwraps.** Only the api process (downloads) and the worker process (tools), both as `thinktin_worker`. `thinktin_llmgw` has no grant on `project_keys` (`0039:224-226`), and the member and definer roles have none either (test 11).

**Scope.** The run decides the space (D8). Tool listing stays scoped to the run tree or the ask (`store/artifacts.rs:173-264`) until 8.17.

**Destroy and cleanup.**
- The key row is deleted in the delete transaction.
- Ciphertext is removed by the purge's artifact step → `blob_purge` → `purge_blobs` (`server/src/workers.rs:437-454`).
- S3 deletes are unversioned (`s3.rs:236-242`). Key destruction is the protection; see the deploy note in §8.

---

## 4. Member-readable project runs

**DTOs** go in `proto/src/domain.rs`, after `ProjectDetail` (`:1100`):

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
// notice_subtype: PROJECT_DELETED = "project_deleted"; PROJECT_RECEIPTS: [&str; 7] (the six at :1322-1332 + deleted)
// Run: #[serde(default, skip_serializing_if = "Option::is_none")] pub project_id: Option<ProjectId>
```

**What runs keep:** `id, kind, instance_id, owner, parent/root, step_key, source, prompt, coarse state, summary, times`.

**What runs drop:** `state_reason, error, wait_code, tokens_used, attempt, plan_id, trigger_id, fire_time, agent_version, run_grant_id, budget, max_attempts, steps, lease_*, interrupts_run_id, announced_at, urgent, answer_deadline, hook_id`.

**Event view fields:**

| Kind | Fields |
|---|---|
| `tool_call` | `tool_call_id`, `tool_kind`, `status` (no `title`, no `raw`) |
| `tool_call_update` | `tool_call_id`, `status` |
| `message` | `text` |
| `plan` | `entries[{content, status}]` |
| `turn_started` | none |
| `turn_ended` | `stop_reason` |
| `state` | coarse `state` |
| `log_truncated` | none |
| `artifact` | `artifact_id`, `name`, `version` |
| `step_started` | `step` |

**Events always dropped:** `agent.thought`, `agent.usage`, `agent.permission_*`, `agent.platform_tool_call`, `agent.vault_reveal`, `vault.*`, `agent.update`, `agent.error`, `agent.ready`, `agent.session_lost`, `agent.exited`, `approval.decided`, `plan.*`, `hook.received`, `board.posted`, `instance.state`, `ask.sent`, `delegate.started` (the last two until 8.17), and `seq`.

**Owner extras.** The owner sees private fields through the tenant `GET /v1/runs/{id}`. That read is gated by membership (D9) and now carries `project_id`.

**How this stays correct once project runs execute (8.16/8.17):**
1. Child rows derive their space from the run by trigger and composite FK, and tenant writes into left projects fail with 23503.
2. New event kinds and states fail closed. Adding one is a reviewed migration (D2 recipe) plus a `PROJECT_RUN_EVENT_KINDS` change, both pinned by test 4.
3. Private lists and the private stream never return project rows.
4. Membership is re-checked on every request.
5. The claim-guard checklist is in §8.

---

## 5. Gateway, templates, client-core

### 5.1 Routes

Routes go in `gateway/src/routes/mod.rs`, after the 8.14 block at `:171-197`. Handlers go in a new `routes/project_runs.rs`; lifecycle handlers go in `routes/projects.rs`. The `/v1/projects*` and `/v1/project-templates*` routes are built in their own `Router`, with `axum::middleware::map_response` adding `Cache-Control: no-store`, and merged into the main router.

| Method and path | Body / query | Success | Errors |
|---|---|---|---|
| `GET /v1/projects` | — | 200 `{"projects":[ProjectSummary]}` (now includes archived) | — |
| `GET /v1/projects/{id}` | — | 200 `ProjectDetail` (member transaction) | 404 not a member, left or deleted |
| `DELETE /v1/projects/{id}` | — | 204 soft delete, shared or not | 404 outsider or already deleted; 403 member |
| `POST /v1/projects/{id}/archive` | — | 200 `ProjectDetail` (idempotent) | 404 / 403 |
| `POST /v1/projects/{id}/unarchive` | — | 200 `ProjectDetail` (idempotent) | 404 / 403 |
| `GET /v1/projects/{id}/runs` | `?instance_id=&before=&limit=` (1–200, default 50) | 200 `{"runs":[ProjectRun]}` | 404; 422 bad id or limit |
| `GET /v1/projects/{id}/runs/{run_id}` | — | 200 `ProjectRun` | 404 |
| `GET /v1/projects/{id}/runs/{run_id}/tree` | — | 200 `{"runs":[ProjectRun]}` | 404 |
| `GET /v1/projects/{id}/runs/{run_id}/events` | `?limit=` (1–500, default 200) | 200 `{"events":[ProjectRunEvent],"truncated":bool}` | 404 |
| `GET /v1/projects/{id}/artifacts` | `?before=&limit=` (1–200, default 50) | 200 `{"artifacts":[ProjectArtifact]}` | 404 |
| `GET /v1/projects/{id}/artifacts/{artifact_id}` | — | 200 `ProjectArtifact` | 404 |
| `GET /v1/projects/{id}/artifacts/{artifact_id}/content` | — | 200 bytes. Headers and labels match `artifacts::content` (`routes/artifacts.rs:93-135`), through a helper `download_response(s, locale, &StoredArtifact, bytes)` factored out of it. | 404, including a destroyed key |
| `GET`/`POST /v1/project-templates`, `DELETE /v1/project-templates/{id}` | as team-templates | same JSON | same |
| `POST /v1/project-templates/{id}/adopt` | `{"name"?}` | 201 `ProjectDetail` | as team adopt |

**Handler notes:**
- **Errors.** `pub(crate) fn project_error(e) -> ApiError`: `Forbidden` → `error!` + `thinktin_project_forbidden_total` + `ApiError::not_found("project")`; everything else → `e.into()`. It is used by every handler above and by the existing `/v1/projects/{id}/*` handlers.
- **Archive and unarchive** call `orchestrator::projects::{archive, unarchive}`, then `projects::detail`.
- **Delete.** `projects::delete` (`:147-156`) passes `allow_shared = true`. `teams::delete` (`teams.rs:97-110`) passes `false` and keeps its 409 and `NotPermitted`→404.
- **Adopt.** The body of `teams::adopt_template` (`teams.rs:187-230`) moves into a shared `fn adopt(..) -> ApiResult<TeamId>`.
- **Tenant routes** need no code change.

### 5.2 Orchestrator (`orchestrator/src/projects.rs`)

- **`delete(db, user, actor, p, allow_shared)`:**
  1. Worker `delete_project`.
  2. Audit `project.delete` with `{project, shared, invites_revoked, runs_cancelled, grants_revoked}`.
  3. For each `notify` member: `project_notice(.., PROJECT_DELETED)` with `dedupe_key = "project_deleted:{p}"`.
  4. Commit.
- **`archive`, `unarchive`:** the same pattern, audit only.
- **`texts.rs`:** `project_deleted(locale, name)`.
- **`sweep`** (`:537-563`):
  - Add up to `SWEEP_BATCHES` calls of `purge_deleted_projects(SWEEP_BATCH, PROJECT_PURGE_GRACE = 10 min)`, one transaction each, stopping at 0.
  - A purge error is logged at `warn!`, counted in `thinktin_project_purge_errors_total` and ends the loop, so it does not propagate through `workers.rs:507` and fail maintenance.
- **`docs/push.md`:** add `project_deleted`.

### 5.3 client-core

**`api.rs`** adds: `project_runs`, `project_run`, `project_run_tree`, `project_run_events`, `project_artifacts`, `project_artifact`, `project_artifact_content`, `archive_project`, `unarchive_project`, and the four `project_template` calls.

**`ffi.rs`:**
- New records: `ProjectAuthor`, `ProjectRun`, `ProjectRunEvent { run_id, kind, data_json, created_at }`, `ProjectRunEvents` and `ProjectArtifact`.
- `Run` (`:422`, `From` at `:453`) gains `#[uniffi(default = None)] pub project_id: Option<String>`.
- New methods go in the 8.14 block (`:3038-3262`).
- The doc of `delete_project` (`:3092`) changes.
- Project content is network-only: there is no local cache of it.

**`cache.rs`:**
- `forget_project(project)` deletes inbox items with that `project_id` whose subtype is not in `PROJECT_RECEIPTS` (via `remove_inbox`, `:377`). It also deletes `runs` rows whose JSON `project_id` matches, as a defensive measure.
- `put_runs` skips `project_id.is_some()`.

**Call sites:**
- after `leave_project` (`ffi.rs:3142-3146`) and `delete_project`;
- when inbox sync (`reconcile_inbox_page`, `cache.rs:305-355`) sees a `project_removed` or `project_deleted` item;
- when any project-path call returns `NotFound`.

**Other files:**
- `tools/client-core/ffi_smoke.py` covers the new methods.
- Android bindings are regenerated in their own commit (`apps/android/scripts/sync-core.sh --bindings-only`, as in `d4d1f18`).
- Apple bindings are generated at build time (`tools/client-core/build-apple.sh:85`).

### 5.4 Deploy docs

**`docs/deploy-checklist.md:57-71`** adds:

```sql
CREATE ROLE thinktin_member NOLOGIN NOBYPASSRLS;
CREATE ROLE thinktin_project_definer NOLOGIN NOBYPASSRLS NOINHERIT;
GRANT thinktin_project_definer TO thinktin_owner WITH INHERIT FALSE, SET TRUE;   -- PostgreSQL 16 语法
GRANT thinktin_member TO thinktin_server_login WITH INHERIT FALSE, SET TRUE;     -- 只 SET ROLE，不继承成员读策略
```

Existing lines stay as they are: `GRANT thinktin_app, thinktin_worker TO thinktin_server_login` (`:67`).

**`docs/release.md:73-78`:** the same `thinktin_member` grant.

**`testing.rs:85-98`:** inside the advisory-locked block:
- create `thinktin_member` (NOLOGIN NOBYPASSRLS) and `thinktin_project_definer` (NOLOGIN NOBYPASSRLS NOINHERIT) if missing;
- after the owner role exists, `GRANT thinktin_project_definer TO thinktin_test_owner WITH INHERIT FALSE, SET TRUE`.

---

## 6. Tests

All store tests use `TestDb::new()`: real Postgres, with migrations run as the non-superuser `thinktin_test_owner` and FORCE in effect (`testing.rs:58-65, 107-123`).

**Cast:**
- alice is the creator and bob a member of P1; alice alone has P2; carol is an outsider.
- Joining uses `join_raw` (`tests/projects.rs:31-58`) or the real accept.
- Project runs come from worker SQL or `copy_into_project` (`:1737`). `solo`, `join_raw` and `copy_into_project` become `pub(super)`.
- Events come from worker `append_event`, approvals from worker `create_approval`, keys from `insert_project_key`, and artifacts from `insert_artifact { project: Some(..) }`.

### 6.1 Store: new `crates/store/src/tests/boundary.rs` (`mod boundary;` in `tests.rs`)

1. **`member_reads_only_live_projects`** (C3).
   - bob: `my_projects` = [P1]; `project_detail(P2)` → NotFound.
   - carol sees nothing; `require_project(P1)` → NotFound.
   - Forged setting: `set_config('app.project_id', P2)` still gives `count(*) FROM projects WHERE id = P2` = 0, and `member_projects()` = {P1}.
   - 42501 (`Forbidden`) for each of: `approvals`, `tool_calls`, `usage_records`, `credentials`, `model_routes`, `vault_items`, `vault_requests`, `devices`, `user_keys`, `project_keys`, `project_invites`, `user_blocks`, `events`, `runs`, `inbox_items`, `board_posts`, `plans`, `outbox`, `audit_log`, `project_members.daily_token_limit`, `instances.state`.
   - A raw INSERT gives 25006 → `Forbidden`.
   - `my_project_budget` returns only bob's row.
2. **`detail_json_is_unchanged`** (C3).
   - Port `project_reads_follow_membership` (`tests/projects.rs:146`) to `db.member` and compare `serde_json::to_value` with the 8.14 expectations.
   - Cover a deleted instance not counted, a left agent hidden, member order, and `my_budget`.
   - An archived P1 is listed with `status = archived`.
3. **`leaving_hides_project_rows_everywhere`** (C6).
   - **Setup:** bob's b1 has project run R in P1 with tool_call, thought and message events, a pending approval with its `approval` notice, a project artifact, an unread run notice (worker), and a private run.
   - **Before leaving (bob as tenant):** `run(R)` is ok; `runs(b1)`, `list_runs`, `events_after(b1)` and `instance_artifacts(b1)` exclude project rows; `pending_approvals` includes R's approval.
   - **After `leave_project`:**
     - tenant `run(R)` → NotFound;
     - the approval is `cancelled` and its notice read (D23);
     - the inbox hides the run notice but shows `project_left`;
     - `unread_inbox_count(bob)` excludes the hidden notice (D23);
     - `delete_artifact` → NotFound;
     - member reads of P1 → NotFound.
   - **Alice:** sees R with `owner.status = left` and the artifact with `author.status = left`.
   - The private run is never visible to alice.
4. **`project_view_is_whitelisted`** (C6).
   - Store every kind, including `agent.permission_requested`, `agent.usage`, `agent.vault_reveal`, `approval.decided` and `agent.platform_tool_call`, each with a marker `raw`.
   - Only the 10 mapped kinds come back, with exactly the §4 fields, and no marker appears anywhere.
   - `waiting_quota` → `waiting_owner`; `backoff` → `running`.
   - `truncated` is true at limit 3.
   - **Forged ids (moved from test 1):** `project_runs(P2, …)`, `project_run(P2, r)`, `project_run_tree(P2, r)` and `project_run_events(P2, r, 10)` return no rows for bob.
   - `PROJECT_RUN_EVENT_KINDS` matches the text of `include_str!("../../migrations/0054_project_scoped_reads.sql")`.
   - `SELECT project_receipt(s)` is true for every `PROJECT_RECEIPTS` entry and false for `approval`, `info` and NULL.
5. **`scope_follows_the_run`.**
   - **C4 part:**
     - worker-appended events, approvals and artifacts of R get `space_kind = 'project'`;
     - a tenant append by bob on R derives the project;
     - `UPDATE events SET project_id = NULL` → `Invalid` (23514);
     - an approval whose space disagrees: `ALTER TABLE approvals DISABLE TRIGGER approvals_space` on the superuser pool, then a worker insert → `Invalid` (23503), then re-enable the trigger.
   - **C6 part (5b):** after bob leaves, the same tenant append → `Invalid` (23503).
6. **`inbox_project_is_derived`** (C6).
   - A worker run notice without `project_id` is stored with P1.
   - A mismatched `project_id` → `Invalid`.
   - A receipt subtype with `run_id` → `Invalid` (D10 step 4).
   - Bob as tenant: `insert_inbox(run_id = R)` → `Forbidden` while a member, `Invalid` after leaving.
   - Update 8.14's `inbox_project_fields_are_server_only` (`tests/projects.rs:275-366`):
     - the fixture uses `run_id: None`;
     - the "run deleted → `run_id` NULL, `project_id` kept" check uses a project run from `copy_into_project`;
     - the tenant `UPDATE … SET subtype` at `:330` now expects `Forbidden` (column grant).
7. **`deleting_makes_unreadable_then_purges`** (C7).
   - **`delete_project(alice, P1, true)`:**
     - bob's member reads → NotFound;
     - tenant `run(R)` → NotFound;
     - `project_key(P1)` → None;
     - runs are cancelled and epochs bumped (`epoch`, `tests/projects.rs:1789`);
     - agents are left;
     - invites are `revoked` and stay until the purge;
     - bob's non-receipt notices are read.
   - **Purge,** with batch 2 and grace 0:
     - commit each call, roll one back midway, and continue until 0;
     - while another transaction holds `FOR UPDATE` on one of P1's notices, the project row survives that round, and it is purged after release.
   - **At the end:**
     - no runs, events, artifacts, run_grants or non-receipt inbox rows remain;
     - receipts remain;
     - `blob_purge` holds every `blob_key`;
     - the `projects` row is gone.
   - Bob's receipt is checked over HTTP (§6.2).
   - Update `deleting_a_solo_project_keeps_invite_caps` (`tests/projects.rs:2086-2147`): use `delete_project(.., false)`, and at `:2117` assert no *pending* invites instead of `gone == 0`.
8. **`archive_is_read_only`** (C7).
   - Runs are cancelled (approvals too) and invites revoked.
   - Members still read detail, runs and artifacts.
   - `insert_project_key`, `insert_artifact` into P1, `add_project_agents` and `update_project` → NotFound.
   - Leave still works.
   - `unarchive` restores `active`.
9. **`erase_keeps_others_records`** (C7).
   - **Bob erased:**
     - R stays visible to alice with `owner.status = erased`;
     - its kept events carry only whitelisted keys: no `raw`, `title`, `reason` or `attempt`;
     - `runs.error` and `state_reason` are NULL;
     - R's thought events, its approval, its tool_calls and bob's `live_activities` are gone;
     - bob's private runs are gone.
   - **Alice (creator) erased:**
     - no 23514 or 23503;
     - P1 is soft-deleted and its key gone;
     - bob's project runs are cancelled.
   - The purge then removes P1.
   - Update `erase_and_project_flows_do_not_deadlock` (`tests/projects.rs:1886`, assertion at `:1993` → `count(*) FILTER (WHERE status <> 'deleted') = 0`) and `erasures_and_instance_deletes_do_not_deadlock` (`:2296`).
10. **`delete_races`** (C7), using a `tokio::sync::Barrier`:
    - delete vs `insert_project_key`: no key survives on a deleted project;
    - delete vs accept: the accept gets NotFound;
    - delete vs leave;
    - delete vs a member's erase: no 40P01.
11. **Schema** (in `tests.rs`):
    - **RLS for every role.** Generalize `every_tenant_table_the_app_can_touch_has_rls` (`:765-829`) to `thinktin_app`, `thinktin_member` and `thinktin_project_definer`: each reachable table has RLS and at least one policy for that role, and none has `qual = 'true'`.
    - **FORCE for every role.** Extend the FORCE query in `migrations_run_as_a_plain_owner` (`:836-865`) to tables the member and definer can reach. The draft's extension of the 0039 copy-test list (`:1024-1043`) is dropped.
    - **`member_roles_are_restricted`:**
      - both roles are NOLOGIN, NOBYPASSRLS, not superuser and members of nothing;
      - the `pg_auth_members` rows granting the definer are exactly `thinktin_test_owner`, with `inherit_option = false` and `set_option = true`;
      - `thinktin_member`'s table and column privileges equal the allow-list exactly (`information_schema.column_privileges`);
      - the allow-list gains the artifacts columns in C6.
    - **`definer_functions_are_locked_down`:**
      - every `prosecdef` function is either owned by `thinktin_project_definer` (with `proconfig` containing `search_path=pg_catalog, public, pg_temp`, no PUBLIC EXECUTE, and EXECUTE only for allow-listed roles) or is one of the four legacy functions, whose `proconfig` now has the same search_path;
      - `thinktin_project_definer` owns no relations (`pg_class.relowner`).
    - **`check_roles`:** with a temporary login role (unique name, created and dropped by the superuser pool), grants to app, worker and member pass. Revoking member, or granting the definer, gives `Error::Schema`.
12. **Migration backfill** (C4).
    - `TestDb::up_to(49)`.
    - Insert a project run with `db.worker()` (`copy_into_project`). `fill_space` rejects superusers (`0040:3,19-22`).
    - Insert an approval, an artifact and events for it as superuser; 0050's trigger does not exist yet.
    - `migrate_rest()`.
    - The rows carry project scope, and all three FKs are validated (pattern from the 0046 test at `tests.rs:868`).

**Changes to existing tests, by commit:**
- `tests.rs:1452-1460`: the DELETE moves to a `Forbidden` assertion (C2).
- `tests/projects.rs:275-366, 330`: C6.
- `tests/projects.rs:1993, 2086-2147, 2296`: C7.

### 6.2 Gateway (`crates/gateway/tests/api.rs`)

- **`project_runs_and_artifacts_over_http`.**
  - Alice and bob join via HTTP; carol is an outsider.
  - Seed R and its events with worker SQL, and publish a project artifact through the harness `ArtifactStore` (as at `:1267`).
  - **Bob:**
    - `GET /v1/projects/{p}/runs` → 200 with `owner`, `mine` and the coarse state, and no `error`, `tokens_used` or `wait_code` keys;
    - `/events` has no thought, usage, permission or `raw` content and no `seq`;
    - `/artifacts/{a}/content` returns the bytes, the label footer and `x-aigc`;
    - every project response carries `cache-control: no-store`.
  - **Carol:** every project path → 404.
  - **Bob, after `POST /leave`:**
    - every project path → 404;
    - `GET /v1/runs/{R}`, `/tree` and `/cancel` → 404;
    - `GET /v1/instances/{b1}/events` has no project events;
    - `GET` and `DELETE /v1/artifacts/{a}` → 404;
    - `GET /v1/inbox` shows `project_left` and not the run notice.
- **`deleting_a_shared_project_over_http`.**
  - In the existing test, the creator's leave 409 at `:5020` stays. The shared-DELETE 409 at `:5029` is removed: a 204 there would break the PATCH at `:5031-5039`.
  - In the new test:
    - DELETE → 204;
    - bob's inbox has `project_deleted`;
    - all project paths and the artifact content → 404;
    - a second DELETE → 404;
    - `DELETE /v1/teams/{id}` on a shared project still → 409 (`:2905-2915`, `:5257-5284` unchanged).
- **`archive_and_unarchive_over_http`.**
  - Member → 403, outsider → 404, creator → 200 with `status`.
  - The list shows the archived project.
  - `PATCH` and `POST /invites` → 404 while archived.
  - Unarchive → 200.
- **`project_templates_alias_over_http`.** CRUD works through `/v1/project-templates`, and adopt → 201 `ProjectDetail`. The template is also visible through `/v1/team-templates`.
- **`forbidden_is_404_on_project_paths`.** A unit test of `project_error(Forbidden(..))` checks the 404 and that the metric increments. One HTTP case revokes a column grant in the test database and expects 404.

### 6.3 client-core (`crates/client-core/tests/client.rs`; the harness at `:64-67` turns the switch on)

- **`ffi_project_content_and_forget`** covers runs, events and artifacts through the FFI:
  - a cached inbox item with `project_id = P` is gone after `leave_project`, while the `project_joined` receipt stays;
  - `project_runs` → NotFound;
  - `put_runs` stores nothing for a run with `project_id` set.
- A unit test in `cache.rs` covers `forget_project`.

### 6.4 Other

`cargo test --workspace`, plus orchestrator unit tests:
- `project_vault` creates the key once when two tasks race (`LocalKms`);
- `publish` into a project run seals with `project:<p>`, and a user DEK cannot open it;
- `read` after a delete → `Gone`.

---

## 7. Commit sequence

Each commit compiles, passes `cargo test --workspace`, is pushed immediately, and updates `docs/progress/claude-determined-lovelace-vn0j5h.md` (CLAUDE.md "防止工作丢失").

| # | Commit | Files |
|---|---|---|
| C1 | proto: the new DTOs, `PROJECT_RUN_EVENT_KINDS`, `PROJECT_DELETED`, `PROJECT_RECEIPTS`, `Run.project_id`; store selects `project_id` | `proto/src/domain.rs`, `store/src/runs.rs`, `orchestrator/src/delegate.rs` (test literals `:316,371`) |
| C2 | Migration 0049 (roles, member directory, tenant project policies, legacy hardening); test roles; deploy docs; error 25006; schema tests (roles, definer, RLS and FORCE per role); `tests.rs:1452-1460` | `migrations/0049_*.sql`, `store/src/{testing,error}.rs`, `store/src/tests.rs`, `docs/deploy-checklist.md`, `docs/release.md` |
| C3 | `ProjectTx`, `Db::member`, `project_reads.rs` (directory), `Db::check_roles` + test; orchestrator reads switched; worker reads removed; tests 1 and 2 | `store/src/{lib,schema,project_reads,projects}.rs`, `store/src/tests/{boundary,projects}.rs`, `orchestrator/src/projects.rs`, `server/src/lib.rs` |
| C4 | Migration 0050; `StoredArtifact.project_id`, `NewArtifact.project` (and `project: None` at `orchestrator/src/artifacts.rs:306` and `store/src/tests.rs:1686`); `project_key`, `insert_project_key`, `run_project`; tests 5 (C4 part) and 12 | `migrations/0050_*.sql`, `store/src/{artifacts,projects}.rs`, `orchestrator/src/artifacts.rs`, tests |
| C5 | Migrations 0051–0053 (indexes) | `migrations/0051_*.sql`, `0052_*.sql`, `0053_*.sql` |
| C6 | Migration 0054; tenant list filters; `events_after`/`event_range` moved to `Tx<Tenant>`; `ProjectTx` runs, events and artifacts; member allow-list updated; tests 3, 4, 5b and 6, plus the 8.14 inbox test fixes | `migrations/0054_*.sql`, `store/src/{runs,events,project_reads}.rs`, tests |
| C7 | Store lifecycle: `delete_project`, archive and unarchive, `stop_project`, `cancel_project_runs`, `settle_cancelled_approvals`, `read_project_notices`, `revoke_project_grants`, `purge_deleted_projects`, `project_artifact_blob`, erase changes, `exit_member` mark-read; tenant delete code removed; tests 7–10 and the existing-test updates | `store/src/{project_invites,project_members,projects,teams,runs,grants,users,artifacts}.rs`, tests |
| C8 | Orchestrator: `project_vault`, publish and read branches, `read_for_member`; delete, archive and unarchive wrappers; `project_deleted` receipt; sweep purge with error isolation; unit tests; push doc | `orchestrator/src/{artifacts,projects,texts}.rs`, `docs/push.md` |
| C9 | Gateway: `project_runs.rs`, `project_error` (+ metric), no-store layer, archive routes, delete semantics, template alias, download helper; API tests | `gateway/src/routes/{mod,projects,project_runs,teams,artifacts}.rs`, `gateway/tests/api.rs` |
| C10 | client-core: API, FFI (`#[uniffi(default = None)]`), cache forget and skip, tests, smoke script | `client-core/src/{api,ffi,cache,client}.rs`, `client-core/tests/client.rs`, `tools/client-core/ffi_smoke.py` |
| C11 | Android bindings regenerated (own commit, `apps/android/**` only) | `apps/android/core/src/main/kotlin/cn/thinktin/core/client_core.kt` |
| C12 | Docs: projects-impl "8.15 做了什么", the projects.md status line, this plan as `docs/progress/drafts/projects-8.15-plan.md`, the progress file | `docs/**` |

After the merge, delete `autosave/<branch>`.

---

## 8. What 8.15 leaves for 8.16–8.19

**8.16 (must be done before lifting the claim guard):**
- **Per-space sessions and storage:**
  - `ToolContext` (`orchestrator/src/shim.rs:69-75`) carries the space;
  - each (instance, project) gets its own session, HOME, cwd and workspace archive key;
  - `artifact_fetch` and the pipeline handoff (`tools.rs:644-666`, `pipeline.rs:246-249`) write project plaintext only into the project workspace;
  - dedicated instances.
- **Space filters:**
  - `unannounced_messages` (`runs.rs:1285-1302`) and `queue_urgent_run` (`:606-710`);
  - peers and `agent_status` (`peers.rs:93-112`);
  - the board tools (`board.rs:94`);
  - the executor resume brief (`executor.rs:295-320`).
- **Every other tenant-readable table with a `run_id`** gets a stamped `project_id` (derived as for inbox), the same membership-gated tenant policy, and a purge step:
  - `vault_requests` (`0009:26,38`);
  - `device_calls` (`0014:34,46`);
  - `board_posts` (`0025:12,22`);
  - `egress_requests` (`0034:16,26`);
  - `live_activities` (`0018:12,37`, CASCADE);
  - `content_reports` (`0019:9`, no FK).

  The first four are `ON DELETE SET NULL (run_id)`.
- **Status checks:** `fill_space_from_run` checks project status for event appends (projects-impl item 7: every decrypt and every event append).
- **Claims:** check live agents and live membership.

**8.17:**
- the project board;
- dispatch and project grants through an exposed `ProjectActor`;
- `PUT /v1/projects/{id}/lead`;
- cross-owner run trees: drop the old `(x, user_id)` FKs (`0001:251-255`) and detach cross-owner children on erase or withdraw;
- the artifact tool scope widened to the project;
- `ask.sent` and `delegate.started` in the member view;
- a member-facing artifact delete.

**8.18:**
- llm-gw enforcement of `project_members` budgets;
- approvals to the owner;
- per-project vault and computer;
- frozen accounts (`member_projects()` only excludes `deleted`);
- tenant notice paths (`tools.rs:187`, `vault.rs:167`, `routes/plans.rs:358`) for project runs, which D10 now rejects.

**8.19:**
- the project feed (`project_seq`) and live revocation of open streams;
- receipts: `project_archived`, member erased, erase-triggered `project_deleted` (D13), task results;
- possibly a project `PushKind`;
- the inbox FK for cross-owner notices;
- **reporting project content a member did not write** (5.5): `/v1/reports` is tenant-only (`routes/mod.rs:146`).

**15.7 / 16.6 / deploy:**
- review `left_reason` exposure to members;
- object-store bucket versioning must be off, or have a lifecycle rule, because deletes are unversioned;
- personal data inside project content that is kept after erase (16.6).

---

## Appendix A. Critic corrections

The verdicts are Applied, Applied (modified), or Rejected.

### Security critic

| # | Correction | Verdict | Reason (verified) |
|---|---|---|---|
| C1 | Erasing a creator fails with 23514 | **Applied** | `users.rs:248-250` and `0039:44`. D13 step 9 and the §2.4 erase list. |
| C2 | Test 12 cannot seed a project run as superuser | **Applied** | `0040:3,19-22`. It uses `db.worker()` / `copy_into_project`. |
| C3 | Three tests are scheduled before their migrations | **Applied** | The forged-id function checks move to test 4 (C6), test 5 is split into 5/5b, and the member allow-list is updated in C6. |
| C4 | The 0049 role check misses the dangerous directions | **Applied (modified)** | Its `pg_auth_members` form is used. The owner-INHERIT check and the D19 definer check skip superusers, because `pg_has_role` is always true for them (V10) and dev and loadtest migrate as superuser (`setup-db.sh:17`, `server/src/lib.rs:53`, `loadtest/src/scratch.rs:36`). As written, the critic's check would have broken every dev database. The deploy grant for the member role is INHERIT FALSE. |
| C5 | Deleted projects stay readable and writable through tenant policies | **Applied** | `0039:181-208`. `tenant_update ON project_agents` uses `status <> 'deleted'`, so instance deletes still mark agents left in archived solo projects (`instances.rs:393-398`). The worker backstop is `project_members.rs:485-565`. |
| C6 | Tenants can repoint inbox `run_id`; tenant INSERT on approvals | **Applied** | Every tenant inbox UPDATE writes only `read_at` (grep: `inbox.rs:145,157,168,245,253,265`, `instances.rs:412`). Every approval insert is a worker insert (`approvals.rs:100-103`; all `create_approval` callers are worker). Also added: `tests/projects.rs:330` now expects `Forbidden`. |
| C7 | The guard should enforce what the receipt exemption assumes | **Applied** | D10 step 4. All 8.14 receipts carry a project and no run (`orchestrator/projects.rs:24-28`). |
| C8 | Hidden unread items inflate the badge | **Applied** | `inbox.rs:178-189`. D23 and `read_project_notices`, using direct writes for locked users and SKIP LOCKED otherwise. |
| C9 | D18 and test 11 disagree about the legacy functions | **Applied (modified)** | All four are hardened. Created and dropped partition names must also be `public.%I`: with `pg_catalog` first, an unqualified `CREATE TABLE` targets `pg_catalog` and fails (V9). |
| C10 | List every other run-referencing tenant table for 8.16 | **Applied** | FKs verified at `0009:38`, `0014:46`, `0018:37`, `0025:22`, `0034:26`, `0019:9`. See §8. |
| C11 | The 0054 comment wrongly says only the worker writes project rows | **Applied** | Tenant appends at `gateway/routes/runs.rs:51,201,212`, `instances.rs:155`, `approvals.rs:46`. The comment is rewritten. |
| C12a | Erase seq-scans approvals and tool_calls | **Applied** | `0012:4-10`, `0001:346`. Deletes go by the `run_id` of project runs. |
| C12b | Bind the purge lock key from Rust | **Applied** | Same spelling as `project_members.rs:541-545`. |
| C12c | Generic event reads also filter worker callers | **Applied** | Moved to `impl Tx<Tenant>`; all callers are tenant (grep). |
| C12d | Test that the definer owns no relations | **Applied** | Test 11. |
| C12e | `Cache-Control: no-store` | **Applied** | No Cache-Control exists today (grep). D16. |
| C12f | Members cannot report project content | **Applied** | Added to §8 (8.19), plus an open question. |

### Implementation critic

| # | Correction | Verdict | Reason (verified) |
|---|---|---|---|
| B1 | Erase fails for every creator | **Applied** | Same as C1, plus the test updates at `tests/projects.rs:1993, 2117, 2296`. |
| B2 | Guard order breaks the 8.14 test and the tenant error code | **Applied** | Fixture verified at `tests/projects.rs:290-316`. The worker-only check runs first, then derivation, then the worker check again. The fixture and the SET NULL check change. |
| B3 | A bigint limit fails function resolution | **Applied** | Bind `i32` (V12). |
| B4 | Optional filters scan the whole project | **Applied** | Three run functions with fixed WHERE clauses, plus the `coalesce` cursor (as `runs.rs:499`). |
| B5a | `NewArtifact` built at `orchestrator/src/artifacts.rs:306` | **Applied** | `project: None` in C4. |
| B5b | Test 1 and test 5 ordering | **Applied** | As C3. |
| B5c | Key fixtures needed before C7 | **Applied** | `project_key`/`insert_project_key` moved to C4. |
| B5d | Test 12 seeding | **Applied** | As C2. |
| B5e | An approval with a disagreeing space cannot be built | **Applied** | `DISABLE TRIGGER approvals_space` on the superuser pool. `session_replication_role` would also disable the FK triggers. |
| B5f | `api.rs:5020` vs `:5029` | **Applied** | Only `:5029` moves into the new test; the PATCH at `:5031-5039` depends on it. |
| B5g | FFI `Run.project_id` breaks the Swift tests | **Applied** | `#[uniffi(default = None)]` (precedent `ffi.rs:448-449`). |
| B5h | `authors()` NULL bool | **Applied** | `coalesce(..., false)`. |
| I1 | Erase leaves private data on the project runs it keeps | **Applied (modified)** | `live_activities` deleted (`0018:15,37`); approvals and tool_calls deleted by run_id; `error`/`state_reason` nulled. The payload scrub is a **whitelist** CASE rather than `payload - 'raw' - 'title'`, so unknown keys fail closed. |
| I2 | Hidden approvals and notices stay pending | **Applied** | `settle_cancelled_approvals` in all three project cancel helpers (`runs.rs:858,899` and new). Archive uses SKIP LOCKED. |
| I3 | Role check misses the dangerous direction | **Applied (C4's form)** | The `pg_auth_members` join was chosen over `pg_has_role(r, …)` on an unnest; the latter raises 42704 when a role is missing. The test on the definer's `pg_auth_members` rows is added. |
| I4 | Purge can get stuck and fail maintenance | **Applied** | The final delete is gated, the key is built in Rust, and errors are isolated in `sweep` (`workers.rs:507`). |
| S1 | Drop 0051 | **Applied** | 0050 already holds ACCESS EXCLUSIVE with runs NO FORCE. Renumbered to 0049–0054. |
| S2 | D18 has four references and must stay SECURITY DEFINER | **Applied** | `0023:39,42,47,53`. Full SQL written out. |
| S3 | D16 hides a missing GRANT as 404 | **Applied (second option)** | The 8.14 §9 rule (`:818`) is kept, with logging at `error!` plus a metric. Limiting the mapping to `ProjectTx` handlers was not chosen. |
| S4 | Erase order | **Applied** | `stop_project` and the agent update run before `cancel_user_runs`. |
| S5 | One membership rule for downloads | **Applied** | Worker EXECUTE on `member_projects()`, with `app.user_id` set in the download transaction. |
| S6 | Drop the FORCE-list item | **Applied** | Replaced by extending `migrations_run_as_a_plain_owner`. |
| S7 | `check_roles` raises 42704 | **Applied** | LEFT JOIN `pg_roles`; a NULL oid gives NULL (V10). |
| S8 | `events_after` is `impl<R>` | **Applied** | As C12c. |
| S9 | Hard-coded receipt subtypes | **Applied** | `project_receipt(text)`, inlined into the policy (V11), used by the guard and the purge. |
| S10 | `fill_space_from_run` has no status check | **Applied** | Added to §8 (8.16). |
| S11 | Line references | **Applied** | D3 is at `:17`; 8.19 is at `:843`. |

### Found while verifying (not raised by either critic)

| # | Correction | Verdict | Reason |
|---|---|---|---|
| E1 | `REVOKE DELETE ON projects` in 0049 breaks `tests.rs:1452-1460` (a raw tenant `DELETE FROM projects` expects 0 rows) in C2 | **Applied** | That assertion becomes `Forbidden` in C2. |
| E2 | Superuser exemption for the role checks | **Applied** | See C4 and D19. |
| E3 | `public.%I` for partition names | **Applied** | See C9 and V9. |
| E4 | D22 departs from the 8.14 §9 bullet (`:817` "and the preview's member list") | **Applied (documented)** | Preview readers are not members, so `ProjectTx` cannot serve them. |

## 待定问题

- Archived projects in the project list: should they keep showing up there, marked as archived? Default chosen: yes. Members can still open an archived project read-only and can leave it.
- When a creator deletes their account, their projects are deleted too. Should the other members be told? Default chosen: for now the project just disappears for them with no notice. A 'project deleted' notice for this case comes with the notification work in 8.19.
- Deleting a shared project: should the creator be able to do it alone, at once, with no undo? Default chosen: yes. Members get a 'project deleted' notice, the project's key is destroyed right away, and the leftovers are cleaned up after 10 minutes. Nothing can be restored.
- What members see of another member's agent work: the task text, the agent's replies, plan steps, the type and status of each tool step, and the final summary. Not tool details, thinking, costs, errors or approvals. Default chosen: exactly this.
- Archiving stops any work the agents are doing in the project. Should that work restart when the project is unarchived? Default chosen: no. Unarchiving only makes the project editable again, and stopped tasks stay stopped.
- Former members are shown as 'left' or 'account deleted'. Should others ever see that someone was removed rather than left on their own? Default chosen: no. Removed and left look the same ('已退出的成员').
- Members cannot yet report content in a project that someone else wrote (the report button covers only your own content). Default chosen: keep cross-user projects switched off in production (the cross_user_projects setting) until reporting project content ships in 8.19.
