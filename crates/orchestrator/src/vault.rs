//! 密码保险箱的平台工具（WBS 9.11）：`vault_list`、`vault_request`，以及给运行日志抹值的工具函数。
//!
//! agent 不经手密码：它只知道名字，要用时在命令里写 `thinktin-vault`（沙箱里的助手向平台要值、
//! 注入命令，见 agent-shim 的 `vault_helper`）。没有合适的条目时用 `vault_request` 请用户在 App 里填，
//! 用户填的值只进保险箱；填好后平台在实例上接着跑一轮。

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use keyvault::{Kms, Scrubber};
use notify::PushKind;
use proto::domain::{UserId, VAULT_FIELDS, valid_vault_name};
use proto::shim::PlatformTool;
use serde::Deserialize;
use serde_json::{Value, json};
use store::{Db, NewVaultRequest};
use tracing::warn;

use crate::outbox::{Notice, notify_tenant};
use crate::shim::{PlatformTools, ToolContext, ToolOutput};

pub const VAULT_TOOLS: [&str; 2] = ["vault_list", "vault_request"];

/// 请求多久没处理就过期。
const REQUEST_TTL: Duration = Duration::from_secs(7 * 24 * 3600);
/// 一次运行里 agent 最多请用户填这么多次（每次都会推送提醒）。
const MAX_REQUESTS_PER_RUN: u64 = 5;

/// 给 agent 的用法说明。
pub const USAGE: &str = "Use a vault item without ever seeing its value: run commands through `thinktin-vault exec`, e.g. \
`thinktin-vault exec --env GH_TOKEN=github -- gh repo list`, `thinktin-vault exec --stdin db -- psql -W`, or put \
`{{github.password}}` / `{{github.username}}` in the command's arguments: `thinktin-vault exec -- curl -u '{{mail.username}}:{{mail.password}}' https://...`. \
A bare name means the password. Never print or echo the values; they are scrubbed from logs and from what the model sees.";

pub struct VaultTools {
    db: Db,
}

impl VaultTools {
    pub fn new(db: Db) -> Self {
        Self { db }
    }

    async fn list(&self, ctx: &ToolContext) -> Result<Value, String> {
        let mut t = self.db.tenant(ctx.user).await.map_err(internal)?;
        let items: Vec<Value> = t
            .vault_items()
            .await
            .map_err(internal)?
            .into_iter()
            .filter(|i| i.instance_ids.is_empty() || i.instance_ids.contains(&ctx.instance))
            .map(|i| {
                json!({
                    "name": i.name,
                    "purpose": i.purpose,
                    "has_username": i.has_username,
                    "last_used_at": i.last_used_at,
                })
            })
            .collect();
        let requests: Vec<Value> = t
            .vault_requests(true)
            .await
            .map_err(internal)?
            .into_iter()
            .filter(|r| r.instance_id == ctx.instance)
            .map(|r| json!({ "name": r.name, "purpose": r.purpose, "status": r.status }))
            .collect();
        t.rollback().await.map_err(internal)?;
        Ok(json!({ "items": items, "pending_requests": requests, "usage": USAGE }))
    }

