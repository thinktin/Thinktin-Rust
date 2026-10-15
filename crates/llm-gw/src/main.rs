//! 模型网关的命令行入口。`serve` 跑网关，其余子命令用于本地开发：生成签名密钥、签发沙箱令牌、保存 key。

use std::io::Read;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, bail};
use auth::sandbox_token::{SandboxTokenIssuer, SandboxTokenVerifier, TokenRequest};
use clap::{Parser, Subcommand};
use keyvault::secrecy::{ExposeSecret, SecretString};
use keyvault::{KeyStore, KeyVault, LocalKms, MemoryKeyStore, SecretOpener};
use llm_gw::limits::{BudgetLedger, Limiter, MemoryLedger};
use llm_gw::pg::{PgDirectory, PgLedger, PgUsageSink};
use llm_gw::store::{Credential, DevStore, Directory};
use llm_gw::usage::{LogSink, UsageSink};
use llm_gw::{Gateway, Options, ServeOptions, build_client, router, serve, vendors};
use zeroize::Zeroizing;

/// 本地 KMS 主密钥（64 位十六进制）。只从环境变量读，不走命令行参数（会出现在进程列表里）。
const ENV_KMS_KEY: &str = "THINKTIN_DEV_KMS_KEY";
/// 沙箱令牌签名私钥种子（base64url）。
const ENV_TOKEN_SEED: &str = "THINKTIN_DEV_TOKEN_SEED";
/// 生产：KMS 主密钥（本地 KMS，64 位十六进制），和控制面的 THINKTIN_KMS_KEY 是同一把。
const ENV_KMS_KEY_PROD: &str = "THINKTIN_KMS_KEY";

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
        /// 路由数据和用户 DEK（开发用 JSON 文件）。和 --database-url 二选一
        #[arg(
            long,
            conflicts_with = "database_url",
            required_unless_present = "database_url"
        )]
        store: Option<PathBuf>,
        /// 控制面数据库（生产）：路由数据、用户 DEK、用量都在这里。主密钥从环境变量 THINKTIN_KMS_KEY 读
        #[arg(long, env = "DATABASE_URL")]
        database_url: Option<String>,
        /// 本地 KMS 主密钥的 id（和控制面的 api.kms_key_id 一致）
        #[arg(long, default_value = "local-1")]
        kms_key_id: String,
        /// 路由数据缓存多久（秒）：吊销授权、改路由最多这么久后生效
        #[arg(long, default_value_t = 5)]
        cache_secs: u64,
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
        /// Prometheus `/metrics` 的监听地址（只给内网的抓取方）
        #[arg(long)]
        metrics_listen: Option<SocketAddr>,
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

/// 路由数据、解密、用量、预算账本：开发用文件版，生产用数据库版。
type Backends = (
    Arc<dyn Directory>,
    Arc<dyn SecretOpener>,
    Arc<dyn UsageSink>,
    Arc<dyn BudgetLedger>,
);

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
            database_url,
            kms_key_id,
            cache_secs,
            token_keys,
            egress_proxy,
            insecure_upstreams,
            allow_unbound_tokens,
            max_body_mb,
            max_connections_per_ip,
            budget_utc_offset_hours,
            log_json,
            metrics_listen,
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
            let client = build_client(&options, egress_proxy.as_deref())?;
            let runtime = tokio::runtime::Runtime::new()?;
            runtime.block_on(async move {
                let mut writer = None;
                let (directory, secrets, usage, ledger): Backends = match (store, database_url) {
                    (Some(path), _) => {
                        let dev = DevStore::load(&path)?;
                        let keys = MemoryKeyStore::default();
                        for (user, wrapped) in &dev.user_keys {
                            keys.insert_new(user, wrapped.clone());
                        }
                        (
                            Arc::new(dev.directory()),
                            Arc::new(KeyVault::new(kms(&dev.kms_key_id)?, keys)),
                            Arc::new(LogSink),
                            Arc::new(MemoryLedger::default()),
                        )
                    }
                    (None, Some(url)) => {
                        let db = store::Db::connect(&url, 16)
                            .await
                            .context("connect to database")?;
                        let hex = Zeroizing::new(
                            std::env::var(ENV_KMS_KEY_PROD)
                                .with_context(|| format!("{ENV_KMS_KEY_PROD} is not set"))?,
                        );
                        let kms =
                            LocalKms::from_hex(&kms_key_id, hex.trim()).with_context(|| {
                                format!("{ENV_KMS_KEY_PROD} must be 64 hex characters")
                            })?;
                        let ttl = Duration::from_secs(cache_secs.max(1));
                        let keys = Arc::new(MemoryKeyStore::default());
                        let (sink, w) = PgUsageSink::spawn(db.clone());
                        writer = Some(w);
                        (
                            Arc::new(PgDirectory::new(db.clone(), keys.clone(), ttl)),
                            Arc::new(KeyVault::new(kms, keys)),
                            Arc::new(sink),
                            Arc::new(PgLedger::new(db, options.budget_utc_offset_secs, ttl)),
                        )
                    }
                    (None, None) => bail!("give --store or --database-url"),
                };
                let gw = Gateway {
                    verifier,
                    directory,
                    secrets,
                    usage,
                    ledger,
                    limiter: Limiter::default(),
                    client,
                    options,
                };
                if let Some(addr) = metrics_listen {
                    let handle = metrics_exporter_prometheus::PrometheusBuilder::new()
                        .install_recorder()
                        .context("installing the metrics recorder")?;
                    let l = tokio::net::TcpListener::bind(addr)
                        .await
                        .with_context(|| format!("bind {addr}"))?;
                    let app = axum::Router::new().route(
                        "/metrics",
                        axum::routing::get(move || {
                            let h = handle.clone();
                            async move { h.render() }
                        }),
                    );
                    tokio::spawn(async move {
                        if let Err(e) = axum::serve(l, app).await {
                            tracing::error!(error = %e, "metrics endpoint stopped");
                        }
                    });
                    tracing::info!(%addr, "metrics endpoint started");
                }
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
                // 等还没写进库的用量落库（进行中的流式响应结束后队列才会关闭）。
                if let Some(w) = writer
                    && tokio::time::timeout(Duration::from_secs(30), w.finish())
                        .await
                        .is_err()
                {
                    tracing::warn!("usage writer did not finish in time");
                }
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
                    ep: 0,
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
