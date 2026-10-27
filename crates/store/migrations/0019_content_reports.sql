-- 内容举报（WBS 5.5）：用户举报 agent 的输出（运行的回复、其中一条事件、一个产出物），运营处理后把结果告诉用户。
-- 应用审核和生成式 AI 服务都要求有投诉举报的渠道，并及时处理。

CREATE TABLE content_reports (
    id          uuid PRIMARY KEY,
    user_id     uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    -- 不设外键：用户删了实例、运行，举报和复制下来的内容还在，照样要处理（注销账号时一起删）。
    instance_id uuid NOT NULL,
    run_id      uuid NOT NULL,
    event_seq   bigint,
    artifact_id uuid,
    reason      text NOT NULL CHECK (reason IN ('harmful', 'illegal', 'sexual', 'hateful', 'privacy',
                                                'misinformation', 'infringement', 'other')),
    note        text CHECK (length(note) <= 1000),
    -- 提交时复制下来的、被举报的那一条内容（运行的提问和摘要、那条事件、产出物的元数据），给运营判断。
    snapshot    jsonb NOT NULL,
    state       text NOT NULL DEFAULT 'open' CHECK (state IN ('open', 'closed')),
    resolution  text CHECK (length(resolution) <= 500),
    handled_by  text CHECK (length(handled_by) <= 64),
    handled_at  timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CHECK ((state = 'closed') = (handled_at IS NOT NULL))
);
-- 同一个人对同一条内容只有一条待处理的举报（再点一次就是那一条）。
CREATE UNIQUE INDEX content_reports_open ON content_reports
    (user_id, run_id, coalesce(event_seq, -1), coalesce(artifact_id, '00000000-0000-0000-0000-000000000000'))
    WHERE state = 'open';
-- 运营的待处理队列，先来先处理。
CREATE INDEX content_reports_queue ON content_reports (created_at) WHERE state = 'open';
CREATE INDEX content_reports_user ON content_reports (user_id, created_at DESC);

ALTER TABLE content_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE content_reports FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant ON content_reports TO thinktin_app USING (user_id = app_user_id()) WITH CHECK (user_id = app_user_id());

-- 业务接口只提交、看自己的；处理只有运营命令（后台角色）做。
GRANT SELECT, INSERT ON content_reports TO thinktin_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON content_reports TO thinktin_worker;
