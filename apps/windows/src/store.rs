//! 本机保存的东西：登录会话（刷新令牌等同于密码）、电脑的配对私钥、手机控制的开关。
//! 一个文件 `state.bin`，内容是 JSON 经 DPAPI 加密（Windows），只有这个用户在这台电脑上能解；
//! 别的系统上是明文（开发用）。给 client-core 当 [`SessionStore`]。

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use client_core::api::{Session, SessionStore};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Saved {
    #[serde(default)]
    pub session: Option<Session>,
    /// 配对私钥（P-256，32 字节，base64）。一台电脑一把，换账号也用它。
    #[serde(default)]
    pub pairing_key: Option<String>,
    /// 用户上次把手机控制开着（按设备 id 记，重新登录是新设备）。
    #[serde(default)]
    pub control_on: Vec<String>,
}

pub struct LocalStore {
    path: PathBuf,
    saved: Mutex<Saved>,
}

impl LocalStore {
    /// 读 `<data_dir>/state.bin`；读不出来（没有、坏了、别的用户的）按空的算。
    pub fn open(data_dir: &Path) -> Self {
        let path = data_dir.join("state.bin");
        let saved = std::fs::read(&path)
            .ok()
            .and_then(|blob| crate::platform::unprotect(&blob).ok())
            .and_then(|json| serde_json::from_slice(&json).ok())
            .unwrap_or_default();
        Self {
            path,
            saved: Mutex::new(saved),
        }
    }

    fn write(&self, saved: &Saved) {
        let result = (|| -> Result<(), String> {
            if let Some(dir) = self.path.parent() {
                std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
            }
            let json = serde_json::to_vec(saved).map_err(|e| e.to_string())?;
            let blob = crate::platform::protect(&json)?;
            let tmp = self.path.with_extension("tmp");
            std::fs::write(&tmp, blob).map_err(|e| e.to_string())?;
            std::fs::rename(&tmp, &self.path).map_err(|e| e.to_string())
        })();
        if let Err(e) = result {
            tracing::error!(error = %e, path = %self.path.display(), "cannot save local state");
        }
    }

    fn update(&self, f: impl FnOnce(&mut Saved)) {
        let mut saved = self.saved.lock().unwrap_or_else(|e| e.into_inner());
        f(&mut saved);
        self.write(&saved);
    }

    pub fn snapshot(&self) -> Saved {
        self.saved.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// 配对私钥；没有就生成一把存起来。
    pub fn pairing_key(&self) -> Result<desktop::SoftwareKey, String> {
        use base64::Engine;
        let b64 = base64::engine::general_purpose::STANDARD;
        let existing = self.snapshot().pairing_key;
        if let Some(encoded) = existing
            && let Ok(bytes) = b64.decode(encoded)
            && let Ok(key) = desktop::SoftwareKey::from_bytes(&bytes)
        {
            return Ok(key);
        }
        let mut bytes = [0u8; 32];
        let key = loop {
            getrandom::fill(&mut bytes).map_err(|e| e.to_string())?;
            if let Ok(key) = desktop::SoftwareKey::from_bytes(&bytes) {
                break key;
            }
        };
        self.update(|s| s.pairing_key = Some(b64.encode(bytes)));
        Ok(key)
    }

    pub fn control_on(&self, device_id: &str) -> bool {
        self.snapshot().control_on.iter().any(|d| d == device_id)
    }

    pub fn set_control_on(&self, device_id: &str, on: bool) {
        self.update(|s| {
            s.control_on.retain(|d| d != device_id);
            if on {
                s.control_on.push(device_id.to_owned());
            }
        });
    }
}

impl SessionStore for LocalStore {
    fn load(&self) -> Option<Session> {
        self.snapshot().session
    }

    fn save(&self, session: Option<Session>) {
        self.update(|s| s.session = session);
    }
}

#[cfg(test)]
mod tests {
    use desktop::PairingKey;

    use super::*;

    #[test]
    fn state_round_trips_through_the_file() {
        let dir = tempfile::tempdir().unwrap();
        let store = LocalStore::open(dir.path());
        assert!(store.load().is_none());
        let key = store.pairing_key().unwrap();
        store.save(Some(Session {
            user_id: "u".into(),
            device_id: "d".into(),
            access_token: "a".into(),
            refresh_token: "r".into(),
        }));
        store.set_control_on("d", true);

        let again = LocalStore::open(dir.path());
        assert_eq!(again.load().map(|s| s.device_id), Some("d".to_owned()));
        assert!(again.control_on("d"));
        assert!(!again.control_on("x"));
        assert_eq!(again.pairing_key().unwrap().public_key(), key.public_key());
        again.set_control_on("d", false);
        again.save(None);
        let third = LocalStore::open(dir.path());
        assert!(third.load().is_none());
        assert!(!third.control_on("d"));
        // 坏文件按空的算。
        std::fs::write(dir.path().join("state.bin"), b"garbage").unwrap();
        assert!(LocalStore::open(dir.path()).load().is_none());
    }
}
