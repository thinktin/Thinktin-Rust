//! 实时活动（WBS 10.6）：iOS 的灵动岛、锁屏上显示运行的进度。
//!
//! 每台设备、每个运行一行。App 自己开的实时活动把它的推送令牌报上来；计划到点开始的根运行，后台按设备的推送开启
//! 令牌远程开启，App 拿到新实时活动的令牌后同样报上来。后台在运行的状态、步数和上次发的不一样时发更新（几次变化
//! 合成一次，只看现在的状态），运行结束发 end。多个后台副本按锁分着发。

use std::time::Duration;

use chrono::{DateTime, Utc};
use proto::domain::{DeviceId, InstanceId, RunId, RunState, UserId};
use uuid::Uuid;

use crate::{Error, Result, Tenant, Tx, Worker, parse, secs};

/// 实时活动最多显示 8 小时（苹果的上限，之后系统自己结束）：开了更久的不再发，也不算开着的。
const MAX_AGE_SECS: f64 = 8.0 * 3600.0;

/// 运行结束这么久以后不能再登记（实时活动的令牌在运行结束前后才到的，end 还要发得到；早就结束了的
/// App 自己在本地结束它）。
const LATE_REGISTER_SECS: f64 = 600.0;

/// 后台领到的、该发的一个实时活动，连同运行现在的样子。
#[derive(Clone, PartialEq)]
pub struct LiveActivity {
    pub device_id: DeviceId,
    pub run_id: RunId,
    pub user_id: UserId,
    /// 后台远程开启的（不是 App 自己开的）。
    pub pushed: bool,
    /// 这个实时活动的推送令牌；远程开启的在 App 报上来之前没有。
    pub push_token: Option<String>,
    /// 设备的推送开启令牌（远程开启用）。
    pub start_token: Option<String>,
    /// 设备登记的是 APNs 沙盒环境的推送令牌（开发包，10.7）：实时活动也发到沙盒环境。
    pub sandbox: bool,
    pub start_sent: bool,
    pub sent_state: Option<RunState>,
    pub sent_steps: Option<u32>,
    /// 连着失败了几次。
    pub attempts: u32,
    pub instance_id: InstanceId,
    pub instance_name: String,
    pub state: RunState,
    /// 运行在等什么（`proto::domain::wait_code`），等 key、等电脑时有。
    pub wait_code: Option<String>,
    pub steps: u32,
    pub started_at: Option<DateTime<Utc>>,
    pub finished_at: Option<DateTime<Utc>>,
}

impl std::fmt::Debug for LiveActivity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LiveActivity")
            .field("device_id", &self.device_id)
            .field("run_id", &self.run_id)
            .field("pushed", &self.pushed)
            .field("sandbox", &self.sandbox)
            .field("has_push_token", &self.push_token.is_some())
            .field("start_sent", &self.start_sent)
            .field("sent_state", &self.sent_state)
            .field("state", &self.state)
            .field("steps", &self.steps)
            .finish_non_exhaustive()
    }
}

/// 发完一个实时活动后记下的结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LiveSettle {
    /// 发出去了：记下发的状态、等待原因和步数。`started` 是远程开启的那一次，`ended` 是发了 end。
    Sent {
        state: RunState,
        steps: u32,
        started: bool,
        ended: bool,
        /// 发出去的 `waitCode`（不在等时没有）。
        wait_code: Option<String>,
    },
    /// 暂时失败：`at` 再试。
    Retry { error: String, at: DateTime<Utc> },
    /// 连着暂时失败太多次，不再发（App 再登记同一个令牌可以从头来）。
    GiveUp { error: String },
    /// 不再发（令牌失效、请求被拒、没开启运行就结束了）。
    End { error: Option<String> },
}

#[derive(sqlx::FromRow)]
struct Row {
    device_id: Uuid,
    run_id: Uuid,
    user_id: Uuid,
    origin: String,
    push_token: Option<String>,
    start_sent_at: Option<DateTime<Utc>>,
    sent_state: Option<String>,
    sent_steps: Option<i32>,
    attempts: i32,
    activity_start_token: Option<String>,
    sandbox: bool,
    instance_id: Uuid,
    name: String,
    state: String,
    wait_code: Option<String>,
    steps: i32,
    started_at: Option<DateTime<Utc>>,
    finished_at: Option<DateTime<Utc>>,
}

