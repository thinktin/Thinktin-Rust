//! 本地开发后端（WBS 6.3）：沙箱是本机上的一个目录加一组进程，**没有任何隔离**，只用于开发和端到端测试。
//!
//! 目录布局（`root` 下）：
//! - `sandboxes/<id>/home`：沙箱里进程的 HOME（agent 的状态目录）；
//! - `sandboxes/<id>/workspace`：指向工作区卷的符号链接，没有卷时是普通目录；
//! - `volumes/<workspace>`：工作区卷，沙箱销毁后保留；
//! - `snapshots/<id>`：快照（只有磁盘，进程不保留）。
//!
//! 暂停和恢复用 SIGSTOP、SIGCONT 停住和继续沙箱里的进程组。

use std::collections::{BTreeMap, HashMap};
use std::net::{IpAddr, Ipv4Addr};
use std::path::{Path, PathBuf};
use std::process::{ExitStatus, Stdio};
use std::sync::Mutex;

use async_trait::async_trait;

use crate::{
    CreateSpec, Error, ExecSpec, Process, ProcessControl, Result, SandboxId, SandboxInfo,
    SandboxProvider, SandboxState, SnapshotId, check_relative_path,
};

/// 默认透传给沙箱进程的宿主机环境变量（agent 要靠 PATH 找到自己的可执行文件）。
pub const DEFAULT_INHERITED_ENV: &[&str] = &["PATH", "LANG", "LC_ALL", "TERM", "TZ"];

struct Entry {
    info: SandboxInfo,
    dir: PathBuf,
    /// 在这个沙箱里启动过的进程组。
    groups: Vec<i32>,
}

pub struct LocalProvider {
    root: PathBuf,
    inherited_env: Vec<String>,
    sandboxes: Mutex<HashMap<SandboxId, Entry>>,
}

fn random_id(prefix: &str) -> String {
    let mut b = [0u8; 8];
    getrandom::fill(&mut b).expect("random bytes");
    let hex: String = b.iter().map(|x| format!("{x:02x}")).collect();
    format!("{prefix}-{hex}")
}

fn check_name(name: &str) -> Result<()> {
    if name.is_empty()
        || name.len() > 128
        || !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
        || name.starts_with('.')
    {
        return Err(Error::Invalid(format!("bad name {name:?}")));
    }
    Ok(())
}

/// 进程组还在不在。
fn group_alive(pgid: i32) -> bool {
    // SAFETY: killpg 只读参数；信号 0 只做存在性检查。
    unsafe { libc::killpg(pgid, 0) == 0 }
}

fn signal_groups(groups: &[i32], signal: i32) {
    for &pgid in groups {
        if group_alive(pgid) {
            // SAFETY: 同上；目标是本后端自己启动的进程组。
            unsafe {
                libc::killpg(pgid, signal);
            }
        }
    }
}

fn copy_tree(from: &Path, to: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(to)?;
    for entry in std::fs::read_dir(from)? {
        let entry = entry?;
        let ty = entry.file_type()?;
        let dest = to.join(entry.file_name());
        if ty.is_dir() {
            copy_tree(&entry.path(), &dest)?;
        } else if ty.is_file() {
            std::fs::copy(entry.path(), &dest)?;
        } else if ty.is_symlink() {
            // 快照里不跟随符号链接（可能指向沙箱外），只复制链接本身。
            let target = std::fs::read_link(entry.path())?;
            let _ = std::fs::remove_file(&dest);
            std::os::unix::fs::symlink(target, &dest)?;
        }
    }
    Ok(())
}

impl LocalProvider {
    pub fn new(root: impl Into<PathBuf>) -> std::io::Result<Self> {
        let root = root.into();
        for sub in ["sandboxes", "volumes", "snapshots"] {
            std::fs::create_dir_all(root.join(sub))?;
        }
        Ok(Self {
            root: root.canonicalize()?,
            inherited_env: DEFAULT_INHERITED_ENV
                .iter()
                .map(|s| s.to_string())
                .collect(),
            sandboxes: Mutex::default(),
        })
    }

    /// 改写透传的宿主机环境变量。
    pub fn with_inherited_env(
        mut self,
        names: impl IntoIterator<Item = impl Into<String>>,
    ) -> Self {
        self.inherited_env = names.into_iter().map(Into::into).collect();
        self
    }

