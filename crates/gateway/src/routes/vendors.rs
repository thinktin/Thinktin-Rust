//! 预置的模型厂商（9.12）：App 添加 key 时选厂商；不在列表里的接口用自定义端点（`custom`）。
//! 每家带上订阅类 key 的前缀和套餐专用地址（11.9），App 保存前可以先在本地提示；服务端保存时照样检查。

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
                // 这家的 key 以这些开头的是订阅类 key，不收（区分大小写）。
                "subscription_key_prefixes": v.subscription_key_prefixes,
                // 自定义端点填了任何一家的这些地址（小写后等于它或接着是 `/`）不收。
                "plan_only_bases": v.plan_only_bases,
            })
        })
        .collect();
    Json(json!({ "vendors": vendors, "custom": CUSTOM, "verified": VERIFIED }))
}
