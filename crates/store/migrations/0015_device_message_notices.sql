-- 电脑发给手机的审批请求（14.2）要推送提醒用户：后台把还没提醒过的发成收件箱条目和推送，记下提醒的时间，
-- 只提醒一次。
ALTER TABLE device_messages ADD COLUMN notified_at timestamptz;
CREATE INDEX device_messages_to_notify ON device_messages (id)
    WHERE notified_at IS NULL AND delivered_at IS NULL AND kind = 'approval_request';
-- 已有的消息不补提醒。
UPDATE device_messages SET notified_at = created_at;
