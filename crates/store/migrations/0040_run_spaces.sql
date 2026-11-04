-- 运行、授权的空间（docs/projects-impl.md 第 1、3 条）：private（user_id）或 project（project_id）。父子运行、子授权、运行用的
-- 授权必须在同一个空间（0045 的复合外键）；空间由触发器从 project_id 算，建了就不能改；带 project_id 的行只有 thinktin_worker
-- 写得出（白名单：租户、迁移账号、超级用户、8.15 的新角色都会报 42501）。8.13 没有任何地方写 project_id；旧的 (x, user_id)
-- 外键照留，8.17 跨主人的运行树再删。
-- 回填在一个事务里改写 runs、run_grants 的每一行（ADD COLUMN 拿的 ACCESS EXCLUSIVE 锁到提交）。按 0039 的前提表还是空的；
-- 如果发布时库里已经有大量运行，先拆成：加列和触发器 → 分批回填 → CHECK NOT VALID / VALIDATE / SET NOT NULL。
CREATE FUNCTION fill_space() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.project_id IS DISTINCT FROM OLD.project_id OR NEW.user_id IS DISTINCT FROM OLD.user_id
           OR NEW.instance_id IS DISTINCT FROM OLD.instance_id OR NEW.space_kind IS DISTINCT FROM OLD.space_kind
           OR NEW.space_id IS DISTINCT FROM OLD.space_id THEN
            RAISE EXCEPTION '% cannot move between users, instances or projects', TG_TABLE_NAME
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.project_id IS NOT NULL AND current_user <> 'thinktin_worker' THEN
        RAISE EXCEPTION 'project rows in % are written by the server only', TG_TABLE_NAME
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    NEW.space_kind := CASE WHEN NEW.project_id IS NULL THEN 'private' ELSE 'project' END;
    NEW.space_id := coalesce(NEW.project_id, NEW.user_id);
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION fill_space() FROM PUBLIC;

ALTER TABLE runs ADD COLUMN project_id uuid, ADD COLUMN space_kind text NOT NULL DEFAULT 'private',
    ADD COLUMN space_id uuid;
ALTER TABLE run_grants ADD COLUMN project_id uuid, ADD COLUMN space_kind text NOT NULL DEFAULT 'private',
    ADD COLUMN space_id uuid;
-- 回填在建触发器之前（触发器不许改 space_id）；迁移账号受 FORCE 约束，临时去掉。
ALTER TABLE runs NO FORCE ROW LEVEL SECURITY;
ALTER TABLE run_grants NO FORCE ROW LEVEL SECURITY;
UPDATE runs SET space_id = user_id WHERE space_id IS NULL;
UPDATE run_grants SET space_id = user_id WHERE space_id IS NULL;
ALTER TABLE runs FORCE ROW LEVEL SECURITY;
ALTER TABLE run_grants FORCE ROW LEVEL SECURITY;
-- relay 只改 runs (not_before, updated_at)，不会触发 UPDATE OF 这几列。
CREATE TRIGGER runs_space BEFORE INSERT OR UPDATE OF project_id, space_kind, space_id, user_id, instance_id ON runs
    FOR EACH ROW EXECUTE FUNCTION fill_space();
CREATE TRIGGER run_grants_space BEFORE INSERT OR UPDATE OF project_id, space_kind, space_id, user_id, instance_id
    ON run_grants FOR EACH ROW EXECUTE FUNCTION fill_space();
-- deploy-safe: 上一版插入时不填 space_id，由 BEFORE INSERT 触发器 runs_space 填上（NOT NULL 在触发器之后检查）
ALTER TABLE runs ALTER COLUMN space_id SET NOT NULL,
    ADD CONSTRAINT runs_space CHECK (space_kind IN ('private', 'project') AND CASE space_kind
        WHEN 'private' THEN project_id IS NULL AND space_id = user_id
        ELSE project_id IS NOT NULL AND space_id = project_id END);
-- deploy-safe: 同上，run_grants_space 触发器填 space_id
ALTER TABLE run_grants ALTER COLUMN space_id SET NOT NULL,
    ADD CONSTRAINT run_grants_space CHECK (space_kind IN ('private', 'project') AND CASE space_kind
        WHEN 'private' THEN project_id IS NULL AND space_id = user_id
        ELSE project_id IS NOT NULL AND space_id = project_id END);
