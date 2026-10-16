//! 预置的模型厂商（9.12）：App 添加 key 时选厂商；不在列表里的接口用自定义端点（`custom`）。

use axum::Json;
use proto::vendors::{CUSTOM, VENDORS, VERIFIED};
use serde_json::{Value, json};

pub async fn list() -> Json<Value> {
    let vendors: Vec<Value> = VENDORS
        .iter()
        .map(|v| {
            let mut protocols = Vec::new();
            if v.anthropic_base.is_some() {
                protocols.push("anthropic");
            }
            if v.openai_base.is_some() {
                protocols.push("chat");
            }
            if v.responses_base.is_some() {
                protocols.push("responses");
            }
            json!({
                "id": v.id,
                "name": v.name,
                // agent 用哪种协议：Claude 走 anthropic，Codex 只会 responses，其余走 chat。
                "protocols": protocols,
                "models": v.models,
                "notes": v.notes,
            })
        })
        .collect();
    Json(json!({ "vendors": vendors, "custom": CUSTOM, "verified": VERIFIED }))
}
