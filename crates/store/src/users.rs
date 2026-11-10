//! 用户（4.1）。登录发生在有租户之前，所以建号、按手机号查找只在后台角色上。

use chrono::{DateTime, Utc};
use proto::domain::{Locale, User, UserId, UserStatus};
use uuid::Uuid;

use crate::{Result, Tenant, Tx, Worker, parse, unsigned};

#[derive(sqlx::FromRow)]
struct Row {
    id: Uuid,
    phone: String,
    display_name: Option<String>,
    status: String,
    locale: String,
    created_at: DateTime<Utc>,
}

impl Row {
    fn into_user(self) -> Result<User> {
        Ok(User {
            id: self.id.into(),
            phone: self.phone,
            display_name: self.display_name,
            status: parse(&self.status)?,
            locale: parse(&self.locale)?,
            created_at: self.created_at,
        })
    }
}

macro_rules! columns {
    () => {
        "id, phone, display_name, status, locale, created_at"
    };
}

impl Tx<Worker> {
    /// 按手机号（已规范化的 E.164）找到账号，没有就新建。返回账号和是否新建。
    /// 冻结的账号照样返回，由调用方决定能不能登录。
    pub async fn upsert_user_by_phone(&mut self, phone: &str) -> Result<(User, bool)> {
        let inserted: Option<Row> = sqlx::query_as(concat!(
            "INSERT INTO users (id, phone) VALUES ($1, $2) \
             ON CONFLICT (phone) WHERE status <> 'deleted' DO NOTHING \
             RETURNING ",
            columns!()
        ))
        .bind(UserId::new().0)
        .bind(phone)
        .fetch_optional(self.conn())
        .await?;
        if let Some(row) = inserted {
            return Ok((row.into_user()?, true));
        }
        // 并发插入时 DO NOTHING 会等对方提交；读已提交隔离级别下这里能看到对方的行。
        let row: Row = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM users WHERE phone = $1 AND status <> 'deleted'"
        ))
        .bind(phone)
        .fetch_one(self.conn())
        .await?;
        Ok((row.into_user()?, false))
    }

    /// 按手机号（已规范化的 E.164）找没注销的账号。
    pub async fn user_by_phone(&mut self, phone: &str) -> Result<Option<User>> {
        let row: Option<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM users WHERE phone = $1 AND status <> 'deleted'"
        ))
        .bind(phone)
        .fetch_optional(self.conn())
        .await?;
        row.map(Row::into_user).transpose()
    }

    pub async fn user(&mut self, id: UserId) -> Result<User> {
        let row: Row = sqlx::query_as(concat!("SELECT ", columns!(), " FROM users WHERE id = $1"))
            .bind(id.0)
            .fetch_one(self.conn())
            .await?;
        row.into_user()
    }

    /// 先锁住用户行再读（冻结账号）。改状态的 UPDATE 拿的是 `FOR NO KEY UPDATE`，挡不住项目派单读目标主人状态时拿的
    /// `FOR KEY SHARE`；这里的 `FOR UPDATE` 挡得住：在途的派单先提交（冻结接着取消运行时看得到它建的），之后的派单等
    /// 这里提交、看到新状态。和“全部停止”（[`Tx::mark_stopped_all`]）、注销一样先锁用户行、再锁运行。
    pub async fn lock_user(&mut self, id: UserId) -> Result<User> {
        let row: Row = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM users WHERE id = $1 FOR UPDATE"
        ))
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        row.into_user()
    }

    /// 冻结、解冻、注销。
    pub async fn set_user_status(&mut self, id: UserId, status: UserStatus) -> Result<()> {
        let done = sqlx::query(
            "UPDATE users SET status = $2, \
               frozen_at = CASE WHEN $2 = 'frozen' THEN now() ELSE NULL END, \
               deleted_at = CASE WHEN $2 = 'deleted' THEN now() ELSE deleted_at END \
             WHERE id = $1 AND status <> 'deleted'",
        )
        .bind(id.0)
        .bind(status.as_str())
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            return Err(crate::Error::NotFound);
        }
        Ok(())
    }
}

