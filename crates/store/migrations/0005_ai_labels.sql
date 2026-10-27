-- AI 生成内容标识（WBS 16.3）：收件箱条目的正文是不是 agent 生成的，客户端据此显示标识。
ALTER TABLE inbox_items ADD COLUMN ai_generated boolean NOT NULL DEFAULT false;
