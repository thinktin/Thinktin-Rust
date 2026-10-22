//! 平台工具的副作用幂等（WBS 7.13）：同一次运行里参数完全相同、有副作用的调用只执行一次。

use proto::domain::{RunId, UserId};
use serde_json::Value;

use crate::{Result, Tx, Worker};

impl Tx<Worker> {
    /// 这次运行里同样的调用（`key` 是工具名加参数的摘要）之前执行成功的结果。
    pub async fn tool_call_result(&mut self, run: RunId, key: &[u8]) -> Result<Option<Value>> {
        Ok(
            sqlx::query_scalar("SELECT result FROM tool_calls WHERE run_id = $1 AND key = $2")
                .bind(run.0)
                .bind(key)
                .fetch_optional(self.conn())
                .await?,
        )
    }

    /// 记下执行成功的结果。同样的调用已经记过就不覆盖（以第一次为准）。
    pub async fn record_tool_call(
        &mut self,
        user: UserId,
        run: RunId,
        key: &[u8],
        tool: &str,
        result: &Value,
    ) -> Result<()> {
        sqlx::query(
            "INSERT INTO tool_calls (run_id, key, user_id, tool, result) VALUES ($1, $2, $3, $4, $5) \
             ON CONFLICT (run_id, key) DO NOTHING",
        )
        .bind(run.0)
        .bind(key)
        .bind(user.0)
        .bind(tool)
        .bind(result)
        .execute(self.conn())
        .await?;
        Ok(())
    }
}
