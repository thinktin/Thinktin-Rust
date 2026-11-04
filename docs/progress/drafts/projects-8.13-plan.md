# 8.13 实现方案定稿（2026-11-04）

workflow `projects-8-13-plan` 的最后一步：草稿按评审改过（采纳和不采纳的理由在附录）。英文原样，按这个实现。

# WP 8.13 implementation plan (final): project model and migration, with teams becoming single-user projects

Branch `claude/determined-lovelace-vn0j5h` @ `362813f`. That commit is `be8afae` plus the two draft files under `docs/progress/drafts/`; it has no code changes. I re-checked every file:line below at HEAD. Appendix A lists each critic correction and what happened to it.

**Verification in this pass.** I ran this on a scratch PostgreSQL 16.15 database as superuser, seeded with teams data at 0038, and dropped it afterwards. I changed no repo files. Results:

- **Backfill (corrected 0039):** copied T1/T2/T3. D, which was deleted, became `left_at` set and `is_lead = false`.
- **Agent marked `dedicated` by the worker, then the tenant's `delete_instance` retirement UPDATE:**
  - with the draft CHECK: fails with 23514;
  - with the draft `tenant_update ... WITH CHECK (... NOT dedicated)`: fails with 42501, which maps to 500;
  - with the corrected CHECK and policy: succeeds, and the tenant still cannot write `dedicated` (`permission denied`).
- **`fill_space` allowlist:** both the tenant and the superuser are refused with "server only", and the worker succeeds.
  - A private child of a project parent is rejected by `runs_parent_space`.
  - Moving a run between spaces is rejected with 23514.
- **Foreign key to a plain unique index:** `pg_constraint.conindid` of `runs_parent_space` is `runs_id_space`, so no `UNIQUE USING INDEX` is needed.
- **Foreign-key lookup on `run_grants` by project:** uses `run_grants_project`. Without that index, the plan is a filter over `run_grants_id_user_id_key` (or a seq scan).
- **CREATE INDEX CONCURRENTLY with a second session blocked on `pg_advisory_lock`:** fails with `deadlock detected`, and the index is left `indisvalid = f`.
- **Erase statements:** worked against a shared project and pending phone invites.
- **Linter (`tools/ci/check_migrations.py` `lint()`) on the new files:**
  - 0039: no findings;
  - 0040: the two `SET NOT NULL` statements need the `deploy-safe` comments they carry below, and two "add constraint" warnings remain (warnings only);
  - 0044–0046: no findings.

The non-superuser-owner behaviour (D8, the NO FORCE need, cascades under FORCE) relies on the draft's and the critic's earlier runs, which used a NOSUPERUSER NOCREATEROLE NOBYPASSRLS owner.

## 0. Decisions, and where they depart from design A

| # | Decision | Why |
|---|---|---|
| D1 | Migrations start at **0039** and run to 0046. Design A's 0031–0036 are already taken; the last migration is `0038_browser.sql`. | `tools/ci/check_migrations.py:318` requires contiguous numbers. (Line 29 is only the filename regex.) |
| D2 | **Single-user project writes go through `thinktin_app` RLS policies, not `Tx<Worker>`.** The policies allow only three things: projects I created that were never shared, a creator row for me, and my own instances as agents. | projects-impl.md "旧版领养" requires the restricted write path to reuse the tenant transaction. Adoption is one `Tx<Tenant>` (`gateway/src/routes/teams.rs:191-224`): `lock_instance_count`, then `control::adopt_in` (`control/src/lib.rs:216-224`), then `create_run_grant`, then `create_team`, then commit. |
| D3 | New column **`projects.shared_at`**. A trigger sets it when the first non-creator member row is inserted; only the worker can insert such rows, from 8.14. Every tenant write policy requires `shared_at IS NULL`. | This enforces "single-user only" in the database without SECURITY DEFINER: the tenant cannot see other users' member rows, so a policy cannot count them. It also makes the 8.13 tenant policies final, so 8.14 does not have to remember to narrow them. In 8.13 no project can become shared. Old `/v1/teams` writes on a shared project return 409 (design A instead allowed diff-only edits). |
| D4 | **`TeamId == ProjectId` and `TeamTemplateId == project template id`. The project tables are the only source of truth.** The new binary never reads or writes `teams`, `team_members` or `team_templates`. They are copied once, frozen, kept, and still erased on account deletion. They are dropped (marked `deploy-safe`) in the release after 12.25/13.18. No dual-write. **Precondition: 0039 ships before the first deployment.** | Both kinds of client hit one table, so there is no double adoption and no double editing. But release.md §3 requires the previous binary to keep working during a rollout: an old replica that adopts after 0039 would write a `teams` row the new binary never reads, leaving orphan instances, which "旧版领养" forbids. That is safe today only because there is no `v*` tag and RDS has not been created (`docs/handoff.md:131`). If the precondition fails, choose one of two options. Either this release dual-writes, or, once the old replicas are gone, the *next* release re-copies with `INSERT … SELECT … ON CONFLICT (id) DO NOTHING` for teams, members and templates. A re-copy in the same release is useless, because old replicas keep writing after it. |
| D5 | **8.13 adds no `thinktin_member` or `thinktin_definer` roles, no SECURITY DEFINER functions and no member policies.** Those belong to 8.15. | Per the brief, the tenant sees only its own rows until 8.15. All new trigger functions are SECURITY INVOKER and read nothing that depends on another user's RLS. |
| D6 | **Typed space columns on `runs` and `run_grants` only:** `project_id`, `space_kind IN ('private','project')` and `space_id`. The names avoid clashing with `run_grants.scope jsonb` (`0001_init.sql:163`) and `store::ArtifactScope`. New composite foreign keys sit *alongside* the old `(x,user_id)` ones (expand). 8.17 drops the old ones (contract). | impl item 1 asks for a typed scope, and ID collisions must not cross types. The claim guard (impl "8.14–8.16") needs `runs.project_id` to exist in every worker version before any project run is written. |
| D7 | **Invites and the project key table are created in 8.13** (schema only, worker-only grants). | WBS 8.13 (`docs/wbs.md:216`) and projects.md §3 list ProjectInvite. Design A put invites in P6. |
| D8 | **Tests migrate as a production-like owner.** `TestDb` creates `thinktin_test_owner` (LOGIN, no SUPERUSER, CREATEROLE, CREATEDB or BYPASSRLS) and migrates with it. This requires fixing the role DO-blocks in `0001_init.sql:16-18` and `0014_device_relay.sql:15`, which fail today for such an owner: PostgreSQL checks the CREATEROLE permission before it checks whether the role exists. | The impl plan requires tests that use the production migration account under FORCE RLS. Editing 0001/0014 is allowed only because no `v*` tag (`git tag -l 'v*'` is empty) and no deployed database exist. |
| D9 | **No new `/v1/projects*` routes, no Project FFI types, and no Android binding regeneration in 8.13.** | See §3 and §4. |
| D10 | **Columns rule:** the new tables carry the fields projects.md §3 names, plus the lifecycle fields that rows written from 8.14 need (`left_at`/`left_reason`, `consented_at`). Every other forward column arrives with the package that reads it: design A's `projects.policy`, `project_agents.preauthorized_tools`, `approval_timeout_secs` and `purpose`, and the vault-items table. | Adding a nullable or defaulted column to these new, tiny tables later costs nothing. Dropping `purpose` keeps the rule consistent. |

## 1. Migrations

### 1.0 Fix role creation in 0001 and 0014 (in commit C1)

Replace these lines:
- `crates/store/migrations/0001_init.sql:16-18`
- `crates/store/migrations/0014_device_relay.sql:15`

Use this pattern, and change the comment at `0001_init.sql:8` to match:

```sql
-- 角色先查再建：托管库的属主账号没有 CREATEROLE，CREATE ROLE 会在查重之前就报权限错，所以角色由高权限账号预先建好时
-- 这里必须跳过（docs/deploy-checklist.md 第 3 节）。并发建库仍可能撞唯一键，照样忽略。
DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_app') THEN CREATE ROLE thinktin_app NOLOGIN NOBYPASSRLS; END IF; EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $$;
-- same for thinktin_worker (NOLOGIN BYPASSRLS), thinktin_llmgw (NOLOGIN BYPASSRLS); 0014: thinktin_relay (NOLOGIN BYPASSRLS)
```

- A role that really is missing still fails loudly with "permission denied to create role", which is what we want. Silently swallowing `insufficient_privilege` would hide that.
- Docs:
  - `docs/deploy-checklist.md:59-64` (lines 59-60 say "迁移遇到已有的就跳过") becomes true as written.
  - Add one sentence to `docs/release.md:74` saying the check is by role name.
- Side effect: any persistent database that already applied 0001 now reports `modified` and must be recreated. Test databases are created fresh, so tests are unaffected.

### 1.1 `crates/store/migrations/0039_projects.sql` (one transaction)

