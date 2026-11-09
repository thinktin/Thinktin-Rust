-- 主人给派进项目的 botin 设 token 限额（WBS 8.17，用户 2026-11-07 定）：每天的、总的，空的是不限（只受成员在项目里的预算）。
-- 8.17 派单时按它粗略挡，8.18 在模型网关里精确扣。只有主人看得到、改得了：成员的投影（0049）没有这两列的权限。
ALTER TABLE project_agents
    ADD COLUMN daily_token_limit bigint CHECK (daily_token_limit BETWEEN 1 AND 1000000000000),
    ADD COLUMN total_token_limit bigint CHECK (total_token_limit BETWEEN 1 AND 1000000000000),
    ADD CONSTRAINT project_agents_token_limits
        CHECK (daily_token_limit IS NULL OR total_token_limit IS NULL OR daily_token_limit <= total_token_limit);
