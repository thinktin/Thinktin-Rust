-- 派单（WBS 8.17，docs/projects-impl.md 第 3 条、“迁移与放量”）：可执行的项目运行、项目授权只由 8.17 的派单写。
-- 1. 库里的开关（一行，默认关）：运维确认老副本都退出以后 `thinktin-server admin project-dispatch on` 打开。
-- 2. 写入时的栅栏：项目运行、项目授权只有 worker、开关开着、连接声明了隔离级别（专属 1、混用 2）和项目协议（2 = 8.17：
--    跨主人的运行树、项目授权、项目里的工具）时写得进；agent、主人的成员关系、项目、实例都还在；只有负责人的运行能委派；
--    父运行还没结束；agent 运行要带授权；不来自计划，不是紧急消息（打断规则在 8.18）。
-- 3. 拿租约也要项目协议 2：8.16 的程序不再执行项目运行（它按主人的租户读名字、把子运行的失败原因交还给负责人）。
-- 4. 删掉同一主人的父子外键：项目里的运行树跨主人；私人空间里 0045 的同一空间外键照样要求同一个用户（space_id = user_id）。
-- 5. 私人看板不收项目条目（项目看板是 0061 的新表）。
-- 前提同 0039：第一次部署之前发布；滚动发布时上一版（8.16）不写项目运行、项目授权、跨主人的子运行。

CREATE TABLE project_dispatch (
    id         boolean PRIMARY KEY DEFAULT true CHECK (id),
    enabled    boolean NOT NULL DEFAULT false,
    changed_at timestamptz NOT NULL DEFAULT now(),
    changed_by text NOT NULL DEFAULT 'migration' CHECK (length(changed_by) BETWEEN 1 AND 200),
    reason     text CHECK (length(reason) <= 500)
);
-- 先插再开行级安全（FORCE 下迁移账号写不进）。没有策略：只有 worker（BYPASSRLS）读写。
INSERT INTO project_dispatch (id) VALUES (true);
ALTER TABLE project_dispatch ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_dispatch FORCE ROW LEVEL SECURITY;
-- UPDATE 的列权限也让下面的栅栏能 FOR SHARE 读这一行（和关开关的 UPDATE 排队）。
GRANT SELECT, UPDATE (enabled, changed_at, changed_by, reason) ON project_dispatch TO thinktin_worker;

-- agent、主人的成员关系、项目、实例都还在（和 store runs.rs 的 live_space!、cancel_orphaned_project_runs 一样，加上实例
-- 没删：租户删实例到 worker 撤下之间的那一会儿）。
CREATE FUNCTION project_agent_live(p uuid, i uuid, u uuid) RETURNS boolean LANGUAGE sql STABLE
    SET search_path = pg_catalog, public, pg_temp AS $$
    SELECT EXISTS (SELECT 1 FROM public.project_agents a
                     JOIN public.project_members m ON m.project_id = a.project_id AND m.user_id = a.user_id
                                                  AND m.left_at IS NULL
                     JOIN public.projects pr ON pr.id = a.project_id AND pr.status = 'active'
                     JOIN public.instances ins ON ins.id = a.instance_id AND ins.state <> 'deleted'
                    WHERE a.project_id = p AND a.instance_id = i AND a.user_id = u AND a.left_at IS NULL) $$;
