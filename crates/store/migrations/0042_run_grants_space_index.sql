-- no-transaction
-- 0045 的同一空间外键要引用的唯一索引。
CREATE UNIQUE INDEX CONCURRENTLY run_grants_id_space ON run_grants (id, space_kind, space_id);
