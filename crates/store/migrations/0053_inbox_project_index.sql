-- no-transaction
-- 项目的提醒（8.15）：删项目、退出时把这个项目的提醒标已读，后台清理时用。
CREATE INDEX CONCURRENTLY inbox_project ON inbox_items (project_id) WHERE project_id IS NOT NULL;
