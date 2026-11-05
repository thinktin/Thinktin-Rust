-- 项目邀请的发送记录（8.14 评审）：邀请人每天的上限、每个号码每天的通知数从这里数，不再数 project_invites。
-- project_invites 跟着项目级联删除：没人加入过的单人项目创建者自己就能删，删了再建、再邀请，两个 24 小时的计数就都清零了，
-- 一个账号一天能发无数条邀请推送。这张表不挂在项目上，只有 worker 读写；后台删掉两天前的（只用来数 24 小时），注销时删掉
-- 他发的和发给他号码的。
CREATE TABLE project_invite_sends (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    inviter_id    uuid NOT NULL REFERENCES users (id),
    -- 手机号邀请的号码（E.164）；链接邀请没有。
    invitee_phone text,
    -- 这一条给号码的主人发了通知。
    delivered     boolean NOT NULL DEFAULT false,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CHECK (invitee_phone IS NOT NULL OR NOT delivered)
);
CREATE INDEX project_invite_sends_inviter ON project_invite_sends (inviter_id, created_at);
CREATE INDEX project_invite_sends_phone ON project_invite_sends (invitee_phone, created_at) WHERE delivered;
CREATE INDEX project_invite_sends_created ON project_invite_sends (created_at);
ALTER TABLE project_invite_sends ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_invite_sends FORCE ROW LEVEL SECURITY;
-- 没有给 thinktin_app 的策略和权限（默认拒绝）。
-- UPDATE 只为了清理时 `FOR UPDATE SKIP LOCKED`（不等注销正在删的行）。
GRANT SELECT, INSERT, UPDATE, DELETE ON project_invite_sends TO thinktin_worker;

-- 不回填：0047 和这个迁移一起在第一次部署之前发布，线上还没有邀请。
