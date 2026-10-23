-- 密码保险箱（WBS 9.11）：账号和密码按用户 DEK 加密（库里只有密文），接口从不返回密码；
-- agent 只知道名字，用的时候由沙箱里的助手按名字注入命令。

CREATE TABLE vault_items (
    id           uuid PRIMARY KEY,
    user_id      uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name         text NOT NULL CHECK (name ~ '^[a-z0-9][a-z0-9_-]{0,63}$'),
    purpose      text NOT NULL DEFAULT '' CHECK (length(purpose) <= 200),
    -- 账号和密码一起加密（附加认证数据带用户 id 和条目 id，挪到别的行解不开）。
    sealed       bytea NOT NULL,
    has_username boolean NOT NULL DEFAULT false,
    -- 能用它的实例；空数组表示全部实例。
    instance_ids uuid[] NOT NULL DEFAULT '{}',
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz,
    UNIQUE (user_id, name),
    UNIQUE (id, user_id)
);

-- agent 请用户填账号密码（App 弹表单）。用户填的值只进保险箱，这里只有名字和用途。
CREATE TABLE vault_requests (
    id          uuid PRIMARY KEY,
    user_id     uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    instance_id uuid NOT NULL,
    run_id      uuid,
    name        text NOT NULL CHECK (name ~ '^[a-z0-9][a-z0-9_-]{0,63}$'),
    purpose     text NOT NULL DEFAULT '' CHECK (length(purpose) <= 200),
    fields      text[] NOT NULL DEFAULT '{password}'
                CHECK (cardinality(fields) > 0 AND fields <@ ARRAY['username', 'password']::text[]),
    -- 过了期限还没处理的读出来是 expired；同名的新请求进来时才真正改成 expired。
    status      text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'fulfilled', 'declined', 'expired')),
    item_id     uuid,
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    resolved_at timestamptz,
    FOREIGN KEY (instance_id, user_id) REFERENCES instances (id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (run_id, user_id) REFERENCES runs (id, user_id) ON DELETE SET NULL (run_id),
    FOREIGN KEY (item_id, user_id) REFERENCES vault_items (id, user_id) ON DELETE SET NULL (item_id)
);
CREATE INDEX vault_requests_user ON vault_requests (user_id, created_at DESC);
-- 同一个名字同时只有一个待处理的请求（agent 重复请求时复用）。
CREATE UNIQUE INDEX vault_requests_pending_name ON vault_requests (user_id, name) WHERE status = 'pending';

-- ---------- 行级安全与权限 ----------

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['vault_items', 'vault_requests']
    LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('CREATE POLICY tenant ON %I TO thinktin_app USING (user_id = app_user_id()) WITH CHECK (user_id = app_user_id())', t);
    END LOOP;
END $$;

GRANT SELECT, INSERT, UPDATE, DELETE ON vault_items TO thinktin_app;
GRANT SELECT, INSERT, UPDATE ON vault_requests TO thinktin_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON vault_items, vault_requests TO thinktin_worker;
-- 模型网关转发前把保险箱里的值从请求里抹掉，要读密文（用用户的 DEK 解开）。
GRANT SELECT (id, user_id, name, sealed) ON vault_items TO thinktin_llmgw;
