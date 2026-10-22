-- 设备中继（WBS 14.1）：用户的电脑（macOS App）主动连出到中继，平台经它用电脑上的工具、在手机和电脑之间转发消息。
--
--   device_links    电脑现在连在哪个中继副本上（在线状态）。中继每次心跳刷新 last_seen_at，
--                   副本挂了没人刷新，过一会儿就算离线；
--   device_calls    平台发给电脑的工具调用：执行器写入，连着这台电脑的中继领走、转给电脑、回填结果；
--   device_messages 手机和电脑之间转发的消息（配对、审批、能力令牌、吊销，见 docs/pairing.md）：
--                   内容由两端签名，平台只转发；收件方不在线时排队，上线后投递，过期没送到的丢掉。
--
-- 有新东西要给某台电脑（调用、消息、连接被顶掉）时发通知 thinktin_device（载荷是设备 id），
-- 调用结束时发 thinktin_device_call（载荷是调用 id）。
--
-- 中继用自己的角色 thinktin_relay：核对设备会话、维护在线状态、领取和回填调用、收发消息、
-- 唤醒等电脑的运行（7.11），别的都碰不到。

DO $$ BEGIN CREATE ROLE thinktin_relay NOLOGIN BYPASSRLS; EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $$;

CREATE TABLE device_links (
    device_id    uuid PRIMARY KEY,
    user_id      uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    node         text NOT NULL,                       -- 中继副本
    connection   uuid NOT NULL,                       -- 这次连接；电脑重连后换新的，旧连接据此知道自己被顶掉了
    tools        text[] NOT NULL DEFAULT '{}',        -- 电脑报上来的、现在能用的工具（随系统权限变化）
    app_version  text NOT NULL DEFAULT '',
    connected_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (device_id, user_id) REFERENCES devices (id, user_id) ON DELETE CASCADE
);
CREATE INDEX device_links_user ON device_links (user_id);

CREATE TABLE device_calls (
    id          uuid PRIMARY KEY,
    user_id     uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    device_id   uuid NOT NULL,
    run_id      uuid,                                 -- 哪个运行发起的
    tool        text NOT NULL,
    arguments   jsonb NOT NULL,
    state       text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'sent', 'done', 'failed', 'expired')),
    connection  uuid,                                 -- 转给了电脑的哪次连接：连接断了，转出去没回的判失败
    result      jsonb,                                -- 电脑的回答：{"content": [...], "is_error": …}
    error       text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    sent_at     timestamptz,
    finished_at timestamptz,
    expires_at  timestamptz NOT NULL,
    FOREIGN KEY (device_id, user_id) REFERENCES devices (id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (run_id, user_id) REFERENCES runs (id, user_id) ON DELETE SET NULL (run_id)
);
CREATE INDEX device_calls_pending ON device_calls (device_id, created_at) WHERE state = 'pending';
CREATE INDEX device_calls_sent ON device_calls (connection) WHERE state = 'sent';
CREATE INDEX device_calls_created ON device_calls (created_at);

CREATE TABLE device_messages (
    id           uuid PRIMARY KEY,                    -- UUIDv7，按它的顺序投递
    user_id      uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    from_device  uuid NOT NULL,
    to_device    uuid NOT NULL,
    kind         text NOT NULL CHECK (kind IN ('pair_response', 'pair_confirm', 'approval_request',
                                                'approval_decision', 'capability', 'revocation')),
    body         jsonb NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,
    delivered_at timestamptz,
    CHECK (from_device <> to_device),
    FOREIGN KEY (from_device, user_id) REFERENCES devices (id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (to_device, user_id) REFERENCES devices (id, user_id) ON DELETE CASCADE
);
CREATE INDEX device_messages_pending ON device_messages (to_device, id) WHERE delivered_at IS NULL;
CREATE INDEX device_messages_created ON device_messages (created_at);

-- 业务接口：看自己电脑在不在线；手机收发消息。工具调用只由后台写，业务接口碰不到。
ALTER TABLE device_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE device_links FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant ON device_links FOR SELECT TO thinktin_app USING (user_id = app_user_id());
ALTER TABLE device_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE device_messages FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant ON device_messages TO thinktin_app USING (user_id = app_user_id()) WITH CHECK (user_id = app_user_id());
ALTER TABLE device_calls ENABLE ROW LEVEL SECURITY;
ALTER TABLE device_calls FORCE ROW LEVEL SECURITY;

GRANT SELECT ON device_links TO thinktin_app;
GRANT SELECT, INSERT, UPDATE ON device_messages TO thinktin_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON device_links, device_calls, device_messages TO thinktin_worker;

GRANT USAGE ON SCHEMA public TO thinktin_relay;
GRANT SELECT (id, status) ON users TO thinktin_relay;
GRANT SELECT (id, user_id, platform, revoked_at) ON devices TO thinktin_relay;
GRANT SELECT (id, user_id, device_id, revoked_at, expires_at) ON sessions TO thinktin_relay;
GRANT SELECT, INSERT, UPDATE, DELETE ON device_links TO thinktin_relay;
GRANT SELECT, UPDATE ON device_calls TO thinktin_relay;
GRANT SELECT, INSERT, UPDATE ON device_messages TO thinktin_relay;
-- 电脑上线时唤醒等电脑的运行（7.11）。
GRANT SELECT (user_id, state, lease_owner, not_before), UPDATE (not_before, updated_at) ON runs TO thinktin_relay;
