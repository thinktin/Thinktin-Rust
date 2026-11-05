-- 项目的成员读（WBS 8.15，docs/projects.md 第 5、9 节，docs/projects-impl.md 第 2 条，progress/drafts/projects-8.15-plan.md）。
-- 两个新角色由高权限账号预先建好（属主没有 CREATEROLE，docs/deploy-checklist.md 第 3 节），这里按名字先查：
--   thinktin_member          ProjectTx 用：默认对业务表没有权限，只有下面列出的列；行只放行“我是存活成员、项目没删”。
--   thinktin_project_definer SECURITY DEFINER 函数的属主：NOLOGIN、NOBYPASSRLS、NOINHERIT、不是任何角色的成员，自己也受
--                            行级安全约束（只看得到自己的成员行、用户行）。迁移账号是它的成员（WITH INHERIT FALSE,
--                            SET TRUE）：能把函数交给它，又不继承它的权限。服务角色都不能是这两个角色的成员（继承了就拿到
--                            成员读策略，或者定义者对 runs、events.payload 的列权限）。
-- 成员关系只按 app.user_id 算（member_projects() 没有参数）：手动传别的项目 id、设 app.project_id 之类的都读不到。
-- 定义者函数：search_path 固定、表名（包括要建的表名）带 public.、撤销 PUBLIC 的 EXECUTE；先授权、再改属主（ACL 跟着过去，
-- 迁移账号不继承新属主，改完就授不了权）。以后要改：GRANT CREATE → SET LOCAL ROLE thinktin_project_definer →
-- CREATE OR REPLACE（重写 SET search_path）→ RESET ROLE → REVOKE CREATE。
-- 另外：项目软删除以后（后台清理之前）租户策略也挡住删了的项目；四个旧的定义者函数固定 search_path。
-- 前提同 0039：第一次部署之前发布。

DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_member') THEN CREATE ROLE thinktin_member NOLOGIN NOBYPASSRLS; END IF; EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'thinktin_project_definer') THEN CREATE ROLE thinktin_project_definer NOLOGIN NOBYPASSRLS NOINHERIT; END IF; EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $$;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname IN ('thinktin_member', 'thinktin_project_definer')
                 AND (rolsuper OR rolbypassrls OR rolcanlogin OR rolcreaterole OR rolcreatedb))
       OR (SELECT rolinherit FROM pg_roles WHERE rolname = 'thinktin_project_definer')
       -- 这两个角色不是任何角色的成员。
       OR EXISTS (SELECT 1 FROM pg_auth_members am JOIN pg_roles r ON r.oid = am.member
                   WHERE r.rolname IN ('thinktin_member', 'thinktin_project_definer'))
       -- 服务角色都不是这两个角色的成员（迁移账号、登录账号不在这张单子里：它们只 SET ROLE）。
       OR EXISTS (SELECT 1 FROM pg_auth_members am JOIN pg_roles g ON g.oid = am.roleid
                    JOIN pg_roles m ON m.oid = am.member
                   WHERE g.rolname IN ('thinktin_member', 'thinktin_project_definer')
                     AND m.rolname IN ('thinktin_app', 'thinktin_worker', 'thinktin_llmgw', 'thinktin_relay')) THEN
        RAISE EXCEPTION 'thinktin_member and thinktin_project_definer must be NOLOGIN NOBYPASSRLS (the definer NOINHERIT), members of no role, and no service role may be their member';
    END IF;
    -- 超级用户（开发库、压测的临时库）跳过：pg_has_role 对它总是真。
    IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
        IF NOT pg_has_role(current_user, 'thinktin_project_definer', 'SET') THEN
            RAISE EXCEPTION 'grant thinktin_project_definer to the migration owner WITH INHERIT FALSE, SET TRUE (docs/deploy-checklist.md section 3)';
        END IF;
        IF pg_has_role(current_user, 'thinktin_project_definer', 'USAGE') THEN
            RAISE EXCEPTION 'the migration owner must not inherit thinktin_project_definer (GRANT ... WITH INHERIT FALSE, SET TRUE)';
        END IF;
    END IF;
END $$;
GRANT USAGE ON SCHEMA public TO thinktin_member, thinktin_project_definer;

-- 我是存活成员、项目进行中或归档、我没注销的项目。所有成员策略、租户收窄、worker 的下载核对都用它。
CREATE FUNCTION member_projects() RETURNS SETOF uuid LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, public, pg_temp AS $$
    SELECT m.project_id FROM public.project_members m
      JOIN public.projects p ON p.id = m.project_id
      JOIN public.users u ON u.id = m.user_id
     WHERE m.user_id = public.app_user_id() AND m.left_at IS NULL
       AND p.status IN ('active', 'archived') AND u.status <> 'deleted' $$;
