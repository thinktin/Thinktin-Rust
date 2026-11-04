//! 后台：接口客户端（client-core 的 `Api`）和电脑端工具服务（`desktop::Desktop`）跑在自己的 tokio 运行时上；
//! 界面线程只发命令、读 [`Shared`] 里的快照，后台每次改完快照就请求重画。

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use client_core::api::{Api, ApiConfig, DeviceView};
use client_core::pairing::CapabilityGrant;
use client_core::{ClientError, Result as ClientResult};
use desktop::files::FileTools;
use desktop::{Desktop, DesktopConfig, DesktopError, PairingStatus, Status, ToolBackend, ToolSet};
use proto::domain::{DevicePlatform, User};
use tokio::task::JoinHandle;

use crate::config::Config;
use crate::store::LocalStore;
use crate::texts::{Lang, Text};

/// 服务为什么停了（给界面提示）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Stopped {
    Requested,
    Replaced,
    Refused(String),
}

/// 界面看的快照。
#[derive(Debug, Clone, Default)]
pub struct Shared {
    pub busy: bool,
    pub error: Option<String>,
    pub user: Option<User>,
    pub device_id: Option<String>,
    pub devices: Vec<DeviceView>,
    pub status: Option<Status>,
    pub pairing: Option<PairingStatus>,
    pub phone: Option<String>,
    pub grants: Vec<CapabilityGrant>,
    pub activity: Option<String>,
    pub stopped: Option<Stopped>,
    /// 验证码发出去了（倒计时从这时算）。
    pub code_sent_at: Option<std::time::Instant>,
}

impl Shared {
    pub fn signed_in(&self) -> bool {
        self.device_id.is_some()
    }
}

struct Tokens(Arc<Api>);

#[async_trait]
impl desktop::TokenSource for Tokens {
    async fn access_token(&self, refresh: bool) -> Result<String, String> {
        if refresh {
            self.0.refresh().await.map_err(|e| e.to_string())?;
        }
        self.0.bearer().map_err(|e| e.to_string())
    }
}

struct Running {
    desktop: Desktop,
    device_id: String,
    runner: JoinHandle<()>,
}

pub struct Backend {
    rt: tokio::runtime::Runtime,
    pub cfg: Config,
    pub store: Arc<LocalStore>,
    api: Arc<Api>,
    lang: Lang,
    shared: Arc<Mutex<Shared>>,
    running: Mutex<Option<Running>>,
    repaint: Mutex<Option<egui::Context>>,
}

/// 接口错误换成给人看的话。
pub fn describe(lang: Lang, e: &ClientError) -> String {
    match e {
        ClientError::Network { detail } => format!("{}{detail}", lang.t(Text::ErrorNetwork)),
        ClientError::SignedOut => lang.t(Text::ErrorSignedOut).to_owned(),
        ClientError::UpgradeRequired => lang.t(Text::ErrorUpgrade).to_owned(),
        ClientError::AccountFrozen => lang.t(Text::ErrorFrozen).to_owned(),
        ClientError::Api {
            detail,
            retry_after_secs: Some(secs),
            ..
        } => format!("{detail} ({secs}s)"),
        ClientError::Api { detail, .. } => detail.clone(),
        other => other.to_string(),
    }
}

impl Backend {
    pub fn new(cfg: Config, lang: Lang) -> Result<Arc<Self>, String> {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("thinktin-backend")
            .enable_all()
            .build()
            .map_err(|e| e.to_string())?;
        let store = Arc::new(LocalStore::open(&cfg.data_dir));
        let api = Arc::new(
            Api::new(
                ApiConfig {
                    base_url: cfg.api_url.clone(),
                    platform: DevicePlatform::Windows,
                    device_name: cfg.device_name.clone(),
                    timeout: Duration::from_secs(30),
                    accept_language: Some(lang.accept_language().to_owned()),
                },
                store.clone(),
            )
            .map_err(|e| e.to_string())?,
        );
        let shared = Arc::new(Mutex::new(Shared {
            device_id: api.session().map(|s| s.device_id),
            ..Default::default()
        }));
        let me = Arc::new(Self {
            rt,
            cfg,
            store,
            api,
            lang,
            shared,
            running: Mutex::new(None),
            repaint: Mutex::new(None),
        });
        // 会话失效（被远程下线、刷新令牌被拒）：停掉服务、回到登录页。
        let weak = Arc::downgrade(&me);
        me.api.on_signed_out(move || {
            if let Some(me) = weak.upgrade() {
                me.stop_service(false);
                me.update(|s| {
                    s.device_id = None;
                    s.user = None;
                    s.devices.clear();
                });
            }
        });
        Ok(me)
    }

