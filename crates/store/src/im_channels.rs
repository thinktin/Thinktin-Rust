//! IM 渠道（WBS 10.5）：用户绑定的群机器人。
//!
//! 库里只有密钥库用用户 DEK 封好的 token 和签名密钥，这里的读接口除了后台发送时取密文的那个，都不返回密文。
//! 每个机器人每分钟能发几条，各家有上限；后台有好几个副本，所以限流窗口记在这张表里，原子地占位。

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

/// 改绑定：给了才改。`webhook` 是重新封好的 token 和签名密钥，连同提示和有没有密钥
/// （换了地址或密钥，之前记下的错误就清掉）。
#[derive(Clone, Default)]
pub struct ImChannelChange {
    pub label: Option<String>,
    pub events: Option<Vec<ImEvent>>,
    pub enabled: Option<bool>,
    pub webhook: Option<(ImVendor, Vec<u8>, String, bool)>,
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
    /// 这一分钟的名额用完了，到这个时间再来。
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
}

macro_rules! columns {
    () => {
        "id, vendor, label, hint, has_secret, events, enabled, last_sent_at, last_error, created_at, updated_at"
    };
}

fn event_strings(events: &[ImEvent]) -> Vec<String> {
    let mut out: Vec<String> = events.iter().map(|e| e.as_str().to_owned()).collect();
    out.sort();
    out.dedup();
    out
}

impl Tx<Tenant> {
    pub async fn create_im_channel(&mut self, new: &NewImChannel) -> Result<ImChannel> {
        let row: Row = sqlx::query_as(concat!(
            "INSERT INTO im_channels (id, user_id, vendor, label, sealed, hint, has_secret, events) \
             VALUES ($1, app_user_id(), $2, $3, $4, $5, $6, $7) RETURNING ",
            columns!()
        ))
        .bind(new.id.0)
        .bind(new.vendor.as_str())
        .bind(&new.label)
        .bind(&new.sealed)
        .bind(&new.hint)
        .bind(new.has_secret)
        .bind(event_strings(&new.events))
        .fetch_one(self.conn())
        .await?;
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
        let (vendor, sealed, hint, has_secret) = match &change.webhook {
            Some((v, s, h, secret)) => (
                Some(v.as_str()),
                Some(s.as_slice()),
                Some(h.as_str()),
                Some(*secret),
            ),
            None => (None, None, None, None),
        };
        let row: Option<Row> = sqlx::query_as(concat!(
            "UPDATE im_channels SET label = coalesce($2, label), events = coalesce($3, events), \
               enabled = coalesce($4, enabled), sealed = coalesce($6, sealed), hint = coalesce($7, hint), \
               has_secret = coalesce($8, has_secret), \
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
        .bind(sealed)
        .bind(hint)
        .bind(has_secret)
        .fetch_optional(self.conn())
        .await?;
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
            ", user_id, sealed FROM im_channels WHERE id = $1"
        ))
        .bind(id.0)
        .fetch_optional(self.conn())
        .await?;
        row.map(|r| {
            Ok(SealedImChannel {
                channel: r.channel.into_channel()?,
                user_id: r.user_id.into(),
                sealed: r.sealed,
            })
        })
        .transpose()
    }

    /// 占一个发送名额：每个渠道每分钟最多 `per_minute` 条（多个副本共用这个窗口）。要在发送前提交。
    pub async fn take_im_slot(&mut self, id: ImChannelId, per_minute: u32) -> Result<ImSlot> {
        let taken = sqlx::query(
            "UPDATE im_channels SET \
               rate_window_count = CASE WHEN rate_window_start > now() - interval '1 minute' \
                                        THEN rate_window_count + 1 ELSE 1 END, \
               rate_window_start = CASE WHEN rate_window_start > now() - interval '1 minute' \
                                        THEN rate_window_start ELSE now() END \
             WHERE id = $1 AND enabled \
               AND (rate_window_start IS NULL OR rate_window_start <= now() - interval '1 minute' \
                    OR rate_window_count < $2)",
        )
        .bind(id.0)
        .bind(i64::from(per_minute))
        .execute(self.conn())
        .await?;
        if taken.rows_affected() == 1 {
            return Ok(ImSlot::Go);
        }
        let row: Option<(bool, Option<DateTime<Utc>>)> = sqlx::query_as(
            "SELECT enabled, rate_window_start + interval '1 minute' FROM im_channels WHERE id = $1",
        )
        .bind(id.0)
        .fetch_optional(self.conn())
        .await?;
        Ok(match row {
            Some((true, Some(at))) => ImSlot::Wait(at),
            Some((true, None)) => ImSlot::Go,
            _ => ImSlot::Gone,
        })
    }

    /// 记下这次发送的结果：成功清掉错误；失败记原因，`disable` 时停用渠道（机器人被删、地址失效）。
    /// 只改 `updated_at` 还是 `seen` 那一刻的行：用户在这期间换了地址，不能把新地址停掉。
    pub async fn record_im_result(
        &mut self,
        id: ImChannelId,
        seen: DateTime<Utc>,
        error: Option<&str>,
        disable: bool,
    ) -> Result<()> {
        let error: Option<String> = error.map(|e| e.chars().take(500).collect());
        sqlx::query(
            "UPDATE im_channels SET \
               last_sent_at = CASE WHEN $3::text IS NULL THEN now() ELSE last_sent_at END, \
               last_error = $3, last_error_at = CASE WHEN $3::text IS NULL THEN NULL ELSE now() END, \
               enabled = enabled AND NOT $4 \
             WHERE id = $1 AND updated_at = $2",
        )
        .bind(id.0)
        .bind(seen)
        .bind(error)
        .bind(disable)
        .execute(self.conn())
        .await?;
        Ok(())
    }
}
