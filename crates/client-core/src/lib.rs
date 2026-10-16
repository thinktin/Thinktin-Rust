//! 客户端共享核心（WBS 11.1–11.4），经 UniFFI 供 Swift / Kotlin 调用：
//!
//! - [`api`]：接口客户端，版本头、统一错误模型、令牌自动刷新；
//! - [`events`]：实例事件流，断线重连、按序号续传和去重；
//! - [`cache`]：本地 SQLite 缓存、离线收件箱；
//! - [`secrets`]：发送前识别消息里的密码、key，换成保险箱引用（11.6）；
//! - [`ffi`]：给原生端的接口（UniFFI 生成 Swift / Kotlin 绑定，见 `tools/client-core/`）。

pub mod api;
pub mod cache;
pub mod client;
pub mod error;
pub mod events;
pub mod ffi;
pub mod secrets;

pub use error::{ClientError, Result};

uniffi::setup_scaffolding!();

/// TLS 用 aws-lc-rs（和 HTTP 客户端一致）；WebSocket 走进程默认的加密实现，要先装上。
pub(crate) fn install_crypto() {
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
}
