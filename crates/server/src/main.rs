//! 控制面主程序入口。

use std::path::PathBuf;

use anyhow::Context;
use clap::{Parser, Subcommand};
use server::Config;
use server::config::ProcessEnv;
use tracing_subscriber::EnvFilter;

#[derive(Parser)]
#[command(name = "thinktin-server", version, about = "ThinkTin 控制面")]
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
    /// 检查配置并打印生效的值（不打印数据库连接串）
    CheckConfig,
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
            Ok(())
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
