-- Windows 电脑端（架构方案 8.6）：设备平台多一种 windows。
-- deploy-safe: 只是放宽约束；上一版程序不认识 windows，但只有新版接口才会以 windows 登录，老程序读到的都是老设备。
ALTER TABLE devices DROP CONSTRAINT devices_platform_check;
ALTER TABLE devices ADD CONSTRAINT devices_platform_check
    CHECK (platform IN ('ios', 'android', 'macos', 'windows'));
