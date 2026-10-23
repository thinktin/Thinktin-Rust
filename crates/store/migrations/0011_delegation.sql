-- 委派（WBS 8.7）：子运行的结果交还给父运行的 agent 之后记下时间，同一个结果不重复交。
ALTER TABLE runs ADD COLUMN reported_at timestamptz;
CREATE INDEX runs_parent ON runs (parent_run_id) WHERE parent_run_id IS NOT NULL;
