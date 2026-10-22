//! IM 渠道（WBS 10.5）：用户绑定的群机器人。
//!
//! 库里只有密钥库用用户 DEK 封好的 token 和签名密钥，这里的读接口除了后台发送时取密文的那个，都不返回密文。
//! 每个机器人每分钟、每秒能发几条，各家有上限；后台有好几个副本，所以发送节奏（下一条最早什么时候发）记在
//! 库里（`im_bot_slots`，按机器人的指纹，几个人绑了同一个群也合在一起算），原子地占位。

use chrono::{DateTime, Utc};
use proto::domain::{ImChannel, ImChannelId, ImEvent, ImVendor, UserId};
use uuid::Uuid;

use crate::{Error, Result, Tenant, Tx, Worker, parse};

/// 新绑定的群机器人。`sealed` 是密钥库用这个用户的 DEK 封好的 token 和签名密钥。
#[derive(Clone)]
pub struct NewImChannel {
    /// 由调用方先生成：密文的附加认证数据里带着它。
    pub id: ImChannelId,
    pub vendor: ImVendor,
    pub label: String,
    pub sealed: Vec<u8>,
    pub hint: String,
    pub has_secret: bool,
    /// 认出同一个群机器人（`keyvault::webhook_fingerprint`）。
    pub bot_tag: [u8; 32],
    pub events: Vec<ImEvent>,
}

impl std::fmt::Debug for NewImChannel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NewImChannel")
            .field("id", &self.id)
            .field("vendor", &self.vendor)
            .finish_non_exhaustive()
    }
}

/// 改绑定：给了才改。`webhook` 是换上的地址或密钥（之前记下的错误清掉；机器人失效被后台停用的渠道重新打开，
/// 换上新地址就能接着发。用户自己关掉的渠道换地址后还是关着）。
#[derive(Clone, Default)]
pub struct ImChannelChange {
    pub label: Option<String>,
    pub events: Option<Vec<ImEvent>>,
    pub enabled: Option<bool>,
    pub webhook: Option<ImWebhook>,
}

/// 换上的 webhook：重新封好的 token 和签名密钥，连同平台、提示、有没有密钥、机器人的指纹。
#[derive(Clone)]
pub struct ImWebhook {
    pub vendor: ImVendor,
    pub sealed: Vec<u8>,
    pub hint: String,
    pub has_secret: bool,
    pub bot_tag: [u8; 32],
}

impl std::fmt::Debug for ImChannelChange {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ImChannelChange")
            .field("label", &self.label)
            .field("events", &self.events)
            .field("enabled", &self.enabled)
            .field("webhook", &self.webhook.is_some())
            .finish()
    }
}

/// 后台发送时读的一行：连同密文。
#[derive(Clone)]
pub struct SealedImChannel {
    pub channel: ImChannel,
    pub user_id: UserId,
    pub sealed: Vec<u8>,
    /// 地址的版本：记发送结果时带上（[`Tx::record_im_result`]）。
    pub webhook_rev: i32,
}

impl std::fmt::Debug for SealedImChannel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SealedImChannel")
            .field("channel", &self.channel)
            .finish_non_exhaustive()
    }
}

/// 占发送名额的结果。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImSlot {
    /// 可以发。
    Go,
    /// 还没轮到，到这个时间再来。
    Wait(DateTime<Utc>),
    /// 渠道删了或者停用了。
    Gone,
}

