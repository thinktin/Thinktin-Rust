//! 登录验证码、设备、设备会话（4.1、4.2）。验证码和刷新令牌都只存哈希。

use std::time::Duration;

use chrono::{DateTime, Utc};
use proto::domain::{
    Device, DeviceId, DevicePlatform, PushChannelKind, SessionId, UserId, UserStatus,
};
use uuid::Uuid;

use crate::{Error, Result, Tenant, Tx, Worker, parse, secs};

/// 一个还有效的验证码。
#[derive(Debug, Clone)]
pub struct LoginCode {
    pub id: Uuid,
    pub code_hash: Vec<u8>,
    pub attempts: u32,
    pub expires_at: DateTime<Utc>,
}

/// 刷新时读出的会话（行已锁住）。
#[derive(Debug, Clone)]
pub struct SessionRecord {
    pub id: SessionId,
    pub user_id: UserId,
    pub device_id: DeviceId,
    pub user_status: UserStatus,
    pub refresh_hash: Vec<u8>,
    pub prev_refresh_hash: Option<Vec<u8>>,
    /// 上次轮换到现在过了多久（数据库时间）。
    pub since_rotation: Duration,
    pub expired: bool,
    pub revoked: bool,
}

/// 访问令牌验签后核对的会话状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SessionState {
    pub user_id: UserId,
    pub device_id: DeviceId,
    pub user_status: UserStatus,
    pub live: bool,
}

#[derive(sqlx::FromRow)]
struct DeviceRow {
    id: Uuid,
    platform: String,
    name: String,
    push_channel: Option<String>,
    created_at: DateTime<Utc>,
    last_seen_at: DateTime<Utc>,
    revoked_at: Option<DateTime<Utc>>,
}

impl DeviceRow {
    fn into_device(self) -> Result<Device> {
        Ok(Device {
            id: self.id.into(),
            platform: parse(&self.platform)?,
            name: self.name,
            push_channel: self.push_channel.as_deref().map(parse).transpose()?,
            created_at: self.created_at,
            last_seen_at: self.last_seen_at,
            revoked_at: self.revoked_at,
        })
    }
}