    /// 沙箱目录在宿主机上的位置（测试和调试用）。
    pub fn sandbox_dir(&self, id: &SandboxId) -> Option<PathBuf> {
        self.lock().get(id).map(|e| e.dir.clone())
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<SandboxId, Entry>> {
        self.sandboxes.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn volume_dir(&self, workspace: &str) -> Result<PathBuf> {
        check_name(workspace)?;
        Ok(self.root.join("volumes").join(workspace))
    }

    fn running_dir(&self, id: &SandboxId) -> Result<PathBuf> {
        let map = self.lock();
        let e = map.get(id).ok_or_else(|| Error::NotFound(id.clone()))?;
        if e.info.state != SandboxState::Running {
            return Err(Error::InvalidState {
                id: id.clone(),
                expected: SandboxState::Running,
                actual: e.info.state,
            });
        }
        Ok(e.dir.clone())
    }

    /// 把沙箱里的相对路径解析到宿主机路径，并确认没有经符号链接跳出沙箱目录和工作区卷。
    fn resolve(&self, dir: &Path, path: &str, for_write: bool) -> Result<PathBuf> {
        check_relative_path(path)?;
        let full = dir.join(path);
        let probe = if for_write {
            let parent = full.parent().ok_or_else(|| Error::Invalid(path.into()))?;
            std::fs::create_dir_all(parent)?;
            parent.canonicalize()?
        } else {
            full.canonicalize()?
        };
        let volumes = self.root.join("volumes");
        if !(probe.starts_with(dir) || probe.starts_with(&volumes)) {
            return Err(Error::Invalid(format!("{path:?} escapes the sandbox")));
        }
        Ok(if for_write {
            probe.join(full.file_name().unwrap())
        } else {
            probe
        })
    }

    fn materialize(&self, spec: &CreateSpec) -> Result<(SandboxId, PathBuf)> {
        let id = SandboxId(random_id("sbx"));
        let dir = self.root.join("sandboxes").join(&id.0);
        std::fs::create_dir_all(dir.join("home"))?;
        match &spec.workspace {
            Some(ws) => {
                let vol = self.volume_dir(ws)?;
                std::fs::create_dir_all(&vol)?;
                std::os::unix::fs::symlink(&vol, dir.join("workspace"))?;
            }
            None => std::fs::create_dir_all(dir.join("workspace"))?,
        }
        Ok((id, dir))
    }

    fn register(&self, id: SandboxId, dir: PathBuf, spec: CreateSpec) -> SandboxInfo {
        let info = SandboxInfo {
            id: id.clone(),
            template: spec.template,
            workspace: spec.workspace,
            state: SandboxState::Running,
            address: Some(IpAddr::V4(Ipv4Addr::LOCALHOST)),
            metadata: spec.metadata,
        };
        self.lock().insert(
            id,
            Entry {
                info: info.clone(),
                dir,
                groups: Vec::new(),
            },
        );
        info
    }
}

struct LocalControl {
    child: tokio::process::Child,
    pgid: i32,
}

#[async_trait]
impl ProcessControl for LocalControl {
    async fn wait(&mut self) -> Result<ExitStatus> {
        Ok(self.child.wait().await?)
    }

    async fn kill(&mut self) -> Result<()> {
        signal_groups(&[self.pgid], libc::SIGKILL);
        let _ = self.child.wait().await;
        Ok(())
    }
}

#[async_trait]
impl SandboxProvider for LocalProvider {
    fn name(&self) -> &'static str {
        "local"
    }

    async fn create(&self, spec: CreateSpec) -> Result<SandboxInfo> {
        if spec.template.is_empty() {
            return Err(Error::Invalid("template is required".into()));
        }
        let (id, dir) = self.materialize(&spec)?;
        Ok(self.register(id, dir, spec))
    }

    async fn get(&self, id: &SandboxId) -> Result<Option<SandboxInfo>> {
        Ok(self.lock().get(id).map(|e| e.info.clone()))
    }

    async fn exec(&self, id: &SandboxId, spec: ExecSpec) -> Result<Process> {
        let dir = self.running_dir(id)?;
        let (program, args) = spec
            .argv
            .split_first()
            .ok_or_else(|| Error::Invalid("argv is empty".into()))?;
        let cwd = match &spec.cwd {
            Some(rel) => self.resolve(&dir, rel, false)?,
            None => dir.join("workspace"),
        };
        let mut cmd = tokio::process::Command::new(program);
        cmd.args(args)
            .env_clear()
            .current_dir(cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0)
            .kill_on_drop(true);
        for name in &self.inherited_env {
            if let Ok(v) = std::env::var(name) {
                cmd.env(name, v);
            }
        }
        cmd.env("HOME", dir.join("home"));
        for (k, v) in &spec.env {
            cmd.env(k, v.expose());
        }
        let mut child = cmd.spawn()?;
        let pgid = child
            .id()
            .map(|p| p as i32)
            .ok_or_else(|| Error::Provider("process exited at once".into()))?;
        {
            let mut map = self.lock();
            match map.get_mut(id) {
                Some(e) => {
                    e.groups.retain(|&g| group_alive(g));
                    e.groups.push(pgid);
                }
                None => {
                    signal_groups(&[pgid], libc::SIGKILL);
                    return Err(Error::NotFound(id.clone()));
                }
            }
        }
        Ok(Process {
            stdin: Box::new(child.stdin.take().expect("piped stdin")),
            stdout: Box::new(child.stdout.take().expect("piped stdout")),
            stderr: Box::new(child.stderr.take().expect("piped stderr")),
            control: Box::new(LocalControl { child, pgid }),
        })
    }

    async fn pause(&self, id: &SandboxId) -> Result<()> {
        let mut map = self.lock();
        let e = map.get_mut(id).ok_or_else(|| Error::NotFound(id.clone()))?;
        if e.info.state == SandboxState::Paused {
            return Ok(());
        }
        signal_groups(&e.groups, libc::SIGSTOP);
        e.info.state = SandboxState::Paused;
        Ok(())
    }

    async fn resume(&self, id: &SandboxId) -> Result<SandboxInfo> {
        let mut map = self.lock();
        let e = map.get_mut(id).ok_or_else(|| Error::NotFound(id.clone()))?;
        if e.info.state == SandboxState::Paused {
            signal_groups(&e.groups, libc::SIGCONT);
            e.info.state = SandboxState::Running;
        }
        Ok(e.info.clone())
    }

    async fn snapshot(&self, id: &SandboxId) -> Result<SnapshotId> {
        let (dir, workspace) = {
            let map = self.lock();
            let e = map.get(id).ok_or_else(|| Error::NotFound(id.clone()))?;
            (e.dir.clone(), e.info.workspace.clone())
        };
        let snap = SnapshotId(random_id("snap"));
        let dest = self.root.join("snapshots").join(&snap.0);
        let ws_src = match &workspace {
            Some(ws) => self.volume_dir(ws)?,
            None => dir.join("workspace"),
        };
        tokio::task::spawn_blocking(move || -> std::io::Result<()> {
            copy_tree(&dir.join("home"), &dest.join("home"))?;
            copy_tree(&ws_src, &dest.join("workspace"))
        })
        .await
        .map_err(|e| Error::Provider(e.to_string()))??;
        Ok(snap)
    }

    async fn restore(&self, snapshot: &SnapshotId, spec: CreateSpec) -> Result<SandboxInfo> {
        check_name(&snapshot.0)?;
        let src = self.root.join("snapshots").join(&snapshot.0);
        if !src.is_dir() {
            return Err(Error::SnapshotNotFound(snapshot.clone()));
        }
        let (id, dir) = self.materialize(&spec)?;
        let ws_dest = match &spec.workspace {
            Some(ws) => self.volume_dir(ws)?,
            None => dir.join("workspace"),
        };
        let home_dest = dir.join("home");
        tokio::task::spawn_blocking(move || -> std::io::Result<()> {
            copy_tree(&src.join("home"), &home_dest)?;
            copy_tree(&src.join("workspace"), &ws_dest)
        })
        .await
        .map_err(|e| Error::Provider(e.to_string()))??;
        Ok(self.register(id, dir, spec))
    }

    async fn destroy(&self, id: &SandboxId) -> Result<()> {
        let Some(entry) = self.lock().remove(id) else {
            return Ok(());
        };
        // SIGKILL 对停住的进程同样有效。
        signal_groups(&entry.groups, libc::SIGKILL);
        let dir = entry.dir;
        tokio::task::spawn_blocking(move || std::fs::remove_dir_all(dir))
            .await
            .map_err(|e| Error::Provider(e.to_string()))??;
        Ok(())
    }

    async fn delete_workspace(&self, workspace: &str) -> Result<()> {
        let vol = self.volume_dir(workspace)?;
        if vol.exists() {
            tokio::task::spawn_blocking(move || std::fs::remove_dir_all(vol))
                .await
                .map_err(|e| Error::Provider(e.to_string()))??;
        }
        Ok(())
    }

    async fn write_file(&self, id: &SandboxId, path: &str, data: &[u8]) -> Result<()> {
        let dir = self.running_dir(id)?;
        let full = self.resolve(&dir, path, true)?;
        let data = data.to_vec();
        // 最后一段如果是符号链接（agent 可能建一个指向沙箱外的链接），拒绝写入，不跟过去。
        tokio::task::spawn_blocking(move || -> std::io::Result<()> {
            use std::io::Write;
            use std::os::unix::fs::OpenOptionsExt;
            let mut f = std::fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .custom_flags(libc::O_NOFOLLOW)
                .open(full)?;
            f.write_all(&data)
        })
        .await
        .map_err(|e| Error::Provider(e.to_string()))??;
        Ok(())
    }

    async fn read_file(&self, id: &SandboxId, path: &str, max: u64) -> Result<Vec<u8>> {
        use tokio::io::AsyncReadExt;
        let dir = self.running_dir(id)?;
        let full = self.resolve(&dir, path, false)?;
        let file = tokio::fs::File::open(full).await?;
        let too_large = || Error::Invalid(format!("{path} is larger than {max} bytes"));
        if file.metadata().await?.len() > max {
            return Err(too_large());
        }
        // 读的时候文件可能还在变大：最多读 max + 1 字节来判断。
        let mut data = Vec::new();
        file.take(max.saturating_add(1))
            .read_to_end(&mut data)
            .await?;
        if data.len() as u64 > max {
            return Err(too_large());
        }
        Ok(data)
    }
}

/// 只给测试用：列出沙箱的元数据。
impl LocalProvider {
    pub fn list(&self) -> Vec<SandboxInfo> {
        let mut v: Vec<_> = self.lock().values().map(|e| e.info.clone()).collect();
        v.sort_by(|a, b| a.id.cmp(&b.id));
        v
    }

