-- 事件触发（WBS 7.1 的事件部分）：计划的 webhook。外面的服务往一个只有用户知道的地址 POST，平台按这个计划
-- 起一次运行，把收到的内容交给 agent。设计见 docs/event-triggers.md。

CREATE TABLE plan_hooks (
    id            uuid PRIMARY KEY,
    user_id       uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    plan_id       uuid NOT NULL,
    -- 地址里令牌的 SHA-256。令牌只在建、换的时候给用户看一次。
    token_hash    bytea NOT NULL UNIQUE,
    enabled       boolean NOT NULL DEFAULT true,
    -- 用户同意把收到的内容交给 agent 和他配置的模型厂商处理的时间（建的时候必须同意）。
    consented_at  timestamptz NOT NULL,
    last_event_at timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, user_id),
    FOREIGN KEY (plan_id, user_id) REFERENCES plans (id, user_id) ON DELETE CASCADE
);
CREATE INDEX plan_hooks_plan ON plan_hooks (plan_id);

ALTER TABLE plan_hooks ENABLE ROW LEVEL SECURITY;
ALTER TABLE plan_hooks FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant ON plan_hooks TO thinktin_app USING (user_id = app_user_id()) WITH CHECK (user_id = app_user_id());
GRANT SELECT, INSERT, DELETE ON plan_hooks TO thinktin_app;
GRANT UPDATE (token_hash, enabled, last_event_at) ON plan_hooks TO thinktin_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON plan_hooks TO thinktin_worker;

-- 运行是哪个 webhook 起的（来源还是 plan，老版本照样解析）。按 webhook 数最近一小时起了几次、排着几个。
ALTER TABLE runs ADD COLUMN hook_id uuid;
CREATE INDEX runs_hook ON runs (hook_id, created_at) WHERE hook_id IS NOT NULL;
