-- no-transaction
-- 项目运行写的看板条目（8.16；8.17 的项目看板也用）：删项目后清理用。
CREATE INDEX CONCURRENTLY board_posts_project ON board_posts (project_id, id DESC) WHERE project_id IS NOT NULL;
