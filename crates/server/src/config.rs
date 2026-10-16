//! 配置：TOML 文件 + 环境变量覆盖。密钥类的值（数据库连接串）只建议走环境变量。

use std::net::SocketAddr;
use std::path::Path;
use std::time::Duration;

use anyhow::{Context, bail};
use serde::Deserialize;

#[derive(Clone, Deserialize)]
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
    pub storage: Storage,
    pub push: Push,
    pub compliance: Compliance,
    pub observability: Observability,
    pub sms: Sms,
    pub kms: KmsSettings,
    /// 沙箱令牌签名私钥种子（base64url），只从环境变量 THINKTIN_SANDBOX_TOKEN_SEED 读。
    #[serde(skip)]
    pub sandbox_token_seed: Option<String>,
    /// 极光推送的 Master Secret，只从环境变量 THINKTIN_JPUSH_MASTER_SECRET 读。
    #[serde(skip)]
    pub jpush_master_secret: Option<String>,
    /// CubeAPI 的 key，只从环境变量 THINKTIN_CUBE_API_KEY 读（CubeAPI 没开鉴权时不用配）。
    #[serde(skip)]
    pub cube_api_key: Option<String>,
    /// S3 兼容存储的访问密钥，只从环境变量 THINKTIN_S3_ACCESS_KEY_ID、THINKTIN_S3_SECRET_ACCESS_KEY 读。
    #[serde(skip)]
    pub s3_access_key_id: Option<String>,
    #[serde(skip)]
    pub s3_secret_access_key: Option<String>,
    /// 阿里云短信的 AccessKey，只从环境变量 THINKTIN_ALIYUN_SMS_ACCESS_KEY_ID、
    /// THINKTIN_ALIYUN_SMS_ACCESS_KEY_SECRET 读。
    #[serde(skip)]
    pub aliyun_sms_access_key_id: Option<String>,
    #[serde(skip)]
    pub aliyun_sms_access_key_secret: Option<String>,
    /// 阿里云 KMS 的 AccessKey，只从环境变量 THINKTIN_ALIYUN_KMS_ACCESS_KEY_ID、
    /// THINKTIN_ALIYUN_KMS_ACCESS_KEY_SECRET 读。
    #[serde(skip)]
    pub aliyun_kms_access_key_id: Option<String>,
    #[serde(skip)]
    pub aliyun_kms_access_key_secret: Option<String>,
    /// 接口用的密钥，只从环境变量读（见 [`ApiSecrets`]）。
    #[serde(skip)]
    pub api_secrets: ApiSecrets,
}

/// 密钥类的值只显示有没有配置（打日志、调试输出时不泄露）。
impl std::fmt::Debug for Config {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Config")
            .field("listen", &self.listen)
            .field("node_id", &self.node_id)
            .field("database", &self.database)
            .field("shutdown", &self.shutdown)
            .field("log", &self.log)
            .field("api", &self.api)
            .field("worker", &self.worker)
            .field("sandbox", &self.sandbox)
            .field("storage", &self.storage)
            .field("push", &self.push)
            .field("compliance", &self.compliance)
            .field("observability", &self.observability)
            .field("sms", &self.sms)
            .field("kms", &self.kms)
            .field("sandbox_token_seed", &self.sandbox_token_seed.is_some())
            .field("jpush_master_secret", &self.jpush_master_secret.is_some())
            .field("cube_api_key", &self.cube_api_key.is_some())
            .field("s3_access_key_id", &self.s3_access_key_id.is_some())
            .field("s3_secret_access_key", &self.s3_secret_access_key.is_some())
            .field(
                "aliyun_sms_access_key_id",
                &self.aliyun_sms_access_key_id.is_some(),
            )
            .field(
                "aliyun_sms_access_key_secret",
                &self.aliyun_sms_access_key_secret.is_some(),
            )
            .field(
                "aliyun_kms_access_key_id",
                &self.aliyun_kms_access_key_id.is_some(),
            )
            .field(
                "aliyun_kms_access_key_secret",
                &self.aliyun_kms_access_key_secret.is_some(),
            )
            .field("api_secrets", &self.api_secrets)
            .finish()
    }
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
    /// 限流与防刷（5.4）：`[api.limits]`，各项上限，0 表示不限。
    pub limits: gateway::LimitConfig,
}