impl Row {
    fn into_activity(self) -> Result<LiveActivity> {
        let count = |n: i32, what: &str| {
            u32::try_from(n).map_err(|_| Error::Corrupt(format!("negative {what}")))
        };
        Ok(LiveActivity {
            device_id: self.device_id.into(),
            run_id: self.run_id.into(),
            user_id: self.user_id.into(),
            pushed: self.origin == "push",
            push_token: self.push_token,
            start_token: self.activity_start_token,
            sandbox: self.sandbox,
            start_sent: self.start_sent_at.is_some(),
            sent_state: self.sent_state.as_deref().map(parse).transpose()?,
            sent_steps: self.sent_steps.map(|n| count(n, "steps")).transpose()?,
            attempts: count(self.attempts, "attempts")?,
            instance_id: self.instance_id.into(),
            instance_name: self.name,
            state: parse(&self.state)?,
            wait_code: self.wait_code,
            steps: count(self.steps, "steps")?,
            started_at: self.started_at,
            finished_at: self.finished_at,
        })
    }
}

impl Tx<Tenant> {
    /// App 开了一个实时活动（或者远程开启的那个拿到了令牌）：登记它的推送令牌。一台设备一个运行只有一个：
    /// 换了令牌（新的实时活动）就把发过的内容清掉、8 小时从现在算，现在的状态再发一次（离上次发照样要隔一阵）；同一个令牌再报一次什么都不变
    /// （放弃了的从头来）。只有 iPhone、iPad 有实时活动；一台设备同时开着的最多 `max_open` 个；运行结束很久了的
    /// 不能登记。
    pub async fn register_live_activity(
        &mut self,
        device: DeviceId,
        run: RunId,
        token: &str,
        max_open: u32,
    ) -> Result<()> {
        // 按设备加锁：数和插入在同一个事务里，并发的请求不能一起超过上限。
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
            .bind(format!("live_activities/{}", device.0))
            .execute(self.conn())
            .await?;
        let late: Option<bool> = sqlx::query_scalar(
            "SELECT coalesce(finished_at < now() - make_interval(secs => $2), false) FROM runs WHERE id = $1",
        )
        .bind(run.0)
        .bind(LATE_REGISTER_SECS)
        .fetch_optional(self.conn())
        .await?;
        match late {
            None => return Err(Error::NotFound),
            Some(true) => return Err(Error::Invalid("the run has already finished".into())),
            Some(false) => {}
        }
        let ios: Option<i32> = sqlx::query_scalar(
            "SELECT 1 FROM devices WHERE id = $1 AND revoked_at IS NULL AND platform = 'ios'",
        )
        .bind(device.0)
        .fetch_optional(self.conn())
        .await?;
        if ios.is_none() {
            return Err(Error::Invalid(
                "live activities are only available on iPhone and iPad".into(),
            ));
        }
        let open: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM live_activities WHERE device_id = $1 AND run_id <> $2 \
               AND ended_at IS NULL AND created_at > now() - make_interval(secs => $3)",
        )
        .bind(device.0)
        .bind(run.0)
        .bind(MAX_AGE_SECS)
        .fetch_one(self.conn())
        .await?;
        if open >= i64::from(max_open) {
            return Err(Error::Invalid(format!(
                "at most {max_open} live activities at a time on one device"
            )));
        }
        // 上次发的时间和锁不动：换令牌换得再勤也只是隔一阵发一次，正在发的那一次记不上（令牌对不上），放开锁后
        // 新令牌接着发。
        sqlx::query(
            "INSERT INTO live_activities (device_id, run_id, user_id, origin, push_token) \
             SELECT d.id, $2, d.user_id, 'app', $3 FROM devices d WHERE d.id = $1 \
             ON CONFLICT (device_id, run_id) DO UPDATE SET push_token = EXCLUDED.push_token, \
               sent_state = NULL, sent_steps = NULL, sent_wait_code = NULL, attempts = 0, retry_at = NULL, last_error = NULL, \
               ended_at = NULL, gave_up = false, \
               created_at = CASE WHEN live_activities.push_token IS DISTINCT FROM EXCLUDED.push_token \
                 THEN now() ELSE live_activities.created_at END \
             WHERE live_activities.push_token IS DISTINCT FROM EXCLUDED.push_token OR live_activities.gave_up",
        )
        .bind(device.0)
        .bind(run.0)
        .bind(token)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// App 关掉了这个运行的实时活动（用户划掉了、App 自己结束了）：不再发。没登记过也算成功。
    pub async fn end_live_activity(&mut self, device: DeviceId, run: RunId) -> Result<()> {
        sqlx::query(
            "UPDATE live_activities SET ended_at = now(), gave_up = false \
             WHERE device_id = $1 AND run_id = $2 AND (ended_at IS NULL OR gave_up)",
        )
        .bind(device.0)
        .bind(run.0)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 登记（`Some`）或清掉（`None`）这台设备的推送开启令牌。只有 iPhone、iPad 能登记。
    pub async fn set_activity_start_token(
        &mut self,
        device: DeviceId,
        token: Option<&str>,
    ) -> Result<()> {
        let done = sqlx::query(
            "UPDATE devices SET activity_start_token = $2 \
             WHERE id = $1 AND revoked_at IS NULL AND ($2::text IS NULL OR platform = 'ios')",
        )
        .bind(device.0)
        .bind(token)
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            return Err(Error::Invalid(
                "live activities are only available on iPhone and iPad".into(),
            ));
        }
        Ok(())
    }
}

