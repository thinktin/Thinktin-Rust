-- 8.16 对抗评审的两处修复（docs/progress/drafts/projects-8.16-review.md）。

-- 1. 标成专属时，没结束的流水线里还有一步在这个实例上也算“还有别的事”：计划暂停着、流水线照样往下走，走到这一步时
--    私人的运行进不了专属实例。和 store 的 free_instance_check 一致。
CREATE OR REPLACE FUNCTION instances_dedicated_alone() RETURNS trigger LANGUAGE plpgsql
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
                         OR p.id IN (SELECT s.plan_id FROM public.plan_steps s WHERE s.instance_id = NEW.id)))
       OR EXISTS (SELECT 1 FROM public.runs r JOIN public.plan_steps s ON s.plan_id = r.plan_id
                   WHERE r.kind = 'pipeline' AND r.state NOT IN ('succeeded', 'failed', 'cancelled')
                     AND s.instance_id = NEW.id) THEN
        RAISE EXCEPTION 'instance % still has other work', NEW.id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'instance_not_free';
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION instances_dedicated_alone() FROM PUBLIC;

-- 2. 出网请求记下是在哪个工作区里问的（最后一次问的那个）：换工作区（标专属、放回私人、项目删了）时被用户锁着、没删掉的
--    请求，之后再“一直允许”也不能把网站加进新的工作区。建的时候、同一个网站再问的时候按实例现在的工作区填（建、再问的
--    只有出口代理和后台，它们都读得到实例；不用表属主身份：FORCE 行级安全下属主一行都看不到）。别的更新不能改它。
--    老的行是空的，按“不知道”放行（和以前一样）。
ALTER TABLE egress_requests ADD COLUMN workspace_id text;
CREATE FUNCTION egress_request_workspace() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.asked_at IS NOT DISTINCT FROM OLD.asked_at THEN
        NEW.workspace_id := OLD.workspace_id;
        RETURN NEW;
    END IF;
    NEW.workspace_id := (SELECT i.workspace_id FROM public.instances i WHERE i.id = NEW.instance_id);
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION egress_request_workspace() FROM PUBLIC;
CREATE TRIGGER egress_requests_workspace BEFORE INSERT OR UPDATE ON egress_requests
    FOR EACH ROW EXECUTE FUNCTION egress_request_workspace();
