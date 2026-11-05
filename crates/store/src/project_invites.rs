//! 项目邀请与拉黑（8.14，docs/projects.md 第 4、9 节，docs/progress/drafts/projects-8.14-plan.md 第 2.5 节）。
//!
//! 全部在 `Tx<Worker>` 里：动作人由调用方从登录态得到，每个方法自己按 D3 的顺序加锁、核对。要点：
//! - 只有创建者邀请。按手机号邀请不管号码注册没有、对方拉黑没有、是不是已经在项目里，返回的都一样（不能用来探测）；
//!   `invitee_id` 只表示“通知送达了谁”，从不给邀请人看。
//! - 被邀请人拉黑了邀请人：邀请照样“发出”，但标 `suppressed_at`，对方看不到、接受不了，邀请人那边到期变“已过期”。
//! - 链接邀请库里只有令牌的 SHA-256，按哈希找，永远不能按 id 找到；一次有效。

use std::time::Duration;

use chrono::{DateTime, Utc};
use proto::domain::{
    BlockedUser, InstanceId, MAX_BLOCKS, MAX_PENDING_PROJECT_INVITES, MAX_PROJECT_AGENTS,
    MAX_PROJECT_USERS, ProjectBrief, ProjectId, ProjectInvite, ProjectInviteId,
    ProjectInvitePreview, ProjectLimits, ProjectMemberBrief, ProjectPerson, ProjectRole,
    ProjectStatus, UserId, UserStatus, mask_phone, project_consent,
};
use uuid::Uuid;

use crate::project_members::{check_agent_ids, check_budget};
use crate::projects::{LockedUser, ProjectActor};
use crate::{Error, ProjectCap, Result, Tx, Worker, parse, secs, signed, unsigned};

/// 按什么找邀请：手机号邀请按 id（只找 `kind = 'phone'` 的），链接邀请只按令牌的哈希（只找 `kind = 'link'` 的）。
#[derive(Debug, Clone, Copy)]
pub enum InviteKey<'a> {
    Phone(ProjectInviteId),
    Link(&'a [u8; 32]),
}

/// 按时间窗数的上限；0 表示不限（同 `[api.limits]`）。
#[derive(Debug, Clone, Copy, Default)]
pub struct InviteCaps {
    /// 每个邀请人 24 小时最多发几个邀请（超过回 429）。
    pub per_inviter_per_day: u64,
    /// 每个号码 24 小时最多收到几条邀请通知（超过的照样有效，只是不推送）。
    pub per_phone_per_day: u64,
}

/// 用户确认过的加入说明（[`proto::domain::PROJECT_CONSENT_VERSION`]）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Consent {
    pub version: u32,
}

impl Consent {
    pub(crate) fn check(self) -> Result<()> {
        if self.version == proto::domain::PROJECT_CONSENT_VERSION {
            Ok(())
        } else {
            Err(Error::Invalid("the consent version is out of date".into()))
        }
    }
}

/// 发出的邀请。`deliver_to` 是该给谁发通知（没有就不发）；邀请人只拿到 `invite`。
#[derive(Debug, Clone)]
pub struct CreatedInvite {
    pub invite: ProjectInvite,
    /// false：这个号码已经有一个待处理的邀请，返回的是它（不再数一次、不再通知）。
    pub created: bool,
    pub deliver_to: Option<UserId>,
    pub project_name: String,
}

/// 加入时带上的：放进项目的 agent、每天和总的 token 预算、确认过的说明。
#[derive(Debug, Clone)]
pub struct JoinTerms {
    pub agents: Vec<InstanceId>,
    pub daily_token_limit: u64,
    pub total_token_limit: u64,
    pub consent: Consent,
}

/// 接受了邀请。`created = false`：之前已经用这个邀请加入了，这次什么也没改（不再通知）。
#[derive(Debug, Clone)]
pub struct Accepted {
    pub created: bool,
    pub project: ProjectId,
    pub creator: UserId,
    pub invite: ProjectInviteId,
    pub project_name: String,
    pub member_name: Option<String>,
    /// 我在项目里的 agent。
    pub agents: Vec<InstanceId>,
    /// 这些 agent 用到的模型厂商（审计用）。
    pub vendors: Vec<String>,
}

type InviteRow = (
    Uuid,
    Uuid,
    String,
    String,
    Option<String>,
    DateTime<Utc>,
    DateTime<Utc>,
    Option<DateTime<Utc>>,
    Option<Uuid>,
    Option<String>,
);

/// 邀请人看的邀请：过期了还没被后台标上的按过期算；不读 `invitee_id`、`suppressed_at`。
const INVITE_SQL: &str = "SELECT i.id, i.project_id, i.kind, \
       CASE WHEN i.status = 'pending' AND i.expires_at <= now() THEN 'expired' ELSE i.status END, \
       i.invitee_phone, i.created_at, i.expires_at, \
       CASE WHEN i.status = 'pending' AND i.expires_at <= now() THEN i.expires_at ELSE i.settled_at END, \
       i.accepted_by, au.display_name \
  FROM project_invites i LEFT JOIN users au ON au.id = i.accepted_by";

