//! 用户的模型 key（9.8）。库里只有密钥库封好的密文，对外只给后 4 位。

use chrono::{DateTime, Utc};
use proto::domain::{Credential, CredentialId};
use uuid::Uuid;

use crate::{Error, Result, Tenant, Tx, signed, unsigned};

/// 新增的 key。`sealed` 是密钥库用这个用户的 DEK 封好的密文。
#[derive(Clone)]
pub struct NewCredential {
    pub vendor: String,
    pub label: String,
    pub anthropic_base: Option<String>,
    pub openai_base: Option<String>,
    pub responses_base: Option<String>,
    pub sealed: Vec<u8>,
    pub last4: String,
    pub daily_token_limit: Option<u64>,
}

impl std::fmt::Debug for NewCredential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NewCredential")
            .field("vendor", &self.vendor)
            .field("label", &self.label)
            .field("last4", &self.last4)
            .finish_non_exhaustive()
    }
}

#[derive(sqlx::FromRow)]
struct Row {
    id: Uuid,
    vendor: String,
    label: String,
    last4: String,
    daily_token_limit: Option<i64>,
    disabled: bool,
    created_at: DateTime<Utc>,
}

impl Row {
    fn into_credential(self) -> Result<Credential> {
        Ok(Credential {
            id: self.id.into(),
            vendor: self.vendor,
            label: self.label,
            last4: self.last4,
            daily_token_limit: self
                .daily_token_limit
                .map(|v| unsigned(v, "daily_token_limit"))
                .transpose()?,
            disabled: self.disabled,
            created_at: self.created_at,
        })
    }
}

macro_rules! columns {
    () => {
        "id, vendor, label, last4, daily_token_limit, disabled, created_at"
    };
}

impl Tx<Tenant> {
    pub async fn create_credential(&mut self, new: &NewCredential) -> Result<Credential> {
        let row: Row = sqlx::query_as(concat!(
            "INSERT INTO credentials (id, user_id, vendor, label, anthropic_base, openai_base, responses_base, \
               sealed, last4, daily_token_limit) \
             VALUES ($1, app_user_id(), $2, $3, $4, $5, $6, $7, $8, $9) RETURNING ",
            columns!()
        ))
        .bind(CredentialId::new().0)
        .bind(&new.vendor)
        .bind(&new.label)
        .bind(&new.anthropic_base)
        .bind(&new.openai_base)
        .bind(&new.responses_base)
        .bind(&new.sealed)
        .bind(&new.last4)
        .bind(
            new.daily_token_limit
                .map(|v| signed(v, "daily_token_limit"))
                .transpose()?,
        )
        .fetch_one(self.conn())
        .await?;
        row.into_credential()
    }

    pub async fn credentials(&mut self) -> Result<Vec<Credential>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM credentials WHERE deleted_at IS NULL ORDER BY created_at"
        ))
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_credential).collect()
    }

    pub async fn credential(&mut self, id: CredentialId) -> Result<Credential> {
        let row: Row = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM credentials WHERE id = $1 AND deleted_at IS NULL"
        ))
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        row.into_credential()
    }

    pub async fn set_credential_disabled(
        &mut self,
        id: CredentialId,
        disabled: bool,
    ) -> Result<()> {
        let done = sqlx::query(
            "UPDATE credentials SET disabled = $2, updated_at = now() WHERE id = $1 AND deleted_at IS NULL",
        )
        .bind(id.0)
        .bind(disabled)
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }

    /// 换 key（同一个厂商）：只替换密文和后 4 位，别名路由不用动。
    pub async fn replace_credential_secret(
        &mut self,
        id: CredentialId,
        sealed: &[u8],
        last4: &str,
    ) -> Result<()> {
        let done = sqlx::query(
            "UPDATE credentials SET sealed = $2, last4 = $3, updated_at = now() \
             WHERE id = $1 AND deleted_at IS NULL",
        )
        .bind(id.0)
        .bind(sealed)
        .bind(last4)
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }

    /// 删除 key：还有实例的别名指向它时拒绝（先改路由）。删除时清掉密文，不在库里留着。
    pub async fn delete_credential(&mut self, id: CredentialId) -> Result<()> {
        // 和 set_model_routes 的 FOR SHARE 互斥：不会有路由在检查之后指过来。
        sqlx::query_scalar::<_, Uuid>(
            "SELECT id FROM credentials WHERE id = $1 AND deleted_at IS NULL FOR UPDATE",
        )
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        let routes: i64 =
            sqlx::query_scalar("SELECT count(*) FROM model_routes WHERE credential_id = $1")
                .bind(id.0)
                .fetch_one(self.conn())
                .await?;
        if routes > 0 {
            return Err(Error::Conflict(format!(
                "credential is used by {routes} model route(s)"
            )));
        }
        let done = sqlx::query(
            "UPDATE credentials SET deleted_at = now(), disabled = true, sealed = ''::bytea, updated_at = now() \
             WHERE id = $1 AND deleted_at IS NULL",
        )
        .bind(id.0)
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }
}
