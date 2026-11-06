-- 专属实例与项目运行的隔离（WBS 8.16，docs/projects.md 第 6 节，docs/projects-impl.md 第 5 条、“迁移与放量”）。
-- 沙箱里所有进程是同一个 OS 用户，按目录分不开私人和项目（impl 第 5 条）：这一版的隔离单位是整个实例。
-- instances.workspace_project_id 不为空的实例（专属实例）的沙箱、工作区卷、归档、agent 的 HOME 和会话只属于这个项目，
-- 不接私人任务；混用实例（为空）的项目运行哪个版本的程序都不领（runs_isolation）。这一列只有 thinktin_worker 写
-- （租户的列权限见 0023:24-27、0024:9、0032:9）。
-- 前提同 0039：第一次部署之前发布，表是空的；instances 上的索引、约束直接建（行数 = 实例数）。

ALTER TABLE instances ADD COLUMN workspace_project_id uuid REFERENCES projects (id);
CREATE INDEX instances_workspace_project ON instances (workspace_project_id) WHERE workspace_project_id IS NOT NULL;
-- 专属实例不让别的 agent 查、问：上一版程序的 agents_list、agent_status、ask 只认 peer_access（instances.rs peers、
-- runs.rs accepts_questions），照样看不到它（方案 D11）。
-- deploy-safe: 新列全是空的；上一版的租户 PATCH 只会在专属实例上撞这个约束（422）
ALTER TABLE instances ADD CONSTRAINT instances_dedicated_no_peers
    CHECK (workspace_project_id IS NULL OR NOT peer_access);
-- 归档键跟着空间走（impl 第 5 条）：专属实例只用 projects/<项目>/workspaces/ 下的键（项目 DEK），私人实例不用 projects/
-- 下的键。上一版的控制面给专属实例归档时按用户前缀记待定的键，在这里被拒（23514），沙箱留着不删，项目明文不会按个人
-- DEK 存进对象存储。
-- deploy-safe: 上一版只写 workspaces/<用户>/ 下的键，新列全是空的
ALTER TABLE instances ADD CONSTRAINT instances_archive_space CHECK (CASE
    WHEN workspace_project_id IS NULL THEN
        NOT starts_with(coalesce(workspace_archive_key, ''), 'projects/')
        AND NOT starts_with(coalesce(workspace_archive_pending, ''), 'projects/')
    ELSE coalesce(starts_with(workspace_archive_key,
                  'projects/' || replace(workspace_project_id::text, '-', '') || '/workspaces/'), true)
        AND coalesce(starts_with(workspace_archive_pending,
                  'projects/' || replace(workspace_project_id::text, '-', '') || '/workspaces/'), true) END);
-- 跨用户项目里派混用实例时，用户确认过“它记忆里的私人内容可能被带进项目”（试点默认不收混用实例）。
ALTER TABLE project_agents ADD COLUMN shared_memory_ack_at timestamptz;
-- dedicated 由下面的 project_agents_dedicated 触发器从实例算（租户没有这一列的权限，0039:220）：插入策略不再查
-- NOT dedicated，不然单人项目里专属于它的 agent 一改团队（INSERT … ON CONFLICT 先按插入策略查拟插入的行）就 42501。
ALTER POLICY tenant_insert ON project_agents
    WITH CHECK (user_id = app_user_id()
                AND EXISTS (SELECT 1 FROM projects p WHERE p.id = project_id
                              AND p.creator_id = app_user_id() AND p.shared_at IS NULL AND p.status = 'active'));

