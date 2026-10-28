-- 问队友（WBS 8.11）：agent 用平台工具 ask 问同一用户的另一个 agent，问题是提问方运行下的一个子运行（来源 ask），
-- 在对方的实例上跑、接着对方的会话；回答交还给提问方。依据《架构方案 v3》4.11“agent 之间怎么交流”。

-- 放宽来源的检查约束。上一版程序不认识 ask：滚动更新期间老副本领到提问的运行会解析失败、领不走它，
-- 等新副本来领；提问只有新版程序的工具建得出来。
ALTER TABLE runs DROP CONSTRAINT runs_source_check,
    ADD CONSTRAINT runs_source_check CHECK (source IN ('user', 'plan', 'pipeline', 'delegate', 'ask'));

-- 回答的期限：过了还没答完的，后台取消它（连同它下面的子孙），提问方得到“对方没回答”。
-- 不用 wait_deadline：回答方等电脑、等 key 时会改写那一列。
ALTER TABLE runs ADD COLUMN answer_deadline timestamptz;
CREATE INDEX runs_answer_due ON runs (answer_deadline)
    WHERE answer_deadline IS NOT NULL AND state NOT IN ('succeeded', 'failed', 'cancelled');

-- 新的平台工具加进已有的实例授权、计划授权（同 0024）。
UPDATE run_grants
   SET scope = jsonb_set(scope, '{platform_tools}', (scope -> 'platform_tools') || '["ask"]'::jsonb)
 WHERE parent_id IS NULL AND revoked_at IS NULL
   AND jsonb_typeof(scope -> 'platform_tools') = 'array'
   AND jsonb_array_length(scope -> 'platform_tools') > 0
   AND NOT (scope -> 'platform_tools') ? 'ask';
