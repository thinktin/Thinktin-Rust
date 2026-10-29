-- 交流功能（WBS 8.11、8.12）第二轮评审后的修正。

-- 子运行的结果（委派的子任务、队友的回答）什么时候交给了父运行的 agent：发出带结果的消息时记。
-- 处理完这一轮才记成已交还（reported_at），中途断了下次重交、并且说明是续跑；交出去以后再问同一个问题是真的再问。
ALTER TABLE runs ADD COLUMN handed_at timestamptz;

-- 紧急消息排在同一实例别的排队运行前面：领取时看这个实例有没有排着的紧急消息。
CREATE INDEX runs_urgent_queued ON runs (instance_id) WHERE urgent AND state = 'queued';
