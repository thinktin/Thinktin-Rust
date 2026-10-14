-- ThinkTin 平台数据模型（WBS 3.4）。依据《架构方案 v3》第 4、5 节。
--
-- 角色：
--   thinktin_app     业务接口用，受行级安全（RLS）约束，只能看到 app.user_id 对应用户的数据；
--   thinktin_worker  后台任务（调度、租约、出箱投递、登录流程）用，绕过 RLS，代码里显式选用；
--   thinktin_llmgw   模型网关用，只读路由数据、写用量。
-- 应用每个事务开头切换到对应角色（set_config('role', ..., true)，等同 SET LOCAL ROLE），租户事务再设置 app.user_id。
-- 角色是整个集群共享的；并发建库（测试）时两个迁移可能同时建角色，所以也忽略唯一键冲突。
-- 部署时给各服务的登录账号授予对应角色的成员身份（GRANT thinktin_app TO app_login），开发环境用超级用户直接 SET ROLE。
--
-- 主键都是应用生成的 UUIDv7；时间都是 timestamptz（UTC）。
--
-- 跨表引用一律用 (id, user_id) 复合外键：外键检查不受 RLS 约束，单列外键会让一个用户
-- 引用别人的 key、实例或计划（只要知道 id）；复合外键在库里保证两边属于同一个用户。

DO $$ BEGIN CREATE ROLE thinktin_app NOLOGIN NOBYPASSRLS; EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE thinktin_worker NOLOGIN BYPASSRLS; EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE thinktin_llmgw NOLOGIN BYPASSRLS; EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $$;

-- 当前租户；没设置时为 NULL，策略因此不匹配任何行。
CREATE FUNCTION app_user_id() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$ SELECT nullif(current_setting('app.user_id', true), '')::uuid $$;

-- ---------- 账号与会话（4.1、4.2） ----------

CREATE TABLE users (
    id           uuid PRIMARY KEY,
    phone        text NOT NULL,             -- E.164
    display_name text,
    status       text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'frozen', 'deleted')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    frozen_at    timestamptz,
    deleted_at   timestamptz
);
-- 注销后手机号可以重新注册。
CREATE UNIQUE INDEX users_phone_live ON users (phone) WHERE status <> 'deleted';

