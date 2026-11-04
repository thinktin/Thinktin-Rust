-- no-transaction
-- 改、删 project_agents 的行时检查 runs_project_agent 要用。
CREATE INDEX CONCURRENTLY runs_project ON runs (project_id, instance_id, user_id) WHERE project_id IS NOT NULL;
