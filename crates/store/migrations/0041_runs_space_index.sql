-- no-transaction
-- 0045 的同一空间外键要引用的唯一索引（单独一个文件：CONCURRENTLY 不能在事务里）。
CREATE UNIQUE INDEX CONCURRENTLY runs_id_space ON runs (id, space_kind, space_id);