fn invite(row: InviteRow) -> Result<ProjectInvite> {
    let (id, project, kind, status, phone, created_at, expires_at, settled_at, by, by_name) = row;
    Ok(ProjectInvite {
        id: ProjectInviteId(id),
        project_id: ProjectId(project),
        kind: parse(&kind)?,
        status: parse(&status)?,
        phone_masked: phone.as_deref().map(mask_phone),
        created_at,
        expires_at,
        settled_at,
        accepted_by: by.map(|u| ProjectPerson {
            user_id: UserId(u),
            display_name: by_name,
        }),
    })
}

type PreviewRow = (
    Uuid,
    String,
    DateTime<Utc>,
    Uuid,
    String,
    String,
    Uuid,
    Option<String>,
);

const PREVIEW_COLUMNS: &str =
    "i.id, i.kind, i.expires_at, p.id, p.name, p.goal, p.creator_id, cu.display_name";

/// 给 `$1` 看的手机号邀请：发给他的号码、待处理、没过期、没被标不送达，项目进行中，他没拉黑邀请人，也不在项目里。
fn for_me_sql(columns: &str, extra: &str) -> String {
    format!(
        "SELECT {columns} FROM users me \
           JOIN project_invites i ON i.kind = 'phone' AND i.invitee_phone = me.phone \
                AND i.status = 'pending' AND i.expires_at > now() AND i.suppressed_at IS NULL \
           JOIN projects p ON p.id = i.project_id AND p.status = 'active' \
           JOIN users cu ON cu.id = p.creator_id \
          WHERE me.id = $1 AND me.status <> 'deleted' \
            AND NOT EXISTS (SELECT 1 FROM user_blocks b WHERE b.blocker_id = $1 AND b.blocked_id = i.inviter_id) \
            AND NOT EXISTS (SELECT 1 FROM project_members m WHERE m.project_id = p.id AND m.user_id = $1 \
                              AND m.left_at IS NULL) {extra}"
    )
}

impl<R> Tx<R> {
    /// 事务级的咨询锁（事务结束放开）。
    pub(crate) async fn advisory_lock(&mut self, key: &str) -> Result<()> {
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
            .bind(key)
            .execute(self.conn())
            .await?;
        Ok(())
    }
}

