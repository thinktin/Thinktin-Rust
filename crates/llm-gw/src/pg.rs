//! 生产环境的数据来源：控制面的 Postgres（`thinktin_llmgw` 角色，只读路由数据、写用量）。
//!
//! - [`PgDirectory`]：实例、凭证、授权状态按短时缓存读；令牌里的沙箱和缓存对不上时网关会要求重读
//!   （实例刚唤醒换了沙箱）。读凭证时顺手把用户的包裹 DEK 放进共享的密钥库，解密由 KeyVault 做；
//! - [`PgUsageSink`]：计量记录进队列，后台批量写用量表（执行器的 token 预算、用量看板都读它）；
//! - [`PgLedger`]：按 key 的每日预算以用量表的汇总为准（多副本共享），加上本副本还没落库的记账。

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use chrono::{TimeZone, Utc};
use keyvault::{KeyStore, MemoryKeyStore, SealedSecret, WrappedKey};
use proto::domain::{CredentialId, GrantId, InstanceId, UserId};
use store::{Db, NewUsage};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use crate::limits::BudgetLedger;
use crate::store::{Credential, Directory, Fallback, Instance, Limits, Route, SealedVault};
use crate::usage::{UsageRecord, UsageSink};

/// 缓存条目上限，超过时清掉过期的。
const MAX_CACHED: usize = 50_000;

struct Cached<T> {
    at: Instant,
    value: T,
}

struct TtlMap<T>(Mutex<HashMap<String, Cached<T>>>);

impl<T: Clone> TtlMap<T> {
    fn new() -> Self {
        Self(Mutex::new(HashMap::new()))
    }

    fn get(&self, key: &str, ttl: Duration) -> Option<T> {
        let map = self.0.lock().unwrap_or_else(|e| e.into_inner());
        map.get(key)
            .filter(|c| c.at.elapsed() < ttl)
            .map(|c| c.value.clone())
    }

    fn put(&self, key: &str, value: T, ttl: Duration) {
        let mut map = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if map.len() >= MAX_CACHED {
            map.retain(|_, c| c.at.elapsed() < ttl);
        }
        map.insert(
            key.to_owned(),
            Cached {
                at: Instant::now(),
                value,
            },
        );
    }
}

pub struct PgDirectory {
    db: Db,
    keys: Arc<MemoryKeyStore>,
    ttl: Duration,
    instances: TtlMap<Option<Arc<Instance>>>,
    credentials: TtlMap<Option<Arc<Credential>>>,
    /// 授权 → 允许的别名；None 表示不能用。
    grants: TtlMap<Option<Arc<Vec<String>>>>,
}

impl PgDirectory {
    /// `keys` 要和网关解密用的 KeyVault 共用。`ttl` 决定吊销、改路由最多多久后生效。
    pub fn new(db: Db, keys: Arc<MemoryKeyStore>, ttl: Duration) -> Self {
        Self {
            db,
            keys,
            ttl,
            instances: TtlMap::new(),
            credentials: TtlMap::new(),
            grants: TtlMap::new(),
        }
    }

    async fn load_instance(&self, id: &str) -> store::Result<Option<Arc<Instance>>> {
        let Ok(id) = id.parse::<InstanceId>() else {
            return Ok(None);
        };
        let mut tx = self.db.llmgw().await?;
        let row = tx.gateway_instance(id).await?;
        tx.rollback().await?;
        Ok(row.map(|i| {
            Arc::new(Instance {
                id: i.id.to_string(),
                user_id: i.user_id.to_string(),
                sandbox: i.sandbox_id,
                epoch: i.token_epoch,
                active: i.running,
                routes: i
                    .routes
                    .into_iter()
                    .map(|r| {
                        (
                            r.alias,
                            Route {
                                credential: r.credential.to_string(),
                                model: r.model,
                                fallbacks: r
                                    .fallbacks
                                    .into_iter()
                                    .map(|(credential, model)| Fallback {
                                        credential: credential.to_string(),
                                        model,
                                    })
                                    .collect(),
                            },
                        )
                    })
                    .collect(),
                limits: Limits {
                    requests_per_minute: i.limits.requests_per_minute,
                    max_concurrent: i.limits.max_concurrent,
                },
            })
        }))
    }

    async fn load_credential(&self, id: &str) -> store::Result<Option<Arc<Credential>>> {
        let Ok(id) = id.parse::<CredentialId>() else {
            return Ok(None);
        };
        let mut tx = self.db.llmgw().await?;
        let Some(c) = tx.sealed_credential(id).await? else {
            tx.rollback().await?;
            return Ok(None);
        };
        let key = tx.user_key(c.user_id).await?;
        tx.rollback().await?;
        let uid = c.user_id.to_string();
        // 用户注销后 DEK 已销毁：密钥库里也不留。
        if !self.remember_user_key(&uid, key) {
            return Ok(None);
        }
        Ok(Some(Arc::new(Credential {
            id: c.id.to_string(),
            user_id: uid,
            vendor: c.vendor,
            anthropic_base: c.anthropic_base,
            openai_base: c.openai_base,
            responses_base: c.responses_base,
            secret: SealedSecret {
                ciphertext: c.sealed,
                last4: c.last4,
            },
            daily_token_limit: c.daily_token_limit,
            disabled: c.disabled,
        })))
    }

