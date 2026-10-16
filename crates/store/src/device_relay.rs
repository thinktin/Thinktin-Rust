//! 设备中继（WBS 14.1）的数据：电脑的在线状态、平台发给电脑的工具调用、手机和电脑之间转发的消息。
//! 表结构和通知频道见迁移 `0014_device_relay.sql`。
//!
//! - 中继（[`Tx<Relay>`]）：电脑连上、心跳、断开时维护在线状态；领走发给这台电脑的调用、回填结果；
//!   投递和收下消息；电脑上线时唤醒等电脑的运行（7.11）。
//! - 执行器（[`Tx<Worker>`]）：按会话绑定找用户在线的电脑、写调用、读结果、过期。
//! - 业务接口（[`Tx<Tenant>`]）：手机发消息给电脑、收电脑发来的消息、看电脑在不在线。

use std::time::Duration;

use chrono::{DateTime, Utc};
use proto::domain::{
    DeviceCallId, DeviceCallState, DeviceId, DeviceMessage, DeviceMessageId, DeviceMessageKind,
    DevicePlatform, RunId, RunState, UserId,
};
use serde_json::Value;
use uuid::Uuid;

use crate::{Error, Relay, Result, Tenant, Tx, Worker, parse, secs};

/// 有新东西给某台电脑（调用、消息，或者它的连接被顶掉了）。载荷是设备 id。
pub const DEVICE_CHANNEL: &str = "thinktin_device";
/// 发给电脑的调用结束了（有结果、失败或过期）。载荷是调用 id。
pub const DEVICE_CALL_CHANNEL: &str = "thinktin_device_call";
/// 中继这么久没刷新一台电脑的连接，就算它离线（中继挂了没人刷新）。中继的心跳间隔要明显短于它。
pub const LINK_FRESH: Duration = Duration::from_secs(90);
/// 转发的消息排多久的队，过期没送到的丢掉（审批请求本身最长 24 小时有效）。
const MESSAGE_TTL: Duration = Duration::from_secs(24 * 3600);
/// 电脑连接断了，转给它、还没回结果的调用的失败原因。
const DISCONNECTED: &str = "the computer went offline before answering";

/// 电脑连上了中继。
#[derive(Debug, Clone)]
pub struct NewLink {
    pub device: DeviceId,
    pub user: UserId,
    /// 中继副本。
    pub node: String,
    /// 这次连接。
    pub connection: Uuid,
}

/// 中继领走、要转给电脑的调用。
#[derive(Debug, Clone, PartialEq)]
pub struct ClaimedCall {
    pub id: DeviceCallId,
    pub run: Option<RunId>,
    pub tool: String,
    pub arguments: Value,
    pub expires_at: DateTime<Utc>,
}

/// 执行器要发给电脑的调用。
#[derive(Debug, Clone)]
pub struct NewDeviceCall {
    pub user: UserId,
    pub device: DeviceId,
    pub run: Option<RunId>,
    pub tool: String,
    pub arguments: Value,
    /// 最多等多久；过了中继不再转出，电脑也可以放弃。
    pub timeout: Duration,
}

/// 一个调用现在的样子。
#[derive(Debug, Clone, PartialEq)]
pub struct DeviceCallRecord {
    pub id: DeviceCallId,
    pub device: DeviceId,
    pub state: DeviceCallState,
    /// 电脑回的 `{"content": [...], "is_error": …}`。
    pub result: Option<Value>,
    pub error: Option<String>,
}

macro_rules! message_columns {
    () => {
        "id, from_device, to_device, kind, body, created_at, expires_at"
    };
}

#[derive(sqlx::FromRow)]
struct MessageRow {
    id: Uuid,
    from_device: Uuid,
    to_device: Uuid,
    kind: String,
    body: Value,
    created_at: DateTime<Utc>,
    expires_at: DateTime<Utc>,
}

impl MessageRow {
    fn into_message(self) -> Result<DeviceMessage> {
        Ok(DeviceMessage {
            id: self.id.into(),
            from_device: self.from_device.into(),
            to_device: self.to_device.into(),
            kind: parse(&self.kind)?,
            body: self.body,
            created_at: self.created_at,
            expires_at: self.expires_at,
        })
    }
}

