//! 本地审计日志（架构方案第 7 节“可见可控”）：电脑上每个工具调用一行 JSON（JSON Lines），
//! 记时间、调用、发起的运行、工具、参数的摘要（不记参数原文：里面可能有文件内容）、
//! 权限的结论和执行结果。macOS App 可以把它展示给用户看。

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::Path;
use std::sync::Mutex;

use serde::Serialize;

/// 权限的结论。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Decision {
    /// 能力令牌允许。
    Allowed,
    /// 没有令牌允许，或者参数不对。
    Denied,
    /// 用户在手机上签名批准了。
    Approved,
    /// 用户拒绝了、没按时批准，或者签名验不过。
    Declined,
}

#[derive(Debug, Clone, Serialize)]
pub struct Entry {
    /// Unix 秒。
    pub at: u64,
    pub call: String,
    pub run: Option<String>,
    pub tool: String,
    /// 参数规范化后的 SHA-256（和审批签的是同一个摘要）。
    pub arguments_digest: String,
    pub decision: Decision,
    /// 执行了的话，工具有没有报错。
    pub ok: Option<bool>,
    /// 没执行的原因，或者工具的错误。
    pub detail: Option<String>,
}

pub struct Audit {
    file: Mutex<File>,
}

impl Audit {
    pub fn open(path: &Path) -> std::io::Result<Self> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let file = OpenOptions::new().create(true).append(true).open(path)?;
        Ok(Self {
            file: Mutex::new(file),
        })
    }

    /// 记一行。写不进去只记日志，不影响调用。
    pub fn record(&self, entry: &Entry) {
        let Ok(mut line) = serde_json::to_vec(entry) else {
            return;
        };
        line.push(b'\n');
        let mut file = self.file.lock().unwrap_or_else(|e| e.into_inner());
        if let Err(e) = file.write_all(&line).and_then(|()| file.flush()) {
            tracing::warn!(error = %e, "cannot write the audit log");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entries_are_json_lines() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("logs/audit.jsonl");
        let audit = Audit::open(&path).unwrap();
        for (i, decision) in [Decision::Allowed, Decision::Declined]
            .into_iter()
            .enumerate()
        {
            audit.record(&Entry {
                at: 1,
                call: format!("c{i}"),
                run: None,
                tool: "computer_run".into(),
                arguments_digest: "ab".into(),
                decision,
                ok: None,
                detail: Some("declined".into()),
            });
        }
        let text = std::fs::read_to_string(&path).unwrap();
        let lines: Vec<serde_json::Value> = text
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[1]["decision"], "declined");
        assert_eq!(lines[0]["call"], "c0");
    }
}
