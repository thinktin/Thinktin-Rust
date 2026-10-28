//! CubeSandbox 后端（WBS 6.2）：按 Cube 的 E2B 兼容接口实现 [`SandboxProvider`]。
//!
//! - 控制面：CubeAPI（`/sandboxes`、`/volumes`），开了鉴权时带 `Authorization: Bearer`；
//! - 数据面：沙箱里的 envd（端口 49983，客户端在 `envd.rs`，和 ACS 后端共用），经 CubeProxy
//!   按 `49983-<沙箱 id>.<域名>` 路由。
//!
//! 沙箱里的目录约定（模板负责建好，见 docs/sandbox-cube.md）：`<root>/home` 是 HOME，
//! `<root>/workspace` 挂工作区卷；进程以 `user` 运行。trait 里的相对路径都相对 `<root>`。
//!
//! 两处和本地后端不同：
//! - Cube 按模板分配 CPU、内存，[`CreateSpec::resources`] 由模板决定，这里不传；
//! - 沙箱出网经节点 SNAT，模型网关看不到单个沙箱的地址，[`SandboxInfo::address`] 用配置的
//!   `egress_address`（节点出网地址或 NAT 地址），沙箱令牌只能绑到这一级。

use std::collections::{BTreeMap, HashMap};
use std::net::IpAddr;
use std::sync::Mutex;
use std::time::Duration;

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

pub use crate::envd::ENVD_PORT;

/// 沙箱正在暂停、恢复时（409、503）重试几次、隔多久。
const LIFECYCLE_RETRIES: u32 = 5;
const LIFECYCLE_RETRY_DELAY: Duration = Duration::from_secs(2);
/// 元数据里记原始模板和工作区：从快照恢复的沙箱，Cube 返回的模板 id 是快照 id。
const META_TEMPLATE: &str = "thinktin_template";
const META_WORKSPACE: &str = "thinktin_workspace";

#[derive(Clone)]
pub struct CubeConfig {
    /// CubeAPI 地址（E2B SDK 的 `E2B_API_URL`），如 `http://cube-api:3000`。
    pub api_url: String,
    /// CubeAPI 开了鉴权时的 key（`Authorization: Bearer`）。
    pub api_key: Option<String>,
    /// 沙箱域名。Cube 在创建、连接的响应里会返回，这里只是兜底。
    pub domain: Option<String>,
    /// 直接连 CubeProxy 的地址（如 `http://10.0.0.5`），按 Host 头路由；不填就按
    /// `<data_scheme>://49983-<沙箱 id>.<域名>` 解析（需要泛域名 DNS）。
    pub proxy_url: Option<String>,
    /// 不用 `proxy_url` 时数据面的 scheme。
    pub data_scheme: String,
    /// 沙箱里的根目录。
    pub root: String,
    /// 进程以哪个用户运行（envd 的 Basic 认证用户名）。
    pub user: String,
    /// 模型网关看到的沙箱来源地址（节点出网地址或 NAT 地址）。
    pub egress_address: Option<IpAddr>,
    /// 工作区放在 Cube 卷上（卷插件要先在 CubeMaster 里配好）。关掉时工作区在沙箱自己的磁盘上，
    /// 只随暂停和快照保留，重建沙箱会丢。
    pub use_volumes: bool,
    /// 卷插件名，不填用 CubeMaster 的默认插件。
    pub volume_driver: Option<String>,
    /// 控制面请求的超时（创建、暂停要做快照，可能要几十秒）。
    pub request_timeout: Duration,
}

impl Default for CubeConfig {
    fn default() -> Self {
        Self {
            api_url: "http://127.0.0.1:3000".into(),
            api_key: None,
            domain: None,
            proxy_url: None,
            data_scheme: "https".into(),
            root: "/sandbox".into(),
            user: "user".into(),
            egress_address: None,
            use_volumes: true,
            volume_driver: None,
            request_timeout: Duration::from_secs(120),
        }
    }
}

