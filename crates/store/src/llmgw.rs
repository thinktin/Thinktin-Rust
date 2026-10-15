//! 模型网关读的路由数据（9.2）和写的用量（9.4）。网关用 `thinktin_llmgw` 角色连接：
//! 只能读路由相关的表、写用量，碰不到对话、事件这些数据。

use chrono::{DateTime, Utc};
use proto::domain::{CredentialId, GrantId, InstanceId, InstanceLimits, UserId};
use uuid::Uuid;

use crate::{Llmgw, Result, Tx, from_json, unsigned};

/// 网关校验沙箱令牌、选路要的实例信息。
#[derive(Debug, Clone, PartialEq)]
pub struct GatewayInstance {
    pub id: InstanceId,
    pub user_id: UserId,
    /// 只有运行中的实例能用模型。
    pub running: bool,
    /// 当前沙箱：令牌里的沙箱 id 必须是它。
    pub sandbox_id: Option<String>,
    /// 令牌代数：令牌里的必须是它（运行结束后旧令牌失效）。
    pub token_epoch: u64,
    pub limits: InstanceLimits,
    /// （别名，凭证，上游模型）
    pub routes: Vec<(String, CredentialId, String)>,
}

impl Tx<Llmgw> {
    pub async fn gateway_instance(&mut self, id: InstanceId) -> Result<Option<GatewayInstance>> {
        let row: Option<(Uuid, String, Option<String>, serde_json::Value, i64)> = sqlx::query_as(
            "SELECT user_id, state, sandbox_id, limits, token_epoch FROM instances WHERE id = $1",
        )
        .bind(id.0)
        .fetch_optional(self.conn())
        .await?;
        let Some((user, state, sandbox_id, limits, token_epoch)) = row else {
            return Ok(None);
        };
        let routes: Vec<(String, Uuid, String)> = sqlx::query_as(
            "SELECT alias, credential_id, upstream_model FROM model_routes WHERE instance_id = $1 ORDER BY alias",
        )
        .bind(id.0)
        .fetch_all(self.conn())
        .await?;
        let limits: InstanceLimits = if limits.as_object().is_some_and(|o| o.is_empty()) {
            InstanceLimits::default()
        } else {
            from_json(limits, "instance limits")?
        };
        Ok(Some(GatewayInstance {
            id,
            user_id: UserId(user),
            running: state == "running",
            sandbox_id,
            token_epoch: u64::try_from(token_epoch).unwrap_or_default(),
            limits,
            routes: routes
                .into_iter()
                .map(|(a, c, m)| (a, CredentialId(c), m))
                .collect(),
        }))
    }

    /// 还能用的授权允许的模型别名（空表示实例配置的全部）；授权被吊销、过期或者不存在时为 None。
    pub async fn usable_grant_aliases(&mut self, grant: GrantId) -> Result<Option<Vec<String>>> {
        let row: Option<(bool, serde_json::Value)> = sqlx::query_as(concat!(
            "SELECT revoked_at IS NULL AND expires_at > now() AND ",
            crate::grants::ancestors_usable!(),
            ", scope FROM run_grants WHERE id = $1"
        ))
        .bind(grant.0)
        .fetch_optional(self.conn())
        .await?;
        match row {
            Some((true, scope)) => {
                let scope: proto::domain::GrantScope = from_json(scope, "grant scope")?;
                Ok(Some(scope.aliases))
            }
            _ => Ok(None),
        }
    }

    /// 一把 key 从 `since` 起计费的 token 数（每日预算）。
    pub async fn credential_tokens_since(
        &mut self,
        credential: CredentialId,
        since: DateTime<Utc>,
    ) -> Result<u64> {
        let n: i64 = sqlx::query_scalar(
            "SELECT coalesce(sum(charged_tokens), 0)::bigint FROM usage_records \
             WHERE credential_id = $1 AND created_at >= $2",
        )
        .bind(credential.0)
        .bind(since)
        .fetch_one(self.conn())
        .await?;
        unsigned(n, "charged tokens")
    }
}
