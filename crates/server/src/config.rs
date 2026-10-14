//! 配置：TOML 文件 + 环境变量覆盖。密钥类的值（数据库连接串）只建议走环境变量。

use std::net::SocketAddr;
use std::path::Path;
use std::time::Duration;

use anyhow::{Context, bail};
use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    /// 接入网关监听的地址。
    pub listen: SocketAddr,
    /// 这个副本的名字：执行租约、出箱锁记的就是它。默认 `主机名-进程号`。
    pub node_id: Option<String>,
    pub database: Database,
    pub shutdown: Shutdown,
    pub log: Log,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Database {
    /// 优先用环境变量 DATABASE_URL。
    pub url: Option<String>,
    pub max_connections: u32,
    /// 启动时执行迁移（开发环境；生产由发布流程单独执行 `thinktin-server migrate`）。
    pub migrate_on_start: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Shutdown {
    /// 收到停机信号后先报“未就绪”这么久，让负载均衡摘掉这个副本，再停止接新连接。
    pub drain_secs: u64,
    /// 之后最多再等这么久让进行中的请求、后台任务收尾。
    pub grace_secs: u64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Log {
    pub json: bool,
    /// tracing 的过滤表达式；环境变量 RUST_LOG 优先。
    pub filter: String,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            listen: SocketAddr::from(([127, 0, 0, 1], 8080)),
            node_id: None,
            database: Database::default(),
            shutdown: Shutdown::default(),
            log: Log::default(),
        }
    }
}

impl Default for Database {
    fn default() -> Self {
        Self {
            url: None,
            max_connections: 20,
            migrate_on_start: false,
        }
    }
}

impl Default for Shutdown {
    fn default() -> Self {
        Self {
            drain_secs: 5,
            grace_secs: 30,
        }
    }
}

impl Default for Log {
    fn default() -> Self {
        Self {
            json: false,
            filter: "info".into(),
        }
    }
}

/// 读环境变量的方式（测试里换成固定的表）。
pub trait Env {
    fn var(&self, key: &str) -> Option<String>;
}

pub struct ProcessEnv;

impl Env for ProcessEnv {
    fn var(&self, key: &str) -> Option<String> {
        std::env::var(key).ok().filter(|v| !v.is_empty())
    }
}

impl Config {
    /// 读配置文件（可选），再用环境变量覆盖：DATABASE_URL、THINKTIN_LISTEN、THINKTIN_NODE_ID。
    pub fn load(path: Option<&Path>, env: &dyn Env) -> anyhow::Result<Self> {
        let mut cfg = match path {
            Some(p) => {
                let text = std::fs::read_to_string(p)
                    .with_context(|| format!("read config {}", p.display()))?;
                Self::parse(&text).with_context(|| format!("parse config {}", p.display()))?
            }
            None => Self::default(),
        };
        if let Some(url) = env.var("DATABASE_URL") {
            cfg.database.url = Some(url);
        }
        if let Some(listen) = env.var("THINKTIN_LISTEN") {
            cfg.listen = listen.parse().context("THINKTIN_LISTEN")?;
        }
        if let Some(node) = env.var("THINKTIN_NODE_ID") {
            cfg.node_id = Some(node);
        }
        cfg.validate()?;
        Ok(cfg)
    }

    pub fn parse(text: &str) -> anyhow::Result<Self> {
        Ok(toml::from_str(text)?)
    }

    fn validate(&self) -> anyhow::Result<()> {
        if self.database.url.is_none() {
            bail!("database url is not configured (set DATABASE_URL)");
        }
        if self.database.max_connections == 0 {
            bail!("database.max_connections must be positive");
        }
        if let Some(id) = &self.node_id
            && (id.is_empty() || id.len() > 128)
        {
            bail!("node_id must be 1-128 characters");
        }
        Ok(())
    }

    pub fn database_url(&self) -> &str {
        self.database.url.as_deref().unwrap_or_default()
    }

    pub fn node_id(&self) -> String {
        self.node_id.clone().unwrap_or_else(default_node_id)
    }

    pub fn drain(&self) -> Duration {
        Duration::from_secs(self.shutdown.drain_secs)
    }

    pub fn grace(&self) -> Duration {
        Duration::from_secs(self.shutdown.grace_secs)
    }
}

fn default_node_id() -> String {
    let host = std::env::var("HOSTNAME")
        .ok()
        .or_else(|| std::fs::read_to_string("/etc/hostname").ok())
        .map(|h| h.trim().to_owned())
        .filter(|h| !h.is_empty())
        .unwrap_or_else(|| "node".into());
    format!("{host}-{}", std::process::id())
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;

    struct MapEnv(HashMap<&'static str, &'static str>);

    impl Env for MapEnv {
        fn var(&self, key: &str) -> Option<String> {
            self.0.get(key).map(|v| v.to_string())
        }
    }

    #[test]
    fn defaults_and_env_overrides() {
        let env = MapEnv(HashMap::from([
            ("DATABASE_URL", "postgres://u:p@db/thinktin"),
            ("THINKTIN_LISTEN", "0.0.0.0:9000"),
        ]));
        let cfg = Config::load(None, &env).unwrap();
        assert_eq!(cfg.database_url(), "postgres://u:p@db/thinktin");
        assert_eq!(cfg.listen.port(), 9000);
        assert_eq!(cfg.database.max_connections, 20);
        assert_eq!(cfg.grace(), Duration::from_secs(30));
        assert!(cfg.node_id().contains('-'));
    }

    #[test]
    fn file_values_and_validation() {
        let cfg = Config::parse(
            r#"
            listen = "127.0.0.1:8081"
            node_id = "api-1"
            [database]
            url = "postgres://localhost/dev"
            migrate_on_start = true
            [shutdown]
            drain_secs = 0
            "#,
        )
        .unwrap();
        assert_eq!(cfg.node_id(), "api-1");
        assert!(cfg.database.migrate_on_start);
        assert_eq!(cfg.shutdown.grace_secs, 30, "unset keys keep defaults");
        assert!(
            Config::parse("lisen = \"x\"").is_err(),
            "typos are rejected"
        );
        let err = Config::load(None, &MapEnv(HashMap::new())).unwrap_err();
        assert!(err.to_string().contains("DATABASE_URL"));
    }
}
