-- 交流功能（WBS 8.10、8.12）评审后的修正。

-- 紧急消息（8.12）：每条都打标记。之前只有真去打断的那条带着要打断的运行，排在它后面的、实例空闲时发的
-- 都没标记，后来的紧急消息就可能插到它们前面，也会被当成普通消息捎带。
ALTER TABLE runs ADD COLUMN urgent boolean NOT NULL DEFAULT false;

-- 看板（8.10）：用户取消归档的条目算作新的。不然看板满了时，下一条新的又先把它归档了。
ALTER TABLE board_posts ADD COLUMN revived_at timestamptz;
GRANT UPDATE (revived_at) ON board_posts TO thinktin_app;
