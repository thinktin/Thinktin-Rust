-- 平台工具的副作用幂等（WBS 7.13）：同一次运行里参数完全相同、有副作用的调用只执行一次，
-- agent 重试时再调一遍直接复用上次的结果（不会多建一个计划、多委派一个子任务）。
CREATE TABLE tool_calls (
    run_id     uuid NOT NULL REFERENCES runs (id) ON DELETE CASCADE,
    key        bytea NOT NULL,          -- sha256(工具名 + 参数)
    user_id    uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    tool       text NOT NULL,
    result     jsonb NOT NULL,          -- 给 agent 的 content
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, key)
);

ALTER TABLE tool_calls ENABLE ROW LEVEL SECURITY;
ALTER TABLE tool_calls FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant ON tool_calls TO thinktin_app USING (user_id = app_user_id()) WITH CHECK (user_id = app_user_id());
GRANT SELECT, INSERT, DELETE ON tool_calls TO thinktin_worker;
