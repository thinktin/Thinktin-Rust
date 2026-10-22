//! `thinktin-vault`（WBS 9.11）：在沙箱里按名字把保险箱里的值注入命令，值不经过 agent 的上下文。
//!
//! ```text
//! thinktin-vault exec --env GH_TOKEN=github -- gh repo list
//! thinktin-vault exec --stdin db.password -- psql -U app -W
//! thinktin-vault exec -- curl -u '{{mail.username}}:{{mail.password}}' https://mail.example.com
//! ```
//!
//! 引用写成 `名字` 或 `名字.字段`，字段是 `password`（默认）或 `username`。助手连 shim 的工具桥 socket
//! 要值（平台按这一轮的授权和实例核对、记审计），设好环境变量、替换参数后执行命令，退出码照传。
//! 值不打印；agent 把它打印出来也没用：运行日志落盘前、模型网关转发前都会抹掉。

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use anyhow::{Context, bail};
use serde_json::{Value, json};
use zeroize::Zeroizing;

/// 沙箱里给 agent 用的命令名。
pub const COMMAND: &str = "thinktin-vault";

/// 引用：`名字` 或 `名字.字段`。
pub fn valid_ref(r: &str) -> bool {
    let (name, field) = match r.split_once('.') {
        Some((n, f)) => (n, f),
        None => (r, "password"),
    };
    proto::domain::valid_vault_name(name) && matches!(field, "password" | "username")
}

fn valid_env_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// 参数的一段：原样的文字或者 `{{引用}}`。
#[derive(Debug, PartialEq)]
enum Piece<'a> {
    Text(&'a str),
    Ref(&'a str),
}

/// 把参数拆成文字和 `{{引用}}`。不是合法引用的 `{{…}}` 原样保留。
fn pieces(arg: &str) -> Vec<Piece<'_>> {
    let mut out = Vec::new();
    let mut rest = arg;
    while let Some(open) = rest.find("{{") {
        let after = &rest[open + 2..];
        let Some(close) = after.find("}}") else {
            break;
        };
        let inner = &after[..close];
        if valid_ref(inner) {
            if open > 0 {
                out.push(Piece::Text(&rest[..open]));
            }
            out.push(Piece::Ref(inner));
        } else {
            out.push(Piece::Text(&rest[..open + 2 + close + 2]));
        }
        rest = &after[close + 2..];
    }
    if !rest.is_empty() {
        out.push(Piece::Text(rest));
    }
    out
}

/// 要注入的东西：环境变量、标准输入、参数里的引用。
#[derive(Debug, PartialEq)]
pub struct Plan {
    env: Vec<(String, String)>,
    stdin: Option<String>,
    command: Vec<String>,
    /// 去重后的全部引用（按出现顺序），一次向平台要。
    refs: Vec<String>,
}

impl Plan {
    pub fn parse(env: &[String], stdin: Option<&str>, command: &[String]) -> anyhow::Result<Self> {
        if command.is_empty() {
            bail!("give the command after --");
        }
        let mut refs: Vec<String> = Vec::new();
        let mut add = |r: &str| {
            if !refs.iter().any(|x| x == r) {
                refs.push(r.to_owned());
            }
        };
        let mut pairs = Vec::new();
        for e in env {
            let (var, r) = e
                .split_once('=')
                .with_context(|| format!("--env takes VAR=REF, got {e:?}"))?;
            if !valid_env_name(var) {
                bail!("{var:?} is not a valid environment variable name");
            }
            if !valid_ref(r) {
                bail!("{r:?} is not a vault reference (name or name.username / name.password)");
            }
            add(r);
            pairs.push((var.to_owned(), r.to_owned()));
        }
        if let Some(r) = stdin {
            if !valid_ref(r) {
                bail!("{r:?} is not a vault reference (name or name.username / name.password)");
            }
            add(r);
        }
        for arg in command {
            for p in pieces(arg) {
                if let Piece::Ref(r) = p {
                    add(r);
                }
            }
        }
        if refs.is_empty() {
            bail!(
                "nothing to inject: use --env VAR=NAME, --stdin NAME or {{{{NAME}}}} in the command"
            );
        }
        Ok(Self {
            env: pairs,
            stdin: stdin.map(str::to_owned),
            command: command.to_vec(),
            refs,
        })
    }

