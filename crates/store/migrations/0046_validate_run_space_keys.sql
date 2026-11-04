-- 检查 0045 加的同一空间外键（VALIDATE 只在引用方拿 SHARE UPDATE EXCLUSIVE）。
ALTER TABLE runs VALIDATE CONSTRAINT runs_project_agent;
ALTER TABLE run_grants VALIDATE CONSTRAINT run_grants_project_agent;
ALTER TABLE run_grants VALIDATE CONSTRAINT run_grants_parent_space;
ALTER TABLE runs VALIDATE CONSTRAINT runs_parent_space;
ALTER TABLE runs VALIDATE CONSTRAINT runs_grant_space;
