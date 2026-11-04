-- 出网要问用户的网站（2.7e）评审（2026-11-04）后的修复。

-- 提醒用户的那条收件箱条目指向哪条请求：推送带上它，App 直接打开这一条；用户回答了、请求过期了，条目算已读。
ALTER TABLE inbox_items ADD COLUMN egress_request_id uuid;
CREATE INDEX inbox_egress_request ON inbox_items (egress_request_id)
    WHERE egress_request_id IS NOT NULL AND read_at IS NULL;

-- 每个实例一小时里最多登记几条新请求（不让定时任务每跑一次就弹一堆提示）。
CREATE INDEX egress_requests_instance_created ON egress_requests (instance_id, created_at);
