-- 实时活动上次发的等待原因（10.7 的 waitCode）：只是等的原因变了（限流变成欠费）也要发一次更新。
ALTER TABLE live_activities ADD COLUMN sent_wait_code text;

-- 业务接口换令牌时把发过的内容清掉（和 sent_state、sent_steps 一样）。
GRANT UPDATE (sent_wait_code) ON live_activities TO thinktin_app;
