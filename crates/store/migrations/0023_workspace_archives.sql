-- 工作区归档（没有工作区卷的沙箱后端，如 ACS，见 docs/sandbox-acs.md）：销毁沙箱前把工作区打包、
-- 按用户 DEK 加密存进对象存储，重建沙箱时放回。每个实例只记最新的一份。
ALTER TABLE instances
    ADD COLUMN workspace_archive_key text,
    ADD COLUMN workspace_archive_id uuid,
    ADD COLUMN workspace_archive_bytes bigint,
    ADD COLUMN workspace_archive_sha256 bytea,
    ADD COLUMN workspace_archived_at timestamptz,
    -- 正在上传的对象：上传前先记下，进程中途被杀时下一次归档会把它换掉（旧的排进清理队列）。
    ADD COLUMN workspace_archive_pending text;

-- 换掉的归档、没用上的上传、删掉的实例：对象排进 blob_purge，由后台删除。
-- 触发器以表属主身份写队列（业务角色没有这张表的写权限）。
CREATE FUNCTION queue_workspace_archive_purge() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.workspace_archive_key IS NOT NULL THEN
            INSERT INTO blob_purge (blob_key) VALUES (OLD.workspace_archive_key) ON CONFLICT DO NOTHING;
        END IF;
        IF OLD.workspace_archive_pending IS NOT NULL THEN
            INSERT INTO blob_purge (blob_key) VALUES (OLD.workspace_archive_pending) ON CONFLICT DO NOTHING;
        END IF;
        RETURN OLD;
    END IF;
    IF OLD.workspace_archive_key IS NOT NULL
       AND OLD.workspace_archive_key IS DISTINCT FROM NEW.workspace_archive_key THEN
        INSERT INTO blob_purge (blob_key) VALUES (OLD.workspace_archive_key) ON CONFLICT DO NOTHING;
    END IF;
    -- 上传完成时待定的对象变成正式的，不删。
    IF OLD.workspace_archive_pending IS NOT NULL
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
