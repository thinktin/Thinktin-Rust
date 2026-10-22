-- 推送补齐（10.7）。

-- 开发证书签名的包拿到的是 APNs 沙盒环境的令牌（TestFlight、App Store 的包是生产环境）。
ALTER TABLE devices DROP CONSTRAINT devices_push_channel_check;
ALTER TABLE devices ADD CONSTRAINT devices_push_channel_check
    CHECK (push_channel IN ('apns', 'apns_sandbox', 'fcm', 'hms', 'honor', 'mi', 'oppo', 'vivo', 'unipush'));
