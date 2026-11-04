-- 厂商替 agent 搜了几次（docs/search.md）：用户 2026-11-04 选了保留 agent 自带的厂商搜索，这笔钱厂商另收、不在 token 里，
-- 用量看板要看得到。
ALTER TABLE usage_records ADD COLUMN web_searches integer NOT NULL DEFAULT 0 CHECK (web_searches >= 0);
