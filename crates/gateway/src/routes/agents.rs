//! agent 目录：可以领养的 agent 和它们的接入方式。介绍、许可说明按 `Accept-Language` 给（没登录也能看）。

use axum::Json;
use axum::http::{HeaderMap, header};
use axum::response::IntoResponse;
use catalog::LlmProtocol;
use proto::domain::Locale;
use serde_json::{Value, json};

pub async fn list(headers: HeaderMap) -> impl IntoResponse {
    let lang = headers
        .get(header::ACCEPT_LANGUAGE)
        .and_then(|v| v.to_str().ok())
        .and_then(Locale::from_accept_language)
        .unwrap_or_default()
        .as_str();
    let agents: Vec<Value> = catalog::builtin_ids()
        .filter_map(catalog::builtin)
        .map(|m| {
            json!({
                "id": m.agent.id,
                "name": m.agent.name,
                "version": m.agent.version,
                "license": m.agent.license,
                "license_note": m.agent.license_note.as_ref().map(|n| n.get(lang)),
                "description": m.agent.description.as_ref().map_or("", |d| d.get(lang)),
                "upstream": m.agent.upstream,
                "sites": m.agent.sites,
                "harnesses": m.harnesses.iter().map(|h| h.id.clone()).collect::<Vec<_>>(),
                "default_harness": m.default_harness().id,
                // 可以用的版本，当前版本在前：实例的版本落后时提示升级，也可以回滚到旧版本。
                "versions": catalog::builtin_versions(&m.agent.id),
                // 能说的协议（按优先级）和运行时实际用的那个：实例配的每把 key（包括降级的）都要支持
                // `active_protocol`，模型网关不在协议之间转换。名字和 `/v1/vendors` 的 `protocols` 一样。
                "protocols": m.usable_protocols().map(LlmProtocol::api_name).collect::<Vec<_>>(),
                "active_protocol": m.pick_protocol(None).map(LlmProtocol::api_name),
            })
        })
        .collect();
    (
        [(header::VARY, "Accept-Language")],
        Json(json!({ "agents": agents })),
    )
}

#[cfg(test)]
mod tests {
    use axum::body::to_bytes;
    use axum::http::HeaderValue;

    use super::*;

    async fn agents(lang: Option<&str>) -> (HeaderMap, Vec<Value>) {
        let mut headers = HeaderMap::new();
        if let Some(l) = lang {
            headers.insert(header::ACCEPT_LANGUAGE, HeaderValue::from_str(l).unwrap());
        }
        let resp = list(headers).await.into_response();
        let h = resp.headers().clone();
        let body = to_bytes(resp.into_body(), 1 << 20).await.unwrap();
        let v: Value = serde_json::from_slice(&body).unwrap();
        (h, v["agents"].as_array().unwrap().clone())
    }

    #[tokio::test]
    async fn agents_list_protocols_and_texts() {
        let (headers, zh) = agents(None).await;
        assert_eq!(headers[header::VARY], "Accept-Language");
        let by = |list: &[Value], id: &str| list.iter().find(|a| a["id"] == id).unwrap().clone();
        let claude = by(&zh, "claude");
        assert_eq!(
            (
                claude["protocols"].clone(),
                claude["active_protocol"].clone()
            ),
            (json!(["anthropic"]), json!("anthropic"))
        );
        assert_eq!(by(&zh, "codex")["active_protocol"], "responses");
        assert_eq!(by(&zh, "hermes")["protocols"], json!(["chat", "anthropic"]));
        assert!(claude["license_note"].is_string());
        assert!(by(&zh, "codex")["license_note"].is_null());
        for a in &zh {
            assert!(!a["description"].as_str().unwrap().is_empty(), "{a}");
            assert!(
                a["upstream"].as_str().unwrap().starts_with("https://"),
                "{a}"
            );
            let protocols = a["protocols"].as_array().unwrap();
            for p in protocols {
                assert!(
                    proto::vendors::PROTOCOLS.contains(&p.as_str().unwrap()),
                    "{a}"
                );
            }
            assert!(protocols.contains(&a["active_protocol"]), "{a}");
        }
        let (_, en) = agents(Some("en-US,en;q=0.9")).await;
        assert_ne!(by(&en, "claude")["description"], claude["description"]);
        assert_ne!(by(&en, "claude")["license_note"], claude["license_note"]);
        // 清单里的语言和服务端支持的语言是同一套。
        assert_eq!(
            catalog::Localized::LOCALES.to_vec(),
            Locale::ALL.iter().map(|l| l.as_str()).collect::<Vec<_>>()
        );
    }
}
