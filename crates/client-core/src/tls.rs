//! TLS（11.8）：接口请求（reqwest）和事件流（WebSocket）都用系统的证书校验（`rustls-platform-verifier`：
//! iOS / macOS 是 Security.framework，Android 是系统的 `X509TrustManager`，Linux 读系统证书目录），和系统设置里
//! 信任的证书一致，不用编进程序里的一份根证书。
//!
//! Android 上系统的证书校验要经 JNI 调 Java，所以 App 建 [`ThinktinClient`](crate::ffi::ThinktinClient) 之前要先调
//! `cn.thinktin.core.TlsInit.initialize(applicationContext)`（Kotlin：`object TlsInit { init { System.loadLibrary(
//! "client_core") } @JvmStatic external fun initialize(context: android.content.Context) }`），没调的话 https 的地址
//! 建客户端时直接报错（不然第一次握手时才 panic）。校验时调的是 rustls-platform-verifier 的 Kotlin 组件
//! `org.rustls:rustls-platform-verifier`：`tools/client-core/build-android.sh` 生成的库工程带着这个依赖和混淆规则，
//! 引入库工程的 App 要在 settings.gradle.kts 里加它的 Maven 仓库；缺了它每次握手都失败（找不到类）。

use std::sync::Arc;

use rustls_platform_verifier::BuilderVerifierExt;

/// 事件流的 TLS 配置：系统证书校验，不协商 ALPN（WebSocket 走 HTTP/1.1）。
pub(crate) fn ws_client_config() -> Result<Arc<rustls::ClientConfig>, rustls::Error> {
    let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
    let cfg = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()?
        .with_platform_verifier()?
        .with_no_client_auth();
    Ok(Arc::new(cfg))
}

/// 这个平台的证书校验能不能用了（Android 上要先初始化；别的平台一直可以）。
pub(crate) fn platform_ready() -> bool {
    #[cfg(target_os = "android")]
    {
        android::READY.load(std::sync::atomic::Ordering::Acquire)
    }
    #[cfg(not(target_os = "android"))]
    {
        true
    }
}

#[cfg(target_os = "android")]
mod android {
    use std::sync::atomic::{AtomicBool, Ordering};

    use jni::EnvUnowned;
    use jni::objects::{JClass, JObject};

    pub(super) static READY: AtomicBool = AtomicBool::new(false);

    /// `cn.thinktin.core.TlsInit.initialize(context)`：把 App 的 Context 交给系统证书校验（只用第一次的）。
    /// 失败时在 Java 那边抛 `RuntimeException`。
    #[unsafe(no_mangle)]
    pub extern "system" fn Java_cn_thinktin_core_TlsInit_initialize<'caller>(
        mut unowned_env: EnvUnowned<'caller>,
        _class: JClass<'caller>,
        context: JObject<'caller>,
    ) {
        unowned_env
            .with_env(|env| -> Result<(), jni::errors::Error> {
                rustls_platform_verifier::android::init_with_env(env, context)?;
                READY.store(true, Ordering::Release);
                Ok(())
            })
            .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_event_stream_uses_the_platform_verifier_without_alpn() {
        crate::install_crypto();
        let cfg = super::ws_client_config().unwrap();
        assert!(cfg.alpn_protocols.is_empty());
        assert!(super::platform_ready());
    }
}
