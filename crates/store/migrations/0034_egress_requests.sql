-- 受控出网通道（WBS 2.7）按用户 2026-11-04 改的规则：不放档位开关，大家默认 `dev`（搜索和开发网站直接能用），
-- 别的网站 agent 第一次访问时问用户：访问一次（这次任务）/ 一直允许（记进 egress_hosts）/ 拒绝（这次任务不再问）。

-- 出口代理还没在任何地方开过，已有的实例都还是建表时的默认值 `model`，一起改成 `dev`。
ALTER TABLE instances ALTER COLUMN egress_mode SET DEFAULT 'dev';
UPDATE instances SET egress_mode = 'dev' WHERE egress_mode = 'model';

-- agent 想访问、要问用户的网站。同一个实例、同一个网站同时只有一条在等（pending）；用户回答后定下来，“访问一次”
-- “拒绝”只对 run_id 那次任务有效（没有任务时只管一小时）。
CREATE TABLE egress_requests (
    id          uuid PRIMARY KEY,
    user_id     uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    instance_id uuid NOT NULL,
    host        text NOT NULL CHECK (length(host) BETWEEN 1 AND 253),
    -- 问的时候实例在做的任务；还在等的时候，后来的任务再问同一个网站就改成后来的那个。
    run_id      uuid,
    status      text NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'once', 'always', 'denied', 'expired')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    -- 最近一次有 agent 在等这个回答。
    asked_at    timestamptz NOT NULL DEFAULT now(),
    decided_at  timestamptz,
    -- 后台给用户发过提醒的时间；为空表示还没发。
    notified_at timestamptz,
    FOREIGN KEY (instance_id, user_id) REFERENCES instances (id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (run_id, user_id) REFERENCES runs (id, user_id) ON DELETE SET NULL (run_id)
);
CREATE UNIQUE INDEX egress_requests_pending ON egress_requests (instance_id, host) WHERE status = 'pending';
-- 出口代理查“这次任务里用户答过没有”。
CREATE INDEX egress_requests_decided ON egress_requests (instance_id, host, decided_at DESC)
    WHERE status IN ('once', 'denied');
-- 后台找还没提醒过的。
CREATE INDEX egress_requests_unnotified ON egress_requests (asked_at)
    WHERE status = 'pending' AND notified_at IS NULL;
-- 后台把等太久的标成过期、删掉旧的。
CREATE INDEX egress_requests_created ON egress_requests (created_at);
-- App 列自己在等的。
CREATE INDEX egress_requests_user ON egress_requests (user_id, created_at DESC) WHERE status = 'pending';

ALTER TABLE egress_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE egress_requests FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant ON egress_requests TO thinktin_app USING (user_id = app_user_id());

-- App 列出、回答；出口代理建、查、续（同一个网站后来的任务再问）；后台提醒、过期、删掉旧的。
GRANT SELECT, UPDATE (status, decided_at) ON egress_requests TO thinktin_app;
GRANT SELECT, INSERT, UPDATE (run_id, asked_at, notified_at) ON egress_requests TO thinktin_llmgw;
GRANT SELECT, UPDATE (status, notified_at), DELETE ON egress_requests TO thinktin_worker;
-- 出口代理要知道实例现在在做哪个任务（同一个实例同时只有一个在跑的 agent 任务）。
GRANT SELECT (id, user_id, instance_id, kind, state) ON runs TO thinktin_llmgw;