impl Tx<Worker> {
    /// 按手机号串行化（发码限频、校验），锁到事务结束。
    pub async fn lock_phone(&mut self, phone: &str) -> Result<()> {
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
            .bind(format!("phone:{phone}"))
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 最近一次发码的时间和 24 小时内发了几次（按手机号限频）。
    pub async fn login_code_stats(&mut self, phone: &str) -> Result<(Option<DateTime<Utc>>, i64)> {
        Ok(sqlx::query_as(
            "SELECT max(created_at), count(*) FROM login_codes \
             WHERE phone = $1 AND created_at > now() - interval '24 hours'",
        )
        .bind(phone)
        .fetch_one(self.conn())
        .await?)
    }

    /// 存新的验证码；同一手机号同一用途之前没用掉的码一并作废（只有最新的有效）。
    pub async fn insert_login_code(
        &mut self,
        phone: &str,
        purpose: &str,
        code_hash: &[u8],
        ttl: Duration,
    ) -> Result<()> {
        sqlx::query(
            "UPDATE login_codes SET consumed_at = now() \
             WHERE phone = $1 AND purpose = $2 AND consumed_at IS NULL",
        )
        .bind(phone)
        .bind(purpose)
        .execute(self.conn())
        .await?;
        sqlx::query(
            "INSERT INTO login_codes (id, phone, purpose, code_hash, expires_at) \
             VALUES ($1, $2, $3, $4, now() + make_interval(secs => $5))",
        )
        .bind(Uuid::now_v7())
        .bind(phone)
        .bind(purpose)
        .bind(code_hash)
        .bind(secs(ttl))
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 当前有效的验证码（没用掉、没过期），锁住这一行：并发校验时尝试次数不会少算。
    pub async fn active_login_code(
        &mut self,
        phone: &str,
        purpose: &str,
    ) -> Result<Option<LoginCode>> {
        let row: Option<(Uuid, Vec<u8>, i32, DateTime<Utc>)> = sqlx::query_as(
            "SELECT id, code_hash, attempts, expires_at FROM login_codes \
             WHERE phone = $1 AND purpose = $2 AND consumed_at IS NULL AND expires_at > now() \
             ORDER BY created_at DESC LIMIT 1 FOR UPDATE",
        )
        .bind(phone)
        .bind(purpose)
        .fetch_optional(self.conn())
        .await?;
        row.map(|(id, code_hash, attempts, expires_at)| {
            Ok(LoginCode {
                id,
                code_hash,
                attempts: u32::try_from(attempts)
                    .map_err(|_| Error::Corrupt("negative attempts".into()))?,
                expires_at,
            })
        })
        .transpose()
    }

    /// 记一次失败；到达上限时作废这个码。
    pub async fn fail_login_code(&mut self, id: Uuid, max_attempts: u32) -> Result<()> {
        sqlx::query(
            "UPDATE login_codes SET attempts = attempts + 1, \
               consumed_at = CASE WHEN attempts + 1 >= $2 THEN now() ELSE consumed_at END \
             WHERE id = $1",
        )
        .bind(id)
        .bind(i32::try_from(max_attempts).unwrap_or(i32::MAX))
        .execute(self.conn())
        .await?;
        Ok(())
    }

    pub async fn consume_login_code(&mut self, id: Uuid) -> Result<()> {
        sqlx::query("UPDATE login_codes SET consumed_at = now() WHERE id = $1")
            .bind(id)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 清理过期很久的验证码（维护任务）。
    pub async fn purge_login_codes(&mut self, older_than: Duration) -> Result<u64> {
        let done = sqlx::query(
            "DELETE FROM login_codes WHERE created_at < now() - make_interval(secs => $1)",
        )
        .bind(secs(older_than))
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }

    pub async fn create_device(
        &mut self,
        user: UserId,
        platform: DevicePlatform,
        name: &str,
        push: Option<(PushChannelKind, &str)>,
    ) -> Result<DeviceId> {
        let id = DeviceId::new();
        sqlx::query(
            "INSERT INTO devices (id, user_id, platform, name, push_channel, push_token) \
             VALUES ($1, $2, $3, $4, $5, $6)",
        )
        .bind(id.0)
        .bind(user.0)
        .bind(platform.as_str())
        .bind(name)
        .bind(push.map(|(c, _)| c.as_str()))
        .bind(push.map(|(_, t)| t))
        .execute(self.conn())
        .await?;
        Ok(id)
    }

    /// 新会话。会话 id 由调用方先生成（刷新令牌里带着它）。
    pub async fn create_session(
        &mut self,
        id: SessionId,
        user: UserId,
        device: DeviceId,
        refresh_hash: &[u8],
        ttl: Duration,
    ) -> Result<()> {
        sqlx::query(
            "INSERT INTO sessions (id, user_id, device_id, refresh_hash, expires_at) \
             VALUES ($1, $2, $3, $4, now() + make_interval(secs => $5))",
        )
        .bind(id.0)
        .bind(user.0)
        .bind(device.0)
        .bind(refresh_hash)
        .bind(secs(ttl))
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 刷新时读会话并锁住：并发刷新排队，轮换不会交错。
    pub async fn session_for_refresh(&mut self, id: SessionId) -> Result<Option<SessionRecord>> {
        #[allow(clippy::type_complexity)]
        let row: Option<(
            Uuid,
            Uuid,
            String,
            Vec<u8>,
            Option<Vec<u8>>,
            f64,
            bool,
            bool,
        )> = sqlx::query_as(
            "SELECT s.user_id, s.device_id, u.status, s.refresh_hash, s.prev_refresh_hash, \
                   extract(epoch FROM now() - s.rotated_at)::float8, s.expires_at <= now(), \
                   s.revoked_at IS NOT NULL \
                 FROM sessions s JOIN users u ON u.id = s.user_id \
                 WHERE s.id = $1 FOR UPDATE OF s",
        )
        .bind(id.0)
        .fetch_optional(self.conn())
        .await?;
        row.map(
            |(user, device, status, refresh_hash, prev_refresh_hash, since, expired, revoked)| {
                Ok(SessionRecord {
                    id,
                    user_id: user.into(),
                    device_id: device.into(),
                    user_status: parse(&status)?,
                    refresh_hash,
                    prev_refresh_hash,
                    since_rotation: Duration::from_secs_f64(since.max(0.0)),
                    expired,
                    revoked,
                })
            },
        )
        .transpose()
    }

    /// 轮换刷新令牌：当前的变成“上一个”，过期时间顺延（滑动有效期）。
    pub async fn rotate_session(
        &mut self,
        id: SessionId,
        new_hash: &[u8],
        ttl: Duration,
    ) -> Result<()> {
        sqlx::query(
            "UPDATE sessions SET prev_refresh_hash = refresh_hash, refresh_hash = $2, rotated_at = now(), \
               expires_at = now() + make_interval(secs => $3) WHERE id = $1",
        )
        .bind(id.0)
        .bind(new_hash)
        .bind(secs(ttl))
        .execute(self.conn())
        .await?;
        sqlx::query(
            "UPDATE devices SET last_seen_at = now() FROM sessions s WHERE s.id = $1 AND devices.id = s.device_id",
        )
        .bind(id.0)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    pub async fn revoke_session(&mut self, id: SessionId, reason: &str) -> Result<()> {
        sqlx::query(
            "UPDATE sessions SET revoked_at = now(), revoke_reason = $2 WHERE id = $1 AND revoked_at IS NULL",
        )
        .bind(id.0)
        .bind(reason)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 访问令牌验签之后核对：会话没吊销、没过期，账号状态。
    pub async fn session_state(&mut self, id: SessionId) -> Result<Option<SessionState>> {
        let row: Option<(Uuid, Uuid, String, bool)> = sqlx::query_as(
            "SELECT s.user_id, s.device_id, u.status, s.revoked_at IS NULL AND s.expires_at > now() \
             FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.id = $1",
        )
        .bind(id.0)
        .fetch_optional(self.conn())
        .await?;
        row.map(|(user, device, status, live)| {
            Ok(SessionState {
                user_id: user.into(),
                device_id: device.into(),
                user_status: parse(&status)?,
                live,
            })
        })
        .transpose()
    }

    /// 吊销用户的全部设备和会话（冻结、注销）。返回吊销的会话数。
    pub async fn revoke_user_sessions(&mut self, user: UserId, reason: &str) -> Result<u64> {
        let done = sqlx::query(
            "UPDATE sessions SET revoked_at = now(), revoke_reason = $2 WHERE user_id = $1 AND revoked_at IS NULL",
        )
        .bind(user.0)
        .bind(reason)
        .execute(self.conn())
        .await?;
        sqlx::query(
            "UPDATE devices SET revoked_at = now(), push_channel = NULL, push_token = NULL \
             WHERE user_id = $1 AND revoked_at IS NULL",
        )
        .bind(user.0)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }
}

impl Tx<Tenant> {
    /// 登录着的设备（没被吊销的），最近活跃的在前。
    pub async fn devices(&mut self) -> Result<Vec<Device>> {
        let rows: Vec<DeviceRow> = sqlx::query_as(
            "SELECT id, platform, name, push_channel, created_at, last_seen_at, revoked_at FROM devices \
             WHERE revoked_at IS NULL ORDER BY last_seen_at DESC",
        )
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(DeviceRow::into_device).collect()
    }

    /// 更新推送令牌（App 启动、令牌刷新时上报）。
    pub async fn set_push_token(
        &mut self,
        device: DeviceId,
        channel: PushChannelKind,
        token: &str,
    ) -> Result<()> {
        let done = sqlx::query(
            "UPDATE devices SET push_channel = $2, push_token = $3, last_seen_at = now() \
             WHERE id = $1 AND revoked_at IS NULL",
        )
        .bind(device.0)
        .bind(channel.as_str())
        .bind(token)
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }

    /// 下线一台设备（退出登录、远程下线）：吊销它的会话、清掉推送令牌。运行授权不受影响。
    pub async fn revoke_device(&mut self, device: DeviceId, reason: &str) -> Result<()> {
        let done = sqlx::query(
            "UPDATE devices SET revoked_at = now(), push_channel = NULL, push_token = NULL \
             WHERE id = $1 AND revoked_at IS NULL",
        )
        .bind(device.0)
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        sqlx::query(
            "UPDATE sessions SET revoked_at = now(), revoke_reason = $2 WHERE device_id = $1 AND revoked_at IS NULL",
        )
        .bind(device.0)
        .bind(reason)
        .execute(self.conn())
        .await?;
        Ok(())
    }
}
