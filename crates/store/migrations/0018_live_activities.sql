-- 实时活动（WBS 10.6）：iOS 的灵动岛、锁屏上显示运行的进度。App 开了实时活动后把它的推送令牌报上来，后台在运行的
-- 状态、步数变了时经 APNs 的 liveactivity 推送更新，运行结束时发 end。计划到点开始的根运行，按设备的推送开启令牌
-- （iOS 17.2 起）远程开启。

-- 推送开启令牌：一个 App 安装一个，用户在 App 里打开“计划运行时显示实时活动”才报上来。和推送令牌一样只属于一台设备。
ALTER TABLE devices ADD COLUMN activity_start_token text CHECK (length(activity_start_token) <= 512);
-- 登记时把同一个令牌从别的设备上拿掉（同一台手机换了账号）。
CREATE INDEX devices_activity_start_token ON devices (activity_start_token) WHERE activity_start_token IS NOT NULL;

CREATE TABLE live_activities (
    device_id     uuid NOT NULL,
    run_id        uuid NOT NULL,
    user_id       uuid NOT NULL,
    -- app：App 自己开的；push：后台按推送开启令牌远程开的（开启的推送发出去之前、App 报上这个实时活动的令牌之前，
    -- push_token 是空的）。
    origin        text NOT NULL CHECK (origin IN ('app', 'push')),
    push_token    text CHECK (length(push_token) <= 512),
    start_sent_at timestamptz,
    -- 最近一次发出去的内容：和运行现在的状态、步数比，变了才发（几次变化合成一次）。
    sent_state    text,
    sent_steps    integer,
    sent_at       timestamptz,
    -- 发送失败：退避重试，次数到了就不再发。
    attempts      integer NOT NULL DEFAULT 0,
    retry_at      timestamptz,
    last_error    text CHECK (length(last_error) <= 500),
    -- 多个后台副本：领了的锁一会儿。
    locked_by     text,
    locked_until  timestamptz,
    -- 不再发了：发过 end（运行结束）、App 说关掉了、令牌失效、放弃了。
    ended_at      timestamptz,
    -- 是连着暂时失败、放弃了的（App 再登记同一个令牌可以从头来；令牌失效、关掉了的不行）。
    gave_up       boolean NOT NULL DEFAULT false,
    created_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (device_id, run_id),
    FOREIGN KEY (device_id, user_id) REFERENCES devices (id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (run_id, user_id) REFERENCES runs (id, user_id) ON DELETE CASCADE
);
CREATE INDEX live_activities_open ON live_activities (created_at) WHERE ended_at IS NULL;
CREATE INDEX live_activities_run ON live_activities (run_id);
CREATE INDEX live_activities_user ON live_activities (user_id);

ALTER TABLE live_activities ENABLE ROW LEVEL SECURITY;
ALTER TABLE live_activities FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant ON live_activities TO thinktin_app USING (user_id = app_user_id()) WITH CHECK (user_id = app_user_id());

GRANT SELECT, INSERT ON live_activities TO thinktin_app;
-- 业务接口只登记令牌、关掉（上次发的时间、锁只有后台写）；换了令牌（新的实时活动）时把发过的内容清掉、从现在起
-- 算 8 小时，现在的状态重发一次。
GRANT UPDATE (push_token, sent_state, sent_steps, attempts, retry_at, last_error, ended_at, gave_up, created_at)
    ON live_activities TO thinktin_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON live_activities TO thinktin_worker;