    pub fn attach(&self, ctx: egui::Context) {
        *self.repaint.lock().unwrap_or_else(|e| e.into_inner()) = Some(ctx);
    }

    pub fn snapshot(&self) -> Shared {
        self.shared
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    fn update(&self, f: impl FnOnce(&mut Shared)) {
        f(&mut self.shared.lock().unwrap_or_else(|e| e.into_inner()));
        if let Some(ctx) = self
            .repaint
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
        {
            ctx.request_repaint();
        }
    }

    /// 在后台跑一件事，先标忙，完了把错误（如果有）放进快照。
    fn spawn<F>(self: &Arc<Self>, work: impl FnOnce(Arc<Self>) -> F + Send + 'static)
    where
        F: std::future::Future<Output = ClientResult<()>> + Send + 'static,
    {
        let me = self.clone();
        self.update(|s| {
            s.busy = true;
            s.error = None;
        });
        self.rt.spawn(async move {
            let result = work(me.clone()).await;
            let lang = me.lang;
            me.update(|s| {
                s.busy = false;
                if let Err(e) = &result {
                    s.error = Some(describe(lang, e));
                }
            });
        });
    }

    // ---------- 账号 ----------

    pub fn send_code(self: &Arc<Self>, phone: String) {
        self.spawn(move |me| async move {
            me.api.send_code(phone.trim()).await?;
            me.update(|s| s.code_sent_at = Some(std::time::Instant::now()));
            Ok(())
        });
    }

    pub fn login(self: &Arc<Self>, phone: String, code: String) {
        self.spawn(move |me| async move {
            let l = me.api.login(phone.trim(), code.trim(), None).await?;
            let device_id = me.api.session().map(|s| s.device_id);
            me.update(|s| {
                s.user = Some(l.user);
                s.device_id = device_id.clone();
                s.code_sent_at = None;
            });
            // 上次开着就接着开。
            if let Some(id) = device_id
                && me.store.control_on(&id)
            {
                me.start_service();
            }
            me.refresh().await
        });
    }

    /// 登录着：拉用户和设备；按上次的开关起服务。启动时调。
    pub fn resume(self: &Arc<Self>) {
        if self.api.session().is_none() {
            return;
        }
        let device_id = self.api.session().map(|s| s.device_id);
        if let Some(id) = &device_id
            && self.store.control_on(id)
        {
            self.start_service();
        }
        self.spawn(|me| async move { me.refresh().await });
    }

    async fn refresh(self: &Arc<Self>) -> ClientResult<()> {
        let user = self.api.me().await?;
        let devices = self.api.devices().await.unwrap_or_default();
        self.update(|s| {
            s.user = Some(user);
            s.devices = devices;
        });
        Ok(())
    }

    pub fn logout(self: &Arc<Self>) {
        self.stop_service(false);
        self.spawn(|me| async move {
            let r = me.api.logout().await;
            me.update(|s| {
                s.user = None;
                s.device_id = None;
                s.devices.clear();
                s.phone = None;
                s.grants.clear();
                s.pairing = None;
            });
            r
        });
    }

    // ---------- 手机控制 ----------

    fn desktop(self: &Arc<Self>, device_id: &str) -> Result<Desktop, DesktopError> {
        let dir = self.cfg.desktop_dir(device_id);
        std::fs::create_dir_all(&dir).map_err(|e| DesktopError::State(e.to_string()))?;
        let mut cfg = DesktopConfig::new(self.cfg.relay_url.clone(), device_id, &dir);
        cfg.app_version = self.cfg.app_version.clone();
        let files: Arc<dyn ToolBackend> = Arc::new(FileTools::for_home(&self.cfg.home_dir));
        #[cfg(windows)]
        let backends = vec![
            files,
            Arc::new(desktop::windows::WindowsTools::new()) as Arc<dyn ToolBackend>,
        ];
        #[cfg(not(windows))]
        let backends = vec![files];
        Desktop::new(
            cfg,
            Arc::new(Tokens(self.api.clone())),
            Arc::new(ToolSet(backends)),
        )
    }

    /// 连中继（用户点“开始”、启动时恢复）。已经在跑就不动。
    pub fn start_service(self: &Arc<Self>) {
        let Some(device_id) = self.api.session().map(|s| s.device_id) else {
            return;
        };
        let mut running = self.running.lock().unwrap_or_else(|e| e.into_inner());
        if running
            .as_ref()
            .is_some_and(|r| r.device_id == device_id && !r.runner.is_finished())
        {
            return;
        }
        let desktop = match self.desktop(&device_id) {
            Ok(d) => d,
            Err(e) => {
                self.update(|s| s.error = Some(e.to_string()));
                return;
            }
        };
        self.store.set_control_on(&device_id, true);
        let me = self.clone();
        let phone = desktop.paired_phone().map(|p| p.device_id);
        let grants = desktop.grants();
        self.update(|s| {
            s.stopped = None;
            s.status = Some(Status::Connecting);
            s.phone = phone;
            s.grants = grants;
        });
        // 状态、配对、活动的变化转进快照。
        let (mut status, mut pairing, mut activity) = (
            desktop.watch_status(),
            desktop.watch_pairing(),
            desktop.watch_activity(),
        );
        let d = desktop.clone();
        let w = me.clone();
        self.rt.spawn(async move {
            while status.changed().await.is_ok() {
                let now = *status.borrow_and_update();
                let grants = d.grants();
                w.update(|s| {
                    s.status = Some(now);
                    s.grants = grants;
                });
            }
        });
        let d = desktop.clone();
        let w = me.clone();
        self.rt.spawn(async move {
            while pairing.changed().await.is_ok() {
                let now = pairing.borrow_and_update().clone();
                let phone = d.paired_phone().map(|p| p.device_id);
                w.update(|s| {
                    s.pairing = Some(now);
                    s.phone = phone;
                });
            }
        });
        let d = desktop.clone();
        let w = me.clone();
        self.rt.spawn(async move {
            while activity.changed().await.is_ok() {
                let tool = activity.borrow_and_update().tool.clone();
                let grants = d.grants();
                w.update(|s| {
                    s.activity = tool;
                    s.grants = grants;
                });
            }
        });
        let d = desktop.clone();
        let w = me.clone();
        let runner = self.rt.spawn(async move {
            let stopped = match d.run().await {
                Ok(()) => Stopped::Requested,
                Err(DesktopError::Replaced) => Stopped::Replaced,
                Err(e) => Stopped::Refused(e.to_string()),
            };
            w.update(|s| {
                s.status = Some(Status::Offline);
                s.activity = None;
                s.stopped = Some(stopped);
            });
        });
        *running = Some(Running {
            desktop,
            device_id,
            runner,
        });
    }

    /// 断开（用户点“停止”时记住；退出登录、会话失效这种被动的不记）。
    pub fn stop_service(&self, remember: bool) {
        let running = self.running.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(r) = running.as_ref() {
            r.desktop.stop();
            if remember {
                self.store.set_control_on(&r.device_id, false);
            }
        }
    }

    pub fn service_running(&self) -> bool {
        self.running
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .is_some_and(|r| !r.runner.is_finished())
    }

    fn with_desktop<R>(&self, f: impl FnOnce(&Desktop) -> R) -> Option<R> {
        self.running
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .map(|r| f(&r.desktop))
    }

    /// 出配对二维码（要连着中继才收得到手机的回复）。
    pub fn start_pairing(self: &Arc<Self>) {
        if !self.service_running() {
            self.start_service();
        }
        let key = match self.store.pairing_key() {
            Ok(k) => Arc::new(k),
            Err(e) => {
                self.update(|s| s.error = Some(e));
                return;
            }
        };
        let result = self.with_desktop(|d| d.start_pairing(key, Duration::from_secs(10 * 60)));
        if let Some(Err(e)) = result {
            self.update(|s| s.error = Some(e.to_string()));
        }
    }

    pub fn cancel_pairing(&self) {
        self.with_desktop(|d| d.cancel_pairing());
    }

    pub fn unpair(&self) {
        let result = self.with_desktop(|d| d.unpair());
        match result {
            Some(Err(e)) => self.update(|s| s.error = Some(e.to_string())),
            _ => self.update(|s| {
                s.phone = None;
                s.grants.clear();
                s.pairing = None;
            }),
        }
    }

    pub fn refresh_grants(&self) {
        let now = self.with_desktop(|d| (d.paired_phone().map(|p| p.device_id), d.grants()));
        if let Some((phone, grants)) = now {
            self.update(|s| {
                s.phone = phone;
                s.grants = grants;
            });
        }
    }

    pub fn clear_error(&self) {
        self.update(|s| s.error = None);
    }

    pub fn lang(&self) -> Lang {
        self.lang
    }
}
