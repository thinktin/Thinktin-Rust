# 8.13 实现方案草稿（原始结果，2026-11-04）

workflow `projects-8-13-plan` 的第二步。**评审和定稿两步因为用量上限没跑**，用之前要再核对一遍。

# WP 8.13 implementation plan: project model and migration, with teams becoming single-user projects

Branch `claude/determined-lovelace-vn0j5h` @ `be8afae`. Every file:line below was re-checked at HEAD. The proposed SQL in §1 was applied to a scratch PostgreSQL 16 database in both of these setups, then dropped (no repo files were touched):
- as a superuser over seeded team data;
- as a **NOSUPERUSER NOCREATEROLE NOBYPASSRLS database owner**, with the 0001/0014 fix from §1.0.

What that run confirmed:
- the backfill copies rows under FORCE RLS;
- tenant writes are confined to the user's own projects;
- the lead swap works through upsert;
- the `fill_space` trigger and the space foreign keys reject forged or cross-space rows;
- `CREATE INDEX CONCURRENTLY` works in its own file, and the resulting index is used by the foreign-key check.

## 0. Decisions, and where they depart from design A

| # | Decision | Why |
|---|---|---|
| D1 | Migrations start at **0039** (0039–0044). Design A's 0031–0036 are already taken; the last migration is `0038_browser.sql`. | `tools/ci/check_migrations.py:29` requires contiguous numbers. |
| D2 | **Single-user project writes go through `thinktin_app` RLS policies, not `Tx<Worker>`.** The policies allow only: projects I created that were never shared, a creator row for me, and my own instances. | projects-impl.md "旧版领养" requires the restricted write path to reuse the tenant transaction. Adoption is one `Tx<Tenant>` (`gateway/src/routes/teams.rs:191-224`): `lock_instance_count`, then `control::adopt_in` (`control/src/lib.rs:216-224`), then `create_run_grant`, then `create_team`, then commit. |
| D3 | New column **`projects.shared_at`**. A trigger sets it when the first non-creator member row is inserted (worker only, from 8.14). Every tenant write policy requires `shared_at IS NULL`. | Enforces "single-user only" in the database without SECURITY DEFINER. In 8.13 no project can become shared, because tenants cannot insert `role='member'`. Old `/v1/teams` writes on a shared project return 409 (design A instead allowed diff-only edits). |
| D4 | **`TeamId == ProjectId` and `TeamTemplateId == project template id`. The project tables are the only source of truth.** The new binary never reads or writes `teams`, `team_members` or `team_templates`. They are copied once, frozen, kept, and still erased on account deletion. They are dropped (with `deploy-safe`) in the release after 12.25/13.18. No dual-write. | Both kinds of client hit one table, so there is no double adoption and no double editing. The cost is that a rollback below 0039 does not see team changes made after the migration. That is acceptable now: there is no `v*` tag, and the progress file says the server machine has not been bought (open question). |
| D5 | **8.13 adds no `thinktin_member` / `thinktin_definer` roles, no SECURITY DEFINER functions and no member policies.** Those belong to 8.15. | The brief: the tenant sees only its own rows until 8.15. All new trigger functions are SECURITY INVOKER and read nothing that is RLS-dependent across users. |
| D6 | **Typed space columns on `runs` and `run_grants` only:** `project_id`, `space_kind IN ('private','project')`, `space_id`. The names avoid clashing with `run_grants.scope jsonb` (`0001_init.sql:164`) and `store::ArtifactScope`. New composite foreign keys sit *alongside* the old `(x,user_id)` ones (expand). 8.17 drops the old ones (contract). | impl item 1: typed scope, and ID collisions cannot cross types. The claim guard (impl "8.14–8.16") needs `runs.project_id` to exist in every worker version before any project run is written. |
| D7 | **Invites and the project key table are created in 8.13** (schema only, worker-only grants). | WBS 8.13 (`docs/wbs.md:216`) and projects.md §3 list ProjectInvite. Design A pushed it to P6. |
| D8 | **Tests migrate as a production-like owner.** `TestDb` creates `thinktin_test_owner` (LOGIN, no SUPERUSER, CREATEROLE, CREATEDB or BYPASSRLS) and migrates with it. This requires fixing the role DO-blocks in `0001_init.sql:16-18` and `0014_device_relay.sql:15`, which today fail for such an owner: PostgreSQL checks the CREATEROLE permission before it checks whether the role exists. Verified. | The impl plan requires tests that use the production migration account and FORCE RLS. Editing 0001/0014 is allowed only because no `v*` tag and no deployed database exist (open question). |
| D9 | **No new `/v1/projects*` routes, no Project FFI types, and no Android binding regeneration in 8.13.** | See §3 and §4. |

## 1. Migrations

### 1.0 Fix role creation in 0001 and 0014 (in commit C1)

Replace these lines:
- `crates/store/migrations/0001_init.sql:16-18`
- `crates/store/migrations/0014_device_relay.sql:15`

Use this pattern, and change the comment at 0001:8 accordingly:

