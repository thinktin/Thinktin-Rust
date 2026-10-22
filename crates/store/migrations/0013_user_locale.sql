-- 用户的语言（WBS 1.6）：服务端生成的推送、收件箱文案按它输出。
ALTER TABLE users ADD COLUMN locale text NOT NULL DEFAULT 'zh-CN' CHECK (locale IN ('zh-CN', 'en'));