/// 运维查看账号（4.6）：给客服用的概况，不含对话内容。
#[derive(Debug, Clone)]
pub struct AccountSummary {
    pub user: User,
    /// 没下线的设备。
    pub devices: u64,
    /// 没删除的实例。
    pub instances: u64,
    /// 没结束的运行。
    pub active_runs: u64,
    /// 在用的计划。
    pub active_plans: u64,
    /// 有效的运行授权。
    pub active_grants: u64,
    /// 最近一次登录。
    pub last_login_at: Option<DateTime<Utc>>,
}

impl Tx<Worker> {
    pub async fn account_summary(&mut self, id: UserId) -> Result<AccountSummary> {
        let user = self.user(id).await?;
        let (devices, instances, runs, plans, grants, last_login): (
            i64,
            i64,
            i64,
            i64,
            i64,
            Option<DateTime<Utc>>,
        ) = sqlx::query_as(
            "SELECT \
               (SELECT count(*) FROM devices WHERE user_id = $1 AND revoked_at IS NULL), \
               (SELECT count(*) FROM instances WHERE user_id = $1 AND state <> 'deleted'), \
               (SELECT count(*) FROM runs WHERE user_id = $1 \
                  AND state NOT IN ('succeeded', 'failed', 'cancelled')), \
               (SELECT count(*) FROM plans WHERE user_id = $1 AND status = 'active'), \
               (SELECT count(*) FROM run_grants WHERE user_id = $1 AND revoked_at IS NULL \
                  AND expires_at > now()), \
               (SELECT max(created_at) FROM sessions WHERE user_id = $1)",
        )
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        Ok(AccountSummary {
            user,
            devices: unsigned(devices, "device count")?,
            instances: unsigned(instances, "instance count")?,
            active_runs: unsigned(runs, "run count")?,
            active_plans: unsigned(plans, "plan count")?,
            active_grants: unsigned(grants, "grant count")?,
            last_login_at: last_login,
        })
    }
}