impl std::fmt::Debug for CubeConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CubeConfig")
            .field("api_url", &self.api_url)
            .field("api_key", &self.api_key.is_some())
            .field("domain", &self.domain)
            .field("proxy_url", &self.proxy_url)
            .field("data_scheme", &self.data_scheme)
            .field("root", &self.root)
            .field("user", &self.user)
            .field("egress_address", &self.egress_address)
            .field("use_volumes", &self.use_volumes)
            .field("volume_driver", &self.volume_driver)
            .field("request_timeout", &self.request_timeout)
            .finish()
    }
}

/// 一个沙箱的数据面连接信息（令牌不进日志）。
#[derive(Clone)]
struct Conn {
    id: String,
    domain: String,
    envd_token: Option<String>,
    traffic_token: Option<String>,
}

pub struct CubeProvider {
    cfg: CubeConfig,
    api: reqwest::Client,
    data: reqwest::Client,
    conns: Mutex<HashMap<String, Conn>>,
    /// 工作区名 → Cube 的卷 id。
    volumes: Mutex<HashMap<String, String>>,
}

#[derive(Deserialize)]
struct Created {
    #[serde(rename = "sandboxID")]
    sandbox_id: String,
    #[serde(default)]
    domain: Option<String>,
    #[serde(rename = "envdAccessToken", default)]
    envd_access_token: Option<String>,
    #[serde(rename = "trafficAccessToken", default)]
    traffic_access_token: Option<String>,
}

#[derive(Deserialize)]
struct Detail {
    #[serde(rename = "sandboxID")]
    sandbox_id: String,
    #[serde(rename = "templateID", default)]
    template_id: String,
    #[serde(default)]
    state: Option<String>,
    #[serde(default)]
    metadata: Option<BTreeMap<String, String>>,
}

impl Detail {
    fn running(&self) -> bool {
        self.state.as_deref() == Some("running")
    }
}

#[derive(Deserialize)]
struct VolumeEntry {
    #[serde(rename = "volumeID")]
    volume_id: String,
    #[serde(default)]
    name: String,
}

#[derive(Deserialize)]
struct SnapshotCreated {
    #[serde(rename = "snapshotID")]
    snapshot_id: String,
}

/// `host:port` → `host`：Cube 的出网白名单按地址或域名放行，不分端口。
pub fn allow_host(target: &str) -> &str {
    let t = target.trim();
    if let Some(rest) = t.strip_prefix('[') {
        return rest.split(']').next().unwrap_or(rest);
    }
    match t.rsplit_once(':') {
        Some((host, port))
            if !host.contains(':')
                && !port.is_empty()
                && port.bytes().all(|b| b.is_ascii_digit()) =>
        {
            host
        }
        _ => t,
    }
}

/// Cube 的卷名只能是字母、数字、`-`、`_`。
fn check_volume_name(name: &str) -> Result<()> {
    if name.is_empty()
        || name.len() > 64
        || !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return Err(Error::Invalid(format!("bad workspace name {name:?}")));
    }
    Ok(())
}

