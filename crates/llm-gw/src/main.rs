//! 模型网关的命令行入口。`serve` 跑网关，其余子命令用于本地开发：生成签名密钥、签发沙箱令牌、保存 key。

use std::io::Read;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, bail};
use auth::sandbox_token::{SandboxTokenIssuer, SandboxTokenVerifier, TokenRequest};
use clap::{Parser, Subcommand};
use keyvault::secrecy::{ExposeSecret, SecretString};
use keyvault::{KeyStore, KeyVault, LocalKms, MemoryKeyStore};
use llm_gw::limits::{Limiter, MemoryLedger};
use llm_gw::store::{Credential, DevStore};
use llm_gw::usage::LogSink;
use llm_gw::{Gateway, Options, ServeOptions, build_client, router, serve, vendors};
use zeroize::Zeroizing;

/// 本地 KMS 主密钥（64 位十六进制）。只从环境变量读，不走命令行参数（会出现在进程列表里）。
const ENV_KMS_KEY: &str = "THINKTIN_DEV_KMS_KEY";
/// 沙箱令牌签名私钥种子（base64url）。
const ENV_TOKEN_SEED: &str = "THINKTIN_DEV_TOKEN_SEED";

#[derive(Parser)]
#[command(
    name = "llm-gw",
    version,
    about = "ThinkTin 模型网关：沙箱令牌换用户 key，流式透传给厂商"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// 运行网关
    Serve {
        #[arg(long, default_value = "127.0.0.1:8790")]
        listen: SocketAddr,
        /// 路由数据和用户 DEK（开发用 JSON 文件）
        #[arg(long)]
        store: PathBuf,
        /// 沙箱令牌验签公钥，格式 `kid=base64url`，可重复
        #[arg(long = "token-key", required = true)]
        token_keys: Vec<String>,
        /// 出口代理，例如 http://egress:3128。不配则直连，并在 DNS 层拦截非公网地址
        #[arg(long)]
        egress_proxy: Option<String>,
        /// 只用于本地开发和测试：允许 http 和非公网上游
        #[arg(long)]
        insecure_upstreams: bool,
        /// 只用于本地开发：接受不绑定来源地址的令牌
        #[arg(long)]
        allow_unbound_tokens: bool,
        #[arg(long, default_value_t = 32)]
        max_body_mb: usize,
        /// 每个来源地址最多同时保持的连接数
        #[arg(long, default_value_t = 64)]
        max_connections_per_ip: usize,
        /// 每日预算按哪个时区切天（相对 UTC 的小时数）
        #[arg(long, default_value_t = 8, allow_negative_numbers = true)]
        budget_utc_offset_hours: i64,
        /// 日志输出 JSON
        #[arg(long)]
        log_json: bool,
    },
    /// 生成沙箱令牌签名密钥，打印私钥种子和公钥
    Keygen {
        #[arg(long, default_value = "dev")]
        kid: String,
    },
    /// 签发沙箱令牌（私钥种子从环境变量 THINKTIN_DEV_TOKEN_SEED 读）
    IssueToken {
        #[arg(long, default_value = "dev")]
        kid: String,
        #[arg(long)]
        instance: String,
        #[arg(long)]
        user: String,
        #[arg(long, default_value = "dev-grant")]
        grant: String,
        #[arg(long)]
        sandbox: String,
        /// 沙箱的来源地址；不填则令牌不绑定来源（网关要开 --allow-unbound-tokens）
        #[arg(long)]
        net: Option<String>,
        #[arg(long, default_value_t = 3600)]
        ttl_secs: u64,
    },
    /// 加密保存一把厂商 key：key 从标准输入读，主密钥从环境变量 THINKTIN_DEV_KMS_KEY 读
    PutKey {
        #[arg(long)]
        store: PathBuf,
        /// 凭证 id
        #[arg(long)]
        id: String,
        #[arg(long)]
        user: String,
        /// 厂商 id（见 `llm-gw vendors`）或 custom
        #[arg(long)]
        vendor: String,
        /// custom 厂商：Anthropic 兼容接口的 base URL（不带 /v1）
        #[arg(long)]
        anthropic_base: Option<String>,
        /// custom 厂商：OpenAI 兼容接口的 base URL（带版本段）
        #[arg(long)]
        openai_base: Option<String>,
        /// custom 厂商：Responses API 的前缀
        #[arg(long)]
        responses_base: Option<String>,
        /// custom 厂商：Responses API 和 --openai-base 同一个前缀
        #[arg(long, conflicts_with = "responses_base")]
        responses: bool,
        #[arg(long)]
        daily_token_limit: Option<u64>,
    },
    /// 打印厂商适配表
    Vendors,
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn kms(kms_key_id: &str) -> anyhow::Result<LocalKms> {
    let hex = Zeroizing::new(
        std::env::var(ENV_KMS_KEY).with_context(|| format!("{ENV_KMS_KEY} is not set"))?,
    );
    LocalKms::from_hex(kms_key_id, hex.trim())
        .with_context(|| format!("{ENV_KMS_KEY} must be 64 hex characters"))
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Serve {
            listen,
            store,
            token_keys,
            egress_proxy,
            insecure_upstreams,
            allow_unbound_tokens,
            max_body_mb,
            max_connections_per_ip,
            budget_utc_offset_hours,
            log_json,
        } => {
            let filter = tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into());
            if log_json {
                tracing_subscriber::fmt()
                    .json()
                    .with_env_filter(filter)
                    .with_writer(std::io::stderr)
                    .init();
            } else {
                tracing_subscriber::fmt()
                    .with_env_filter(filter)
                    .with_writer(std::io::stderr)
                    .init();
            }
            let mut verifier = SandboxTokenVerifier::new();
            for entry in &token_keys {
                let (kid, key) = entry
                    .split_once('=')
                    .context("--token-key must look like kid=base64url")?;
                verifier
                    .add_key_b64(kid, key)
                    .with_context(|| format!("bad --token-key for {kid}"))?;
            }
            let dev = DevStore::load(&store)?;
            let keys = MemoryKeyStore::default();
            for (user, wrapped) in &dev.user_keys {
                keys.insert_new(user, wrapped.clone());
            }
            let options = Options {
                insecure_upstreams,
                allow_unbound_tokens,
                via_proxy: egress_proxy.is_some(),
                max_body_bytes: max_body_mb << 20,
                budget_utc_offset_secs: budget_utc_offset_hours * 3600,
            };
            if insecure_upstreams {
                tracing::warn!(
                    "--insecure-upstreams: http and private upstream addresses are allowed (dev only)"
                );
            }
            let gw = Gateway {
                verifier,
                directory: Arc::new(dev.directory()),
                secrets: Arc::new(KeyVault::new(kms(&dev.kms_key_id)?, keys)),
                usage: Arc::new(LogSink),
                ledger: Arc::new(MemoryLedger::default()),
                limiter: Limiter::default(),
                client: build_client(&options, egress_proxy.as_deref())?,
                options,
            };
            let runtime = tokio::runtime::Runtime::new()?;
            runtime.block_on(async move {
                let listener = tokio::net::TcpListener::bind(listen)
                    .await
                    .with_context(|| format!("bind {listen}"))?;
                tracing::info!(addr = %listener.local_addr()?, "llm-gw listening");
                let serve_options = ServeOptions {
                    max_connections_per_ip,
                    ..ServeOptions::default()
                };
                serve(listener, router(Arc::new(gw)), serve_options, async {
                    let _ = tokio::signal::ctrl_c().await;
                })
                .await?;
                anyhow::Ok(())
            })
        }
        Command::Keygen { kid } => {
            let issuer = SandboxTokenIssuer::generate(&kid)?;
            println!("{ENV_TOKEN_SEED}={}", issuer.seed_b64().as_str());
            println!(
                "--token-key {}={}",
                issuer.kid(),
                issuer.verifying_key_b64()
            );
            Ok(())
        }
        Command::IssueToken {
            kid,
            instance,
            user,
            grant,
            sandbox,
            net,
            ttl_secs,
        } => {
            let seed = Zeroizing::new(
                std::env::var(ENV_TOKEN_SEED)
                    .with_context(|| format!("{ENV_TOKEN_SEED} is not set"))?,
            );
            let issuer = SandboxTokenIssuer::from_seed_b64(&kid, &seed)?;
            let token = issuer.issue(
                TokenRequest {
                    iid: instance,
                    uid: user,
                    grant,
                    sbx: sandbox,
                    net,
                },
                ttl_secs,
                now(),
            )?;
            println!("{token}");
            Ok(())
        }
        Command::PutKey {
            store,
            id,
            user,
            vendor,
            anthropic_base,
            openai_base,
            responses_base,
            responses,
            daily_token_limit,
        } => {
            if vendor != vendors::CUSTOM && vendors::vendor(&vendor).is_none() {
                bail!("unknown vendor {vendor}; see `llm-gw vendors`");
            }
            let responses_base =
                responses_base.or_else(|| openai_base.clone().filter(|_| responses));
            let mut dev = DevStore::load(&store)?;
            let keys = MemoryKeyStore::default();
            for (u, wrapped) in &dev.user_keys {
                keys.insert_new(u, wrapped.clone());
            }
            let vault = KeyVault::new(kms(&dev.kms_key_id)?, keys);
            if !dev.user_keys.contains_key(&user) {
                vault.create_user_key(&user)?;
            }
            let mut text = String::new();
            std::io::stdin().read_to_string(&mut text)?;
            let secret = SecretString::from(text.trim().to_owned());
            zeroize::Zeroize::zeroize(&mut text);
            vendors::check_key(&vendor, secret.expose_secret()).map_err(anyhow::Error::msg)?;
            let sealed = vault.seal(&user, &id, &secret)?;
            println!(
                "saved key ****{} as {id}",
                sealed.last4.trim_start_matches('*')
            );
            if let Some(wrapped) = KeyStore::get(vault.store(), &user) {
                dev.user_keys.insert(user.clone(), wrapped);
            }
            dev.upsert_credential(Credential {
                id,
                user_id: user,
                vendor,
                anthropic_base,
                openai_base,
                responses_base,
                secret: sealed,
                daily_token_limit,
                disabled: false,
            });
            dev.save(&store)
        }
        Command::Vendors => {
            println!("{}", serde_json::to_string_pretty(vendors::VENDORS)?);
            Ok(())
        }
    }
}
