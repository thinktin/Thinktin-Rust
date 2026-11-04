-- 运行中收消息（WBS 8.12）：实例正忙时用户的紧急消息“打断重来”；别的消息排队，agent 调平台工具时在返回里
-- 捎带“有新消息”。依据《架构方案 v3》4.11“干活时收到新消息”。

-- 打断：新消息的运行记下它要打断的那个运行。正在执行的那个续租时看到，就取消这一轮、结束运行，新消息接着跑
-- （还是那个会话）。执行器每次续租都查，按要打断的运行建索引。
ALTER TABLE runs ADD COLUMN interrupts_run_id uuid;
CREATE INDEX runs_interrupts ON runs (interrupts_run_id) WHERE interrupts_run_id IS NOT NULL AND state = 'queued';
-- 捎带：排队的用户消息已经在正忙的那个运行里给 agent 看过的时间（之后轮到它时提醒 agent 已经看过了）。
ALTER TABLE runs ADD COLUMN announced_at timestamptz;