-- 我在项目里的预算（别人的预算成员看不到：成员角色没有这两列）。
CREATE FUNCTION my_project_budget(p_project uuid)
    RETURNS TABLE (daily_token_limit bigint, total_token_limit bigint)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
    SELECT m.daily_token_limit, m.total_token_limit FROM public.project_members m
     WHERE m.project_id = p_project AND m.user_id = public.app_user_id()
       AND m.project_id IN (SELECT public.member_projects()) $$;
REVOKE ALL ON FUNCTION member_projects(), my_project_budget(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION member_projects() TO thinktin_member, thinktin_app, thinktin_worker;
GRANT EXECUTE ON FUNCTION my_project_budget(uuid) TO thinktin_member;
GRANT CREATE ON SCHEMA public TO thinktin_project_definer;   -- 只为改属主（新属主要有建对象的权限），下面就收回
ALTER FUNCTION member_projects() OWNER TO thinktin_project_definer;
ALTER FUNCTION my_project_budget(uuid) OWNER TO thinktin_project_definer;
-- deploy-safe: 只收回上面临时给的 CREATE，上一版没有用到这个角色
REVOKE CREATE ON SCHEMA public FROM thinktin_project_definer;

-- 定义者自己：只看得到自己的成员行、自己的用户行、自己（曾经）是成员的项目行。
GRANT SELECT (project_id, user_id, left_at, daily_token_limit, total_token_limit) ON project_members
    TO thinktin_project_definer;
GRANT SELECT (id, status) ON projects TO thinktin_project_definer;
GRANT SELECT (id, status) ON users TO thinktin_project_definer;
CREATE POLICY definer_own ON project_members FOR SELECT TO thinktin_project_definer
    USING (user_id = app_user_id());
CREATE POLICY definer_own ON projects FOR SELECT TO thinktin_project_definer
    USING (id IN (SELECT pm.project_id FROM project_members pm WHERE pm.user_id = app_user_id()));
CREATE POLICY definer_self ON users FOR SELECT TO thinktin_project_definer USING (id = app_user_id());

-- 成员：项目目录（列表、详情的结构和 8.14 一样）。没有预算列、allow_computer、consented_at；实例没有 state（看得出别人
-- 私下在不在忙），删掉的实例和撤下的 agent 的实例看不到；用户只看得到还在的成员的昵称（退出、注销的匿名）。
GRANT SELECT (id, creator_id, name, goal, status, shared_at, created_at, updated_at, archived_at) ON projects
    TO thinktin_member;
GRANT SELECT (project_id, user_id, role, joined_at, left_at, left_reason) ON project_members TO thinktin_member;
GRANT SELECT (project_id, instance_id, user_id, is_lead, dedicated, position, added_at, left_at) ON project_agents
    TO thinktin_member;
GRANT SELECT (id, display_name) ON users TO thinktin_member;
GRANT SELECT (id, user_id, agent_id, name) ON instances TO thinktin_member;
CREATE POLICY member_read ON projects FOR SELECT TO thinktin_member USING (id IN (SELECT member_projects()));
CREATE POLICY member_read ON project_members FOR SELECT TO thinktin_member
    USING (project_id IN (SELECT member_projects()));
CREATE POLICY member_read ON project_agents FOR SELECT TO thinktin_member
    USING (project_id IN (SELECT member_projects()));
CREATE POLICY member_read ON users FOR SELECT TO thinktin_member
    USING (id IN (SELECT m.user_id FROM project_members m
                   WHERE m.left_at IS NULL AND m.project_id IN (SELECT member_projects())));
CREATE POLICY member_read ON instances FOR SELECT TO thinktin_member
    USING (state <> 'deleted' AND id IN (SELECT a.instance_id FROM project_agents a
                                           WHERE a.left_at IS NULL AND a.project_id IN (SELECT member_projects())));

-- 租户的项目策略也看状态（之前只有 own_project、writable_solo 在代码里查）：删了的（清理之前）看不到；只有进行中的单人
-- 项目改得了名、加得进成员和 agent；删实例时归档的单人项目里自己的 agent 照样能标成离开（共享项目的由 worker 撤下）。
ALTER POLICY tenant_read ON projects USING (creator_id = app_user_id() AND status <> 'deleted');
ALTER POLICY tenant_update ON projects
    USING (creator_id = app_user_id() AND shared_at IS NULL AND status = 'active')
    WITH CHECK (creator_id = app_user_id() AND shared_at IS NULL AND status = 'active');
ALTER POLICY tenant_insert ON project_members
    WITH CHECK (user_id = app_user_id() AND role = 'creator' AND left_at IS NULL
                AND EXISTS (SELECT 1 FROM projects p WHERE p.id = project_id
                              AND p.creator_id = app_user_id() AND p.shared_at IS NULL AND p.status = 'active'));
ALTER POLICY tenant_insert ON project_agents
    WITH CHECK (user_id = app_user_id() AND NOT dedicated
                AND EXISTS (SELECT 1 FROM projects p WHERE p.id = project_id
                              AND p.creator_id = app_user_id() AND p.shared_at IS NULL AND p.status = 'active'));
ALTER POLICY tenant_update ON project_agents
    USING (user_id = app_user_id()
           AND EXISTS (SELECT 1 FROM projects p WHERE p.id = project_id
                         AND p.creator_id = app_user_id() AND p.shared_at IS NULL AND p.status <> 'deleted'))
    WITH CHECK (user_id = app_user_id()
                AND EXISTS (SELECT 1 FROM projects p WHERE p.id = project_id
                              AND p.creator_id = app_user_id() AND p.shared_at IS NULL AND p.status <> 'deleted'));

-- 删项目一律软删除（worker），租户不能再硬删单人项目（会跳过销毁密钥、后台清理）。
-- deploy-safe: 8.14 起删项目、删团队都走 worker（orchestrator::projects::delete），上一版不再用租户的删除
DROP POLICY tenant_delete ON projects;
-- deploy-safe: 同上
REVOKE DELETE ON projects FROM thinktin_app;
-- 后台清理找删了的项目（表小，按 0039 的前提没有流量）。
CREATE INDEX projects_deleted ON projects (deleted_at) WHERE status = 'deleted';

-- 加固四个旧的定义者函数（0001、0007、0023）：search_path = public 且没写 pg_temp 时临时表排在最前，能遮住 events、
-- blob_purge。要建、要删的表名也带 public.（search_path 第一项是 pg_catalog，不带就建到 pg_catalog 里去，报错）。
CREATE OR REPLACE FUNCTION ensure_event_partitions(start_month date, months integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    m date := date_trunc('month', start_month)::date;
    name text;
BEGIN
    FOR i IN 0..months - 1 LOOP
        name := format('events_%s', to_char(m, 'YYYYMM'));
        EXECUTE format('CREATE TABLE IF NOT EXISTS public.%I PARTITION OF public.events FOR VALUES FROM (%L) TO (%L)',
                       name, m, (m + interval '1 month')::date);
        m := (m + interval '1 month')::date;
    END LOOP;
END $$;
CREATE OR REPLACE FUNCTION drop_event_partitions_before(before date) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    part text;
    dropped integer := 0;
BEGIN
    FOR part IN
        SELECT c.relname FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = 'public.events'::regclass AND c.relname ~ '^events_[0-9]{6}$'
    LOOP
        IF (to_date(substr(part, 8), 'YYYYMM') + interval '1 month')::date <= before THEN
            EXECUTE format('DROP TABLE public.%I', part);
            dropped := dropped + 1;
        END IF;
    END LOOP;
    RETURN dropped;
END $$;
CREATE OR REPLACE FUNCTION queue_artifact_blob_purge() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    INSERT INTO public.blob_purge (blob_key) VALUES (OLD.blob_key) ON CONFLICT DO NOTHING;
    RETURN OLD;
END $$;
CREATE OR REPLACE FUNCTION queue_workspace_archive_purge() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    own text := 'workspaces/' || replace(OLD.user_id::text, '-', '') || '/';
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF starts_with(OLD.workspace_archive_key, own) THEN
            INSERT INTO public.blob_purge (blob_key) VALUES (OLD.workspace_archive_key) ON CONFLICT DO NOTHING;
        END IF;
        IF starts_with(OLD.workspace_archive_pending, own) THEN
            INSERT INTO public.blob_purge (blob_key) VALUES (OLD.workspace_archive_pending) ON CONFLICT DO NOTHING;
        END IF;
        RETURN OLD;
    END IF;
    IF starts_with(OLD.workspace_archive_key, own)
       AND OLD.workspace_archive_key IS DISTINCT FROM NEW.workspace_archive_key THEN
        INSERT INTO public.blob_purge (blob_key) VALUES (OLD.workspace_archive_key) ON CONFLICT DO NOTHING;
    END IF;
    -- 上传完成时待定的对象变成正式的，不删。
    IF starts_with(OLD.workspace_archive_pending, own)
       AND OLD.workspace_archive_pending IS DISTINCT FROM NEW.workspace_archive_pending
       AND OLD.workspace_archive_pending IS DISTINCT FROM NEW.workspace_archive_key THEN
        INSERT INTO public.blob_purge (blob_key) VALUES (OLD.workspace_archive_pending) ON CONFLICT DO NOTHING;
    END IF;
    RETURN NEW;
END $$;
