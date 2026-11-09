-- 项目看板（WBS 8.17，docs/projects.md 第 3、5 节）：归项目所有，成员和成员的 agent 读写。单独一张表：私人看板的老读法
-- （8.15 不按项目过滤、按 id 归档和删除、注销按用户删）碰不到它；租户没有任何权限。正文和运行的任务一样存明文（不按
-- docs/projects.md 第 3 节说的用项目密钥加密，8.17 文档里改）；删项目时成员马上读不到（member_projects()），后台按项目清理
-- （store project_lifecycle.rs）。退出、注销以后条目留着（作者显示已退出、已注销）。0056 第 2 行说的“8.17 的项目看板”
-- 不是 board_posts 了：board_posts 从 0060 起只收私人条目。
CREATE TABLE project_board_posts (
    id                 uuid PRIMARY KEY,                                  -- UUIDv7
    project_id         uuid NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
    author_user_id     uuid NOT NULL,                                     -- 写它的人，或写它的 agent 的主人
    author_instance_id uuid,
    run_id             uuid,
    by_agent           boolean NOT NULL,
    body               text NOT NULL CHECK (length(body) BETWEEN 1 AND 2000),
    tags               text[] NOT NULL DEFAULT '{}' CHECK (cardinality(tags) <= 8),
    created_at         timestamptz NOT NULL DEFAULT now(),
    archived_at        timestamptz,
    revived_at         timestamptz,
    -- 和私人看板（0025）一样的复合外键：实例、运行都是作者的。成员行退出、注销都不删（只记 left_at）。
    FOREIGN KEY (project_id, author_user_id) REFERENCES project_members (project_id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (author_instance_id, author_user_id) REFERENCES instances (id, user_id) ON DELETE SET NULL (author_instance_id),
    FOREIGN KEY (run_id, author_user_id) REFERENCES runs (id, user_id) ON DELETE SET NULL (run_id),
    CHECK (by_agent OR (run_id IS NULL AND author_instance_id IS NULL))
);
CREATE INDEX project_board_posts_live ON project_board_posts (project_id, id DESC) WHERE archived_at IS NULL;
CREATE INDEX project_board_posts_archived ON project_board_posts (project_id, id DESC) WHERE archived_at IS NOT NULL;
CREATE INDEX project_board_posts_archived_at ON project_board_posts (archived_at) WHERE archived_at IS NOT NULL;
CREATE INDEX project_board_posts_run ON project_board_posts (run_id) WHERE run_id IS NOT NULL;
CREATE INDEX project_board_posts_author ON project_board_posts (author_instance_id) WHERE author_instance_id IS NOT NULL;
CREATE INDEX project_board_posts_by_member ON project_board_posts (project_id, author_user_id, created_at) WHERE NOT by_agent;

-- agent 写的：运行在这个项目里（项目归属从运行派生，impl 第 1 条；主人、实例由上面的外键对上）。成员读的策略只看
-- project_id，所以这里核对。
CREATE FUNCTION project_board_post_run() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    IF NEW.by_agent AND (NEW.run_id IS NULL OR NOT EXISTS (
             SELECT 1 FROM public.runs r WHERE r.id = NEW.run_id AND r.project_id = NEW.project_id
                AND r.instance_id = NEW.author_instance_id)) THEN
        RAISE EXCEPTION 'board post does not match its run'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'project_board_post_run';
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION project_board_post_run() FROM PUBLIC;
CREATE TRIGGER project_board_posts_run BEFORE INSERT ON project_board_posts
    FOR EACH ROW EXECUTE FUNCTION project_board_post_run();

ALTER TABLE project_board_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_board_posts FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, DELETE ON project_board_posts TO thinktin_worker;
GRANT UPDATE (archived_at, revived_at) ON project_board_posts TO thinktin_worker;
GRANT SELECT (id, project_id, author_user_id, author_instance_id, run_id, by_agent, body, tags, created_at, archived_at)
    ON project_board_posts TO thinktin_member;
CREATE POLICY member_read ON project_board_posts FOR SELECT TO thinktin_member
    USING (project_id IN (SELECT member_projects()));
