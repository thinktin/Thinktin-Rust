-- no-transaction
-- 项目运行的出网请求（8.16）：删项目后清理用。
CREATE INDEX CONCURRENTLY egress_requests_project ON egress_requests (project_id) WHERE project_id IS NOT NULL;
