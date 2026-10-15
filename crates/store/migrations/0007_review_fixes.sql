-- 后端核心评审（2026-10-15）的修复。

-- 刷新令牌重用检测：记下会话用过的全部刷新令牌哈希，出示其中任何一个都吊销整个会话。
-- 只比对“上一个”不够：拿到旧令牌的人连刷两次，就把用户手里的令牌挤出了 prev_refresh_hash。
CREATE TABLE session_refresh_history (
    session_id   uuid NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
    refresh_hash bytea NOT NULL,
    retired_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (session_id, refresh_hash)
);
-- 登录流程只在 thinktin_worker 下跑；业务角色一行也看不到。
ALTER TABLE session_refresh_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE session_refresh_history FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, DELETE ON session_refresh_history TO thinktin_worker;