```sql
-- 角色先查再建：托管库的属主账号没有 CREATEROLE，CREATE ROLE 会在查重之前就报权限错，所以角色由高权限账号预先建好时
-- 这里必须跳过（docs/deploy-checklist.md 第 3 节）。并发建库仍可能撞唯一键，照样忽略。
DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_app') THEN CREATE ROLE thinktin_app NOLOGIN NOBYPASSRLS; END IF; EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $$;
-- same for thinktin_worker (NOLOGIN BYPASSRLS), thinktin_llmgw (NOLOGIN BYPASSRLS); 0014: thinktin_relay (NOLOGIN BYPASSRLS)
```

- A role that really is missing still fails loudly with "permission denied to create role", which is what we want. Silently swallowing `insufficient_privilege` would not.
- Docs: `docs/deploy-checklist.md:60` becomes true as written. Add one sentence to `docs/release.md:74` saying the check is by name.
- Side effect: any local database that already applied 0001 now reports `modified` and must be recreated. Test databases are created fresh, so tests are unaffected.

### 1.1 `crates/store/migrations/0039_projects.sql` (one transaction)

```sql
-- 项目（WBS 8.13，docs/projects.md 第 3 节，docs/projects-impl.md“数据、身份与现有接口”）：项目、成员、项目 agent、
-- 邀请、项目密钥、项目模板；现有团队搬成单人项目（id 不变：TeamId 就是 ProjectId），团队模板搬成项目模板。
-- 这一版只有单人项目：thinktin_app 只能写自己创建、从没共享过（shared_at IS NULL）的项目，成员只有自己，agent 只能是
-- 自己的实例。跨用户的写（8.14 起：接受邀请、加入、移出）只走 thinktin_worker；按成员关系的读（thinktin_member）在 8.15。
-- 旧表 teams、team_members、team_templates 复制后不再读写，App 换成项目页（12.25、13.18）以后的版本再删。

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
    dedicated      boolean NOT NULL DEFAULT false,              -- 8.16
    position       integer NOT NULL DEFAULT 0,
    purpose        text NOT NULL DEFAULT '' CHECK (length(purpose) <= 200),
    allow_computer boolean NOT NULL DEFAULT false,              -- 8.18
    added_at       timestamptz NOT NULL DEFAULT now(),
    left_at        timestamptz,                                 -- 撤回、实例删除：只标记（运行记录要引用这一行）
    PRIMARY KEY (project_id, instance_id),
    UNIQUE (project_id, instance_id, user_id),
    FOREIGN KEY (project_id, user_id) REFERENCES project_members (project_id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (instance_id, user_id) REFERENCES instances (id, user_id) ON DELETE CASCADE,
    CHECK (left_at IS NULL OR NOT (is_lead OR dedicated))
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

-- 项目密钥（KMS 包裹的 DEK，8.15 起按需建）：删这一行就是销毁密钥。业务角色没有任何权限。
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
CREATE POLICY tenant_read ON project_agents FOR SELECT TO thinktin_app USING (user_id = app_user_id());
CREATE POLICY tenant_insert ON project_agents FOR INSERT TO thinktin_app
    WITH CHECK (user_id = app_user_id() AND NOT dedicated
                AND EXISTS (SELECT 1 FROM projects p WHERE p.id = project_id
                              AND p.creator_id = app_user_id() AND p.shared_at IS NULL));
CREATE POLICY tenant_update ON project_agents FOR UPDATE TO thinktin_app
    USING (user_id = app_user_id()
           AND EXISTS (SELECT 1 FROM projects p WHERE p.id = project_id
                         AND p.creator_id = app_user_id() AND p.shared_at IS NULL))
    WITH CHECK (user_id = app_user_id() AND NOT dedicated
                AND EXISTS (SELECT 1 FROM projects p WHERE p.id = project_id
                              AND p.creator_id = app_user_id() AND p.shared_at IS NULL));
CREATE POLICY tenant ON project_templates TO thinktin_app
    USING (user_id = app_user_id()) WITH CHECK (user_id = app_user_id());
-- project_invites、project_keys：没有给 thinktin_app 的策略和权限（默认拒绝）。

GRANT SELECT, DELETE ON projects TO thinktin_app;
GRANT INSERT (id, creator_id, name, goal) ON projects TO thinktin_app;
GRANT UPDATE (name, goal, updated_at) ON projects TO thinktin_app;
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
- The column grants are why a tenant gets `permission denied` (42501, mapped to `Error::Forbidden`) when it tries to set `dedicated`, `shared_at`, `status`, budgets or `consented_at`. Verified.
- Cascades still work for a tenant `DELETE FROM projects`, because PostgreSQL runs foreign-key actions as the table owner with FORCE suppressed. Verified: deleting the project left 0 rows in `project_agents`.
- The name CHECK matches the gateway's `check_len` (characters, `gateway/src/routes/mod.rs:218-224`). A development database holding a team name the gateway would have rejected aborts on `projects_name_check`; recreate that database.
- `check_migrations.py` raises nothing here. Every changed table is either new or only toggles FORCE, and the toggles are not flagged.

### 1.2 `0040_run_spaces.sql` (one transaction): typed space on runs and run grants, nothing writes it yet

```sql
-- 运行、授权的空间（docs/projects-impl.md 第 1、3 条）：private（user_id）或 project（project_id）。父子运行、子授权、运行用的
-- 授权必须在同一个空间（0044 的复合外键）；空间由触发器从 project_id 算，建了就不能改；带 project_id 的行只有服务端写得出
-- （租户角色写会报 42501）。8.13 没有任何地方写 project_id；旧的 (x, user_id) 外键照留，8.17 跨主人的运行树再删。
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
    IF NEW.project_id IS NOT NULL AND current_user = 'thinktin_app' THEN
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

