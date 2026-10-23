//! 把当前会话记在 agent 的 HOME 里（工作区卷上），沙箱唤醒或 agent 重启后用来接回会话。

use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedSession {
    pub agent_id: String,
    pub harness: String,
    pub cwd: PathBuf,
    pub session_id: String,
}

fn path(home: &Path) -> PathBuf {
    home.join(".thinktin").join("shim-session.json")
}

pub fn load(home: &Path) -> Option<SavedSession> {
    let text = std::fs::read_to_string(path(home)).ok()?;
    match serde_json::from_str(&text) {
        Ok(saved) => Some(saved),
        Err(err) => {
            tracing::warn!("ignoring unreadable session state: {err}");
            None
        }
    }
}

pub fn save(home: &Path, saved: &SavedSession) -> io::Result<()> {
    let path = path(home);
    std::fs::create_dir_all(path.parent().expect("state path has a parent"))?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(saved)?)?;
    std::fs::rename(tmp, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(load(dir.path()), None);
        let saved = SavedSession {
            agent_id: "claude".into(),
            harness: "acp".into(),
            cwd: "/work".into(),
            session_id: "s1".into(),
        };
        save(dir.path(), &saved).unwrap();
        assert_eq!(load(dir.path()), Some(saved));
    }
}
