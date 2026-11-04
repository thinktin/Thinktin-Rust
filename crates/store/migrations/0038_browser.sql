-- 浏览器（docs/browser.md）：浏览器打开一个新网站时问用户，页面资源不问。回答按“网站”（主域名，proto::egress::site_of）
-- 共用：浏览器里批准了 zhihu.com，这次任务里再打开 zhuanlan.zhihu.com 不再问；直接上网仍按完整网址问。

ALTER TABLE egress_requests
    ADD COLUMN via text NOT NULL DEFAULT 'direct' CHECK (via IN ('direct', 'browser')),
    ADD COLUMN site text CHECK (site IS NULL OR length(site) BETWEEN 1 AND 253);
-- 按网站查这次任务的回答、按网站找在等的浏览器提问。
CREATE INDEX egress_requests_site_decided ON egress_requests (instance_id, site, decided_at DESC)
    WHERE status IN ('once', 'denied') AND site IS NOT NULL;
CREATE INDEX egress_requests_site_pending ON egress_requests (instance_id, site)
    WHERE status = 'pending' AND via = 'browser';

-- 日志：哪条通道、哪一种（问询、打开网页、页面资源）、是哪个网页带出来的。
ALTER TABLE egress_log
    ADD COLUMN via text NOT NULL DEFAULT 'direct' CHECK (via IN ('direct', 'browser')),
    ADD COLUMN kind text CHECK (kind IS NULL OR kind IN ('ask', 'nav', 'res')),
    ADD COLUMN page_site text;

-- 浏览器算一个平台工具权限：加进已有的实例授权、计划授权（同 0036）。
UPDATE run_grants
   SET scope = jsonb_set(scope, '{platform_tools}', (scope -> 'platform_tools') || '["browser"]'::jsonb)
 WHERE parent_id IS NULL AND revoked_at IS NULL
   AND jsonb_typeof(scope -> 'platform_tools') = 'array'
   AND jsonb_array_length(scope -> 'platform_tools') > 0
   AND NOT (scope -> 'platform_tools') ? 'browser';