    async fn load_grant(&self, grant: &str) -> store::Result<Option<Arc<Vec<String>>>> {
        let Ok(id) = grant.parse::<GrantId>() else {
            return Ok(None);
        };
        let mut tx = self.db.llmgw().await?;
        let r = tx.usable_grant_aliases(id).await?;
        tx.rollback().await?;
        Ok(r.map(Arc::new))
    }

    /// 把用户的包裹 DEK 放进共享的密钥库（解密 key 和保险箱条目都要它）；用户注销后清掉。
    fn remember_user_key(&self, uid: &str, key: Option<(String, Vec<u8>)>) -> bool {
        match key {
            Some((kms_key_id, ciphertext)) => {
                let wrapped = WrappedKey {
                    kms_key_id,
                    ciphertext,
                };
                if self.keys.get(uid).as_ref() != Some(&wrapped) {
                    self.keys.remove(uid);
                    self.keys.insert_new(uid, wrapped);
                }
                true
            }
            None => {
                self.keys.remove(uid);
                false
            }
        }
    }

    async fn load_vault(&self, user_id: &str) -> store::Result<Vec<SealedVault>> {
        let Ok(user) = user_id.parse::<UserId>() else {
            return Ok(Vec::new());
        };
        let mut tx = self.db.llmgw().await?;
        let items = tx.vault_items_sealed(user).await?;
        let key = if items.is_empty() {
            None
        } else {
            tx.user_key(user).await?
        };
        tx.rollback().await?;
        if items.is_empty() || !self.remember_user_key(user_id, key) {
            return Ok(Vec::new());
        }
        Ok(items
            .into_iter()
            .map(|(id, name, sealed)| SealedVault {
                id: id.to_string(),
                name,
                sealed,
            })
            .collect())
    }

    /// 读不到时按不能用处理（宁可拒绝）。
    async fn grant(&self, grant: &str) -> Option<Arc<Vec<String>>> {
        if let Some(v) = self.grants.get(grant, self.ttl) {
            return v;
        }
        match self.load_grant(grant).await {
            Ok(v) => {
                self.grants.put(grant, v.clone(), self.ttl);
                v
            }
            Err(e) => {
                tracing::error!(error = %e, "loading run grant failed");
                None
            }
        }
    }
}

#[async_trait]
impl Directory for PgDirectory {
    async fn instance(&self, id: &str, fresh: bool) -> Option<Arc<Instance>> {
        if !fresh && let Some(v) = self.instances.get(id, self.ttl) {
            return v;
        }
        match self.load_instance(id).await {
            Ok(v) => {
                self.instances.put(id, v.clone(), self.ttl);
                v
            }
            Err(e) => {
                tracing::error!(error = %e, "loading instance failed");
                None
            }
        }
    }

    async fn credential(&self, id: &str) -> Option<Arc<Credential>> {
        if let Some(v) = self.credentials.get(id, self.ttl) {
            return v;
        }
        match self.load_credential(id).await {
            Ok(v) => {
                self.credentials.put(id, v.clone(), self.ttl);
                v
            }
            Err(e) => {
                tracing::error!(error = %e, "loading credential failed");
                None
            }
        }
    }

    async fn grant_revoked(&self, grant: &str) -> bool {
        self.grant(grant).await.is_none()
    }

    async fn grant_aliases(&self, grant: &str) -> Vec<String> {
        self.grant(grant)
            .await
            .map(|a| a.as_ref().clone())
            .unwrap_or_default()
    }

    async fn vault_items(&self, user_id: &str) -> Option<Vec<SealedVault>> {
        match self.load_vault(user_id).await {
            Ok(items) => Some(items),
            Err(e) => {
                tracing::error!(error = %e, "loading vault items failed");
                None
            }
        }
    }
}

// ---------- 用量 ----------

/// 计量记录写进用量表。队列满或者库写不进去时退回到日志（不丢账）。
pub struct PgUsageSink {
    tx: mpsc::Sender<UsageRecord>,
}

/// 后台写入任务。网关停机时先丢掉 [`PgUsageSink`]（关闭队列），再等它写完。
pub struct UsageWriter(JoinHandle<()>);

impl UsageWriter {
    pub async fn finish(self) {
        let _ = self.0.await;
    }
}

const USAGE_QUEUE: usize = 10_000;
const USAGE_BATCH: usize = 200;

impl PgUsageSink {
    pub fn spawn(db: Db) -> (Self, UsageWriter) {
        let (tx, rx) = mpsc::channel(USAGE_QUEUE);
        (Self { tx }, UsageWriter(tokio::spawn(write_usage(db, rx))))
    }
}

fn log_record(record: &UsageRecord, why: &str) {
    let json = serde_json::to_string(record).unwrap_or_default();
    tracing::warn!(target: "llm_gw::usage", usage = %json, why, "usage record not stored");
}

