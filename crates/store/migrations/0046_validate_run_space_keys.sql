-- 检查 0045 加的同一空间外键。迁移账号是属主，FORCE 时外键检查也按行级安全看不到任何行（两边都是 0 行，什么都不查就
-- 标成检查过了）：同一个事务里引用方、被引用方都临时去掉 FORCE，查完再加回来（会拿 ACCESS EXCLUSIVE；按 0039 的前提表还是空的）。
ALTER TABLE runs NO FORCE ROW LEVEL SECURITY;
ALTER TABLE run_grants NO FORCE ROW LEVEL SECURITY;
ALTER TABLE project_agents NO FORCE ROW LEVEL SECURITY;
ALTER TABLE runs VALIDATE CONSTRAINT runs_project_agent;
ALTER TABLE run_grants VALIDATE CONSTRAINT run_grants_project_agent;
ALTER TABLE run_grants VALIDATE CONSTRAINT run_grants_parent_space;
ALTER TABLE runs VALIDATE CONSTRAINT runs_parent_space;
ALTER TABLE runs VALIDATE CONSTRAINT runs_grant_space;
ALTER TABLE runs FORCE ROW LEVEL SECURITY;
ALTER TABLE run_grants FORCE ROW LEVEL SECURITY;
ALTER TABLE project_agents FORCE ROW LEVEL SECURITY;
