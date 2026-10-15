//! 接口客户端（WBS 11.2）：带版本头、统一错误模型；访问令牌过期时自动用刷新令牌换新的再重试一次，
//! 并发的请求只刷新一次。刷新令牌失效（被吊销、被重复使用）就清掉会话，返回 [`ClientError::SignedOut`]。
//!
//! 会话（含刷新令牌）交给原生端的 [`SessionStore`] 保存（Keychain / Keystore），这里只在内存里留一份。

use std::sync::{Arc, RwLock};
use std::time::Duration;

use proto::api::{API_VERSION, ErrorBody, ErrorCode, VERSION_HEADER};
use proto::domain::{
    Approval, ApprovalId, Artifact, ArtifactId, Credential, CredentialId, DevicePlatform,
    InboxItem, InboxItemId, Instance, InstanceEvent, InstanceId, ModelRoute, Plan, PlanId,
    PlanStep, PushChannelKind, Run, RunId, ScheduleSpec, Trigger, User,
};
use reqwest::Method;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::error::{ClientError, Result};

/// 登录后的会话。刷新令牌等同于密码，原生端要放进系统的安全存储。
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct Session {
    pub user_id: String,
    pub device_id: String,
    pub access_token: String,
    pub refresh_token: String,
}

impl std::fmt::Debug for Session {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Session")
            .field("user_id", &self.user_id)
            .field("device_id", &self.device_id)
            .finish_non_exhaustive()
    }
}

/// 原生端实现：把会话存进 Keychain / Keystore。`save(None)` 表示退出登录或会话失效，要删掉。
#[uniffi::export(foreign)]
pub trait SessionStore: Send + Sync {
    fn load(&self) -> Option<Session>;
    fn save(&self, session: Option<Session>);
}

/// 只放内存（测试、命令行工具）。
#[derive(Default)]
pub struct MemorySessionStore(RwLock<Option<Session>>);

impl SessionStore for MemorySessionStore {
    fn load(&self) -> Option<Session> {
        self.0.read().unwrap_or_else(|e| e.into_inner()).clone()
    }
    fn save(&self, session: Option<Session>) {
        *self.0.write().unwrap_or_else(|e| e.into_inner()) = session;
    }
}