Files 0041–0043 each have `-- no-transaction` as the first line and contain exactly one statement (`docs/release.md:47-50`). These are the first such files in the repo; sqlx 0.9 honours them (`Migration::no_tx`).
- `0041_runs_space_index.sql`: `CREATE UNIQUE INDEX CONCURRENTLY runs_id_space ON runs (id, space_kind, space_id);`
- `0042_run_grants_space_index.sql`: `CREATE UNIQUE INDEX CONCURRENTLY run_grants_id_space ON run_grants (id, space_kind, space_id);`
- `0043_runs_project_index.sql`: `CREATE INDEX CONCURRENTLY runs_project ON runs (project_id, instance_id, user_id) WHERE project_id IS NOT NULL;` The `runs_project_agent` foreign-key check on project-agent update/delete needs this index. Verified: Index Only Scan.

`0044_run_space_keys.sql` (one transaction):

```sql
ALTER TABLE runs ADD CONSTRAINT runs_id_space UNIQUE USING INDEX runs_id_space;
ALTER TABLE run_grants ADD CONSTRAINT run_grants_id_space UNIQUE USING INDEX run_grants_id_space;
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
ALTER TABLE runs VALIDATE CONSTRAINT runs_project_agent;
ALTER TABLE run_grants VALIDATE CONSTRAINT run_grants_project_agent;
ALTER TABLE run_grants VALIDATE CONSTRAINT run_grants_parent_space;
ALTER TABLE runs VALIDATE CONSTRAINT runs_parent_space;
ALTER TABLE runs VALIDATE CONSTRAINT runs_grant_space;
```

Results verified in scratch:
- an old-style tenant insert with no space columns gets `space_kind = 'private'` and `space_id = user_id`;
- a tenant insert with `project_id` fails with "server only" (42501, mapped to Forbidden);
- an UPDATE that changes `space_id` fails with 23514 (mapped to Invalid);
- `UPDATE … SET state` is unaffected;
- a private child of a project parent is rejected by `runs_parent_space` (23503, mapped to Invalid);
- deleting a project_agent that a project run references is rejected.

Events, approvals, inbox_items, artifacts, plans and usage_records are **not** touched in 8.13 (see §8).

## 2. Store API (`crates/store`)

**`proto/src/domain.rs`**
- Add `ProjectId` to `id_type!` (lines 51-76).
- Add `impl From<TeamId> for ProjectId` and `impl From<ProjectId> for TeamId`.
- Add `str_enum!(ProjectStatus { Active="active", Archived="archived", Deleted="deleted" })` and `str_enum!(ProjectRole { Creator="creator", Member="member" })`. The Role enum is unused until 8.14; adding it now is optional.
- No wire types change.

**`lib.rs`**
- Add `mod projects;` next to `mod teams;` (line 33) and `pub use projects::{ProjectRecord, SoloAgent};`.
- No new `Db`/`Tx` role in 8.13; `ProjectTx` and `Db::project` arrive in 8.15.

**New file `crates/store/src/projects.rs`**, all methods on `impl Tx<Tenant>`, RLS-backed:

```rust
pub struct SoloAgent { pub instance_id: InstanceId, pub is_lead: bool, pub position: u32 }
pub struct ProjectRecord { pub id: ProjectId, pub creator_id: UserId, pub name: String, pub goal: String,
    pub status: ProjectStatus, pub shared: bool, pub created_at: DateTime<Utc>, pub updated_at: DateTime<Utc> }

/// 单人项目：creator = me，agent 都是我没删的实例。和领养在同一个租户事务里。
pub async fn create_solo_project(&mut self, name: &str, goal: &str, agents: &[SoloAgent]) -> Result<ProjectId>;
pub async fn own_project(&mut self, id: ProjectId) -> Result<ProjectRecord>;        // status <> 'deleted'
pub async fn own_projects(&mut self) -> Result<Vec<ProjectRecord>>;                // status = 'active' ORDER BY created_at, id
pub async fn my_project_agents(&mut self, id: ProjectId) -> Result<Vec<SoloAgent>>;// mine, left_at IS NULL, instance not deleted
pub async fn update_solo_project(&mut self, id: ProjectId, name: Option<&str>, goal: Option<&str>) -> Result<()>;
pub async fn replace_my_project_agents(&mut self, id: ProjectId, agents: &[SoloAgent]) -> Result<()>;
pub async fn delete_solo_project(&mut self, id: ProjectId) -> Result<()>;
async fn writable_solo(&mut self, id: ProjectId) -> Result<()>;   // not visible/active → NotFound; shared_at set → Conflict("project is shared")
async fn check_agents(&mut self, agents: &[SoloAgent]) -> Result<()>;
```

