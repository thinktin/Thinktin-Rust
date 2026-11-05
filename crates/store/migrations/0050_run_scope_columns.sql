-- 事件、审批、产出物的空间（docs/projects-impl.md 第 1 条：保留 (run_id, user_id) 外键，再加 scope 一致性外键）。
-- 空间不由调用方给：BEFORE INSERT 触发器按调用者看得到的运行算（租户看不到的——退出了的项目里自己的运行——算成私人，
-- 外键随即拒绝），建了不能改。项目运行的子行因此不用改写入方就带上项目。
-- 锁、前提同 0039：第一次部署之前发布，表是空的。三个外键都在这里直接加（不用 NOT VALID 再单独检查）：审批、产出物加列、
-- 回填已经拿着 ACCESS EXCLUSIVE 到提交；events 是分区表，PostgreSQL 16 本来就不支持分区表上的 NOT VALID 外键（扫描每个
-- 分区，events 和 runs 拿 SHARE ROW EXCLUSIVE 到提交）。有线上库时先看表多大，或者等 PostgreSQL 18。
-- 迁移账号受 FORCE 约束：回填、加外键时引用方和被引用方都临时去掉 FORCE（0040、0046 的做法）。

CREATE FUNCTION fill_space_from_run() RETURNS trigger LANGUAGE plpgsql
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
    NEW.space_kind := CASE WHEN NEW.project_id IS NULL THEN 'private' ELSE 'project' END;
    NEW.space_id := coalesce(NEW.project_id, NEW.user_id);
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION fill_space_from_run() FROM PUBLIC;

ALTER TABLE events ADD COLUMN project_id uuid, ADD COLUMN space_kind text NOT NULL DEFAULT 'private',
    ADD COLUMN space_id uuid;
ALTER TABLE approvals ADD COLUMN project_id uuid, ADD COLUMN space_kind text NOT NULL DEFAULT 'private',
    ADD COLUMN space_id uuid;
ALTER TABLE artifacts ADD COLUMN project_id uuid, ADD COLUMN space_kind text NOT NULL DEFAULT 'private',
    ADD COLUMN space_id uuid;

ALTER TABLE runs NO FORCE ROW LEVEL SECURITY;
ALTER TABLE events NO FORCE ROW LEVEL SECURITY;
ALTER TABLE approvals NO FORCE ROW LEVEL SECURITY;
ALTER TABLE artifacts NO FORCE ROW LEVEL SECURITY;
UPDATE events e SET project_id = r.project_id, space_kind = r.space_kind, space_id = r.space_id
  FROM runs r WHERE r.id = e.run_id;
UPDATE events SET space_id = user_id WHERE space_id IS NULL;            -- run_id 为空的（instance.state 等）
UPDATE approvals a SET project_id = r.project_id, space_kind = r.space_kind, space_id = r.space_id
  FROM runs r WHERE r.id = a.run_id;
UPDATE artifacts a SET project_id = r.project_id, space_kind = r.space_kind, space_id = r.space_id
  FROM runs r WHERE r.id = a.run_id;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM approvals WHERE space_id IS NULL) OR EXISTS (SELECT 1 FROM artifacts WHERE space_id IS NULL)
       OR EXISTS (SELECT 1 FROM events WHERE space_id IS NULL) THEN
        RAISE EXCEPTION 'scope backfill missed rows';
    END IF;
END $$;
ALTER TABLE events ADD CONSTRAINT events_run_space FOREIGN KEY (run_id, space_kind, space_id)
    REFERENCES runs (id, space_kind, space_id) ON DELETE CASCADE;
ALTER TABLE approvals ADD CONSTRAINT approvals_run_space FOREIGN KEY (run_id, space_kind, space_id)
    REFERENCES runs (id, space_kind, space_id) ON DELETE CASCADE;
ALTER TABLE artifacts ADD CONSTRAINT artifacts_run_space FOREIGN KEY (run_id, space_kind, space_id)
    REFERENCES runs (id, space_kind, space_id) ON DELETE CASCADE;
ALTER TABLE runs FORCE ROW LEVEL SECURITY;
ALTER TABLE events FORCE ROW LEVEL SECURITY;
ALTER TABLE approvals FORCE ROW LEVEL SECURITY;
ALTER TABLE artifacts FORCE ROW LEVEL SECURITY;

-- 回填之后才建触发器（触发器不许改 space_id）。分区表的触发器会复制到已有和以后的分区。payload 等别的列不在 UPDATE OF 里。
CREATE TRIGGER events_space BEFORE INSERT OR UPDATE OF project_id, space_kind, space_id, user_id, run_id
    ON events FOR EACH ROW EXECUTE FUNCTION fill_space_from_run();
CREATE TRIGGER approvals_space BEFORE INSERT OR UPDATE OF project_id, space_kind, space_id, user_id, run_id
    ON approvals FOR EACH ROW EXECUTE FUNCTION fill_space_from_run();
CREATE TRIGGER artifacts_space BEFORE INSERT OR UPDATE OF project_id, space_kind, space_id, user_id, run_id
    ON artifacts FOR EACH ROW EXECUTE FUNCTION fill_space_from_run();
-- deploy-safe: 上一版插入时不填 space_id，由 BEFORE INSERT 触发器 events_space 填上
ALTER TABLE events ALTER COLUMN space_id SET NOT NULL,
    ADD CONSTRAINT events_space CHECK (space_kind IN ('private', 'project') AND CASE space_kind
        WHEN 'private' THEN project_id IS NULL AND space_id = user_id
        ELSE project_id IS NOT NULL AND space_id = project_id END);
-- deploy-safe: 同上，approvals_space 触发器
ALTER TABLE approvals ALTER COLUMN space_id SET NOT NULL,
    ADD CONSTRAINT approvals_space CHECK (space_kind IN ('private', 'project') AND CASE space_kind
        WHEN 'private' THEN project_id IS NULL AND space_id = user_id
        ELSE project_id IS NOT NULL AND space_id = project_id END);
-- deploy-safe: 同上，artifacts_space 触发器
ALTER TABLE artifacts ALTER COLUMN space_id SET NOT NULL,
    ADD CONSTRAINT artifacts_space CHECK (space_kind IN ('private', 'project') AND CASE space_kind
        WHEN 'private' THEN project_id IS NULL AND space_id = user_id
        ELSE project_id IS NOT NULL AND space_id = project_id END);