#[derive(sqlx::FromRow)]
struct Row {
    id: Uuid,
    vendor: String,
    label: String,
    hint: String,
    has_secret: bool,
    events: Vec<String>,
    enabled: bool,
    last_sent_at: Option<DateTime<Utc>>,
    last_error: Option<String>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

impl Row {
    fn into_channel(self) -> Result<ImChannel> {
        Ok(ImChannel {
            id: self.id.into(),
            vendor: parse(&self.vendor)?,
            label: self.label,
            hint: self.hint,
            has_secret: self.has_secret,
            events: self
                .events
                .iter()
                .map(|e| parse(e))
                .collect::<Result<_>>()?,
            enabled: self.enabled,
            last_sent_at: self.last_sent_at,
            last_error: self.last_error,
            created_at: self.created_at,
            updated_at: self.updated_at,
        })
    }
}

#[derive(sqlx::FromRow)]
struct SealedRow {
    #[sqlx(flatten)]
    channel: Row,
    user_id: Uuid,
    sealed: Vec<u8>,
    webhook_rev: i32,
}

macro_rules! columns {
    () => {
        "id, vendor, label, hint, has_secret, events, enabled, last_sent_at, last_error, created_at, updated_at"
    };
}

/// 同一个人把同一个群机器人绑两次：没有意义（每条通知会发两遍），还会让发送节奏翻倍。
fn already_bound(e: sqlx::Error) -> Error {
    match Error::from(e) {
        Error::Conflict(_) => {
            Error::Conflict("this group bot is already bound to another channel".into())
        }
        e => e,
    }
}

fn event_strings(events: &[ImEvent]) -> Vec<String> {
    let mut out: Vec<String> = events.iter().map(|e| e.as_str().to_owned()).collect();
    out.sort();
    out.dedup();
    out
}

impl Tx<Tenant> {
    /// 新绑定。每个用户最多 `max` 个：按用户加锁，数和插入在同一个事务里，并发的请求不能一起超过上限
    /// （一条通知给每个渠道各发一条，上限管着它放大多少倍）。
    pub async fn create_im_channel(&mut self, new: &NewImChannel, max: u64) -> Result<ImChannel> {
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
            .bind(format!("im_channels/{}", self.user()))
            .execute(self.conn())
            .await?;
        if self.im_channel_count().await? >= max {
            return Err(Error::Invalid(format!(
                "at most {max} IM channels per account"
            )));
        }
        let row: Row = sqlx::query_as(concat!(
            "INSERT INTO im_channels (id, user_id, vendor, label, sealed, hint, has_secret, bot_tag, events) \
             VALUES ($1, app_user_id(), $2, $3, $4, $5, $6, $7, $8) RETURNING ",
            columns!()
        ))
        .bind(new.id.0)
        .bind(new.vendor.as_str())
        .bind(&new.label)
        .bind(&new.sealed)
        .bind(&new.hint)
        .bind(new.has_secret)
        .bind(&new.bot_tag[..])
        .bind(event_strings(&new.events))
        .fetch_one(self.conn())
        .await
        .map_err(already_bound)?;
        row.into_channel()
    }

