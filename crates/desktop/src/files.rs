//! 用 Rust 实现的电脑工具：看目录、读写文件、删除（挪进废纸篓）、执行命令。
//! 截图、键鼠、打开应用要用 macOS 的系统接口，由 App 实现（14.3、14.4），和这些组合起来交给 [`crate::Desktop`]。
//!
//! 权限在调用之前已经核对过（[`crate::policy`]），这里只管做事；路径一律是解开符号链接后的绝对路径。

use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

use async_trait::async_trait;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Value, json};

use crate::{ToolBackend, ToolResult};

/// 这里实现的工具。
pub const FILE_TOOLS: [&str; 5] = [
    "computer_list_dir",
    "computer_read_file",
    "computer_write_file",
    "computer_delete",
    "computer_run",
];

/// 读文件默认读多少、最多读多少。
const DEFAULT_READ: u64 = 256 << 10;
const MAX_READ: u64 = 4 << 20;
/// 一个目录最多列多少项。
const MAX_ENTRIES: usize = 1000;
/// 命令的输出每路最多留多少。
const MAX_OUTPUT: usize = 64 << 10;

pub struct FileTools {
    /// 删除的东西挪到这里（macOS 上是 `~/.Trash`）。
    pub trash: PathBuf,
    /// 命令没传 `cwd` 时在哪儿跑。
    pub home: PathBuf,
    /// 命令最多跑多久。
    pub run_timeout: Duration,
}

impl FileTools {
    /// 用户目录下的默认设置：废纸篓 `~/.Trash`，命令最多跑两分钟。
    pub fn for_home(home: impl Into<PathBuf>) -> Self {
        let home = home.into();
        Self {
            trash: home.join(".Trash"),
            home,
            run_timeout: Duration::from_secs(120),
        }
    }
}

#[async_trait]
impl ToolBackend for FileTools {
    fn available(&self) -> Vec<String> {
        FILE_TOOLS.iter().map(|t| t.to_string()).collect()
    }

    async fn call(&self, tool: &str, arguments: &Value) -> ToolResult {
        let args = arguments.clone();
        let result = match tool {
            "computer_list_dir" => blocking(move || list_dir(&args)).await,
            "computer_read_file" => blocking(move || read_file(&args)).await,
            "computer_write_file" => blocking(move || write_file(&args)).await,
            "computer_delete" => {
                let trash = self.trash.clone();
                blocking(move || delete(&args, &trash)).await
            }
            "computer_run" => self.run(arguments).await,
            other => Err(format!("{other} is not available on this computer")),
        };
        result.unwrap_or_else(ToolResult::error)
    }
}

async fn blocking(
    f: impl FnOnce() -> Result<ToolResult, String> + Send + 'static,
) -> Result<ToolResult, String> {
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|e| format!("the tool crashed: {e}"))?
}

fn path_arg(args: &Value) -> Result<PathBuf, String> {
    let p = args["path"]
        .as_str()
        .ok_or_else(|| "path is required".to_owned())?;
    crate::policy::resolve(Path::new(p))
}

fn secs(t: std::io::Result<std::time::SystemTime>) -> Option<u64> {
    t.ok()?.duration_since(UNIX_EPOCH).ok().map(|d| d.as_secs())
}

fn list_dir(args: &Value) -> Result<ToolResult, String> {
    let dir = path_arg(args)?;
    let read =
        std::fs::read_dir(&dir).map_err(|e| format!("cannot list {}: {e}", dir.display()))?;
    let mut entries = Vec::new();
    for e in read.flatten() {
        let Ok(meta) = e.path().symlink_metadata() else {
            continue;
        };
        let kind = if meta.is_dir() {
            "dir"
        } else if meta.file_type().is_symlink() {
            "link"
        } else {
            "file"
        };
        entries.push(json!({
            "name": e.file_name().to_string_lossy(),
            "kind": kind,
            "size": meta.len(),
            "modified": secs(meta.modified()),
        }));
    }
    entries.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
    let truncated = entries.len() > MAX_ENTRIES;
    entries.truncate(MAX_ENTRIES);
    let listing = json!({ "path": dir, "entries": entries, "truncated": truncated });
    Ok(ToolResult::text(
        serde_json::to_string_pretty(&listing).unwrap_or_default(),
    ))
}