impl Tx<Worker> {
    /// 一个推送开启令牌只属于一台设备：同一台手机换了账号登录，之前账号的设备不再远程开启。
    pub async fn release_activity_start_token(
        &mut self,
        keep: DeviceId,
        token: &str,
    ) -> Result<u64> {
        let done = sqlx::query(
            "UPDATE devices SET activity_start_token = NULL WHERE activity_start_token = $2 AND id <> $1",
        )
        .bind(keep.0)
        .bind(token)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }

    /// 推送开启令牌失效了：清掉（只在令牌没被 App 换过时清）。
    pub async fn clear_activity_start_token(
        &mut self,
        device: DeviceId,
        token: &str,
    ) -> Result<()> {
        sqlx::query(
            "UPDATE devices SET activity_start_token = NULL WHERE id = $1 AND activity_start_token = $2",
        )
        .bind(device.0)
        .bind(token)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 计划到点开始的根运行：用户登录着、登记了推送开启令牌的每台设备各记一个待开启的实时活动（在领取运行的
    /// 事务里写）。一台设备同时开着的远程开启的最多 `max_open` 个（苹果对远程开启也有预算）。返回记了几个。
    pub async fn queue_live_starts(
        &mut self,
        user: UserId,
        run: RunId,
        max_open: u32,
    ) -> Result<u64> {
        // 按用户加锁：两个副本同时领到这个用户的两个计划运行，数和插入也不能一起超过上限。
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
            .bind(format!("live_starts/{}", user.0))
            .execute(self.conn())
            .await?;
        let done = sqlx::query(
            "INSERT INTO live_activities (device_id, run_id, user_id, origin) \
             SELECT d.id, $2, d.user_id, 'push' FROM devices d \
             WHERE d.user_id = $1 AND d.revoked_at IS NULL AND d.platform = 'ios' \
               AND d.activity_start_token IS NOT NULL \
               AND EXISTS (SELECT 1 FROM sessions s WHERE s.device_id = d.id \
                             AND s.revoked_at IS NULL AND s.expires_at > now()) \
               AND (SELECT count(*) FROM live_activities o WHERE o.device_id = d.id AND o.origin = 'push' \
                      AND o.ended_at IS NULL AND o.created_at > now() - make_interval(secs => $4)) < $3 \
             ON CONFLICT (device_id, run_id) DO NOTHING",
        )
        .bind(user.0)
        .bind(run.0)
        .bind(i64::from(max_open))
        .bind(MAX_AGE_SECS)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }

    /// 领该发的实时活动，锁 `lock_for`。步数连同直接子运行的一起算（流水线的步骤、委派的子任务）。待远程开启的；还没发过的；状态变了、离上次发过了 `state_gap` 的；只是步数变了、
    /// 离上次发过了 `step_gap` 的（步数变得勤，苹果对更新也有预算）；还有远程开启了却一直没拿到令牌、运行已经结束的
    /// （没法再发，了结掉）。设备下线了、开了太久的不领。先轮一遍每个用户等得最久的那一个，再轮第二个……一个用户
    /// 一次最多 `per_user` 个：刷令牌的账号再多，每个用户的实时活动每一批都排得上（只要这一批里的用户不比整批多）。
    /// 等了多久从上次发、或者登记（换了令牌）算起，刚换过令牌的排到后面。
    pub async fn claim_live_activities(
        &mut self,
        owner: &str,
        lock_for: Duration,
        limit: i64,
        per_user: i64,
        state_gap: Duration,
        step_gap: Duration,
    ) -> Result<Vec<LiveActivity>> {
        let rows: Vec<Row> = sqlx::query_as(
            "WITH cand AS ( \
               SELECT x.device_id, x.run_id, greatest(x.sent_at, x.created_at) AS since, t.steps, \
                 row_number() OVER (PARTITION BY x.user_id ORDER BY greatest(x.sent_at, x.created_at)) AS n \
               FROM live_activities x \
               JOIN runs r ON r.id = x.run_id \
               CROSS JOIN LATERAL (SELECT r.steps + coalesce((SELECT sum(c.steps) FROM runs c \
                 WHERE c.parent_run_id = r.id), 0)::int AS steps) t \
               JOIN devices d ON d.id = x.device_id \
               WHERE x.ended_at IS NULL AND d.revoked_at IS NULL \
                 AND x.created_at > now() - make_interval(secs => $6) \
                 AND (x.locked_until IS NULL OR x.locked_until < now()) \
                 AND (x.retry_at IS NULL OR x.retry_at <= now()) \
                 AND CASE WHEN x.push_token IS NULL THEN \
                       x.origin = 'push' AND ((x.start_sent_at IS NULL AND d.activity_start_token IS NOT NULL) \
                         OR r.state IN ('succeeded', 'failed', 'cancelled')) \
                     ELSE x.sent_at IS NULL \
                       OR ((r.state IS DISTINCT FROM x.sent_state OR r.wait_code IS DISTINCT FROM x.sent_wait_code) \
                           AND x.sent_at <= now() - make_interval(secs => $4)) \
                       OR (t.steps IS DISTINCT FROM x.sent_steps AND x.sent_at <= now() - make_interval(secs => $5)) \
                     END), \
             due AS ( \
               SELECT x.device_id, x.run_id, c.steps FROM live_activities x \
               JOIN cand c ON c.device_id = x.device_id AND c.run_id = x.run_id \
               WHERE c.n <= $7 AND x.ended_at IS NULL \
                 AND (x.locked_until IS NULL OR x.locked_until < now()) \
               ORDER BY c.n, c.since \
               LIMIT $3 \
               FOR UPDATE OF x SKIP LOCKED), \
             claimed AS ( \
               UPDATE live_activities la SET locked_by = $1, locked_until = now() + make_interval(secs => $2) \
               FROM due WHERE la.device_id = due.device_id AND la.run_id = due.run_id \
               RETURNING la.device_id, la.run_id, la.user_id, la.origin, la.push_token, la.start_sent_at, \
                 la.sent_state, la.sent_steps, la.attempts) \
             SELECT c.*, d.activity_start_token, coalesce(d.push_channel = 'apns_sandbox', false) AS sandbox, \
               r.instance_id, i.name, r.state, r.wait_code, due.steps, r.started_at, \
               r.finished_at \
             FROM claimed c JOIN due ON due.device_id = c.device_id AND due.run_id = c.run_id \
               JOIN runs r ON r.id = c.run_id JOIN instances i ON i.id = r.instance_id \
               JOIN devices d ON d.id = c.device_id",
        )
        .bind(owner)
        .bind(secs(lock_for))
        .bind(limit)
        .bind(secs(state_gap))
        .bind(secs(step_gap))
        .bind(MAX_AGE_SECS)
        .bind(per_user)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_activity).collect()
    }