impl<R> Tx<R> {
    async fn notify_channel(&mut self, channel: &str, payload: &str) -> Result<()> {
        sqlx::query("SELECT pg_notify($1, $2)")
            .bind(channel)
            .bind(payload)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 存一条转发的消息，通知收件设备。两台设备都得是这个用户没吊销的设备，方向得对：
    /// 电脑发的（配对确认、审批请求）只能给手机，手机发的只能给电脑。
    async fn insert_device_message(
        &mut self,
        user: UserId,
        from: DeviceId,
        to: DeviceId,
        kind: DeviceMessageKind,
        body: &Value,
    ) -> Result<DeviceMessage> {
        if from == to {
            return Err(Error::Invalid("a device cannot message itself".into()));
        }
        let rows: Vec<(Uuid, String)> = sqlx::query_as(
            "SELECT id, platform FROM devices WHERE user_id = $1 AND id = ANY($2) AND revoked_at IS NULL",
        )
        .bind(user.0)
        .bind(vec![from.0, to.0])
        .fetch_all(self.conn())
        .await?;
        let platform = |d: DeviceId| -> Result<Option<DevicePlatform>> {
            rows.iter()
                .find(|(id, _)| *id == d.0)
                .map(|(_, p)| parse(p))
                .transpose()
        };
        let (Some(from_platform), Some(to_platform)) = (platform(from)?, platform(to)?) else {
            return Err(Error::NotFound);
        };
        let from_computer = from_platform == DevicePlatform::Macos;
        let to_computer = to_platform == DevicePlatform::Macos;
        if kind.from_computer() != from_computer || from_computer == to_computer {
            return Err(Error::Invalid(format!(
                "{kind} cannot go from a {from_platform} device to a {to_platform} device"
            )));
        }
        let row: MessageRow = sqlx::query_as(concat!(
            "INSERT INTO device_messages (id, user_id, from_device, to_device, kind, body, expires_at) \
             VALUES ($1, $2, $3, $4, $5, $6, now() + make_interval(secs => $7)) RETURNING ",
            message_columns!()
        ))
        .bind(DeviceMessageId::new().0)
        .bind(user.0)
        .bind(from.0)
        .bind(to.0)
        .bind(kind.as_str())
        .bind(body)
        .bind(secs(MESSAGE_TTL))
        .fetch_one(self.conn())
        .await?;
        self.notify_channel(DEVICE_CHANNEL, &to.to_string()).await?;
        row.into_message()
    }

    /// 发给这台设备、还没送到也没过期的消息，按发出的顺序。
    async fn device_inbox(
        &mut self,
        user: UserId,
        device: DeviceId,
        limit: i64,
    ) -> Result<Vec<DeviceMessage>> {
        let rows: Vec<MessageRow> = sqlx::query_as(concat!(
            "SELECT ",
            message_columns!(),
            " FROM device_messages WHERE user_id = $1 AND to_device = $2 AND delivered_at IS NULL \
               AND expires_at > now() ORDER BY id LIMIT $3"
        ))
        .bind(user.0)
        .bind(device.0)
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(MessageRow::into_message).collect()
    }

    /// 收件设备确认收到：之后不再投递。返回标记的条数。
    async fn ack_device_inbox(
        &mut self,
        user: UserId,
        device: DeviceId,
        ids: &[DeviceMessageId],
    ) -> Result<u64> {
        let ids: Vec<Uuid> = ids.iter().map(|i| i.0).collect();
        let done = sqlx::query(
            "UPDATE device_messages SET delivered_at = now() \
             WHERE user_id = $1 AND to_device = $2 AND id = ANY($3) AND delivered_at IS NULL",
        )
        .bind(user.0)
        .bind(device.0)
        .bind(ids)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }
}

impl Tx<Relay> {
    /// 电脑连上来：记下它连在哪个副本的哪次连接上，同一台电脑之前的连接作废。
    /// 通知设备频道，让之前的连接（可能在别的副本上）发现自己被顶掉了。
    pub async fn link_device(&mut self, link: &NewLink) -> Result<()> {
        sqlx::query(
            "INSERT INTO device_links (device_id, user_id, node, connection) VALUES ($1, $2, $3, $4) \
             ON CONFLICT (device_id) DO UPDATE SET user_id = EXCLUDED.user_id, node = EXCLUDED.node, \
               connection = EXCLUDED.connection, tools = '{}', app_version = '', \
               connected_at = now(), last_seen_at = now()",
        )
        .bind(link.device.0)
        .bind(link.user.0)
        .bind(&link.node)
        .bind(link.connection)
        .execute(self.conn())
        .await?;
        self.notify_channel(DEVICE_CHANNEL, &link.device.to_string())
            .await
    }