    fn value<'v>(&self, values: &'v [Zeroizing<String>], r: &str) -> &'v str {
        let i = self
            .refs
            .iter()
            .position(|x| x == r)
            .expect("every reference was collected");
        values[i].as_str()
    }

    /// 参数里的引用换成值。
    fn args(&self, values: &[Zeroizing<String>]) -> Vec<Zeroizing<String>> {
        self.command
            .iter()
            .map(|arg| {
                let mut out = Zeroizing::new(String::with_capacity(arg.len()));
                for p in pieces(arg) {
                    match p {
                        Piece::Text(t) => out.push_str(t),
                        Piece::Ref(r) => out.push_str(self.value(values, r)),
                    }
                }
                out
            })
            .collect()
    }
}

/// 向 shim 要值：每个引用一个值，顺序相同。
fn reveal(socket: &Path, refs: &[String]) -> anyhow::Result<Vec<Zeroizing<String>>> {
    let mut stream = UnixStream::connect(socket)
        .with_context(|| format!("connecting to the agent-shim at {}", socket.display()))?;
    stream.set_read_timeout(Some(Duration::from_secs(900)))?;
    let mut line = json!({"id": 1, "op": "reveal", "refs": refs}).to_string();
    line.push('\n');
    stream.write_all(line.as_bytes())?;
    let mut reader = BufReader::new(stream);
    loop {
        let mut buf = Zeroizing::new(String::new());
        if reader.read_line(&mut buf)? == 0 {
            bail!("the agent-shim closed the connection");
        }
        let Ok(msg) = serde_json::from_str::<Value>(&buf) else {
            continue;
        };
        // 工具列表变化之类的通知。
        if msg["id"] != 1 {
            continue;
        }
        if let Some(error) = msg["error"].as_str() {
            bail!("{error}");
        }
        let values: Vec<Zeroizing<String>> = msg["values"]
            .as_array()
            .context("malformed reply from the agent-shim")?
            .iter()
            .map(|v| v.as_str().map(|s| Zeroizing::new(s.to_owned())))
            .collect::<Option<_>>()
            .context("malformed reply from the agent-shim")?;
        if values.len() != refs.len() {
            bail!("malformed reply from the agent-shim");
        }
        return Ok(values);
    }
}

/// 执行命令，返回它的退出码（被信号杀掉时按 shell 的习惯是 128 + 信号）。
pub fn exec(socket: &Path, plan: &Plan) -> anyhow::Result<i32> {
    use std::os::unix::process::ExitStatusExt;
    let values = reveal(socket, &plan.refs)?;
    let args = plan.args(&values);
    let (program, rest) = args.split_first().expect("the command is not empty");
    let mut cmd = Command::new(program.as_str());
    cmd.args(rest.iter().map(|a| a.as_str()));
    for (var, r) in &plan.env {
        cmd.env(var, plan.value(&values, r));
    }
    if plan.stdin.is_some() {
        cmd.stdin(Stdio::piped());
    }
    let mut child = cmd
        .spawn()
        .with_context(|| format!("starting {}", plan.command[0]))?;
    if let (Some(r), Some(mut input)) = (&plan.stdin, child.stdin.take()) {
        let mut text = Zeroizing::new(plan.value(&values, r).to_owned());
        text.push('\n');
        // 命令不读标准输入就关掉管道了，写失败不算错。
        let _ = input.write_all(text.as_bytes());
    }
    let status = child.wait()?;
    Ok(status
        .code()
        .unwrap_or_else(|| 128 + status.signal().unwrap_or(0)))
}

