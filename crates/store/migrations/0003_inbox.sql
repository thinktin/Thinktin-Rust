-- 收件箱（WBS 10.4）：每条推送同时写进收件箱，客户端按已读状态展示、点开跳到对应对象。

ALTER TABLE inbox_items
    ADD COLUMN plan_id uuid,
    ADD COLUMN approval_id uuid,
    -- 同一件事只记一条（执行器重试结束运行时不会重复写）。
    ADD COLUMN dedupe_key text,
    ADD FOREIGN KEY (plan_id, user_id) REFERENCES plans (id, user_id) ON DELETE SET NULL (plan_id);

CREATE UNIQUE INDEX inbox_dedupe ON inbox_items (user_id, dedupe_key) WHERE dedupe_key IS NOT NULL;
CREATE INDEX inbox_approval ON inbox_items (approval_id) WHERE approval_id IS NOT NULL AND read_at IS NULL;