impl Tx<Worker> {
    /// 保存用户的包裹 DEK（第一次存 key 时由密钥库生成）。已经有了返回冲突。
    pub async fn insert_user_key(
        &mut self,
        user: UserId,
        kms_key_id: &str,
        wrapped_dek: &[u8],
    ) -> Result<()> {
        sqlx::query("INSERT INTO user_keys (user_id, kms_key_id, wrapped_dek) VALUES ($1, $2, $3)")
            .bind(user.0)
            .bind(kms_key_id)
            .bind(wrapped_dek)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 注销（16.4）：销毁用户的 DEK（key、保险箱和产出物的密文从此解不开），删掉用户的内容
    /// （运行、提示词、摘要、事件、收件箱、计划、审批、团队和他建的项目、保险箱、产出物索引、推送记录、
    /// 电脑工具的调用和手机电脑之间的消息；产出物的密文排进清理队列，由后台从对象存储删掉），
    /// 手机号和设备信息去标识化，实例标记删除（沙箱和工作区卷由巡检回收）。
    /// 审计日志和用量记录只有 id 和计数，按网络日志的要求保留。
    pub async fn erase_account(&mut self, id: UserId) -> Result<()> {
        // 先锁住用户行：和正在给这个用户插数据的事务（调度器建运行、API 请求）互斥。
        // 外键检查拿的是 KEY SHARE 锁，这里的 FOR UPDATE 会等它们提交，后面的删除能看到它们的行。
        sqlx::query("SELECT 1 FROM users WHERE id = $1 FOR UPDATE")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        // 再拿下面要改到的项目的锁：他建的、加入过的、派过 agent 的（离开了的也算：下面也改离开的 agent 行）、和他有关的
        // 邀请所在的。自己改团队（租户事务先改 projects 再改 project_agents）和下面的注销（先改 project_agents 再删
        // projects）方向相反；两个人同时注销时，一个删项目级联到邀请、成员行，另一个改自己离开了的 agent 行、删发给自己的
        // 邀请。不排队都会互相等。
        let mut projects: Vec<proto::domain::ProjectId> = sqlx::query_scalar::<_, uuid::Uuid>(
            "SELECT id FROM projects WHERE creator_id = $1 \
             UNION SELECT project_id FROM project_members WHERE user_id = $1 \
             UNION SELECT project_id FROM project_agents WHERE user_id = $1 \
             UNION SELECT project_id FROM project_invites WHERE inviter_id = $1 OR invitee_id = $1 \
                     OR accepted_by = $1 OR invitee_phone = (SELECT phone FROM users WHERE id = $1)",
        )
        .bind(id.0)
        .fetch_all(self.conn())
        .await?
        .into_iter()
        .map(Into::into)
        .collect();
        self.lock_projects(&mut projects).await?;
        // 他建的项目（8.15）：软删除（马上谁都读不到、密钥删掉），停掉里面的运行和授权，别人的项目提醒标已读（不等锁）。
        // 8.15 不给别的成员发回执（写别人的收件箱要先锁他们的用户行，会和他们自己注销互相等；8.19 由后台补）。
        let created: Vec<proto::domain::ProjectId> = sqlx::query_scalar::<_, uuid::Uuid>(
            "SELECT id FROM projects WHERE creator_id = $1 AND status <> 'deleted' ORDER BY id",
        )
        .bind(id.0)
        .fetch_all(self.conn())
        .await?
        .into_iter()
        .map(Into::into)
        .collect();
        for p in created {
            sqlx::query(
                "UPDATE projects SET status = 'deleted', deleted_at = now(), updated_at = now() WHERE id = $1",
            )
            .bind(p.0)
            .execute(self.conn())
            .await?;
            sqlx::query("DELETE FROM project_keys WHERE project_id = $1")
                .bind(p.0)
                .execute(self.conn())
                .await?;
            self.stop_project(p, "account_deleted", true).await?;
            // 别的成员专属于它的实例换成全新的私人工作区（8.16；锁着的由后台清理兜底）。
            self.retire_project_workspaces(p).await?;
            let others: Vec<UserId> = sqlx::query_scalar::<_, uuid::Uuid>(
                "SELECT user_id FROM project_members WHERE project_id = $1 AND left_at IS NULL AND user_id <> $2",
            )
            .bind(p.0)
            .bind(id.0)
            .fetch_all(self.conn())
            .await?
            .into_iter()
            .map(UserId)
            .collect();
            self.read_project_notices(p, &others, true).await?;
        }
        // 他的 agent 离开所有项目（D3：项目 agent 行在运行之前）。
        sqlx::query(
            "UPDATE project_agents SET is_lead = false, dedicated = false, left_at = coalesce(left_at, now()) \
              WHERE user_id = $1",
        )
        .bind(id.0)
        .execute(self.conn())
        .await?;
        self.cancel_user_runs(id, "account_deleted").await?;
        self.set_user_status(id, UserStatus::Deleted).await?;
        self.revoke_user_sessions(id, "account_deleted").await?;
        self.revoke_user_grants(id, "account_deleted").await?;
        // 他在别人项目里做的事（8.15）：运行、白名单里的事件、项目产出物留给项目里的人（主人显示“已注销”）；白名单以外的
        // 事件删掉，留下的事件只留白名单里的字段，运行的失败原因清掉；审批、工具调用、灵动岛删掉。
        sqlx::query(
            "DELETE FROM events WHERE instance_id IN (SELECT id FROM instances WHERE user_id = $1) \
               AND (project_id IS NULL OR NOT (kind = ANY($2)))",
        )
        .bind(id.0)
        .bind(&proto::domain::PROJECT_RUN_EVENT_KINDS[..])
        .execute(self.conn())
        .await?;
        for sql in [
            "DELETE FROM user_keys WHERE user_id = $1",
            "UPDATE credentials SET deleted_at = coalesce(deleted_at, now()), disabled = true, \
               sealed = ''::bytea, label = '', anthropic_base = NULL, openai_base = NULL, \
               responses_base = NULL, updated_at = now() WHERE user_id = $1",
            "DELETE FROM model_routes WHERE user_id = $1",
            "DELETE FROM approvals WHERE run_id IN (SELECT id FROM runs WHERE user_id = $1 AND project_id IS NOT NULL)",
            "DELETE FROM tool_calls WHERE run_id IN (SELECT id FROM runs WHERE user_id = $1 AND project_id IS NOT NULL)",
            "DELETE FROM live_activities WHERE user_id = $1",
            "UPDATE runs SET error = NULL, state_reason = NULL WHERE user_id = $1 AND project_id IS NOT NULL",
            "UPDATE events SET payload = CASE kind \
                 WHEN 'agent.tool_call' THEN jsonb_strip_nulls(jsonb_build_object('tool_call_id', payload->'tool_call_id', \
                      'kind', payload->'kind', 'status', payload->'status')) \
                 WHEN 'agent.tool_call_update' THEN jsonb_strip_nulls(jsonb_build_object( \
                      'tool_call_id', payload->'tool_call_id', 'status', payload->'status')) \
                 WHEN 'agent.message' THEN jsonb_strip_nulls(jsonb_build_object('text', payload->'text')) \
                 WHEN 'agent.plan' THEN jsonb_strip_nulls(jsonb_build_object('entries', payload->'entries')) \
                 WHEN 'agent.turn_ended' THEN jsonb_strip_nulls(jsonb_build_object('stop_reason', payload->'stop_reason')) \
                 WHEN 'run.state' THEN jsonb_strip_nulls(jsonb_build_object('state', payload->'state')) \
                 WHEN 'artifact.published' THEN jsonb_strip_nulls(jsonb_build_object( \
                      'artifact_id', payload->'artifact_id', 'name', payload->'name', 'version', payload->'version')) \
                 WHEN 'pipeline.step_started' THEN jsonb_strip_nulls(jsonb_build_object('step', payload->'step')) \
                 ELSE '{}'::jsonb END \
              WHERE instance_id IN (SELECT id FROM instances WHERE user_id = $1) AND project_id IS NOT NULL",
            // 私人运行删了，审批、产出物、带运行的事件一起级联删掉（产出物的密文排进 blob_purge）。
            "DELETE FROM runs WHERE user_id = $1 AND project_id IS NULL",
            // 计划删了，触发器、流水线步骤级联删掉。
            "DELETE FROM plan_hooks WHERE user_id = $1",
            "DELETE FROM plans WHERE user_id = $1",
            "DELETE FROM inbox_items WHERE user_id = $1",
            // 举报里复制了被举报的内容（运行的提问、事件）。
            "DELETE FROM content_reports WHERE user_id = $1",
            // 送达的也删：载荷里有推送的标题和正文（运行摘要、工具调用标题）。
            "DELETE FROM outbox WHERE user_id = $1",
            // 8.13 以前的团队（复制进项目以后冻结的旧表）。
            "DELETE FROM teams WHERE user_id = $1",
            "DELETE FROM team_templates WHERE user_id = $1",
            // 他发出、还没处理的邀请：收件人那边的提醒标已读（邀请下面就删了，留着就一直未读、点开 404）。别人的收件箱
            // 不等锁（D3）。
            "UPDATE inbox_items SET read_at = now() WHERE id IN (SELECT id FROM inbox_items \
               WHERE user_id IN (SELECT invitee_id FROM project_invites WHERE inviter_id = $1 \
                                   AND status = 'pending' AND invitee_id IS NOT NULL) \
                 AND project_invite_id IN (SELECT id FROM project_invites WHERE inviter_id = $1 \
                                             AND status = 'pending') \
                 AND read_at IS NULL FOR UPDATE SKIP LOCKED)",
            // 邀请的发送记录（数上限用，8.14）：发给他号码的删掉；他发的只去掉是谁发的（照样算进对方号码的通知数，
            // 两天后后台删掉）。
            "DELETE FROM project_invite_sends WHERE invitee_phone = (SELECT phone FROM users WHERE id = $1)",
            "UPDATE project_invite_sends SET inviter_id = NULL WHERE inviter_id = $1",
            // 项目：他在别人项目里的成员身份标成注销，早就退出、被移出的也一样（留下的内容显示“已注销”，退出时间不变；
            // 他建的项目上面已经软删除，创建者那一行留到后台清理）；发给他的、他发的邀请删掉（手机号邀请在改掉手机号之前
            // 按号码找）。
            "UPDATE project_members SET left_at = coalesce(left_at, now()), left_reason = 'erased' \
               WHERE user_id = $1 AND role = 'member'",
            "DELETE FROM project_invites WHERE inviter_id = $1 OR invitee_id = $1 OR accepted_by = $1 \
               OR invitee_phone = (SELECT phone FROM users WHERE id = $1)",
            // 拉黑（8.14）：他拉黑的、拉黑他的。
            "DELETE FROM user_blocks WHERE blocker_id = $1 OR blocked_id = $1",
            "DELETE FROM project_templates WHERE user_id = $1",
            "DELETE FROM vault_requests WHERE user_id = $1",
            "DELETE FROM vault_items WHERE user_id = $1",
            // IM 群机器人的 token 和签名密钥（10.5）。
            "DELETE FROM im_channels WHERE user_id = $1",
            // 电脑工具的参数和结果（文件内容、截图）、手机和电脑之间的消息、电脑的在线状态（14.1）。
            "DELETE FROM device_calls WHERE user_id = $1",
            "DELETE FROM device_messages WHERE user_id = $1",
            "DELETE FROM device_links WHERE user_id = $1",
            // 共享看板（8.10）：agent 和用户写的进展、决定。
            "DELETE FROM board_posts WHERE user_id = $1",
            "UPDATE instances SET state = 'deleted', name = '', purpose = '', egress_mode = 'model', egress_hosts = '{}', deleted_at = coalesce(deleted_at, now()), \
               updated_at = now() WHERE user_id = $1",
            "UPDATE devices SET name = '', push_channel = NULL, push_token = NULL, activity_start_token = NULL WHERE user_id = $1",
            "UPDATE users SET phone = 'deleted', display_name = NULL WHERE id = $1",
        ] {
            sqlx::query(sql).bind(id.0).execute(self.conn()).await?;
        }
        Ok(())
    }
}

impl Tx<Tenant> {
    /// 当前用户自己。
    pub async fn me(&mut self) -> Result<User> {
        let row: Row = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM users WHERE id = app_user_id()"
        ))
        .fetch_one(self.conn())
        .await?;
        row.into_user()
    }

    pub async fn set_display_name(&mut self, name: Option<&str>) -> Result<()> {
        sqlx::query("UPDATE users SET display_name = $1 WHERE id = app_user_id()")
            .bind(name)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 推送、收件箱用的语言（1.6）。
    pub async fn set_locale(&mut self, locale: Locale) -> Result<()> {
        sqlx::query("UPDATE users SET locale = $1 WHERE id = app_user_id()")
            .bind(locale.as_str())
            .execute(self.conn())
            .await?;
        Ok(())
    }
}

impl<R> Tx<R> {
    /// 用户的语言（1.6）：服务端生成推送、收件箱文案时用。找不到用户按默认语言。
    pub async fn user_locale(&mut self, user: UserId) -> Result<Locale> {
        let locale: Option<String> = sqlx::query_scalar("SELECT locale FROM users WHERE id = $1")
            .bind(user.0)
            .fetch_optional(self.conn())
            .await?;
        Ok(locale.and_then(|l| l.parse().ok()).unwrap_or_default())
    }
}

impl<R: crate::Internal> Tx<R> {
    /// 用户的包裹 DEK：（KMS 主密钥 id，密文）。
    pub async fn user_key(&mut self, user: UserId) -> Result<Option<(String, Vec<u8>)>> {
        Ok(
            sqlx::query_as("SELECT kms_key_id, wrapped_dek FROM user_keys WHERE user_id = $1")
                .bind(user.0)
                .fetch_optional(self.conn())
                .await?,
        )
    }
}
