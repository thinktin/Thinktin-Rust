//! 客户端接口的组装：账号服务、key 加密、事件流监听，挂到 `/v1`。

use std::sync::Arc;

use anyhow::{Context, bail};
use auth::access_token::{AccessTokenIssuer, AccessTokenVerifier};
use auth::service::{AuthConfig, AuthService};
use auth::signed::{Signer25519, Verifier25519};
use auth::sms::DevConsoleSms;
use axum::Router;
use control::BuiltinTemplates;
use gateway::{AppState, EventHub, GatewayConfig, Inner};
use keyvault::LocalKms;
use store::Db;
use zeroize::Zeroizing;

use crate::{Background, Config};

fn decode_hex(s: &str) -> Option<Vec<u8>> {
    let s = s.trim();
    if s.len() % 2 != 0 {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok())
        .collect()
}

pub fn build(cfg: &Config, db: &Db, bg: &mut Background) -> anyhow::Result<Router> {
    let secrets = &cfg.api_secrets;
    let seed = secrets
        .access_token_seed
        .as_deref()
        .context("THINKTIN_ACCESS_TOKEN_SEED is not set")?;
    let signer = Signer25519::from_seed_b64(cfg.api.access_token_kid.clone(), seed)
        .context("THINKTIN_ACCESS_TOKEN_SEED")?;
    let mut verifier = Verifier25519::new();
    verifier
        .add_key_b64(signer.kid().to_owned(), &signer.verifying_key_b64())
        .context("access token key")?;
    let pepper = Zeroizing::new(
        decode_hex(secrets.code_pepper.as_deref().unwrap_or_default())
            .context("THINKTIN_CODE_PEPPER must be hex")?,
    );
    if pepper.len() < 32 {
        bail!("THINKTIN_CODE_PEPPER must be at least 32 bytes (64 hex characters)");
    }
    let kms = LocalKms::from_hex(
        cfg.api.kms_key_id.clone(),
        secrets.kms_key.as_deref().unwrap_or_default(),
    )
    .context("THINKTIN_KMS_KEY must be 64 hex characters")?;
    let auth = AuthService::new(
        db.clone(),
        AuthConfig::default(),
        pepper,
        AccessTokenIssuer(signer),
        AccessTokenVerifier(verifier),
        Arc::new(DevConsoleSms),
    )
    .context("auth service")?;
    let hub = EventHub::new();
    let state = AppState::new(Inner {
        db: db.clone(),
        auth: Arc::new(auth),
        templates: Arc::new(BuiltinTemplates),
        kms: Arc::new(kms),
        hub: hub.clone(),
        cfg: GatewayConfig {
            default_platform_tools: cfg.api.default_platform_tools.clone(),
            ..GatewayConfig::default()
        },
    });
    let pool = db.pool().clone();
    bg.spawn("event-listener", move |mut stop| async move {
        hub.listen(pool, async move { stop.wait().await }).await;
        Ok(())
    });
    Ok(gateway::router(state))
}

#[cfg(test)]
mod tests {
    #[test]
    fn hex() {
        assert_eq!(super::decode_hex("00ff10"), Some(vec![0, 255, 16]));
        assert_eq!(super::decode_hex("0"), None);
        assert_eq!(super::decode_hex("zz"), None);
    }
}