#[derive(Debug, Clone)]
pub struct ApiConfig {
    /// 比如 `https://api.thinktin.cn`。
    pub base_url: String,
    pub platform: DevicePlatform,
    pub device_name: String,
    pub timeout: Duration,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct LoginResult {
    pub user: User,
    pub new_user: bool,
}

/// 可以领养的 agent。
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct AgentInfo {
    pub id: String,
    pub name: String,
    pub version: String,
    #[serde(default)]
    pub license: Option<String>,
    #[serde(default)]
    pub sites: Vec<String>,
    pub harnesses: Vec<String>,
    pub default_harness: String,
    /// 可以用的版本，当前版本在前。
    #[serde(default)]
    pub versions: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct PlanView {
    #[serde(flatten)]
    pub plan: Plan,
    #[serde(default)]
    pub triggers: Vec<Trigger>,
    #[serde(default)]
    pub steps: Vec<PlanStep>,
}

#[derive(Debug, Clone, Serialize)]
pub struct NewPlan {
    pub instance_id: InstanceId,
    pub title: String,
    pub goal: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub triggers: Vec<ScheduleSpec>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub steps: Vec<PlanStep>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct InboxPage {
    pub items: Vec<InboxItem>,
    pub unread: i64,
}

/// 用量的一组汇总（9.10）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct UsageBucket {
    pub key: String,
    pub requests: u64,
    pub input_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub output_tokens: u64,
    pub charged_tokens: u64,
    pub estimated_requests: u64,
    pub failed_requests: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct UsageSummary {
    pub buckets: Vec<UsageBucket>,
    pub total: UsageBucket,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct EventsPage {
    pub events: Vec<InstanceEvent>,
    pub oldest_seq: Option<u64>,
    pub latest_seq: Option<u64>,
}

#[derive(Clone, Default, Serialize)]
pub struct NewCredential {
    pub vendor: String,
    pub label: String,
    pub api_key: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub anthropic_base: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub openai_base: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub responses_base: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub daily_token_limit: Option<u64>,
}

impl std::fmt::Debug for NewCredential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NewCredential")
            .field("vendor", &self.vendor)
            .field("label", &self.label)
            .finish_non_exhaustive()
    }
}

#[derive(Deserialize)]
struct Tokens {
    access_token: String,
    refresh_token: String,
}

#[derive(Deserialize)]
struct LoginResp {
    user: User,
    new_user: bool,
    device_id: String,
    #[serde(flatten)]
    tokens: Tokens,
}

pub struct Api {
    base: String,
    cfg: ApiConfig,
    http: reqwest::Client,
    store: Arc<dyn SessionStore>,
    session: RwLock<Option<Session>>,
    refreshing: tokio::sync::Mutex<()>,
}

/// 刷新请求本身的结果。
enum Refreshed {
    Ok,
    SignedOut,
}

impl Api {
    pub fn new(cfg: ApiConfig, store: Arc<dyn SessionStore>) -> Result<Self> {
        crate::install_crypto();
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(cfg.timeout)
            .build()
            .map_err(ClientError::network)?;
        let session = store.load();
        Ok(Self {
            base: cfg.base_url.trim_end_matches('/').to_owned(),
            cfg,
            http,
            store,
            session: RwLock::new(session),
            refreshing: tokio::sync::Mutex::new(()),
        })
    }

    pub fn base_url(&self) -> &str {
        &self.base
    }

    pub fn session(&self) -> Option<Session> {
        self.session
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    fn access_token(&self) -> Option<String> {
        self.session().map(|s| s.access_token)
    }

    fn set_session(&self, s: Option<Session>) {
        *self.session.write().unwrap_or_else(|e| e.into_inner()) = s.clone();
        self.store.save(s);
    }

    /// 当前的访问令牌（事件流连 WebSocket 用）。没有登录时返回 [`ClientError::SignedOut`]。
    pub fn bearer(&self) -> Result<String> {
        self.access_token().ok_or(ClientError::SignedOut)
    }

    /// 发请求，解析错误体。`auth` 时带访问令牌，遇到令牌过期刷新后重试一次。
    async fn send(
        &self,
        method: Method,
        path: &str,
        body: Option<&Value>,
        auth: bool,
    ) -> Result<reqwest::Response> {
        for attempt in 0..2 {
            let token = if auth { Some(self.bearer()?) } else { None };
            let mut req = self
                .http
                .request(method.clone(), format!("{}{path}", self.base))
                .header(VERSION_HEADER, API_VERSION.to_string());
            if let Some(t) = &token {
                req = req.bearer_auth(t);
            }
            if let Some(b) = body {
                req = req.json(b);
            }
            let resp = req.send().await.map_err(ClientError::network)?;
            let status = resp.status().as_u16();
            if (200..300).contains(&status) {
                return Ok(resp);
            }
            let err = match resp.json::<ErrorBody>().await {
                Ok(e) => e,
                Err(_) if status == 426 => ErrorBody::new(ErrorCode::UpgradeRequired, ""),
                Err(e) => return Err(ClientError::decode(format!("status {status}: {e}"))),
            };
            match err.code {
                ErrorCode::UpgradeRequired => return Err(ClientError::UpgradeRequired),
                ErrorCode::Unauthenticated if attempt == 0 && token.is_some() => {
                    // 令牌过期：刷新后重试。别人已经刷新过就直接重试。
                    match self.refresh_from(token.as_deref()).await? {
                        Refreshed::Ok => continue,
                        Refreshed::SignedOut => return Err(ClientError::SignedOut),
                    }
                }
                ErrorCode::Unauthenticated | ErrorCode::SessionRevoked if auth => {
                    self.set_session(None);
                    return Err(ClientError::SignedOut);
                }
                code => {
                    return Err(ClientError::api(
                        status,
                        code,
                        err.message,
                        err.retry_after_secs,
                    ));
                }
            }
        }
        Err(ClientError::SignedOut)
    }

    /// 用刷新令牌换新令牌。`stale` 是失败请求用的访问令牌：当前令牌已经不是它，说明别的请求刚刷新过。
    async fn refresh_from(&self, stale: Option<&str>) -> Result<Refreshed> {
        let _guard = self.refreshing.lock().await;
        let Some(current) = self.session() else {
            return Ok(Refreshed::SignedOut);
        };
        if stale.is_some_and(|s| s != current.access_token) {
            return Ok(Refreshed::Ok);
        }
        let resp = self
            .http
            .post(format!("{}/v1/auth/refresh", self.base))
            .header(VERSION_HEADER, API_VERSION.to_string())
            .json(&json!({ "refresh_token": current.refresh_token }))
            .send()
            .await
            .map_err(ClientError::network)?;
        let status = resp.status().as_u16();
        if status == 200 {
            let t: Tokens = resp.json().await.map_err(ClientError::decode)?;
            self.set_session(Some(Session {
                access_token: t.access_token,
                refresh_token: t.refresh_token,
                ..current
            }));
            return Ok(Refreshed::Ok);
        }
        let err = resp.json::<ErrorBody>().await.ok();
        match err.as_ref().map(|e| e.code) {
            Some(ErrorCode::Unauthenticated | ErrorCode::SessionRevoked) => {
                self.set_session(None);
                Ok(Refreshed::SignedOut)
            }
            Some(ErrorCode::UpgradeRequired) => Err(ClientError::UpgradeRequired),
            Some(code) => {
                let e = err.unwrap_or_else(|| ErrorBody::new(code, ""));
                Err(ClientError::api(
                    status,
                    code,
                    e.message,
                    e.retry_after_secs,
                ))
            }
            None => Err(ClientError::decode(format!("refresh: status {status}"))),
        }
    }

    /// 强制刷新一次访问令牌（事件流被服务端以“令牌过期”关闭时用）。
    pub async fn refresh(&self) -> Result<()> {
        let stale = self.access_token();
        match self.refresh_from(stale.as_deref()).await? {
            Refreshed::Ok => Ok(()),
            Refreshed::SignedOut => Err(ClientError::SignedOut),
        }
    }

    async fn json<T: DeserializeOwned>(
        &self,
        method: Method,
        path: &str,
        body: Option<&Value>,
    ) -> Result<T> {
        let resp = self.send(method, path, body, true).await?;
        resp.json().await.map_err(ClientError::decode)
    }

    async fn empty(&self, method: Method, path: &str, body: Option<&Value>) -> Result<()> {
        self.send(method, path, body, true).await?;
        Ok(())
    }

    // ---------- 账号（4.1、4.2） ----------

    pub async fn send_code(&self, phone: &str) -> Result<()> {
        self.send(
            Method::POST,
            "/v1/auth/code",
            Some(&json!({ "phone": phone })),
            false,
        )
        .await?;
        Ok(())
    }

    pub async fn login(
        &self,
        phone: &str,
        code: &str,
        push: Option<(PushChannelKind, String)>,
    ) -> Result<LoginResult> {
        let mut device = json!({
            "platform": self.cfg.platform,
            "name": self.cfg.device_name,
        });
        if let Some((channel, token)) = push {
            device["push_channel"] = json!(channel);
            device["push_token"] = json!(token);
        }
        let resp = self
            .send(
                Method::POST,
                "/v1/auth/login",
                Some(&json!({ "phone": phone, "code": code, "device": device })),
                false,
            )
            .await?;
        let l: LoginResp = resp.json().await.map_err(ClientError::decode)?;
        self.set_session(Some(Session {
            user_id: l.user.id.to_string(),
            device_id: l.device_id,
            access_token: l.tokens.access_token,
            refresh_token: l.tokens.refresh_token,
        }));
        Ok(LoginResult {
            user: l.user,
            new_user: l.new_user,
        })
    }

    /// 退出登录（只下线本设备）。服务端调用失败也清掉本地会话。
    pub async fn logout(&self) -> Result<()> {
        let result = match self.access_token() {
            Some(_) => self.empty(Method::POST, "/v1/auth/logout", None).await,
            None => Ok(()),
        };
        self.set_session(None);
        match result {
            Err(ClientError::SignedOut) => Ok(()),
            r => r,
        }
    }

    pub async fn me(&self) -> Result<User> {
        self.json(Method::GET, "/v1/me", None).await
    }

    pub async fn set_push(&self, channel: PushChannelKind, token: &str) -> Result<()> {
        self.empty(
            Method::PUT,
            "/v1/devices/current/push",
            Some(&json!({ "channel": channel, "token": token })),
        )
        .await
    }

    // ---------- agent 与实例 ----------

    pub async fn agents(&self) -> Result<Vec<AgentInfo>> {
        #[derive(Deserialize)]
        struct R {
            agents: Vec<AgentInfo>,
        }
        Ok(self
            .json::<R>(Method::GET, "/v1/agents", None)
            .await?
            .agents)
    }

    pub async fn instances(&self) -> Result<Vec<Instance>> {
        #[derive(Deserialize)]
        struct R {
            instances: Vec<Instance>,
        }
        Ok(self
            .json::<R>(Method::GET, "/v1/instances", None)
            .await?
            .instances)
    }

    pub async fn instance(&self, id: InstanceId) -> Result<Instance> {
        self.json(Method::GET, &format!("/v1/instances/{id}"), None)
            .await
    }

    pub async fn adopt(
        &self,
        agent_id: &str,
        name: &str,
        harness: Option<&str>,
    ) -> Result<Instance> {
        self.json(
            Method::POST,
            "/v1/instances",
            Some(&json!({ "agent_id": agent_id, "name": name, "harness": harness })),
        )
        .await
    }

    pub async fn rename_instance(&self, id: InstanceId, name: &str) -> Result<Instance> {
        self.json(
            Method::PATCH,
            &format!("/v1/instances/{id}"),
            Some(&json!({ "name": name })),
        )
        .await
    }

    /// 换模板版本（不给就是升级到当前版本）：下次唤醒时重建沙箱，工作区保留。
    pub async fn set_instance_version(
        &self,
        id: InstanceId,
        version: Option<&str>,
    ) -> Result<Instance> {
        self.json(
            Method::POST,
            &format!("/v1/instances/{id}/version"),
            Some(&json!({ "version": version })),
        )
        .await
    }

    /// 实例的模型别名 → 哪把 key、哪个上游模型。
    pub async fn model_routes(&self, id: InstanceId) -> Result<Vec<ModelRoute>> {
        #[derive(Deserialize)]
        struct R {
            routes: Vec<ModelRoute>,
        }
        Ok(self
            .json::<R>(Method::GET, &format!("/v1/instances/{id}/routes"), None)
            .await?
            .routes)
    }

    /// 整体替换实例的模型别名。
    pub async fn set_model_routes(&self, id: InstanceId, routes: &[ModelRoute]) -> Result<()> {
        self.send(
            Method::PUT,
            &format!("/v1/instances/{id}/routes"),
            Some(&json!({ "routes": routes })),
            true,
        )
        .await?;
        Ok(())
    }

    pub async fn delete_instance(&self, id: InstanceId) -> Result<()> {
        self.empty(Method::DELETE, &format!("/v1/instances/{id}"), None)
            .await
    }

    // ---------- 运行 ----------

    pub async fn create_run(&self, instance: InstanceId, prompt: &str) -> Result<Run> {
        self.json(
            Method::POST,
            &format!("/v1/instances/{instance}/runs"),
            Some(&json!({ "prompt": prompt })),
        )
        .await
    }

    pub async fn runs(
        &self,
        instance: InstanceId,
        before: Option<RunId>,
        limit: u32,
    ) -> Result<Vec<Run>> {
        #[derive(Deserialize)]
        struct R {
            runs: Vec<Run>,
        }
        let mut path = format!("/v1/instances/{instance}/runs?limit={limit}");
        if let Some(b) = before {
            path.push_str(&format!("&before={b}"));
        }
        Ok(self.json::<R>(Method::GET, &path, None).await?.runs)
    }

    pub async fn run(&self, id: RunId) -> Result<Run> {
        self.json(Method::GET, &format!("/v1/runs/{id}"), None)
            .await
    }

    /// 取消一个运行；`tree` 时停掉整棵运行树（流水线）。
    pub async fn cancel_run(&self, id: RunId, tree: bool) -> Result<Run> {
        self.json(
            Method::POST,
            &format!("/v1/runs/{id}/cancel?tree={tree}"),
            None,
        )
        .await
    }

    pub async fn run_tree(&self, id: RunId) -> Result<Vec<Run>> {
        #[derive(Deserialize)]
        struct R {
            runs: Vec<Run>,
        }
        Ok(self
            .json::<R>(Method::GET, &format!("/v1/runs/{id}/tree"), None)
            .await?
            .runs)
    }

    // ---------- 审批 ----------

    pub async fn approvals(&self) -> Result<Vec<Approval>> {
        #[derive(Deserialize)]
        struct R {
            approvals: Vec<Approval>,
        }
        Ok(self
            .json::<R>(Method::GET, "/v1/approvals", None)
            .await?
            .approvals)
    }

    pub async fn decide_approval(&self, id: ApprovalId, option_id: &str) -> Result<Approval> {
        self.json(
            Method::POST,
            &format!("/v1/approvals/{id}/decide"),
            Some(&json!({ "option_id": option_id })),
        )
        .await
    }

    // ---------- 计划 ----------

    pub async fn plans(&self, instance: Option<InstanceId>) -> Result<Vec<Plan>> {
        #[derive(Deserialize)]
        struct R {
            plans: Vec<Plan>,
        }
        let path = match instance {
            Some(i) => format!("/v1/plans?instance_id={i}"),
            None => "/v1/plans".into(),
        };
        Ok(self.json::<R>(Method::GET, &path, None).await?.plans)
    }

    pub async fn plan(&self, id: PlanId) -> Result<PlanView> {
        self.json(Method::GET, &format!("/v1/plans/{id}"), None)
            .await
    }

    pub async fn create_plan(&self, plan: &NewPlan) -> Result<PlanView> {
        let body = serde_json::to_value(plan).map_err(ClientError::decode)?;
        self.json(Method::POST, "/v1/plans", Some(&body)).await
    }

    /// 暂停或恢复用户自己的计划（等确认的计划用 `confirm_plan`）。
    pub async fn set_plan_paused(&self, id: PlanId, paused: bool) -> Result<PlanView> {
        let action = if paused { "pause" } else { "resume" };
        self.json(Method::POST, &format!("/v1/plans/{id}/{action}"), None)
            .await
    }

    /// 确认 agent 新建或修改的计划，`revision` 是用户看到的版本。
    pub async fn confirm_plan(&self, id: PlanId, revision: u32) -> Result<PlanView> {
        self.json(
            Method::POST,
            &format!("/v1/plans/{id}/confirm"),
            Some(&serde_json::json!({ "revision": revision })),
        )
        .await
    }

    pub async fn delete_plan(&self, id: PlanId) -> Result<()> {
        self.empty(Method::DELETE, &format!("/v1/plans/{id}"), None)
            .await
    }

    // ---------- 收件箱（10.4） ----------

    pub async fn inbox(
        &self,
        before: Option<InboxItemId>,
        limit: u32,
        unread_only: bool,
    ) -> Result<InboxPage> {
        let mut path = format!("/v1/inbox?limit={limit}&unread={unread_only}");
        if let Some(b) = before {
            path.push_str(&format!("&before={b}"));
        }
        self.json(Method::GET, &path, None).await
    }

    /// 标已读：给 `ids` 只标这些；否则标到 `up_to`（含）为止。返回剩余未读数。
    pub async fn mark_inbox_read(
        &self,
        ids: Option<&[InboxItemId]>,
        up_to: Option<InboxItemId>,
    ) -> Result<i64> {
        #[derive(Deserialize)]
        struct R {
            unread: i64,
        }
        let body = match ids {
            Some(ids) => json!({ "ids": ids }),
            None => json!({ "up_to": up_to }),
        };
        Ok(self
            .json::<R>(Method::POST, "/v1/inbox/read", Some(&body))
            .await?
            .unread)
    }

    // ---------- 事件（补发） ----------

    pub async fn events_page(
        &self,
        instance: InstanceId,
        after: u64,
        limit: u32,
    ) -> Result<EventsPage> {
        self.json(
            Method::GET,
            &format!("/v1/instances/{instance}/events?after={after}&limit={limit}"),
            None,
        )
        .await
    }

    // ---------- 模型 key ----------

    pub async fn credentials(&self) -> Result<Vec<Credential>> {
        #[derive(Deserialize)]
        struct R {
            credentials: Vec<Credential>,
        }
        Ok(self
            .json::<R>(Method::GET, "/v1/credentials", None)
            .await?
            .credentials)
    }

    pub async fn add_credential(&self, c: &NewCredential) -> Result<Credential> {
        let body = serde_json::to_value(c).map_err(ClientError::decode)?;
        self.json(Method::POST, "/v1/credentials", Some(&body))
            .await
    }

    pub async fn delete_credential(&self, id: CredentialId) -> Result<()> {
        self.empty(Method::DELETE, &format!("/v1/credentials/{id}"), None)
            .await
    }

    // ---------- 用量 ----------

    /// 用量汇总。`group`：day / instance / model / credential；时间是 RFC 3339，不给就是最近 30 天。
    pub async fn usage(
        &self,
        group: &str,
        from: Option<&str>,
        to: Option<&str>,
        tz: Option<&str>,
    ) -> Result<UsageSummary> {
        let query = {
            let mut q = url::form_urlencoded::Serializer::new(String::new());
            q.append_pair("group", group);
            for (k, v) in [("from", from), ("to", to), ("tz", tz)] {
                if let Some(v) = v {
                    q.append_pair(k, v);
                }
            }
            q.finish()
        };
        self.json(Method::GET, &format!("/v1/usage?{query}"), None)
            .await
    }

    // ---------- 产出物 ----------

    pub async fn run_artifacts(&self, run: RunId) -> Result<Vec<Artifact>> {
        #[derive(Deserialize)]
        struct R {
            artifacts: Vec<Artifact>,
        }
        Ok(self
            .json::<R>(Method::GET, &format!("/v1/runs/{run}/artifacts"), None)
            .await?
            .artifacts)
    }

    pub async fn artifact_content(&self, id: ArtifactId) -> Result<Vec<u8>> {
        let resp = self
            .send(
                Method::GET,
                &format!("/v1/artifacts/{id}/content"),
                None,
                true,
            )
            .await?;
        Ok(resp.bytes().await.map_err(ClientError::network)?.to_vec())
    }
}