-- 登录验证码只存 HMAC 哈希。登录前没有租户，只有 worker 角色能读写。
CREATE TABLE login_codes (
    id          uuid PRIMARY KEY,
    phone       text NOT NULL,
    purpose     text NOT NULL CHECK (purpose IN ('login', 'delete_account', 'change_phone')),
    code_hash   bytea NOT NULL,
    attempts    integer NOT NULL DEFAULT 0,
    expires_at  timestamptz NOT NULL,
    consumed_at timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX login_codes_phone ON login_codes (phone, purpose, created_at DESC);

CREATE TABLE devices (
    id           uuid PRIMARY KEY,
    user_id      uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    platform     text NOT NULL CHECK (platform IN ('ios', 'android', 'macos')),
    name         text NOT NULL DEFAULT '',
    push_channel text CHECK (push_channel IN ('apns', 'fcm', 'hms', 'honor', 'mi', 'oppo', 'vivo', 'unipush')),
    push_token   text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    revoked_at   timestamptz,
    UNIQUE (id, user_id)
);
CREATE INDEX devices_user ON devices (user_id) WHERE revoked_at IS NULL;

-- 设备会话：访问令牌 15 分钟，刷新令牌按设备保存、每次刷新轮换。
-- prev_refresh_hash 用来识别“旧令牌被重复使用”（令牌被盗的信号），grace 期内的并发刷新不算。
CREATE TABLE sessions (
    id                uuid PRIMARY KEY,
    user_id           uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    device_id         uuid NOT NULL,
    refresh_hash      bytea NOT NULL,
    prev_refresh_hash bytea,
    rotated_at        timestamptz NOT NULL DEFAULT now(),
    created_at        timestamptz NOT NULL DEFAULT now(),
    expires_at        timestamptz NOT NULL,
    revoked_at        timestamptz,
    revoke_reason     text,
    FOREIGN KEY (device_id, user_id) REFERENCES devices (id, user_id) ON DELETE CASCADE
);
CREATE INDEX sessions_user ON sessions (user_id) WHERE revoked_at IS NULL;
CREATE INDEX sessions_device ON sessions (device_id) WHERE revoked_at IS NULL;

-- ---------- 密钥库与模型 key（5.4、9.1、9.8） ----------

-- 包裹后的用户 DEK。只有 worker 和模型网关能读；删除这一行即“注销即销毁”。
CREATE TABLE user_keys (
    user_id     uuid PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
    kms_key_id  text NOT NULL,
    wrapped_dek bytea NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE credentials (
    id                uuid PRIMARY KEY,
    user_id           uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    vendor            text NOT NULL,          -- 厂商表的 id（含区域），或 custom
    label             text NOT NULL DEFAULT '',
    anthropic_base    text,                   -- 只对 custom 生效
    openai_base       text,
    responses_base    text,
    sealed            bytea NOT NULL,         -- 随机数 + AES-256-GCM 密文
    last4             text NOT NULL,
    daily_token_limit bigint CHECK (daily_token_limit > 0),
    disabled          boolean NOT NULL DEFAULT false,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    deleted_at        timestamptz,
    UNIQUE (id, user_id)
);
CREATE INDEX credentials_user ON credentials (user_id) WHERE deleted_at IS NULL;

-- ---------- 实例（6.4） ----------

CREATE TABLE instances (
    id               uuid PRIMARY KEY,
    user_id          uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    agent_id         text NOT NULL,           -- 目录里的 agent id，比如 claude
    agent_version    text NOT NULL,           -- 锁定的模板版本
    harness          text NOT NULL,
    name             text NOT NULL,
    state            text NOT NULL DEFAULT 'provisioning'
                     CHECK (state IN ('provisioning', 'running', 'paused', 'archived', 'deleted')),
    sandbox_id       text,                    -- 当前沙箱；沙箱令牌按它核对
    sandbox_address  inet,                    -- 模型网关看到的来源地址
    workspace_id     text NOT NULL,           -- 工作区卷
    snapshot_id      text,                    -- 最近的快照
    limits           jsonb NOT NULL DEFAULT '{}'::jsonb,
    event_seq        bigint NOT NULL DEFAULT 0,  -- 这个实例事件流的最新序号（4.8）
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    last_active_at   timestamptz NOT NULL DEFAULT now(),
    deleted_at       timestamptz,
    UNIQUE (id, user_id)
);
CREATE INDEX instances_user ON instances (user_id) WHERE state <> 'deleted';
-- 空闲暂停、归档扫描。
CREATE INDEX instances_idle ON instances (state, last_active_at) WHERE state IN ('running', 'paused');

-- 实例的模型别名：别名 → 凭证 + 上游模型（5.5）。
CREATE TABLE model_routes (
    instance_id    uuid NOT NULL,
    alias          text NOT NULL CHECK (alias ~ '^[a-z0-9][a-z0-9._-]{0,63}$'),
    user_id        uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    credential_id  uuid NOT NULL,
    upstream_model text NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (instance_id, alias),
    FOREIGN KEY (instance_id, user_id) REFERENCES instances (id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (credential_id, user_id) REFERENCES credentials (id, user_id)
);
CREATE INDEX model_routes_credential ON model_routes (credential_id);

-- ---------- 运行授权（4.3、4.6） ----------

CREATE TABLE run_grants (
    id            uuid PRIMARY KEY,
    user_id       uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    instance_id   uuid NOT NULL,
    plan_id       uuid,                       -- 为某个计划签发时填
    parent_id     uuid,                       -- 子运行收窄出的授权
    scope         jsonb NOT NULL,             -- 别名、工具、预算上限
    created_at    timestamptz NOT NULL DEFAULT now(),
    expires_at    timestamptz NOT NULL,       -- 默认 90 天，有活动自动续期
    last_used_at  timestamptz,
    revoked_at    timestamptz,
    revoke_reason text,
    UNIQUE (id, user_id),
    FOREIGN KEY (instance_id, user_id) REFERENCES instances (id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (parent_id, user_id) REFERENCES run_grants (id, user_id) ON DELETE CASCADE
);
CREATE INDEX run_grants_instance ON run_grants (instance_id) WHERE revoked_at IS NULL;

-- ---------- 计划与触发器（7.1） ----------

CREATE TABLE plans (
    id           uuid PRIMARY KEY,
    user_id      uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    instance_id  uuid NOT NULL,
    title        text NOT NULL,
    goal         text NOT NULL,               -- 交给 agent 的目标描述
    policy       jsonb NOT NULL DEFAULT '{}'::jsonb,  -- 预授权范围、审批超时策略、预算
    catch_up     text NOT NULL DEFAULT 'once' CHECK (catch_up IN ('once', 'all', 'skip')),
    status       text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused', 'deleted')),
    run_grant_id uuid,
    created_by   text NOT NULL DEFAULT 'user' CHECK (created_by IN ('user', 'agent')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, user_id),
    FOREIGN KEY (instance_id, user_id) REFERENCES instances (id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (run_grant_id, user_id) REFERENCES run_grants (id, user_id) ON DELETE SET NULL (run_grant_id)
);
CREATE INDEX plans_user ON plans (user_id) WHERE status <> 'deleted';
CREATE INDEX plans_instance ON plans (instance_id) WHERE status <> 'deleted';

CREATE TABLE triggers (
    id           uuid PRIMARY KEY,
    user_id      uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    plan_id      uuid NOT NULL,
    spec         jsonb NOT NULL,              -- ScheduleSpec：cron / rrule / once，或事件触发
    enabled      boolean NOT NULL DEFAULT true,
    next_fire_at timestamptz,                 -- 名义时间；NULL 表示不会再触发
    last_fire_at timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, user_id),
    FOREIGN KEY (plan_id, user_id) REFERENCES plans (id, user_id) ON DELETE CASCADE
);
-- 调度循环按它扫描到点的触发器。
CREATE INDEX triggers_due ON triggers (next_fire_at) WHERE enabled AND next_fire_at IS NOT NULL;
CREATE INDEX triggers_plan ON triggers (plan_id);

-- ---------- 运行（7.3、7.4、8.2） ----------

CREATE TABLE runs (
    id               uuid PRIMARY KEY,
    user_id          uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    instance_id      uuid NOT NULL,
    plan_id          uuid,
    trigger_id       uuid,
    fire_time        timestamptz,             -- 计划运行的名义触发时间
    parent_run_id    uuid,
    root_run_id      uuid NOT NULL,           -- 运行树的根（没有父运行时等于自己）
    source           text NOT NULL CHECK (source IN ('user', 'plan', 'pipeline', 'delegate')),
    prompt           text NOT NULL,
    state            text NOT NULL DEFAULT 'queued' CHECK (state IN (
                         'queued', 'starting', 'running', 'waiting_approval', 'waiting_device',
                         'waiting_quota', 'waiting_children', 'backoff', 'succeeded', 'failed', 'cancelled')),
    state_reason     text,
    attempt          integer NOT NULL DEFAULT 0,
    max_attempts     integer NOT NULL DEFAULT 3,
    not_before       timestamptz NOT NULL DEFAULT now(),   -- 抖动、退避后才能领取
    lease_owner      text,
    lease_expires_at timestamptz,
    agent_version    text NOT NULL,           -- 启动时锁定的模板版本
    run_grant_id     uuid,
    budget           jsonb NOT NULL DEFAULT '{}'::jsonb,   -- token、时长、步数上限
    tokens_used      bigint NOT NULL DEFAULT 0,
    steps            integer NOT NULL DEFAULT 0,
    summary          text,
    error            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    started_at       timestamptz,
    finished_at      timestamptz,
    UNIQUE (id, user_id),
    FOREIGN KEY (instance_id, user_id) REFERENCES instances (id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (plan_id, user_id) REFERENCES plans (id, user_id) ON DELETE SET NULL (plan_id),
    FOREIGN KEY (trigger_id, user_id) REFERENCES triggers (id, user_id) ON DELETE SET NULL (trigger_id),
    FOREIGN KEY (parent_run_id, user_id) REFERENCES runs (id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (run_grant_id, user_id) REFERENCES run_grants (id, user_id) ON DELETE SET NULL (run_grant_id)
);
-- 多副本同时扫描触发器也只生成一次运行（4.4）。
CREATE UNIQUE INDEX runs_plan_fire ON runs (plan_id, fire_time) WHERE plan_id IS NOT NULL AND fire_time IS NOT NULL;
-- 领取排队的运行和退避到期的运行。
CREATE INDEX runs_claim ON runs (not_before) WHERE state IN ('queued', 'backoff');
-- 接管过期租约。
CREATE INDEX runs_lease ON runs (lease_expires_at) WHERE lease_owner IS NOT NULL;
CREATE INDEX runs_instance ON runs (instance_id, created_at DESC);
CREATE INDEX runs_user ON runs (user_id, created_at DESC);
CREATE INDEX runs_tree ON runs (root_run_id);
-- 同一实例同时只执行一个运行（4.3）：等待中、退避中的运行仍然占着实例（agent 的会话停在这一轮中间）。
CREATE UNIQUE INDEX runs_one_active_per_instance ON runs (instance_id)
    WHERE state IN ('starting', 'running', 'waiting_approval', 'waiting_device', 'waiting_quota',
                    'waiting_children', 'backoff');

-- ---------- 事件流（4.8、7.9）：按实例的单调序号，按月分区，保留 30 天 ----------

CREATE TABLE events (
    instance_id uuid NOT NULL,
    seq         bigint NOT NULL,
    user_id     uuid NOT NULL,
    run_id      uuid,
    kind        text NOT NULL,
    payload     jsonb NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (instance_id, seq, created_at),
    FOREIGN KEY (instance_id, user_id) REFERENCES instances (id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (run_id, user_id) REFERENCES runs (id, user_id) ON DELETE CASCADE
) PARTITION BY RANGE (created_at);
CREATE INDEX events_run ON events (run_id, seq) WHERE run_id IS NOT NULL;

-- 建好从某月起连续几个月的分区；维护任务每天调用一次。以迁移账号的身份执行（worker 没有建表权限）。
CREATE FUNCTION ensure_event_partitions(start_month date, months integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    m date := date_trunc('month', start_month)::date;
    name text;
BEGIN
    FOR i IN 0..months - 1 LOOP
        name := format('events_%s', to_char(m, 'YYYYMM'));
        EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF events FOR VALUES FROM (%L) TO (%L)',
                       name, m, (m + interval '1 month')::date);
        m := (m + interval '1 month')::date;
    END LOOP;
END $$;
SELECT ensure_event_partitions((now() - interval '1 month')::date, 4);

-- 保留期：删掉整月都早于 before 的分区，返回删掉的个数。
CREATE FUNCTION drop_event_partitions_before(before date) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    part text;
    dropped integer := 0;
BEGIN
    FOR part IN
        SELECT c.relname FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = 'events'::regclass AND c.relname ~ '^events_[0-9]{6}$'
    LOOP
        IF (to_date(substr(part, 8), 'YYYYMM') + interval '1 month')::date <= before THEN
            EXECUTE format('DROP TABLE %I', part);
            dropped := dropped + 1;
        END IF;
    END LOOP;
    RETURN dropped;
END $$;

-- ---------- 审批（4.7、7.10） ----------

CREATE TABLE approvals (
    id             uuid PRIMARY KEY,
    user_id        uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    instance_id    uuid NOT NULL,
    run_id         uuid NOT NULL,
    request_id     text NOT NULL,             -- shim 的权限请求 id
    title          text,
    options        jsonb NOT NULL,
    tool_call      jsonb NOT NULL DEFAULT '{}'::jsonb,
    state          text NOT NULL DEFAULT 'pending'
                   CHECK (state IN ('pending', 'approved', 'rejected', 'expired', 'cancelled')),
    decided_option text,
    decided_by     text,                      -- 设备 id，或 policy / timeout
    signature      bytea,                     -- 高危操作的设备签名（P2）
    expires_at     timestamptz NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    decided_at     timestamptz,
    UNIQUE (run_id, request_id),
    FOREIGN KEY (instance_id, user_id) REFERENCES instances (id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (run_id, user_id) REFERENCES runs (id, user_id) ON DELETE CASCADE
);
CREATE INDEX approvals_pending ON approvals (user_id, created_at) WHERE state = 'pending';
CREATE INDEX approvals_expiry ON approvals (expires_at) WHERE state = 'pending';

-- ---------- 出箱与收件箱（7.5、10.4） ----------

-- 状态变更和要发的通知在同一个事务里写入，投递器异步发送。
CREATE TABLE outbox (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id      uuid NOT NULL,
    kind         text NOT NULL,               -- push / im / internal
    payload      jsonb NOT NULL,
    dedupe_key   text,
    available_at timestamptz NOT NULL DEFAULT now(),
    attempts     integer NOT NULL DEFAULT 0,
    locked_by    text,
    locked_until timestamptz,
    last_error   text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    delivered_at timestamptz
);
-- 去重键按用户划分：业务角色入箱时的冲突检查只会碰到自己的键。
CREATE UNIQUE INDEX outbox_dedupe ON outbox (user_id, dedupe_key) WHERE dedupe_key IS NOT NULL;
CREATE INDEX outbox_ready ON outbox (available_at) WHERE delivered_at IS NULL;

CREATE TABLE inbox_items (
    id          uuid PRIMARY KEY,
    user_id     uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    instance_id uuid,
    run_id      uuid,
    kind        text NOT NULL,                -- run_finished / run_failed / approval / info
    title       text NOT NULL,
    body        text NOT NULL DEFAULT '',
    read_at     timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (instance_id, user_id) REFERENCES instances (id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (run_id, user_id) REFERENCES runs (id, user_id) ON DELETE SET NULL (run_id)
);
CREATE INDEX inbox_user ON inbox_items (user_id, created_at DESC);
CREATE INDEX inbox_unread ON inbox_items (user_id) WHERE read_at IS NULL;

-- ---------- 用量与审计（5.7、9.4、5.6） ----------

CREATE TABLE usage_records (
    id                 uuid PRIMARY KEY,
    user_id            uuid NOT NULL,
    instance_id        uuid NOT NULL,
    run_grant_id       uuid,
    credential_id      uuid,
    alias              text NOT NULL,
    vendor             text NOT NULL,
    upstream_model     text NOT NULL,
    endpoint           text NOT NULL,
    stream             boolean NOT NULL,
    status             integer NOT NULL,
    outcome            text NOT NULL,
    input_tokens       bigint NOT NULL DEFAULT 0,
    cache_read_tokens  bigint NOT NULL DEFAULT 0,
    cache_write_tokens bigint NOT NULL DEFAULT 0,
    output_tokens      bigint NOT NULL DEFAULT 0,
    charged_tokens     bigint NOT NULL DEFAULT 0,
    estimated          boolean NOT NULL DEFAULT false,
    duration_ms        bigint NOT NULL DEFAULT 0,
    created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX usage_user_time ON usage_records (user_id, created_at DESC);
CREATE INDEX usage_instance_time ON usage_records (instance_id, created_at DESC);
CREATE INDEX usage_credential_time ON usage_records (credential_id, created_at DESC);

-- 只追加：key 的增删改、登录、会话吊销、授权变化等安全事件（不记对话内容）。
CREATE TABLE audit_log (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id    uuid,
    actor      text NOT NULL,                 -- user:<设备 id> / system / agent:<实例 id>
    action     text NOT NULL,
    target     text,
    detail     jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_user ON audit_log (user_id, created_at DESC);

-- ---------- 行级安全 ----------

-- 租户表：thinktin_app 只能看到、写入自己的行。FORCE 让表的属主也受约束（防止迁移账号误用）。
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['devices', 'sessions', 'credentials', 'instances', 'model_routes', 'run_grants',
                             'plans', 'triggers', 'runs', 'events', 'approvals', 'inbox_items', 'usage_records']
    LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('CREATE POLICY tenant ON %I TO thinktin_app USING (user_id = app_user_id()) WITH CHECK (user_id = app_user_id())', t);
    END LOOP;
END $$;

ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE users FORCE ROW LEVEL SECURITY;
CREATE POLICY self ON users TO thinktin_app USING (id = app_user_id()) WITH CHECK (id = app_user_id());

-- 审计日志：业务接口只能追加自己的记录，不能读改删。
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log FORCE ROW LEVEL SECURITY;
CREATE POLICY append_own ON audit_log FOR INSERT TO thinktin_app WITH CHECK (user_id = app_user_id());

-- 没有为 thinktin_app 建策略的表（login_codes、user_keys）开启 RLS 后它一行也看不到；
-- 再加上不授予权限，双保险。出箱只允许业务接口追加自己的记录。
ALTER TABLE login_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE login_codes FORCE ROW LEVEL SECURITY;
ALTER TABLE user_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_keys FORCE ROW LEVEL SECURITY;
ALTER TABLE outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE outbox FORCE ROW LEVEL SECURITY;
CREATE POLICY append_own ON outbox FOR INSERT TO thinktin_app WITH CHECK (user_id = app_user_id());
-- 入箱用 ON CONFLICT 去重，需要对新行有读权限：只放开自己的行，且列权限只给 user_id、dedupe_key。
CREATE POLICY read_own_keys ON outbox FOR SELECT TO thinktin_app USING (user_id = app_user_id());

-- ---------- 权限 ----------

GRANT USAGE ON SCHEMA public TO thinktin_app, thinktin_worker, thinktin_llmgw;
GRANT EXECUTE ON FUNCTION app_user_id() TO thinktin_app, thinktin_worker, thinktin_llmgw;

GRANT SELECT, INSERT, UPDATE ON users, devices, sessions, instances, plans, triggers, runs, approvals, inbox_items
    TO thinktin_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON credentials, model_routes, run_grants TO thinktin_app;
GRANT DELETE ON inbox_items, triggers TO thinktin_app;
GRANT SELECT, INSERT ON events TO thinktin_app;
GRANT SELECT ON usage_records TO thinktin_app;
GRANT INSERT ON audit_log TO thinktin_app;
GRANT INSERT ON outbox TO thinktin_app;  -- 和状态变更同事务写入；RLS 下 thinktin_app 读不到出箱
GRANT SELECT (user_id, dedupe_key) ON outbox TO thinktin_app;  -- ON CONFLICT 推断去重索引要用（行仍然读不到）

-- worker：后台任务需要的全部读写（绕过 RLS）。
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO thinktin_worker;
REVOKE EXECUTE ON FUNCTION ensure_event_partitions(date, integer), drop_event_partitions_before(date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ensure_event_partitions(date, integer), drop_event_partitions_before(date)
    TO thinktin_worker;

-- 模型网关：只读路由数据，写用量。
GRANT SELECT ON users, instances, model_routes, credentials, run_grants, user_keys TO thinktin_llmgw;
GRANT INSERT ON usage_records TO thinktin_llmgw;