```sql
-- 项目（WBS 8.13，docs/projects.md 第 3 节，docs/projects-impl.md“数据、身份与现有接口”）：项目、成员、项目 agent、
-- 邀请、项目密钥、项目模板；现有团队搬成单人项目（id 不变：TeamId 就是 ProjectId），团队模板搬成项目模板。
-- 这一版只有单人项目：thinktin_app 只能写自己创建、从没共享过（shared_at IS NULL）的项目，成员只有自己，agent 只能是
-- 自己的实例。跨用户的写（8.14 起：接受邀请、加入、移出）只走 thinktin_worker；按成员关系的读（thinktin_member）在 8.15。
-- 旧表 teams、team_members、team_templates 复制后不再读写，App 换成项目页（12.25、13.18）以后的版本再删。
-- 前提：这个迁移在第一次部署之前发布（还没有 v* 标签、没有线上库）。滚动发布时上一版副本还会写 teams（包括领养），新版
-- 看不到。如果发布时已经有跑着 ≤0038 程序的库：这一版改成双写，或者等旧副本全部下线后的下一次发布再补拷一次
-- （INSERT … SELECT … FROM teams ON CONFLICT (id) DO NOTHING，成员、模板同理）。
-- 锁：下面按 teams → team_members → team_templates → instances 拿 ACCESS EXCLUSIVE。有流量时会和领养（先 instances 后
-- teams）互相等；先拿 instances 又会和 GET/POST /v1/teams（先 teams 后 instances）互相等。死锁时整个迁移回滚，重跑即可；
-- 按上面的前提，迁移时没有流量。
-- 列：只建 projects.md 第 3 节列出的字段和 8.14 起写入的行要用的状态字段；项目范围、预授权工具、审批超时、用途、保险箱
-- 条目跟着用到它们的工作包（8.17、8.18）加。

CREATE TABLE projects (
    id          uuid PRIMARY KEY,
    creator_id  uuid NOT NULL REFERENCES users (id),
    name        text NOT NULL CHECK (length(name) BETWEEN 1 AND 64),
    goal        text NOT NULL DEFAULT '' CHECK (length(goal) <= 4000),
    status      text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived', 'deleted')),
    -- 第一次有别的用户加入的时间（project_members_share 触发器填）。之后不再是单人项目，租户事务不能再改它。
    shared_at   timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    archived_at timestamptz,
    deleted_at  timestamptz,
    CHECK (status <> 'archived' OR archived_at IS NOT NULL),
    CHECK (status <> 'deleted' OR deleted_at IS NOT NULL)
);
CREATE INDEX projects_creator ON projects (creator_id, created_at);

CREATE TABLE project_members (
    project_id        uuid NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
    user_id           uuid NOT NULL REFERENCES users (id),
    role              text NOT NULL CHECK (role IN ('creator', 'member')),
    daily_token_limit bigint CHECK (daily_token_limit > 0),     -- 8.18 用
    total_token_limit bigint CHECK (total_token_limit > 0),
    consented_at      timestamptz,                              -- 加入时确认“内容会发给模型厂商”（8.14）
    joined_at         timestamptz NOT NULL DEFAULT now(),
    left_at           timestamptz,
    left_reason       text CHECK (left_reason IN ('left', 'removed', 'erased')),
    PRIMARY KEY (project_id, user_id),
    CHECK ((left_at IS NULL) = (left_reason IS NULL)),
    CHECK (role = 'member' OR left_at IS NULL),                 -- 创建者不退出，只能删项目
    CHECK (role = 'creator' OR consented_at IS NOT NULL)
);
CREATE UNIQUE INDEX project_one_creator ON project_members (project_id) WHERE role = 'creator';
CREATE INDEX project_members_user ON project_members (user_id) WHERE left_at IS NULL;

CREATE TABLE project_agents (
    project_id     uuid NOT NULL,
    instance_id    uuid NOT NULL,
    user_id        uuid NOT NULL,                               -- 主人
    is_lead        boolean NOT NULL DEFAULT false,
    dedicated      boolean NOT NULL DEFAULT false,              -- 8.16；离开的行不算（见 project_agent_dedicated）
    position       integer NOT NULL DEFAULT 0,
    allow_computer boolean NOT NULL DEFAULT false,              -- 8.18
    added_at       timestamptz NOT NULL DEFAULT now(),
    left_at        timestamptz,                                 -- 撤回、实例删除：只标记（运行记录要引用这一行）
    PRIMARY KEY (project_id, instance_id),
    UNIQUE (project_id, instance_id, user_id),
    FOREIGN KEY (project_id, user_id) REFERENCES project_members (project_id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (instance_id, user_id) REFERENCES instances (id, user_id) ON DELETE CASCADE,
    -- 只约束负责人：租户删实例时改不了 dedicated（没有列权限），离开的专属行由唯一索引的条件排除。
    CHECK (left_at IS NULL OR NOT is_lead)
);
-- 一个项目最多一个负责人；离开的不占（旧的 team_one_lead 会把删掉的实例也算进去）。
CREATE UNIQUE INDEX project_one_lead ON project_agents (project_id) WHERE is_lead AND left_at IS NULL;
CREATE UNIQUE INDEX project_agent_dedicated ON project_agents (instance_id) WHERE dedicated AND left_at IS NULL;
CREATE INDEX project_agents_instance ON project_agents (instance_id) WHERE left_at IS NULL;
CREATE INDEX project_agents_user ON project_agents (user_id);

-- 邀请（8.14 才有接口）：手机号邀请存 E.164（和 login_codes 一样）；链接邀请只存令牌的哈希，一次有效。
CREATE TABLE project_invites (
    id            uuid PRIMARY KEY,
    project_id    uuid NOT NULL,
    inviter_id    uuid NOT NULL,
    kind          text NOT NULL CHECK (kind IN ('phone', 'link')),
    invitee_phone text,
    invitee_id    uuid REFERENCES users (id),
    token_hash    bytea UNIQUE,
    status        text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'accepted', 'declined', 'revoked', 'expired')),
    expires_at    timestamptz NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    settled_at    timestamptz,
    accepted_by   uuid REFERENCES users (id),
    FOREIGN KEY (project_id, inviter_id) REFERENCES project_members (project_id, user_id) ON DELETE CASCADE,
    CHECK (kind <> 'phone' OR (invitee_phone IS NOT NULL AND token_hash IS NULL)),
    CHECK (kind <> 'link' OR (token_hash IS NOT NULL AND invitee_phone IS NULL)),
    CHECK ((status = 'pending') = (settled_at IS NULL)),
    CHECK (status <> 'accepted' OR accepted_by IS NOT NULL)
);
CREATE INDEX project_invites_project ON project_invites (project_id, created_at DESC);
CREATE INDEX project_invites_inviter ON project_invites (inviter_id, created_at);   -- 每天的上限
CREATE INDEX project_invites_phone ON project_invites (invitee_phone) WHERE status = 'pending';
CREATE INDEX project_invites_invitee ON project_invites (invitee_id) WHERE status = 'pending';

-- 项目密钥（KMS 包裹的 DEK，8.15 起按需建）：删这一行就是销毁密钥。thinktin_app、thinktin_llmgw 没有权限；
-- 只有 worker（8.15 建密钥、删项目）。
CREATE TABLE project_keys (
    project_id  uuid PRIMARY KEY REFERENCES projects (id) ON DELETE CASCADE,
    kms_key_id  text NOT NULL,
    wrapped_dek bytea NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- 项目模板（原团队模板）：spec 仍是 TeamTemplateSpec，只有自己看得到。
CREATE TABLE project_templates (
    id         uuid PRIMARY KEY,
    user_id    uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name       text NOT NULL,
    spec       jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, user_id)
);
CREATE INDEX project_templates_user ON project_templates (user_id, created_at);

-- ---------- 团队搬成单人项目（id 不变） ----------
-- 生产的迁移账号受 FORCE 约束，看不到任何行（INSERT … SELECT 会悄悄复制 0 行）：同一个事务里临时去掉 FORCE，
-- 复制、核对，再加回来。新表在复制完之后才开 RLS。
ALTER TABLE teams NO FORCE ROW LEVEL SECURITY;
ALTER TABLE team_members NO FORCE ROW LEVEL SECURITY;
ALTER TABLE team_templates NO FORCE ROW LEVEL SECURITY;
ALTER TABLE instances NO FORCE ROW LEVEL SECURITY;
INSERT INTO projects (id, creator_id, name, created_at, updated_at)
    SELECT id, user_id, name, created_at, updated_at FROM teams;
INSERT INTO project_members (project_id, user_id, role, joined_at)
    SELECT id, user_id, 'creator', created_at FROM teams;
-- 实例已删的成员标成离开（负责人位置因此空出来）。
INSERT INTO project_agents (project_id, instance_id, user_id, is_lead, position, added_at, left_at)
    SELECT m.team_id, m.instance_id, m.user_id, m.role = 'lead' AND i.state <> 'deleted', m.position, t.created_at,
           CASE WHEN i.state = 'deleted' THEN coalesce(i.deleted_at, now()) END
      FROM team_members m
      JOIN teams t ON t.id = m.team_id
      JOIN instances i ON i.id = m.instance_id;
INSERT INTO project_templates (id, user_id, name, spec, created_at)
    SELECT id, user_id, name, spec, created_at FROM team_templates;
DO $$
BEGIN
    IF (SELECT count(*) FROM projects) <> (SELECT count(*) FROM teams)
       OR (SELECT count(*) FROM project_members) <> (SELECT count(*) FROM teams)
       OR (SELECT count(*) FROM project_agents) <> (SELECT count(*) FROM team_members)
       OR (SELECT count(*) FROM project_templates) <> (SELECT count(*) FROM team_templates)
       OR EXISTS (SELECT 1 FROM team_members m
                   WHERE NOT EXISTS (SELECT 1 FROM project_agents a WHERE a.project_id = m.team_id
                                        AND a.instance_id = m.instance_id AND a.user_id = m.user_id))
       OR EXISTS (SELECT 1 FROM project_agents a JOIN instances i ON i.id = a.instance_id
                   WHERE i.user_id <> a.user_id) THEN
        RAISE EXCEPTION 'copying teams into projects lost rows';
    END IF;
END $$;
ALTER TABLE teams FORCE ROW LEVEL SECURITY;
ALTER TABLE team_members FORCE ROW LEVEL SECURITY;
ALTER TABLE team_templates FORCE ROW LEVEL SECURITY;
ALTER TABLE instances FORCE ROW LEVEL SECURITY;

-- 有别的用户加入（只有 worker 写得出 role = 'member'）就标记共享：之后租户事务不能再改这个项目。
CREATE FUNCTION project_members_share() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    UPDATE public.projects SET shared_at = now() WHERE id = NEW.project_id AND shared_at IS NULL;
    RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION project_members_share() FROM PUBLIC;
CREATE TRIGGER project_members_share AFTER INSERT ON project_members
    FOR EACH ROW WHEN (NEW.role = 'member') EXECUTE FUNCTION project_members_share();

-- ---------- 行级安全与权限 ----------
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['projects', 'project_members', 'project_agents', 'project_invites', 'project_keys',
                             'project_templates'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    END LOOP;
END $$;

-- 项目：租户只看得到自己创建的；只能建、改名、删除自己创建且没共享过的。
CREATE POLICY tenant_read ON projects FOR SELECT TO thinktin_app USING (creator_id = app_user_id());
CREATE POLICY tenant_insert ON projects FOR INSERT TO thinktin_app
    WITH CHECK (creator_id = app_user_id() AND status = 'active' AND shared_at IS NULL);
CREATE POLICY tenant_update ON projects FOR UPDATE TO thinktin_app
    USING (creator_id = app_user_id() AND shared_at IS NULL)
    WITH CHECK (creator_id = app_user_id() AND shared_at IS NULL);
CREATE POLICY tenant_delete ON projects FOR DELETE TO thinktin_app
    USING (creator_id = app_user_id() AND shared_at IS NULL);
-- 成员：自己的那几行；租户只能写“自己是创建者”这一行。
CREATE POLICY tenant_read ON project_members FOR SELECT TO thinktin_app USING (user_id = app_user_id());
CREATE POLICY tenant_insert ON project_members FOR INSERT TO thinktin_app
    WITH CHECK (user_id = app_user_id() AND role = 'creator' AND left_at IS NULL
                AND EXISTS (SELECT 1 FROM projects p WHERE p.id = project_id
                              AND p.creator_id = app_user_id() AND p.shared_at IS NULL));
-- 项目 agent：看得到自己的 agent（在哪个项目都算）；只能在自己的单人项目里加、改自己的 agent（实例归属由复合外键保证）。
-- UPDATE 的 WITH CHECK 不查 dedicated：worker 标成专属的行，租户删实例时还要能把它标成离开；租户改不了 dedicated
-- 本身（没有列权限）。
CREATE POLICY tenant_read ON project_agents FOR SELECT TO thinktin_app USING (user_id = app_user_id());
CREATE POLICY tenant_insert ON project_agents FOR INSERT TO thinktin_app
    WITH CHECK (user_id = app_user_id() AND NOT dedicated
                AND EXISTS (SELECT 1 FROM projects p WHERE p.id = project_id
                              AND p.creator_id = app_user_id() AND p.shared_at IS NULL));
CREATE POLICY tenant_update ON project_agents FOR UPDATE TO thinktin_app
    USING (user_id = app_user_id()
           AND EXISTS (SELECT 1 FROM projects p WHERE p.id = project_id
                         AND p.creator_id = app_user_id() AND p.shared_at IS NULL))
    WITH CHECK (user_id = app_user_id()
                AND EXISTS (SELECT 1 FROM projects p WHERE p.id = project_id
                              AND p.creator_id = app_user_id() AND p.shared_at IS NULL));
CREATE POLICY tenant ON project_templates TO thinktin_app
    USING (user_id = app_user_id()) WITH CHECK (user_id = app_user_id());
-- project_invites、project_keys：没有给 thinktin_app 的策略和权限（默认拒绝）。

GRANT SELECT, DELETE ON projects TO thinktin_app;
GRANT INSERT (id, creator_id, name) ON projects TO thinktin_app;
GRANT UPDATE (name, updated_at) ON projects TO thinktin_app;
GRANT SELECT ON project_members TO thinktin_app;
GRANT INSERT (project_id, user_id, role) ON project_members TO thinktin_app;
GRANT SELECT ON project_agents TO thinktin_app;
GRANT INSERT (project_id, instance_id, user_id, is_lead, position) ON project_agents TO thinktin_app;
GRANT UPDATE (is_lead, position, left_at, added_at) ON project_agents TO thinktin_app;
GRANT SELECT, INSERT, DELETE ON project_templates TO thinktin_app;
-- 0001 的 ON ALL TABLES 只覆盖当时的表。
GRANT SELECT, INSERT, UPDATE, DELETE ON projects, project_members, project_agents, project_invites, project_keys,
    project_templates TO thinktin_worker;
-- thinktin_llmgw、thinktin_relay：这一版不需要（8.18 给 llmgw 加列权限）。
```

