-- 共享看板（WBS 8.10）：每个用户一块，他的所有 agent 都能读写：进展、做过的决定、待别人处理的事。
-- 依据《架构方案 v3》4.11“agent 之间怎么交流”和交流的护栏。

-- 内容是 agent（或用户在 App 里）写的，交给 agent 时当不可信输入（像网页内容一样，不当指令）。
-- 没归档的条数有上限：按用户加咨询锁再数，满了先把最早的归档；归档的过一段时间由维护任务删掉。
CREATE TABLE board_posts (
    id                 uuid PRIMARY KEY,                  -- UUIDv7，按它排先后
    user_id            uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    -- 作者：哪个实例写的；NULL 是用户自己在 App 里写的，或者写它的实例已经删了（显示“已删除的 agent”）。
    author_instance_id uuid,
    -- 哪次运行写的（运行树里看得到）；运行删了条目还在。
    run_id             uuid,
    -- agent 写的（App 里按 AI 生成内容标注；作者、运行删了也还知道）。
    by_agent           boolean NOT NULL,
    body               text NOT NULL CHECK (length(body) BETWEEN 1 AND 2000),
    -- 团队、项目标签，按标签读。格式（字母数字、-、_，最长 32）在程序里查，这里只限个数。
    tags               text[] NOT NULL DEFAULT '{}' CHECK (cardinality(tags) <= 8),
    created_at         timestamptz NOT NULL DEFAULT now(),
    archived_at        timestamptz,
    FOREIGN KEY (author_instance_id, user_id) REFERENCES instances (id, user_id)
        ON DELETE SET NULL (author_instance_id),
    FOREIGN KEY (run_id, user_id) REFERENCES runs (id, user_id) ON DELETE SET NULL (run_id)
);
-- 读看板、数条数：没归档的，新的在前。标签在这个范围里过滤（条数有上限，不用 GIN）。
CREATE INDEX board_posts_live ON board_posts (user_id, id DESC) WHERE archived_at IS NULL;
-- 看归档的（新的在前）；按归档时间删。
CREATE INDEX board_posts_archived ON board_posts (user_id, id DESC) WHERE archived_at IS NOT NULL;
CREATE INDEX board_posts_archived_at ON board_posts (archived_at) WHERE archived_at IS NOT NULL;
-- 删实例、删运行时 SET NULL 要按它们找。
CREATE INDEX board_posts_author ON board_posts (author_instance_id) WHERE author_instance_id IS NOT NULL;
CREATE INDEX board_posts_run ON board_posts (run_id) WHERE run_id IS NOT NULL;

ALTER TABLE board_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE board_posts FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant ON board_posts TO thinktin_app USING (user_id = app_user_id()) WITH CHECK (user_id = app_user_id());

-- 业务接口（App 的看板页；平台工具也按用户开事务）：读、写、归档、删除。写了的内容不改，只能归档。
GRANT SELECT, INSERT, DELETE ON board_posts TO thinktin_app;
GRANT UPDATE (archived_at) ON board_posts TO thinktin_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON board_posts TO thinktin_worker;

-- 新的平台工具加进已有的实例授权、计划授权（同 0024）。
UPDATE run_grants
   SET scope = jsonb_set(scope, '{platform_tools}', (scope -> 'platform_tools') || '["board_read", "board_post"]'::jsonb)
 WHERE parent_id IS NULL AND revoked_at IS NULL
   AND jsonb_typeof(scope -> 'platform_tools') = 'array'
   AND jsonb_array_length(scope -> 'platform_tools') > 0
   AND NOT (scope -> 'platform_tools') ? 'board_read';
