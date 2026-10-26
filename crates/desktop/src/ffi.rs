//! macOS App 用的接口（UniFFI，14.5、14.6）：App 的后台进程建一个 [`DesktopService`]，它在自己的 tokio 运行时里跑
//! [`Desktop`]（连中继、把关、执行、记审计日志）。App 交进来的是系统那一侧的东西：
//!
//! - [`DesktopTokens`]：这台电脑的访问令牌（App 用 client-core 的 `ThinktinClient` 管会话，刷新也在那边）；
//! - [`NativeTools`]：截图、键鼠、打开应用这些要用 macOS 系统接口的工具（14.3、14.4），文件和命令由 [`FileTools`] 做；
//! - [`PairingSigner`]：电脑的配对密钥（钥匙串 / Secure Enclave，14.8）；
//! - [`DesktopObserver`]：连接状态、配对进度、停下的原因（菜单栏的“正在被控制”、配对界面）。
//!
//! 和 client-core 打进同一个库（App 链接 `libdesktop`，绑定按库生成，两个模块都有）。回调在后台线程上，
//! 界面更新要切回主线程。

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use client_core::pairing::CapabilityGrant;
use serde_json::Value;
use tokio::task::JoinHandle;

use crate::files::FileTools;
use crate::pairing::{PairingKey, PairingStatus};
use crate::{
    Desktop, DesktopConfig, DesktopError, PairedPhone, Status, TokenSource, ToolBackend, ToolResult,
};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum DesktopFfiError {
    /// 本地状态读写不了（数据目录不对、文件坏了）。
    #[error("local state: {detail}")]
    State { detail: String },
    /// 出不了配对二维码。
    #[error("pairing: {detail}")]
    Pairing { detail: String },
    /// App 那一侧的回调出错（拿不到令牌、签不了名）。
    #[error("{detail}")]
    Callback { detail: String },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for DesktopFfiError {
    fn from(e: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Callback { detail: e.reason }
    }
}

impl From<DesktopError> for DesktopFfiError {
    fn from(e: DesktopError) -> Self {
        match e {
            DesktopError::Pairing(detail) => Self::Pairing { detail },
            other => Self::State {
                detail: other.to_string(),
            },
        }
    }
}

/// 建服务要的设置。
#[derive(Debug, Clone, uniffi::Record)]
pub struct DesktopSettings {
    /// 设备中继，比如 `wss://relay.example.com/v1/connect`。
    pub relay_url: String,
    /// 这台电脑的设备 id（登录时拿到的）。
    pub desktop_id: String,
    pub app_version: String,
    /// 本地状态和审计日志放在这里（App 的 Application Support 目录）。
    pub data_dir: String,
    /// 用户目录：命令默认在这里跑，删除的东西挪到它下面的 `.Trash`。
    pub home_dir: String,
}

/// 连接状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConnectionStatus {
    Offline,
    Connecting,
    Connected,
}

impl From<Status> for ConnectionStatus {
    fn from(s: Status) -> Self {
        match s {
            Status::Offline => Self::Offline,
            Status::Connecting => Self::Connecting,
            Status::Connected => Self::Connected,
        }
    }
}

/// 配对进行到哪了。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum PairingState {
    Idle,
    /// 二维码在显示：内容、过期时间（Unix 秒）。
    Waiting {
        uri: String,
        expires_at: u64,
    },
    Paired {
        phone_id: String,
    },
    /// 手机的回复验不过，或者邀请过期了：要重新出二维码。
    Failed {
        reason: String,
    },
}

impl From<PairingStatus> for PairingState {
    fn from(s: PairingStatus) -> Self {
        match s {
            PairingStatus::Idle => Self::Idle,
            PairingStatus::Waiting { uri, expires_at } => Self::Waiting { uri, expires_at },
            PairingStatus::Paired { phone_id } => Self::Paired { phone_id },
            PairingStatus::Failed { reason } => Self::Failed { reason },
        }
    }
}

/// 服务为什么停了。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum StopReason {
    /// App 调了 [`DesktopService::stop`]。
    Requested,
    /// 中继拒绝了这台电脑（账号被冻结，或者这台设备不是电脑）：提示用户，不要自动重启。
    Refused { detail: String },
    /// 这台电脑在别处又连了一次（开了两个 App？）：这边停下。
    Replaced,
}

/// 配对的手机。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PhoneInfo {
    pub device_id: String,
    /// 手机的公钥（SEC1，base64url）。
    pub public_key: String,
}

/// 系统工具的结果：MCP 的 content 数组（JSON 文本）；工具自己出错时 `is_error` 为真。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NativeToolResult {
    pub content_json: String,
    pub is_error: bool,
}

/// 这台电脑的访问令牌（App 用 client-core 管）。
#[uniffi::export(foreign)]
#[async_trait]
pub trait DesktopTokens: Send + Sync {
    /// 现在的访问令牌；`refresh` 为真时先换一个新的。
    async fn access_token(&self, refresh: bool) -> Result<String, DesktopFfiError>;
}

