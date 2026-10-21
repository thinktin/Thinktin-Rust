-- IM 渠道（WBS 10.5）：用户绑定的飞书 / Lark、企业微信、钉钉群机器人。运行完成、需要审批、运行失败
-- 这些重要事件按用户的选择经出箱发到群里。
-- webhook 地址只存 token（发送时按官方前缀重新拼地址），token 和签名密钥一起按用户 DEK 加密，库里只有密文。

CREATE TABLE im_channels (
    id                uuid PRIMARY KEY,
    user_id           uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    vendor            text NOT NULL CHECK (vendor IN ('feishu', 'lark', 'wecom', 'dingtalk')),
    label             text NOT NULL DEFAULT '' CHECK (length(label) <= 64),
    -- token 和签名密钥一起加密（附加认证数据带用户 id 和渠道 id，挪到别的行解不开）。
    sealed            bytea NOT NULL,
    -- 给用户辨认用：token 后 4 位。
    hint              text NOT NULL DEFAULT '' CHECK (length(hint) <= 16),
    has_secret        boolean NOT NULL DEFAULT false,
    events            text[] NOT NULL DEFAULT '{run_finished,run_failed,approval}'
                      CHECK (events <@ ARRAY['run_finished', 'run_failed', 'approval']::text[]),
    enabled           boolean NOT NULL DEFAULT true,
    -- 多个后台副本共用的限流窗口（各家对每个机器人每分钟能发几条有上限）。
    rate_window_start timestamptz,
    rate_window_count integer NOT NULL DEFAULT 0,
    last_sent_at      timestamptz,
    last_error        text CHECK (length(last_error) <= 500),
    last_error_at     timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, user_id)
);
CREATE INDEX im_channels_user ON im_channels (user_id);

ALTER TABLE im_channels ENABLE ROW LEVEL SECURITY;
ALTER TABLE im_channels FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant ON im_channels TO thinktin_app USING (user_id = app_user_id()) WITH CHECK (user_id = app_user_id());

GRANT SELECT, INSERT, DELETE ON im_channels TO thinktin_app;
-- 业务接口改不了限流窗口和发送时间（只有后台发送时写）。
GRANT UPDATE (label, sealed, hint, has_secret, events, enabled, last_error, last_error_at, updated_at) ON im_channels TO thinktin_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON im_channels TO thinktin_worker;