    pub fn metadata_of(&self, id: &SandboxId) -> Option<BTreeMap<String, String>> {
        self.lock().get(id).map(|e| e.info.metadata.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::EnvValue;
    use std::time::Duration;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    fn spec(ws: Option<&str>) -> CreateSpec {
        CreateSpec {
            template: "test@1".into(),
            workspace: ws.map(Into::into),
            ..CreateSpec::default()
        }
    }

    fn sh(script: &str) -> ExecSpec {
        ExecSpec {
            argv: vec!["sh".into(), "-c".into(), script.into()],
            ..ExecSpec::default()
        }
    }

    #[tokio::test]
    async fn exec_talks_over_stdio_with_clean_env() {
        let dir = tempfile::tempdir().unwrap();
        let p = LocalProvider::new(dir.path()).unwrap();
        let info = p.create(spec(Some("ws1"))).await.unwrap();
        assert_eq!(info.state, SandboxState::Running);
        assert_eq!(info.address, Some(IpAddr::V4(Ipv4Addr::LOCALHOST)));

        let mut es = sh(
            r#"echo "home=$HOME secret=$TOKEN other=${CARGO:-unset}"; read line; echo "got $line"; pwd"#,
        );
        es.env
            .insert("TOKEN".into(), EnvValue::Secret("s3cr3t".into()));
        let mut proc = p.exec(&info.id, es).await.unwrap();
        let mut out = BufReader::new(proc.stdout).lines();
        let first = out.next_line().await.unwrap().unwrap();
        assert!(
            first.ends_with("/home secret=s3cr3t other=unset"),
            "{first}"
        );
        proc.stdin.write_all(b"ping\n").await.unwrap();
        assert_eq!(out.next_line().await.unwrap().unwrap(), "got ping");
        let cwd = out.next_line().await.unwrap().unwrap();
        assert!(cwd.ends_with("/volumes/ws1"), "{cwd}");
        assert!(proc.control.wait().await.unwrap().success());
    }

    #[tokio::test]
    async fn pause_resume_and_destroy() {
        let dir = tempfile::tempdir().unwrap();
        let p = LocalProvider::new(dir.path()).unwrap();
        let info = p.create(spec(None)).await.unwrap();
        let proc = p
            .exec(&info.id, sh("while true; do echo tick; sleep 0.05; done"))
            .await
            .unwrap();
        let mut out = BufReader::new(proc.stdout).lines();
        out.next_line().await.unwrap().unwrap();

        p.pause(&info.id).await.unwrap();
        p.pause(&info.id).await.unwrap(); // 幂等
        assert_eq!(
            p.get(&info.id).await.unwrap().unwrap().state,
            SandboxState::Paused
        );
        assert!(matches!(
            p.exec(&info.id, sh("true")).await,
            Err(Error::InvalidState { .. })
        ));
        // 暂停期间不再有输出（先读掉管道里已有的）。
        while tokio::time::timeout(Duration::from_millis(100), out.next_line())
            .await
            .is_ok()
        {}
        assert!(
            tokio::time::timeout(Duration::from_millis(300), out.next_line())
                .await
                .is_err()
        );

        p.resume(&info.id).await.unwrap();
        let line = tokio::time::timeout(Duration::from_secs(2), out.next_line())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(line.as_deref(), Some("tick"));

        let sbx_dir = p.sandbox_dir(&info.id).unwrap();
        p.destroy(&info.id).await.unwrap();
        p.destroy(&info.id).await.unwrap(); // 幂等
        assert!(!sbx_dir.exists());
        let eof = tokio::time::timeout(Duration::from_secs(2), async {
            while let Ok(Some(_)) = out.next_line().await {}
        })
        .await;
        assert!(eof.is_ok(), "processes are killed on destroy");
        assert!(p.get(&info.id).await.unwrap().is_none());
    }

    #[tokio::test]
    async fn snapshot_restore_and_workspace_survives_destroy() {
        let dir = tempfile::tempdir().unwrap();
        let p = LocalProvider::new(dir.path()).unwrap();
        let a = p.create(spec(Some("inst-1"))).await.unwrap();
        p.write_file(&a.id, "workspace/notes/plan.md", b"step 1")
            .await
            .unwrap();
        p.write_file(&a.id, "home/.agent/state.json", b"{}")
            .await
            .unwrap();
        let snap = p.snapshot(&a.id).await.unwrap();
        p.write_file(&a.id, "workspace/notes/plan.md", b"step 2")
            .await
            .unwrap();
        p.destroy(&a.id).await.unwrap();

        // 工作区卷在沙箱销毁后还在：新沙箱挂回同一块卷能读到最新内容。
        let b = p.create(spec(Some("inst-1"))).await.unwrap();
        assert_eq!(
            p.read_file(&b.id, "workspace/notes/plan.md", u64::MAX)
                .await
                .unwrap(),
            b"step 2"
        );
        assert!(
            p.read_file(&b.id, "home/.agent/state.json", u64::MAX)
                .await
                .is_err()
        );
        p.destroy(&b.id).await.unwrap();

        // 从快照恢复到另一块卷：回到快照时的状态。
        let c = p
            .restore(&snap, spec(Some("inst-1-restored")))
            .await
            .unwrap();
        assert_eq!(
            p.read_file(&c.id, "workspace/notes/plan.md", u64::MAX)
                .await
                .unwrap(),
            b"step 1"
        );
        assert_eq!(
            p.read_file(&c.id, "home/.agent/state.json", u64::MAX)
                .await
                .unwrap(),
            b"{}"
        );
        assert!(matches!(
            p.restore(&SnapshotId("snap-nope".into()), spec(None)).await,
            Err(Error::SnapshotNotFound(_))
        ));

        p.delete_workspace("inst-1").await.unwrap();
        assert!(!dir.path().join("volumes/inst-1").exists());
    }

    #[tokio::test]
    async fn file_access_cannot_escape() {
        let dir = tempfile::tempdir().unwrap();
        let outside = dir.path().join("outside.txt");
        std::fs::write(&outside, "host secret").unwrap();
        let p = LocalProvider::new(dir.path().join("root")).unwrap();
        let s = p.create(spec(Some("w"))).await.unwrap();
        for bad in [
            "../outside.txt",
            "/etc/passwd",
            "workspace/../../../outside.txt",
        ] {
            assert!(p.read_file(&s.id, bad, u64::MAX).await.is_err(), "{bad}");
        }
        // agent 在工作区里建了指向外面的符号链接，平台读文件时不跟过去。
        let mut proc = p
            .exec(&s.id, sh(&format!("ln -s {} link.txt", outside.display())))
            .await
            .unwrap();
        assert!(proc.control.wait().await.unwrap().success());
        assert!(
            p.read_file(&s.id, "workspace/link.txt", u64::MAX)
                .await
                .is_err()
        );
        // 超过上限的文件不读进内存，直接拒绝。
        p.write_file(&s.id, "workspace/big.bin", &[7; 100])
            .await
            .unwrap();
        assert!(matches!(
            p.read_file(&s.id, "workspace/big.bin", 99).await,
            Err(Error::Invalid(_))
        ));
        assert_eq!(
            p.read_file(&s.id, "workspace/big.bin", 100)
                .await
                .unwrap()
                .len(),
            100
        );
        assert!(
            p.write_file(&s.id, "workspace/link.txt", b"x")
                .await
                .is_err()
        );
        assert_eq!(std::fs::read_to_string(&outside).unwrap(), "host secret");
        assert!(
            LocalProvider::new(dir.path().join("root"))
                .unwrap()
                .volume_dir("../x")
                .is_err()
        );
    }
}
