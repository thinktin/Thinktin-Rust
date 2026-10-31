//! 普通操作的权限：手机签发的能力令牌（见 docs/pairing.md 第 4 节）。
//!
//! 只读和普通操作（看目录、读写文件、截图、键鼠、打开网页和应用）要有一张还有效、没被吊销的令牌覆盖：
//! 文件按目录（按路径段比较，先解开符号链接），键鼠按前台应用（macOS 是 bundle id，Windows 是程序名，
//! 如 `chrome.exe`）。高危操作（删除、执行命令）不看令牌，每次都要手机签名批准（见 [`crate::Desktop`]）。

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use client_core::pairing::{CapabilityGrant, capability_allows_path};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// 配对过的手机：审批请求发给它，能力令牌和审批决定用它的公钥验。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PairedPhone {
    /// 手机的设备 id（平台上的）。
    pub device_id: String,
    /// 手机的公钥（SEC1，base64url），配对时记下的。
    pub public_key: String,
}

/// 本地保存的状态：配对的手机、收到的能力令牌、吊销过的令牌 id。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct State {
    #[serde(default)]
    pub phone: Option<PairedPhone>,
    #[serde(default)]
    pub grants: Vec<CapabilityGrant>,
    #[serde(default)]
    pub revoked: Vec<String>,
}

impl State {
    /// 收下一张验过签的令牌（同一个 id 的新令牌替换旧的；吊销过的不收）。
    pub fn add_grant(&mut self, grant: CapabilityGrant) -> bool {
        if self.revoked.contains(&grant.token_id) {
            return false;
        }
        self.grants.retain(|g| g.token_id != grant.token_id);
        self.grants.push(grant);
        true
    }

    pub fn revoke(&mut self, token_id: &str) {
        self.grants.retain(|g| g.token_id != token_id);
        if !self.revoked.iter().any(|t| t == token_id) {
            self.revoked.push(token_id.to_owned());
        }
    }

    /// 还有效的令牌：没过期、没吊销。顺带丢掉过期的。
    pub fn valid(&mut self, now: u64) -> Vec<CapabilityGrant> {
        self.grants.retain(|g| g.expires_at > now);
        let revoked: HashSet<&String> = self.revoked.iter().collect();
        self.grants
            .iter()
            .filter(|g| !revoked.contains(&g.token_id))
            .cloned()
            .collect()
    }
}

/// 一次调用要什么权限。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Need {
    /// 要有令牌覆盖这个路径（已经解开符号链接）。
    Path(PathBuf),
    /// 要有令牌覆盖这个应用（macOS 的 bundle id，Windows 的程序名）。
    App(String),
    /// 有任意一张有效的令牌就行（截图、打开网页）。
    Any,
    /// 每次都要手机签名批准。
    Approval,
}

/// 按工具和参数算出要什么权限；参数不对时返回给 agent 看的错误。
pub fn need(tool: &str, arguments: &Value, frontmost_app: Option<String>) -> Result<Need, String> {
    let path = || -> Result<Need, String> {
        let p = arguments["path"]
            .as_str()
            .ok_or_else(|| "path is required".to_owned())?;
        Ok(Need::Path(resolve(Path::new(p))?))
    };
    match tool {
        "computer_list_dir" | "computer_read_file" | "computer_write_file" => path(),
        "computer_delete" | "computer_run" => Ok(Need::Approval),
        "computer_screenshot" => Ok(Need::Any),
        "computer_click" | "computer_type" | "computer_key" => frontmost_app
            .map(Need::App)
            .ok_or_else(|| "cannot tell which app is in front".to_owned()),
        "computer_open" => {
            let target = arguments["target"]
                .as_str()
                .ok_or_else(|| "target is required".to_owned())?;
            if target.starts_with("https://") || target.starts_with("http://") {
                Ok(Need::Any)
            } else if Path::new(target).is_absolute() {
                Ok(Need::Path(resolve(Path::new(target))?))
            } else {
                Ok(Need::App(target.to_owned()))
            }
        }
        other => Err(format!("{other} is not a computer tool")),
    }
}

/// 绝对路径，解开符号链接（链接指到授权目录外面就按外面算）。还不存在的文件按它所在的目录解。
/// Windows 上去掉 `canonicalize` 加的 `\\?\` 前缀（给人看、给系统接口用的都是普通写法）。
pub fn resolve(path: &Path) -> Result<PathBuf, String> {
    if !path.is_absolute() {
        return Err(format!("{} is not an absolute path", path.display()));
    }
    if let Ok(p) = std::fs::canonicalize(path) {
        return Ok(plain(p));
    }
    let (Some(parent), Some(name)) = (path.parent(), path.file_name()) else {
        return Err(format!("{} cannot be resolved", path.display()));
    };
    let parent = std::fs::canonicalize(parent)
        .map_err(|_| format!("{} does not exist", parent.display()))?;
    Ok(plain(parent).join(name))
}

