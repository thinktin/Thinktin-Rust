//! 托盘图标和它的菜单（Windows）。菜单：打开窗口、开始 / 停止手机控制、退出。点图标打开窗口。
//! 事件在消息循环（eframe / winit 的线程）里回调，放进通道，界面每帧取。别的系统上没有托盘，关窗口就是退出。

use std::sync::mpsc::{Receiver, channel};

use crate::icon::Tone;

/// 用户在托盘上点了什么。
#[cfg_attr(not(windows), allow(dead_code))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrayAction {
    Open,
    Toggle,
    Quit,
}

pub struct Tray {
    rx: Receiver<TrayAction>,
    #[cfg(windows)]
    inner: Option<windows::Inner>,
}

impl Tray {
    /// 建托盘；建不出来（没有托盘的环境）也能用，只是收不到事件。
    pub fn new(ctx: egui::Context, lang: crate::texts::Lang) -> Self {
        let (tx, rx) = channel();
        #[cfg(windows)]
        let inner = windows::Inner::new(tx, ctx, lang);
        #[cfg(not(windows))]
        let _ = (tx, ctx, lang);
        Self {
            rx,
            #[cfg(windows)]
            inner,
        }
    }

    pub fn present(&self) -> bool {
        #[cfg(windows)]
        {
            self.inner.is_some()
        }
        #[cfg(not(windows))]
        {
            false
        }
    }

    pub fn poll(&self) -> Vec<TrayAction> {
        self.rx.try_iter().collect()
    }

    /// 图标颜色、提示和“开始 / 停止”菜单项跟着状态变。
    pub fn set_state(&self, tone: Tone, tooltip: &str, control_on: bool) {
        #[cfg(windows)]
        if let Some(inner) = &self.inner {
            inner.set_state(tone, tooltip, control_on);
        }
        #[cfg(not(windows))]
        let _ = (tone, tooltip, control_on);
    }
}

#[cfg(windows)]
mod windows {
    use std::sync::Mutex;
    use std::sync::mpsc::Sender;

    use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
    use tray_icon::{Icon, TrayIcon, TrayIconBuilder, TrayIconEvent};

    use super::TrayAction;
    use crate::icon::{self, Tone};
    use crate::texts::{Lang, Text};

    pub struct Inner {
        tray: TrayIcon,
        toggle: MenuItem,
        lang: Lang,
        last: Mutex<Option<Tone>>,
    }

    fn icon(tone: Tone) -> Option<Icon> {
        Icon::from_rgba(icon::rgba(32, tone), 32, 32).ok()
    }

    impl Inner {
        pub fn new(tx: Sender<TrayAction>, ctx: egui::Context, lang: Lang) -> Option<Self> {
            let open = MenuItem::new(lang.t(Text::OpenWindow), true, None);
            let toggle = MenuItem::new(lang.t(Text::Start), true, None);
            let quit = MenuItem::new(lang.t(Text::Quit), true, None);
            let menu = Menu::new();
            menu.append_items(&[&open, &toggle, &PredefinedMenuItem::separator(), &quit])
                .ok()?;
            let tray = TrayIconBuilder::new()
                .with_tooltip(lang.t(Text::AppName))
                .with_icon(icon(Tone::Off)?)
                .with_menu(Box::new(menu))
                .with_menu_on_left_click(false)
                .build()
                .map_err(|e| tracing::warn!(error = %e, "no tray icon"))
                .ok()?;
            let ids = (open.id().clone(), toggle.id().clone(), quit.id().clone());
            let menu_tx = tx.clone();
            let menu_ctx = ctx.clone();
            MenuEvent::set_event_handler(Some(move |e: MenuEvent| {
                let action = if e.id == ids.0 {
                    TrayAction::Open
                } else if e.id == ids.1 {
                    TrayAction::Toggle
                } else if e.id == ids.2 {
                    TrayAction::Quit
                } else {
                    return;
                };
                let _ = menu_tx.send(action);
                menu_ctx.request_repaint();
            }));
            TrayIconEvent::set_event_handler(Some(move |e: TrayIconEvent| {
                if let TrayIconEvent::Click {
                    button: tray_icon::MouseButton::Left,
                    button_state: tray_icon::MouseButtonState::Up,
                    ..
                } = e
                {
                    let _ = tx.send(TrayAction::Open);
                    ctx.request_repaint();
                }
            }));
            Some(Self {
                tray,
                toggle,
                lang,
                last: Mutex::new(None),
            })
        }

        pub fn set_state(&self, tone: Tone, tooltip: &str, control_on: bool) {
            let mut last = self.last.lock().unwrap_or_else(|e| e.into_inner());
            if *last != Some(tone) {
                let _ = self.tray.set_icon(icon(tone));
                *last = Some(tone);
            }
            let _ = self.tray.set_tooltip(Some(tooltip));
            self.toggle.set_text(
                self.lang
                    .t(if control_on { Text::Stop } else { Text::Start }),
            );
        }
    }
}