impl Default for Api {
    fn default() -> Self {
        Self {
            enabled: false,
            dev_sms: false,
            access_token_kid: "a1".into(),
            kms_key_id: "local-1".into(),
            default_platform_tools: orchestrator::tools::SCHEDULE_TOOLS
                .iter()
                .chain(orchestrator::tools::ARTIFACT_TOOLS.iter())
                .chain(orchestrator::vault::VAULT_TOOLS.iter())
                .chain(orchestrator::delegate::DELEGATE_TOOLS.iter())
                .map(|s| s.to_string())
                // 电脑工具（14.2）：只有登录着电脑的用户的 agent 才真的拿到。
                .chain(proto::computer::names().map(String::from))
                .collect(),
            limits: gateway::LimitConfig::default(),
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
    /// 执行租约时长：副本被杀、宿主机宕机后，别的副本最多等这么久（再加一个接管间隔）接手它的运行。
    /// 续租间隔是它的四分之一。
    pub lease_secs: u64,
    /// 多久扫一次租约过期的运行。
    pub takeover_every_secs: u64,
    /// 运行中断（agent 崩溃、租约过期）后第一次重试前等多久，之后每次翻倍。
    pub retry_backoff_secs: u64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Sandbox {
    /// 沙箱后端：local（本地开发，没有隔离）或 cube（CubeSandbox，6.2）。
    pub provider: String,
    /// local 后端的数据目录。
    pub local_root: std::path::PathBuf,
    /// cube 后端（`provider = "cube"` 时用）。CubeAPI 的 key 只从环境变量 THINKTIN_CUBE_API_KEY 读。
    pub cube: CubeSandbox,
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

/// cube 后端的配置（见 docs/sandbox-cube.md）。
#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct CubeSandbox {
    /// CubeAPI 地址（E2B SDK 的 `E2B_API_URL`）。
    pub api_url: String,
    /// 沙箱域名兜底（Cube 的响应里会带）。
    pub domain: Option<String>,
    /// 直接连 CubeProxy 的地址（如 `http://10.0.0.5`），按 Host 头路由；不填就走泛域名 DNS。
    pub proxy_url: Option<String>,
    /// 不用 `proxy_url` 时数据面的 scheme。
    pub data_scheme: String,
    /// 沙箱里的根目录：`home` 是 HOME，`workspace` 挂工作区卷。
    pub root: String,
    /// 沙箱里运行进程的用户。
    pub user: String,
    /// 模型网关看到的沙箱来源地址（Cube 节点的出网地址或 NAT 地址），沙箱令牌绑定它。
    pub egress_address: Option<std::net::IpAddr>,
    /// 工作区放在 Cube 卷上（要先在 CubeMaster 里配好卷插件）。
    pub use_volumes: bool,
    /// 卷插件名，不填用 CubeMaster 的默认插件。
    pub volume_driver: Option<String>,
    /// 控制面请求的超时（秒）。
    pub request_timeout_secs: u64,
}

impl Default for CubeSandbox {
    fn default() -> Self {
        let d = sandbox::cube::CubeConfig::default();
        Self {
            api_url: d.api_url,
            domain: d.domain,
            proxy_url: d.proxy_url,
            data_scheme: d.data_scheme,
            root: d.root,
            user: d.user,
            egress_address: d.egress_address,
            use_volumes: d.use_volumes,
            volume_driver: d.volume_driver,
            request_timeout_secs: d.request_timeout.as_secs(),
        }
    }
}

impl CubeSandbox {
    pub fn to_config(&self, api_key: Option<String>) -> sandbox::cube::CubeConfig {
        sandbox::cube::CubeConfig {
            api_url: self.api_url.clone(),
            api_key,
            domain: self.domain.clone(),
            proxy_url: self.proxy_url.clone(),
            data_scheme: self.data_scheme.clone(),
            root: self.root.clone(),
            user: self.user.clone(),
            egress_address: self.egress_address,
            use_volumes: self.use_volumes,
            volume_driver: self.volume_driver.clone(),
            request_timeout: Duration::from_secs(self.request_timeout_secs),
        }
    }
}

/// 可观测性（2.8）。
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Observability {
    /// Prometheus `/metrics` 的监听地址（只给内网的抓取方）；不配就不提供。
    pub metrics_listen: Option<SocketAddr>,
}

/// 合规（16.3）：AI 生成内容标识、推送的内容安全过滤。
#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Compliance {
    /// 标识里的服务提供者名称或编码（ASCII，放进元数据头）。
    pub content_producer: String,
    /// 下载产出物时加标识（元数据头；纯文本和 Markdown 末尾加一行显式标识）。
    pub label_downloads: bool,
    /// 推送文字的关键词过滤表（一行一个）；不配就不过滤。
    pub push_keywords_file: Option<std::path::PathBuf>,
}

impl Default for Compliance {
    fn default() -> Self {
        Self {
            content_producer: "ThinkTin".into(),
            label_downloads: true,
            push_keywords_file: None,
        }
    }
}

/// 主密钥（2.6）：包裹每个用户的数据密钥（DEK）。
/// - local：环境变量 THINKTIN_KMS_KEY 里的本地主密钥（开发、测试用）；
/// - aliyun：阿里云 KMS，主密钥不出 KMS。这时如果还配着 THINKTIN_KMS_KEY，它只用来解迁移前包裹的老 DEK。
#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct KmsSettings {
    pub provider: String,
    /// 解开的 DEK 在进程里缓存多久（秒），省得每次加解密都调云 KMS。
    pub cache_secs: u64,
    /// aliyun（`provider = "aliyun"` 时用）。AccessKey 只从环境变量
    /// THINKTIN_ALIYUN_KMS_ACCESS_KEY_ID、THINKTIN_ALIYUN_KMS_ACCESS_KEY_SECRET 读。
    pub aliyun: Option<AliyunKms>,
}

impl Default for KmsSettings {
    fn default() -> Self {
        Self {
            provider: "local".into(),
            cache_secs: 300,
            aliyun: None,
        }
    }
}

/// 阿里云 KMS。
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AliyunKms {
    /// 比如 `https://kms.cn-hangzhou.aliyuncs.com`。
    pub endpoint: String,
    /// 主密钥的 KeyId 或别名（`alias/...`，换主密钥版本时不用改配置）。
    pub key_id: String,
}

/// 短信（4.1 登录验证码）。没配服务商时只能用 `api.dev_sms`（本地开发）。
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Sms {
    /// 阿里云短信服务。AccessKey 只从环境变量 THINKTIN_ALIYUN_SMS_ACCESS_KEY_ID、
    /// THINKTIN_ALIYUN_SMS_ACCESS_KEY_SECRET 读。
    pub aliyun: Option<AliyunSms>,
}

/// 阿里云短信：签名和验证码模板在阿里云控制台申请，模板里的变量是 `${code}`。
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AliyunSms {
    /// 默认中国站 `https://dysmsapi.aliyuncs.com`；国际站账号用 `https://dysmsapi.ap-southeast-1.aliyuncs.com`。
    #[serde(default = "default_aliyun_sms_endpoint")]
    pub endpoint: String,
    /// 国内短信的签名。
    pub sign_name: String,
    /// 国内验证码模板的 code（`SMS_` 开头）。
    pub template_code: String,
    /// 国际 / 港澳台消息的签名和模板（两个一起配）；不配就只能给国内号码发。
    pub international_sign_name: Option<String>,
    pub international_template_code: Option<String>,
}

fn default_aliyun_sms_endpoint() -> String {
    auth::sms::aliyun::ENDPOINT.into()
}

/// 产出物存储（8.4）。内容按用户 DEK 加密后才落盘。
#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Storage {
    /// 对象存储后端：local（本地目录，开发用；接口和后台任务要能看到同一个目录）或 s3（S3 兼容的对象存储）。
    pub provider: String,
    /// local 后端的目录。
    pub local_root: std::path::PathBuf,
    /// s3 后端（`provider = "s3"` 时用）。
    pub s3: Option<S3Storage>,
}