impl UsageSink for PgUsageSink {
    fn record(&self, record: UsageRecord) {
        if let Err(e) = self.tx.try_send(record) {
            let record = match e {
                mpsc::error::TrySendError::Full(r) | mpsc::error::TrySendError::Closed(r) => r,
            };
            log_record(&record, "queue full or closed");
        }
    }
}

fn new_usage(r: &UsageRecord) -> Option<NewUsage> {
    let usage = r.usage.unwrap_or_default();
    Some(NewUsage {
        user: r.user.parse::<UserId>().ok()?,
        instance: r.instance.parse::<InstanceId>().ok()?,
        run_grant: r.grant.parse::<GrantId>().ok(),
        credential: r.credential.parse::<CredentialId>().ok(),
        alias: r.alias.clone(),
        vendor: r.vendor.clone(),
        upstream_model: r.upstream_model.clone(),
        endpoint: r.endpoint.to_owned(),
        stream: r.stream,
        status: r.status,
        outcome: serde_json::to_value(r.outcome)
            .ok()
            .and_then(|v| v.as_str().map(str::to_owned))
            .unwrap_or_default(),
        input_tokens: usage.input_tokens,
        cache_read_tokens: usage.cache_read_tokens,
        cache_write_tokens: usage.cache_write_tokens,
        output_tokens: usage.output_tokens,
        charged_tokens: r.charged_tokens,
        estimated: r.estimated,
        duration_ms: r.duration_ms,
    })
}

async fn insert_batch(db: &Db, batch: &[UsageRecord]) -> store::Result<()> {
    let mut tx = db.llmgw().await?;
    for r in batch {
        match new_usage(r) {
            Some(u) => tx.insert_usage(&u).await?,
            None => log_record(r, "ids are not platform ids"),
        }
    }
    tx.commit().await
}

async fn write_usage(db: Db, mut rx: mpsc::Receiver<UsageRecord>) {
    let mut batch = Vec::with_capacity(USAGE_BATCH);
    loop {
        if rx.recv_many(&mut batch, USAGE_BATCH).await == 0 {
            return;
        }
        let mut delay = Duration::from_millis(200);
        let mut stored = false;
        for _ in 0..5 {
            match insert_batch(&db, &batch).await {
                Ok(()) => {
                    stored = true;
                    break;
                }
                Err(e) => {
                    tracing::warn!(error = %e, records = batch.len(), "storing usage failed, retrying");
                    tokio::time::sleep(delay).await;
                    delay *= 2;
                }
            }
        }
        if !stored {
            for r in &batch {
                log_record(r, "database unavailable");
            }
        }
        batch.clear();
    }
}

// ---------- 每日预算 ----------

struct DayUse {
    fetched: Instant,
    stored: u64,
    /// 本副本在上次查询之后记的账（可能还没落库）。
    local: u64,
}

pub struct PgLedger {
    db: Db,
    /// 切天的时区偏移（秒），和网关的 `budget_utc_offset_secs` 一致。
    offset_secs: i64,
    /// 汇总结果用多久再查。
    ttl: Duration,
    days: Mutex<HashMap<(String, u64), DayUse>>,
}

impl PgLedger {
    pub fn new(db: Db, offset_secs: i64, ttl: Duration) -> Self {
        Self {
            db,
            offset_secs,
            ttl,
            days: Mutex::new(HashMap::new()),
        }
    }

    async fn stored(&self, credential: CredentialId, day: u64) -> store::Result<u64> {
        let start = (day as i64) * 86_400 - self.offset_secs;
        let since = Utc
            .timestamp_opt(start, 0)
            .single()
            .unwrap_or_else(Utc::now);
        let mut tx = self.db.llmgw().await?;
        let n = tx.credential_tokens_since(credential, since).await?;
        tx.rollback().await?;
        Ok(n)
    }
}

#[async_trait]
impl BudgetLedger for PgLedger {
    async fn used(&self, credential: &str, day: u64) -> u64 {
        let key = (credential.to_owned(), day);
        {
            let days = self.days.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(d) = days.get(&key)
                && d.fetched.elapsed() < self.ttl
            {
                return d.stored.saturating_add(d.local);
            }
        }
        let Ok(id) = credential.parse::<CredentialId>() else {
            return 0;
        };
        match self.stored(id, day).await {
            Ok(stored) => {
                let mut days = self.days.lock().unwrap_or_else(|e| e.into_inner());
                days.retain(|(_, d), _| *d + 1 >= day);
                // 本地记的账这时多半已经落库，算进了 stored。
                days.insert(
                    key,
                    DayUse {
                        fetched: Instant::now(),
                        stored,
                        local: 0,
                    },
                );
                stored
            }
            Err(e) => {
                tracing::error!(error = %e, "reading daily usage failed");
                let days = self.days.lock().unwrap_or_else(|e| e.into_inner());
                days.get(&key)
                    .map_or(0, |d| d.stored.saturating_add(d.local))
            }
        }
    }

    fn add(&self, credential: &str, day: u64, tokens: u64) {
        let mut days = self.days.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(d) = days.get_mut(&(credential.to_owned(), day)) {
            d.local = d.local.saturating_add(tokens);
        }
    }
}