    /// 发之前续锁：锁还在自己手里、还该发，就再锁 `lock_for`。返回 `false` 时不要发：锁过期了（别人可能已经领了去发），
    /// 或者领了以后不该发了（App 关掉了、设备下线了、同一台手机换了账号）。`start_token` 是要远程开启时用的推送开启
    /// 令牌：设备上的已经不是它（用户关掉了、换了账号）也不发。
    pub async fn extend_live_lock(
        &mut self,
        device: DeviceId,
        run: RunId,
        owner: &str,
        lock_for: Duration,
        start_token: Option<&str>,
    ) -> Result<bool> {
        let done = sqlx::query(
            "UPDATE live_activities x SET locked_until = now() + make_interval(secs => $4) \
             FROM devices d \
             WHERE x.device_id = $1 AND x.run_id = $2 AND x.locked_by = $3 AND x.locked_until > now() \
               AND x.ended_at IS NULL AND d.id = x.device_id AND d.revoked_at IS NULL \
               AND ($5::text IS NULL OR d.activity_start_token = $5)",
        )
        .bind(device.0)
        .bind(run.0)
        .bind(owner)
        .bind(secs(lock_for))
        .bind(start_token)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected() == 1)
    }

    /// 记下发送结果，放开锁。`token` 是这次发给的实时活动令牌（远程开启的那一次是 `None`）：发送期间 App 换了令牌，
    /// 结果不记（新令牌还没收到），只放开锁，新令牌接着发。锁已经不在自己手里（过期后被别人领了）返回
    /// [`Error::LeaseLost`]。
    pub async fn settle_live_activity(
        &mut self,
        device: DeviceId,
        run: RunId,
        owner: &str,
        token: Option<&str>,
        settle: &LiveSettle,
    ) -> Result<()> {
        // 只记自己锁着、令牌没换过的。
        macro_rules! mine {
            ($set:literal) => {
                concat!(
                    "UPDATE live_activities SET ",
                    $set,
                    ", locked_by = NULL, locked_until = NULL \
                     WHERE device_id = $1 AND run_id = $2 AND locked_by = $3 \
                       AND push_token IS NOT DISTINCT FROM $4"
                )
            };
        }
        let sql = match settle {
            LiveSettle::Sent { .. } => mine!(
                "sent_state = $5, sent_steps = $6, sent_wait_code = $9, sent_at = now(), \
                 start_sent_at = CASE WHEN $7 THEN now() ELSE start_sent_at END, \
                 ended_at = CASE WHEN $8 THEN coalesce(ended_at, now()) ELSE ended_at END, \
                 attempts = 0, retry_at = NULL, last_error = NULL"
            ),
            LiveSettle::Retry { .. } => {
                mine!("attempts = attempts + 1, last_error = $5, retry_at = $6")
            }
            LiveSettle::GiveUp { .. } => mine!(
                "gave_up = ended_at IS NULL, ended_at = coalesce(ended_at, now()), last_error = $5"
            ),
            LiveSettle::End { .. } => {
                mine!("ended_at = coalesce(ended_at, now()), last_error = coalesce($5, last_error)")
            }
        };
        let cut = |e: &str| e.chars().take(500).collect::<String>();
        let q = sqlx::query(sql)
            .bind(device.0)
            .bind(run.0)
            .bind(owner)
            .bind(token);
        let q = match settle {
            LiveSettle::Sent {
                state,
                steps,
                started,
                ended,
                wait_code,
            } => q
                .bind(state.as_str())
                .bind(i32::try_from(*steps).unwrap_or(i32::MAX))
                .bind(started)
                .bind(ended)
                .bind(wait_code.as_deref()),
            LiveSettle::Retry { error, at } => q.bind(cut(error)).bind(at),
            LiveSettle::GiveUp { error } => q.bind(cut(error)),
            LiveSettle::End { error } => q.bind(error.as_deref().map(cut)),
        };
        if q.execute(self.conn()).await?.rows_affected() == 1 {
            return Ok(());
        }
        // 令牌换了：只放开锁。
        let released = sqlx::query(
            "UPDATE live_activities SET locked_by = NULL, locked_until = NULL \
             WHERE device_id = $1 AND run_id = $2 AND locked_by = $3",
        )
        .bind(device.0)
        .bind(run.0)
        .bind(owner)
        .execute(self.conn())
        .await?;
        if released.rows_affected() == 0 {
            return Err(Error::LeaseLost {
                owner: owner.to_owned(),
            });
        }
        Ok(())
    }

    /// 维护任务：删掉开了 `older` 以上的（早就不显示了）。返回删了几行。
    pub async fn purge_live_activities(&mut self, older: Duration) -> Result<u64> {
        let done = sqlx::query(
            "DELETE FROM live_activities WHERE created_at < now() - make_interval(secs => $1)",
        )
        .bind(secs(older))
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected())
    }
}