What each function does:
- **`check_agents`**:
  - more than one lead returns `Invalid("a team has at most one lead")`, which keeps 422;
  - a duplicate `instance_id` returns `Conflict("project_agents_pkey")`, which keeps today's 409 from the `team_members` primary key;
  - each instance goes through `self.instance(id)` (`instances.rs:291-301`), so another user's or a deleted instance returns NotFound and stays 404.
- **`create_solo_project`**:
  - `INSERT INTO projects (id, creator_id, name, goal) VALUES ($1, app_user_id(), $2, $3)`;
  - `INSERT INTO project_members (project_id, user_id, role) VALUES ($1, app_user_id(), 'creator')`;
  - per agent: `INSERT INTO project_agents (project_id, instance_id, user_id, is_lead, position) VALUES ($1,$2,app_user_id(),$3,$4)`.
- **`replace_my_project_agents`** (replaces the delete-and-reinsert at `teams.rs:104-110`, so rows and per-agent settings are kept). It runs three statements in this order, because unique indexes are checked per row:
  1. `UPDATE project_agents SET is_lead = false WHERE project_id = $1 AND user_id = app_user_id() AND is_lead`
  2. `UPDATE project_agents SET left_at = now() WHERE project_id = $1 AND user_id = app_user_id() AND left_at IS NULL AND NOT (instance_id = ANY($2))`
  3. per agent: `INSERT … ON CONFLICT (project_id, instance_id) DO UPDATE SET is_lead = EXCLUDED.is_lead, position = EXCLUDED.position, left_at = NULL, added_at = CASE WHEN project_agents.left_at IS NULL THEN project_agents.added_at ELSE now() END`

  The lead swap was verified in scratch.
- **`update_solo_project`**: `writable_solo`, then `UPDATE projects SET name = coalesce($2,name), goal = coalesce($3,goal), updated_at = now() WHERE id = $1 AND status = 'active'`. Zero rows returns NotFound.
- **`delete_solo_project`**: `writable_solo`, then `DELETE FROM projects WHERE id = $1`. Members, agents, invites and keys cascade; instances stay. Zero rows returns NotFound. 8.15 replaces this with the soft-delete flow once project content exists.

**`crates/store/src/teams.rs`** keeps every signature (`teams.rs:11-190`) as a compatibility layer:

| Function | New implementation |
|---|---|
| `create_team(name, members)` | `create_solo_project(name, "", &solo(members))`, then `team(id.into())` |
| `team(id)` | `own_project` (name, created_at); then `SELECT a.instance_id, a.is_lead, a.position FROM project_agents a JOIN instances i ON i.id = a.instance_id AND i.state <> 'deleted' WHERE a.project_id = $1 AND a.left_at IS NULL ORDER BY a.position, a.instance_id`. RLS limits this to my agents. Role is `Lead` if `is_lead`, else `Member`. JSON stays `{id,name,members,created_at}`. |
| `teams()` | `own_projects()`, then `team()` for each (same N+1 pattern as today) |
| `update_team(id, name, members)` | `update_solo_project(id, name, None)`, then `replace_my_project_agents` if members were given, then `team(id)` |
| `delete_team(id)` | `delete_solo_project` |
| `create_team_template`, `team_templates`, `team_template`, `delete_team_template` | Same SQL with the table renamed to `project_templates`; spec format unchanged (`from_json(…, "team template")`) |

**`crates/store/src/instances.rs`**
- `delegation_targets` (lines 563-577), `Tx<Tenant>`. Exact old team semantics: only projects the lead's owner created, only my own agents.
  ```sql
  SELECT <cols> FROM instances WHERE state <> 'deleted' AND id <> $1 AND user_id = app_user_id() AND id IN (
    SELECT a.instance_id FROM project_agents a
     WHERE a.left_at IS NULL AND a.user_id = app_user_id() AND a.project_id IN (
       SELECT l.project_id FROM project_agents l JOIN projects p ON p.id = l.project_id
        WHERE l.instance_id = $1 AND l.is_lead AND l.left_at IS NULL
          AND p.creator_id = app_user_id() AND p.status = 'active'))
  ORDER BY name, id
  ```
- `is_team_lead` (lines 580-590), `Tx<Worker>`:
  ```sql
  SELECT EXISTS (SELECT 1 FROM project_agents a JOIN projects p ON p.id = a.project_id
     WHERE a.instance_id = $1 AND a.is_lead AND a.left_at IS NULL AND p.creator_id = a.user_id AND p.status = 'active')
  ```
  - The `creator_id = owner` condition keeps a lead in someone else's shared project (8.14+) from getting delegate tools in its private runs. The tenant-side `delegation_targets` already excludes those projects through RLS.
  - Supports one instance leading several projects and being a member elsewhere, as `orchestrator/tests/executor.rs:2117-2133` requires: the key is per (project, instance).
- `delete_instance` (lines 384-411): after the soft delete, add `UPDATE project_agents SET is_lead = false, left_at = now() WHERE instance_id = $1 AND left_at IS NULL`. The tenant policy limits this to my unshared projects, which in 8.13 is all of them. It frees the lead slot and preserves the old PATCH-after-delete behaviour.