/// 要用 macOS 系统接口的工具（截图、键鼠、打开应用）。权限在调用之前已经核对过。
#[uniffi::export(foreign)]
#[async_trait]
pub trait NativeTools: Send + Sync {
    /// 现在能用的（随系统权限变化：没给屏幕录制权限就没有截图）。
    fn available(&self) -> Vec<String>;
    /// 前台应用的 bundle id（键鼠只能对着手机授权过的应用）。
    fn frontmost_app(&self) -> Option<String>;
    /// `arguments_json` 是工具参数（JSON 对象）。
    async fn call(&self, tool: String, arguments_json: String) -> NativeToolResult;
}

/// 电脑的配对密钥（P-256，钥匙串 / Secure Enclave 里）。
#[uniffi::export(foreign)]
pub trait PairingSigner: Send + Sync {
    /// 公钥（SEC1）。
    fn public_key(&self) -> Vec<u8>;
    /// ECDSA P-256 + SHA-256 签名，DER 或 r‖s。
    fn sign(&self, message: Vec<u8>) -> Result<Vec<u8>, DesktopFfiError>;
}

/// 状态变化（后台线程上回调）。
#[uniffi::export(foreign)]
pub trait DesktopObserver: Send + Sync {
    fn on_status(&self, status: ConnectionStatus);
    fn on_pairing(&self, state: PairingState);
    /// [`DesktopService::start`] 之后服务停了。
    fn on_stopped(&self, reason: StopReason);
}

struct Tokens(Arc<dyn DesktopTokens>);

#[async_trait]
impl TokenSource for Tokens {
    async fn access_token(&self, refresh: bool) -> Result<String, String> {
        self.0
            .access_token(refresh)
            .await
            .map_err(|e| e.to_string())
    }
}

struct Signer(Arc<dyn PairingSigner>);

impl PairingKey for Signer {
    fn public_key(&self) -> Vec<u8> {
        self.0.public_key()
    }

    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, String> {
        self.0.sign(message.to_vec()).map_err(|e| e.to_string())
    }
}

/// 文件和命令用 [`FileTools`]，其余交给 App。
struct Tools {
    files: FileTools,
    native: Arc<dyn NativeTools>,
}

#[async_trait]
impl ToolBackend for Tools {
    fn available(&self) -> Vec<String> {
        let mut tools = self.files.available();
        for tool in self.native.available() {
            if !tools.contains(&tool) {
                tools.push(tool);
            }
        }
        tools
    }

    fn frontmost_app(&self) -> Option<String> {
        self.native.frontmost_app()
    }

    async fn call(&self, tool: &str, arguments: &Value) -> ToolResult {
        if self.files.available().iter().any(|t| t == tool) {
            return self.files.call(tool, arguments).await;
        }
        let result = self
            .native
            .call(tool.to_owned(), arguments.to_string())
            .await;
        match serde_json::from_str::<Vec<Value>>(&result.content_json) {
            Ok(content) => ToolResult {
                content,
                is_error: result.is_error,
            },
            Err(_) => ToolResult::error("The computer returned a malformed result for this tool."),
        }
    }
}

/// 电脑端的工具服务（macOS App 的后台进程里一个）。
#[derive(uniffi::Object)]
pub struct DesktopService {
    rt: tokio::runtime::Runtime,
    desktop: Desktop,
    observer: Arc<dyn DesktopObserver>,
    runner: Mutex<Option<JoinHandle<()>>>,
}

#[uniffi::export]
impl DesktopService {
    /// 读本地状态（配对的手机、令牌）、开审计日志。还不连中继，[`start`](Self::start) 才连。
    #[uniffi::constructor]
    pub fn new(
        settings: DesktopSettings,
        tokens: Arc<dyn DesktopTokens>,
        native: Arc<dyn NativeTools>,
        observer: Arc<dyn DesktopObserver>,
    ) -> Result<Arc<Self>, DesktopFfiError> {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("thinktin-desktop")
            .enable_all()
            .build()
            .map_err(|e| DesktopFfiError::State {
                detail: e.to_string(),
            })?;
        let mut cfg = DesktopConfig::new(
            settings.relay_url,
            settings.desktop_id,
            &PathBuf::from(settings.data_dir),
        );
        cfg.app_version = settings.app_version;
        let backend = Tools {
            files: FileTools::for_home(settings.home_dir),
            native,
        };
        let desktop = Desktop::new(cfg, Arc::new(Tokens(tokens)), Arc::new(backend))?;
        // 状态、配对进度变了就告诉 App（每个只留最新的，不排队）。
        let mut status = desktop.watch_status();
        let mut pairing = desktop.watch_pairing();
        let to_app = observer.clone();
        rt.spawn(async move {
            while status.changed().await.is_ok() {
                let now = *status.borrow_and_update();
                to_app.on_status(now.into());
            }
        });
        let to_app = observer.clone();
        rt.spawn(async move {
            while pairing.changed().await.is_ok() {
                let now = pairing.borrow_and_update().clone();
                to_app.on_pairing(now.into());
            }
        });
        Ok(Arc::new(Self {
            rt,
            desktop,
            observer,
            runner: Mutex::new(None),
        }))
    }

