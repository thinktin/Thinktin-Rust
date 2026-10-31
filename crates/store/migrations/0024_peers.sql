-- 认识队友与查进度（WBS 8.9）：同一用户的 agent 能列出彼此、查对方做到哪了（只读运行记录，不打扰对方）。
-- 依据《架构方案 v3》4.11“agent 之间怎么交流”和交流的护栏。

-- “允许其他 agent 查我、问我”，默认打开。关了以后它对 agents_list 不可见，agent_status（之后还有 ask）都被拒绝。
ALTER TABLE instances ADD COLUMN peer_access boolean NOT NULL DEFAULT true;
-- 用途说明：用户写的，agents_list 里给别的 agent 看（比如“负责调研”）。空的时候只看 agent 的种类。
ALTER TABLE instances ADD COLUMN purpose text NOT NULL DEFAULT '' CHECK (length(purpose) <= 200);
-- 0023 起业务角色按列授权：新列要单独放开（都在 App 里改，领养时用默认值）。
GRANT UPDATE (peer_access, purpose) ON instances TO thinktin_app;

-- 新的平台工具加进已有的实例授权、计划授权（新签发的授权按配置给）。只加给本来就有平台工具的授权
-- （平台工具为空表示有意不给），子授权跟着父授权、很快过期，不改。
UPDATE run_grants
   SET scope = jsonb_set(scope, '{platform_tools}', (scope -> 'platform_tools') || '["agents_list", "agent_status"]'::jsonb)
 WHERE parent_id IS NULL AND revoked_at IS NULL
   AND jsonb_typeof(scope -> 'platform_tools') = 'array'
   AND jsonb_array_length(scope -> 'platform_tools') > 0
   AND NOT (scope -> 'platform_tools') ? 'agents_list';
