-- 平台搜索工具 web_search（docs/search.md）：服务器替 agent 调搜索接口，只回标题、链接、摘要。用户 2026-11-04 定：
-- 每人每天最多 50 次，测试期每月最多 ¥100，到了就停。

-- 每个用户每天（北京时间）搜了几次、花了多少（千分之一分，搜索接口的单价是“分/千次”）。
CREATE TABLE search_usage (
    user_id         uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    day             date NOT NULL,
    calls           integer NOT NULL DEFAULT 0 CHECK (calls >= 0),
    cost_millicents bigint NOT NULL DEFAULT 0 CHECK (cost_millicents >= 0),
    PRIMARY KEY (user_id, day)
);
CREATE INDEX search_usage_day ON search_usage (day);

ALTER TABLE search_usage ENABLE ROW LEVEL SECURITY;
ALTER TABLE search_usage FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant ON search_usage TO thinktin_app USING (user_id = app_user_id());
-- App 看自己的用量；后台（执行平台工具的就是后台）记账、到期删除。
GRANT SELECT ON search_usage TO thinktin_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON search_usage TO thinktin_worker;

-- 新的平台工具加进已有的实例授权、计划授权（同 0026）。
UPDATE run_grants
   SET scope = jsonb_set(scope, '{platform_tools}', (scope -> 'platform_tools') || '["web_search"]'::jsonb)
 WHERE parent_id IS NULL AND revoked_at IS NULL
   AND jsonb_typeof(scope -> 'platform_tools') = 'array'
   AND jsonb_array_length(scope -> 'platform_tools') > 0
   AND NOT (scope -> 'platform_tools') ? 'web_search';
