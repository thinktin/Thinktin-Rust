//! 给一个新环境生成密钥（`thinktin-server gen-secrets`，docs/deploy-checklist.md 第 3 节）：访问令牌、沙箱令牌的
//! 签名种子，验证码的 HMAC 密钥，四个服务的数据库登录密码；和要填进 ConfigMap 的公钥。不读配置、不连数据库。

use anyhow::Context;
use auth::sandbox_token::SandboxTokenIssuer;
use auth::signed::Signer25519;
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use zeroize::Zeroizing;

/// 一套新生成的密钥。私密的部分用 `Zeroizing` 装着，打印完就清掉。
pub struct GeneratedSecrets {
    /// `THINKTIN_ACCESS_TOKEN_SEED`（Secret `thinktin-api`）。
    pub access_token_seed: Zeroizing<String>,
    /// `THINKTIN_ACCESS_TOKEN_KEYS` 的值（ConfigMap `thinktin-relay`）：`kid=公钥`。
    pub access_token_key: String,
    /// `THINKTIN_SANDBOX_TOKEN_SEED`（Secret `thinktin-worker`）。
    pub sandbox_token_seed: Zeroizing<String>,
    /// `THINKTIN_SANDBOX_TOKEN_KEY` 的值（ConfigMap `thinktin-llm-gw`）：`kid=公钥`。
    pub sandbox_token_key: String,
    /// `THINKTIN_CODE_PEPPER`（Secret `thinktin-api`）：32 字节，十六进制。
    pub code_pepper: Zeroizing<String>,
    /// 数据库登录账号的密码：属主（迁移）、控制面、模型网关、中继。
    pub db_passwords: [(&'static str, Zeroizing<String>); 4],
}

/// 数据库账号（docs/release.md 第 3 节）：迁移用属主，三个服务各用自己的登录账号。
pub const DB_LOGINS: [&str; 4] = [
    "thinktin_owner",
    "thinktin_server_login",
    "thinktin_llmgw_login",
    "thinktin_relay_login",
];

fn random(len: usize) -> anyhow::Result<Zeroizing<Vec<u8>>> {
    let mut bytes = Zeroizing::new(vec![0u8; len]);
    getrandom::fill(bytes.as_mut_slice())
        .map_err(|e| anyhow::anyhow!("no randomness from the system: {e}"))?;
    Ok(bytes)
}

pub fn generate(access_kid: &str, sandbox_kid: &str) -> anyhow::Result<GeneratedSecrets> {
    let access = Signer25519::generate(access_kid).context("access token key")?;
    let sandbox = SandboxTokenIssuer::generate(sandbox_kid).context("sandbox token key")?;
    let pepper = random(32)?;
    let mut code_pepper = Zeroizing::new(String::with_capacity(64));
    for b in pepper.iter() {
        code_pepper.push_str(&format!("{b:02x}"));
    }
    // 密码只用 URL 安全的字符，放进连接串（postgres://user:密码@…）不用转义。
    let password = || -> anyhow::Result<Zeroizing<String>> {
        Ok(Zeroizing::new(
            URL_SAFE_NO_PAD.encode(random(24)?.as_slice()),
        ))
    };
    Ok(GeneratedSecrets {
        access_token_seed: access.seed_b64(),
        access_token_key: format!("{}={}", access.kid(), access.verifying_key_b64()),
        sandbox_token_seed: sandbox.seed_b64(),
        sandbox_token_key: format!("{}={}", sandbox.kid(), sandbox.verifying_key_b64()),
        code_pepper,
        db_passwords: [
            (DB_LOGINS[0], password()?),
            (DB_LOGINS[1], password()?),
            (DB_LOGINS[2], password()?),
            (DB_LOGINS[3], password()?),
        ],
    })
}

/// 打印成运维照着填的样子。
pub fn render(s: &GeneratedSecrets) -> String {
    let mut out = String::new();
    out.push_str("# 新生成的密钥：只显示这一次，存进密码管理器，不要提交到仓库、不要贴进聊天。\n");
    out.push_str("# 每个环境（预发、生产）各生成一套，不共用。\n\n");
    out.push_str("## Secret thinktin-api\n");
    out.push_str(&format!(
        "THINKTIN_ACCESS_TOKEN_SEED={}\n",
        s.access_token_seed.as_str()
    ));
    out.push_str(&format!(
        "THINKTIN_CODE_PEPPER={}\n\n",
        s.code_pepper.as_str()
    ));
    out.push_str("## Secret thinktin-worker\n");
    out.push_str(&format!(
        "THINKTIN_SANDBOX_TOKEN_SEED={}\n\n",
        s.sandbox_token_seed.as_str()
    ));
    out.push_str("## 数据库登录账号的密码（建账号时用，再拼进各个 Secret 的 DATABASE_URL）\n");
    for (login, password) in &s.db_passwords {
        out.push_str(&format!("{login}: {}\n", password.as_str()));
    }
    out.push_str(
        "\n# 公钥（不是秘密）：填进 deploy/k8s/overlays/<环境>/kustomization.yaml 的 configMapGenerator。\n",
    );
    out.push_str(&format!(
        "thinktin-relay   THINKTIN_ACCESS_TOKEN_KEYS={}\n",
        s.access_token_key
    ));
    out.push_str(&format!(
        "thinktin-llm-gw  THINKTIN_SANDBOX_TOKEN_KEY={}\n",
        s.sandbox_token_key
    ));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_keys_match_their_public_halves() {
        let a = generate("a1", "k1").unwrap();
        let b = generate("a1", "k1").unwrap();
        assert_ne!(a.access_token_seed.as_str(), b.access_token_seed.as_str());
        // 种子能被服务原样读回，算出同一个公钥。
        let access = Signer25519::from_seed_b64("a1", &a.access_token_seed).unwrap();
        assert_eq!(
            a.access_token_key,
            format!("a1={}", access.verifying_key_b64())
        );
        let sandbox = SandboxTokenIssuer::from_seed_b64("k1", &a.sandbox_token_seed).unwrap();
        assert_eq!(
            a.sandbox_token_key,
            format!("k1={}", sandbox.verifying_key_b64())
        );
        assert_eq!(a.code_pepper.len(), 64);
        assert!(a.code_pepper.chars().all(|c| c.is_ascii_hexdigit()));
        for (_, password) in &a.db_passwords {
            assert_eq!(password.len(), 32);
            assert!(
                password
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
            );
        }
        let text = render(&a);
        assert!(text.contains("THINKTIN_ACCESS_TOKEN_SEED="));
        assert!(text.contains("THINKTIN_SANDBOX_TOKEN_KEY=k1="));
    }
}
