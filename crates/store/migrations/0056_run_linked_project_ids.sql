-- 带运行的其余六张表也记项目（8.15 方案第 8 节）：保险箱请求、电脑调用、看板、出网请求、实时活动、举报。
-- 项目由触发器按调用者看得到的运行算，建了不能改；只有 worker 能自己填（8.17 的项目看板有不带运行的条目），填了要和运行
-- 一致（同 0054 inbox_project_guard 的写法）。不用 0050 的 fill_space_from_run：vault_requests、device_calls、
-- board_posts、egress_requests 是 ON DELETE SET NULL (run_id)，外键置空会触发 UPDATE OF run_id（方案 V5）。
-- 看不到运行（退出了的项目）一律 23503：外键检查不管行级安全。
-- 回填按 0050：迁移账号受 FORCE 约束，回填时临时去掉；按 0039 的前提这几张表里没有项目运行的行。

CREATE FUNCTION stamp_project_from_run() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    run_project uuid;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.project_id IS DISTINCT FROM OLD.project_id THEN
            RAISE EXCEPTION '%.project_id comes from the run and cannot change', TG_TABLE_NAME
                USING ERRCODE = 'check_violation';
        END IF;
        -- 运行只能被外键置空；出网请求在等的时候会换到同一个实例后来的运行上（store/egress.rs touch_request）。
        IF TG_TABLE_NAME <> 'egress_requests' AND NEW.run_id IS NOT NULL
           AND NEW.run_id IS DISTINCT FROM OLD.run_id THEN
            RAISE EXCEPTION '%.run_id cannot move to another run', TG_TABLE_NAME
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.project_id IS NOT NULL AND current_user <> 'thinktin_worker' THEN
        RAISE EXCEPTION '%.project_id is written by the server only', TG_TABLE_NAME
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NEW.run_id IS NOT NULL THEN
        SELECT r.project_id INTO run_project FROM public.runs r WHERE r.id = NEW.run_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION '% refers to a run that is not visible', TG_TABLE_NAME
                USING ERRCODE = 'foreign_key_violation';
        END IF;
        IF NEW.project_id IS NOT NULL AND NEW.project_id IS DISTINCT FROM run_project THEN
            RAISE EXCEPTION '%.project_id does not match its run', TG_TABLE_NAME
                USING ERRCODE = 'check_violation';
        END IF;
        NEW.project_id := run_project;
    END IF;
    -- 删了的项目里不再记新的（同 fill_space_from_run；出口代理读不到 projects，它只给在跑的运行记，删项目时已经取消了）。
    -- 两层 IF：projects 的权限在语句开始时就查，出口代理没有这张表的权限（方案 V15）。
    IF NEW.project_id IS NOT NULL AND current_user = 'thinktin_worker' THEN
        IF EXISTS (SELECT 1 FROM public.projects p WHERE p.id = NEW.project_id AND p.status = 'deleted') THEN
            RAISE EXCEPTION 'the project of this run was deleted'
                USING ERRCODE = 'check_violation', CONSTRAINT = 'project_deleted';
        END IF;
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION stamp_project_from_run() FROM PUBLIC;

ALTER TABLE vault_requests ADD COLUMN project_id uuid;
ALTER TABLE device_calls ADD COLUMN project_id uuid;
ALTER TABLE board_posts ADD COLUMN project_id uuid;
ALTER TABLE egress_requests ADD COLUMN project_id uuid;
ALTER TABLE live_activities ADD COLUMN project_id uuid;
ALTER TABLE content_reports ADD COLUMN project_id uuid;

ALTER TABLE runs NO FORCE ROW LEVEL SECURITY;
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['vault_requests', 'device_calls', 'board_posts', 'egress_requests', 'live_activities',
                             'content_reports'] LOOP
        EXECUTE format('ALTER TABLE %I NO FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('UPDATE %I x SET project_id = r.project_id FROM runs r '
                       'WHERE r.id = x.run_id AND r.project_id IS NOT NULL', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE OF project_id, run_id ON %I FOR EACH ROW '
                       'EXECUTE FUNCTION stamp_project_from_run()', t || '_project', t);
    END LOOP;
END $$;
ALTER TABLE runs FORCE ROW LEVEL SECURITY;

-- 出口代理插入出网请求时触发器要读运行的项目（0034:49 只给了这几列）。
GRANT SELECT (project_id) ON runs TO thinktin_llmgw;
-- 租户只改保险箱请求的处理结果（store/vault.rs create_vault_request、resolve_vault_request），不能把它挪到别的运行上。
-- deploy-safe: 上一版的租户代码只写 status、item_id、resolved_at
REVOKE UPDATE ON vault_requests FROM thinktin_app;
GRANT UPDATE (status, item_id, resolved_at) ON vault_requests TO thinktin_app;

-- 租户：项目行只在还是存活成员时看得到（0054 的写法）。vault_requests、board_posts、live_activities、content_reports 的
-- WITH CHECK 不变；egress_requests 本来没有 WITH CHECK（0034:42），新的 USING 也用来查 UPDATE 后的行，租户只改
-- status、decided_at，不影响。device_calls 没有租户权限（0014:77-82）。
ALTER POLICY tenant ON vault_requests
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));
ALTER POLICY tenant ON board_posts
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));
ALTER POLICY tenant ON egress_requests
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));
ALTER POLICY tenant ON live_activities
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));
ALTER POLICY tenant ON content_reports
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));

-- 删项目后清理用。这三张表很小（每人几条、24 小时保留、举报），直接建；大的两张在 0057、0058 并发建。
CREATE INDEX vault_requests_project ON vault_requests (project_id) WHERE project_id IS NOT NULL;
CREATE INDEX device_calls_project ON device_calls (project_id) WHERE project_id IS NOT NULL;
CREATE INDEX content_reports_project ON content_reports (project_id) WHERE project_id IS NOT NULL;
