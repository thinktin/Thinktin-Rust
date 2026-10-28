//! 阿里云 ACS 智能体沙箱后端：按 OpenKruise Agents（ACS 的 ack-sandbox-manager 组件）的
//! E2B 兼容私有协议实现 [`SandboxProvider`]。接口和实测要点见 docs/sandbox-acs.md。
//!
//! - 控制面：`<api_url>/sandboxes`（`api_url` 一般是 `http://<域名>/kruise/api`），带 `X-API-KEY`；
//! - 数据面：沙箱里的 envd（客户端在 `envd.rs`），经 sandbox-manager 按路径路由：
//!   `<data_url>/kruise/<沙箱 id>/49983/<路径>`。
//!
//! 和 Cube 后端不同的地方：
//! - 没有卷：工作区在沙箱自己的磁盘上，暂停时保留，销毁就没了
//!   （[`SandboxProvider::workspace_persists`] 是 false），要靠控制服务把工作区存到对象存储；
//! - 不支持快照；envd 没有 CloseStdin，`/files` 只收 multipart；
//! - 模板是 SandboxSet 的名字，必须是 Kubernetes 的名字：按 `templates` 映射，没配就把模板 id
//!   规整成合法名字（[`sandboxset_name`]）；
//! - 不按空闲回收：创建时带 never-timeout 扩展，暂停、归档由控制服务的巡检决定；
//! - 每个沙箱是一个 Pod，有自己的 IP。创建时要 sandbox-manager 返回 Pod IP，[`SandboxInfo::address`]
//!   就是它，沙箱令牌绑到单个沙箱。拿不到 IP 就当创建失败（不退回到不绑定）。

use std::collections::{BTreeMap, HashMap};
use std::net::IpAddr;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use bytes::Bytes;
use reqwest::{Method, StatusCode};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::envd::{self, Envd, Route, Upload, api_error, parse, provider_err};
use crate::{
    CreateSpec, Error, ExecSpec, Process, Result, SandboxId, SandboxInfo, SandboxProvider,
    SandboxState, SnapshotId, check_relative_path,
};

/// 控制面的鉴权头。
const API_KEY_HEADER: &str = "X-API-KEY";
/// 创建时的 `timeout`：sandbox-manager 要求 30 秒到 30 天之间（不填是 300）。带了 never-timeout
/// 扩展就不按它回收，这里只是满足校验。
const CREATE_TIMEOUT_SECS: u32 = 300;
/// connect 的 `timeout`：必须大于 0；never-timeout 的沙箱不会据此改超时。
const CONNECT_TIMEOUT_SECS: u32 = 300;
/// 扩展参数放在 metadata 里，sandbox-manager 解析后从 metadata 里删掉。
const EXT_NEVER_TIMEOUT: &str = "e2b.agents.kruise.io/never-timeout";
const EXT_RETURN_IP: &str = "e2b.agents.kruise.io/return-sandbox-ip";
/// 要了 Pod IP 时 sandbox-manager 在响应的 metadata 里放这个键（写在存储的 metadata 之后，伪造不了）。
const META_POD_IP: &str = "e2b.agents.kruise.io/sandbox-ip";
/// sandbox-manager 保留的 metadata 前缀：调用方不能设，响应里的不对外显示。
const RESERVED_PREFIXES: [&str; 2] = ["e2b.agents.kruise.io/", "agents.kruise.io/"];
/// 元数据里记原始模板和工作区（和 Cube 后端一样）。
const META_TEMPLATE: &str = "thinktin_template";
const META_WORKSPACE: &str = "thinktin_workspace";
/// 沙箱正在暂停、恢复时重试几次、隔多久。
const LIFECYCLE_RETRIES: u32 = 5;
const LIFECYCLE_RETRY_DELAY: Duration = Duration::from_secs(2);
/// 等 Pod IP 时多久查一次。
const IP_POLL: Duration = Duration::from_millis(500);