**`crates/store/src/users.rs` `erase_account`** (around lines 211-212). Keep both old `DELETE FROM teams/team_templates WHERE user_id` lines, because the frozen copies hold user content. Add, in this order:
```
"UPDATE project_agents SET is_lead = false, dedicated = false, left_at = coalesce(left_at, now()) WHERE user_id = $1",
"DELETE FROM projects WHERE creator_id = $1",                       -- cascades members/agents/invites/keys (8.15: soft delete)
"UPDATE project_members SET left_at = now(), left_reason = 'erased' WHERE user_id = $1 AND left_at IS NULL",
"DELETE FROM project_invites WHERE inviter_id = $1 OR invitee_id = $1",
"DELETE FROM project_templates WHERE user_id = $1",
```
Update the doc comment at lines 177-181 to match.

**`runs.rs` / `grants.rs`** (commit C7, together with 0040–0044):
- Claim guard: this build only executes private runs. Add `AND r.project_id IS NULL` or `AND project_id IS NULL` to:
  - `claim_next_run` (line 880, the first SELECT);
  - `take_over_expired` (line 997);
  - `claim_expired_waits` (line 1295);
  - `due_pipelines` (line 1428).
- Add a comment next to `known_sources()` (lines 201-205) explaining it. This is impl "8.14–8.16": all workers exclude project runs they cannot isolate.
- Private grant lookups exclude project grants (impl item 3). Add `AND project_id IS NULL` to:
  - `active_grant_for_instance` (`grants.rs:303-315`);
  - `run_grants(instance)` (`grants.rs:136-147`), which the gateway's `ensure_instance_grant` uses (`gateway/src/routes/runs.rs:67-91`).
- `RunRecord`, `columns!()`, `NewRun` and `insert_run` are unchanged in 8.13. Parent-to-child `project_id` copying moves to 8.17; the foreign keys already reject mismatches.

**`schema.rs:16`**: make `fn migrator()` `pub(crate)` for the test helper.

**`testing.rs` (commit C1)**:
- Keep `TestDb { db, admin, name }` and add `owner: PgConnectOptions`.
- `new()` becomes `migrated(None)`. Add `pub async fn up_to(version: i64)`, which calls `migrator().run_to(version, &owner_pool)`, and `pub async fn migrate_rest(&self)`, which runs the remaining migrations with `set_ignore_missing(true)` as the owner.
- On the admin connection:
  1. `SELECT pg_advisory_lock(hashtextextended('thinktin-test-roles', 0))`. Advisory locks are per database, and every admin connection uses the same `DATABASE_URL` database.
  2. `sqlx::raw_sql` of one DO block that creates, `IF NOT EXISTS`, the roles `thinktin_app`, `thinktin_worker`, `thinktin_llmgw` and `thinktin_relay` (same attributes as 0001/0014), plus `thinktin_test_owner LOGIN NOSUPERUSER NOCREATEROLE NOCREATEDB NOBYPASSRLS PASSWORD 'thinktin_test_owner'`.
  3. Unlock.
  4. `CREATE DATABASE {name} OWNER thinktin_test_owner`.
- Migrate over a one-connection pool using `admin.clone().database(&name).username(OWNER).password(OWNER)`.
- `TestDb.db` stays the 16-connection **superuser** pool, so the roughly 130 raw `db.pool()` call sites keep working.
- On PostgreSQL 15+ the database owner has CREATE on `public`, so the `ensure_event_partitions` and blob-purge definer functions (now owner-owned) work as they will in production.

## 3. Gateway

- Code in `crates/gateway/src/routes/teams.rs` and `routes/mod.rs:158-169` is unchanged. Only the module doc changes, to say the routes are a compatibility view over single-user projects.
- Paths, status codes and JSON stay the same:
  - another user's id gives 404, through tenant RLS on `projects`;
  - a shared project (impossible in 8.13) gives 409 through `Error::Conflict`;
  - 1-12 member validation (`teams.rs:16-25`) is kept.
- **Adoption stays atomic with no code change.** `adopt_template` (`teams.rs:183-226`) still runs `lock_instance_count`, then for each member `control::adopt_in` and `create_run_grant`, then `create_team` (now project rows), all in one `Tx<Tenant>`. Any error drops the transaction and rolls back instances, grants, the `instance.adopt` audit rows, `instance.state` events and project rows together. Adopted teams keep private grants with the full `default_scope` and `project_id = NULL` runs (design A).
- **No new `/v1/projects*` or `/v1/project-templates*` routes in 8.13.**
  - The only safe candidates are `GET /v1/projects` and `GET /v1/projects/{id}`, as tenant reads of `own_project(s)`.
  - Their response must later include other members and agents and switch to `ProjectTx` semantics (404 for non-members) in 8.15. Shipping a creator-only shape now would freeze a contract no app uses before 12.25/13.18.
  - `/v1/project-templates/{id}/adopt` should return a Project, which does not exist yet.
  - All of these move to 8.14.
- `gateway/src/error.rs:67-80` still maps `Forbidden` to 500. No `/v1/teams` path can reach 42501 in 8.13: every write follows a creator-visible read or creates a fresh project. Mapping member-path 42501 to 404 is 8.15.

## 4. client-core / FFI

