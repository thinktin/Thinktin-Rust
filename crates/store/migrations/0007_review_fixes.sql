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

-- 计划确认绑定到用户看过的版本：agent 每次新建、修改计划都把版本号加一、标记待确认；
-- 用户确认时带上看到的版本号，对不上（中间又被 agent 改过）就拒绝。待确认的计划不能直接“恢复”。
ALTER TABLE plans ADD COLUMN revision integer NOT NULL DEFAULT 1;
ALTER TABLE plans ADD COLUMN awaiting_confirmation boolean NOT NULL DEFAULT false;

-- 沙箱令牌的代数：运行的一次尝试结束时加一，之前签出的令牌随之失效
-- （agent 在沙箱里留下的后台进程拿着旧令牌，运行结束后就用不了模型网关了）。
ALTER TABLE instances ADD COLUMN token_epoch bigint NOT NULL DEFAULT 0;