#[derive(Clone)]
pub struct AcsConfig {
    /// 控制面地址，如 `http://sandbox.example.internal/kruise/api`。
    pub api_url: String,
    /// 数据面地址，不填就是 `api_url` 去掉末尾的 `/kruise/api`。
    pub data_url: Option<String>,
    /// sandbox-manager 的 API Key（`X-API-KEY`）。
    pub api_key: Option<String>,
    /// 沙箱里的根目录。
    pub root: String,
    /// 进程以哪个用户运行（envd 的 Basic 认证用户名）。
    pub user: String,
    /// 模板 id → SandboxSet 名字。没列的按 [`sandboxset_name`] 规整。
    pub templates: BTreeMap<String, String>,
    /// 创建后等 Pod IP 最多多久。
    pub ip_wait: Duration,
    /// 控制面请求的超时（创建要等 Pod 就绪）。
    pub request_timeout: Duration,
}

impl Default for AcsConfig {
    fn default() -> Self {
        Self {
            api_url: "http://127.0.0.1/kruise/api".into(),
            data_url: None,
            api_key: None,
            root: "/sandbox".into(),
            user: "user".into(),
            templates: BTreeMap::new(),
            ip_wait: Duration::from_secs(15),
            request_timeout: Duration::from_secs(120),
        }
    }
}

impl std::fmt::Debug for AcsConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AcsConfig")
            .field("api_url", &self.api_url)
            .field("data_url", &self.data_url)
            .field("api_key", &self.api_key.is_some())
            .field("root", &self.root)
            .field("user", &self.user)
            .field("templates", &self.templates)
            .field("ip_wait", &self.ip_wait)
            .field("request_timeout", &self.request_timeout)
            .finish()
    }
}

impl AcsConfig {
    fn data_base(&self) -> String {
        match &self.data_url {
            Some(u) => u.trim_end_matches('/').to_owned(),
            None => {
                let api = self.api_url.trim_end_matches('/');
                api.strip_suffix("/kruise/api").unwrap_or(api).to_owned()
            }
        }
    }
}