REVOKE ALL ON FUNCTION project_agent_live(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION project_agent_live(uuid, uuid, uuid) TO thinktin_worker;

-- runs、run_grants 共用：只引用两张表都有的列（方案 8.16 V6）。每一层 IF 单独一句（8.16 V15：别的角色读不了下面的表）。
CREATE FUNCTION project_rows_fence() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    need int := 2;
    on_ boolean;
BEGIN
    IF current_user <> 'thinktin_worker' THEN
        RAISE EXCEPTION 'project rows in % are written by the server only', TG_TABLE_NAME
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    -- FOR SHARE：关开关的 UPDATE 等已经过了这里、还没提交的派单（关了以后再取消，不会漏掉在途的）。
    SELECT d.enabled INTO on_ FROM public.project_dispatch d FOR SHARE;
    IF NOT coalesce(on_, false) THEN
        RAISE EXCEPTION 'project dispatch is switched off'
            USING ERRCODE = 'insufficient_privilege', CONSTRAINT = 'project_dispatch_off';
    END IF;
    IF EXISTS (SELECT 1 FROM public.instances i WHERE i.id = NEW.instance_id
                 AND i.workspace_project_id = NEW.project_id) THEN
        need := 1;
    END IF;
    IF coalesce(nullif(current_setting('thinktin.isolation', true), ''), '0')::int < need
       OR coalesce(nullif(current_setting('thinktin.project_protocol', true), ''), '0')::int < 2 THEN
        RAISE EXCEPTION 'this server cannot write project work on instance %', NEW.instance_id
            USING ERRCODE = 'insufficient_privilege', CONSTRAINT = 'runs_isolation';
    END IF;
    IF NOT public.project_agent_live(NEW.project_id, NEW.instance_id, NEW.user_id) THEN
        RAISE EXCEPTION 'instance % is not a live agent of project %', NEW.instance_id, NEW.project_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'project_agent_gone';
    END IF;
    RETURN NEW;
END $$;

-- 项目运行树的样子：根是创建者派的任务（user/agent）或流水线（pipeline/pipeline，不跑 agent、不带授权）；子运行是委派、
-- 提问、流水线步骤，父运行还没结束；只有负责人的运行能委派（docs/projects.md 第 7 节）。父子同一个项目由 runs_parent_space
-- 保证。
CREATE FUNCTION runs_project_tree() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    parent record;
BEGIN
    IF NEW.plan_id IS NOT NULL OR NEW.trigger_id IS NOT NULL OR NEW.fire_time IS NOT NULL
       OR NEW.hook_id IS NOT NULL OR NEW.urgent OR NEW.interrupts_run_id IS NOT NULL THEN
        RAISE EXCEPTION 'project runs do not come from plans and do not interrupt'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'project_run_shape';
    END IF;
    IF NEW.kind = 'agent' AND NEW.run_grant_id IS NULL THEN
        RAISE EXCEPTION 'a project run needs a project grant'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'project_run_shape';
    END IF;
    IF NEW.parent_run_id IS NULL THEN
        IF NOT ((NEW.source = 'user' AND NEW.kind = 'agent')
                OR (NEW.source = 'pipeline' AND NEW.kind = 'pipeline' AND NEW.run_grant_id IS NULL)) THEN
            RAISE EXCEPTION 'a project root is a task or a pipeline'
                USING ERRCODE = 'check_violation', CONSTRAINT = 'project_run_shape';
        END IF;
        RETURN NEW;
    END IF;
    SELECT r.instance_id, r.kind, r.state INTO parent FROM public.runs r WHERE r.id = NEW.parent_run_id;
    IF NOT FOUND OR parent.state IN ('succeeded', 'failed', 'cancelled') THEN
        RAISE EXCEPTION 'the parent run % is gone or over', NEW.parent_run_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'project_run_shape';
    END IF;
    IF NEW.kind <> 'agent' OR NEW.source NOT IN ('delegate', 'ask', 'pipeline')
       OR (NEW.source = 'pipeline') <> (parent.kind = 'pipeline') THEN
        RAISE EXCEPTION 'unexpected project child run'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'project_run_shape';
    END IF;
    IF NEW.source = 'delegate' THEN
        IF NOT EXISTS (SELECT 1 FROM public.project_agents l
                        WHERE l.project_id = NEW.project_id AND l.instance_id = parent.instance_id
                          AND l.is_lead AND l.left_at IS NULL) THEN
            RAISE EXCEPTION 'only the project lead delegates'
                USING ERRCODE = 'insufficient_privilege', CONSTRAINT = 'project_delegate_not_lead';
        END IF;
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION project_rows_fence(), runs_project_tree() FROM PUBLIC;
CREATE TRIGGER runs_project_fence BEFORE INSERT ON runs FOR EACH ROW
    WHEN (NEW.project_id IS NOT NULL) EXECUTE FUNCTION project_rows_fence();
CREATE TRIGGER runs_project_tree BEFORE INSERT ON runs FOR EACH ROW
    WHEN (NEW.project_id IS NOT NULL) EXECUTE FUNCTION runs_project_tree();
CREATE TRIGGER run_grants_project_fence BEFORE INSERT ON run_grants FOR EACH ROW
    WHEN (NEW.project_id IS NOT NULL) EXECUTE FUNCTION project_rows_fence();

-- deploy-safe: 收紧。8.16 的程序不再给项目运行拿租约；可执行的项目运行只在派单开关打开以后才有，开关在老副本都退出
-- 以后才开（docs/release.md）
CREATE OR REPLACE FUNCTION runs_isolation_fence() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    need int := 2;
BEGIN
    IF EXISTS (SELECT 1 FROM public.instances i WHERE i.id = NEW.instance_id
                 AND i.workspace_project_id = NEW.project_id) THEN
        need := 1;
    END IF;
    IF coalesce(nullif(current_setting('thinktin.isolation', true), ''), '0')::int < need
       OR coalesce(nullif(current_setting('thinktin.project_protocol', true), ''), '0')::int < 2 THEN
        RAISE EXCEPTION 'this worker cannot run project run %', NEW.id
            USING ERRCODE = 'insufficient_privilege', CONSTRAINT = 'runs_isolation';
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION runs_isolation_fence() FROM PUBLIC;

-- deploy-safe: 只放宽。私人空间里 runs_parent_space（0045）照样要求父子同一个 space_id（= user_id）；上一版不写跨主人的子运行
ALTER TABLE runs DROP CONSTRAINT runs_parent_run_id_user_id_fkey;
-- deploy-safe: 同上，run_grants_parent_space
ALTER TABLE run_grants DROP CONSTRAINT run_grants_parent_id_user_id_fkey;
-- runs_parent_space 的 ON DELETE CASCADE 留着：用户行从不硬删，注销只删私人运行（users.rs），项目运行只由清理按新的在前删，
-- 级联不会跨主人。
COMMENT ON CONSTRAINT runs_parent_space ON runs IS
    'same space; cascade never crosses owners: users are never hard-deleted, erase deletes private runs only';

-- deploy-safe: 哪一版都不往私人看板写项目条目（8.16 的项目运行没有看板工具；8.17 写进 project_board_posts）。0056 给
-- board_posts 加的项目标记从此只会让带项目运行的写入失败（23514），2 级时连同 0058 的索引一起删
ALTER TABLE board_posts ADD CONSTRAINT board_posts_private CHECK (project_id IS NULL);
