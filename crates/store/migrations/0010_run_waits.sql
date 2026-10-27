-- 等待电脑、等待 key（WBS 7.11）：进入等待时记下最晚等到什么时候，过了就按计划策略结束运行。
-- 等的事情发生（补上 key、电脑上线）或者到了下次试探的时间（not_before），执行器把运行重新领起来接着跑。
ALTER TABLE runs ADD COLUMN wait_deadline timestamptz;

DROP INDEX runs_claim;
CREATE INDEX runs_claim ON runs (not_before)
    WHERE state IN ('queued', 'backoff', 'waiting_quota', 'waiting_device');
CREATE INDEX runs_wait_deadline ON runs (wait_deadline)
    WHERE state IN ('waiting_quota', 'waiting_device');
