-- 同一空间的外键，先只加 NOT VALID（ADD FOREIGN KEY 在两张表上拿 SHARE ROW EXCLUSIVE，锁到提交）；检查已有的行在 0046，
-- 单独一个事务。外键直接引用 0041、0042 建的唯一索引，不需要 ADD CONSTRAINT … UNIQUE USING INDEX。
-- 项目运行、项目授权只能落在这个项目里这个主人的 agent 上。运行是 NO ACTION（有项目运行的 agent 行删不掉，删项目要先清运行，
-- 8.15）；授权级联删掉（授权只吊销、从来不删，NO ACTION 的话签过一次项目授权就再也删不了项目、注销不了账号；用它的运行由
-- runs_grant_space 置空）。
ALTER TABLE runs ADD CONSTRAINT runs_project_agent FOREIGN KEY (project_id, instance_id, user_id)
    REFERENCES project_agents (project_id, instance_id, user_id) NOT VALID;
ALTER TABLE run_grants ADD CONSTRAINT run_grants_project_agent FOREIGN KEY (project_id, instance_id, user_id)
    REFERENCES project_agents (project_id, instance_id, user_id) ON DELETE CASCADE NOT VALID;
-- 同一空间：子授权跟父授权、子运行跟父运行、运行跟它用的授权。删除动作和旧的 (x, user_id) 外键一致；8.17 删旧外键时再定
-- 跨主人子运行的处理（impl 第 7 条：解除父关联）。
ALTER TABLE run_grants ADD CONSTRAINT run_grants_parent_space FOREIGN KEY (parent_id, space_kind, space_id)
    REFERENCES run_grants (id, space_kind, space_id) ON DELETE CASCADE NOT VALID;
ALTER TABLE runs ADD CONSTRAINT runs_parent_space FOREIGN KEY (parent_run_id, space_kind, space_id)
        REFERENCES runs (id, space_kind, space_id) ON DELETE CASCADE NOT VALID,
    ADD CONSTRAINT runs_grant_space FOREIGN KEY (run_grant_id, space_kind, space_id)
        REFERENCES run_grants (id, space_kind, space_id) ON DELETE SET NULL (run_grant_id) NOT VALID;