Notes:
- **Column grants.** They are why a tenant gets `permission denied` (42501, mapped to `Error::Forbidden`, `store/src/error.rs:51`) when it tries to set `dedicated`, `shared_at`, `status`, `goal`, budgets or `consented_at`.
  - `goal` stays in the table (projects.md §3) but is not tenant-writable until 8.14 adds `/v1/projects`.
  - `NOT dedicated` in `tenant_insert` is redundant with the INSERT column grant; it is kept as defence in depth.
  - It must **not** appear in `tenant_update`: there it would block every tenant update of a row the worker marked dedicated. Verified: 42501, which surfaces as 500 on `DELETE /v1/instances/{id}`.
- **Cascades.** A tenant `DELETE FROM projects` still cascades, because foreign-key actions run as the table owner with FORCE suppressed (verified by the draft run).
- **Name length.** The name CHECK matches the gateway's `check_len`, which counts characters (`gateway/src/routes/mod.rs:218-224`). A development database holding a team name the gateway would have rejected aborts on `projects_name_check`; recreate that database.
- **Linter.** `lint()` returns no findings for this file. The NO FORCE/FORCE toggles and the `REVOKE` on a function created in the same file are not flagged.

### 1.2 `0040_run_spaces.sql` (one transaction): typed space on runs and run grants, nothing writes it yet

```sql
-- 运行、授权的空间（docs/projects-impl.md 第 1、3 条）：private（user_id）或 project（project_id）。父子运行、子授权、运行用的
-- 授权必须在同一个空间（0045 的复合外键）；空间由触发器从 project_id 算，建了就不能改；带 project_id 的行只有 thinktin_worker
-- 写得出（白名单：租户、迁移账号、超级用户、8.15 的新角色都会报 42501）。8.13 没有任何地方写 project_id；旧的 (x, user_id)
-- 外键照留，8.17 跨主人的运行树再删。
-- 回填在一个事务里改写 runs、run_grants 的每一行（ADD COLUMN 拿的 ACCESS EXCLUSIVE 锁到提交）。按 0039 的前提表还是空的；
-- 如果发布时库里已经有大量运行，先拆成：加列和触发器 → 分批回填 → CHECK NOT VALID / VALIDATE / SET NOT NULL。
CREATE FUNCTION fill_space() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.project_id IS DISTINCT FROM OLD.project_id OR NEW.user_id IS DISTINCT FROM OLD.user_id
           OR NEW.instance_id IS DISTINCT FROM OLD.instance_id OR NEW.space_kind IS DISTINCT FROM OLD.space_kind
           OR NEW.space_id IS DISTINCT FROM OLD.space_id THEN
            RAISE EXCEPTION '% cannot move between users, instances or projects', TG_TABLE_NAME
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.project_id IS NOT NULL AND current_user <> 'thinktin_worker' THEN
        RAISE EXCEPTION 'project rows in % are written by the server only', TG_TABLE_NAME
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    NEW.space_kind := CASE WHEN NEW.project_id IS NULL THEN 'private' ELSE 'project' END;
    NEW.space_id := coalesce(NEW.project_id, NEW.user_id);
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION fill_space() FROM PUBLIC;

ALTER TABLE runs ADD COLUMN project_id uuid, ADD COLUMN space_kind text NOT NULL DEFAULT 'private',
    ADD COLUMN space_id uuid;
ALTER TABLE run_grants ADD COLUMN project_id uuid, ADD COLUMN space_kind text NOT NULL DEFAULT 'private',
    ADD COLUMN space_id uuid;
-- 回填在建触发器之前（触发器不许改 space_id）；迁移账号受 FORCE 约束，临时去掉。
ALTER TABLE runs NO FORCE ROW LEVEL SECURITY;
ALTER TABLE run_grants NO FORCE ROW LEVEL SECURITY;
UPDATE runs SET space_id = user_id WHERE space_id IS NULL;
UPDATE run_grants SET space_id = user_id WHERE space_id IS NULL;
ALTER TABLE runs FORCE ROW LEVEL SECURITY;
ALTER TABLE run_grants FORCE ROW LEVEL SECURITY;
-- relay 只改 runs (not_before, updated_at)，不会触发 UPDATE OF 这几列。
CREATE TRIGGER runs_space BEFORE INSERT OR UPDATE OF project_id, space_kind, space_id, user_id, instance_id ON runs
    FOR EACH ROW EXECUTE FUNCTION fill_space();
CREATE TRIGGER run_grants_space BEFORE INSERT OR UPDATE OF project_id, space_kind, space_id, user_id, instance_id
    ON run_grants FOR EACH ROW EXECUTE FUNCTION fill_space();
-- deploy-safe: 上一版插入时不填 space_id，由 BEFORE INSERT 触发器 runs_space 填上（NOT NULL 在触发器之后检查）
ALTER TABLE runs ALTER COLUMN space_id SET NOT NULL,
    ADD CONSTRAINT runs_space CHECK (space_kind IN ('private', 'project') AND CASE space_kind
        WHEN 'private' THEN project_id IS NULL AND space_id = user_id
        ELSE project_id IS NOT NULL AND space_id = project_id END);
-- deploy-safe: 同上，run_grants_space 触发器填 space_id
ALTER TABLE run_grants ALTER COLUMN space_id SET NOT NULL,
    ADD CONSTRAINT run_grants_space CHECK (space_kind IN ('private', 'project') AND CASE space_kind
        WHEN 'private' THEN project_id IS NULL AND space_id = user_id
        ELSE project_id IS NOT NULL AND space_id = project_id END);
```

Files 0041–0044 each have `-- no-transaction` as their first line and contain exactly one statement (`docs/release.md:49-50`). They are the first such files in the repo; sqlx 0.9 honours the marker (`sqlx-core-0.9.0/src/migrate/source.rs:234`, `sqlx-postgres-0.9.0/src/migrate.rs:231-232`).
- `0041_runs_space_index.sql`: `CREATE UNIQUE INDEX CONCURRENTLY runs_id_space ON runs (id, space_kind, space_id);`
- `0042_run_grants_space_index.sql`: `CREATE UNIQUE INDEX CONCURRENTLY run_grants_id_space ON run_grants (id, space_kind, space_id);`
- `0043_runs_project_index.sql`: `CREATE INDEX CONCURRENTLY runs_project ON runs (project_id, instance_id, user_id) WHERE project_id IS NOT NULL;` The `runs_project_agent` check runs when a `project_agents` row is updated or deleted, and needs this index.
- `0044_run_grants_project_index.sql`: `CREATE INDEX CONCURRENTLY run_grants_project ON run_grants (project_id, instance_id, user_id) WHERE project_id IS NOT NULL;` The same applies to `run_grants_project_agent`.
  - Rows get deleted through `delete_solo_project` (cascade projects → members → agents), through erase, and through the instances cascade.
  - Without this index, every deleted agent row scans run_grants: the only other index is `run_grants_instance (instance_id) WHERE revoked_at IS NULL` (`0001_init.sql:174`).

