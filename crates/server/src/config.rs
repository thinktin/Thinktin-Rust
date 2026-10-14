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
    pub api: Api,
    pub worker: Worker,
    pub sandbox: Sandbox,
    pub push: Push,
    /// 沙箱令牌签名私钥种子（base64url），只从环境变量 THINKTIN_SANDBOX_TOKEN_SEED 读。
    #[serde(skip)]
    pub sandbox_token_seed: Option<String>,
    /// 接口用的密钥，只从环境变量读（见 [`ApiSecrets`]）。
    #[serde(skip)]
    pub api_secrets: ApiSecrets,
}

/// 客户端接口（接入网关）。
#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Api {
    pub enabled: bool,
    /// 只用于本地开发：验证码打印到标准错误，不发短信。
    pub dev_sms: bool,
    /// 访问令牌签名密钥的 kid。
    pub access_token_kid: String,
    /// 本地 KMS 主密钥的 id（生产环境换成云 KMS）。
    pub kms_key_id: String,
    /// 领养、建计划时默认给 agent 的平台工具。
    pub default_platform_tools: Vec<String>,
}

impl Default for Api {
    fn default() -> Self {
        Self {
            enabled: false,
            dev_sms: false,
            access_token_kid: "a1".into(),
            kms_key_id: "local-1".into(),
            default_platform_tools: Vec::new(),
        }
    }
}

/// 接口用的密钥。
#[derive(Clone, Default)]
pub struct ApiSecrets {
    /// THINKTIN_ACCESS_TOKEN_SEED：访问令牌签名私钥种子（base64url）。
    pub access_token_seed: Option<String>,
    /// THINKTIN_CODE_PEPPER：验证码 HMAC 的服务端密钥（十六进制，至少 32 字节）。
    pub code_pepper: Option<String>,
    /// THINKTIN_KMS_KEY：本地 KMS 主密钥（64 位十六进制）。
    pub kms_key: Option<String>,
}

impl std::fmt::Debug for ApiSecrets {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ApiSecrets")
            .field("access_token_seed", &self.access_token_seed.is_some())
            .field("code_pepper", &self.code_pepper.is_some())
            .field("kms_key", &self.kms_key.is_some())
            .finish()
    }
}

/// 后台任务：调度循环、执行器、出箱投递、实例巡检、数据维护。
#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Worker {
    /// 这个副本跑后台任务。只做接口的副本不开。
    pub enabled: bool,
    /// 同时执行的运行数上限。
    pub max_concurrent_runs: usize,
    /// 实例巡检（空闲暂停、归档、回收）间隔。
    pub sweep_every_secs: u64,
    /// 数据维护（事件分区、过期验证码）间隔。
    pub maintenance_every_secs: u64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Sandbox {
    /// 沙箱后端：目前只有 local（本地开发）；cube 待 WBS 6.2。
    pub provider: String,
    /// local 后端的数据目录。
    pub local_root: std::path::PathBuf,
    /// 沙箱出网白名单。
    pub network_allow: Vec<String>,
    /// 沙箱里 agent-shim 的路径。
    pub shim_path: String,
    /// 沙箱里看到的模型网关地址。
    pub gateway_url: String,
    /// 本地开发：用这个清单代替内置清单（比如接假 agent）。
    pub manifest_override: Option<String>,
    /// 沙箱令牌签名密钥的 kid（模型网关按它找公钥）。
    pub token_kid: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Push {
    pub apns: Option<Apns>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Apns {
    /// 默认生产环境；测试包用 https://api.sandbox.push.apple.com。
    #[serde(default = "default_apns_endpoint")]
    pub endpoint: String,
    /// App 的 bundle id。
    pub topic: String,
    pub team_id: String,
    pub key_id: String,
    /// .p8 私钥文件。
    pub key_path: std::path::PathBuf,
}

fn default_apns_endpoint() -> String {
    "https://api.push.apple.com".into()
}

impl Default for Worker {
    fn default() -> Self {
        Self {
            enabled: false,
            max_concurrent_runs: 16,
            sweep_every_secs: 60,
            maintenance_every_secs: 3600,
        }
    }
}

impl Default for Sandbox {
    fn default() -> Self {
        Self {
            provider: "local".into(),
            local_root: ".thinktin/sandboxes".into(),
            network_allow: Vec::new(),
            shim_path: "agent-shim".into(),
            gateway_url: "http://127.0.0.1:8790".into(),
            manifest_override: None,
            token_kid: "k1".into(),
        }
    }
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
            api: Api::default(),
            worker: Worker::default(),
            sandbox: Sandbox::default(),
            push: Push::default(),
            sandbox_token_seed: None,
            api_secrets: ApiSecrets::default(),
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
        cfg.sandbox_token_seed = env.var("THINKTIN_SANDBOX_TOKEN_SEED");
        cfg.api_secrets = ApiSecrets {
            access_token_seed: env.var("THINKTIN_ACCESS_TOKEN_SEED"),
            code_pepper: env.var("THINKTIN_CODE_PEPPER"),
            kms_key: env.var("THINKTIN_KMS_KEY"),
        };
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
        if self.api.enabled {
            let missing: Vec<&str> = [
                (
                    "THINKTIN_ACCESS_TOKEN_SEED",
                    &self.api_secrets.access_token_seed,
                ),
                ("THINKTIN_CODE_PEPPER", &self.api_secrets.code_pepper),
                ("THINKTIN_KMS_KEY", &self.api_secrets.kms_key),
            ]
            .into_iter()
            .filter(|(_, v)| v.is_none())
            .map(|(k, _)| k)
            .collect();
            if !missing.is_empty() {
                bail!("api.enabled needs {}", missing.join(", "));
            }
            if !self.api.dev_sms {
                bail!(
                    "no SMS provider is configured yet; set api.dev_sms = true for local development"
                );
            }
        }
        if self.worker.enabled {
            if self.sandbox_token_seed.is_none() {
                bail!(
                    "worker.enabled needs THINKTIN_SANDBOX_TOKEN_SEED (generate one with `llm-gw keygen`)"
                );
            }
            if self.sandbox.provider != "local" {
                bail!(
                    "sandbox.provider {:?} is not supported yet (only \"local\")",
                    self.sandbox.provider
                );
            }
            if self.worker.max_concurrent_runs == 0 {
                bail!("worker.max_concurrent_runs must be positive");
            }
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

    #[test]
    fn workers_need_the_token_seed() {
        let dir = std::env::temp_dir().join(format!("tt-cfg-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("server.toml");
        std::fs::write(
            &path,
            r#"
            [worker]
            enabled = true
            [sandbox]
            local_root = "/var/lib/thinktin/sandboxes"
            [push.apns]
            topic = "app.thinktin"
            team_id = "T"
            key_id = "K"
            key_path = "/etc/thinktin/apns.p8"
            "#,
        )
        .unwrap();
        let db = ("DATABASE_URL", "postgres://x");
        let err = Config::load(Some(&path), &MapEnv(HashMap::from([db]))).unwrap_err();
        assert!(err.to_string().contains("THINKTIN_SANDBOX_TOKEN_SEED"));
        let cfg = Config::load(
            Some(&path),
            &MapEnv(HashMap::from([db, ("THINKTIN_SANDBOX_TOKEN_SEED", "seed")])),
        )
        .unwrap();
        assert!(cfg.worker.enabled);
        assert_eq!(
            cfg.push.apns.unwrap().endpoint,
            "https://api.push.apple.com"
        );
        std::fs::remove_dir_all(dir).ok();
    }
}