    async fn request(&self, ctx: &ToolContext, args: &Value) -> Result<Value, String> {
        #[derive(Deserialize)]
        struct Args {
            name: String,
            purpose: String,
            #[serde(default)]
            fields: Vec<String>,
        }
        let a: Args =
            serde_json::from_value(args.clone()).map_err(|e| format!("invalid arguments: {e}"))?;
        let name = a.name.trim().to_owned();
        if !valid_vault_name(&name) {
            return Err(
                "name must be 1-64 lowercase letters, digits, _ or -, starting with a letter or digit"
                    .into(),
            );
        }
        let purpose = a.purpose.trim().to_owned();
        let n = purpose.chars().count();
        if n == 0 || n > 200 || purpose.chars().any(char::is_control) {
            return Err(
                "purpose must be 1-200 characters without control characters: say what the account is for"
                    .into(),
            );
        }
        let mut fields: Vec<String> = Vec::new();
        for f in a.fields.iter().map(|f| f.trim()) {
            if !VAULT_FIELDS.contains(&f) {
                return Err(format!("unknown field {f:?}: use username and/or password"));
            }
            if !fields.iter().any(|x| x == f) {
                fields.push(f.to_owned());
            }
        }
        if !fields.iter().any(|f| f == "password") {
            fields.push("password".into());
        }
        let mut t = self.db.tenant(ctx.user).await.map_err(internal)?;
        match t.sealed_vault_item_named(&name).await {
            Ok(found)
                if found.item.instance_ids.is_empty()
                    || found.item.instance_ids.contains(&ctx.instance) =>
            {
                t.rollback().await.map_err(internal)?;
                return Ok(json!({
                    "status": "available",
                    "name": name,
                    "note": format!("{name} is already in the vault. {USAGE}"),
                }));
            }
            // 有同名条目但这个 agent 不能用：照样请用户处理（填好后允许这个实例使用）。
            Ok(_) | Err(store::Error::NotFound) => {}
            Err(e) => return Err(internal(e)),
        }
        if t.run_event_count(ctx.run, "vault.requested")
            .await
            .map_err(internal)?
            >= MAX_REQUESTS_PER_RUN
        {
            return Err(format!(
                "this task already asked for {MAX_REQUESTS_PER_RUN} credentials; wait for the user"
            ));
        }
        let (request, created) = t
            .create_vault_request(&NewVaultRequest {
                instance_id: ctx.instance,
                run_id: Some(ctx.run),
                name: name.clone(),
                purpose: purpose.clone(),
                fields,
                expires_in: REQUEST_TTL,
            })
            .await
            .map_err(|e| match e {
                store::Error::Invalid(m) | store::Error::Conflict(m) => m,
                other => internal(other),
            })?;
        if created {
            let locale = t.user_locale(ctx.user).await.map_err(internal)?;
            let (title, body) =
                crate::texts::vault_request(locale, &purpose.chars().take(60).collect::<String>());
            let notice = Notice {
                instance: Some(ctx.instance),
                run: Some(ctx.run),
                vault_request: Some(request.id),
                thread_id: Some(ctx.run.to_string()),
                collapse_id: Some(format!("vault-request:{}", request.id)),
                dedupe_key: Some(format!("vault-request:{}", request.id)),
                ttl: Some(REQUEST_TTL),
                // 用途是 agent 写的。
                ai_generated: true,
                ..Notice::new(PushKind::VaultRequest, title, body)
            };
            notify_tenant(&mut t, &notice).await.map_err(internal)?;
            t.append_event(
                ctx.instance,
                Some(ctx.run),
                "vault.requested",
                &json!({
                    "request_id": request.id,
                    "name": request.name,
                    "purpose": request.purpose,
                    "fields": request.fields,
                }),
            )
            .await
            .map_err(internal)?;
            t.audit(
                &format!("agent:{}", ctx.instance),
                "vault.request",
                Some(&request.id.to_string()),
                &json!({ "run": ctx.run, "name": request.name }),
            )
            .await
            .map_err(internal)?;
        }
        t.commit().await.map_err(internal)?;
        Ok(json!({
            "status": "requested",
            "request_id": request.id,
            "name": request.name,
            "note": "The user has been asked to fill in these credentials in the ThinkTin app; you will never see the values. \
                     Tell the user what you need them for and end your turn: when they are saved, the platform starts a new turn \
                     and you can use them with thinktin-vault.",
        }))
    }
}

fn internal(e: store::Error) -> String {
    tracing::error!(error = %e, "vault tool failed");
    "internal error, try again later".into()
}