**Operational rule for no-transaction files.** sqlx takes a blocking session advisory lock (`sqlx-postgres-0.9.0/src/migrate.rs:198`). A second migrator waiting on that lock holds a snapshot, and CREATE INDEX CONCURRENTLY waits for older snapshots. Result: `deadlock detected`, an index left `indisvalid = f`, and no `_sqlx_migrations` row, because the row is written only after the SQL succeeds (`execute_migration`, migrate.rs:315-338). A rerun then fails with "already exists". This was reproduced on PG 16.15.

Production already runs one migrator: the Job has `backoffLimit: 0` (`deploy/k8s/migrate/job.yaml:15`), and `migrate_on_start = false` in every overlay (`deploy/k8s/overlays/*/server.toml`). But two comments wrongly promise that sqlx serialises concurrent migrators: `crates/store/src/schema.rs:96` and `deploy/k8s/migrate/job.yaml:7`. C7 fixes both and adds this to `docs/release.md` §3 after line 50:

> 带 `-- no-transaction` 的迁移只能由一个迁移进程执行（迁移 Job；`migrate_on_start` 不能在多个副本上同时开）：别的进程等 sqlx 咨询锁时持有快照，CREATE INDEX CONCURRENTLY 等它会死锁，留下无效索引。失败后先 `DROP INDEX CONCURRENTLY IF EXISTS <索引名>;` 再重跑。

`0045_run_space_keys.sql` (one transaction, short locks only):

```sql
-- 同一空间的外键，先只加 NOT VALID（ADD FOREIGN KEY 在两张表上拿 SHARE ROW EXCLUSIVE，锁到提交）；检查已有的行在 0046，
-- 单独一个事务。外键直接引用 0041、0042 建的唯一索引，不需要 ADD CONSTRAINT … UNIQUE USING INDEX。
-- 项目运行、项目授权只能落在这个项目里这个主人的 agent 上（NO ACTION：有项目运行的 agent 行删不掉，删项目要先清运行，8.15）。
ALTER TABLE runs ADD CONSTRAINT runs_project_agent FOREIGN KEY (project_id, instance_id, user_id)
    REFERENCES project_agents (project_id, instance_id, user_id) NOT VALID;
ALTER TABLE run_grants ADD CONSTRAINT run_grants_project_agent FOREIGN KEY (project_id, instance_id, user_id)
    REFERENCES project_agents (project_id, instance_id, user_id) NOT VALID;
-- 同一空间：子授权跟父授权、子运行跟父运行、运行跟它用的授权。删除动作和旧的 (x, user_id) 外键一致；8.17 删旧外键时再定
-- 跨主人子运行的处理（impl 第 7 条：解除父关联）。
ALTER TABLE run_grants ADD CONSTRAINT run_grants_parent_space FOREIGN KEY (parent_id, space_kind, space_id)
    REFERENCES run_grants (id, space_kind, space_id) ON DELETE CASCADE NOT VALID;
ALTER TABLE runs ADD CONSTRAINT runs_parent_space FOREIGN KEY (parent_run_id, space_kind, space_id)
        REFERENCES runs (id, space_kind, space_id) ON DELETE CASCADE NOT VALID,
    ADD CONSTRAINT runs_grant_space FOREIGN KEY (run_grant_id, space_kind, space_id)
        REFERENCES run_grants (id, space_kind, space_id) ON DELETE SET NULL (run_grant_id) NOT VALID;
```

`0046_validate_run_space_keys.sql` (one transaction; VALIDATE takes only SHARE UPDATE EXCLUSIVE on the referencing table):

```sql
ALTER TABLE runs VALIDATE CONSTRAINT runs_project_agent;
ALTER TABLE run_grants VALIDATE CONSTRAINT run_grants_project_agent;
ALTER TABLE run_grants VALIDATE CONSTRAINT run_grants_parent_space;
ALTER TABLE runs VALIDATE CONSTRAINT runs_parent_space;
ALTER TABLE runs VALIDATE CONSTRAINT runs_grant_space;
```

Verified in scratch: all five constraints end up `convalidated = t`, and `runs_parent_space` and `runs_grant_space` use `runs_id_space` and `run_grants_id_space` as their `conindid`.

Behaviour checks:
- An old-style tenant insert with no space columns gets `space_kind = 'private'` and `space_id = user_id`.
- A tenant or superuser insert with `project_id` fails with "server only" (42501, mapped to Forbidden). A worker insert succeeds and gets `space_kind = 'project'`.
- An UPDATE that changes `space_id` fails with 23514 (mapped to Invalid). `UPDATE … SET state` is unaffected.
- A private child of a project parent is rejected by `runs_parent_space` (23503, mapped to Invalid).
- Deleting a project_agent that a project run references is rejected.

Events, approvals, inbox_items, artifacts, plans and usage_records are **not** touched in 8.13 (see §8; the events, approvals and inbox tagging must land in 8.15).

## 2. Store API (`crates/store`)

**`proto/src/domain.rs`**
- Add `ProjectId` to `id_type!` (lines 52-76).
- Add `impl From<TeamId> for ProjectId` and `impl From<ProjectId> for TeamId`.
- Add `str_enum!(ProjectStatus { Active="active", Archived="archived", Deleted="deleted" })`.
- `ProjectRole` waits for 8.14, which is the first code that writes `role='member'`.
- No wire types change.

**`lib.rs`**
- Add `mod projects;` next to `mod teams;` (line 33) and `pub use projects::{ProjectRecord, SoloAgent};`.
- No new `Db`/`Tx` role in 8.13; `ProjectTx` and `Db::project` arrive in 8.15.

**New file `crates/store/src/projects.rs`.** All methods are on `impl Tx<Tenant>` and rely on RLS:

```rust
pub struct SoloAgent { pub instance_id: InstanceId, pub is_lead: bool, pub position: u32 }
pub struct ProjectRecord { pub id: ProjectId, pub name: String, pub status: ProjectStatus, pub shared: bool,
    pub created_at: DateTime<Utc>, pub updated_at: DateTime<Utc> }

/// 单人项目：creator = me，agent 都是我没删的实例。和领养在同一个租户事务里。
pub async fn create_solo_project(&mut self, name: &str, agents: &[SoloAgent]) -> Result<ProjectId>;
pub async fn own_project(&mut self, id: ProjectId) -> Result<ProjectRecord>;        // status <> 'deleted'
pub async fn own_projects(&mut self) -> Result<Vec<ProjectRecord>>;                // status = 'active' ORDER BY created_at, id
pub async fn my_project_agents(&mut self, id: ProjectId) -> Result<Vec<SoloAgent>>;// mine, left_at IS NULL, instance not deleted
pub async fn update_solo_project(&mut self, id: ProjectId, name: Option<&str>) -> Result<()>;
pub async fn replace_my_project_agents(&mut self, id: ProjectId, agents: &[SoloAgent]) -> Result<()>;
pub async fn delete_solo_project(&mut self, id: ProjectId) -> Result<()>;
async fn writable_solo(&mut self, id: ProjectId) -> Result<()>;   // not visible/active → NotFound; shared → Conflict("project is shared")
async fn check_agents(&mut self, agents: &[SoloAgent]) -> Result<()>;
```

What each function does:
- **`check_agents`**:
  - more than one lead returns `Invalid("a team has at most one lead")`. That is the same message as `teams.rs:26` and the Swift mock (`MockClient.swift:1978,2002`), and it keeps 422;
  - a duplicate `instance_id` returns `Conflict("project_agents_pkey")`, which keeps today's 409. The upsert below would otherwise silently merge duplicates, so the check is explicit;
  - each instance goes through `self.instance(id)` (`instances.rs:291-301`), so another user's or a deleted instance returns NotFound and stays 404.
