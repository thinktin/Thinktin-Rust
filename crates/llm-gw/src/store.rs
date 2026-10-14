//! 路由数据（架构方案 5.5，WBS 9.2）：令牌 → 实例 → 别名 → 凭证 + 上游模型。
//!
//! 生产环境的数据在控制面（Postgres），网关通过 [`Directory`] 读取。这里提供内存实现，
//! 以及本地开发用的 JSON 文件格式 [`DevStore`]。

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, RwLock};

use anyhow::Context;
use keyvault::{SealedSecret, WrappedKey};
use serde::{Deserialize, Serialize};

/// 实例的模型别名指向哪把凭证、哪个上游模型。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Route {
    pub credential: String,
    pub model: String,
}

/// 单个实例的速率和并发上限（WBS 9.5）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Limits {
    /// 每分钟请求数，也是令牌桶容量。
    pub requests_per_minute: u32,
    /// 同时进行中的请求数。
    pub max_concurrent: u32,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            requests_per_minute: 120,
            max_concurrent: 8,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Instance {
    pub id: String,
    pub user_id: String,
    /// 当前沙箱 id。沙箱休眠或重建后变化，旧沙箱的令牌随之失效。
    pub sandbox: Option<String>,
    #[serde(default = "yes")]
    pub active: bool,
    #[serde(default)]
    pub routes: BTreeMap<String, Route>,
    #[serde(default)]
    pub limits: Limits,
}

fn yes() -> bool {
    true
}

/// 用户保存的一把厂商 key。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Credential {
    pub id: String,
    pub user_id: String,
    /// 厂商 id（见 `vendors`），或 `custom`。
    pub vendor: String,
    /// 只对 `custom` 生效：Anthropic 兼容接口的 base URL（不带 `/v1`）。
    #[serde(default)]
    pub anthropic_base: Option<String>,
    /// 只对 `custom` 生效：OpenAI 兼容接口的 base URL（带版本段）。
    #[serde(default)]
    pub openai_base: Option<String>,
    /// 只对 `custom` 生效：Responses API 的前缀（通常和 `openai_base` 相同），不提供就为空。
    #[serde(default)]
    pub responses_base: Option<String>,
    pub secret: SealedSecret,
    /// 每天最多消耗的 token 数（输入、缓存、输出合计）。
    #[serde(default)]
    pub daily_token_limit: Option<u64>,
    #[serde(default)]
    pub disabled: bool,
}

/// 网关读取路由数据的接口。实现要快（每个请求都会调用），生产实现应在本地缓存。
pub trait Directory: Send + Sync {
    fn instance(&self, id: &str) -> Option<Arc<Instance>>;
    fn credential(&self, id: &str) -> Option<Arc<Credential>>;
    fn grant_revoked(&self, grant: &str) -> bool;
}

#[derive(Default)]
struct Snapshot {
    instances: HashMap<String, Arc<Instance>>,
    credentials: HashMap<String, Arc<Credential>>,
    revoked_grants: HashSet<String>,
}

/// 内存里的 [`Directory`]，整体替换，读多写少。
#[derive(Default)]
pub struct MemoryDirectory(RwLock<Snapshot>);

impl MemoryDirectory {
    pub fn new(
        instances: Vec<Instance>,
        credentials: Vec<Credential>,
        revoked_grants: Vec<String>,
    ) -> Self {
        let dir = Self::default();
        dir.replace(instances, credentials, revoked_grants);
        dir
    }

    pub fn replace(
        &self,
        instances: Vec<Instance>,
        credentials: Vec<Credential>,
        revoked_grants: Vec<String>,
    ) {
        let snapshot = Snapshot {
            instances: instances
                .into_iter()
                .map(|i| (i.id.clone(), Arc::new(i)))
                .collect(),
            credentials: credentials
                .into_iter()
                .map(|c| (c.id.clone(), Arc::new(c)))
                .collect(),
            revoked_grants: revoked_grants.into_iter().collect(),
        };
        *self.0.write().unwrap_or_else(|e| e.into_inner()) = snapshot;
    }

    pub fn upsert_instance(&self, instance: Instance) {
        let mut s = self.0.write().unwrap_or_else(|e| e.into_inner());
        s.instances.insert(instance.id.clone(), Arc::new(instance));
    }

    pub fn revoke_grant(&self, grant: &str) {
        let mut s = self.0.write().unwrap_or_else(|e| e.into_inner());
        s.revoked_grants.insert(grant.to_owned());
    }
}

impl Directory for MemoryDirectory {
    fn instance(&self, id: &str) -> Option<Arc<Instance>> {
        self.0
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .instances
            .get(id)
            .cloned()
    }

    fn credential(&self, id: &str) -> Option<Arc<Credential>> {
        self.0
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .credentials
            .get(id)
            .cloned()
    }

    fn grant_revoked(&self, grant: &str) -> bool {
        self.0
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .revoked_grants
            .contains(grant)
    }
}

/// 本地开发用的单文件存储：路由数据加上包裹后的用户 DEK。
#[derive(Debug, Default, Serialize, Deserialize)]
pub struct DevStore {
    /// 本地 KMS 主密钥的 id，主密钥本身从环境变量读取。
    #[serde(default = "dev_kms_key_id")]
    pub kms_key_id: String,
    #[serde(default)]
    pub user_keys: BTreeMap<String, WrappedKey>,
    #[serde(default)]
    pub credentials: Vec<Credential>,
    #[serde(default)]
    pub instances: Vec<Instance>,
    #[serde(default)]
    pub revoked_grants: Vec<String>,
}

fn dev_kms_key_id() -> String {
    "dev".into()
}

impl DevStore {
    pub fn load(path: &Path) -> anyhow::Result<Self> {
        if !path.exists() {
            return Ok(Self {
                kms_key_id: dev_kms_key_id(),
                ..Self::default()
            });
        }
        let text =
            std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
        serde_json::from_str(&text).with_context(|| format!("parse {}", path.display()))
    }

    /// 先写临时文件再改名，避免写一半留下坏文件。
    pub fn save(&self, path: &Path) -> anyhow::Result<()> {
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(self)?)?;
        std::fs::rename(&tmp, path)?;
        Ok(())
    }

    pub fn upsert_credential(&mut self, cred: Credential) {
        self.credentials.retain(|c| c.id != cred.id);
        self.credentials.push(cred);
    }

    pub fn directory(&self) -> MemoryDirectory {
        MemoryDirectory::new(
            self.instances.clone(),
            self.credentials.clone(),
            self.revoked_grants.clone(),
        )
    }
}
