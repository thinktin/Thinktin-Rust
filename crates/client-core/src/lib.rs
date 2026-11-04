//! 客户端共享核心（WBS 11.1–11.4），经 UniFFI 供 Swift / Kotlin 调用：
//!
//! - [`api`]：接口客户端，版本头、统一错误模型、令牌自动刷新；
//! - [`events`]：实例事件流，断线重连、按序号续传和去重；
//! - [`cache`]：本地 SQLite 缓存、离线收件箱；
//! - [`secrets`]：发送前识别消息里的密码、key，换成保险箱引用（11.6）；
//! - [`pairing`]：手机和电脑的配对、审批签名、能力令牌的编码与验签（11.5）；
//! - `tls`：接口和事件流都用系统的证书校验，Android 上要先初始化（11.8）；
//! - [`logging`]：日志抹掉敏感内容后交给 App 写进系统日志（11.8）；
//! - [`ffi`]：给原生端的接口（UniFFI 生成 Swift / Kotlin 绑定，见 `tools/client-core/`）。

pub mod api;
pub mod cache;
pub mod client;
pub mod error;
pub mod events;
pub mod ffi;
mod lenient;
pub mod logging;
pub mod pairing;
pub mod secrets;
mod tls;

pub use error::{ClientError, Result};

uniffi::setup_scaffolding!();

/// TLS 用 aws-lc-rs（和 HTTP 客户端一致），装成进程默认的加密实现（reqwest 用它）。
/// 电脑端的工具服务（`desktop`）连设备中继前也调它。
pub fn install_crypto() {
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
}
