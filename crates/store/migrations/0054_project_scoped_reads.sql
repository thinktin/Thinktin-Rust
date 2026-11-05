-- 项目运行对成员可读、退出即不可见（WBS 8.15，docs/projects-impl.md 第 2、6 条）。
-- 1. 运行、事件只经四个定义者函数给成员：按白名单投影（新的事件种类默认看不到），没有实例序号、失败原因、花费、审批。
-- 2. 租户读自己的运行、授权、事件、审批：项目行只在“我还是存活成员、项目没删”时看得到；产出物只看私人的（项目产出物走
--    /v1/projects/{id}/artifacts）；收件箱的项目回执按 subtype 照常看得到。
-- 3. 收件箱的 project_id 从运行算（0047 留下的 8.15 一条）；租户对收件箱只改 read_at，审批只做决定。
-- 收紧策略：上一版（8.14）没有项目运行、项目产出物，不读这些行。

-- 项目回执的子类型（proto::domain::notice_subtype::PROJECT_RECEIPTS，测试核对两边一样）：租户策略、守卫、后台清理共用。
-- 不是定义者函数，没有 SET（内联进策略）；8.19 加回执时 CREATE OR REPLACE 这一个函数。
CREATE FUNCTION project_receipt(subtype text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT subtype IN ('project_invite', 'project_joined', 'project_left', 'project_removed',
                       'project_agent_left', 'project_agent_removed', 'project_deleted') $$;

CREATE FUNCTION project_run_state(state text) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
    SELECT CASE state
        WHEN 'queued' THEN 'queued'
        WHEN 'waiting_approval' THEN 'waiting_owner' WHEN 'waiting_quota' THEN 'waiting_owner'
        WHEN 'waiting_device' THEN 'waiting_owner'
        WHEN 'waiting_children' THEN 'waiting_children'
        WHEN 'succeeded' THEN 'succeeded' WHEN 'failed' THEN 'failed' WHEN 'cancelled' THEN 'cancelled'
        ELSE 'running' END $$;            -- starting、running、backoff 和以后新加的状态
REVOKE ALL ON FUNCTION project_run_state(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION project_run_state(text) TO thinktin_project_definer;

GRANT SELECT (id, kind, user_id, instance_id, project_id, parent_run_id, root_run_id, step_key, source, prompt,
              state, summary, created_at, started_at, finished_at) ON runs TO thinktin_project_definer;
GRANT SELECT (run_id, project_id, seq, kind, payload, created_at) ON events TO thinktin_project_definer;
CREATE POLICY definer_project ON runs FOR SELECT TO thinktin_project_definer
    USING (project_id IN (SELECT member_projects()));
CREATE POLICY definer_project ON events FOR SELECT TO thinktin_project_definer
    USING (project_id IN (SELECT member_projects()));

-- 项目运行（成员能看的字段）。三个函数各一条固定的 WHERE（SQL 函数按通用参数规划，“p IS NULL OR 列 = p”用不上索引）。
CREATE FUNCTION project_run(p_project uuid, p_run uuid)
RETURNS TABLE (id uuid, kind text, user_id uuid, instance_id uuid, parent_run_id uuid, root_run_id uuid,
               step_key text, source text, prompt text, state text, summary text,
               created_at timestamptz, started_at timestamptz, finished_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
    SELECT r.id, r.kind, r.user_id, r.instance_id, r.parent_run_id, r.root_run_id, r.step_key, r.source, r.prompt,
           public.project_run_state(r.state), r.summary, r.created_at, r.started_at, r.finished_at
      FROM public.runs r
     WHERE r.id = p_run AND r.project_id = p_project AND r.project_id IN (SELECT public.member_projects()) $$;
-- 一棵树（同一空间的外键保证子孙都在这个项目里），先建的在前，最多 500 个（runs_tree）。
CREATE FUNCTION project_run_tree(p_project uuid, p_root uuid)
RETURNS TABLE (id uuid, kind text, user_id uuid, instance_id uuid, parent_run_id uuid, root_run_id uuid,
               step_key text, source text, prompt text, state text, summary text,
               created_at timestamptz, started_at timestamptz, finished_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
    SELECT r.id, r.kind, r.user_id, r.instance_id, r.parent_run_id, r.root_run_id, r.step_key, r.source, r.prompt,
           public.project_run_state(r.state), r.summary, r.created_at, r.started_at, r.finished_at
      FROM public.runs r
     WHERE r.root_run_id = p_root AND r.project_id = p_project AND r.project_id IN (SELECT public.member_projects())
     ORDER BY r.created_at, r.id
     LIMIT 500 $$;
-- 项目的运行，新的在前，p_before 往下翻（runs_project_recent），p_instance 只看一个 agent 的。
CREATE FUNCTION project_runs(p_project uuid, p_instance uuid, p_before uuid, p_limit integer)
RETURNS TABLE (id uuid, kind text, user_id uuid, instance_id uuid, parent_run_id uuid, root_run_id uuid,
               step_key text, source text, prompt text, state text, summary text,
               created_at timestamptz, started_at timestamptz, finished_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
    SELECT r.id, r.kind, r.user_id, r.instance_id, r.parent_run_id, r.root_run_id, r.step_key, r.source, r.prompt,
           public.project_run_state(r.state), r.summary, r.created_at, r.started_at, r.finished_at
      FROM public.runs r
     WHERE r.project_id = p_project AND r.project_id IN (SELECT public.member_projects())
       AND r.id < coalesce(p_before, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)
       AND (p_instance IS NULL OR r.instance_id = p_instance)
     ORDER BY r.id DESC
     LIMIT least(greatest(coalesce(p_limit, 50), 1), 200) $$;

-- 一个项目运行最近的事件（白名单投影，旧的在前）。
CREATE FUNCTION project_run_events(p_project uuid, p_run uuid, p_limit integer)
RETURNS TABLE (kind text, data jsonb, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
    SELECT v.kind, v.data, v.created_at FROM (
        SELECT e.seq, e.created_at,
               CASE e.kind
                   WHEN 'agent.tool_call' THEN 'tool_call' WHEN 'agent.tool_call_update' THEN 'tool_call_update'
                   WHEN 'agent.message' THEN 'message' WHEN 'agent.plan' THEN 'plan'
                   WHEN 'agent.turn_started' THEN 'turn_started' WHEN 'agent.turn_ended' THEN 'turn_ended'
                   WHEN 'run.state' THEN 'state' WHEN 'run.log_truncated' THEN 'log_truncated'
                   WHEN 'artifact.published' THEN 'artifact' WHEN 'pipeline.step_started' THEN 'step_started'
               END AS kind,
               CASE e.kind
                   WHEN 'agent.tool_call' THEN jsonb_strip_nulls(jsonb_build_object(
                       'tool_call_id', left(e.payload->>'tool_call_id', 200),
                       'tool_kind', left(e.payload->>'kind', 64), 'status', left(e.payload->>'status', 64)))
                   WHEN 'agent.tool_call_update' THEN jsonb_strip_nulls(jsonb_build_object(
                       'tool_call_id', left(e.payload->>'tool_call_id', 200), 'status', left(e.payload->>'status', 64)))
                   WHEN 'agent.message' THEN jsonb_build_object('text', coalesce(e.payload->>'text', ''))
                   WHEN 'agent.plan' THEN jsonb_build_object('entries', (
                       SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                                  'content', left(x->>'content', 1000), 'status', left(x->>'status', 64)))), '[]'::jsonb)
                         FROM jsonb_array_elements(CASE WHEN jsonb_typeof(e.payload->'entries') = 'array'
                                                        THEN e.payload->'entries' ELSE '[]'::jsonb END) AS x
                        WHERE jsonb_typeof(x) = 'object'))
                   WHEN 'agent.turn_ended' THEN jsonb_strip_nulls(jsonb_build_object(
                       'stop_reason', left(e.payload->>'stop_reason', 64)))
                   WHEN 'run.state' THEN jsonb_build_object('state', public.project_run_state(e.payload->>'state'))
                   WHEN 'artifact.published' THEN jsonb_strip_nulls(jsonb_build_object(
                       'artifact_id', e.payload->>'artifact_id', 'name', left(e.payload->>'name', 200),
                       'version', e.payload->'version'))
                   WHEN 'pipeline.step_started' THEN jsonb_strip_nulls(jsonb_build_object(
                       'step', left(e.payload->>'step', 200)))
                   ELSE '{}'::jsonb
               END AS data
          FROM public.events e
         WHERE e.run_id = p_run AND e.project_id = p_project
           AND e.project_id IN (SELECT public.member_projects())
           AND e.kind IN ('agent.tool_call', 'agent.tool_call_update', 'agent.message', 'agent.plan',
                          'agent.turn_started', 'agent.turn_ended', 'run.state', 'run.log_truncated',
                          'artifact.published', 'pipeline.step_started')
         ORDER BY e.seq DESC
         LIMIT least(greatest(coalesce(p_limit, 200), 1), 501)) v
     ORDER BY v.seq $$;
REVOKE ALL ON FUNCTION project_run(uuid, uuid), project_run_tree(uuid, uuid),
    project_runs(uuid, uuid, uuid, integer), project_run_events(uuid, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION project_run(uuid, uuid), project_run_tree(uuid, uuid),
    project_runs(uuid, uuid, uuid, integer), project_run_events(uuid, uuid, integer) TO thinktin_member;
GRANT CREATE ON SCHEMA public TO thinktin_project_definer;
ALTER FUNCTION project_run(uuid, uuid) OWNER TO thinktin_project_definer;
ALTER FUNCTION project_run_tree(uuid, uuid) OWNER TO thinktin_project_definer;
ALTER FUNCTION project_runs(uuid, uuid, uuid, integer) OWNER TO thinktin_project_definer;
ALTER FUNCTION project_run_events(uuid, uuid, integer) OWNER TO thinktin_project_definer;
-- deploy-safe: 只收回上面临时给的 CREATE
REVOKE CREATE ON SCHEMA public FROM thinktin_project_definer;

-- 项目产出物的索引（没有 blob_key：下载由 worker 在同一句 SQL 里按 member_projects() 再核对，并取密钥）。
GRANT SELECT (id, user_id, instance_id, run_id, root_run_id, project_id, name, version, content_type, size, sha256,
              created_at) ON artifacts TO thinktin_member;
CREATE POLICY member_read ON artifacts FOR SELECT TO thinktin_member USING (project_id IN (SELECT member_projects()));

-- 租户收窄（WITH CHECK 不变）。项目行只有 worker 写得出（运行、授权：fill_space；收件箱：inbox_project_guard）；租户还是
-- 存活成员时，可以往自己的项目运行上追加事件（取消、打断），空间由 fill_space_from_run 从运行算，成员视图只显示白名单
-- 种类；退出以后看不到运行，追加被外键拒绝。
ALTER POLICY tenant ON runs
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));
ALTER POLICY tenant ON run_grants
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));
ALTER POLICY tenant ON events
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));
ALTER POLICY tenant ON approvals
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_id IN (SELECT member_projects())));
ALTER POLICY tenant ON artifacts USING (user_id = app_user_id() AND project_id IS NULL);
-- 回执按 subtype（不按 run_id 为空：run_id 是 ON DELETE SET NULL）；守卫保证回执带项目、不带运行。
ALTER POLICY tenant ON inbox_items
    USING (user_id = app_user_id() AND (project_id IS NULL OR project_receipt(subtype)
           OR project_id IN (SELECT member_projects())));

