-- App 要用的运行列表和等待原因（11.8）。

-- 等的是什么：只在 waiting_quota / waiting_device 时有意义（invalid、no_balance、unavailable、rate_limited、
-- overloaded、device_offline），离开等待时清掉。读的时候程序也按状态过滤（上一版既不写也不清）。
ALTER TABLE runs ADD COLUMN wait_code text;
ALTER TABLE runs ADD CONSTRAINT runs_wait_code_format CHECK (wait_code ~ '^[a-z][a-z_]{0,31}$') NOT VALID;

-- 后台为什么停用了这个触发器（invalid_rule：规则解析不了了）。用户自己停不了触发器。
ALTER TABLE triggers ADD COLUMN disabled_reason text CHECK (disabled_reason ~ '^[a-z][a-z_]{0,31}$');

-- GET /v1/runs：一个用户没结束的运行、一个计划的运行、一个用户的全部运行，按 id（UUIDv7）新的在前。
-- runs_user_active 的条件要和 list_runs 里的写法一模一样，规划器才用得上。
CREATE INDEX runs_user_active ON runs (user_id, id DESC) WHERE state NOT IN ('succeeded', 'failed', 'cancelled');
CREATE INDEX runs_plan ON runs (plan_id, id DESC) WHERE plan_id IS NOT NULL;
CREATE INDEX runs_user_recent ON runs (user_id, id DESC);
