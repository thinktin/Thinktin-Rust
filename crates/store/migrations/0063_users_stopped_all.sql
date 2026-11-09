-- 用户最近一次按“全部停止”的时间（WBS 8.17，用户 2026-11-07 定的第 1 条）：项目里的 botin 在这之后还没有经主人确认
-- 过的常设授权（之前从没有过、过期了的也算），派来的活先等主人确认。常设授权被“全部停止”吊销的照旧按暂停算。
-- deploy-safe: 新的可空列，上一版的代码不读不写它。
ALTER TABLE users ADD COLUMN stopped_all_at timestamptz;