-- 换下来的工作区：沙箱、正在放回的沙箱、工作区卷由巡检销毁（不设外键：实例删了、账号注销了也要收拾）。
-- 归档对象不在这里：实例行上的键清空时由 queue_workspace_archive_purge 排进 blob_purge。
CREATE TABLE retired_workspaces (
    id           uuid PRIMARY KEY,
    instance_id  uuid NOT NULL,
    user_id      uuid NOT NULL,
    workspace_id text NOT NULL,
    sandbox_ids  text[] NOT NULL DEFAULT '{}',
    reason       text NOT NULL CHECK (reason IN ('dedicate', 'release', 'project_deleted')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    attempts     integer NOT NULL DEFAULT 0,
    retry_at     timestamptz NOT NULL DEFAULT now(),
    last_error   text CHECK (length(last_error) <= 500)
);
CREATE INDEX retired_workspaces_due ON retired_workspaces (retry_at);
ALTER TABLE retired_workspaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE retired_workspaces FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON retired_workspaces TO thinktin_worker;

-- 运行、授权：专属实例上只有它那个项目的（行类型不同的表各用一个函数，见方案 V6）。读实例时加 KEY SHARE：和标专属的
-- FOR UPDATE 排队（不和改 token_epoch、event_seq 的 NO KEY UPDATE 冲突）。
CREATE FUNCTION space_matches_instance() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    ws uuid;
BEGIN
    SELECT i.workspace_project_id INTO ws FROM public.instances i WHERE i.id = NEW.instance_id FOR KEY SHARE;
    IF ws IS NOT NULL AND ws IS DISTINCT FROM NEW.project_id THEN
        RAISE EXCEPTION 'instance % works only for its project', NEW.instance_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'instance_dedicated';
    END IF;
    RETURN NEW;
END $$;
-- 计划的步骤总是私人的。
CREATE FUNCTION private_target_not_dedicated() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    ws uuid;
BEGIN
    SELECT i.workspace_project_id INTO ws FROM public.instances i WHERE i.id = NEW.instance_id FOR KEY SHARE;
    IF ws IS NOT NULL THEN
        RAISE EXCEPTION 'instance % works only for its project', NEW.instance_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'instance_dedicated';
    END IF;
    RETURN NEW;
END $$;
-- 生效中的计划：自己的实例和步骤的实例都不能是专属的（暂停的可以留着，恢复时再查）。
CREATE FUNCTION plan_not_on_dedicated() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    PERFORM 1 FROM public.instances i WHERE i.id = NEW.instance_id FOR KEY SHARE;
    PERFORM 1 FROM public.plan_steps s JOIN public.instances i ON i.id = s.instance_id
      WHERE s.plan_id = NEW.id FOR KEY SHARE OF i;
    IF EXISTS (SELECT 1 FROM public.instances i WHERE i.id = NEW.instance_id AND i.workspace_project_id IS NOT NULL)
       OR EXISTS (SELECT 1 FROM public.plan_steps s JOIN public.instances i ON i.id = s.instance_id
                   WHERE s.plan_id = NEW.id AND i.workspace_project_id IS NOT NULL) THEN
        RAISE EXCEPTION 'plan % uses an instance that works only for a project', NEW.id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'instance_dedicated';
    END IF;
    RETURN NEW;
END $$;
-- 项目 agent：专属实例只在它那个项目里有存活的行；存活行的 dedicated 由实例算（离开的行不动：注销时会改成 false）。
CREATE FUNCTION project_agents_dedicated() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    ws uuid;
BEGIN
    IF NEW.left_at IS NOT NULL THEN
        RETURN NEW;
    END IF;
    SELECT i.workspace_project_id INTO ws FROM public.instances i WHERE i.id = NEW.instance_id FOR KEY SHARE;
    IF ws IS NOT NULL AND ws <> NEW.project_id THEN
        RAISE EXCEPTION 'instance % works only for another project', NEW.instance_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'instance_dedicated';
    END IF;
    NEW.dedicated := ws IS NOT NULL;
    RETURN NEW;
END $$;
-- 标成专属：实例上不能还有别的事（没结束的运行、生效中的计划、别的项目里存活的行）。由 worker 先锁实例再写，
-- 这里兜底（错误码 instance_not_free → 409）。
CREATE FUNCTION instances_dedicated_alone() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    IF NEW.workspace_project_id IS NULL OR NEW.workspace_project_id IS NOT DISTINCT FROM OLD.workspace_project_id THEN
        RETURN NEW;
    END IF;
    IF EXISTS (SELECT 1 FROM public.project_agents a WHERE a.instance_id = NEW.id AND a.left_at IS NULL
                 AND a.project_id <> NEW.workspace_project_id)
       OR EXISTS (SELECT 1 FROM public.runs r WHERE r.instance_id = NEW.id
                    AND r.state NOT IN ('succeeded', 'failed', 'cancelled'))
       OR EXISTS (SELECT 1 FROM public.plans p WHERE p.status = 'active'
                    AND (p.instance_id = NEW.id
                         OR p.id IN (SELECT s.plan_id FROM public.plan_steps s WHERE s.instance_id = NEW.id))) THEN
        RAISE EXCEPTION 'instance % still has other work', NEW.id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'instance_not_free';
    END IF;
    RETURN NEW;
END $$;
-- 拿项目运行的租约（任何版本、任何语句）：这一版程序声明能隔离到哪一级（Db::worker 设 thinktin.isolation）。专属于这个
-- 项目的实例要 1 级，混用实例要 2 级（还没有程序做得到）。续租只改 lease_expires_at、交还租约置空，都不触发；
-- transition_run 每次都写 lease_owner（保持原值），拿着租约的状态变更也触发（方案 V1）。
CREATE FUNCTION runs_isolation_fence() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    need int := 2;
BEGIN
    IF EXISTS (SELECT 1 FROM public.instances i WHERE i.id = NEW.instance_id
                 AND i.workspace_project_id = NEW.project_id) THEN
        need := 1;
    END IF;
    IF coalesce(nullif(current_setting('thinktin.isolation', true), ''), '0')::int < need THEN
        RAISE EXCEPTION 'this worker cannot isolate project run %', NEW.id
            USING ERRCODE = 'insufficient_privilege', CONSTRAINT = 'runs_isolation';
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION space_matches_instance(), private_target_not_dedicated(), plan_not_on_dedicated(),
    project_agents_dedicated(), instances_dedicated_alone(), runs_isolation_fence() FROM PUBLIC;

CREATE TRIGGER runs_instance_space BEFORE INSERT ON runs FOR EACH ROW EXECUTE FUNCTION space_matches_instance();
CREATE TRIGGER run_grants_instance_space BEFORE INSERT ON run_grants
    FOR EACH ROW EXECUTE FUNCTION space_matches_instance();
CREATE TRIGGER plan_steps_instance_space BEFORE INSERT OR UPDATE OF instance_id ON plan_steps
    FOR EACH ROW EXECUTE FUNCTION private_target_not_dedicated();
CREATE TRIGGER plans_instance_space BEFORE INSERT OR UPDATE OF instance_id, status ON plans
    FOR EACH ROW WHEN (NEW.status = 'active') EXECUTE FUNCTION plan_not_on_dedicated();
CREATE TRIGGER project_agents_dedicated BEFORE INSERT OR UPDATE OF left_at, dedicated, instance_id, project_id
    ON project_agents FOR EACH ROW EXECUTE FUNCTION project_agents_dedicated();
CREATE TRIGGER instances_dedicated_alone BEFORE UPDATE OF workspace_project_id ON instances
    FOR EACH ROW EXECUTE FUNCTION instances_dedicated_alone();
CREATE TRIGGER runs_isolation BEFORE UPDATE OF lease_owner ON runs FOR EACH ROW
    WHEN (NEW.project_id IS NOT NULL AND NEW.lease_owner IS NOT NULL) EXECUTE FUNCTION runs_isolation_fence();

-- 专属实例的归档在 projects/<项目>/workspaces/ 下（按项目 DEK 加密）：只收这一行自己项目前缀下的键（同 0023 的规矩）。
CREATE OR REPLACE FUNCTION queue_workspace_archive_purge() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    own text := 'workspaces/' || replace(OLD.user_id::text, '-', '') || '/';
    proj text := 'projects/' || replace(OLD.workspace_project_id::text, '-', '') || '/workspaces/';
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF starts_with(OLD.workspace_archive_key, own) OR starts_with(OLD.workspace_archive_key, proj) THEN
            INSERT INTO public.blob_purge (blob_key) VALUES (OLD.workspace_archive_key) ON CONFLICT DO NOTHING;
        END IF;
        IF starts_with(OLD.workspace_archive_pending, own) OR starts_with(OLD.workspace_archive_pending, proj) THEN
            INSERT INTO public.blob_purge (blob_key) VALUES (OLD.workspace_archive_pending) ON CONFLICT DO NOTHING;
        END IF;
        RETURN OLD;
    END IF;
    IF (starts_with(OLD.workspace_archive_key, own) OR starts_with(OLD.workspace_archive_key, proj))
       AND OLD.workspace_archive_key IS DISTINCT FROM NEW.workspace_archive_key THEN
        INSERT INTO public.blob_purge (blob_key) VALUES (OLD.workspace_archive_key) ON CONFLICT DO NOTHING;
    END IF;
    -- 上传完成时待定的对象变成正式的，不删。
    IF (starts_with(OLD.workspace_archive_pending, own) OR starts_with(OLD.workspace_archive_pending, proj))
       AND OLD.workspace_archive_pending IS DISTINCT FROM NEW.workspace_archive_pending
       AND OLD.workspace_archive_pending IS DISTINCT FROM NEW.workspace_archive_key THEN
        INSERT INTO public.blob_purge (blob_key) VALUES (OLD.workspace_archive_pending) ON CONFLICT DO NOTHING;
    END IF;
    RETURN NEW;
END $$;

-- 删了的项目（impl 第 7 条：每次发事件都查状态）：worker 不再往里追加事件、审批、产出物。租户本来就加不进去（看不到
-- 运行，空间算成私人，复合外键拒绝）；租户也读不到别人创建的项目行，所以只查 worker。两层 IF：表权限在语句开始时就查
-- （方案 V15）。
CREATE OR REPLACE FUNCTION fill_space_from_run() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.project_id IS DISTINCT FROM OLD.project_id OR NEW.space_kind IS DISTINCT FROM OLD.space_kind
           OR NEW.space_id IS DISTINCT FROM OLD.space_id OR NEW.user_id IS DISTINCT FROM OLD.user_id
           OR NEW.run_id IS DISTINCT FROM OLD.run_id THEN
            RAISE EXCEPTION '% cannot move between users, runs or spaces', TG_TABLE_NAME
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    NEW.project_id := NULL;
    IF NEW.run_id IS NOT NULL THEN
        SELECT r.project_id INTO NEW.project_id FROM public.runs r WHERE r.id = NEW.run_id;
    END IF;
    IF NEW.project_id IS NOT NULL AND current_user = 'thinktin_worker' THEN
        IF EXISTS (SELECT 1 FROM public.projects p WHERE p.id = NEW.project_id AND p.status = 'deleted') THEN
            RAISE EXCEPTION 'the project of this run was deleted'
                USING ERRCODE = 'check_violation', CONSTRAINT = 'project_deleted';
        END IF;
    END IF;
    NEW.space_kind := CASE WHEN NEW.project_id IS NULL THEN 'private' ELSE 'project' END;
    NEW.space_id := coalesce(NEW.project_id, NEW.user_id);
    RETURN NEW;
END $$;