    /// 电脑报上来的工具和 App 版本。这次连接已经被顶掉时返回 false。
    pub async fn set_link_info(
        &mut self,
        device: DeviceId,
        connection: Uuid,
        tools: &[String],
        app_version: &str,
    ) -> Result<bool> {
        let done = sqlx::query(
            "UPDATE device_links SET tools = $3, app_version = $4, last_seen_at = now() \
             WHERE device_id = $1 AND connection = $2",
        )
        .bind(device.0)
        .bind(connection)
        .bind(tools)
        .bind(app_version)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected() == 1)
    }

    /// 心跳：刷新在线时间。这次连接已经被顶掉（或者在线状态被清掉了）时返回 false。
    pub async fn touch_link(&mut self, device: DeviceId, connection: Uuid) -> Result<bool> {
        let done = sqlx::query(
            "UPDATE device_links SET last_seen_at = now() WHERE device_id = $1 AND connection = $2",
        )
        .bind(device.0)
        .bind(connection)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected() == 1)
    }

    /// 连接断了：去掉在线状态（还是这次连接的话）；转给这次连接、没回结果的调用判失败
    /// （工具可能有副作用，不重发），通知等结果的一方。返回判失败的调用。
    pub async fn unlink_device(
        &mut self,
        device: DeviceId,
        connection: Uuid,
    ) -> Result<Vec<DeviceCallId>> {
        sqlx::query("DELETE FROM device_links WHERE device_id = $1 AND connection = $2")
            .bind(device.0)
            .bind(connection)
            .execute(self.conn())
            .await?;
        let failed: Vec<Uuid> = sqlx::query_scalar(
            "UPDATE device_calls SET state = 'failed', error = $2, finished_at = now() \
             WHERE connection = $1 AND state = 'sent' RETURNING id",
        )
        .bind(connection)
        .bind(DISCONNECTED)
        .fetch_all(self.conn())
        .await?;
        for id in &failed {
            self.notify_channel(DEVICE_CALL_CHANNEL, &id.to_string())
                .await?;
        }
        Ok(failed.into_iter().map(Into::into).collect())
    }

    /// 领走等着这台电脑的调用（最多 `limit` 个，先来的先领），标成已转出。
    /// 这次连接已经被顶掉时什么也不领。
    pub async fn claim_device_calls(
        &mut self,
        device: DeviceId,
        connection: Uuid,
        limit: i64,
    ) -> Result<Vec<ClaimedCall>> {
        let rows: Vec<(Uuid, Option<Uuid>, String, Value, DateTime<Utc>)> = sqlx::query_as(
            "UPDATE device_calls SET state = 'sent', sent_at = now(), connection = $2 \
             WHERE id IN (SELECT c.id FROM device_calls c \
                          WHERE c.device_id = $1 AND c.state = 'pending' AND c.expires_at > now() \
                            AND EXISTS (SELECT 1 FROM device_links l \
                                        WHERE l.device_id = $1 AND l.connection = $2) \
                          ORDER BY c.created_at LIMIT $3 FOR UPDATE SKIP LOCKED) \
             RETURNING id, run_id, tool, arguments, expires_at",
        )
        .bind(device.0)
        .bind(connection)
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        let mut calls: Vec<ClaimedCall> = rows
            .into_iter()
            .map(|(id, run, tool, arguments, expires_at)| ClaimedCall {
                id: id.into(),
                run: run.map(Into::into),
                tool,
                arguments,
                expires_at,
            })
            .collect();
        calls.sort_by_key(|c| c.id);
        Ok(calls)
    }

    /// 电脑回了结果。必须是转给这次连接、还在等结果的调用：平台已经不等了（过期）、
    /// 或者不是发给这台电脑的，返回 false。
    pub async fn finish_device_call(
        &mut self,
        call: DeviceCallId,
        device: DeviceId,
        connection: Uuid,
        result: &Value,
    ) -> Result<bool> {
        let done = sqlx::query(
            "UPDATE device_calls SET state = 'done', result = $4, finished_at = now() \
             WHERE id = $1 AND device_id = $2 AND connection = $3 AND state = 'sent'",
        )
        .bind(call.0)
        .bind(device.0)
        .bind(connection)
        .bind(result)
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            return Ok(false);
        }
        self.notify_channel(DEVICE_CALL_CHANNEL, &call.to_string())
            .await?;
        Ok(true)
    }

    /// 电脑上线：等电脑的运行（7.11）马上可以重新领起来接着跑。返回唤醒的个数。
    pub async fn wake_device_waiters(&mut self, user: UserId) -> Result<u64> {
        let done = sqlx::query(
            "UPDATE runs SET not_before = now(), updated_at = now() \
             WHERE user_id = $1 AND state = $2 AND lease_owner IS NULL AND not_before > now()",
        )
        .bind(user.0)
        .bind(RunState::WaitingDevice.as_str())
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }

    /// 电脑发给手机的消息（配对确认、审批请求）。
    pub async fn send_device_message(
        &mut self,
        user: UserId,
        from: DeviceId,
        to: DeviceId,
        kind: DeviceMessageKind,
        body: &Value,
    ) -> Result<DeviceMessage> {
        self.insert_device_message(user, from, to, kind, body).await
    }

    /// 发给这台电脑、还没送到的消息。
    pub async fn pending_device_messages(
        &mut self,
        user: UserId,
        device: DeviceId,
        limit: i64,
    ) -> Result<Vec<DeviceMessage>> {
        self.device_inbox(user, device, limit).await
    }

    /// 电脑确认收到了这些消息。
    pub async fn ack_device_messages(
        &mut self,
        user: UserId,
        device: DeviceId,
        ids: &[DeviceMessageId],
    ) -> Result<u64> {
        self.ack_device_inbox(user, device, ids).await
    }
}

