//! agent 目录：可以领养的 agent 和它们的接入方式。

use axum::Json;
use serde_json::{Value, json};

pub async fn list() -> Json<Value> {
    let agents: Vec<Value> = catalog::builtin_ids()
        .filter_map(catalog::builtin)
        .map(|m| {
            json!({
                "id": m.agent.id,
                "name": m.agent.name,
                "version": m.agent.version,
                "license": m.agent.license,
                "sites": m.agent.sites,
                "harnesses": m.harnesses.iter().map(|h| h.id.clone()).collect::<Vec<_>>(),
                "default_harness": m.default_harness().id,
                // 可以用的版本，当前版本在前：实例的版本落后时提示升级，也可以回滚到旧版本。
                "versions": catalog::builtin_versions(&m.agent.id),
            })
        })
        .collect();
    Json(json!({ "agents": agents }))
}