    pub async fn im_channels(&mut self) -> Result<Vec<ImChannel>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM im_channels ORDER BY created_at, id"
        ))
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_channel).collect()
    }

    pub async fn im_channel(&mut self, id: ImChannelId) -> Result<ImChannel> {
        let row: Row = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM im_channels WHERE id = $1"
        ))
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        row.into_channel()
    }

    pub async fn im_channel_count(&mut self) -> Result<u64> {
        let n: i64 = sqlx::query_scalar("SELECT count(*) FROM im_channels")
            .fetch_one(self.conn())
            .await?;
        crate::unsigned(n, "im channel count")
    }

    pub async fn update_im_channel(
        &mut self,
        id: ImChannelId,
        change: &ImChannelChange,
    ) -> Result<ImChannel> {
        let hook = change.webhook.as_ref();
        let vendor = hook.map(|h| h.vendor.as_str());
        let row: Option<Row> = sqlx::query_as(concat!(
            "UPDATE im_channels SET label = coalesce($2, label), events = coalesce($3, events), \
               enabled = coalesce($4, CASE WHEN $6::bytea IS NULL THEN enabled ELSE enabled OR auto_disabled END), \
               auto_disabled = CASE WHEN $4::bool IS NULL AND $6::bytea IS NULL THEN auto_disabled ELSE false END, \
               sealed = coalesce($6, sealed), hint = coalesce($7, hint), \
               has_secret = coalesce($8, has_secret), bot_tag = coalesce($9, bot_tag), \
               webhook_rev = webhook_rev + CASE WHEN $6::bytea IS NULL THEN 0 ELSE 1 END, \
               last_error = CASE WHEN $6::bytea IS NULL THEN last_error END, \
               last_error_at = CASE WHEN $6::bytea IS NULL THEN last_error_at END, \
               updated_at = now() \
             WHERE id = $1 AND ($5::text IS NULL OR vendor = $5) RETURNING ",
            columns!()
        ))
        .bind(id.0)
        .bind(change.label.as_deref())
        .bind(change.events.as_deref().map(event_strings))
        .bind(change.enabled)
        .bind(vendor)
        .bind(hook.map(|h| h.sealed.as_slice()))
        .bind(hook.map(|h| h.hint.as_str()))
        .bind(hook.map(|h| h.has_secret))
        .bind(hook.map(|h| &h.bot_tag[..]))
        .fetch_optional(self.conn())
        .await
        .map_err(already_bound)?;
        match row {
            Some(row) => row.into_channel(),
            None if vendor.is_some() && self.im_channel(id).await.is_ok() => Err(Error::Invalid(
                "the new webhook belongs to a different vendor; add it as a new channel".into(),
            )),
            None => Err(Error::NotFound),
        }
    }

    pub async fn delete_im_channel(&mut self, id: ImChannelId) -> Result<()> {
        let done = sqlx::query("DELETE FROM im_channels WHERE id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }
}

impl<R> Tx<R> {
    /// 订了这个事件、开着的渠道（发通知时在同一个事务里查，一个渠道发一条）。
    pub async fn im_channels_for(
        &mut self,
        user: UserId,
        event: ImEvent,
    ) -> Result<Vec<ImChannelId>> {
        let ids: Vec<Uuid> = sqlx::query_scalar(
            "SELECT id FROM im_channels WHERE user_id = $1 AND enabled AND $2 = ANY (events) \
             ORDER BY created_at, id",
        )
        .bind(user.0)
        .bind(event.as_str())
        .fetch_all(self.conn())
        .await?;
        Ok(ids.into_iter().map(Into::into).collect())
    }
}

impl Tx<Worker> {
    /// 后台发送时读渠道连同密文；删了返回 None。
    pub async fn sealed_im_channel(&mut self, id: ImChannelId) -> Result<Option<SealedImChannel>> {
        let row: Option<SealedRow> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            ", user_id, sealed, webhook_rev FROM im_channels WHERE id = $1"
        ))
        .bind(id.0)
        .fetch_optional(self.conn())
        .await?;
        row.map(|r| {
            Ok(SealedImChannel {
                channel: r.channel.into_channel()?,
                user_id: r.user_id.into(),
                sealed: r.sealed,
                webhook_rev: r.webhook_rev,
            })
        })
        .transpose()
    }

    /// 占一个发送名额：同一个群机器人两条之间隔 `interval`，可以连着发两条（各家按每分钟、每秒限流：钉钉一分钟超过
    /// 20 条要限 10 分钟，按固定的一分钟窗口算，窗口交界的地方几秒内能发出两倍）。按机器人算：绑了同一个机器人的
    /// 几个渠道（不同的人）共用这个节奏，多个副本也共用。要在发送前提交。
    pub async fn take_im_slot(
        &mut self,
        id: ImChannelId,
        interval: std::time::Duration,
    ) -> Result<ImSlot> {
        let secs = interval.as_secs_f64();
        let taken = sqlx::query(
            "INSERT INTO im_bot_slots (bot_tag, next_slot_at) \
             SELECT bot_tag, now() + make_interval(secs => $2) FROM im_channels WHERE id = $1 AND enabled \
             ON CONFLICT (bot_tag) DO UPDATE \
               SET next_slot_at = greatest(im_bot_slots.next_slot_at, now()) + make_interval(secs => $2) \
               WHERE im_bot_slots.next_slot_at <= now() + make_interval(secs => $2)",
        )
        .bind(id.0)
        .bind(secs)
        .execute(self.conn())
        .await?;
        if taken.rows_affected() == 1 {
            return Ok(ImSlot::Go);
        }
        let row: Option<(bool, Option<DateTime<Utc>>)> = sqlx::query_as(
            "SELECT c.enabled, s.next_slot_at - make_interval(secs => $2) FROM im_channels c \
             LEFT JOIN im_bot_slots s ON s.bot_tag = c.bot_tag WHERE c.id = $1",
        )
        .bind(id.0)
        .bind(secs)
        .fetch_optional(self.conn())
        .await?;
        Ok(match row {
            Some((true, Some(at))) => ImSlot::Wait(at),
            Some((true, None)) => ImSlot::Go,
            _ => ImSlot::Gone,
        })
    }

    /// 厂商说限流了：这个渠道的机器人 `until` 之前都不发（钉钉超限后限 10 分钟，别的条目不用再去碰一次；
    /// 绑了同一个机器人的别的渠道也一起等）。
    pub async fn throttle_im_channel(
        &mut self,
        id: ImChannelId,
        until: DateTime<Utc>,
    ) -> Result<()> {
        sqlx::query(
            "INSERT INTO im_bot_slots (bot_tag, next_slot_at) \
             SELECT bot_tag, $2 FROM im_channels WHERE id = $1 \
             ON CONFLICT (bot_tag) DO UPDATE \
               SET next_slot_at = greatest(im_bot_slots.next_slot_at, EXCLUDED.next_slot_at)",
        )
        .bind(id.0)
        .bind(until)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 维护任务：删掉一天前就过了的发送节奏（机器人早就没在发了，下次发时重新开始）。
    pub async fn purge_im_bot_slots(&mut self) -> Result<u64> {
        let done =
            sqlx::query("DELETE FROM im_bot_slots WHERE next_slot_at < now() - interval '1 day'")
                .execute(self.conn())
                .await?;
        Ok(done.rows_affected())
    }

    /// 记下这次发送的结果：成功清掉错误；失败记原因，`disable` 时停用渠道（机器人被删、地址失效）。
    /// 只改地址还是 `webhook_rev` 那一版的行：用户在这期间换了地址，不能把新地址停掉、记上旧地址的错误。
    /// 返回这次是不是把开着的渠道停掉了（只在那时通知用户）。
    pub async fn record_im_result(
        &mut self,
        id: ImChannelId,
        webhook_rev: i32,
        error: Option<&str>,
        disable: bool,
    ) -> Result<bool> {
        let error: Option<String> = error.map(|e| e.chars().take(500).collect());
        let turned_off: Option<bool> = sqlx::query_scalar(
            "WITH old AS (SELECT enabled FROM im_channels WHERE id = $1 AND webhook_rev = $2 FOR UPDATE) \
             UPDATE im_channels c SET \
               last_sent_at = CASE WHEN $3::text IS NULL THEN now() ELSE c.last_sent_at END, \
               last_error = $3, last_error_at = CASE WHEN $3::text IS NULL THEN NULL ELSE now() END, \
               enabled = c.enabled AND NOT $4, \
               auto_disabled = c.auto_disabled OR (c.enabled AND $4) \
             FROM old WHERE c.id = $1 AND c.webhook_rev = $2 \
             RETURNING old.enabled AND NOT c.enabled",
        )
        .bind(id.0)
        .bind(webhook_rev)
        .bind(error)
        .bind(disable)
        .fetch_optional(self.conn())
        .await?;
        Ok(turned_off.unwrap_or(false))
    }
}
