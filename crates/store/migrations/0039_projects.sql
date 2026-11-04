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
