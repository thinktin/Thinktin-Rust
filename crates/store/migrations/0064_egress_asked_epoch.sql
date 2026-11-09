-- 出口代理问用户时带上通过验证的令牌代数（WBS 8.17，8.16 复核留下的）：目录缓存还有效的几秒里，旧沙箱（运行结束、换了
-- 工作区）的提问不能记成新工作区的。代数和工作区在同一句里读（换工作区在同一个 UPDATE 里改两样）。上一版的出口代理不填，
-- 照旧放行；再问时没带代数（上一版的出口代理）沿用的旧代数过时了就当“不知道”。
ALTER TABLE egress_requests ADD COLUMN asked_epoch bigint;
-- deploy-safe: 新列，上一版的出口代理不写它（INSERT 的列权限 0034 已经是整行）。
GRANT UPDATE (asked_epoch) ON egress_requests TO thinktin_llmgw;
-- deploy-safe: 只在带了代数、和实例现在的不一样时拒绝；上一版的出口代理不带，沿用的旧代数过时了清空（照旧放行，同 0059）。
CREATE OR REPLACE FUNCTION egress_request_workspace() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    ws text;
    ep bigint;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.asked_at IS NOT DISTINCT FROM OLD.asked_at THEN
        NEW.workspace_id := OLD.workspace_id;
        NEW.asked_epoch := OLD.asked_epoch;
        RETURN NEW;
    END IF;
    SELECT i.workspace_id, i.token_epoch INTO ws, ep FROM public.instances i WHERE i.id = NEW.instance_id;
    -- 这次没带代数、沿用的是上一次问的：过时了就当“不知道”。
    IF TG_OP = 'UPDATE' AND NEW.asked_epoch IS NOT DISTINCT FROM OLD.asked_epoch
       AND NEW.asked_epoch IS DISTINCT FROM ep THEN
        NEW.asked_epoch := NULL;
    END IF;
    IF NEW.asked_epoch IS NOT NULL AND NEW.asked_epoch <> ep THEN
        RAISE EXCEPTION 'egress ask from an outdated sandbox token'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'egress_stale_token';
    END IF;
    NEW.workspace_id := ws;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION egress_request_workspace() FROM PUBLIC;