impl Tx<Worker> {
    /// 按手机号邀请（`phone` 已经规范成 E.164）。`recipient` 是调用方在加锁前按号码查到的用户（没注册就是 None），
    /// 这样能按 D3 先锁他的用户行。号码已经有待处理的邀请时返回那一条（`created = false`），不数上限、不再通知。
    pub async fn create_phone_invite(
        &mut self,
        user: UserId,
        project: ProjectId,
        phone: &str,
        recipient: Option<UserId>,
        caps: InviteCaps,
        ttl: Duration,
    ) -> Result<CreatedInvite> {
        let also: Vec<UserId> = recipient.into_iter().collect();
        let actor = self
            .project_actor(user, project, &also, &[ProjectStatus::Active])
            .await?;
        let me = inviter(&actor)?;
        if me.phone == phone {
            return Err(Error::Invalid("you cannot invite yourself".into()));
        }
        // 锁住以后再核对一遍：号码换了主人（注销后被别人注册）的，按没注册算（新主人照样能按号码看到邀请）。
        let recipient = recipient.filter(|r| actor.locked(*r).is_some_and(|u| u.phone == phone));
        // D3 第 4 步：动邀请行之前拿齐窄的咨询锁（和拉黑互斥：拉黑先拿 user_blocks/{拉黑的人}）。
        self.advisory_lock(&format!("project_invites/{user}"))
            .await?;
        self.advisory_lock(&format!("project_invite_phone/{phone}"))
            .await?;
        if let Some(r) = recipient {
            self.advisory_lock(&format!("user_blocks/{r}")).await?;
        }
        sqlx::query(
            "UPDATE project_invites SET status = 'expired', settled_at = now() \
              WHERE project_id = $1 AND kind = 'phone' AND invitee_phone = $2 \
                AND status = 'pending' AND expires_at <= now()",
        )
        .bind(project.0)
        .bind(phone)
        .execute(self.conn())
        .await?;
        let project_name = project_name(self, project).await?;
        let existing: Option<Uuid> = sqlx::query_scalar(
            "SELECT id FROM project_invites WHERE project_id = $1 AND kind = 'phone' \
               AND invitee_phone = $2 AND status = 'pending'",
        )
        .bind(project.0)
        .bind(phone)
        .fetch_optional(self.conn())
        .await?;
        if let Some(id) = existing {
            return Ok(CreatedInvite {
                invite: self.invite_row(ProjectInviteId(id)).await?,
                created: false,
                deliver_to: None,
                project_name,
            });
        }
        self.invite_caps(user, project, caps).await?;
        // 不管号码是谁的都数一遍，每个号码花的工夫一样。
        let delivered: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM project_invites WHERE invitee_phone = $1 AND invitee_id IS NOT NULL \
               AND created_at > now() - interval '24 hours'",
        )
        .bind(phone)
        .fetch_one(self.conn())
        .await?;
        let (blocked, member): (bool, bool) = sqlx::query_as(
            "SELECT EXISTS (SELECT 1 FROM user_blocks WHERE blocker_id = $1 AND blocked_id = $2), \
                    EXISTS (SELECT 1 FROM project_members WHERE project_id = $3 AND user_id = $1 \
                              AND left_at IS NULL)",
        )
        .bind(recipient.map(|r| r.0))
        .bind(user.0)
        .bind(project.0)
        .fetch_one(self.conn())
        .await?;
        let over = caps.per_phone_per_day > 0
            && unsigned(delivered, "delivered invites")? >= caps.per_phone_per_day;
        let deliver_to = recipient.filter(|_| !blocked && !member && !over);
        let id = ProjectInviteId::new();
        sqlx::query(
            "INSERT INTO project_invites \
               (id, project_id, inviter_id, kind, invitee_phone, invitee_id, expires_at, suppressed_at) \
             VALUES ($1, $2, $3, 'phone', $4, $5, now() + make_interval(secs => $6), \
                     CASE WHEN $7 THEN now() END)",
        )
        .bind(id.0)
        .bind(project.0)
        .bind(user.0)
        .bind(phone)
        .bind(deliver_to.map(|u| u.0))
        .bind(secs(ttl))
        .bind(blocked)
        .execute(self.conn())
        .await?;
        Ok(CreatedInvite {
            invite: self.invite_row(id).await?,
            created: true,
            deliver_to,
            project_name,
        })
    }

    /// 邀请链接：库里只存令牌的 SHA-256（`token_hash`），令牌本身由调用方生成、只交给邀请人一次。
    pub async fn create_link_invite(
        &mut self,
        user: UserId,
        project: ProjectId,
        token_hash: &[u8; 32],
        caps: InviteCaps,
        ttl: Duration,
    ) -> Result<ProjectInvite> {
        let actor = self
            .project_actor(user, project, &[], &[ProjectStatus::Active])
            .await?;
        inviter(&actor)?;
        self.advisory_lock(&format!("project_invites/{user}"))
            .await?;
        self.invite_caps(user, project, caps).await?;
        let id = ProjectInviteId::new();
        sqlx::query(
            "INSERT INTO project_invites (id, project_id, inviter_id, kind, token_hash, expires_at) \
             VALUES ($1, $2, $3, 'link', $4, now() + make_interval(secs => $5))",
        )
        .bind(id.0)
        .bind(project.0)
        .bind(user.0)
        .bind(&token_hash[..])
        .bind(secs(ttl))
        .execute(self.conn())
        .await?;
        self.invite_row(id).await
    }

    /// 发邀请前的上限：邀请人 24 小时的数（429）、项目人数、待处理的邀请数（409）。
    async fn invite_caps(
        &mut self,
        user: UserId,
        project: ProjectId,
        caps: InviteCaps,
    ) -> Result<()> {
        if caps.per_inviter_per_day > 0 {
            // 等多久：24 小时窗口里最早的一条过了窗口为止（按库里的时钟算）。
            let (n, wait): (i64, Option<i64>) = sqlx::query_as(
                "SELECT count(*), \
                        ceil(extract(epoch FROM min(created_at) + interval '24 hours' - now()))::bigint \
                   FROM project_invites \
                  WHERE inviter_id = $1 AND created_at > now() - interval '24 hours'",
            )
            .bind(user.0)
            .fetch_one(self.conn())
            .await?;
            if unsigned(n, "invites")? >= caps.per_inviter_per_day {
                let wait = wait.and_then(|w| u64::try_from(w).ok()).unwrap_or(1);
                return Err(Error::RetryAfter(wait.max(1)));
            }
        }
        let (members, pending): (i64, i64) = sqlx::query_as(
            "SELECT (SELECT count(*) FROM project_members WHERE project_id = $1 AND left_at IS NULL), \
                    (SELECT count(*) FROM project_invites WHERE project_id = $1 AND status = 'pending' \
                       AND expires_at > now())",
        )
        .bind(project.0)
        .fetch_one(self.conn())
        .await?;
        if unsigned(members, "members")? >= MAX_PROJECT_USERS {
            return Err(Error::ProjectLimit(ProjectCap::Members));
        }
        if unsigned(pending, "pending invites")? >= MAX_PENDING_PROJECT_INVITES {
            return Err(Error::ProjectLimit(ProjectCap::PendingInvites));
        }
        Ok(())
    }

    async fn invite_row(&mut self, id: ProjectInviteId) -> Result<ProjectInvite> {
        let row: InviteRow =
            sqlx::query_as(sqlx::AssertSqlSafe(format!("{INVITE_SQL} WHERE i.id = $1")))
                .bind(id.0)
                .fetch_one(self.conn())
                .await?;
        invite(row)
    }

    /// 项目的邀请（只有创建者看得到；成员 NotPermitted，别人 NotFound），新的在前，最多 100 条。
    pub async fn project_invites(
        &mut self,
        user: UserId,
        project: ProjectId,
    ) -> Result<Vec<ProjectInvite>> {
        let role: String = sqlx::query_scalar(
            "SELECT m.role FROM project_members m JOIN projects p ON p.id = m.project_id \
              WHERE m.project_id = $1 AND m.user_id = $2 AND m.left_at IS NULL AND p.status <> 'deleted'",
        )
        .bind(project.0)
        .bind(user.0)
        .fetch_one(self.conn())
        .await?;
        if parse::<ProjectRole>(&role)? != ProjectRole::Creator {
            return Err(Error::NotPermitted(
                "only the project creator can see its invites".into(),
            ));
        }
        let rows: Vec<InviteRow> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
            "{INVITE_SQL} WHERE i.project_id = $1 ORDER BY i.created_at DESC, i.id DESC LIMIT 100"
        )))
        .bind(project.0)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(invite).collect()
    }

    /// 撤回邀请（只有创建者）。已经接受的 Conflict；已经结束的（拒绝、撤回、过期）照样成功。返回这次有没有改。
    pub async fn revoke_invite(
        &mut self,
        user: UserId,
        project: ProjectId,
        id: ProjectInviteId,
    ) -> Result<bool> {
        // 先不加锁读出送达给了谁：这个流程要改他的收件箱，按 D3 先锁他的用户行。
        let (in_project, invitee): (Uuid, Option<Uuid>) =
            sqlx::query_as("SELECT project_id, invitee_id FROM project_invites WHERE id = $1")
                .bind(id.0)
                .fetch_one(self.conn())
                .await?;
        if in_project != project.0 {
            return Err(Error::NotFound);
        }
        let also: Vec<UserId> = invitee.map(UserId).into_iter().collect();
        let actor = self
            .project_actor(user, project, &also, &[ProjectStatus::Active])
            .await?;
        actor.require_creator("revoke invites")?;
        let (status, invitee): (String, Option<Uuid>) = sqlx::query_as(
            "SELECT status, invitee_id FROM project_invites WHERE id = $1 AND project_id = $2 FOR UPDATE",
        )
        .bind(id.0)
        .bind(project.0)
        .fetch_one(self.conn())
        .await?;
        match status.as_str() {
            "accepted" => return Err(Error::Conflict("invite already accepted".into())),
            "pending" => {}
            _ => return Ok(false),
        }
        sqlx::query(
            "UPDATE project_invites SET status = 'revoked', settled_at = now() \
              WHERE id = $1 AND status = 'pending'",
        )
        .bind(id.0)
        .execute(self.conn())
        .await?;
        // 收件箱里的那条（在前面锁住的人那里才改）标成已读。
        if let Some(u) = invitee.filter(|u| also.iter().any(|a| a.0 == *u)) {
            self.read_invite_items(UserId(u), &[id.0]).await?;
        }
        Ok(true)
    }

    /// 发给我的手机号邀请（我还不是成员），新的在前，最多 50 条。
    pub async fn invites_for(&mut self, user: UserId) -> Result<Vec<ProjectInvitePreview>> {
        let rows: Vec<PreviewRow> = sqlx::query_as(sqlx::AssertSqlSafe(for_me_sql(
            PREVIEW_COLUMNS,
            "ORDER BY i.created_at DESC, i.id DESC LIMIT 50",
        )))
        .bind(user.0)
        .fetch_all(self.conn())
        .await?;
        let mut out = Vec::with_capacity(rows.len());
        for row in rows {
            out.push(self.preview(row).await?);
        }
        Ok(out)
    }

    /// 加入前看的邀请：手机号邀请只给被邀请的号码看（同 [`Tx::invites_for`] 的条件）；链接邀请凭令牌（不管拉黑：
    /// 链接是用户自己点开的）。别的情况一律 NotFound。
    pub async fn invite_preview(
        &mut self,
        user: UserId,
        key: InviteKey<'_>,
    ) -> Result<ProjectInvitePreview> {
        let row: PreviewRow = match key {
            InviteKey::Phone(id) => {
                sqlx::query_as(sqlx::AssertSqlSafe(for_me_sql(
                    PREVIEW_COLUMNS,
                    "AND i.id = $2",
                )))
                .bind(user.0)
                .bind(id.0)
                .fetch_one(self.conn())
                .await?
            }
            InviteKey::Link(hash) => {
                sqlx::query_as(sqlx::AssertSqlSafe(format!(
                    "SELECT {PREVIEW_COLUMNS} FROM project_invites i \
                       JOIN projects p ON p.id = i.project_id AND p.status = 'active' \
                       JOIN users cu ON cu.id = p.creator_id \
                      WHERE i.token_hash = $1 AND i.kind = 'link' AND i.status = 'pending' \
                        AND i.expires_at > now()"
                )))
                .bind(&hash[..])
                .fetch_one(self.conn())
                .await?
            }
        };
        self.preview(row).await
    }

    /// 接受邀请、加入项目（一个事务）。手机号邀请要是发给我的号码、没被标不送达、我没拉黑邀请人；链接邀请凭令牌。
    /// 找不到、过期、撤回、拒绝、被别人用掉的一律 NotFound；已经是成员 Conflict（邀请不作废）；人数、agent 数到了上限
    /// 回 `ProjectLimit`（邀请不作废）。同一个人用同一个邀请再接受一次：什么也不改，`created = false`。
    pub async fn accept_invite(
        &mut self,
        user: UserId,
        key: InviteKey<'_>,
        terms: &JoinTerms,
    ) -> Result<Accepted> {
        let ids = check_agent_ids(&terms.agents)?;
        check_budget(terms.daily_token_limit, terms.total_token_limit)?;
        terms.consent.check()?;
        let (invite_id, project, creator): (Uuid, Uuid, Uuid) = match key {
            InviteKey::Phone(id) => sqlx::query_as(
                "SELECT i.id, i.project_id, p.creator_id FROM project_invites i \
                   JOIN projects p ON p.id = i.project_id WHERE i.id = $1 AND i.kind = 'phone'",
            )
            .bind(id.0),
            InviteKey::Link(hash) => sqlx::query_as(
                "SELECT i.id, i.project_id, p.creator_id FROM project_invites i \
                   JOIN projects p ON p.id = i.project_id WHERE i.token_hash = $1 AND i.kind = 'link'",
            )
            .bind(&hash[..]),
        }
        .fetch_one(self.conn())
        .await?;
        let (invite_id, project, creator) = (
            ProjectInviteId(invite_id),
            ProjectId(project),
            UserId(creator),
        );
        // D3：用户行 → 项目锁 → 自己的成员行（可能没有）→ 邀请行。
        let locked = self.lock_users(&[user, creator]).await?;
        let Some(me) = locked
            .into_iter()
            .find(|u| u.id == user && u.status != UserStatus::Deleted)
        else {
            return Err(Error::NotFound);
        };
        self.lock_project(project).await?;
        let (status, name): (String, String) =
            sqlx::query_as("SELECT status, name FROM projects WHERE id = $1")
                .bind(project.0)
                .fetch_one(self.conn())
                .await?;
        if parse::<ProjectStatus>(&status)? != ProjectStatus::Active {
            return Err(Error::NotFound);
        }
        let member: Option<bool> = sqlx::query_scalar(
            "SELECT left_at IS NULL FROM project_members WHERE project_id = $1 AND user_id = $2 \
             FOR NO KEY UPDATE",
        )
        .bind(project.0)
        .bind(user.0)
        .fetch_optional(self.conn())
        .await?;
        let live_member = member == Some(true);
        type Row = (String, bool, Option<Uuid>, Option<String>, bool, Uuid);
        let (status, unexpired, accepted_by, phone, suppressed, inviter): Row = sqlx::query_as(
            "SELECT status, expires_at > statement_timestamp(), accepted_by, invitee_phone, \
                    suppressed_at IS NOT NULL, inviter_id \
               FROM project_invites WHERE id = $1 FOR UPDATE",
        )
        .bind(invite_id.0)
        .fetch_one(self.conn())
        .await?;
        let mut accepted = Accepted {
            created: false,
            project,
            creator,
            invite: invite_id,
            project_name: name,
            member_name: me.display_name.clone(),
            agents: vec![],
            vendors: vec![],
        };
        if status == "accepted" && accepted_by == Some(user.0) && live_member {
            let mine: Vec<Uuid> = sqlx::query_scalar(
                "SELECT a.instance_id FROM project_agents a \
                   JOIN instances i ON i.id = a.instance_id AND i.state <> 'deleted' \
                  WHERE a.project_id = $1 AND a.user_id = $2 AND a.left_at IS NULL \
                  ORDER BY a.position, a.instance_id",
            )
            .bind(project.0)
            .bind(user.0)
            .fetch_all(self.conn())
            .await?;
            accepted.agents = mine.into_iter().map(InstanceId).collect();
            accepted.vendors = self.instance_vendors(user, &accepted.agents).await?;
            return Ok(accepted);
        }
        if status != "pending" || !unexpired {
            return Err(Error::NotFound);
        }
        if let Some(phone) = phone {
            let blocked: bool = sqlx::query_scalar(
                "SELECT EXISTS (SELECT 1 FROM user_blocks WHERE blocker_id = $1 AND blocked_id = $2)",
            )
            .bind(user.0)
            .bind(inviter)
            .fetch_one(self.conn())
            .await?;
            if phone != me.phone || suppressed || blocked {
                return Err(Error::NotFound);
            }
        }
        if live_member {
            return Err(Error::Conflict("already a member".into()));
        }
        let members: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM project_members WHERE project_id = $1 AND left_at IS NULL",
        )
        .bind(project.0)
        .fetch_one(self.conn())
        .await?;
        if unsigned(members, "members")? + 1 > MAX_PROJECT_USERS {
            return Err(Error::ProjectLimit(ProjectCap::Members));
        }
        let (live, already) = self.live_agents(project, &ids).await?;
        let new: Vec<Uuid> = ids
            .iter()
            .copied()
            .filter(|i| !already.contains(i))
            .collect();
        if live + new.len() as u64 > MAX_PROJECT_AGENTS {
            return Err(Error::ProjectLimit(ProjectCap::Agents));
        }
        self.lock_own_instances(user, &ids).await?;
        // 第一次加入走 INSERT（触发器标共享）；退出、被移出后再加入走 DO UPDATE。
        let done = sqlx::query(
            "INSERT INTO project_members \
               (project_id, user_id, role, daily_token_limit, total_token_limit, consented_at) \
             VALUES ($1, $2, 'member', $3, $4, now()) \
             ON CONFLICT (project_id, user_id) DO UPDATE SET \
               daily_token_limit = EXCLUDED.daily_token_limit, \
               total_token_limit = EXCLUDED.total_token_limit, consented_at = now(), joined_at = now(), \
               left_at = NULL, left_reason = NULL \
             WHERE project_members.role = 'member' AND project_members.left_at IS NOT NULL",
        )
        .bind(project.0)
        .bind(user.0)
        .bind(signed(terms.daily_token_limit, "daily token limit")?)
        .bind(signed(terms.total_token_limit, "total token limit")?)
        .execute(self.conn())
        .await?;
        if done.rows_affected() != 1 {
            return Err(Error::Conflict("already a member".into()));
        }
        self.put_agents(project, user, &new, true).await?;
        let settled = sqlx::query(
            "UPDATE project_invites SET status = 'accepted', settled_at = now(), accepted_by = $2 \
              WHERE id = $1 AND status = 'pending' AND expires_at > statement_timestamp()",
        )
        .bind(invite_id.0)
        .bind(user.0)
        .execute(self.conn())
        .await?;
        if settled.rows_affected() != 1 {
            return Err(Error::NotFound);
        }
        self.read_invite_items(user, &[invite_id.0]).await?;
        accepted.created = true;
        accepted.agents = terms.agents.clone();
        accepted.vendors = self.instance_vendors(user, &terms.agents).await?;
        Ok(accepted)
    }

    /// 预览：项目、创建者（屏蔽要用他的 id），别的成员只有昵称、身份和 agent 数，没有用户 id。
    async fn preview(&mut self, row: PreviewRow) -> Result<ProjectInvitePreview> {
        let (invite_id, kind, expires_at, project, name, goal, creator, creator_name) = row;
        let members: Vec<(Option<String>, String, i64)> = sqlx::query_as(
            "SELECT u.display_name, m.role, \
                    (SELECT count(*) FROM project_agents a JOIN instances i ON i.id = a.instance_id \
                       AND i.state <> 'deleted' \
                      WHERE a.project_id = m.project_id AND a.user_id = m.user_id AND a.left_at IS NULL) \
               FROM project_members m JOIN users u ON u.id = m.user_id \
              WHERE m.project_id = $1 AND m.left_at IS NULL \
              ORDER BY m.role = 'creator' DESC, m.joined_at, m.user_id",
        )
        .bind(project)
        .fetch_all(self.conn())
        .await?;
        let mut agents = 0u64;
        let members = members
            .into_iter()
            .map(|(display_name, role, n)| {
                let n = unsigned(n, "agent count")?;
                agents += n;
                Ok(ProjectMemberBrief {
                    display_name,
                    role: parse(&role)?,
                    agent_count: u32::try_from(n).unwrap_or(u32::MAX),
                })
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(ProjectInvitePreview {
            invite_id: ProjectInviteId(invite_id),
            kind: parse(&kind)?,
            expires_at,
            project: ProjectBrief {
                id: ProjectId(project),
                name,
                goal,
            },
            creator: ProjectPerson {
                user_id: UserId(creator),
                display_name: creator_name,
            },
            users: u32::try_from(members.len()).unwrap_or(u32::MAX),
            members,
            agents: u32::try_from(agents).unwrap_or(u32::MAX),
            limits: ProjectLimits::default(),
            shared_with_project: project_consent::SHARED_WITH_PROJECT
                .iter()
                .map(|s| s.to_string())
                .collect(),
            kept_private: project_consent::KEPT_PRIVATE
                .iter()
                .map(|s| s.to_string())
                .collect(),
        })
    }

    /// 拒绝发给我的手机号邀请。`block`：顺便拉黑邀请人（邀请不标“已拒绝”，标不送达：邀请人那边照样是待接受、
    /// 到期过期，看不出被拉黑）。不是发给我的、已经结束的 NotFound。
    pub async fn decline_invite(
        &mut self,
        user: UserId,
        id: ProjectInviteId,
        block: bool,
    ) -> Result<()> {
        let (project, inviter): (Uuid, Uuid) = sqlx::query_as(sqlx::AssertSqlSafe(for_me_sql(
            "i.project_id, i.inviter_id",
            "AND i.id = $2",
        )))
        .bind(user.0)
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        let (project, inviter) = (ProjectId(project), UserId(inviter));
        if block {
            // 和拉黑一样的锁（不拿项目锁）：用户行 → user_blocks/{我} → 邀请行。
            return self.block_locked(user, inviter).await;
        }
        let locked = self.lock_users(&[user, inviter]).await?;
        let Some(me) = locked
            .iter()
            .find(|u| u.id == user && u.status != UserStatus::Deleted)
        else {
            return Err(Error::NotFound);
        };
        self.lock_project(project).await?;
        let still: Option<Uuid> = sqlx::query_scalar(
            "SELECT i.id FROM project_invites i JOIN projects p ON p.id = i.project_id \
              WHERE i.id = $1 AND i.kind = 'phone' AND i.invitee_phone = $2 AND i.status = 'pending' \
                AND i.expires_at > now() AND i.suppressed_at IS NULL AND p.status = 'active' \
              FOR UPDATE OF i",
        )
        .bind(id.0)
        .bind(&me.phone)
        .fetch_optional(self.conn())
        .await?;
        if still.is_none() {
            return Err(Error::NotFound);
        }
        sqlx::query(
            "UPDATE project_invites SET status = 'declined', settled_at = now() \
              WHERE id = $1 AND status = 'pending'",
        )
        .bind(id.0)
        .execute(self.conn())
        .await?;
        self.read_invite_items(user, &[id.0]).await
    }

    /// 拉黑：对方再发来的手机号邀请不送达；已经发来、还没处理的也标上，收件箱里的标已读。拉黑自己 Invalid，
    /// 没有这个人（或注销了）NotFound。
    pub async fn block_user(&mut self, user: UserId, blocked: UserId) -> Result<()> {
        if user == blocked {
            return Err(Error::Invalid("you cannot block yourself".into()));
        }
        self.block_locked(user, blocked).await
    }

    async fn block_locked(&mut self, user: UserId, blocked: UserId) -> Result<()> {
        let locked = self.lock_users(&[user, blocked]).await?;
        let live = |id: UserId| {
            locked
                .iter()
                .find(|u| u.id == id && u.status != UserStatus::Deleted)
        };
        let (Some(me), Some(_)) = (live(user), live(blocked)) else {
            return Err(Error::NotFound);
        };
        let phone = me.phone.clone();
        self.advisory_lock(&format!("user_blocks/{user}")).await?;
        let (n, already): (i64, bool) = sqlx::query_as(
            "SELECT count(*), coalesce(bool_or(blocked_id = $2), false) FROM user_blocks \
              WHERE blocker_id = $1",
        )
        .bind(user.0)
        .bind(blocked.0)
        .fetch_one(self.conn())
        .await?;
        if !already {
            if unsigned(n, "blocks")? >= MAX_BLOCKS {
                return Err(Error::Invalid(format!(
                    "you can block at most {MAX_BLOCKS} people"
                )));
            }
            sqlx::query(
                "INSERT INTO user_blocks (blocker_id, blocked_id) VALUES ($1, $2) \
                 ON CONFLICT DO NOTHING",
            )
            .bind(user.0)
            .bind(blocked.0)
            .execute(self.conn())
            .await?;
        }
        // 对方发来的、还没处理的邀请（哪个项目的都算）标成不送达。接受邀请在锁住邀请行以后会再查一遍。
        let ids: Vec<Uuid> = sqlx::query_scalar(
            "UPDATE project_invites SET suppressed_at = now() \
              WHERE kind = 'phone' AND inviter_id = $1 AND invitee_phone = $2 \
                AND status = 'pending' AND suppressed_at IS NULL RETURNING id",
        )
        .bind(blocked.0)
        .bind(&phone)
        .fetch_all(self.conn())
        .await?;
        self.read_invite_items(user, &ids).await
    }

    /// 取消拉黑（没拉黑也成功）。之前标了不送达的邀请不会恢复。
    pub async fn unblock_user(&mut self, user: UserId, blocked: UserId) -> Result<()> {
        self.lock_users(&[user]).await?;
        sqlx::query("DELETE FROM user_blocks WHERE blocker_id = $1 AND blocked_id = $2")
            .bind(user.0)
            .bind(blocked.0)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 我拉黑的人，新的在前。
    pub async fn blocks(&mut self, user: UserId) -> Result<Vec<BlockedUser>> {
        let rows: Vec<(Uuid, Option<String>, DateTime<Utc>)> = sqlx::query_as(
            "SELECT b.blocked_id, u.display_name, b.created_at FROM user_blocks b \
               JOIN users u ON u.id = b.blocked_id \
              WHERE b.blocker_id = $1 ORDER BY b.created_at DESC, b.blocked_id",
        )
        .bind(user.0)
        .fetch_all(self.conn())
        .await?;
        Ok(rows
            .into_iter()
            .map(|(id, display_name, created_at)| BlockedUser {
                user_id: UserId(id),
                display_name,
                created_at,
            })
            .collect())
    }

    /// 把 `user` 收件箱里这些邀请的提醒标成已读。
    pub(crate) async fn read_invite_items(&mut self, user: UserId, invites: &[Uuid]) -> Result<()> {
        if invites.is_empty() {
            return Ok(());
        }
        sqlx::query(
            "UPDATE inbox_items SET read_at = now() \
              WHERE user_id = $1 AND project_invite_id = ANY($2) AND read_at IS NULL",
        )
        .bind(user.0)
        .bind(invites)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 后台：到期的待处理邀请标成过期，送达的提醒标已读。不等锁（别人锁着的下一轮再说），返回标了几条。
    pub async fn expire_project_invites(&mut self, batch: u64) -> Result<u64> {
        let rows: Vec<(Uuid, Option<Uuid>)> = sqlx::query_as(
            "UPDATE project_invites SET status = 'expired', settled_at = now() \
              WHERE id IN (SELECT id FROM project_invites WHERE status = 'pending' AND expires_at <= now() \
                            ORDER BY expires_at LIMIT $1 FOR UPDATE SKIP LOCKED) \
             RETURNING id, invitee_id",
        )
        .bind(signed(batch, "batch")?)
        .fetch_all(self.conn())
        .await?;
        let ids: Vec<Uuid> = rows.iter().map(|r| r.0).collect();
        let users: Vec<Uuid> = rows.iter().filter_map(|r| r.1).collect();
        if !users.is_empty() {
            sqlx::query(
                "UPDATE inbox_items SET read_at = now() \
                  WHERE id IN (SELECT id FROM inbox_items WHERE user_id = ANY($1) \
                                 AND project_invite_id = ANY($2) AND read_at IS NULL \
                               FOR UPDATE SKIP LOCKED)",
            )
            .bind(&users)
            .bind(&ids)
            .execute(self.conn())
            .await?;
        }
        Ok(rows.len() as u64)
    }

    /// 后台：结束超过 `older_than`（30 天）的邀请删掉，明文手机号不久留。返回删了几条。
    pub async fn purge_project_invites(&mut self, older_than: Duration, batch: u64) -> Result<u64> {
        Ok(sqlx::query(
            "DELETE FROM project_invites WHERE id IN (SELECT id FROM project_invites \
               WHERE status <> 'pending' AND settled_at < now() - make_interval(secs => $1) LIMIT $2)",
        )
        .bind(secs(older_than))
        .bind(signed(batch, "batch")?)
        .execute(self.conn())
        .await?
        .rows_affected())
    }
}

/// 邀请人：创建者，而且设了昵称（被邀请的人要知道是谁邀请的）。
fn inviter(actor: &ProjectActor) -> Result<&LockedUser> {
    actor.require_creator("invite people")?;
    let me = actor.locked(actor.user).ok_or(Error::NotFound)?;
    if me
        .display_name
        .as_deref()
        .is_none_or(|n| n.trim().is_empty())
    {
        return Err(Error::Invalid("set a display name before inviting".into()));
    }
    Ok(me)
}

async fn project_name(tx: &mut Tx<Worker>, project: ProjectId) -> Result<String> {
    Ok(
        sqlx::query_scalar("SELECT name FROM projects WHERE id = $1")
            .bind(project.0)
            .fetch_one(tx.conn())
            .await?,
    )
}