- Keep `Team`, `TeamMember`, `TeamTemplate` and `TemplateMember` (`client-core/src/ffi.rs:816-918`) and the 10 methods (`ffi.rs:2592-2708`, `api.rs:1722-1818`) unchanged.
- Add **no** Project records in 8.13, so the Android binding `apps/android/core/src/main/kotlin/cn/thinktin/core/client_core.kt` needs no regeneration and nothing in `CoreThinktinService.kt` or Swift changes.
- When 8.14 adds `Project*` records and methods:
  - additions only, with new fields marked `#[uniffi(default = None)]`, following the existing convention (`ffi.rs:63`);
  - run `tools/client-core/gen-bindings.sh`, then commit the regenerated `client_core.kt` in its own commit (precedent: `4f4950d`, `c2b8892`);
  - iOS regenerates at build time.

## 5. Orchestrator

- **No source change in 8.13.**
  - `executor.rs:770-776` keeps calling `is_team_lead`, and `delegate.rs:44-49` keeps calling `delegation_targets`; both are reimplemented in store (§2) with the same private semantics.
  - The claim guard lives in store `runs.rs`.
- Peers, ask, board, pipelines, `lock_run_waits` (per user, `runs.rs:428-435`), `create_child_grant`, `delegate.rs:169` (`create_run(ctx.user)`) and the `ToolContext` shape (`shim.rs:68-75`) stay as they are until 8.16/8.17.
- Expected passing unchanged: `orchestrator/tests/executor.rs` delegation tests 2005-2252 (helper `team()` at 2215 calls `Tx<Tenant>::create_team`).

## 6. Tests

All tests use the existing style: `TestDb::new()` returns `None` and the test is skipped, raw SQL goes through `x.conn()`, and errors are checked with `matches!(err, Error::Forbidden(_))`.

**Store (`crates/store/src/tests.rs`)**
1. **New `migrations_run_as_a_plain_owner`.**
   - Owner of `runs`, `projects` and `_sqlx_migrations` has `rolsuper`, `rolbypassrls` and `rolcreaterole` all false.
   - `relforcerowsecurity` is true on every table that `thinktin_app` can touch.
2. **New `teams_move_into_single_user_projects`** (backfill on a non-empty database):
   - `TestDb::up_to(38)`;
   - as superuser, seed users A and B, A's instances L, W and D (D soft-deleted), team T1 (L lead, W member), team T2 (D lead, L member), B's team T3 and A's template;
   - run `migrate_rest()` as the owner.
   - Assert:
     - project ids equal team ids, `creator_id` equals `user_id`, and each project has exactly one creator member row;
     - in T2, D has `left_at` set and `is_lead = false`, and T2 has no lead;
     - template ids and spec are unchanged;
     - `db.tenant(A).teams()` returns T1 and T2 with the same members and roles as before, `tenant(B).teams()` returns T3 only, and `tenant(A).team(T3)` is NotFound;
     - FORCE is restored on `teams`, `team_members`, `team_templates`, `instances` and all six new tables.

   This is the test that catches a missing `NO FORCE`: without it the in-migration count check compares 0 with 0 and passes.
3. **New `solo_projects_stay_with_their_creator`** (isolation matrix):
   - Alice runs `create_team`. Bob gets NotFound from `team`, `update_team` and `delete_team`, and `teams()` is empty.
   - Raw SQL as Bob:
     - inserting a creator row into `project_members` on Alice's project gives Forbidden (RLS);
     - inserting Bob's own instance into `project_agents` of Alice's project gives Forbidden.
   - Alice inserting Bob's instance gives `Invalid("reference project_agents_instance_id_user_id_fkey")`.
   - Alice updating `dedicated`, or inserting `projects` with `shared_at`, gives Forbidden (column privilege).
   - Worker sets `shared_at`; Alice's `update_team` and `delete_team` then give `Conflict` and `team()` still reads.
   - Worker inserts a `role='member'` row for Bob (with `consented_at`); `shared_at` is set by the trigger.
   - `thinktin_app` has no privilege on `project_invites` or `project_keys` (a SELECT gives Forbidden).
4. **New `team_members_are_replaced_in_place`**:
   - Swapping lead and member in one `update_team` works.
   - Removing W then re-adding it keeps one row (count 2, not 3) with a fresh `added_at`.
   - A duplicate instance in the list gives `Conflict`.
   - `delete_instance(lead)` hides it from `team()` and frees the lead, so the next `update_team` with a new lead succeeds.
   - `delegation_targets` and the worker's `is_team_lead` follow every step.
   - A project created by Bob (raw worker SQL) where Alice's L is lead gives `is_team_lead(L) == false` and adds no targets.
5. **Update `every_tenant_table_the_app_can_touch_has_rls`** (lines 763-817):
   - scan all `relkind IN ('r','p') AND NOT relispartition` tables, not only those with a `user_id` column (line 773);
   - every table the app can touch must have `relrowsecurity` and `relforcerowsecurity` true, at least one policy whose `roles` contains `thinktin_app`, and no app policy whose `qual` or `with_check` is `'true'`;
   - add `projects`, `project_agents` and `project_templates` to the `must` list (line 812, keeping `teams`).
