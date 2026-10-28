-- 工作区归档（没有工作区卷的沙箱后端，如 ACS，见 docs/sandbox-acs.md）：销毁沙箱前把工作区打包、
-- 按用户 DEK 加密存进对象存储，重建沙箱时放回。每个实例只记最新的一份。
ALTER TABLE instances
    ADD COLUMN workspace_archive_key text,
    ADD COLUMN workspace_archive_id uuid,
    ADD COLUMN workspace_archive_bytes bigint,
    ADD COLUMN workspace_archive_sha256 bytea,
    ADD COLUMN workspace_archived_at timestamptz,
    -- 正在上传的对象：上传前先记下，进程中途被杀时下一次归档会把它换掉（旧的排进清理队列）。
    -- 上传期间定时刷新时间：刷新着的别处不另起一份（一个实例同时只有一份在存），太久没刷新的算没人管了。
    ADD COLUMN workspace_archive_pending text,
    ADD COLUMN workspace_archive_pending_since timestamptz,
    -- 上一次归档失败（太大、打包出错、存储不通）：之后一段时间不再试，除非实例又被用过。
    ADD COLUMN workspace_archive_failed_at timestamptz,
    ADD COLUMN workspace_archive_error text,
    -- 当前沙箱是按哪个版本建的（换版本存不下工作区时退回这个版本）。
    ADD COLUMN sandbox_version text,
    -- 正在往新建的沙箱里放回归档：先记下沙箱 id（单独提交），放回时不锁实例，定时刷新时间；
    -- 太久没刷新的（进程中途被杀）巡检据此删掉它。
    ADD COLUMN restoring_sandbox_id text,
    ADD COLUMN restoring_since timestamptz;

-- 业务角色只写它要写的列（以前是整张表的 INSERT、UPDATE）：沙箱绑定、归档、放回这些列只有后台角色能写。
REVOKE INSERT, UPDATE ON instances FROM thinktin_app;
GRANT INSERT (id, user_id, agent_id, agent_version, harness, name, workspace_id, limits) ON instances TO thinktin_app;
GRANT UPDATE (name, state, agent_version, rebuild_pending, deleted_at, updated_at, event_seq, token_epoch)
    ON instances TO thinktin_app;

-- 换掉的归档、没用上的上传、删掉的实例：对象排进 blob_purge，由后台删除。
-- 触发器以表属主身份写队列（业务角色没有这张表的写权限），所以只收这一行的用户自己的归档
-- （`workspaces/<用户 id，不带连字符>/` 开头），别的键一律不排，免得被拿来删别人的对象。
CREATE FUNCTION queue_workspace_archive_purge() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    own text := 'workspaces/' || replace(OLD.user_id::text, '-', '') || '/';
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF starts_with(OLD.workspace_archive_key, own) THEN
            INSERT INTO blob_purge (blob_key) VALUES (OLD.workspace_archive_key) ON CONFLICT DO NOTHING;
        END IF;
        IF starts_with(OLD.workspace_archive_pending, own) THEN
            INSERT INTO blob_purge (blob_key) VALUES (OLD.workspace_archive_pending) ON CONFLICT DO NOTHING;
        END IF;
        RETURN OLD;
    END IF;
    IF starts_with(OLD.workspace_archive_key, own)
       AND OLD.workspace_archive_key IS DISTINCT FROM NEW.workspace_archive_key THEN
        INSERT INTO blob_purge (blob_key) VALUES (OLD.workspace_archive_key) ON CONFLICT DO NOTHING;
    END IF;
    -- 上传完成时待定的对象变成正式的，不删。
    IF starts_with(OLD.workspace_archive_pending, own)
       AND OLD.workspace_archive_pending IS DISTINCT FROM NEW.workspace_archive_pending
       AND OLD.workspace_archive_pending IS DISTINCT FROM NEW.workspace_archive_key THEN
        INSERT INTO blob_purge (blob_key) VALUES (OLD.workspace_archive_pending) ON CONFLICT DO NOTHING;
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION queue_workspace_archive_purge() FROM PUBLIC;
CREATE TRIGGER instances_workspace_archive_purge
    AFTER UPDATE OF workspace_archive_key, workspace_archive_pending OR DELETE ON instances
    FOR EACH ROW EXECUTE FUNCTION queue_workspace_archive_purge();