impl CubeProvider {
    pub fn new(cfg: CubeConfig) -> Result<Self> {
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
            cfg,
            api,
            data,
            conns: Mutex::default(),
            volumes: Mutex::default(),
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
            Some(key) => rb.bearer_auth(key),
            None => rb,
        }
    }

    async fn call(&self, rb: reqwest::RequestBuilder) -> Result<(StatusCode, Bytes)> {
        let resp = rb.send().await.map_err(provider_err)?;
        let status = resp.status();
        let bytes = resp.bytes().await.map_err(provider_err)?;
        Ok((status, bytes))
    }

    fn conns(&self) -> std::sync::MutexGuard<'_, HashMap<String, Conn>> {
        self.conns.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn volume_ids(&self) -> std::sync::MutexGuard<'_, HashMap<String, String>> {
        self.volumes.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn cached_conn(&self, id: &str) -> Option<Conn> {
        self.conns().get(id).cloned()
    }

    fn forget(&self, id: &str) {
        self.conns().remove(id);
    }

    fn remember(&self, c: Created) {
        let conn = Conn {
            id: c.sandbox_id.clone(),
            domain: c
                .domain
                .filter(|d| !d.is_empty())
                .or_else(|| self.cfg.domain.clone())
                .unwrap_or_else(|| "cube.app".into()),
            envd_token: c.envd_access_token.filter(|t| !t.is_empty()),
            traffic_token: c.traffic_access_token.filter(|t| !t.is_empty()),
        };
        self.conns().insert(c.sandbox_id, conn);
    }

    fn envd(&self, conn: Conn) -> Envd {
        let route = match &self.cfg.proxy_url {
            Some(proxy_url) => Route::HostHeader {
                proxy_url: proxy_url.clone(),
                domain: conn.domain,
            },
            None => Route::Wildcard {
                scheme: self.cfg.data_scheme.clone(),
                domain: conn.domain,
            },
        };
        Envd {
            http: self.data.clone(),
            route,
            user: self.cfg.user.clone(),
            sandbox_id: conn.id,
            envd_token: conn.envd_token,
            traffic_token: conn.traffic_token,
            upload: Upload::OctetStreamThenMultipart,
        }
    }

    async fn detail(&self, id: &SandboxId) -> Result<Option<Detail>> {
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

    fn info(&self, d: Detail) -> SandboxInfo {
        let running = d.running();
        let mut metadata = d.metadata.unwrap_or_default();
        let template = metadata.remove(META_TEMPLATE).unwrap_or(d.template_id);
        let workspace = metadata.remove(META_WORKSPACE);
        SandboxInfo {
            id: SandboxId(d.sandbox_id),
            template,
            workspace,
            // pausing、unknown 都按暂停处理：控制服务会去恢复，恢复是幂等的。
            state: if running {
                SandboxState::Running
            } else {
                SandboxState::Paused
            },
            address: self.cfg.egress_address,
            metadata,
        }
    }

    /// `POST /sandboxes/{id}/connect`：暂停的会恢复，顺便取回数据面的令牌。
    /// `timeout` 为 None 时不改沙箱的空闲超时。
    async fn connect(&self, id: &SandboxId, timeout: Option<i64>) -> Result<()> {
        let body = match timeout {
            Some(t) => json!({ "timeout": t }),
            None => json!({}),
        };
        let mut attempt = 0;
        loop {
            let (status, bytes) = self
                .call(
                    self.api(Method::POST, &format!("/sandboxes/{}/connect", id.0))
                        .json(&body),
                )
                .await?;
            if status == StatusCode::NOT_FOUND {
                return Err(Error::NotFound(id.clone()));
            }
            // 正在暂停之类的生命周期操作进行中：稍后再试。
            if (status == StatusCode::CONFLICT || status == StatusCode::SERVICE_UNAVAILABLE)
                && attempt < LIFECYCLE_RETRIES
            {
                attempt += 1;
                tokio::time::sleep(LIFECYCLE_RETRY_DELAY).await;
                continue;
            }
            if !status.is_success() {
                return Err(api_error("connect sandbox", status, &bytes));
            }
            let created: Created = parse("connect sandbox", &bytes)?;
            self.remember(created);
            return Ok(());
        }
    }

    /// 运行中沙箱的数据面连接。控制服务重启后缓存是空的：先确认在运行，再用 connect 取令牌
    /// （不改超时，运行中的沙箱不受影响）。
    async fn running_conn(&self, id: &SandboxId) -> Result<Conn> {
        if let Some(c) = self.cached_conn(&id.0) {
            return Ok(c);
        }
        let detail = self
            .detail(id)
            .await?
            .ok_or_else(|| Error::NotFound(id.clone()))?;
        if !detail.running() {
            return Err(Error::InvalidState {
                id: id.clone(),
                expected: SandboxState::Running,
                actual: SandboxState::Paused,
            });
        }
        self.connect(id, None).await?;
        self.cached_conn(&id.0)
            .ok_or_else(|| Error::Provider(format!("no connection info for sandbox {id}")))
    }

    async fn find_volume(&self, name: &str) -> Result<Option<String>> {
        let cached = self.volume_ids().get(name).cloned();
        if let Some(id) = cached {
            return Ok(Some(id));
        }
        let (status, bytes) = self.call(self.api(Method::GET, "/volumes")).await?;
        if !status.is_success() {
            return Err(api_error("list volumes", status, &bytes));
        }
        let list: Vec<VolumeEntry> = parse("list volumes", &bytes)?;
        let found = list
            .into_iter()
            .find(|v| v.name == name)
            .map(|v| v.volume_id);
        if let Some(id) = &found {
            self.volume_ids().insert(name.to_owned(), id.clone());
        }
        Ok(found)
    }

    async fn ensure_volume(&self, name: &str) -> Result<String> {
        check_volume_name(name)?;
        if let Some(id) = self.find_volume(name).await? {
            return Ok(id);
        }
        let mut body = json!({ "name": name });
        if let Some(driver) = &self.cfg.volume_driver {
            body["driver"] = json!(driver);
        }
        let (status, bytes) = self
            .call(self.api(Method::POST, "/volumes").json(&body))
            .await?;
        if status.is_success() {
            let v: VolumeEntry = parse("create volume", &bytes)?;
            self.volume_ids()
                .insert(name.to_owned(), v.volume_id.clone());
            return Ok(v.volume_id);
        }
        // 并发创建时别的副本可能已经建好了。
        if let Some(id) = self.find_volume(name).await? {
            return Ok(id);
        }
        Err(api_error("create volume", status, &bytes))
    }

    async fn sandbox_body(&self, template_id: &str, spec: &CreateSpec) -> Result<Value> {
        let mut metadata = spec.metadata.clone();
        metadata.insert(META_TEMPLATE.into(), spec.template.clone());
        if let Some(ws) = &spec.workspace {
            metadata.insert(META_WORKSPACE.into(), ws.clone());
        }
        let hosts: Vec<&str> = spec
            .network
            .allow
            .iter()
            .map(|t| allow_host(t))
            .filter(|h| !h.is_empty())
            .collect();
        let mut network = json!({ "allowPublicTraffic": false });
        if !hosts.is_empty() {
            network["allowOut"] = json!(hosts);
        }
        let mut body = json!({
            "templateID": template_id,
            // 不按空闲时间回收：暂停、归档由控制服务的巡检决定。
            "timeout": -1,
            "secure": true,
            // 默认拒绝全部出网，只放行白名单（通常只有模型网关）。
            "allow_internet_access": false,
            "network": network,
            "metadata": metadata,
        });
        if self.cfg.use_volumes
            && let Some(ws) = &spec.workspace
        {
            let volume = self.ensure_volume(ws).await?;
            body["volumeMounts"] = json!([{ "name": volume, "path": self.abs("workspace") }]);
        }
        Ok(body)
    }

    async fn create_from(
        &self,
        template_id: &str,
        spec: CreateSpec,
        missing: Error,
    ) -> Result<SandboxInfo> {
        let body = self.sandbox_body(template_id, &spec).await?;
        let (status, bytes) = self
            .call(self.api(Method::POST, "/sandboxes").json(&body))
            .await?;
        if status == StatusCode::NOT_FOUND {
            return Err(missing);
        }
        if !status.is_success() {
            return Err(api_error("create sandbox", status, &bytes));
        }
        let created: Created = parse("create sandbox", &bytes)?;
        let id = SandboxId(created.sandbox_id.clone());
        self.remember(created);
        Ok(SandboxInfo {
            id,
            template: spec.template,
            workspace: spec.workspace,
            state: SandboxState::Running,
            address: self.cfg.egress_address,
            metadata: spec.metadata,
        })
    }
}

