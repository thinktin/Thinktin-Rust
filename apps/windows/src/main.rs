//! ThinkTin 的 Windows 电脑端（docs/windows.md）：托盘常驻，后台跑电脑端的工具服务（`desktop`），
//! 用户的 agent 经设备中继、按手机给的授权用这台电脑。窗口里登录、配对手机、看授权。
//! 对话和计划的界面还没有（手机 App 上做）。

#![cfg_attr(windows, windows_subsystem = "windows")]

mod app;
mod config;
mod fonts;
mod icon;
mod platform;
mod qr;
mod service;
mod store;
mod texts;
mod tray;

use std::sync::Arc;

use crate::config::Config;
use crate::texts::Lang;

fn logging(cfg: &Config) {
    use tracing_subscriber::EnvFilter;
    let dir = cfg.data_dir.join("logs");
    let _ = std::fs::create_dir_all(&dir);
    let file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("thinktin.log"));
    let filter = EnvFilter::try_from_env("THINKTIN_LOG")
        .unwrap_or_else(|_| EnvFilter::new("info,desktop=debug"));
    match file {
        Ok(file) => tracing_subscriber::fmt()
            .with_env_filter(filter)
            .with_ansi(false)
            .with_writer(std::sync::Mutex::new(file))
            .init(),
        Err(_) => tracing_subscriber::fmt().with_env_filter(filter).init(),
    }
}

fn main() {
    let background = std::env::args().any(|a| a == "--background");
    #[cfg(windows)]
    desktop::windows::become_dpi_aware();
    let cfg = Config::load();
    logging(&cfg);
    let lang = Lang::detect();
    let backend = match service::Backend::new(cfg, lang) {
        Ok(b) => b,
        Err(e) => {
            tracing::error!(error = %e, "cannot start");
            platform::fatal(&e);
            return;
        }
    };
    let icon = egui::IconData {
        rgba: icon::rgba(64, icon::Tone::On),
        width: 64,
        height: 64,
    };
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("ThinkTin")
            .with_inner_size([460.0, 680.0])
            .with_min_inner_size([380.0, 480.0])
            .with_icon(Arc::new(icon))
            .with_visible(!background),
        ..Default::default()
    };
    let result = eframe::run_native(
        "ThinkTin",
        options,
        Box::new(move |cc| Ok(Box::new(app::ThinktinApp::new(cc, backend)))),
    );
    if let Err(e) = result {
        tracing::error!(error = %e, "the window failed");
        platform::fatal(&e.to_string());
    }
}
