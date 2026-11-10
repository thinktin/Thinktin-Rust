-- 项目流水线（WBS 8.17）：创建者在 App 里建一条马上开始的流水线，每一步可以是项目里任何一个专属 botin（不分主人）。不用
-- plans/plan_steps/triggers（同一个用户的外键；0055 不让它们碰专属实例；老版本的调度器会去触发）。根运行（kind 'pipeline'、
-- source 'pipeline'，不带授权）挂在创建者自己的一个专属 botin 上；步骤开始以后不改，存成 jsonb（store 用 order_steps 核对），
-- 由 8.17 的驱动按依赖顺序经派单建子运行（每一步用那个 botin 自己在项目里的常设授权）。随根运行级联删掉。
CREATE TABLE project_pipelines (
    root_run_id uuid PRIMARY KEY REFERENCES runs (id) ON DELETE CASCADE,
    project_id  uuid NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
    title       text NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
    -- [{"key","instance_id","user_id","prompt","depends_on":[]}]，1–20 步
    steps       jsonb NOT NULL CHECK (jsonb_typeof(steps) = 'array' AND jsonb_array_length(steps) BETWEEN 1 AND 20),
    created_by  uuid NOT NULL REFERENCES users (id),
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX project_pipelines_project ON project_pipelines (project_id, root_run_id DESC);

-- 根运行是这个项目的流水线根运行，挂在创建者自己的 botin 上（成员读的策略只看 project_id）。
CREATE FUNCTION project_pipeline_root() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.runs r WHERE r.id = NEW.root_run_id AND r.project_id = NEW.project_id
                     AND r.kind = 'pipeline' AND r.parent_run_id IS NULL AND r.user_id = NEW.created_by) THEN
        RAISE EXCEPTION 'pipeline % does not match its root run', NEW.root_run_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'project_pipeline_root';
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION project_pipeline_root() FROM PUBLIC;
CREATE TRIGGER project_pipelines_root BEFORE INSERT ON project_pipelines
    FOR EACH ROW EXECUTE FUNCTION project_pipeline_root();

ALTER TABLE project_pipelines ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_pipelines FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT ON project_pipelines TO thinktin_worker;
GRANT SELECT (root_run_id, project_id, title, steps, created_by, created_at) ON project_pipelines TO thinktin_member;
CREATE POLICY member_read ON project_pipelines FOR SELECT TO thinktin_member
    USING (project_id IN (SELECT member_projects()));
