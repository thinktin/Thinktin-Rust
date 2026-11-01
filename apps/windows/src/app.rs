//! 窗口：没登录是登录页；登录了是“手机控制”“手机”“授权”“设置”几块。关窗口在 Windows 上是收进托盘。

use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use desktop::{PairingStatus, Status};
use egui::{Color32, RichText, TextureHandle, TextureOptions};

use crate::icon::Tone;
use crate::service::{Backend, Shared, Stopped};
use crate::texts::{Lang, Text};
use crate::tray::{Tray, TrayAction};

pub struct ThinktinApp {
    backend: Arc<Backend>,
    tray: Tray,
    lang: Lang,
    phone: String,
    code: String,
    qr: Option<(String, TextureHandle)>,
    /// 这一轮是不是用户主动要退出（托盘菜单），不是关窗口。
    quitting: bool,
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default()
}

fn expires_in(expires_at: u64) -> String {
    let left = expires_at.saturating_sub(unix_now());
    if left >= 3600 * 24 {
        format!("{}d {}h", left / (3600 * 24), left % (3600 * 24) / 3600)
    } else if left >= 3600 {
        format!("{}h {}m", left / 3600, left % 3600 / 60)
    } else {
        format!("{}:{:02}", left / 60, left % 60)
    }
}

impl ThinktinApp {
    pub fn new(cc: &eframe::CreationContext<'_>, backend: Arc<Backend>) -> Self {
        let lang = backend.lang();
        crate::fonts::install(&cc.egui_ctx);
        cc.egui_ctx.set_zoom_factor(1.1);
        backend.attach(cc.egui_ctx.clone());
        backend.resume();
        let tray = Tray::new(cc.egui_ctx.clone(), lang);
        Self {
            backend,
            tray,
            lang,
            phone: String::new(),
            code: String::new(),
            qr: None,
            quitting: false,
        }
    }