impl Tx<Worker> {
    /// 用户在线的电脑（会话绑定：只看这个用户自己的、没吊销的电脑），有几台时取最近连上的那台，
    /// 带它报上来的工具。
    pub async fn online_computer(
        &mut self,
        user: UserId,
    ) -> Result<Option<(DeviceId, Vec<String>)>> {
        let row: Option<(Uuid, Vec<String>)> = sqlx::query_as(
            "SELECT l.device_id, l.tools FROM device_links l JOIN devices d ON d.id = l.device_id \
             WHERE l.user_id = $1 AND d.user_id = $1 AND d.revoked_at IS NULL AND d.platform = 'macos' \
               AND l.last_seen_at > now() - make_interval(secs => $2) \
             ORDER BY l.connected_at DESC LIMIT 1",
        )
        .bind(user.0)
        .bind(secs(LINK_FRESH))
        .fetch_optional(self.conn())
        .await?;
        Ok(row.map(|(device, tools)| (device.into(), tools)))
    }

    /// 用户有没有登录着的电脑（不管在不在线）。
    pub async fn has_computer(&mut self, user: UserId) -> Result<bool> {
        Ok(sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM devices WHERE user_id = $1 AND platform = 'macos' \
               AND revoked_at IS NULL)",
        )
        .bind(user.0)
        .fetch_one(self.conn())
        .await?)
    }

    /// 写一个发给电脑的调用，通知连着这台电脑的中继。
    pub async fn create_device_call(&mut self, call: &NewDeviceCall) -> Result<DeviceCallId> {
        let id = DeviceCallId::new();
        sqlx::query(
            "INSERT INTO device_calls (id, user_id, device_id, run_id, tool, arguments, expires_at) \
             VALUES ($1, $2, $3, $4, $5, $6, now() + make_interval(secs => $7))",
        )
        .bind(id.0)
        .bind(call.user.0)
        .bind(call.device.0)
        .bind(call.run.map(|r| r.0))
        .bind(&call.tool)
        .bind(&call.arguments)
        .bind(secs(call.timeout))
        .execute(self.conn())
        .await?;
        self.notify_channel(DEVICE_CHANNEL, &call.device.to_string())
            .await?;
        Ok(id)
    }

    pub async fn device_call(&mut self, id: DeviceCallId) -> Result<DeviceCallRecord> {
        let (device, state, result, error): (Uuid, String, Option<Value>, Option<String>) =
            sqlx::query_as(
                "SELECT device_id, state, result, error FROM device_calls WHERE id = $1",
            )
            .bind(id.0)
            .fetch_one(self.conn())
            .await?;
        Ok(DeviceCallRecord {
            id,
            device: device.into(),
            state: parse(&state)?,
            result,
            error,
        })
    }

    /// 平台不等了：还没结果的调用标成过期（中继不再转出、回来的结果不收）。
    /// 已经有结果了返回 false。
    pub async fn expire_device_call(&mut self, id: DeviceCallId) -> Result<bool> {
        let done = sqlx::query(
            "UPDATE device_calls SET state = 'expired', finished_at = now() \
             WHERE id = $1 AND state IN ('pending', 'sent')",
        )
        .bind(id.0)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected() == 1)
    }

    /// 数据维护：删掉建了超过 `older_than` 的调用（结果里可能有截图、文件内容，用完就不留）
    /// 和消息，以及中继副本挂掉留下的、早就不新鲜的在线状态。返回删掉的行数。
    pub async fn purge_device_traffic(&mut self, older_than: Duration) -> Result<u64> {
        let mut n = 0;
        for sql in [
            "DELETE FROM device_calls WHERE created_at < now() - make_interval(secs => $1)",
            "DELETE FROM device_messages WHERE created_at < now() - make_interval(secs => $1)",
            "DELETE FROM device_links WHERE last_seen_at < now() - make_interval(secs => $1)",
        ] {
            n += sqlx::query(sql)
                .bind(secs(older_than))
                .execute(self.conn())
                .await?
                .rows_affected();
        }
        Ok(n)
    }
}