-- 租户对收件箱只改 read_at，改不了一条提醒指向的运行（守卫只在插入时从运行算项目）。
-- deploy-safe: 上一版的租户代码只写 read_at（inbox.rs mark_inbox_read / mark_inbox_unread / settle_*，instances.rs 删实例）
REVOKE UPDATE ON inbox_items FROM thinktin_app;
GRANT UPDATE (read_at) ON inbox_items TO thinktin_app;
-- 审批只由 worker 插入（approvals.rs create_approval）；租户只做决定（SELECT … FOR UPDATE 有列的 UPDATE 权限就够）。
-- deploy-safe: 上一版的租户代码不插审批，UPDATE 只写这四列（approvals.rs decide_approval）
REVOKE INSERT, UPDATE ON approvals FROM thinktin_app;
GRANT UPDATE (state, decided_option, decided_by, decided_at) ON approvals TO thinktin_app;

CREATE OR REPLACE FUNCTION inbox_project_guard() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    run_project uuid;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.project_id IS DISTINCT FROM OLD.project_id
           OR NEW.project_invite_id IS DISTINCT FROM OLD.project_invite_id
           OR NEW.subtype IS DISTINCT FROM OLD.subtype THEN
            RAISE EXCEPTION 'inbox_items project fields and subtype cannot change' USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    -- 先挡租户自己填的项目字段（错误码和 8.14 一样）。
    IF (NEW.project_id IS NOT NULL OR NEW.project_invite_id IS NOT NULL) AND current_user <> 'thinktin_worker' THEN
        RAISE EXCEPTION 'project fields in inbox_items are written by the server only'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NEW.run_id IS NOT NULL THEN
        -- 按调用者看得到的运行：租户看不到（退出了的项目里自己的运行）就拒绝，免得项目运行的提醒存成私人的。
        SELECT r.project_id INTO run_project FROM public.runs r WHERE r.id = NEW.run_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'inbox item refers to a run that is not visible' USING ERRCODE = 'foreign_key_violation';
        END IF;
        IF NEW.project_id IS NULL THEN
            NEW.project_id := run_project;
        ELSIF NEW.project_id IS DISTINCT FROM run_project THEN
            RAISE EXCEPTION 'inbox item project does not match its run' USING ERRCODE = 'check_violation';
        END IF;
        -- 项目运行的提醒（算出来的）也只有 worker 写得出。
        IF NEW.project_id IS NOT NULL AND current_user <> 'thinktin_worker' THEN
            RAISE EXCEPTION 'project fields in inbox_items are written by the server only'
                USING ERRCODE = 'insufficient_privilege';
        END IF;
    END IF;
    -- 回执按 subtype 绕过成员检查，所以必须带项目、不带运行（不然 worker 写错一条运行提醒，退出以后还看得到）。
    IF public.project_receipt(NEW.subtype) AND (NEW.run_id IS NOT NULL OR NEW.project_id IS NULL) THEN
        RAISE EXCEPTION 'project receipts carry a project and no run' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