    /// 连中继（后台一直连着，断了按退避重连）。已经在跑时什么都不做。停下时回调 `on_stopped`。
    pub fn start(&self) {
        let mut runner = self.runner.lock().unwrap_or_else(|e| e.into_inner());
        if runner.as_ref().is_some_and(|r| !r.is_finished()) {
            return;
        }
        self.desktop.resume();
        let desktop = self.desktop.clone();
        let observer = self.observer.clone();
        *runner = Some(self.rt.spawn(async move {
            let reason = match desktop.run().await {
                Ok(()) => StopReason::Requested,
                Err(DesktopError::Replaced) => StopReason::Replaced,
                Err(e) => StopReason::Refused {
                    detail: e.to_string(),
                },
            };
            observer.on_stopped(reason);
        }));
    }

    /// 断开、不再重连（菜单栏的“停止”；用户退出登录时也调）。
    pub fn stop(&self) {
        self.desktop.stop();
    }

    pub fn status(&self) -> ConnectionStatus {
        self.desktop.status().into()
    }

    /// 出配对二维码（`thinktin-pair:v1?…`），最长 10 分钟；之前的作废。
    pub fn start_pairing(
        &self,
        signer: Arc<dyn PairingSigner>,
        ttl_secs: u64,
    ) -> Result<String, DesktopFfiError> {
        Ok(self
            .desktop
            .start_pairing(Arc::new(Signer(signer)), Duration::from_secs(ttl_secs))?)
    }

    pub fn cancel_pairing(&self) {
        self.desktop.cancel_pairing();
    }

    pub fn paired_phone(&self) -> Option<PhoneInfo> {
        self.desktop.paired_phone().map(|p: PairedPhone| PhoneInfo {
            device_id: p.device_id,
            public_key: p.public_key,
        })
    }

    /// 解除配对：之后普通操作、高危操作都不做。
    pub fn unpair(&self) -> Result<(), DesktopFfiError> {
        Ok(self.desktop.unpair()?)
    }

    /// 现在有效的能力令牌（给 App 显示）。
    pub fn grants(&self) -> Vec<CapabilityGrant> {
        self.desktop.grants()
    }
}

impl Drop for DesktopService {
    fn drop(&mut self) {
        self.desktop.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    struct Native;

    #[async_trait]
    impl NativeTools for Native {
        fn available(&self) -> Vec<String> {
            vec!["computer_screenshot".into(), "computer_read_file".into()]
        }
        fn frontmost_app(&self) -> Option<String> {
            Some("com.apple.Safari".into())
        }
        async fn call(&self, tool: String, _arguments_json: String) -> NativeToolResult {
            match tool.as_str() {
                "computer_screenshot" => NativeToolResult {
                    content_json:
                        json!([{ "type": "image", "data": "AA==", "mimeType": "image/png" }])
                            .to_string(),
                    is_error: false,
                },
                _ => NativeToolResult {
                    content_json: "not json".into(),
                    is_error: false,
                },
            }
        }
    }

    #[tokio::test]
    async fn file_tools_stay_in_rust_and_the_rest_go_to_the_app() {
        let home = tempfile::tempdir().unwrap();
        std::fs::write(home.path().join("a.txt"), "hello").unwrap();
        let tools = Tools {
            files: FileTools::for_home(home.path()),
            native: Arc::new(Native),
        };
        let available = tools.available();
        assert!(available.contains(&"computer_screenshot".to_owned()));
        assert_eq!(
            available
                .iter()
                .filter(|t| *t == "computer_read_file")
                .count(),
            1,
            "{available:?}"
        );
        assert_eq!(tools.frontmost_app().as_deref(), Some("com.apple.Safari"));

        let path = home.path().join("a.txt").display().to_string();
        let read = tools
            .call("computer_read_file", &json!({ "path": path }))
            .await;
        assert!(!read.is_error, "{read:?}");
        assert!(read.content[0]["text"].as_str().unwrap().contains("hello"));

        let shot = tools.call("computer_screenshot", &json!({})).await;
        assert_eq!(shot.content[0]["type"], "image");
        let bad = tools.call("computer_click", &json!({})).await;
        assert!(bad.is_error);
    }

    #[test]
    fn errors_and_states_cross_the_boundary() {
        assert_eq!(
            DesktopFfiError::from(DesktopError::Pairing("bad key".into())),
            DesktopFfiError::Pairing {
                detail: "bad key".into()
            }
        );
        assert_eq!(
            PairingState::from(PairingStatus::Paired {
                phone_id: "p".into()
            }),
            PairingState::Paired {
                phone_id: "p".into()
            }
        );
        assert_eq!(
            ConnectionStatus::from(Status::Connected),
            ConnectionStatus::Connected
        );
    }
}
