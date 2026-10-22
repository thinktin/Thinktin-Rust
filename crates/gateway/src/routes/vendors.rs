//! 预置的模型厂商（9.12）：App 添加 key 时选厂商；不在列表里的接口用自定义端点（`custom`）。

use axum::Json;
use proto::vendors::{CUSTOM, VENDORS, VERIFIED};
use serde_json::{Value, json};

pub async fn list() -> Json<Value> {
    let vendors: Vec<Value> = VENDORS
        .iter()
        .map(|v| {
            json!({
                "id": v.id,
                "name": v.name,
                // agent 用哪种协议看 `/v1/agents` 的 `active_protocol`：Claude 走 anthropic，Codex 只会 responses，
                // 其余走 chat。
                "protocols": v.protocols(),
                "models": v.models,
                "notes": v.notes,
            })
        })
        .collect();
    Json(json!({ "vendors": vendors, "custom": CUSTOM, "verified": VERIFIED }))
}
