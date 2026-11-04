-- 邀请与加入（WBS 8.14，docs/projects.md 第 4、9 节，docs/projects-impl.md“受邀加入”，progress/drafts/projects-8.14-plan.md）。
-- 沿用 0039：跨用户的写（建邀请、接受、拒绝、撤回邀请、加入、增派、撤回 agent、退出、移出、拉黑）只走 thinktin_worker，
-- 动作人由服务端从登录态得到；这里不给 thinktin_app 新的表权限，只多一个 projects.goal 的 INSERT 列权限（自己建单人项目时
-- 写目标；改目标走 worker）。邀请相关的表 8.13 才建、8.14 之前没有接口写过，加列、建索引都放在这一个事务里。
-- 锁：这个事务从建 user_blocks（外键）起拿着 users 的 SHARE ROW EXCLUSIVE，从改 inbox_items 起拿着它的 ACCESS EXCLUSIVE，
-- 都到提交。按 0039 的前提（第一次部署之前发布、没有流量）没问题；如果发布时已经有线上库，拆成两个迁移（user_blocks 一个、
-- inbox_items 一个），各自开头 SET LOCAL lock_timeout = '5s'，等不到就失败重跑。

-- 拉黑（第 4、9 节）：被拉黑的人再发来的手机号邀请照样“发出”（接口结果一样），但不送达、不通知、到期变“已过期”，
-- 免得被用来探测“有没有被拉黑”。只有 worker 读写；列表经接口给出（对方的 id 和显示名）。
CREATE TABLE user_blocks (
    blocker_id uuid NOT NULL REFERENCES users (id),
    blocked_id uuid NOT NULL REFERENCES users (id),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (blocker_id, blocked_id),
    CHECK (blocker_id <> blocked_id)
);
CREATE INDEX user_blocks_blocked ON user_blocks (blocked_id);   -- 注销时按被拉黑的人删
ALTER TABLE user_blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_blocks FORCE ROW LEVEL SECURITY;
-- 没有给 thinktin_app 的策略和权限（默认拒绝）。0001 的 ON ALL TABLES 只覆盖当时的表。
GRANT SELECT, INSERT, DELETE ON user_blocks TO thinktin_worker;

-- 不送达（只有手机号邀请）：对方拉黑了邀请人——发的时候已经拉黑，或者之后拉黑时把还没处理的标上。对邀请人照样是
-- “待接受”、到期“已过期”；被邀请人看不到、接受不了。
-- invitee_id（0039）从这一版起表示“通知送达了谁”：号码已注册、对方没拉黑邀请人、不是现有成员、这个号码 24 小时内收到的
-- 通知没到上限才填；接口从不给邀请人看。通知到了上限的邀请照样有效（被邀请人在 App 里按手机号看得到、接受得了），只是
-- 不推送：不能因为别人先发满了，就让这个号码当天真正的邀请悄悄消失。
ALTER TABLE project_invites
    ADD COLUMN suppressed_at timestamptz,
    ADD CONSTRAINT project_invites_suppressed CHECK (suppressed_at IS NULL OR kind = 'phone');
-- 同一个项目同一个号码只留一条待处理的（重复邀请返回原来那条，不多数一次）。
CREATE UNIQUE INDEX project_invites_one_pending ON project_invites (project_id, invitee_phone)
    WHERE status = 'pending' AND kind = 'phone';
-- 一个号码 24 小时收到了几条通知（送达的才算；0039 的 project_invites_phone 只含待处理的）。
CREATE INDEX project_invites_delivered_day ON project_invites (invitee_phone, created_at)
    WHERE invitee_id IS NOT NULL;
-- 后台：到期的标成过期、结束 30 天的删掉（明文手机号不久留）；注销时按接受人删。
CREATE INDEX project_invites_expiry ON project_invites (expires_at) WHERE status = 'pending';
CREATE INDEX project_invites_settled ON project_invites (settled_at) WHERE status <> 'pending';
CREATE INDEX project_invites_accepted_by ON project_invites (accepted_by) WHERE accepted_by IS NOT NULL;

-- 成员（不是创建者）派 agent 进来时确认“项目内容会发给项目里各 agent 用的模型厂商”的时间：加入、增派各记各的。
ALTER TABLE project_agents ADD COLUMN consented_at timestamptz;

-- 收件箱、推送的跳转目标（邀请、加入、退出回执，docs/projects-impl.md 第 6 条）。不加外键（同 vault_request_id、
-- egress_request_id）：项目删了、邀请清理了，回执照样留着，打开时接口回 404。
ALTER TABLE inbox_items ADD COLUMN project_id uuid, ADD COLUMN project_invite_id uuid;
-- 这两列和 subtype 由服务端写（第 1 条：项目归属由服务端派生，更新时不可改）：租户对 inbox_items 有整表的 INSERT、UPDATE
-- （0001），所以靠触发器挡。带项目字段的行只有 thinktin_worker 写得出（白名单，同 0040 的 fill_space）；建了以后谁都不能改
-- 这三列。现有的 UPDATE 只改 read_at，外键的 ON DELETE SET NULL (run_id) 也不在 UPDATE OF 里，都不受影响。
-- 8.15：从运行算 project_id 的逻辑并进这个函数（CREATE OR REPLACE），和传入的不一致就报错；按成员关系收窄读策略时，回执按
-- subtype（回执那几种，已不可改）放行，不能按 run_id 为空放行（run_id 是 ON DELETE SET NULL，运行清掉以后项目运行的通知
-- 也会变成 run_id 为空）。
CREATE FUNCTION inbox_project_guard() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.project_id IS DISTINCT FROM OLD.project_id
           OR NEW.project_invite_id IS DISTINCT FROM OLD.project_invite_id
           OR NEW.subtype IS DISTINCT FROM OLD.subtype THEN
            RAISE EXCEPTION 'inbox_items project fields and subtype cannot change'
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF (NEW.project_id IS NOT NULL OR NEW.project_invite_id IS NOT NULL)
       AND current_user <> 'thinktin_worker' THEN
        RAISE EXCEPTION 'project fields in inbox_items are written by the server only'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION inbox_project_guard() FROM PUBLIC;
CREATE TRIGGER inbox_project_guard BEFORE INSERT OR UPDATE OF project_id, project_invite_id, subtype
    ON inbox_items FOR EACH ROW EXECUTE FUNCTION inbox_project_guard();

-- 自己建单人项目时写目标（POST /v1/projects，租户事务，策略 tenant_insert 不变）。
GRANT INSERT (goal) ON projects TO thinktin_app;
