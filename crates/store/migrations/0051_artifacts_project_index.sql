-- no-transaction
-- 项目产出物（8.15）：成员列项目的产出物、删项目后清理时用。
CREATE INDEX CONCURRENTLY artifacts_project ON artifacts (project_id, id DESC) WHERE project_id IS NOT NULL;