impl Tx<Tenant> {
    /// 手机（`from`，当前设备）发给电脑的消息：配对应答、审批决定、能力令牌、吊销。
    pub async fn send_device_message(
        &mut self,
        from: DeviceId,
        to: DeviceId,
        kind: DeviceMessageKind,
        body: &Value,
    ) -> Result<DeviceMessage> {
        let user = self.user();
        self.insert_device_message(user, from, to, kind, body).await
    }

    /// 电脑发给这台设备、还没收的消息。
    pub async fn pending_device_messages(
        &mut self,
        device: DeviceId,
        limit: i64,
    ) -> Result<Vec<DeviceMessage>> {
        let user = self.user();
        self.device_inbox(user, device, limit).await
    }

    /// 这台设备收下了这些消息。
    pub async fn ack_device_messages(
        &mut self,
        device: DeviceId,
        ids: &[DeviceMessageId],
    ) -> Result<u64> {
        let user = self.user();
        self.ack_device_inbox(user, device, ids).await
    }

    /// 现在在线的电脑（中继最近刷新过它的连接）。
    pub async fn online_devices(&mut self) -> Result<Vec<DeviceId>> {
        let ids: Vec<Uuid> = sqlx::query_scalar(
            "SELECT device_id FROM device_links WHERE last_seen_at > now() - make_interval(secs => $1)",
        )
        .bind(secs(LINK_FRESH))
        .fetch_all(self.conn())
        .await?;
        Ok(ids.into_iter().map(Into::into).collect())
    }
}