#[async_trait]
impl SandboxProvider for CubeProvider {
    fn name(&self) -> &'static str {
        "cube"
    }

    async fn create(&self, spec: CreateSpec) -> Result<SandboxInfo> {
        if spec.template.is_empty() {
            return Err(Error::Invalid("template is required".into()));
        }
        let missing = Error::Invalid(format!("template {:?} not found", spec.template));
        let template = spec.template.clone();
        self.create_from(&template, spec, missing).await
    }

    async fn get(&self, id: &SandboxId) -> Result<Option<SandboxInfo>> {
        Ok(self.detail(id).await?.map(|d| self.info(d)))
    }

    async fn exec(&self, id: &SandboxId, spec: ExecSpec) -> Result<Process> {
        let request = envd::start_request(&self.cfg.root, &spec)?;
        self.envd(self.running_conn(id).await?).start(request).await
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
            // 已经暂停（或正在暂停）时 Cube 报 409。
            return match self.detail(id).await? {
                Some(d) if !d.running() => Ok(()),
                Some(_) => Err(api_error("pause sandbox", status, &bytes)),
                None => Err(Error::NotFound(id.clone())),
            };
        }
        Err(api_error("pause sandbox", status, &bytes))
    }

    async fn resume(&self, id: &SandboxId) -> Result<SandboxInfo> {
        self.connect(id, Some(-1)).await?;
        let detail = self
            .detail(id)
            .await?
            .ok_or_else(|| Error::NotFound(id.clone()))?;
        let mut info = self.info(detail);
        info.state = SandboxState::Running;
        Ok(info)
    }

    async fn snapshot(&self, id: &SandboxId) -> Result<SnapshotId> {
        let (status, bytes) = self
            .call(
                self.api(Method::POST, &format!("/sandboxes/{}/snapshots", id.0))
                    .json(&json!({})),
            )
            .await?;
        if status == StatusCode::NOT_FOUND {
            return Err(Error::NotFound(id.clone()));
        }
        if !status.is_success() {
            return Err(api_error("snapshot sandbox", status, &bytes));
        }
        let s: SnapshotCreated = parse("snapshot sandbox", &bytes)?;
        Ok(SnapshotId(s.snapshot_id))
    }

    async fn restore(&self, snapshot: &SnapshotId, spec: CreateSpec) -> Result<SandboxInfo> {
        // 快照 id 可以直接当模板用来建沙箱。
        self.create_from(&snapshot.0, spec, Error::SnapshotNotFound(snapshot.clone()))
            .await
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
            // 正在暂停或别的生命周期操作占着锁：按 Retry-After 再试。
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

    async fn delete_workspace(&self, workspace: &str) -> Result<()> {
        if !self.cfg.use_volumes {
            return Ok(());
        }
        check_volume_name(workspace)?;
        let Some(volume) = self.find_volume(workspace).await? else {
            return Ok(());
        };
        let (status, bytes) = self
            .call(self.api(Method::DELETE, &format!("/volumes/{volume}")))
            .await?;
        self.volume_ids().remove(workspace);
        if status.is_success() || status == StatusCode::NOT_FOUND {
            return Ok(());
        }
        Err(api_error("delete volume", status, &bytes))
    }

    async fn write_file(&self, id: &SandboxId, path: &str, data: &[u8]) -> Result<()> {
        check_relative_path(path)?;
        let envd = self.envd(self.running_conn(id).await?);
        envd.write(&self.abs(path), data).await
    }

    async fn read_file(&self, id: &SandboxId, path: &str, max: u64) -> Result<Vec<u8>> {
        check_relative_path(path)?;
        let envd = self.envd(self.running_conn(id).await?);
        envd.read(&self.abs(path), path, max).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allow_targets_drop_the_port() {
        assert_eq!(allow_host("gw.internal:8790"), "gw.internal");
        assert_eq!(allow_host("10.1.2.3:443"), "10.1.2.3");
        assert_eq!(allow_host("10.1.2.3"), "10.1.2.3");
        assert_eq!(allow_host("*.example.com"), "*.example.com");
        assert_eq!(allow_host("[2001:db8::1]:443"), "2001:db8::1");
        assert_eq!(allow_host("10.0.0.0/8"), "10.0.0.0/8");
    }

    #[test]
    fn workspace_names_follow_cube_rules() {
        assert!(check_volume_name("ws-0123abcd").is_ok());
        for bad in ["", "ws.1", "ws/1", "../x"] {
            assert!(check_volume_name(bad).is_err(), "{bad}");
        }
    }
}
