//! 模型网关的用量记录（5.7、9.4）：每个请求一行，计费 token 是预算护栏和日限额的依据。

use proto::domain::{CredentialId, GrantId, InstanceId, UserId};
use uuid::Uuid;

use crate::{Result, Tx, signed};

#[derive(Debug, Clone, Default)]
pub struct NewUsage {
    pub user: UserId,
    pub instance: InstanceId,
    pub run_grant: Option<GrantId>,
    pub credential: Option<CredentialId>,
    pub alias: String,
    pub vendor: String,
    pub upstream_model: String,
    pub endpoint: String,
    pub stream: bool,
    pub status: u16,
    pub outcome: String,
    pub input_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub output_tokens: u64,
    /// 计费 token（拿不到用量时是保守估计）。
    pub charged_tokens: u64,
    pub estimated: bool,
    pub duration_ms: u64,
}

impl<R: crate::Internal> Tx<R> {
    pub async fn insert_usage(&mut self, u: &NewUsage) -> Result<()> {
        sqlx::query(
            "INSERT INTO usage_records (id, user_id, instance_id, run_grant_id, credential_id, alias, vendor, \
               upstream_model, endpoint, stream, status, outcome, input_tokens, cache_read_tokens, \
               cache_write_tokens, output_tokens, charged_tokens, estimated, duration_ms) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19)",
        )
        .bind(Uuid::now_v7())
        .bind(u.user.0)
        .bind(u.instance.0)
        .bind(u.run_grant.map(|g| g.0))
        .bind(u.credential.map(|c| c.0))
        .bind(&u.alias)
        .bind(&u.vendor)
        .bind(&u.upstream_model)
        .bind(&u.endpoint)
        .bind(u.stream)
        .bind(i32::from(u.status))
        .bind(&u.outcome)
        .bind(signed(u.input_tokens, "input_tokens")?)
        .bind(signed(u.cache_read_tokens, "cache_read_tokens")?)
        .bind(signed(u.cache_write_tokens, "cache_write_tokens")?)
        .bind(signed(u.output_tokens, "output_tokens")?)
        .bind(signed(u.charged_tokens, "charged_tokens")?)
        .bind(u.estimated)
        .bind(signed(u.duration_ms, "duration_ms")?)
        .execute(self.conn())
        .await?;
        Ok(())
    }
}