6. **Update `erasing_an_account_deletes_its_content`** (seeding at lines 952-976 unchanged; list at 1070-1093):
   - the seeded `create_team` and `create_team_template` now produce project rows;
   - before the erase, insert one raw `teams` and one `team_templates` row per user to stand in for the frozen copies;
   - list: drop `team_members`; add `project_templates`, `project_members` and `project_agents`;
   - assert `SELECT count(*) FROM projects WHERE creator_id = $1` is 0 for Alice and 1 for Bob.
7. **New `project_runs_are_server_only_and_never_claimed`** (commit C7):
   - Tenant inserting a run with `project_id` gives Forbidden; tenant `UPDATE runs SET space_id` gives Invalid.
   - Worker-inserted project run (via `w.conn()`, on an existing `project_agents` row): `claim_next_run` returns None.
   - With an expired lease, `take_over_expired` returns 0. A project run in `waiting_quota` with an expired `wait_deadline` is skipped by `claim_expired_waits`. A project `kind='pipeline'` root is skipped by `due_pipelines`.
   - A private child under a project parent gives `Invalid("reference runs_parent_space")`; a private run using a project grant gives `Invalid("reference runs_grant_space")`.
   - `active_grant_for_instance` and `run_grants(instance)` ignore the project grant.

**Gateway (`crates/gateway/tests/api.rs`)**
8. **New `team_adoption_rolls_back_when_a_member_fails`** (commit C4, before the switch):
   - `POST /v1/team-templates` with `[{claude, 主编, lead}, {claude, harness: "no-such-harness", 写手}]` returns 201, because harnesses are only checked at adoption (`teams.rs:153-158`);
   - adopt returns 422;
   - raw counts on `a.t.db.pool()` are 0 for `instances`, `run_grants`, `events` and `audit_log WHERE action = 'instance.adopt'`;
   - after the switch (C5), also 0 for `projects`, `project_members` and `project_agents`;
   - `GET /v1/teams` returns `[]`.
9. **New `old_team_api_is_backed_by_projects`** (commit C6):
   - `POST /v1/teams`: response keys are exactly `{id,name,members,created_at}` and member keys `{instance_id,role,position}`;
   - raw: a `projects` row with that id, one creator row, two live `project_agents`, and `teams` count 0;
   - PATCH removing a member then re-adding it leaves one row;
   - after `DELETE /v1/instances/{lead}`, GET shows 1 member and a PATCH naming a new lead returns 200;
   - raw `UPDATE projects SET shared_at = now()`: PATCH and DELETE return 409, GET returns 200;
   - reset `shared_at`; DELETE returns 204, project rows are gone and instances remain.
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
| C1 | store testing: migrate as a production-like owner; 0001/0014 check roles before creating | `migrations/0001_init.sql:8,16-18`, `0014_device_relay.sql:15`, `store/src/testing.rs`, `store/src/schema.rs:16` (`pub(crate)`), new test #1, `docs/deploy-checklist.md:58-60`, `docs/release.md:74` | ~150 |
| C2 | proto: ProjectId, ProjectStatus, ProjectRole | `proto/src/domain.rs` | ~40 |
| C3 | migration 0039: projects, members, agents, invites, keys, templates; copy teams | `migrations/0039_projects.sql`, test #2 (needs `TestDb::up_to` from C1). Old code still writes `teams`, which is fine at this step. | ~230 SQL + ~150 test |
| C4 | gateway test: adoption rolls back midway | test #8 without the project counts (passes on the old implementation: the gate before the read switch) | ~70 |
| C5 | store: project functions; teams, delegation, instance delete and erase switched to projects | new `store/src/projects.rs`, `teams.rs`, `instances.rs` (563-590, 384-411), `users.rs` (211-212), `lib.rs`; tests #3, #4, #5, #6; project counts added to #8 | ~300 code + ~300 tests |
| C6 | gateway test: the old team API reads and writes project rows | test #9 | ~150 |
| C7 | runs and grants: typed space, claim guard, private grant lookups exclude project grants | `0040_run_spaces.sql`, `0041`–`0043` (no-transaction), `0044_run_space_keys.sql`, `runs.rs` (880, 997, 1295, 1428), `grants.rs` (136-147, 303-315), test #7 | ~140 SQL + ~20 code + ~150 tests |
| C8 | docs | progress file (done/next/pitfalls); `docs/projects.md` status line; projects-impl "8.13" notes (numbering, `space_*` naming, `shared_at`, frozen old tables) | ~80 |

C7 is independent of C3–C6 and can be split into its own PR if review wants to weigh the `runs` DDL separately.

## 8. Sequencing note for 8.14–8.19: what 8.13 leaves in place, and what each later package must do

**Left in place by 8.13**
- `projects`, `project_members`, `project_agents`, `project_invites`, `project_keys` and `project_templates`, all with FORCE RLS.
  - Tenant policies cover creator-only, unshared writes.
  - Worker has full DML. `thinktin_member`, `thinktin_definer` and `thinktin_llmgw` have no grants.
- `projects.shared_at` and its trigger (D3).
- `TeamId == ProjectId`.
- `TestDb` migrates as a non-superuser owner, and roles are created under an advisory lock.
- `runs` and `run_grants` have `project_id`, `space_kind` and `space_id`, the space foreign keys, `fill_space()` (no tenant-written project rows, immutable space) and the claim guard.
- Private grant lookups exclude project grants.
- The old team tables are frozen.

