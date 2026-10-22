//! 控制面主程序入口。

use std::path::PathBuf;

use anyhow::Context;
use clap::{Parser, Subcommand};
use server::Config;
use server::config::ProcessEnv;
use tracing_subscriber::EnvFilter;

#[derive(Parser)]
#[command(name = "thinktin-server", version = server::VERSION, about = "ThinkTin 控制面")]
struct Cli {
    /// 配置文件（TOML）。环境变量 DATABASE_URL、THINKTIN_LISTEN、THINKTIN_NODE_ID 覆盖其中的值。
    #[arg(long, global = true, env = "THINKTIN_CONFIG")]
    config: Option<PathBuf>,
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// 运行服务（默认）
    Serve,
    /// 执行数据库迁移后退出（用表的属主账号连接）
    Migrate,
    /// 检查配置并打印生效的值（不打印数据库连接串和密钥；打印访问令牌的公钥，配设备中继用）
    CheckConfig,
    /// 运维操作：冻结、解冻、查看账号（冻结和解冻记审计、通知用户）
    Admin {
        #[command(subcommand)]
        action: AdminCommand,
    },
}

#[derive(Subcommand)]
enum AdminCommand {
    /// 冻结账号：停掉所有运行，登录和接口都拒绝，计划暂停触发
    Freeze {
        /// 手机号或用户 id
        account: String,
        /// 原因（只记进审计，不发给用户）
        #[arg(long)]
        reason: String,
        /// 操作人（记进审计）
        #[arg(long, env = "THINKTIN_OPERATOR")]
        operator: String,
    },
    /// 解冻账号
    Unfreeze {
        /// 手机号或用户 id
        account: String,
        /// 原因（只记进审计）
        #[arg(long)]
        reason: String,
        /// 操作人（记进审计）
        #[arg(long, env = "THINKTIN_OPERATOR")]
        operator: String,
    },
    /// 查看账号概况（手机号打码，不含对话内容）
    Show {
        /// 手机号或用户 id
        account: String,
    },
    /// 每个 agent 版本上有多少个实例，标出当前版本和因安全问题下架的版本（漏洞响应用）
    Versions,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    let cfg = Config::load(cli.config.as_deref(), &ProcessEnv)?;
    init_logging(&cfg);
    match cli.command.unwrap_or(Command::Serve) {
        Command::Serve => server::run(cfg).await,
        Command::Migrate => {
            let db = store::Db::connect(cfg.database_url(), 2)
                .await
                .context("connect to database")?;
            db.migrate().await.context("migrate")?;
            tracing::info!("migrations applied");
            Ok(())
        }
        Command::CheckConfig => {
            println!("listen = {}", cfg.listen);
            println!("node_id = {}", cfg.node_id());
            println!(
                "database.max_connections = {}",
                cfg.database.max_connections
            );
            println!(
                "database.migrate_on_start = {}",
                cfg.database.migrate_on_start
            );
            println!(
                "shutdown = drain {}s, grace {}s",
                cfg.shutdown.drain_secs, cfg.shutdown.grace_secs
            );
            println!(
                "api.enabled = {} (dev_sms = {}, review account = {})",
                cfg.api.enabled,
                cfg.api.dev_sms,
                cfg.api.review_phone.is_some()
            );
            println!(
                "worker.enabled = {} (sandbox provider {}, max {} concurrent runs)",
                cfg.worker.enabled, cfg.sandbox.provider, cfg.worker.max_concurrent_runs
            );
            println!("push.im = {}", cfg.push.im.enabled);
            println!("push.apns = {}", cfg.push.apns.is_some());
            // 设备中继（thinktin-relay --access-key）验访问令牌用的公钥。
            match cfg.api_secrets.access_token_seed.as_deref() {
                Some(seed) => {
                    let signer = auth::signed::Signer25519::from_seed_b64(
                        cfg.api.access_token_kid.clone(),
                        seed,
                    )
                    .context("THINKTIN_ACCESS_TOKEN_SEED")?;
                    println!(
                        "access token key = {}={}",
                        signer.kid(),
                        signer.verifying_key_b64()
                    );
                }
                None => println!("access token key = (THINKTIN_ACCESS_TOKEN_SEED is not set)"),
            }
            Ok(())
        }
        Command::Admin { action } => {
            let db = store::Db::connect(cfg.database_url(), 2)
                .await
                .context("connect to database")?;
            let mut out = std::io::stdout();
            match action {
                AdminCommand::Freeze {
                    account,
                    reason,
                    operator,
                } => server::admin::freeze(&db, &account, &operator, &reason, &mut out).await,
                AdminCommand::Unfreeze {
                    account,
                    reason,
                    operator,
                } => server::admin::unfreeze(&db, &account, &operator, &reason, &mut out).await,
                AdminCommand::Show { account } => {
                    server::admin::show(&db, &account, &mut out).await
                }
                AdminCommand::Versions => server::admin::versions(&db, &mut out).await,
            }
        }
    }
}

fn init_logging(cfg: &Config) {
    let filter =
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(&cfg.log.filter));
    let builder = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_ansi(std::io::IsTerminal::is_terminal(&std::io::stdout()));
    if cfg.log.json {
        builder.json().init();
    } else {
        builder.init();
    }
}