/// `\\?\C:\x` → `C:\x`，`\\?\UNC\server\share` → `\\server\share`；别的原样。
fn plain(path: PathBuf) -> PathBuf {
    #[cfg(windows)]
    {
        let s = path.to_string_lossy();
        if let Some(rest) = s.strip_prefix(r"\\?\UNC\") {
            return PathBuf::from(format!(r"\\{rest}"));
        }
        if let Some(rest) = s.strip_prefix(r"\\?\") {
            return PathBuf::from(rest);
        }
    }
    path
}

/// 有没有令牌允许。
pub fn allows(grants: &[CapabilityGrant], need: &Need) -> bool {
    match need {
        Need::Path(p) => {
            let Some(p) = p.to_str() else {
                return false;
            };
            grants
                .iter()
                .any(|g| capability_allows_path(g.clone(), p.to_owned()))
        }
        Need::App(app) => grants.iter().any(|g| g.apps.iter().any(|a| a == app)),
        Need::Any => !grants.is_empty(),
        Need::Approval => false,
    }
}

/// 没有令牌允许时告诉 agent 的话。
pub fn denied(need: &Need) -> String {
    match need {
        Need::Path(p) => format!(
            "The user has not allowed this computer to access {} from their phone; ask them to allow that folder in the ThinkTin app.",
            p.display()
        ),
        Need::App(app) => format!(
            "The user has not allowed controlling the app {app} from their phone; ask them to allow it in the ThinkTin app."
        ),
        Need::Any | Need::Approval => {
            "The user has not allowed anything on this computer yet; ask them to grant access from their phone in the ThinkTin app."
                .into()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn grant(id: &str, dirs: &[&str], apps: &[&str], expires_at: u64) -> CapabilityGrant {
        CapabilityGrant {
            desktop_id: "d1".into(),
            token_id: id.into(),
            dirs: dirs.iter().map(|d| d.to_string()).collect(),
            apps: apps.iter().map(|a| a.to_string()).collect(),
            expires_at,
        }
    }

    #[test]
    fn grants_expire_and_revoke() {
        let mut s = State::default();
        assert!(s.add_grant(grant("t1", &["/a"], &[], 100)));
        assert!(s.add_grant(grant("t2", &["/b"], &[], 50)));
        assert_eq!(s.valid(60).len(), 1);
        s.revoke("t1");
        assert!(s.valid(60).is_empty());
        // 吊销过的同一个 id 不能再收。
        assert!(!s.add_grant(grant("t1", &["/a"], &[], 100)));
        assert_eq!(s.revoked, ["t1"]);
    }

    #[test]
    fn needs_follow_the_tool() {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap();
        let file = root.join("notes.md");
        std::fs::write(&file, "x").unwrap();
        let read = need(
            "computer_read_file",
            &json!({ "path": file.to_str().unwrap() }),
            None,
        )
        .unwrap();
        assert_eq!(read, Need::Path(file.clone()));
        // 还不存在的文件按所在目录解。
        let new = root.join("new.md");
        assert_eq!(
            need(
                "computer_write_file",
                &json!({ "path": new.to_str().unwrap(), "content": "" }),
                None
            )
            .unwrap(),
            Need::Path(new)
        );
        assert!(need("computer_read_file", &json!({ "path": "relative" }), None).is_err());
        assert_eq!(
            need("computer_run", &json!({ "command": "ls" }), None).unwrap(),
            Need::Approval
        );
        assert_eq!(
            need(
                "computer_click",
                &json!({ "x": 1, "y": 2 }),
                Some("com.apple.Safari".into())
            )
            .unwrap(),
            Need::App("com.apple.Safari".into())
        );
        assert!(need("computer_type", &json!({ "text": "a" }), None).is_err());
        assert_eq!(
            need(
                "computer_open",
                &json!({ "target": "https://example.com" }),
                None
            )
            .unwrap(),
            Need::Any
        );
        assert!(need("delegate", &json!({}), None).is_err());

        let grants = [grant(
            "t",
            &[root.to_str().unwrap()],
            &["com.apple.Notes"],
            100,
        )];
        assert!(allows(&grants, &read));
        assert!(!allows(&grants, &Need::Path("/etc/passwd".into())));
        assert!(allows(&grants, &Need::App("com.apple.Notes".into())));
        assert!(!allows(&grants, &Need::App("com.apple.Terminal".into())));
        assert!(allows(&grants, &Need::Any));
        assert!(!allows(&[], &Need::Any));
        assert!(!allows(&grants, &Need::Approval));
    }

    #[cfg(unix)]
    #[test]
    fn symlinks_out_of_a_granted_folder_are_resolved() {
        let allowed = tempfile::tempdir().unwrap();
        let secret = tempfile::tempdir().unwrap();
        let target = secret.path().join("key.pem");
        std::fs::write(&target, "secret").unwrap();
        let link = allowed.path().join("innocent.txt");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        let root = std::fs::canonicalize(allowed.path()).unwrap();
        let grants = [grant("t", &[root.to_str().unwrap()], &[], 100)];
        let n = need(
            "computer_read_file",
            &json!({ "path": link.to_str().unwrap() }),
            None,
        )
        .unwrap();
        assert!(!allows(&grants, &n), "{n:?}");
    }
}
