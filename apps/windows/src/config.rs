//! 地址和目录。接口、中继的地址编译时由 `THINKTIN_API_URL`、`THINKTIN_RELAY_URL` 定（默认正式环境），
//! 运行时同名环境变量可以临时换（联调用）。数据放在 `%LOCALAPPDATA%\Thinktin`（别的系统：`~/.local/share/thinktin`）。

use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct Config {
    pub api_url: String,
    pub relay_url: String,
    pub data_dir: PathBuf,
    pub home_dir: PathBuf,
    pub device_name: String,
    pub app_version: String,
}

const DEFAULT_API: &str = "https://api.thinktin.cn";
const DEFAULT_RELAY: &str = "wss://relay.thinktin.cn/v1/connect";

fn setting(name: &str, compiled: Option<&'static str>, default: &str) -> String {
    std::env::var(name)
        .ok()
        .filter(|v| !v.trim().is_empty())
        .or_else(|| compiled.map(str::to_owned))
        .unwrap_or_else(|| default.to_owned())
}

impl Config {
    pub fn load() -> Self {
        let home_dir = std::env::var_os("USERPROFILE")
            .or_else(|| std::env::var_os("HOME"))
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("."));
        let data_dir = std::env::var_os("LOCALAPPDATA")
            .map(|d| PathBuf::from(d).join("Thinktin"))
            .unwrap_or_else(|| home_dir.join(".local/share/thinktin"));
        let device_name = std::env::var("COMPUTERNAME")
            .or_else(|_| std::env::var("HOSTNAME"))
            .ok()
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| "Windows PC".into());
        Self {
            api_url: setting(
                "THINKTIN_API_URL",
                option_env!("THINKTIN_API_URL"),
                DEFAULT_API,
            ),
            relay_url: setting(
                "THINKTIN_RELAY_URL",
                option_env!("THINKTIN_RELAY_URL"),
                DEFAULT_RELAY,
            ),
            data_dir,
            home_dir,
            device_name: device_name.chars().take(64).collect(),
            app_version: env!("CARGO_PKG_VERSION").to_owned(),
        }
    }

    /// 这台电脑（按设备 id）的工具服务状态目录：配对的手机、能力令牌、审计日志。
    pub fn desktop_dir(&self, device_id: &str) -> PathBuf {
        self.data_dir.join("desktop").join(device_id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settings_prefer_the_environment() {
        assert_eq!(setting("THINKTIN_TEST_UNSET_XYZ", None, "d"), "d");
        assert_eq!(setting("THINKTIN_TEST_UNSET_XYZ", Some("c"), "d"), "c");
        let cfg = Config::load();
        assert!(cfg.api_url.starts_with("http"));
        assert!(cfg.relay_url.starts_with("ws"));
        assert!(cfg.desktop_dir("dev-1").ends_with("desktop/dev-1"));
    }
}