- **`create_solo_project`** keeps the old order of `create_team` (`teams.rs:13-27`: project row first, then the agent checks). That way an adoption that fails at the lead check also proves the project rows roll back (test #8b).
  1. `INSERT INTO projects (id, creator_id, name) VALUES ($1, app_user_id(), $2)`
  2. `INSERT INTO project_members (project_id, user_id, role) VALUES ($1, app_user_id(), 'creator')`
  3. `check_agents`
  4. for each agent: `INSERT INTO project_agents (project_id, instance_id, user_id, is_lead, position) VALUES ($1,$2,app_user_id(),$3,$4)`
- **`replace_my_project_agents`** replaces the delete-and-reinsert at `teams.rs:104-110`, so rows and per-agent settings are kept. It calls `check_agents` first, then runs three statements in this order, because unique indexes are checked per row:
  1. `UPDATE project_agents SET is_lead = false WHERE project_id = $1 AND user_id = app_user_id() AND is_lead`
  2. `UPDATE project_agents SET left_at = now() WHERE project_id = $1 AND user_id = app_user_id() AND left_at IS NULL AND NOT (instance_id = ANY($2))`
  3. for each agent: `INSERT … ON CONFLICT (project_id, instance_id) DO UPDATE SET is_lead = EXCLUDED.is_lead, position = EXCLUDED.position, left_at = NULL, added_at = CASE WHEN project_agents.left_at IS NULL THEN project_agents.added_at ELSE now() END`

  The INSERT WITH CHECK is evaluated on the proposed row, where `dedicated` defaults to false. The UPDATE WITH CHECK no longer tests `dedicated`. So the upsert also works on rows the worker marked dedicated.
- **`update_solo_project`**: `writable_solo`, then `UPDATE projects SET name = coalesce($2,name), updated_at = now() WHERE id = $1 AND status = 'active'`. Zero rows returns NotFound.
- **`delete_solo_project`**: `writable_solo`, then `DELETE FROM projects WHERE id = $1`.
  - Members, agents, invites and keys cascade; instances stay.
  - Zero rows returns NotFound.
  - 8.15 replaces this with the soft-delete flow once project content exists.

**`crates/store/src/teams.rs`** keeps every signature (`teams.rs:11-190`) as a compatibility layer:

| Function | New implementation |
|---|---|
| `create_team(name, members)` | `create_solo_project(name, &solo(members))`, then `team(id.into())` |
| `team(id)` | `own_project` (name, created_at) plus `my_project_agents` (`SELECT a.instance_id, a.is_lead, a.position FROM project_agents a JOIN instances i ON i.id = a.instance_id AND i.state <> 'deleted' WHERE a.project_id = $1 AND a.left_at IS NULL ORDER BY a.position, a.instance_id`; RLS limits it to my agents). Role is `Lead` if `is_lead`, else `Member`. JSON stays `{id,name,members,created_at}`. |
| `teams()` | `own_projects()`, then `team()` for each (same N+1 pattern as today) |
| `update_team(id, name, members)` | `update_solo_project(id, name)`, then `replace_my_project_agents` if members were given, then `team(id)` |
| `delete_team(id)` | `delete_solo_project` |
| `create_team_template`, `team_templates`, `team_template`, `delete_team_template` | Same SQL with the table renamed to `project_templates`; spec format unchanged (`from_json(…, "team template")`) |

**`crates/store/src/instances.rs`**
- **`delegation_targets`** (lines 564-577, `Tx<Tenant>`). Exact old team semantics: only projects the lead's owner created, and only my own agents.
  ```sql
  SELECT <cols> FROM instances WHERE state <> 'deleted' AND id <> $1 AND user_id = app_user_id() AND id IN (
    SELECT a.instance_id FROM project_agents a
     WHERE a.left_at IS NULL AND a.user_id = app_user_id() AND a.project_id IN (
       SELECT l.project_id FROM project_agents l JOIN projects p ON p.id = l.project_id
        WHERE l.instance_id = $1 AND l.is_lead AND l.left_at IS NULL
          AND p.creator_id = app_user_id() AND p.status = 'active'))
  ORDER BY name, id
  ```
- **`is_team_lead`** (lines 582-590, `Tx<Worker>`):
  ```sql
  SELECT EXISTS (SELECT 1 FROM project_agents a JOIN projects p ON p.id = a.project_id
     WHERE a.instance_id = $1 AND a.is_lead AND a.left_at IS NULL AND p.creator_id = a.user_id AND p.status = 'active')
  ```
  - The `creator_id = owner` condition keeps a lead in someone else's shared project (8.14+) from getting delegate tools in its private runs. The tenant-side `delegation_targets` already excludes those projects through RLS.
  - It supports one instance leading several projects and being a member elsewhere, as `orchestrator/tests/executor.rs:2117-2133` requires, because the key is per (project, instance).
- **`delete_instance`** (lines 384-411): after the soft delete, add `UPDATE project_agents SET is_lead = false, left_at = now() WHERE instance_id = $1 AND left_at IS NULL`.
  - The tenant policy limits this to my unshared projects, which in 8.13 is all of them.
  - It frees the lead slot and preserves the old behaviour of PATCH after delete.
  - It also works on dedicated rows (corrected CHECK and policy; see §1.1 notes).

**`crates/store/src/users.rs` `erase_account`** (`Tx<Worker>`, `users.rs:183`). Keep both old lines, `DELETE FROM teams/team_templates WHERE user_id` (`users.rs:211-212`), because the frozen copies hold user content. Insert these five statements **directly after line 212**. That places them after `DELETE FROM runs WHERE user_id = $1` (line 200), so the user's own project runs are gone before agent rows are deleted (`runs_project_agent` is NO ACTION). It also places them before the phone number is overwritten (line 226), which the invite delete reads:
```
"UPDATE project_agents SET is_lead = false, dedicated = false, left_at = coalesce(left_at, now()) WHERE user_id = $1",
"DELETE FROM projects WHERE creator_id = $1",                       -- cascades members/agents/invites/keys (8.15: soft delete)
"UPDATE project_members SET left_at = now(), left_reason = 'erased' WHERE user_id = $1 AND left_at IS NULL",
"DELETE FROM project_invites WHERE inviter_id = $1 OR invitee_id = $1 \
   OR invitee_phone = (SELECT phone FROM users WHERE id = $1)",    -- pending phone invites keep no erased number
"DELETE FROM project_templates WHERE user_id = $1",
```
Update the doc comment at lines 178-182 to match. The sequence was verified in scratch against a shared project, a dedicated agent and two phone invites: only the invite to the erased user's number was removed.

**`runs.rs` / `grants.rs`** (commit C7, together with 0040–0046):
- **Claim guard.** This build executes only private runs. Add `AND r.project_id IS NULL` or `AND project_id IS NULL` to:
  - `claim_next_run` (line 872, the first SELECT at 879-894; outer `r`);
  - `take_over_expired` (line 987, subselect at 996-998);
  - `claim_expired_waits` (line 1284, subselect at 1293-1296);
  - `due_pipelines` (line 1423, WHERE at 1427-1430).

  Add a comment next to `known_sources()` (line 203) explaining why. This is impl "8.14–8.16": every worker excludes project runs it cannot isolate.
  - These four are the only claim and takeover paths. `cancel_stale_asks` (line 1253) only cancels, and `acquire_lease` (line 964) is used only in tests.
- **Private grant lookups exclude project grants** (impl item 3). Add `AND project_id IS NULL` to:
  - `active_grant_for_instance` (`grants.rs:303-315`);
  - `run_grants(instance)` (`grants.rs:136-147`), which the gateway's `ensure_instance_grant` uses (`gateway/src/routes/runs.rs:67`).
- `RunRecord`, `columns!()`, `NewRun` and `insert_run` (line 267) are unchanged in 8.13. Copying a parent's `project_id` to its children moves to 8.17; the foreign keys already reject mismatches.

**`schema.rs:16`**: make `fn migrator()` `pub(crate)` for the test helper. **`schema.rs:96`**: fix the doc comment (§1.2 operational rule).

**`testing.rs` (commit C1)**:
- Keep `TestDb { db, admin, name }` and add `owner: PgConnectOptions`.
- `new()` becomes `migrated(None)`. Add:
  - `pub async fn up_to(version: i64)`, which calls `migrator().run_to(version, &owner_pool)` (`sqlx-core-0.9.0/src/migrate/migrator.rs:185`);
  - `pub async fn migrate_rest(&self)`, which runs the remaining migrations as the owner.
- On the admin connection (`DATABASE_URL` is a superuser, `thinktin_dev`, in CI and locally):
  1. `SELECT pg_advisory_lock(hashtextextended('thinktin-test-roles', 0))`. Advisory locks are per database, and every admin connection uses the same `DATABASE_URL` database.
  2. Run `sqlx::raw_sql` with one DO block that creates, `IF NOT EXISTS`, the roles `thinktin_app`, `thinktin_worker`, `thinktin_llmgw` and `thinktin_relay` (same attributes as 0001/0014), plus `thinktin_test_owner LOGIN NOSUPERUSER NOCREATEROLE NOCREATEDB NOBYPASSRLS PASSWORD 'thinktin_test_owner'`.
  3. Unlock.
  4. `CREATE DATABASE {name} OWNER thinktin_test_owner`.
- Migrate over a one-connection pool using `admin.clone().database(&name).username(OWNER).password(OWNER)`. No other connection touches the new database while migrating, so the no-transaction files cannot deadlock in tests.
- `TestDb.db` stays the 16-connection **superuser** pool, so the existing raw `db.pool()` call sites keep working (134 in store/src/tests.rs and the `crates/*/tests` files).
- On PostgreSQL 15+ the database owner has CREATE on `public`. So the `ensure_event_partitions`, `drop_event_partitions_before` and workspace-archive SECURITY DEFINER functions (`0001_init.sql:287,303`, `0007:41`, `0023:33`), now owner-owned, work as they will in production. No migration runs `CREATE EXTENSION`.

## 3. Gateway

- Code in `crates/gateway/src/routes/teams.rs` and `routes/mod.rs:159-169` is unchanged. Only the module doc changes, to say the routes are a compatibility view over single-user projects.
- Paths, status codes and JSON stay the same:
  - another user's id gives 404, through tenant RLS on `projects`;
  - a shared project (impossible in 8.13) gives 409 through `Error::Conflict`;
  - the 1-12 member validation (`teams.rs:16-25`) is kept.
- **Adoption stays atomic with no code change.** `adopt_template` (`teams.rs:183-226`) still runs, in one `Tx<Tenant>`:
  1. `lock_instance_count`;
  2. for each member, `control::adopt_in` (instance, `instance.state` event and `instance.adopt` audit row via `control::insert`, `control/src/lib.rs:267-293`) and then `create_run_grant`;
  3. `create_team`, which now writes the project rows.

  Any error drops the transaction and rolls all of it back together. Adopted teams keep private grants with the full `default_scope` and runs with `project_id = NULL` (design A).
  - `create_template` (`teams.rs:118-160`) checks neither harness nor lead count. Adoption is where both fail: the harness in `control::resolve` (`control/src/lib.rs:250-254`), the lead count in `create_team`/`check_agents`. Test #8 uses both.
- **No new `/v1/projects*` or `/v1/project-templates*` routes in 8.13.**
  - The only safe candidates are `GET /v1/projects` and `GET /v1/projects/{id}`, as tenant reads of `own_project(s)`.
  - Their response must later include other members and agents, and switch to `ProjectTx` semantics (404 for non-members) in 8.15. Shipping a creator-only shape now would freeze a contract that no app uses before 12.25/13.18.
  - `/v1/project-templates/{id}/adopt` should return a Project, which does not exist yet.
  - All of these move to 8.14.
- **Forbidden still maps to 500.** `gateway/src/error.rs:67-80` maps `Forbidden` to 500.
  - No `/v1/teams` path can reach 42501 in 8.13: every write follows a read the creator can see, or creates a fresh project.
  - With the corrected `tenant_update` policy, `DELETE /v1/instances/{id}` (`gateway/src/routes/instances.rs:383`) cannot reach 42501 either.
  - Mapping 42501 on member paths to 404 is 8.15.

## 4. client-core / FFI

- Keep `Team`, `TeamMember`, `TeamTemplate` and `TemplateMember` (`client-core/src/ffi.rs:818-918`) and the 10 methods (`ffi.rs:2592-2708`, `api.rs:1722-1818`) unchanged.
- Add **no** Project records in 8.13. The Android binding `apps/android/core/src/main/kotlin/cn/thinktin/core/client_core.kt` therefore needs no regeneration, and nothing in `CoreThinktinService.kt` or Swift changes.
- When 8.14 adds `Project*` records and methods:
  - additions only, with new fields marked `#[uniffi(default = None)]`, following the existing convention (`ffi.rs:63`);
  - run `tools/client-core/gen-bindings.sh`, then commit the regenerated `client_core.kt` in its own commit (precedent: `4f4950d`, `c2b8892`);
  - iOS regenerates at build time.

## 5. Orchestrator

- **No source change in 8.13.**
  - `executor.rs:770-776` keeps calling `is_team_lead`, and `delegate.rs:43-48` keeps calling `delegation_targets`. Both are reimplemented in store (§2) with the same private semantics.
  - The claim guard lives in store `runs.rs`.
- These stay as they are until 8.16/8.17: peers, ask, board, pipelines, `lock_run_waits` (per user, `runs.rs:428-435`), `create_child_grant` (`grants.rs:246`), `create_run(ctx.user)` in `delegate.rs`, and the `ToolContext` shape (`shim.rs:68-75`).
- Expected to pass unchanged: the delegation tests in `orchestrator/tests/executor.rs` (2005-2252; the helper `team()` at 2215 calls `Tx<Tenant>::create_team`).

## 6. Tests

All tests use the existing style:
- `TestDb::new()` returns `None` and the test is skipped (`THINKTIN_REQUIRE_DB=1` fails instead);
- raw SQL goes through `x.conn()` inside the store crate, or `a.t.db.pool()` (superuser) in gateway tests;
- errors are checked with `matches!(err, Error::Forbidden(_))`.

**Store (`crates/store/src/tests.rs`)**
1. **New `migrations_run_as_a_plain_owner`.**
   - In C1: the owner of `runs` and `_sqlx_migrations` has `rolsuper`, `rolbypassrls` and `rolcreaterole` all false, and `relforcerowsecurity` is true on every table `thinktin_app` can touch.
   - C3 extends it: the owner of `projects` too, and FORCE on the six new tables.
2. **New `teams_move_into_single_user_projects`** (backfill on a non-empty database).
   - `TestDb::up_to(38)`.
   - **Seed with raw SQL on `t.db.pool()`.** From C5 on, `Tx<Tenant>::create_team`/`create_team_template` write `projects`/`project_templates`, which do not exist at version 38 (42P01). Seed:
     - users A and B;
     - A's instances L, W and D by raw `INSERT INTO instances`, with D soft-deleted by `UPDATE instances SET state='deleted', deleted_at=now()`;
     - raw `teams`, `team_members` and `team_templates` rows: T1 (L lead, W member), T2 (D lead, L member), B's T3, and one template for A.
   - Run `migrate_rest()` as the owner.
   - Assert:
     - project ids equal team ids, `creator_id` equals `user_id`, and each project has exactly one creator member row;
     - in T2, D has `left_at` set and `is_lead = false`, and T2 has no lead;
     - template ids and spec are unchanged;
     - `db.tenant(A).teams()` returns T1 and T2 with the same visible members and roles the old `team()` showed (deleted instances hidden);
     - `tenant(B).teams()` returns T3 only, and `tenant(A).team(T3)` is NotFound;
     - FORCE is restored on `teams`, `team_members`, `team_templates`, `instances` and all six new tables.

   This test catches a missing `NO FORCE`: without it the in-migration count check compares 0 with 0 and passes. It passes at C3 (old code reads `teams`) and at C5 (new code reads projects).
3. **New `solo_projects_stay_with_their_creator`** (isolation matrix).
   - Alice runs `create_team`. Bob gets NotFound from `team`, `update_team` and `delete_team`, and his `teams()` is empty.
   - Raw SQL as Bob:
     - inserting a creator row into `project_members` on Alice's project gives Forbidden (RLS);
     - inserting Bob's own instance into `project_agents` of Alice's project gives Forbidden.
   - Alice inserting Bob's instance gives `Invalid("reference project_agents_instance_id_user_id_fkey")`.
   - Alice updating `dedicated`, inserting into `projects` with `shared_at`, or inserting with `goal` gives Forbidden (column privilege).
   - The worker sets `shared_at`. Alice's `update_team` and `delete_team` then give `Conflict`, and `team()` still reads.
   - The worker inserts a `role='member'` row for Bob (with `consented_at`), and `shared_at` is set by the trigger.
   - `thinktin_app` has no privilege on `project_invites` or `project_keys`: a SELECT gives Forbidden.
4. **New `team_members_are_replaced_in_place`**.
   - Swapping lead and member in one `update_team` works.
   - Removing W and then re-adding it keeps one row (count 2, not 3) with a fresh `added_at`.
   - A duplicate instance in the list gives `Conflict`.
   - `delete_instance(lead)` hides it from `team()` and frees the lead slot, so the next `update_team` with a new lead succeeds.
   - **Dedicated regression (critic #4 and the policy fix):** the worker sets `dedicated = true` on W in Alice's unshared project. Then:
     - `update_team` that keeps W succeeds;
     - `delete_instance(W)` succeeds (no 23514, no 42501), sets `left_at` and leaves `dedicated` unchanged;
     - re-running the dedicated check shows the `project_agent_dedicated` index no longer covers W.
   - `delegation_targets` and the worker's `is_team_lead` follow every step.
   - Bob creates a project (raw worker SQL) in which Alice's L is lead: `is_team_lead(L)` is false and no targets are added.
5. **Update `every_tenant_table_the_app_can_touch_has_rls`** (lines 764-817).
   - Scan all `relkind IN ('r','p') AND NOT relispartition` tables, not only those with a `user_id` column (line 773). Today this adds only `users`, which has the `self` policy; `_sqlx_migrations` is not granted to `thinktin_app` (`0016`).
   - Every table the app can touch must have `relrowsecurity` and `relforcerowsecurity` true, at least one policy whose `roles` contains `thinktin_app`, and no app policy whose `qual` or `with_check` is `'true'`. None exists today.
   - Add `projects`, `project_agents` and `project_templates` to the `must` list (line 812, keeping `teams`).
6. **Update `erasing_an_account_deletes_its_content`** (seeding at lines 952-976 unchanged; table list at 1070-1093).
   - The seeded `create_team` and `create_team_template` now produce project rows.
   - Before the erase, insert one raw `teams` row and one raw `team_templates` row per user, to stand in for the frozen copies.
   - Also: with raw worker SQL, add Alice as a member (with `consented_at`) of Bob's project with one of her agents, and add a pending phone invite from Bob to Alice's phone plus one to another number.
   - Table list: drop `team_members`; add `project_templates`, `project_members` and `project_agents`.
   - Assert:
     - `SELECT count(*) FROM projects WHERE creator_id = $1` is 0 for Alice and 1 for Bob;
     - Alice has no live member or agent rows;
     - only the invite to her number is gone.
7. **New `project_runs_are_server_only_and_never_claimed`** (commit C7).
   - Inserting a run with `project_id` gives Forbidden both as tenant and as superuser on `t.db.pool()`, which pins the allowlist. A tenant `UPDATE runs SET space_id` gives Invalid.
   - For a project run inserted by the worker (via `w.conn()`, on an existing `project_agents` row), `claim_next_run` returns None.
   - With an expired lease, `take_over_expired` returns 0.
   - A project run in `waiting_quota` with an expired `wait_deadline` is skipped by `claim_expired_waits`.
   - A project `kind='pipeline'` root is skipped by `due_pipelines`.
   - A private child under a project parent gives `Invalid("reference runs_parent_space")`. A private run using a project grant gives `Invalid("reference runs_grant_space")`.
   - `active_grant_for_instance` and `run_grants(instance)` ignore the project grant.
   - **Index check:** with `plan_cache_mode = force_generic_plan`, EXPLAIN of the two foreign-key lookups `SELECT 1 FROM ONLY runs x WHERE project_id = $1 AND instance_id = $2 AND user_id = $3 FOR KEY SHARE OF x` (and the same on `run_grants`) uses `runs_project` and `run_grants_project`.
   - All five space constraints are `convalidated`, and `indisvalid` is true for the 0041–0044 indexes.

**Gateway (`crates/gateway/tests/api.rs`)**

8. **New `team_adoption_rolls_back_when_a_member_fails`** (commit C4, before the switch). It has two cases, and each starts from a fresh user.
   - **(a) Harness case.** `POST /v1/team-templates` with `[{claude, 主编, lead}, {claude, harness: "no-such-harness", 写手}]` returns 201. Adopt returns 422 from `control::resolve` during member 2's `adopt_in`, after member 1's instance, event, audit row and grant were written.
   - **(b) Two-lead case.** The template is `[{claude, 主编, lead}, {claude, 写手, lead}]` (201, since `create_template` does not count leads). Adopt returns 422 "a team has at most one lead" from `create_team`, which fails inside the team/project write after two instances, two grants, two `instance.adopt` audit rows and two `instance.state` events, and (from C5) after the `projects` and creator rows were inserted.
   - Both cases assert raw counts of 0 on `a.t.db.pool()` for that user's `instances`, `run_grants`, `events` and `audit_log WHERE action = 'instance.adopt'`, and for `teams` (C4). From C5 they also assert 0 for `projects`, `project_members` and `project_agents`. `GET /v1/teams` returns `[]`.
9. **New `old_team_api_is_backed_by_projects`** (commit C6).
   - `POST /v1/teams`: response keys are exactly `{id,name,members,created_at}`, and member keys `{instance_id,role,position}`.
   - Raw checks: a `projects` row with that id, one creator row, two live `project_agents`, and `teams` count 0.
   - A PATCH that removes a member and then re-adds it leaves one row.
   - After `DELETE /v1/instances/{lead}`, GET shows 1 member and a PATCH naming a new lead returns 200.
   - Raw `UPDATE projects SET shared_at = now()`: PATCH and DELETE return 409, GET returns 200.
   - Reset `shared_at`; DELETE returns 204, the project rows are gone and the instances remain.
10. **Must pass unchanged:**
    - `teams_pipelines_and_artifacts` (1266);
    - `other_users_objects_are_invisible` (1682; team/template 404s at 1890-1902, empty lists at 1941-1942);
    - `instance_limit_over_http` (2581, "no half team" at 2625);
    - `team_adoption_is_all_or_nothing` (2657).

**client-core**: `ffi_teams_and_templates` (`tests/client.rs:1641`) passes unchanged, including the lead swap and the `"boss"` value giving `InvalidArgument`. This is the old-FFI compatibility gate.

**Orchestrator**: the delegation tests listed in §5 pass unchanged.

## 7. Commit sequence

Each commit compiles, passes `cargo fmt --all`, `cargo clippy --workspace --all-targets -- -D warnings` and `cargo test --workspace` (with `THINKTIN_REQUIRE_DB=1`), and is pushed immediately.

| # | Commit | Files | Size |
|---|---|---|---|
| C0 | progress: claim 8.13 | `docs/progress/claude-determined-lovelace-vn0j5h.md` ("进行中: 8.13, who, when") | 10 lines |
| C1 | store testing: migrate as a production-like owner; 0001/0014 check roles before creating them | `migrations/0001_init.sql:8,16-18`, `0014_device_relay.sql:15`, `store/src/testing.rs`, `store/src/schema.rs:16` (`pub(crate)`), new test #1 (checking `runs` and `_sqlx_migrations` only), `docs/deploy-checklist.md:59-60`, `docs/release.md:74` | ~150 |
| C2 | proto: ProjectId, ProjectStatus | `proto/src/domain.rs` | ~30 |
| C3 | migration 0039: projects, members, agents, invites, keys, templates; copy teams | `migrations/0039_projects.sql`; test #2 (needs `TestDb::up_to` from C1); test #1 extended to `projects` and the six new tables; `docs/release.md` §3 new bullet: "回填受 FORCE 约束的表要在同一事务里 NO FORCE / FORCE（迁移账号看不到行，UPDATE/INSERT … SELECT 会悄悄处理 0 行）". Old code still writes `teams`, which is fine at this step. | ~230 SQL + ~150 test |
| C4 | gateway test: adoption rolls back midway | test #8, both cases, with `teams` counts and without project counts. It passes on the old implementation: the gate before the read switch. | ~90 |
| C5 | store: project functions; teams, delegation, instance delete and erase switched to projects | new `store/src/projects.rs`, `teams.rs`, `instances.rs` (384-411, 564-590), `users.rs` (after 212; doc comment 178-182), `lib.rs`; tests #3, #4, #5, #6; project counts added to #8 | ~300 code + ~320 tests |
| C6 | gateway test: the old team API reads and writes project rows | test #9 | ~150 |
| C7 | runs and grants: typed space, claim guard, private grant lookups exclude project grants | `0040_run_spaces.sql`, `0041`–`0044` (no-transaction), `0045_run_space_keys.sql`, `0046_validate_run_space_keys.sql`, `runs.rs` (872, 987, 1284, 1423; comment at 203), `grants.rs` (136-147, 303-315), test #7; docs: `release.md` §3 no-transaction single-migrator bullet, `schema.rs:96` and `deploy/k8s/migrate/job.yaml:7` comments | ~150 SQL + ~20 code + ~170 tests |
| C8 | docs | progress file (done/next/pitfalls); `docs/projects.md` status line; projects-impl "8.13" notes (numbering 0039–0046, `space_*` naming, `shared_at`, frozen old tables and the D4 precondition) | ~80 |

C7 depends on C3 only: 0045 references `project_agents`, the numbering continues from 0039, and test #7 needs `project_agents` rows. It can be a separate PR stacked on C3. If it ships after a first deployment, apply the 0040 header's split (§1.2).

## 8. Sequencing note for 8.14–8.19: what 8.13 leaves in place, and what each later package must do

**Left in place by 8.13**
- `projects`, `project_members`, `project_agents`, `project_invites`, `project_keys` and `project_templates`, all with FORCE RLS.
  - Tenant policies cover creator-only writes to unshared projects. The `project_agents` UPDATE policy does not test `dedicated`; the column grants do.
  - The worker has full DML. `thinktin_member`, `thinktin_definer` and `thinktin_llmgw` have no grants.
- `projects.shared_at` and its trigger (D3).
- `TeamId == ProjectId`.
- `TestDb` migrates as a non-superuser owner, and roles are created under an advisory lock.
- `runs` and `run_grants` have:
  - `project_id`, `space_kind` and `space_id`;
  - the space foreign keys, validated, and the indexes `runs_project` and `run_grants_project`;
  - `fill_space()`, with a worker-only allowlist for project rows and an immutable space;
  - the claim guard.
- Private grant lookups exclude project grants.
- The old team tables are frozen; the D4 precondition applies.

| WP | Must do on top of 8.13 |
|---|---|
| **8.14** invites and join | **Invites, accept and decline:** worker-only flows on `project_invites`. Settle with `UPDATE … WHERE status='pending' AND expires_at > now()` in one transaction, store the token hash only, and make a repeated accept return the existing result.<br>**Joining:** inserts `role='member'` with `consented_at`, so `shared_at` is set automatically.<br>**Caps:** take a per-project `pg_advisory_xact_lock(hashtextextended('project/'||id,0))` around the 10-user / 30-agent caps.<br>**Abuse:** a blocks table and rate limits.<br>**Withdraw, leave, remove:** go through the worker (cancel project work, bump `instances.token_epoch`). `delete_instance` must also retire the instance from *shared* projects via the worker, because the tenant policy only covers unshared ones.<br>**API and FFI:** add `ProjectRole`; `/v1/projects*` and `/v1/project-templates*` (same table) plus Project FFI types, with Android binding regeneration; tenant grants on `projects.goal`.<br>**Decisions:** whether old `/v1/teams` writes on shared projects stay 409; what happens to pending phone invites on erase (8.13 deletes those addressed to the erased number; confirm with 16.6). |
| **8.15** cross-user boundary | **Roles:** create `thinktin_member` and `thinktin_definer` with the C1 idiom (`IF NOT EXISTS` before `CREATE ROLE`). The deploy checklist pre-creates them and runs `GRANT thinktin_definer TO thinktin_owner WITH INHERIT FALSE, SET TRUE`. `TestDb` also creates them and grants SET to `thinktin_test_owner`.<br>**Definer functions:** membership functions with `search_path = pg_catalog, public, pg_temp`.<br>**Member reads:** member read policies with column grants; grants on the `events` parent only. `ProjectTx` as its own type. Map 42501 to 404 on project paths.<br>**Narrow tenant policies:** on `runs`/`run_grants` rows with `project_id IS NOT NULL`. If any new role must write project runs, extend the `fill_space()` allowlist explicitly.<br>**Events, approvals, inbox (critic #7):** add `events.project_id`, `approvals.project_id` and `inbox_items.project_id`. A BEFORE INSERT trigger fills them from `runs.project_id`, so older writers are covered. Add the space-consistency key next to the kept `(run_id,user_id)` keys (`0001_init.sql:280-281` for events). Narrow the tenant policies on these tables (`0001_init.sql:435`) by live membership, so an owner who left cannot read project-run history through `/v1/instances/{id}/events` (`gateway/src/routes/mod.rs:191`). **This must ship before 8.16 lifts the claim guard.**<br>**Project content:** project key creation; `project_artifacts` and project board tables; private artifacts restricted to private runs; the project run list index `runs (project_id, id DESC) WHERE project_id IS NOT NULL` as its own no-transaction CIC file.<br>**Soft delete:** `status='deleted'` first, then batched cleanup (the `runs_project_agent` NO ACTION key forces runs to be cleared first); switch `delete_solo_project` and erase to that flow.<br>**Tests:** extend RLS test #5 to `thinktin_member`. |
| **8.16** sessions and workspaces | **Precondition:** the 8.15 events, approvals and inbox tagging has shipped.<br>**Dedicated agents:** `project_agents.dedicated` (the tenant cannot write it) plus the unique dedicated index. Add the "no private run on a dedicated instance" check (dedicated rows with `left_at IS NULL`) to `fill_space()` via `CREATE OR REPLACE`.<br>**Claim guard:** replace `project_id IS NULL` with "or this build can isolate scopes".<br>**Records:** add `project_id` to `RunRecord` and `columns!()`.<br>**Archives:** add a per-(instance, project) archive table keyed on `project_agents (project_id, instance_id)`. |
| **8.17** project collaboration | **Cross-owner trees:** drop `runs_parent_run_id_user_id_fkey` and `run_grants_parent_id_user_id_fkey` (`deploy-safe`), and re-create `runs_parent_space` with the chosen delete action.<br>**Project ids on runs:** add `NewRun.project_id` for roots, `runs.requested_by` (design A §2.3) and `project_agents.purpose`; copy the parent's `project_id` in `insert_run` (`runs.rs:267`) and `create_child_grant` (`grants.rs:246`).<br>**Delegation:** space-aware `is_lead(instance, space)` and project delegation targets (`executor.rs:770-776`, `delegate.rs:43-48`).<br>**Locks and plans:** a global `run_waits` lock; `plans`/`plan_steps` project columns.<br>**Board:** project board and tools. |
| **8.18** costs, approvals, permissions | **Budgets:** enforce `project_members.daily_token_limit`/`total_token_limit` in llm-gw (llmgw column grants); `usage_records.project_id`.<br>**Grant ancestry:** `run_grants.via_grant_id` (design A §4.2).<br>**Approvals:** routing to the owner only, and the "等待主人处理" DTO.<br>**Scope:** `projects.policy`, `project_agents.preauthorized_tools` and `approval_timeout_secs`; `allow_computer`; `project_agent_vault_items`; the preauthorised-tool intersection. |
| **8.19** notifications and events | Project feed: `project_seq`, a transactional outbox and sequencer (impl item 6). Change the inbox `(run_id,user_id)` FK for cross-owner notices. |
| **After 12.25 / 13.18** | Drop `teams`, `team_members` and `team_templates` (`deploy-safe`) and their erase statements. |

## Appendix A. Critic corrections: what was applied, what was not, and why

| # | Critic correction | Verdict | Evidence / what changed |
|---|---|---|---|
| 1 | Index for the `run_grants → project_agents` foreign key | **Applied** | The only `run_grants` indexes are the PK, `UNIQUE (id,user_id)` and `run_grants_instance (instance_id) WHERE revoked_at IS NULL` (`0001_init.sql:158-174`). Scratch EXPLAIN of the foreign-key lookup: with the new index it is an Index Scan on `run_grants_project`; without it, a filter over `run_grants_id_user_id_key` (or a seq scan). New `0044_run_grants_project_index.sql`; the later files are renumbered; test #7 checks the plan. |
| 2 | Do not VALIDATE in the transaction that adds the constraints; drop `UNIQUE USING INDEX` | **Applied** | `0045` holds only the NOT VALID foreign keys, and `0046` validates them. Verified: a foreign key accepts the plain unique indexes (`conindid` = `runs_id_space` / `run_grants_id_space`). |
| 3 | CREATE INDEX CONCURRENTLY deadlocks with a second migrator | **Applied** | Reproduced: `deadlock detected`, and the index was left `indisvalid = f`. sqlx code: blocking `pg_advisory_lock` at `sqlx-postgres-0.9.0/src/migrate.rs:198`; no-transaction path at 231-232; the `_sqlx_migrations` row is written only in `execute_migration` (315-338). The wrong comments are at `schema.rs:96` (the critic said 95) and `job.yaml:7`. Docs bullet added in C7. |
| 4 | `CHECK (left_at IS NULL OR NOT is_lead)` | **Applied, and extended** | The critic missed the second blocker: the draft's `tenant_update` WITH CHECK also had `NOT dedicated`, so the same UPDATE fails with 42501 (Forbidden, which is 500 via `gateway/src/error.rs:67-80`) even after the CHECK fix. Both were verified in scratch. `NOT dedicated` is removed from `tenant_update` and kept in `tenant_insert`. Test #4 gets a dedicated regression. |
| 5 | Test #8 never reaches the project step | **Applied** | Confirmed: `create_template` validates only the name and agent ids (`gateway/src/routes/teams.rs:118-160`), and the harness fails in `control::resolve` at `control/src/lib.rs:250-254` (the critic cited 244-247, which is the withdrawn-version check). Two-lead case added. `create_solo_project` inserts the project rows before `check_agents` (mirroring `teams.rs:13-27`), so case (b) also proves the project rows roll back. |
| 6 | Seed test #2 with raw SQL | **Applied** | At version 38 `projects` does not exist; from C5 on, `create_team` writes it. |
| 7 | Tag events, approvals and inbox before project runs execute | **Applied (8.15 row)** | `events` has only the `(run_id,user_id)` FK (`0001_init.sql:280-281`) and the `user_id` tenant policy from the loop at `0001_init.sql:435` (the critic said 436). The route is `/v1/instances/{id}/events` (`gateway/src/routes/mod.rs:191`). Moved to 8.15 and made a precondition of 8.16; the 8.18/8.19 rows were trimmed accordingly. |
| 8 | D4 precondition | **Applied, with the remedy corrected** | No `v*` tag; RDS not created (`docs/handoff.md:131`). The critic's "同一版要补拷" does not work: old replicas keep writing `teams` after the same-release migration runs. The remedy is dual-write in this release, or a re-copy in the *next* release once old replicas are gone. The text is in D4 and the 0039 header. |
| 9 | `fill_space` guard as an allowlist | **Applied** | Verified: tenant and superuser are refused, the worker succeeds. `Tx<Worker>` sets `role = thinktin_worker` (`store/src/lib.rs:143`), so `current_user` matches. The UPDATE branch has no role check, so foreign-key actions running as the owner are unaffected; the `ON DELETE SET NULL (run_grant_id)` column is not in the trigger's `UPDATE OF` list anyway. |
| 10 | Erase order and pending phone invites | **Applied** | The exact lines are `DELETE FROM runs` at `users.rs:200` (the critic said 198), the teams deletes at 211-212, `UPDATE instances` at 223 (the critic said 224) and the phone overwrite at 226. Placing the statements after 212 meets both constraints. Verified in scratch. |
| 11 | Commit-sequence fixes | **Applied** | Test #1 is split across C1 and C3; "C7 depends on C3 only". |
| 12 | Take instances' lock first in 0039 | **Rejected** | No order is deadlock-free against today's call paths.<br>• Instances first deadlocks with GET/PATCH/POST `/v1/teams`, which lock teams before instances: `team()` reads `teams` and then joins `instances` (`store/src/teams.rs:44-55`); `create_team` inserts `teams` and then calls `instance()` (`teams.rs:13-29`).<br>• Teams first (the draft) deadlocks with adoption and `delegation_targets`, which touch instances first (`instances.rs:259-288`, `564-577`).<br>Under the D4 precondition there is no traffic, and any deadlock aborts the single 0039 transaction cleanly so it can be rerun. The draft order is kept, and the 0039 header now says so. |
| 13 | Make the forward columns consistent | **Applied (option b, as rule D10)** | §3 fields and lifecycle fields only. `project_agents.purpose` is dropped; `policy`, `preauthorized_tools`, `approval_timeout_secs` and the vault-items table are deferred to 8.17/8.18. Adding them later to these tiny tables costs nothing. |
| 14 | Add `runs.requested_by` and `run_grants.via_grant_id` now; plan the 8.15 list index | **Partly applied** | No columns are added. They have no 8.13 reader or writer, and adding a nullable column later is a catalog-only change. The 8.15 list index, `requested_by` (8.17) and `via_grant_id` (8.18) are written into §8. |
| 15 | Wrong citation for contiguity | **Applied** | `check_migrations.py:318`. |
| 16a | Drop the `UNIQUE USING INDEX` step | **Applied** | Same as #2. |
| 16b | Drop `shared_at` and its trigger from 8.13 | **Rejected** | It is the only DB-side way to keep tenant writes "single-user only" without a definer function: `project_members` tenant RLS hides other users' rows, so a policy cannot count them. Keeping it makes the 8.13 policies final; test #3 exercises it through worker SQL. |
| 16c | Drop unused API: `ProjectRole`, `my_project_agents`, `ProjectRecord.goal/status/shared` | **Applied in part** | `ProjectRole`, `ProjectRecord.goal`, `creator_id`, and the `goal` parameters and grants are removed. `my_project_agents` is kept and now backs `team()`, so the query is not written twice. `status` and `shared` are kept because `writable_solo` uses them. |
| 16d | `WITH CHECK` terms are redundant | **Applied in part** | The critic called them harmless. They are not on UPDATE (see #4), so they are removed from `tenant_update`. On INSERT they stay as defence in depth. |
| 16e | Reword the `project_keys` comment | **Applied** | |
| 17 | Docs rule for backfills under FORCE | **Applied (C3)** | Confirmed: `UPDATE run_grants` at `0024_peers.sql:13`, `0025_board.sql:43`, `0026_ask.sql:16`, `0036_search.sql:22` and `0038_browser.sql:20`, and no migration uses NO FORCE. This is harmless so far because every database was migrated by a superuser or was empty. |

Draft citations corrected in this pass:
- `docs/release.md:47-50` → `49-50`;
- `teams.rs` `is_team_lead` → `instances.rs:582-590`;
- `delegation_targets` → `instances.rs:564-577`;
- `ffi.rs:816` → `818`;
- `delegate.rs:44-49` → `43-48`;
- `deploy-checklist.md:58-60` → `59-60`.

The critic's "checked and correct" items still hold:
- the 0001/0014 fix is needed;
- `Migrator::run_to` exists (`migrator.rs:185`), and `-- no-transaction` is honoured (`source.rs:234`);
- adoption is a single transaction;
- the only existing triggers are on `artifacts` and `instances` (`0007:47`, `0023:59`).


## 待定问题

- D4 precondition: will migration 0039 be released before the first production deployment (no v* tag, RDS not created per docs/handoff.md:131)? If a database running a <=0038 build exists by then, choose between dual-writing teams and projects in this release, or a re-copy migration in the next release after the old replicas are gone.
- D8: editing 0001_init.sql:16-18 and 0014_device_relay.sql:15 changes their sqlx checksums. Is there any persistent dev, staging or Tokyo database that already applied them and must be kept? Otherwise it reports 'modified' and has to be recreated.
- C7 timing: should the run-space migrations (0040-0046) ship in the same release as 0039? If they ship after a first deployment with real runs, 0040's one-transaction backfill must be split (add columns and trigger, then batched backfill, then CHECK NOT VALID / VALIDATE / SET NOT NULL).
- D3: after 8.14, should old /v1/teams PATCH and DELETE on a project that has other members return 409 (enforced by projects.shared_at in the tenant policies), or follow design A ('edit only my own agents, 409 only on delete')?
- D10: confirm that design A's projects.policy, project_agents.preauthorized_tools, approval_timeout_secs, purpose and project_agent_vault_items are deferred to 8.17/8.18 rather than created empty in 8.13.
- Invites: store invitee_phone as plaintext E.164 (consistent with login_codes) or as a keyed hash? And should erasing an account delete pending phone invites addressed to that number (8.13 does), or should 16.6 define a different rule?
- D9: confirm that no read-only /v1/projects routes and no Project FFI types ship in 8.13, so their response shape is designed once in 8.14/8.15 together with the ProjectTx member semantics.