impl Default for Storage {
    fn default() -> Self {
        Self {
            provider: "local".into(),
            local_root: ".thinktin/blobs".into(),
            s3: None,
        }
    }
}

/// S3 兼容的对象存储：AWS S3、阿里云 OSS、腾讯云 COS、MinIO。访问密钥只从环境变量
/// THINKTIN_S3_ACCESS_KEY_ID、THINKTIN_S3_SECRET_ACCESS_KEY 读。
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct S3Storage {
    /// 服务地址，不带桶名：`https://oss-cn-hangzhou.aliyuncs.com`、`https://s3.us-east-1.amazonaws.com`。
    pub endpoint: String,
    /// 签名用的区域：AWS 是 `us-east-1` 之类；OSS 的 S3 兼容接口是 `oss-cn-hangzhou` 之类。
    pub region: String,
    pub bucket: String,
    /// 对象键的前缀，比如 `prod/`。
    #[serde(default)]
    pub prefix: String,
    /// 路径风格（MinIO 常用）；默认虚拟主机风格（AWS、OSS 要求的）。
    #[serde(default)]
    pub path_style: bool,
    /// 单个请求的超时（秒）。
    #[serde(default = "default_storage_timeout")]
    pub timeout_secs: u64,
}

fn default_storage_timeout() -> u64 {
    60
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Push {
    pub apns: Option<Apns>,
    /// 国内 Android：经极光推送覆盖各厂商通道（设备的推送通道是 unipush）。
    pub jpush: Option<Jpush>,
    /// 海外 Android：Firebase Cloud Messaging（设备的推送通道是 fcm）。
    pub fcm: Option<Fcm>,
}

/// FCM：服务账号的 JSON 密钥文件（Firebase 控制台“项目设置 → 服务账号”生成）放在 `service_account_path`，
/// 和 APNs 的私钥文件一样只给服务进程读。
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Fcm {
    #[serde(default = "default_fcm_endpoint")]
    pub endpoint: String,
    pub service_account_path: std::path::PathBuf,
    /// App 里审批通知的通知渠道 id。
    #[serde(default = "default_approval_channel")]
    pub approval_channel: String,
    /// App 里其他通知的通知渠道 id。
    #[serde(default = "default_results_channel")]
    pub default_channel: String,
}

fn default_fcm_endpoint() -> String {
    notify::fcm::ENDPOINT.into()
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Jpush {
    #[serde(default = "default_jpush_endpoint")]
    pub endpoint: String,
    pub app_key: String,
    /// App 里审批通知的通知渠道 id。
    #[serde(default = "default_approval_channel")]
    pub approval_channel: String,
    /// App 里其他通知的通知渠道 id。
    #[serde(default = "default_results_channel")]
    pub default_channel: String,
    /// 各厂商的消息分类参数（厂商后台申请下来以后再填）。
    #[serde(default)]
    pub vendors: notify::jpush::VendorOptions,
}

fn default_jpush_endpoint() -> String {
    notify::jpush::ENDPOINT.into()
}

fn default_approval_channel() -> String {
    "tt_approval".into()
}

fn default_results_channel() -> String {
    "tt_results".into()
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
            lease_secs: 60,
            takeover_every_secs: 15,
            retry_backoff_secs: 30,
        }
    }
}