/// 模板 id → 合法的 Kubernetes 名字（SandboxSet 名）：小写，别的字符换成 `-`，合并、去掉首尾的 `-`，
/// 最多 63 个字符。`agents/claude:0.90.0` → `agents-claude-0-90-0`。
pub fn sandboxset_name(template: &str) -> String {
    let mut out = String::with_capacity(template.len());
    for c in template.chars() {
        let c = c.to_ascii_lowercase();
        if c.is_ascii_lowercase() || c.is_ascii_digit() {
            out.push(c);
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    let mut name = out.trim_matches('-').to_owned();
    name.truncate(63);
    name.trim_end_matches('-').to_owned()
}

/// 出网规则能不能交给 sandbox-manager：和它的校验一样，只认 IP、CIDR 或域名（小写，
/// `^([a-z0-9-]+\.)+[a-z]{2,}$`）。不能带端口（它不分端口，带了端口看着像只放行那个端口，其实整台机器
/// 都放行了），不能用通配符、协议头、单段的主机名；不认的建沙箱时会被拒（400），启动时就挡下来。
pub fn allow_rule_ok(target: &str) -> bool {
    let t = target.trim();
    if t.parse::<IpAddr>().is_ok() {
        return true;
    }
    if let Some((ip, bits)) = t.split_once('/') {
        let Ok(ip) = ip.parse::<IpAddr>() else {
            return false;
        };
        let max = if ip.is_ipv4() { 32 } else { 128 };
        return !bits.is_empty()
            && bits.len() <= 3
            && bits.bytes().all(|b| b.is_ascii_digit())
            && bits.parse::<u8>().is_ok_and(|b| b <= max);
    }
    let Some((labels, tld)) = t.rsplit_once('.') else {
        return false;
    };
    tld.len() >= 2
        && tld.bytes().all(|b| b.is_ascii_lowercase())
        && labels.split('.').all(|l| {
            !l.is_empty()
                && l.bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        })
}

fn reserved(key: &str) -> bool {
    RESERVED_PREFIXES.iter().any(|p| key.starts_with(p))
}

#[derive(Deserialize)]
struct Sandbox {
    #[serde(rename = "sandboxID")]
    sandbox_id: String,
    #[serde(rename = "templateID", default)]
    template_id: String,
    #[serde(rename = "envdAccessToken", default)]
    envd_access_token: Option<String>,
    #[serde(default)]
    state: Option<String>,
    #[serde(default)]
    metadata: Option<BTreeMap<String, String>>,
}

impl Sandbox {
    fn pod_ip(&self) -> Option<IpAddr> {
        self.metadata
            .as_ref()?
            .get(META_POD_IP)?
            .trim()
            .parse::<IpAddr>()
            .ok()
            .map(|ip| ip.to_canonical())
    }
}

pub struct AcsProvider {
    cfg: AcsConfig,
    data_base: String,
    api: reqwest::Client,
    data: reqwest::Client,
    /// 运行中沙箱的 envd 令牌。
    tokens: Mutex<HashMap<String, Option<String>>>,
}

impl AcsProvider {
    pub fn new(cfg: AcsConfig) -> Result<Self> {
        let api = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(cfg.request_timeout)
            .build()
            .map_err(provider_err)?;
        // 进程的输出流可能持续几个小时，不设总超时；小请求各自设超时。
        let data = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .build()
            .map_err(provider_err)?;
        Ok(Self {
            data_base: cfg.data_base(),
            cfg,
            api,
            data,
            tokens: Mutex::default(),
        })
    }

    /// 沙箱里的绝对路径。
    fn abs(&self, rel: &str) -> String {
        format!("{}/{rel}", self.cfg.root.trim_end_matches('/'))
    }

    fn api(&self, method: Method, path: &str) -> reqwest::RequestBuilder {
        let rb = self.api.request(
            method,
            format!("{}{path}", self.cfg.api_url.trim_end_matches('/')),
        );
        match &self.cfg.api_key {
            Some(key) => rb.header(API_KEY_HEADER, key),
            None => rb,
        }
    }

    async fn call(&self, rb: reqwest::RequestBuilder) -> Result<(StatusCode, Bytes)> {
        let resp = rb.send().await.map_err(provider_err)?;
        let status = resp.status();
        let bytes = resp.bytes().await.map_err(provider_err)?;
        Ok((status, bytes))
    }

    fn tokens(&self) -> std::sync::MutexGuard<'_, HashMap<String, Option<String>>> {
        self.tokens.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn remember(&self, s: &Sandbox) {
        let token = s.envd_access_token.clone().filter(|t| !t.is_empty());
        self.tokens().insert(s.sandbox_id.clone(), token);
    }

    fn forget(&self, id: &str) {
        self.tokens().remove(id);
    }

    fn envd(&self, id: &SandboxId, envd_token: Option<String>) -> Envd {
        Envd {
            http: self.data.clone(),
            route: Route::KruisePath {
                base: self.data_base.clone(),
            },
            user: self.cfg.user.clone(),
            sandbox_id: id.0.clone(),
            envd_token,
            traffic_token: None,
            upload: Upload::MultipartOnly,
        }
    }

    async fn detail(&self, id: &SandboxId) -> Result<Option<Sandbox>> {
        let (status, bytes) = self
            .call(self.api(Method::GET, &format!("/sandboxes/{}", id.0)))
            .await?;
        if status == StatusCode::NOT_FOUND {
            return Ok(None);
        }
        if !status.is_success() {
            return Err(api_error("get sandbox", status, &bytes));
        }
        Ok(Some(parse("get sandbox", &bytes)?))
    }

    fn state(id: &SandboxId, s: &Sandbox) -> Result<SandboxState> {
        match s.state.as_deref() {
            Some("running") => Ok(SandboxState::Running),
            Some("paused") => Ok(SandboxState::Paused),
            other => Err(Error::Provider(format!(
                "sandbox {id} is in an unexpected state {other:?}"
            ))),
        }
    }

    fn info(&self, id: &SandboxId, s: Sandbox) -> Result<SandboxInfo> {
        let state = Self::state(id, &s)?;
        let address = s.pod_ip();
        let mut metadata = s.metadata.unwrap_or_default();
        metadata.retain(|k, _| !reserved(k));
        let template = metadata.remove(META_TEMPLATE).unwrap_or(s.template_id);
        let workspace = metadata.remove(META_WORKSPACE);
        Ok(SandboxInfo {
            id: SandboxId(s.sandbox_id),
            template,
            workspace,
            state,
            address,
            metadata,
        })
    }

    /// 运行中沙箱的数据面连接。控制服务重启后缓存是空的：查一次，运行中的响应里就有令牌。
    async fn running_envd(&self, id: &SandboxId) -> Result<Envd> {
        let cached = self.tokens().get(&id.0).cloned();
        if let Some(token) = cached {
            return Ok(self.envd(id, token));
        }
        let s = self
            .detail(id)
            .await?
            .ok_or_else(|| Error::NotFound(id.clone()))?;
        match s.state.as_deref() {
            Some("running") => {}
            Some("paused") => {
                return Err(Error::InvalidState {
                    id: id.clone(),
                    expected: SandboxState::Running,
                    actual: SandboxState::Paused,
                });
            }
            _ => return Err(Error::NotFound(id.clone())),
        }
        self.remember(&s);
        Ok(self.envd(id, s.envd_access_token.filter(|t| !t.is_empty())))
    }

    fn create_body(&self, spec: &CreateSpec) -> Result<Value> {
        if let Some(bad) = spec.network.allow.iter().find(|t| !allow_rule_ok(t)) {
            return Err(Error::Invalid(format!(
                "ACS egress rules take an IP, CIDR or host name without a port or wildcard: {bad:?}"
            )));
        }
        if let Some(bad) = spec.metadata.keys().find(|k| reserved(k)) {
            return Err(Error::Invalid(format!("reserved metadata key {bad:?}")));
        }
        let template = self
            .cfg
            .templates
            .get(&spec.template)
            .cloned()
            .unwrap_or_else(|| sandboxset_name(&spec.template));
        if template.is_empty() {
            return Err(Error::Invalid(format!("bad template {:?}", spec.template)));
        }
        let mut metadata = spec.metadata.clone();
        metadata.insert(META_TEMPLATE.into(), spec.template.clone());
        if let Some(ws) = &spec.workspace {
            metadata.insert(META_WORKSPACE.into(), ws.clone());
        }
        metadata.insert(EXT_NEVER_TIMEOUT.into(), "true".into());
        metadata.insert(EXT_RETURN_IP.into(), "true".into());
        let hosts: Vec<&str> = spec.network.allow.iter().map(|t| t.trim()).collect();
        let mut body = json!({
            "templateID": template,
            "timeout": CREATE_TIMEOUT_SECS,
            // 默认拒绝全部出网，只放行白名单（通常只有模型网关）。
            "allow_internet_access": false,
            "metadata": metadata,
        });
        if !hosts.is_empty() {
            body["network"] = json!({ "allowOut": hosts });
        }
        Ok(body)
    }

    /// 创建响应里没带 IP 时（Pod 刚就绪）再查几次。
    async fn wait_for_ip(&self, id: &SandboxId) -> Result<Option<IpAddr>> {
        let deadline = Instant::now() + self.cfg.ip_wait;
        loop {
            if let Some(ip) = self.detail(id).await?.and_then(|s| s.pod_ip()) {
                return Ok(Some(ip));
            }
            if Instant::now() + IP_POLL > deadline {
                return Ok(None);
            }
            tokio::time::sleep(IP_POLL).await;
        }
    }
}

#[async_trait]
impl SandboxProvider for AcsProvider {
    fn name(&self) -> &'static str {
        "acs"
    }

    fn workspace_persists(&self) -> bool {
        false
    }

    async fn create(&self, spec: CreateSpec) -> Result<SandboxInfo> {
        if spec.template.is_empty() {
            return Err(Error::Invalid("template is required".into()));
        }
        let body = self.create_body(&spec)?;
        let (status, bytes) = self
            .call(self.api(Method::POST, "/sandboxes").json(&body))
            .await?;
        if !status.is_success() {
            return Err(api_error("create sandbox", status, &bytes));
        }
        let created: Sandbox = parse("create sandbox", &bytes)?;
        let id = SandboxId(created.sandbox_id.clone());
        self.remember(&created);
        let ip = match created.pod_ip() {
            Some(ip) => Ok(Some(ip)),
            None => self.wait_for_ip(&id).await,
        };
        let address = match ip {
            Ok(Some(ip)) => ip,
            res => {
                // 令牌绑不到这个沙箱：不用它。删不掉时控制服务那边看不到这个 id，只能记日志。
                if let Err(e) = self.destroy(&id).await {
                    tracing::warn!(sandbox = %id, error = %e, "could not destroy a sandbox without an IP");
                }
                return Err(res.err().unwrap_or_else(|| {
                    Error::Provider(format!(
                        "sandbox-manager did not report the IP of sandbox {id} (needs {EXT_RETURN_IP})"
                    ))
                }));
            }
        };
        Ok(SandboxInfo {
            id,
            template: spec.template,
            workspace: spec.workspace,
            state: SandboxState::Running,
            address: Some(address),
            metadata: spec.metadata,
        })
    }

    async fn get(&self, id: &SandboxId) -> Result<Option<SandboxInfo>> {
        let Some(s) = self.detail(id).await? else {
            return Ok(None);
        };
        if s.state.as_deref() == Some("dead") {
            // 到了关机时间之类：用不了了。删掉，免得控制服务重建后留下一个。
            self.destroy(id).await?;
            return Ok(None);
        }
        Ok(Some(self.info(id, s)?))
    }

    async fn exec(&self, id: &SandboxId, spec: ExecSpec) -> Result<Process> {
        let request = envd::start_request(&self.cfg.root, &spec)?;
        self.running_envd(id).await?.start(request).await
    }

    async fn pause(&self, id: &SandboxId) -> Result<()> {
        // 暂停后数据面不可用；下次用时重新确认状态、取令牌。
        self.forget(&id.0);
        let (status, bytes) = self
            .call(self.api(Method::POST, &format!("/sandboxes/{}/pause", id.0)))
            .await?;
        if status.is_success() {
            return Ok(());
        }
        if status == StatusCode::NOT_FOUND {
            return Err(Error::NotFound(id.clone()));
        }
        if status == StatusCode::CONFLICT {
            // 已经暂停或正在暂停。
            return match self.detail(id).await? {
                Some(s) if s.state.as_deref() == Some("paused") => Ok(()),
                Some(_) => Err(api_error("pause sandbox", status, &bytes)),
                None => Err(Error::NotFound(id.clone())),
            };
        }
        Err(api_error("pause sandbox", status, &bytes))
    }

    async fn resume(&self, id: &SandboxId) -> Result<SandboxInfo> {
        let body = json!({ "timeout": CONNECT_TIMEOUT_SECS });
        let mut attempt = 0;
        loop {
            let (status, bytes) = self
                .call(
                    self.api(Method::POST, &format!("/sandboxes/{}/connect", id.0))
                        .json(&body),
                )
                .await?;
            // connect 只认运行中、暂停的沙箱：Pod 起来了但还没就绪时它也报 404，查一下确实没了才算没了，
            // 不然控制服务会另建一个、把这个连同里面的文件丢下不管。
            let not_ready = status == StatusCode::NOT_FOUND
                && match self.detail(id).await? {
                    None => return Err(Error::NotFound(id.clone())),
                    Some(_) => true,
                };
            // 正在暂停之类的生命周期操作进行中（恢复撞上冲突时 sandbox-manager 报 400）：稍后再试。
            let busy = not_ready
                || status == StatusCode::CONFLICT
                || status == StatusCode::SERVICE_UNAVAILABLE
                || (status == StatusCode::BAD_REQUEST
                    && String::from_utf8_lossy(&bytes).contains("Failed to resume"));
            if busy && attempt < LIFECYCLE_RETRIES {
                attempt += 1;
                tokio::time::sleep(LIFECYCLE_RETRY_DELAY).await;
                continue;
            }
            if !status.is_success() {
                return Err(api_error("connect sandbox", status, &bytes));
            }
            break;
        }
        // 恢复后 Pod IP 可能变了：以恢复后查到的为准，不沿用旧的。
        let s = self
            .detail(id)
            .await?
            .ok_or_else(|| Error::NotFound(id.clone()))?;
        if s.pod_ip().is_none() {
            return Err(Error::Provider(format!(
                "sandbox-manager did not report the IP of sandbox {id} after resume"
            )));
        }
        self.remember(&s);
        let mut info = self.info(id, s)?;
        info.state = SandboxState::Running;
        Ok(info)
    }

    async fn snapshot(&self, _id: &SandboxId) -> Result<SnapshotId> {
        Err(Error::Provider("snapshots are not supported on ACS".into()))
    }

    async fn restore(&self, _snapshot: &SnapshotId, _spec: CreateSpec) -> Result<SandboxInfo> {
        Err(Error::Provider("snapshots are not supported on ACS".into()))
    }

    async fn destroy(&self, id: &SandboxId) -> Result<()> {
        self.forget(&id.0);
        let mut attempt = 0;
        loop {
            let resp = self
                .api(Method::DELETE, &format!("/sandboxes/{}", id.0))
                .send()
                .await
                .map_err(provider_err)?;
            let status = resp.status();
            let retry_after = resp
                .headers()
                .get("retry-after")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.trim().parse::<u64>().ok());
            let bytes = resp.bytes().await.map_err(provider_err)?;
            if status.is_success() || status == StatusCode::NOT_FOUND {
                return Ok(());
            }
            if (status == StatusCode::SERVICE_UNAVAILABLE || status == StatusCode::CONFLICT)
                && attempt < LIFECYCLE_RETRIES
            {
                attempt += 1;
                let wait = retry_after
                    .map(|s| Duration::from_secs(s.clamp(1, 10)))
                    .unwrap_or(LIFECYCLE_RETRY_DELAY);
                tokio::time::sleep(wait).await;
                continue;
            }
            return Err(api_error("delete sandbox", status, &bytes));
        }
    }

    async fn delete_workspace(&self, _workspace: &str) -> Result<()> {
        // 没有卷：工作区随沙箱删掉，对象存储里的归档由控制服务删。
        Ok(())
    }

    async fn write_file(&self, id: &SandboxId, path: &str, data: &[u8]) -> Result<()> {
        check_relative_path(path)?;
        let envd = self.running_envd(id).await?;
        envd.write(&self.abs(path), data).await
    }

    async fn write_file_stream(
        &self,
        id: &SandboxId,
        path: &str,
        data: Box<dyn tokio::io::AsyncRead + Send + Unpin>,
        len: u64,
    ) -> Result<()> {
        check_relative_path(path)?;
        let envd = self.running_envd(id).await?;
        envd.write_stream(&self.abs(path), data, len).await
    }

    async fn read_file(&self, id: &SandboxId, path: &str, max: u64) -> Result<Vec<u8>> {
        check_relative_path(path)?;
        let envd = self.running_envd(id).await?;
        envd.read(&self.abs(path), path, max).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn template_ids_become_kubernetes_names() {
        assert_eq!(
            sandboxset_name("agents/claude:0.90.0"),
            "agents-claude-0-90-0"
        );
        assert_eq!(sandboxset_name("--A__b--"), "a-b");
        assert_eq!(sandboxset_name("模板"), "");
        let long = sandboxset_name(&format!("{}-x", "a".repeat(62)));
        assert_eq!(long, "a".repeat(62));
    }

    #[test]
    fn data_url_defaults_to_the_api_host() {
        let cfg = AcsConfig {
            api_url: "http://sbx.internal/kruise/api/".into(),
            ..AcsConfig::default()
        };
        assert_eq!(cfg.data_base(), "http://sbx.internal");
        let cfg = AcsConfig {
            data_url: Some("http://10.0.0.7/".into()),
            ..cfg
        };
        assert_eq!(cfg.data_base(), "http://10.0.0.7");
    }

    #[test]
    fn egress_rules_match_what_sandbox_manager_takes() {
        for ok in [
            "10.0.1.10",
            "10.0.0.0/8",
            "10.0.1.10/32",
            "2001:db8::1",
            "2001:db8::/32",
            "gw.internal",
            "oss-ap-northeast-1-internal.aliyuncs.com",
            " 10.0.1.10 ",
        ] {
            assert!(allow_rule_ok(ok), "{ok}");
        }
        for bad in [
            "",
            "http://10.0.1.10:8790",
            "10.0.1.10:8790",
            "gw.internal:8790",
            "[2001:db8::1]:443",
            "llm-gw",
            "10.0.1.10/33",
            "10.0.0.0/",
            "10.0.0.0/+8",
            "2001:db8::/129",
            "gw_1.internal",
            "*.example.com",
            "GW.internal",
            "gw..internal",
            "gw.internal.",
            "gw.x1",
        ] {
            assert!(!allow_rule_ok(bad), "{bad}");
        }
    }

    #[test]
    fn debug_hides_the_key() {
        let cfg = AcsConfig {
            api_key: Some("e2b_secret".into()),
            ..AcsConfig::default()
        };
        assert!(!format!("{cfg:?}").contains("e2b_secret"));
    }
}
