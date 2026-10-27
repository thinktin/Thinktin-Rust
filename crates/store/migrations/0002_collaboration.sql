-- 多 agent 协同（WBS 8.1–8.5）：团队、流水线步骤、运行种类、产出物。依据《架构方案 v3》4.11。

-- ---------- 团队（8.1） ----------

CREATE TABLE teams (
    id         uuid PRIMARY KEY,
    user_id    uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, user_id)
);
CREATE INDEX teams_user ON teams (user_id);

-- 团队只能由同一用户的实例组成（复合外键保证）。
CREATE TABLE team_members (
    team_id     uuid NOT NULL,
    instance_id uuid NOT NULL,
    user_id     uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    role        text NOT NULL DEFAULT 'member' CHECK (role IN ('lead', 'member')),
    position    integer NOT NULL DEFAULT 0,
    PRIMARY KEY (team_id, instance_id),
    FOREIGN KEY (team_id, user_id) REFERENCES teams (id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (instance_id, user_id) REFERENCES instances (id, user_id) ON DELETE CASCADE
);
-- 一个团队最多一个负责人（委派时由它分工，8.7）。
CREATE UNIQUE INDEX team_one_lead ON team_members (team_id) WHERE role = 'lead';

-- 团队模板：成员的 agent、接入方式、角色，用来一键领养一整个团队。
CREATE TABLE team_templates (
    id         uuid PRIMARY KEY,
    user_id    uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name       text NOT NULL,
    spec       jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, user_id)
);

-- ---------- 运行种类与流水线（8.2、8.3） ----------

-- agent：在某个实例的沙箱里执行一轮；pipeline：流水线的根，只协调子运行，不占实例、不执行 agent。
ALTER TABLE runs ADD COLUMN kind text NOT NULL DEFAULT 'agent' CHECK (kind IN ('agent', 'pipeline'));
-- 流水线子运行对应的步骤。
ALTER TABLE runs ADD COLUMN step_key text;
CREATE UNIQUE INDEX runs_step ON runs (parent_run_id, step_key) WHERE step_key IS NOT NULL;

-- 只有 agent 运行占实例、由执行器领取。
DROP INDEX runs_one_active_per_instance;
CREATE UNIQUE INDEX runs_one_active_per_instance ON runs (instance_id)
    WHERE kind = 'agent' AND state IN ('starting', 'running', 'waiting_approval', 'waiting_device',
                                       'waiting_quota', 'waiting_children', 'backoff');
DROP INDEX runs_claim;
CREATE INDEX runs_claim ON runs (not_before) WHERE kind = 'agent' AND state IN ('queued', 'backoff');
CREATE INDEX runs_pipeline ON runs (not_before) WHERE kind = 'pipeline' AND state IN ('queued', 'waiting_children');

-- 计划的步骤：有步骤的计划到点生成一个流水线运行，按依赖顺序给每一步生成子运行。
CREATE TABLE plan_steps (
    plan_id     uuid NOT NULL,
    key         text NOT NULL CHECK (key ~ '^[a-z0-9][a-z0-9_-]{0,31}$'),
    user_id     uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    instance_id uuid NOT NULL,
    prompt      text NOT NULL,
    depends_on  text[] NOT NULL DEFAULT '{}',
    position    integer NOT NULL DEFAULT 0,
    PRIMARY KEY (plan_id, key),
    FOREIGN KEY (plan_id, user_id) REFERENCES plans (id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (instance_id, user_id) REFERENCES instances (id, user_id) ON DELETE CASCADE
);

-- ---------- 产出物（8.4） ----------

-- 内容在对象存储里（按用户 DEK 加密）；这里是索引。名字在一棵运行树里唯一，同名再发布是新版本。
CREATE TABLE artifacts (
    id           uuid PRIMARY KEY,
    user_id      uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    instance_id  uuid NOT NULL,
    run_id       uuid NOT NULL,
    root_run_id  uuid NOT NULL,
    name         text NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
    version      integer NOT NULL CHECK (version > 0),
    content_type text NOT NULL DEFAULT 'application/octet-stream',
    size         bigint NOT NULL CHECK (size >= 0),
    sha256       bytea NOT NULL,
    blob_key     text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (root_run_id, name, version),
    FOREIGN KEY (instance_id, user_id) REFERENCES instances (id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (run_id, user_id) REFERENCES runs (id, user_id) ON DELETE CASCADE
);
CREATE INDEX artifacts_tree ON artifacts (root_run_id, name, version DESC);
CREATE INDEX artifacts_instance ON artifacts (instance_id, created_at DESC);

-- ---------- 行级安全与权限 ----------

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['teams', 'team_members', 'team_templates', 'plan_steps', 'artifacts']
    LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('CREATE POLICY tenant ON %I TO thinktin_app USING (user_id = app_user_id()) WITH CHECK (user_id = app_user_id())', t);
    END LOOP;
END $$;

GRANT SELECT, INSERT, UPDATE, DELETE ON teams, team_members, team_templates, plan_steps TO thinktin_app;
-- 产出物由平台工具（后台）写入；用户可以查看、删除。
GRANT SELECT, DELETE ON artifacts TO thinktin_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON teams, team_members, team_templates, plan_steps, artifacts TO thinktin_worker;