impl Default for Sandbox {
    fn default() -> Self {
        Self {
            provider: "local".into(),
            local_root: ".thinktin/sandboxes".into(),
            cube: CubeSandbox::default(),
            network_allow: Vec::new(),
            shim_path: "agent-shim".into(),
            gateway_url: "http://127.0.0.1:8790".into(),
            manifest_override: None,
            token_kid: "k1".into(),
        }
    }
}

#[derive(Clone, Deserialize)]
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
            storage: Storage::default(),
            push: Push::default(),
            compliance: Compliance::default(),
            sms: Sms::default(),
            kms: KmsSettings::default(),
            observability: Observability::default(),
            sandbox_token_seed: None,
            jpush_master_secret: None,
            cube_api_key: None,
            s3_access_key_id: None,
            s3_secret_access_key: None,
            aliyun_sms_access_key_id: None,
            aliyun_sms_access_key_secret: None,
            aliyun_kms_access_key_id: None,
            aliyun_kms_access_key_secret: None,
            api_secrets: ApiSecrets::default(),
        }
    }
}

/// 连接串里有密码，只显示有没有配置。
impl std::fmt::Debug for Database {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Database")
            .field("url", &self.url.is_some())
            .field("max_connections", &self.max_connections)
            .field("migrate_on_start", &self.migrate_on_start)
            .finish()
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
        cfg.jpush_master_secret = env.var("THINKTIN_JPUSH_MASTER_SECRET");
        cfg.cube_api_key = env.var("THINKTIN_CUBE_API_KEY");
        cfg.s3_access_key_id = env.var("THINKTIN_S3_ACCESS_KEY_ID");
        cfg.s3_secret_access_key = env.var("THINKTIN_S3_SECRET_ACCESS_KEY");
        cfg.aliyun_sms_access_key_id = env.var("THINKTIN_ALIYUN_SMS_ACCESS_KEY_ID");
        cfg.aliyun_sms_access_key_secret = env.var("THINKTIN_ALIYUN_SMS_ACCESS_KEY_SECRET");
        cfg.aliyun_kms_access_key_id = env.var("THINKTIN_ALIYUN_KMS_ACCESS_KEY_ID");
        cfg.aliyun_kms_access_key_secret = env.var("THINKTIN_ALIYUN_KMS_ACCESS_KEY_SECRET");
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
            .filter(|(k, _)| *k != "THINKTIN_KMS_KEY" || self.kms.provider == "local")
            .filter(|(_, v)| v.is_none())
            .map(|(k, _)| k)
            .collect();
            if !missing.is_empty() {
                bail!("api.enabled needs {}", missing.join(", "));
            }
            match &self.sms.aliyun {
                Some(a) => {
                    if self.aliyun_sms_access_key_id.is_none()
                        || self.aliyun_sms_access_key_secret.is_none()
                    {
                        bail!(
                            "sms.aliyun needs THINKTIN_ALIYUN_SMS_ACCESS_KEY_ID and THINKTIN_ALIYUN_SMS_ACCESS_KEY_SECRET"
                        );
                    }
                    if a.international_sign_name.is_some()
                        != a.international_template_code.is_some()
                    {
                        bail!(
                            "sms.aliyun: international_sign_name and international_template_code go together"
                        );
                    }
                }
                None if !self.api.dev_sms => bail!(
                    "no SMS provider is configured: add [sms.aliyun], or set api.dev_sms = true for local development"
                ),
                None => {}
            }
        }
        if self.worker.enabled {
            if self.worker.lease_secs < 4 {
                bail!(
                    "worker.lease_secs must be at least 4 (leases are renewed every quarter of it)"
                );
            }
            if self.worker.takeover_every_secs == 0 || self.worker.retry_backoff_secs == 0 {
                bail!("worker.takeover_every_secs and worker.retry_backoff_secs must be positive");
            }
            if self.sandbox_token_seed.is_none() {
                bail!(
                    "worker.enabled needs THINKTIN_SANDBOX_TOKEN_SEED (generate one with `llm-gw keygen`)"
                );
            }
            match self.sandbox.provider.as_str() {
                "local" => {}
                "cube" => {
                    if self.sandbox.cube.api_url.is_empty() {
                        bail!("sandbox.cube.api_url is not configured");
                    }
                    // Cube 的出网经节点 SNAT：不配就签不出绑定来源地址的沙箱令牌，模型网关会拒绝。
                    if self.sandbox.cube.egress_address.is_none() {
                        bail!(
                            "sandbox.cube.egress_address is not configured (the address the model gateway sees for Cube sandboxes)"
                        );
                    }
                }
                other => bail!("sandbox.provider {other:?} is not supported (local or cube)"),
            }
            if self.kms.provider == "local" && self.api_secrets.kms_key.is_none() {
                bail!("worker.enabled needs THINKTIN_KMS_KEY (artifacts are encrypted per user)");
            }
            if self.push.jpush.is_some() && self.jpush_master_secret.is_none() {
                bail!("push.jpush needs THINKTIN_JPUSH_MASTER_SECRET");
            }
            if self.worker.max_concurrent_runs == 0 {
                bail!("worker.max_concurrent_runs must be positive");
            }
        }
        match self.kms.provider.as_str() {
            "local" => {}
            "aliyun" => {
                if self.kms.aliyun.is_none() {
                    bail!("kms.provider = \"aliyun\" needs a [kms.aliyun] section");
                }
                if self.aliyun_kms_access_key_id.is_none()
                    || self.aliyun_kms_access_key_secret.is_none()
                {
                    bail!(
                        "kms.provider = \"aliyun\" needs THINKTIN_ALIYUN_KMS_ACCESS_KEY_ID and THINKTIN_ALIYUN_KMS_ACCESS_KEY_SECRET"
                    );
                }
            }
            other => bail!("kms.provider {other:?} is not supported (local or aliyun)"),
        }
        if self.api.enabled || self.worker.enabled {
            match self.storage.provider.as_str() {
                "local" => {}
                "s3" => {
                    if self.storage.s3.is_none() {
                        bail!("storage.provider = \"s3\" needs a [storage.s3] section");
                    }
                    if self.s3_access_key_id.is_none() || self.s3_secret_access_key.is_none() {
                        bail!(
                            "storage.provider = \"s3\" needs THINKTIN_S3_ACCESS_KEY_ID and THINKTIN_S3_SECRET_ACCESS_KEY"
                        );
                    }
                }
                other => bail!("storage.provider {other:?} is not supported (local or s3)"),
            }
        }
        let producer = &self.compliance.content_producer;
        if producer.is_empty()
            || producer.len() > 64
            || !producer.bytes().all(|b| b.is_ascii_graphic() || b == b' ')
        {
            bail!("compliance.content_producer must be 1-64 printable ASCII characters");
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
    fn debug_output_hides_secrets() {
        let mut cfg = Config::parse("").unwrap();
        cfg.database.url = Some("postgres://u:hunter2@db/x".into());
        cfg.sandbox_token_seed = Some("seed-value-xyz".into());
        cfg.jpush_master_secret = Some("jpush-secret-xyz".into());
        cfg.api_secrets.kms_key = Some("kms-hex-xyz".into());
        cfg.cube_api_key = Some("cube-key-xyz".into());
        let s = format!("{cfg:?}");
        for secret in [
            "hunter2",
            "seed-value-xyz",
            "jpush-secret-xyz",
            "kms-hex-xyz",
            "cube-key-xyz",
        ] {
            assert!(!s.contains(secret), "{secret} leaked: {s}");
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
    fn cube_sandbox_settings() {
        let cfg = Config::parse(
            r#"
            [sandbox]
            provider = "cube"
            [sandbox.cube]
            api_url = "http://cube-api:3000"
            proxy_url = "http://10.0.0.5"
            egress_address = "10.0.0.20"
            volume_driver = "nfs"
            "#,
        )
        .unwrap();
        let c = cfg.sandbox.cube.to_config(Some("k".into()));
        assert_eq!(c.api_url, "http://cube-api:3000");
        assert_eq!(c.proxy_url.as_deref(), Some("http://10.0.0.5"));
        assert_eq!(c.root, "/sandbox", "unset keys keep defaults");
        assert_eq!(c.user, "user");
        assert_eq!(c.egress_address, Some("10.0.0.20".parse().unwrap()));
        assert_eq!(c.volume_driver.as_deref(), Some("nfs"));
        assert_eq!(c.api_key.as_deref(), Some("k"));
        assert!(
            Config::parse("[sandbox.cube]\napi_ur = \"x\"").is_err(),
            "typos are rejected"
        );

        let dir = std::env::temp_dir().join(format!("tt-cube-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("server.toml");
        let env = MapEnv(HashMap::from([
            ("DATABASE_URL", "postgres://x"),
            ("THINKTIN_SANDBOX_TOKEN_SEED", "seed"),
        ]));
        std::fs::write(
            &path,
            "[worker]\nenabled = true\n[sandbox]\nprovider = \"cube\"\n",
        )
        .unwrap();
        let err = Config::load(Some(&path), &env).unwrap_err();
        assert!(err.to_string().contains("egress_address"), "{err}");
        std::fs::write(
            &path,
            "[worker]\nenabled = true\n[sandbox]\nprovider = \"podman\"\n",
        )
        .unwrap();
        let err = Config::load(Some(&path), &env).unwrap_err();
        assert!(err.to_string().contains("not supported"), "{err}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn aliyun_kms_needs_its_section_and_keys() {
        let dir = std::env::temp_dir().join(format!("tt-kms-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("server.toml");
        // 用阿里云 KMS 时不再要求本地主密钥。
        let mut vars = HashMap::from([
            ("DATABASE_URL", "postgres://x"),
            ("THINKTIN_SANDBOX_TOKEN_SEED", "seed"),
        ]);
        let worker = "[worker]\nenabled = true\n";
        std::fs::write(&path, format!("{worker}[kms]\nprovider = \"aliyun\"\n")).unwrap();
        let err = Config::load(Some(&path), &MapEnv(vars.clone())).unwrap_err();
        assert!(err.to_string().contains("[kms.aliyun]"), "{err}");
        std::fs::write(
            &path,
            format!(
                "{worker}[kms]\nprovider = \"aliyun\"\n[kms.aliyun]\n\
                 endpoint = \"https://kms.cn-hangzhou.aliyuncs.com\"\nkey_id = \"alias/thinktin-dek\"\n"
            ),
        )
        .unwrap();
        let err = Config::load(Some(&path), &MapEnv(vars.clone())).unwrap_err();
        assert!(
            err.to_string()
                .contains("THINKTIN_ALIYUN_KMS_ACCESS_KEY_ID"),
            "{err}"
        );
        vars.insert("THINKTIN_ALIYUN_KMS_ACCESS_KEY_ID", "id");
        vars.insert("THINKTIN_ALIYUN_KMS_ACCESS_KEY_SECRET", "kms-secret-xyz");
        let cfg = Config::load(Some(&path), &MapEnv(vars.clone())).unwrap();
        assert_eq!(cfg.kms.cache_secs, 300);
        assert_eq!(
            cfg.kms.aliyun.as_ref().unwrap().key_id,
            "alias/thinktin-dek"
        );
        assert!(!format!("{cfg:?}").contains("kms-secret-xyz"));
        std::fs::write(&path, format!("{worker}[kms]\nprovider = \"vault\"\n")).unwrap();
        let err = Config::load(Some(&path), &MapEnv(vars)).unwrap_err();
        assert!(err.to_string().contains("not supported"), "{err}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_api_needs_an_sms_provider() {
        let dir = std::env::temp_dir().join(format!("tt-sms-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("server.toml");
        let mut vars = HashMap::from([
            ("DATABASE_URL", "postgres://x"),
            ("THINKTIN_ACCESS_TOKEN_SEED", "seed"),
            ("THINKTIN_CODE_PEPPER", "ab"),
            ("THINKTIN_KMS_KEY", "ab"),
        ]);
        let api = "[api]\nenabled = true\n";
        std::fs::write(&path, api).unwrap();
        let err = Config::load(Some(&path), &MapEnv(vars.clone())).unwrap_err();
        assert!(err.to_string().contains("no SMS provider"), "{err}");
        let aliyun = "[sms.aliyun]\nsign_name = \"ThinkTin\"\ntemplate_code = \"SMS_1\"\n";
        std::fs::write(&path, format!("{api}{aliyun}")).unwrap();
        let err = Config::load(Some(&path), &MapEnv(vars.clone())).unwrap_err();
        assert!(
            err.to_string()
                .contains("THINKTIN_ALIYUN_SMS_ACCESS_KEY_ID"),
            "{err}"
        );
        vars.insert("THINKTIN_ALIYUN_SMS_ACCESS_KEY_ID", "id");
        vars.insert("THINKTIN_ALIYUN_SMS_ACCESS_KEY_SECRET", "sms-secret-xyz");
        let cfg = Config::load(Some(&path), &MapEnv(vars.clone())).unwrap();
        let a = cfg.sms.aliyun.as_ref().unwrap();
        assert_eq!(a.endpoint, auth::sms::aliyun::ENDPOINT);
        assert_eq!(a.international_template_code, None);
        assert!(!format!("{cfg:?}").contains("sms-secret-xyz"));
        std::fs::write(
            &path,
            format!("{api}{aliyun}international_sign_name = \"ThinkTin\"\n"),
        )
        .unwrap();
        let err = Config::load(Some(&path), &MapEnv(vars)).unwrap_err();
        assert!(err.to_string().contains("go together"), "{err}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn s3_storage_needs_its_section_and_keys() {
        let dir = std::env::temp_dir().join(format!("tt-s3-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("server.toml");
        let mut vars = HashMap::from([
            ("DATABASE_URL", "postgres://x"),
            ("THINKTIN_SANDBOX_TOKEN_SEED", "seed"),
            ("THINKTIN_KMS_KEY", "ab"),
        ]);
        let worker = "[worker]\nenabled = true\n";
        std::fs::write(&path, format!("{worker}[storage]\nprovider = \"s3\"\n")).unwrap();
        let err = Config::load(Some(&path), &MapEnv(vars.clone())).unwrap_err();
        assert!(err.to_string().contains("[storage.s3]"), "{err}");
        std::fs::write(
            &path,
            format!(
                "{worker}[storage]\nprovider = \"s3\"\n[storage.s3]\n\
                 endpoint = \"https://oss-cn-hangzhou.aliyuncs.com\"\n\
                 region = \"oss-cn-hangzhou\"\nbucket = \"tt-artifacts\"\n"
            ),
        )
        .unwrap();
        let err = Config::load(Some(&path), &MapEnv(vars.clone())).unwrap_err();
        assert!(
            err.to_string().contains("THINKTIN_S3_ACCESS_KEY_ID"),
            "{err}"
        );
        vars.insert("THINKTIN_S3_ACCESS_KEY_ID", "AKID");
        vars.insert("THINKTIN_S3_SECRET_ACCESS_KEY", "s3-secret-xyz");
        let cfg = Config::load(Some(&path), &MapEnv(vars.clone())).unwrap();
        let s3 = cfg.storage.s3.as_ref().unwrap();
        assert_eq!(
            (
                s3.bucket.as_str(),
                s3.prefix.as_str(),
                s3.path_style,
                s3.timeout_secs
            ),
            ("tt-artifacts", "", false, 60)
        );
        assert!(!format!("{cfg:?}").contains("s3-secret-xyz"));
        std::fs::write(&path, format!("{worker}[storage]\nprovider = \"gcs\"\n")).unwrap();
        let err = Config::load(Some(&path), &MapEnv(vars)).unwrap_err();
        assert!(err.to_string().contains("not supported"), "{err}");
        let _ = std::fs::remove_dir_all(&dir);
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
            [push.jpush]
            app_key = "abc"
            [push.jpush.vendors]
            huawei_category = "WORK"
            "#,
        )
        .unwrap();
        let db = ("DATABASE_URL", "postgres://x");
        let err = Config::load(Some(&path), &MapEnv(HashMap::from([db]))).unwrap_err();
        assert!(err.to_string().contains("THINKTIN_SANDBOX_TOKEN_SEED"));
        let seed = ("THINKTIN_SANDBOX_TOKEN_SEED", "seed");
        let err = Config::load(Some(&path), &MapEnv(HashMap::from([db, seed]))).unwrap_err();
        assert!(err.to_string().contains("THINKTIN_KMS_KEY"));
        let kms = ("THINKTIN_KMS_KEY", "ab");
        let err = Config::load(Some(&path), &MapEnv(HashMap::from([db, seed, kms]))).unwrap_err();
        assert!(err.to_string().contains("THINKTIN_JPUSH_MASTER_SECRET"));
        let cfg = Config::load(
            Some(&path),
            &MapEnv(HashMap::from([
                db,
                seed,
                kms,
                ("THINKTIN_JPUSH_MASTER_SECRET", "s"),
            ])),
        )
        .unwrap();
        let jpush = cfg.push.jpush.clone().unwrap();
        assert_eq!(jpush.endpoint, "https://api.jpush.cn");
        assert_eq!(jpush.default_channel, "tt_results");
        assert_eq!(jpush.vendors.huawei_category.as_deref(), Some("WORK"));
        assert!(cfg.worker.enabled);
        assert_eq!(
            cfg.push.apns.unwrap().endpoint,
            "https://api.push.apple.com"
        );
        std::fs::remove_dir_all(dir).ok();
    }
}