    fn t(&self, key: Text) -> &'static str {
        self.lang.t(key)
    }

    fn tone(&self, s: &Shared) -> Tone {
        match (s.status, &s.activity) {
            (Some(Status::Connected), Some(_)) => Tone::Active,
            (Some(Status::Connected), None) => Tone::On,
            _ => Tone::Off,
        }
    }

    fn status_text(&self, s: &Shared) -> &'static str {
        match (s.status, &s.activity) {
            (Some(Status::Connected), Some(_)) => self.t(Text::StatusControlled),
            (Some(Status::Connected), None) => self.t(Text::StatusConnected),
            (Some(Status::Connecting), _) => self.t(Text::StatusConnecting),
            _ => self.t(Text::StatusOffline),
        }
    }

    fn handle_tray(&mut self, ctx: &egui::Context) {
        for action in self.tray.poll() {
            match action {
                TrayAction::Open => {
                    ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
                    ctx.send_viewport_cmd(egui::ViewportCommand::Minimized(false));
                    ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
                }
                TrayAction::Toggle => {
                    if self.backend.service_running() {
                        self.backend.stop_service(true);
                    } else {
                        self.backend.start_service();
                    }
                }
                TrayAction::Quit => {
                    self.quitting = true;
                    ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                }
            }
        }
    }

    fn login_screen(&mut self, ui: &mut egui::Ui, s: &Shared) {
        ui.heading(self.t(Text::SignIn));
        ui.label(self.t(Text::SignInHint));
        ui.add_space(12.0);
        ui.label(self.t(Text::Phone));
        let hint = self.t(Text::PhonePlaceholder);
        ui.add(
            egui::TextEdit::singleline(&mut self.phone)
                .hint_text(hint)
                .desired_width(f32::INFINITY),
        );
        let resend_left = s
            .code_sent_at
            .map(|t| 60u64.saturating_sub(t.elapsed().as_secs()))
            .unwrap_or(0);
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            let can_send = !s.busy && resend_left == 0 && self.phone.trim().len() >= 5;
            let label = if resend_left > 0 {
                format!("{} {resend_left}s", self.t(Text::ResendIn))
            } else {
                self.t(Text::SendCode).to_owned()
            };
            if ui.add_enabled(can_send, egui::Button::new(label)).clicked() {
                self.backend.send_code(self.phone.clone());
            }
        });
        if resend_left > 0 {
            ui.ctx().request_repaint_after(Duration::from_secs(1));
        }
        ui.add_space(12.0);
        ui.label(self.t(Text::Code));
        let hint = self.t(Text::CodePlaceholder);
        let code = ui.add(
            egui::TextEdit::singleline(&mut self.code)
                .hint_text(hint)
                .desired_width(f32::INFINITY),
        );
        let can_login = !s.busy && self.code.trim().len() >= 4 && self.phone.trim().len() >= 5;
        let submit = code.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter));
        ui.add_space(8.0);
        if ui
            .add_enabled(can_login, egui::Button::new(self.t(Text::SignInButton)))
            .clicked()
            || (submit && can_login)
        {
            self.backend.login(self.phone.clone(), self.code.clone());
        }
        if s.busy {
            ui.add_space(4.0);
            ui.horizontal(|ui| {
                ui.spinner();
                ui.label(self.t(Text::Working));
            });
        }
    }

    fn control_section(&mut self, ui: &mut egui::Ui, s: &Shared) {
        ui.heading(self.t(Text::ComputerControl));
        ui.label(self.t(Text::ComputerControlHint));
        ui.add_space(6.0);
        let running = self.backend.service_running();
        ui.horizontal(|ui| {
            let color = match self.tone(s) {
                Tone::Off => Color32::GRAY,
                Tone::On => Color32::from_rgb(47, 111, 237),
                Tone::Active => Color32::from_rgb(240, 140, 30),
            };
            ui.label(RichText::new("●").color(color));
            ui.label(self.status_text(s));
            if running {
                if ui.button(self.t(Text::Stop)).clicked() {
                    self.backend.stop_service(true);
                }
            } else if ui.button(self.t(Text::Start)).clicked() {
                self.backend.start_service();
            }
        });
        if let Some(tool) = &s.activity {
            ui.label(format!("{}{tool}", self.t(Text::Activity)));
        }
        match &s.stopped {
            Some(Stopped::Replaced) => {
                ui.colored_label(Color32::LIGHT_RED, self.t(Text::StoppedReplaced));
            }
            Some(Stopped::Refused(detail)) => {
                ui.colored_label(
                    Color32::LIGHT_RED,
                    format!("{}{detail}", self.t(Text::StoppedRefused)),
                );
            }
            _ => {}
        }
        ui.small(self.t(Text::ApprovalsOnPhone));
    }

    fn phone_section(&mut self, ui: &mut egui::Ui, s: &Shared) {
        ui.heading(self.t(Text::Phone2));
        match &s.phone {
            Some(id) => {
                ui.label(format!("{}: {id}", self.t(Text::PairedWith)));
            }
            None => {
                ui.label(self.t(Text::NoPhone));
            }
        }
        match &s.pairing {
            Some(PairingStatus::Waiting { uri, expires_at }) => {
                ui.label(self.t(Text::PairHint));
                if self.qr.as_ref().is_none_or(|(u, _)| u != uri) {
                    match crate::qr::image(uri) {
                        Ok(img) => {
                            let tex =
                                ui.ctx()
                                    .load_texture("pair-qr", img, TextureOptions::NEAREST);
                            self.qr = Some((uri.clone(), tex));
                        }
                        Err(e) => {
                            ui.colored_label(Color32::LIGHT_RED, e);
                        }
                    }
                }
                if let Some((_, tex)) = &self.qr {
                    let side = 260.0;
                    ui.add(egui::Image::new(tex).fit_to_exact_size(egui::vec2(side, side)));
                }
                ui.horizontal(|ui| {
                    ui.spinner();
                    ui.label(format!(
                        "{}  {}{}",
                        self.t(Text::PairWaiting),
                        self.t(Text::PairExpires),
                        expires_in(*expires_at)
                    ));
                });
                ui.ctx().request_repaint_after(Duration::from_secs(1));
                if ui.button(self.t(Text::CancelPairing)).clicked() {
                    self.backend.cancel_pairing();
                    self.qr = None;
                }
            }
            Some(PairingStatus::Paired { .. }) => {
                ui.colored_label(Color32::LIGHT_GREEN, self.t(Text::PairPaired));
                self.qr = None;
                self.pair_buttons(ui, s);
            }
            Some(PairingStatus::Failed { reason }) => {
                ui.colored_label(
                    Color32::LIGHT_RED,
                    format!("{}{reason}", self.t(Text::PairFailed)),
                );
                self.qr = None;
                if ui.button(self.t(Text::PairAgain)).clicked() {
                    self.backend.start_pairing();
                }
            }
            _ => {
                self.qr = None;
                self.pair_buttons(ui, s);
            }
        }
    }

    fn pair_buttons(&mut self, ui: &mut egui::Ui, s: &Shared) {
        ui.horizontal(|ui| {
            if ui.button(self.t(Text::PairPhone)).clicked() {
                self.backend.start_pairing();
            }
            if s.phone.is_some() && ui.button(self.t(Text::Unpair)).clicked() {
                self.backend.unpair();
            }
        });
    }

    fn grants_section(&mut self, ui: &mut egui::Ui, s: &Shared) {
        ui.horizontal(|ui| {
            ui.heading(self.t(Text::Grants));
            if ui.small_button(self.t(Text::Refresh)).clicked() {
                self.backend.refresh_grants();
            }
        });
        let now = unix_now();
        let live: Vec<_> = s.grants.iter().filter(|g| g.expires_at > now).collect();
        if live.is_empty() {
            ui.label(self.t(Text::NoGrants));
            return;
        }
        for g in live {
            egui::Frame::group(ui.style()).show(ui, |ui| {
                if !g.dirs.is_empty() {
                    ui.label(format!("{}{}", self.t(Text::GrantDirs), g.dirs.join("、")));
                }
                if !g.apps.is_empty() {
                    ui.label(format!("{}{}", self.t(Text::GrantApps), g.apps.join("、")));
                }
                ui.small(format!(
                    "{}{}",
                    self.t(Text::GrantExpires),
                    expires_in(g.expires_at)
                ));
            });
        }
    }

    fn settings_section(&mut self, ui: &mut egui::Ui, s: &Shared) {
        ui.heading(self.t(Text::Settings));
        if let Some(user) = &s.user {
            ui.label(format!(
                "{}: {}",
                self.t(Text::SignedInAs),
                user.display_name
                    .clone()
                    .unwrap_or_else(|| user.phone.clone())
            ));
        }
        let mut autostart = crate::platform::autostart_enabled();
        if ui
            .checkbox(&mut autostart, self.t(Text::Autostart))
            .changed()
            && let Ok(exe) = std::env::current_exe()
            && let Err(e) = crate::platform::set_autostart(&exe, autostart)
        {
            tracing::warn!(error = %e, "autostart");
        }
        ui.small(self.t(Text::AutostartHint));
        if self.tray.present() {
            ui.small(self.t(Text::CloseToTray));
        }
        ui.add_space(6.0);
        if ui.button(self.t(Text::SignOut)).clicked() {
            self.backend.logout();
        }
        ui.add_space(6.0);
        ui.small(format!(
            "{} {}   {} {}",
            self.t(Text::Version),
            self.backend.cfg.app_version,
            self.t(Text::DataDir),
            self.backend.cfg.data_dir.display()
        ));
    }
}

