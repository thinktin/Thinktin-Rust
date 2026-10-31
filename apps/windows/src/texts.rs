//! 界面文案：中文和英文，按系统语言选（和手机端一样只有这两种）。

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lang {
    Zh,
    En,
}

impl Lang {
    /// 按系统的界面语言：中文用中文，其余英文。
    pub fn detect() -> Self {
        if crate::platform::ui_language_is_chinese() {
            Self::Zh
        } else {
            Self::En
        }
    }

    /// 接口请求的 `Accept-Language`。
    pub fn accept_language(self) -> &'static str {
        match self {
            Self::Zh => "zh-Hans-CN, zh;q=0.9, en;q=0.8",
            Self::En => "en-US, en;q=0.9",
        }
    }

    pub fn t(self, key: Text) -> &'static str {
        let (zh, en) = key.pair();
        match self {
            Self::Zh => zh,
            Self::En => en,
        }
    }
}

/// 所有文案（有几条只有托盘用，托盘只在 Windows 上有）。
#[cfg_attr(not(windows), allow(dead_code))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Text {
    AppName,
    SignIn,
    SignInHint,
    Phone,
    PhonePlaceholder,
    SendCode,
    ResendIn,
    Code,
    CodePlaceholder,
    SignInButton,
    Working,
    SignedInAs,
    SignOut,
    ComputerControl,
    ComputerControlHint,
    StatusOffline,
    StatusConnecting,
    StatusConnected,
    StatusControlled,
    Start,
    Stop,
    StoppedReplaced,
    StoppedRefused,
    Activity,
    Phone2,
    NoPhone,
    PairedWith,
    PairPhone,
    PairHint,
    PairWaiting,
    PairExpires,
    PairPaired,
    PairFailed,
    PairAgain,
    CancelPairing,
    Unpair,
    Grants,
    NoGrants,
    GrantDirs,
    GrantApps,
    GrantExpires,
    Refresh,
    Settings,
    Autostart,
    AutostartHint,
    OpenWindow,
    Quit,
    Version,
    DataDir,
    ErrorNetwork,
    ErrorSignedOut,
    ErrorUpgrade,
    ErrorFrozen,
    CloseToTray,
    ApprovalsOnPhone,
}

impl Text {
    fn pair(self) -> (&'static str, &'static str) {
        match self {
            Self::AppName => ("ThinkTin", "ThinkTin"),
            Self::SignIn => ("登录", "Sign in"),
            Self::SignInHint => (
                "用手机号登录。登录后这台电脑会出现在手机 App 的“设备”里。",
                "Sign in with your phone number. This PC then shows up under Devices in the phone app.",
            ),
            Self::Phone => ("手机号", "Phone number"),
            Self::PhonePlaceholder => ("+86 13800000000", "+1 2025550123"),
            Self::SendCode => ("获取验证码", "Send code"),
            Self::ResendIn => ("重新发送", "Resend in"),
            Self::Code => ("验证码", "Verification code"),
            Self::CodePlaceholder => ("6 位数字", "6 digits"),
            Self::SignInButton => ("登录", "Sign in"),
            Self::Working => ("请稍候…", "Working…"),
            Self::SignedInAs => ("已登录", "Signed in as"),
            Self::SignOut => ("退出登录", "Sign out"),
            Self::ComputerControl => ("手机控制", "Phone control"),
            Self::ComputerControlHint => (
                "开着时，你的 agent 可以按手机上给的授权使用这台电脑：看文件、截图、键鼠；删除和执行命令每次都要在手机上批准。",
                "While on, your agents can use this PC within what you allow from your phone: files, screenshots, mouse and keyboard. Deleting and running commands need your approval on the phone every time.",
            ),
            Self::StatusOffline => ("未连接", "Off"),
            Self::StatusConnecting => ("正在连接…", "Connecting…"),
            Self::StatusConnected => ("已连接，等待指令", "Connected, waiting"),
            Self::StatusControlled => ("正在被控制", "Being controlled"),
            Self::Start => ("开始", "Start"),
            Self::Stop => ("停止", "Stop"),
            Self::StoppedReplaced => (
                "这台电脑在别处又连了一次（是不是开了两个 ThinkTin？），这边已停止。",
                "This PC connected again from elsewhere (two copies of ThinkTin running?), so this one stopped.",
            ),
            Self::StoppedRefused => ("服务端拒绝了这台电脑：", "The server refused this PC: "),
            Self::Activity => ("正在执行：", "Running: "),
            Self::Phone2 => ("手机", "Phone"),
            Self::NoPhone => ("还没有配对手机。", "No phone is paired yet."),
            Self::PairedWith => ("已配对手机", "Paired phone"),
            Self::PairPhone => ("配对手机", "Pair a phone"),
            Self::PairHint => (
                "在手机的 ThinkTin App 里打开“设备与账号 → 电脑 → 配对”，扫下面的二维码。",
                "In the ThinkTin phone app open Devices → Computers → Pair and scan this code.",
            ),
            Self::PairWaiting => ("等待手机扫码…", "Waiting for the phone…"),
            Self::PairExpires => ("二维码有效时间：", "Code expires in "),
            Self::PairPaired => ("配对成功。", "Paired."),
            Self::PairFailed => ("配对失败：", "Pairing failed: "),
            Self::PairAgain => ("重新出二维码", "Show a new code"),
            Self::CancelPairing => ("取消", "Cancel"),
            Self::Unpair => ("解除配对", "Unpair"),
            Self::Grants => ("手机给的授权", "Permissions from the phone"),
            Self::NoGrants => (
                "手机还没有给这台电脑任何授权。在手机 App 里选这台电脑，允许目录和应用。",
                "The phone has not allowed anything on this PC yet. Pick this PC in the phone app and allow folders and apps.",
            ),
            Self::GrantDirs => ("目录：", "Folders: "),
            Self::GrantApps => ("应用：", "Apps: "),
            Self::GrantExpires => ("到期：", "Expires: "),
            Self::Refresh => ("刷新", "Refresh"),
            Self::Settings => ("设置", "Settings"),
            Self::Autostart => ("开机时在后台启动", "Start in the background at sign-in"),
            Self::AutostartHint => (
                "登录 Windows 后自动到托盘，手机控制按上次的开关恢复。",
                "ThinkTin goes to the tray when you sign in to Windows and restores phone control as you left it.",
            ),
            Self::OpenWindow => ("打开 ThinkTin", "Open ThinkTin"),
            Self::Quit => ("退出", "Quit"),
            Self::Version => ("版本", "Version"),
            Self::DataDir => ("数据目录", "Data folder"),
            Self::ErrorNetwork => ("网络不通：", "Network problem: "),
            Self::ErrorSignedOut => (
                "登录已失效，请重新登录。",
                "You were signed out; sign in again.",
            ),
            Self::ErrorUpgrade => (
                "这个版本太旧了，请更新 ThinkTin。",
                "This version is too old; please update ThinkTin.",
            ),
            Self::ErrorFrozen => ("账号已被冻结。", "This account is frozen."),
            Self::CloseToTray => (
                "关掉窗口后 ThinkTin 留在托盘里继续工作。",
                "Closing the window keeps ThinkTin running in the tray.",
            ),
            Self::ApprovalsOnPhone => (
                "删除、执行命令的审批在手机上做。",
                "Approvals for deleting and running commands happen on the phone.",
            ),
        }
    }
}
