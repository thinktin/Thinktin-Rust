-- no-transaction
-- 改、删 project_agents 的行时检查 run_grants_project_agent 要用（不然每删一行都扫 run_grants）。
CREATE INDEX CONCURRENTLY run_grants_project ON run_grants (project_id, instance_id, user_id) WHERE project_id IS NOT NULL;