fn image_type(path: &Path) -> Option<&'static str> {
    let ext = path.extension()?.to_str()?.to_ascii_lowercase();
    Some(match ext.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        _ => return None,
    })
}

fn read_file(args: &Value) -> Result<ToolResult, String> {
    let path = path_arg(args)?;
    let offset = args["offset"].as_u64().unwrap_or(0);
    let max = args["max_bytes"]
        .as_u64()
        .unwrap_or(DEFAULT_READ)
        .clamp(1, MAX_READ);
    let mut file =
        std::fs::File::open(&path).map_err(|e| format!("cannot open {}: {e}", path.display()))?;
    let size = file.metadata().map(|m| m.len()).unwrap_or(0);
    if file.metadata().is_ok_and(|m| m.is_dir()) {
        return Err(format!(
            "{} is a folder; use computer_list_dir",
            path.display()
        ));
    }
    file.seek(SeekFrom::Start(offset))
        .map_err(|e| format!("cannot seek: {e}"))?;
    let mut buf = Vec::new();
    file.take(max)
        .read_to_end(&mut buf)
        .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    let end = offset + buf.len() as u64;
    if offset == 0
        && end == size
        && let Some(mime) = image_type(&path)
    {
        return Ok(ToolResult {
            content: vec![
                json!({ "type": "image", "data": STANDARD.encode(&buf), "mimeType": mime }),
            ],
            is_error: false,
        });
    }
    // 文本：截断处可能切在一个字符中间，退回到完整的字符。
    let text = match std::str::from_utf8(&buf) {
        Ok(t) => t.to_owned(),
        Err(e) if e.error_len().is_none() && end < size => {
            std::str::from_utf8(&buf[..e.valid_up_to()])
                .unwrap_or_default()
                .to_owned()
        }
        Err(_) => {
            return Ok(ToolResult::text(format!(
                "{} is a binary file ({size} bytes); bytes {offset}..{end} in base64:\n{}",
                path.display(),
                STANDARD.encode(&buf)
            )));
        }
    };
    let read_to = offset + text.len() as u64;
    let mut out = text;
    if read_to < size {
        out.push_str(&format!(
            "\n[{} more bytes; read again with offset={read_to}]",
            size - read_to
        ));
    }
    Ok(ToolResult::text(out))
}

fn write_file(args: &Value) -> Result<ToolResult, String> {
    let path = path_arg(args)?;
    let content = args["content"]
        .as_str()
        .ok_or_else(|| "content is required".to_owned())?;
    let append = args["append"].as_bool().unwrap_or(false);
    let mut opts = std::fs::OpenOptions::new();
    opts.create(true);
    if append {
        opts.append(true);
    } else {
        opts.write(true).truncate(true);
    }
    let mut file = opts
        .open(&path)
        .map_err(|e| format!("cannot write {}: {e}", path.display()))?;
    std::io::Write::write_all(&mut file, content.as_bytes())
        .map_err(|e| format!("cannot write {}: {e}", path.display()))?;
    Ok(ToolResult::text(format!(
        "{} {} bytes to {}",
        if append { "Appended" } else { "Wrote" },
        content.len(),
        path.display()
    )))
}

fn delete(args: &Value, trash: &Path) -> Result<ToolResult, String> {
    let path = path_arg(args)?;
    if !path.exists() {
        return Err(format!("{} does not exist", path.display()));
    }
    std::fs::create_dir_all(trash).map_err(|e| format!("cannot open the Trash: {e}"))?;
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .ok_or_else(|| format!("{} cannot be deleted", path.display()))?;
    let mut target = trash.join(&name);
    let mut n = 1;
    while target.exists() {
        target = trash.join(format!("{name} {n}"));
        n += 1;
    }
    std::fs::rename(&path, &target)
        .map_err(|e| format!("cannot move {} to the Trash: {e}", path.display()))?;
    Ok(ToolResult::text(format!(
        "Moved {} to the Trash",
        path.display()
    )))
}