impl eframe::App for ThinktinApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.handle_tray(ctx);
        // 关窗口：有托盘就藏起来继续跑；托盘菜单的“退出”才真退出。
        if ctx.input(|i| i.viewport().close_requested()) && self.tray.present() && !self.quitting {
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
            ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
        }
        let s = self.backend.snapshot();
        let tooltip = format!("ThinkTin · {}", self.status_text(&s));
        self.tray
            .set_state(self.tone(&s), &tooltip, self.backend.service_running());

        egui::CentralPanel::default().show(ctx, |ui| {
            egui::ScrollArea::vertical().show(ui, |ui| {
                ui.set_min_width(ui.available_width());
                if let Some(e) = &s.error {
                    ui.horizontal_wrapped(|ui| {
                        ui.colored_label(Color32::LIGHT_RED, e);
                        if ui.small_button("×").clicked() {
                            self.backend.clear_error();
                        }
                    });
                    ui.add_space(6.0);
                }
                if !s.signed_in() {
                    self.login_screen(ui, &s);
                    return;
                }
                self.control_section(ui, &s);
                ui.separator();
                self.phone_section(ui, &s);
                ui.separator();
                self.grants_section(ui, &s);
                ui.separator();
                self.settings_section(ui, &s);
                if s.busy {
                    ui.add_space(6.0);
                    ui.spinner();
                }
            });
        });
    }
}