#[async_trait]
impl PlatformTools for VaultTools {
    fn tools(&self) -> Vec<PlatformTool> {
        vec![
            PlatformTool {
                name: "vault_list".into(),
                description: format!(
                    "List the user's password vault items this agent may use (names and purposes only, never the values), \
                     and your pending requests. {USAGE}"
                ),
                input_schema: json!({ "type": "object", "properties": {} }),
            },
            PlatformTool {
                name: "vault_request".into(),
                description: "Ask the user to store an account's credentials in their password vault (they fill in a form in the \
                              ThinkTin app; you never see the values). Use this instead of asking for a password in the chat. \
                              Afterwards use the item by name with thinktin-vault."
                    .into(),
                input_schema: json!({
                    "type": "object",
                    "properties": {
                        "name": { "type": "string", "description": "Short reference name: lowercase letters, digits, _ or -, e.g. github or work-mail" },
                        "purpose": { "type": "string", "description": "What the account is and what you will do with it, shown to the user" },
                        "fields": { "type": "array", "items": { "type": "string", "enum": ["username", "password"] }, "description": "Which fields you need (default password)" }
                    },
                    "required": ["name", "purpose"]
                }),
            },
        ]
    }

    async fn call(&self, ctx: &ToolContext, name: &str, arguments: &Value) -> ToolOutput {
        let result = match name {
            "vault_list" => self.list(ctx).await,
            "vault_request" => self.request(ctx, arguments).await,
            other => Err(format!("unknown platform tool {other}")),
        };
        match result {
            Ok(v) => ToolOutput::text(v.to_string()),
            Err(m) => ToolOutput::error(m),
        }
    }
}

/// 用户保险箱里全部密码的抹值器：运行日志落盘前、用户发的消息存库前用。出错只记日志、少抹一些：
/// 抹值是额外的一层保护，模型网关转发前还会再抹一遍（读不到保险箱就不转发）。
pub async fn user_scrubber(db: &Db, kms: Arc<dyn Kms>, user: UserId) -> Scrubber {
    let mut s = Scrubber::new();
    let items = async {
        let mut w = db.worker().await?;
        let items = w.user_vault_items(user).await?;
        w.rollback().await?;
        Ok::<_, store::Error>(items)
    }
    .await;
    let items = match items {
        Ok(items) if items.is_empty() => return s,
        Ok(items) => items,
        Err(e) => {
            warn!(%user, error = %e, "loading vault items failed");
            return s;
        }
    };
    let vault = match crate::artifacts::user_vault(db, kms, user, false).await {
        Ok(v) => v,
        Err(e) => {
            warn!(%user, error = %e, "opening the user's vault failed");
            return s;
        }
    };
    let uid = user.to_string();
    for item in items {
        match vault
            .open_vault(&uid, &item.item.id.to_string(), &item.sealed)
            .await
        {
            Ok(secret) => s.add_secret(&item.item.name, &secret),
            Err(e) => warn!(item = %item.item.id, error = %e, "cannot open a vault item"),
        }
    }
    s
}

/// 抹掉 JSON 里所有字符串中的保险箱值（对象的键也算）。返回有没有改动。
pub fn scrub_json(scrubber: &Scrubber, v: &mut Value) -> bool {
    match v {
        Value::String(s) => match scrubber.scrub(s) {
            Some(clean) => {
                *s = clean;
                true
            }
            None => false,
        },
        Value::Array(items) => {
            let mut changed = false;
            for item in items {
                changed |= scrub_json(scrubber, item);
            }
            changed
        }
        Value::Object(map) => {
            let mut changed = false;
            let keys: Vec<String> = map.keys().cloned().collect();
            for k in keys {
                if let Some(clean) = scrubber.scrub(&k) {
                    if let Some(val) = map.remove(&k) {
                        map.insert(clean, val);
                    }
                    changed = true;
                }
            }
            for (_, val) in map.iter_mut() {
                changed |= scrub_json(scrubber, val);
            }
            changed
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_strings_and_keys_are_scrubbed() {
        let mut s = Scrubber::new();
        s.add("github", "gh-secret-123");
        let mut v = json!({
            "text": "token gh-secret-123 ok",
            "gh-secret-123": [1, "x gh-secret-123"],
            "n": 5,
        });
        assert!(scrub_json(&s, &mut v));
        assert_eq!(
            v,
            json!({
                "text": "token [vault:github] ok",
                "[vault:github]": [1, "x [vault:github]"],
                "n": 5,
            })
        );
        assert!(!scrub_json(&s, &mut v));
    }
}