impl FileTools {
    async fn run(&self, args: &Value) -> Result<ToolResult, String> {
        let command = args["command"]
            .as_str()
            .ok_or_else(|| "command is required".to_owned())?;
        let cwd = match args["cwd"].as_str() {
            Some(c) => crate::policy::resolve(Path::new(c))?,
            None => self.home.clone(),
        };
        let mut cmd = tokio::process::Command::new("/bin/sh");
        cmd.arg("-c")
            .arg(command)
            .current_dir(&cwd)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);
        let child = cmd
            .spawn()
            .map_err(|e| format!("cannot run the command: {e}"))?;
        let output = match tokio::time::timeout(self.run_timeout, child.wait_with_output()).await {
            Ok(Ok(o)) => o,
            Ok(Err(e)) => return Err(format!("the command failed: {e}")),
            Err(_) => {
                return Err(format!(
                    "the command did not finish within {} seconds and was stopped",
                    self.run_timeout.as_secs()
                ));
            }
        };
        let clip = |bytes: &[u8]| {
            let text = String::from_utf8_lossy(bytes);
            if text.len() > MAX_OUTPUT {
                let mut cut = MAX_OUTPUT;
                while !text.is_char_boundary(cut) {
                    cut -= 1;
                }
                format!("{}\n[output cut]", &text[..cut])
            } else {
                text.into_owned()
            }
        };
        let code = output
            .status
            .code()
            .map_or_else(|| "killed".to_owned(), |c| c.to_string());
        Ok(ToolResult {
            content: vec![json!({
                "type": "text",
                "text": format!(
                    "exit code: {code}\n--- stdout ---\n{}\n--- stderr ---\n{}",
                    clip(&output.stdout),
                    clip(&output.stderr)
                ),
            })],
            is_error: !output.status.success(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(r: &ToolResult) -> &str {
        r.content[0]["text"].as_str().unwrap_or_default()
    }

    #[tokio::test]
    async fn files_round_trip() {
        let home = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(home.path()).unwrap();
        let tools = FileTools::for_home(&root);
        let file = root.join("notes.md");
        let p = file.to_str().unwrap();

        let w = tools
            .call(
                "computer_write_file",
                &json!({ "path": p, "content": "你好\nworld" }),
            )
            .await;
        assert!(!w.is_error, "{w:?}");
        tools
            .call(
                "computer_write_file",
                &json!({ "path": p, "content": "!", "append": true }),
            )
            .await;
        let r = tools
            .call("computer_read_file", &json!({ "path": p }))
            .await;
        assert_eq!(text(&r), "你好\nworld!");
        // 截断在一个汉字中间：退回到完整的字符，告诉 agent 从哪儿接着读。
        let r = tools
            .call("computer_read_file", &json!({ "path": p, "max_bytes": 4 }))
            .await;
        assert!(text(&r).starts_with("你\n["), "{r:?}");
        assert!(text(&r).contains("offset=3"), "{r:?}");

        std::fs::write(root.join("pic.png"), [0x89, b'P', b'N', b'G']).unwrap();
        let r = tools
            .call(
                "computer_read_file",
                &json!({ "path": root.join("pic.png").to_str().unwrap() }),
            )
            .await;
        assert_eq!(r.content[0]["type"], "image");
        assert_eq!(r.content[0]["mimeType"], "image/png");

        let l = tools
            .call(
                "computer_list_dir",
                &json!({ "path": root.to_str().unwrap() }),
            )
            .await;
        let listing: Value = serde_json::from_str(text(&l)).unwrap();
        let names: Vec<&str> = listing["entries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["name"].as_str().unwrap())
            .collect();
        assert_eq!(names, ["notes.md", "pic.png"]);

        let d = tools.call("computer_delete", &json!({ "path": p })).await;
        assert!(!d.is_error, "{d:?}");
        assert!(!file.exists());
        assert!(root.join(".Trash/notes.md").exists());
        let gone = tools
            .call("computer_read_file", &json!({ "path": p }))
            .await;
        assert!(gone.is_error);
        assert!(tools.call("computer_screenshot", &json!({})).await.is_error);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn commands_run_with_a_timeout() {
        let home = tempfile::tempdir().unwrap();
        let mut tools = FileTools::for_home(home.path());
        let r = tools
            .call(
                "computer_run",
                &json!({ "command": "echo hi; echo oops >&2; exit 3" }),
            )
            .await;
        assert!(r.is_error);
        let t = text(&r);
        assert!(t.starts_with("exit code: 3"), "{t}");
        assert!(t.contains("hi") && t.contains("oops"), "{t}");
        tools.run_timeout = Duration::from_millis(200);
        let r = tools
            .call("computer_run", &json!({ "command": "sleep 5" }))
            .await;
        assert!(r.is_error && text(&r).contains("did not finish"), "{r:?}");
    }
}
