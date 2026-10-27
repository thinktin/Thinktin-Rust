-- 推送补齐（10.7）。

-- 开发证书签名的包拿到的是 APNs 沙盒环境的令牌（TestFlight、App Store 的包是生产环境）。
ALTER TABLE devices DROP CONSTRAINT devices_push_channel_check;
ALTER TABLE devices ADD CONSTRAINT devices_push_channel_check
    CHECK (push_channel IN ('apns', 'apns_sandbox', 'fcm', 'hms', 'honor', 'mi', 'oppo', 'vivo', 'unipush'));

-- 收件箱条目是哪一种提醒（推送的 tt.subtype），和保险箱请求的跳转目标。
ALTER TABLE inbox_items
    ADD COLUMN subtype text CHECK (subtype ~ '^[a-z][a-z_]{0,31}$'),
    ADD COLUMN vault_request_id uuid;
CREATE INDEX inbox_vault_request ON inbox_items (vault_request_id) WHERE vault_request_id IS NOT NULL AND read_at IS NULL;