/// 在 `dir` 下放 `thinktin-vault` 启动脚本（调用本程序的 `vault` 子命令），返回目录（加进 agent 的 PATH）。
pub fn install(dir: &Path, exe: &Path, socket: &Path) -> anyhow::Result<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .with_context(|| format!("creating {}", dir.display()))?;
    let quote = |p: &Path| format!("'{}'", p.display().to_string().replace('\'', r"'\''"));
    let script = format!(
        "#!/bin/sh\n# ThinkTin 密码保险箱助手：按名字把保险箱里的值注入命令。\nexec {} vault --socket {} \"$@\"\n",
        quote(exe),
        quote(socket)
    );
    let path = dir.join(COMMAND);
    std::fs::write(&path, script).with_context(|| format!("writing {}", path.display()))?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))?;
    Ok(dir.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn references_and_placeholders() {
        assert!(valid_ref("github") && valid_ref("github.username") && valid_ref("db_2.password"));
        assert!(!valid_ref("GitHub") && !valid_ref("github.token") && !valid_ref("a.b.c"));
        assert_eq!(
            pieces("-u {{mail.username}}:{{mail.password}}!"),
            [
                Piece::Text("-u "),
                Piece::Ref("mail.username"),
                Piece::Text(":"),
                Piece::Ref("mail.password"),
                Piece::Text("!"),
            ]
        );
        assert_eq!(
            pieces("{{not a ref}} and {{x"),
            [Piece::Text("{{not a ref}}"), Piece::Text(" and {{x")]
        );

        let plan = Plan::parse(
            &s(&["GH_TOKEN=github", "MAIL_USER=mail.username"]),
            Some("github"),
            &s(&[
                "curl",
                "-u",
                "{{mail.username}}:{{mail.password}}",
                "https://x",
            ]),
        )
        .unwrap();
        assert_eq!(plan.refs, ["github", "mail.username", "mail.password"]);
        let values: Vec<Zeroizing<String>> = ["gh-token", "me@x", "mail-pass"]
            .iter()
            .map(|v| Zeroizing::new(v.to_string()))
            .collect();
        let args: Vec<String> = plan.args(&values).iter().map(|a| a.to_string()).collect();
        assert_eq!(args, ["curl", "-u", "me@x:mail-pass", "https://x"]);

        for (env, stdin, cmd) in [
            (s(&["1BAD=github"]), None, s(&["true"])),
            (s(&["OK=Git.Hub"]), None, s(&["true"])),
            (s(&["NOEQ"]), None, s(&["true"])),
            (vec![], Some("bad ref"), s(&["true"])),
            (vec![], None, s(&["true"])),
            (s(&["OK=github"]), None, vec![]),
        ] {
            assert!(
                Plan::parse(&env, stdin, &cmd).is_err(),
                "{env:?} {stdin:?} {cmd:?}"
            );
        }
    }

    #[test]
    fn exec_injects_values_without_printing_them() {
        use std::os::unix::net::UnixListener;

        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("b.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        // 假的 shim：先发一条通知，再按请求回值。
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let req: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(req["op"], "reveal");
            assert_eq!(req["refs"], json!(["db.username", "db"]));
            let mut w = stream;
            writeln!(w, "{}", json!({"op": "tools_changed"})).unwrap();
            writeln!(w, "{}", json!({"id": 1, "values": ["app", "s3cret-pw"]})).unwrap();
        });
        let out = dir.path().join("out.txt");
        let plan = Plan::parse(
            &s(&["DB_USER=db.username"]),
            Some("db"),
            &s(&[
                "sh",
                "-c",
                &format!(
                    "read pw; printf '%s|%s|%s' \"$DB_USER\" \"$pw\" \"$1\" > {}; exit 7",
                    out.display()
                ),
                "sh",
                "x{{db}}y",
            ]),
        )
        .unwrap();
        let code = exec(&socket, &plan).unwrap();
        server.join().unwrap();
        assert_eq!(code, 7);
        assert_eq!(
            std::fs::read_to_string(&out).unwrap(),
            "app|s3cret-pw|xs3cret-pwy"
        );
    }

    #[test]
    fn platform_errors_are_reported() {
        use std::os::unix::net::UnixListener;

        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("b.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let mut w = stream;
            writeln!(w, "{}", json!({"id": 1, "error": "no vault item named db"})).unwrap();
        });
        let plan = Plan::parse(&s(&["X=db"]), None, &s(&["true"])).unwrap();
        let err = exec(&socket, &plan).unwrap_err();
        server.join().unwrap();
        assert!(err.to_string().contains("no vault item named db"), "{err}");
    }

    #[test]
    fn launcher_script_quotes_paths() {
        let dir = tempfile::tempdir().unwrap();
        let bin = install(
            &dir.path().join("bin"),
            Path::new("/opt/it's/agent-shim"),
            Path::new("/home/a b/.thinktin/platform-tools.sock"),
        )
        .unwrap();
        let script = std::fs::read_to_string(bin.join(COMMAND)).unwrap();
        assert!(
            script.contains(
                r#"exec '/opt/it'\''s/agent-shim' vault --socket '/home/a b/.thinktin/platform-tools.sock' "$@""#
            ),
            "{script}"
        );
    }
}
