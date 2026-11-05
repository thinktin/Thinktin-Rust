-- no-transaction
-- 项目运行（8.15）：成员按新的在前列项目的运行、删项目后清理时用（runs_project 是给外键检查的顺序）。
CREATE INDEX CONCURRENTLY runs_project_recent ON runs (project_id, id DESC) WHERE project_id IS NOT NULL;