| WP | Must do on top of 8.13 |
|---|---|
| **8.14** invites and join | Worker-only invite, accept and decline flows on `project_invites`: `UPDATE … WHERE status='pending' AND expires_at > now()` in one transaction, token hash only, repeated accept returns the existing result. Joining inserts `role='member'` with `consented_at`, so `shared_at` is set automatically. A `pg_advisory_xact_lock(hashtextextended('project/'||id,0))` per-project lock around the 10-user / 30-agent caps. A blocks table and rate limits. Withdraw, leave and remove go through the worker (cancel project work, bump `instances.token_epoch`). `delete_instance` must also retire the instance from *shared* projects via the worker, because the tenant policy only covers unshared ones. `/v1/projects*` and `/v1/project-templates*` (same table) plus Project FFI types, with Android binding regeneration. Decide whether old `/v1/teams` writes on shared projects stay 409. |
| **8.15** cross-user boundary | Create `thinktin_member` and `thinktin_definer` with the C1 idiom (`IF NOT EXISTS` before `CREATE ROLE`). Deploy-checklist pre-creation plus `GRANT thinktin_definer TO thinktin_owner WITH INHERIT FALSE, SET TRUE`. `TestDb` also creates them and grants SET to `thinktin_test_owner`. Definer membership functions with `search_path = pg_catalog, public, pg_temp`. Member read policies with column grants; grant on `events` parent only. `ProjectTx` as its own type. Map 42501 to 404 on project paths. Narrow the tenant policies on `runs`/`run_grants` for `project_id IS NOT NULL` rows. Project key creation; `project_artifacts` and project board tables; private artifacts restricted to private runs. Soft-delete projects (`status='deleted'`, then batched cleanup; the `runs_project_agent` NO ACTION key forces runs to be cleared first) and switch `delete_solo_project` and erase to that flow. Extend RLS test #5 to `thinktin_member`. |
| **8.16** sessions and workspaces | `project_agents.dedicated` (tenant cannot write it) plus the unique dedicated index. Add the "no private run on a dedicated instance" check to `fill_space()` via `CREATE OR REPLACE`. Replace the claim guard `project_id IS NULL` with "or this build can isolate scopes". Add `project_id` to `RunRecord` and `columns!()`. Add a per-(instance, project) archive table keyed on `project_agents (project_id, instance_id)`. |
| **8.17** project collaboration | Drop `runs_parent_run_id_user_id_fkey` and `run_grants_parent_id_user_id_fkey` (`deploy-safe`) to allow cross-owner trees, and re-create `runs_parent_space` with the chosen delete action. Add `NewRun.project_id` for roots and copy the parent's `project_id` in `insert_run` (`runs.rs:269-280`) and `create_child_grant` (`grants.rs:246-275`). Space-aware `is_lead(instance, space)` and project delegation targets (`executor.rs:770-776`, `delegate.rs:44-49`). Global `run_waits` lock. `plans`/`plan_steps` project columns. Project board and tools. |
| **8.18** costs, approvals, permissions | Enforce `project_members.daily_token_limit`/`total_token_limit` in llm-gw (llmgw column grants). `usage_records.project_id`. Approvals space columns, keeping `(run_id,user_id)` plus a space-consistency key. `allow_computer`; `project_agent_vault_items`; preauthorised-tool intersection. |
| **8.19** notifications and events | Project feed (`project_seq`, transactional outbox and sequencer, per impl item 6). Change the inbox `(run_id,user_id)` FK for cross-owner notices. Event space consistency. |
| **After 12.25 / 13.18** | Drop `teams`, `team_members` and `team_templates` (`deploy-safe`) and their erase statements. |

## 待定问题

- D8: may we edit the already-applied migrations 0001_init.sql:16-18 and 0014_device_relay.sql:15 to check for the role before CREATE ROLE? This changes their sqlx checksums: any persistent local or Tokyo database migrated before must be recreated. It is acceptable only because no v* tag exists and the progress file says the server machine has not been bought.
- D4: is it acceptable that there is no dual-write? After 0039 the old teams, team_members and team_templates tables are frozen copies, so a rollback below 0039, or an old replica during a rolling deploy, will not see team changes made after the migration.
- D3: after 8.14, should old /v1/teams PATCH and DELETE on a project that has other members return 409 (proposed, enforced by projects.shared_at in the tenant policies)? The alternative is design A's 'edit only my own agents, and 409 only on delete'.
- D6: should the runs/run_grants typed-space columns, the claim guard and the CONCURRENTLY index files (0040-0044) ship in 8.13 (recommended: the claim guard must exist in every worker before any project run is written), or move to 8.15? Is the column naming space_kind/space_id acceptable? It was chosen to avoid run_grants.scope jsonb and store::ArtifactScope.
- Invites schema: store invitee_phone as plaintext E.164 (consistent with login_codes) or as a keyed hash? Link invites are single-use per projects-impl.md, which overrides projects.md's 'times limit'. 16.6 or 8.14 may revise this before any rows exist.
- D9: confirm that no read-only /v1/projects routes and no Project FFI types ship in 8.13, so their response shape is designed once in 8.14/8.15, together with the ProjectTx member semantics.