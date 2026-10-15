//! 用假 ACP agent 驱动真实的 agent-shim 进程，覆盖握手、对话、权限、取消、崩溃重启和会话接回。

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use serde_json::{Value, json};

const SHIM: &str = env!("CARGO_BIN_EXE_agent-shim");
const FAKE_AGENT: &str = env!("CARGO_BIN_EXE_fake-acp-agent");
const TIMEOUT: Duration = Duration::from_secs(20);

fn write_manifest(dir: &Path, caps: &str) -> PathBuf {
    let path = dir.join("fake.toml");
    let text = format!(
        r#"
        [agent]
        id = "fake"
        name = "Fake"
        upstream = "https://example.com/fake"
        version = "0.0.1"
        license = "MIT"
        sites = ["cn"]

        [runtime]
        template = "agents/fake:0.0.1"
        vcpu = 1
        memory_mb = 256
        state_dirs = [".fake-agent"]

        [[harness]]
        id = "acp"
        kind = "acp"
        command = ["{FAKE_AGENT}"]
        env = {{ FAKE_HARNESS_ENV = "from-manifest", FAKE_ACP_CAPS = "{caps}" }}
        session = {{ restore = true, per_session_mcp = true }}

        [llm]
        protocols = ["openai-completions"]
        config = "pi"
        "#
    );
    std::fs::write(&path, text).unwrap();
    path
}

struct Shim {
    child: Child,
    stdin: Option<ChildStdin>,
    events: mpsc::Receiver<Value>,
    seen: Vec<Value>,
}

struct Setup {
    dir: tempfile::TempDir,
    manifest: PathBuf,
}

impl Setup {
    fn new() -> Self {
        Self::with_caps("resume")
    }

    /// `caps` 控制假 agent 声明的会话能力，经清单的 env 传给它（shim 自己的环境不会透传）。
    fn with_caps(caps: &str) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let manifest = write_manifest(dir.path(), caps);
        Self { dir, manifest }
    }

    fn home(&self) -> PathBuf {
        self.dir.path().join("home")
    }

    fn command(&self, sub: &str, extra: &[&str]) -> Command {
        let work = self.dir.path().join("work");
        std::fs::create_dir_all(&work).unwrap();
        let mut cmd = Command::new(SHIM);
        cmd.arg(sub)
            .arg("--manifest")
            .arg(&self.manifest)
            .arg("--home")
            .arg(self.home())
            .arg("--cwd")
            .arg(&work)
            .args([
                "--gateway",
                "https://gw.test",
                "--handshake-timeout-secs",
                "10",
            ])
            .args(extra)
            .env("THINKTIN_SANDBOX_TOKEN", "sbx-test-token")
            .env("SHIM_TEST_SECRET", "must-not-leak")
            .env("RUST_LOG", "warn");
        cmd
    }

    fn serve(&self, extra: &[&str]) -> Shim {
        let mut cmd = self.command("serve", extra);
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                let v: Value = serde_json::from_str(&line).expect("shim stdout is JSON lines");
                if tx.send(v).is_err() {
                    break;
                }
            }
        });
        Shim {
            stdin: child.stdin.take(),
            child,
            events: rx,
            seen: Vec::new(),
        }
    }
}

impl Shim {
    fn send(&mut self, cmd: Value) {
        let stdin = self.stdin.as_mut().unwrap();
        writeln!(stdin, "{cmd}").unwrap();
        stdin.flush().unwrap();
    }

    fn prompt(&mut self, run_id: &str, text: &str) {
        self.send(json!({"type": "prompt", "run_id": run_id, "text": text}));
    }

    /// 读事件直到满足条件，返回满足条件的那一个。
    fn wait_for(&mut self, what: &str, pred: impl Fn(&Value) -> bool) -> Value {
        loop {
            let ev = self
                .events
                .recv_timeout(TIMEOUT)
                .unwrap_or_else(|_| panic!("timed out waiting for {what}; saw {:#?}", self.seen));
            self.seen.push(ev.clone());
            if pred(&ev) {
                return ev;
            }
        }
    }

    fn wait_type(&mut self, ty: &str) -> Value {
        self.wait_for(ty, |e| e["type"] == ty)
    }

    /// 等这一轮结束，返回期间收到的回复正文和结束原因。
    fn finish_turn(&mut self, run_id: &str) -> (String, String) {
        let start = self.seen.len();
        let end = self.wait_for("turn_ended", |e| {
            e["type"] == "turn_ended" && e["run_id"] == run_id
        });
        let text = self.seen[start..]
            .iter()
            .filter(|e| e["type"] == "message_chunk" && e["run_id"] == run_id)
            .map(|e| e["text"].as_str().unwrap())
            .collect();
        (text, end["stop_reason"].as_str().unwrap().to_owned())
    }

    fn shutdown(mut self) -> std::process::ExitStatus {
        self.send(json!({"type": "shutdown"}));
        drop(self.stdin.take());
        self.child.wait().unwrap()
    }
}

#[test]
fn prompt_roundtrip_and_event_order() {
    let setup = Setup::new();
    let mut shim = setup.serve(&[]);
    let ready = shim.wait_type("ready");
    assert_eq!(ready["agent_id"], "fake");
    assert_eq!(ready["harness"], "acp");
    assert_eq!(ready["session_restored"], false);
    assert_eq!(ready["agent_info"]["name"], "fake-acp-agent");

    shim.prompt("r1", "hello");
    let (text, stop) = shim.finish_turn("r1");
    assert_eq!((text.as_str(), stop.as_str()), ("echo: hello", "end_turn"));
    assert!(
        shim.seen
            .iter()
            .any(|e| e["type"] == "plan" && e["entries"][0]["content"] == "answer")
    );
    assert!(
        shim.seen
            .iter()
            .any(|e| e["type"] == "agent_update" && e["kind"] == "available_commands_update")
    );

    let seqs: Vec<u64> = shim
        .seen
        .iter()
        .map(|e| e["seq"].as_u64().unwrap())
        .collect();
    assert!(
        seqs.windows(2).all(|w| w[1] == w[0] + 1),
        "seq 必须连续递增：{seqs:?}"
    );
    assert!(shim.shutdown().success());
}

#[test]
fn shutdown_does_not_wait_for_stdin_to_close() {
    let setup = Setup::new();
    let mut shim = setup.serve(&[]);
    shim.wait_type("ready");
    shim.send(json!({"type": "shutdown"}));
    // stdin 保持打开：平台发完 shutdown 不一定关管道。
    for _ in 0..100 {
        if let Some(status) = shim.child.try_wait().unwrap() {
            assert!(status.success());
            return;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    panic!("agent-shim did not exit after shutdown");
}

#[test]
fn agent_environment_is_isolated() {
    let setup = Setup::new();
    let mut shim = setup.serve(&[]);
    shim.wait_type("ready");
    shim.prompt("r1", "env");
    let (text, _) = shim.finish_turn("r1");
    let env: Value = serde_json::from_str(&text).unwrap();
    let home = setup.home().canonicalize().unwrap();
    assert_eq!(env["HOME"], home.display().to_string());
    assert_eq!(env["token"], "sbx-test-token");
    assert_eq!(
        env["secret"],
        Value::Null,
        "shim 环境里的其他变量不能漏给 agent"
    );
    assert_eq!(env["harness_env"], "from-manifest");
    assert_eq!(env["pi_dir"], home.join(".pi/agent").display().to_string());
    // 生成的配置引用令牌变量，不含令牌本身。
    let models = std::fs::read_to_string(home.join(".pi/agent/models.json")).unwrap();
    assert!(models.contains("$THINKTIN_SANDBOX_TOKEN") && !models.contains("sbx-test-token"));
    shim.shutdown();
}

#[test]
fn preauthorized_tools_are_approved_by_policy() {
    let setup = Setup::new();
    let mut shim = setup.serve(&["--allow-tools", "read,edit", "--on-unlisted", "reject"]);
    shim.wait_type("ready");

    shim.prompt("r1", "tool:edit");
    let resolved = shim.wait_type("permission_resolved");
    assert_eq!(
        (resolved["by"].as_str(), resolved["option_id"].as_str()),
        (Some("policy"), Some("allow"))
    );
    let (text, _) = shim.finish_turn("r1");
    assert_eq!(text, "tool allowed");
    // 预授权直接决定的不当成“请求用户批准”发出去（平台会推送提醒）。
    assert!(
        !shim
            .seen
            .iter()
            .any(|e| e["type"] == "permission_requested"),
        "policy decisions are not announced as requests"
    );

    shim.prompt("r2", "tool:execute");
    let resolved = shim.wait_type("permission_resolved");
    assert_eq!(resolved["option_id"], "deny");
    assert_eq!(shim.finish_turn("r2").0, "tool rejected");
    shim.shutdown();
}

#[test]
fn unlisted_tools_wait_for_the_user() {
    let setup = Setup::new();
    let mut shim = setup.serve(&["--allow-tools", "read"]);
    shim.wait_type("ready");
    shim.prompt("r1", "tool:delete");
    let req = shim.wait_type("permission_requested");
    assert_eq!(req["title"], "Write notes.txt");
    assert_eq!(req["options"].as_array().unwrap().len(), 3);
    let request_id = req["request_id"].as_str().unwrap().to_owned();

    shim.send(
        json!({"type": "permission_decision", "request_id": request_id, "option_id": "bogus"}),
    );
    let err = shim.wait_type("error");
    assert!(err["message"].as_str().unwrap().contains("no option bogus"));

    shim.send(
        json!({"type": "permission_decision", "request_id": request_id, "option_id": "allow"}),
    );
    let resolved = shim.wait_type("permission_resolved");
    assert_eq!(resolved["by"], "user");
    assert_eq!(shim.finish_turn("r1").0, "tool allowed");
    shim.shutdown();
}

#[test]
fn unanswered_permission_times_out() {
    let setup = Setup::new();
    let mut shim = setup.serve(&["--ask-timeout-secs", "1"]);
    shim.wait_type("ready");
    shim.prompt("r1", "tool");
    let resolved = shim.wait_type("permission_resolved");
    assert_eq!(resolved["by"], "timeout");
    assert_eq!(resolved["option_id"], Value::Null);
    assert_eq!(shim.finish_turn("r1").1, "cancelled");
    shim.shutdown();
}

#[test]
fn cancel_and_busy() {
    let setup = Setup::new();
    let mut shim = setup.serve(&[]);
    shim.wait_type("ready");
    shim.prompt("r1", "slow");
    shim.wait_for("first chunk", |e| e["type"] == "message_chunk");
    shim.prompt("r2", "hello");
    let busy = shim.wait_for("busy error", |e| {
        e["type"] == "error" && e["run_id"] == "r2"
    });
    assert!(
        busy["message"]
            .as_str()
            .unwrap()
            .contains("busy with run r1")
    );
    shim.send(json!({"type": "cancel", "run_id": "r1"}));
    assert_eq!(shim.finish_turn("r1").1, "cancelled");
    shim.prompt("r3", "hello");
    assert_eq!(shim.finish_turn("r3").0, "echo: hello");
    shim.shutdown();
}

#[test]
fn usage_is_reported() {
    let setup = Setup::new();
    let mut shim = setup.serve(&[]);
    shim.wait_type("ready");
    shim.prompt("r1", "usage");
    shim.finish_turn("r1");
    let usage: Vec<_> = shim.seen.iter().filter(|e| e["type"] == "usage").collect();
    assert_eq!(usage.len(), 2);
    assert_eq!(usage[0]["raw"]["used"], 1200);
    assert_eq!(usage[1]["raw"]["totalTokens"], 15);
    shim.shutdown();
}

#[test]
fn crash_restarts_agent_and_resumes_session() {
    let setup = Setup::new();
    let mut shim = setup.serve(&[]);
    let first = shim.wait_type("ready");
    shim.prompt("r1", "crash");
    let err = shim.wait_for("run error", |e| e["type"] == "error" && e["run_id"] == "r1");
    assert!(
        err["message"]
            .as_str()
            .unwrap()
            .contains("exited during the run")
    );
    let exited = shim.wait_type("agent_exited");
    assert_eq!(
        (exited["code"].as_i64(), exited["will_restart"].as_bool()),
        (Some(3), Some(true))
    );

    let second = shim.wait_type("ready");
    assert_eq!(second["session_restored"], true);
    assert_eq!(second["session_id"], first["session_id"]);
    shim.prompt("r2", "hello");
    assert_eq!(shim.finish_turn("r2").0, "echo: hello");
    assert!(
        !shim.seen.iter().any(|e| e["text"] == "REPLAYED"),
        "resume 时重放的历史不能算进新的一轮"
    );
    assert!(
        shim.seen
            .iter()
            .any(|e| e["kind"] == "available_commands_update"
                && e["raw"]["availableCommands"][0]["name"] == "after-resume")
    );
    shim.shutdown();
}

#[test]
fn session_survives_shim_restart_via_load_without_replaying() {
    let setup = Setup::with_caps("load");
    let mut shim = setup.serve(&[]);
    let first = shim.wait_type("ready");
    assert!(shim.shutdown().success());

    let mut shim = setup.serve(&[]);
    let second = shim.wait_type("ready");
    assert_eq!(second["session_restored"], true);
    assert_eq!(second["session_id"], first["session_id"]);
    shim.prompt("r1", "hello");
    shim.finish_turn("r1");
    assert!(
        !shim.seen.iter().any(|e| e["text"] == "REPLAYED"),
        "session/load 重放的历史不能再当新事件上报"
    );
    shim.shutdown();
}

#[test]
fn lost_session_is_reported() {
    let setup = Setup::new();
    let mut shim = setup.serve(&[]);
    shim.wait_type("ready");
    shim.shutdown();
    // agent 那边的会话没了（比如状态目录被清掉），shim 要开新会话并告诉平台。
    std::fs::remove_dir_all(setup.home().join(".fake-agent")).unwrap();
    let mut shim = setup.serve(&[]);
    let lost = shim.wait_type("session_lost");
    assert!(
        lost["reason"]
            .as_str()
            .unwrap()
            .contains("session/resume failed")
    );
    let ready = shim.wait_type("ready");
    assert_eq!(ready["session_restored"], false);
    shim.shutdown();
}

#[test]
fn run_mode_exits_with_turn_result() {
    let setup = Setup::new();
    let out = setup
        .command("run", &["--prompt", "hello"])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let events: Vec<Value> = String::from_utf8(out.stdout)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert_eq!(events.first().unwrap()["type"], "ready");
    assert_eq!(events.last().unwrap()["type"], "turn_ended");

    let out = setup
        .command("run", &["--prompt", "tool:execute", "--format", "text"])
        .output()
        .unwrap();
    assert!(out.status.success());
    assert_eq!(
        String::from_utf8(out.stdout).unwrap().trim(),
        "tool rejected"
    );
}

#[test]
fn run_mode_fails_when_agent_crashes() {
    let setup = Setup::new();
    let out = setup
        .command("run", &["--prompt", "crash"])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(1));
}

#[test]
fn platform_tools_reach_the_platform_and_back() {
    let setup = Setup::new();
    let tools = setup.dir.path().join("tools.json");
    std::fs::write(
        &tools,
        json!([{"name": "schedule_list", "description": "List schedules", "input_schema": {"type": "object"}}]).to_string(),
    )
    .unwrap();
    let mut shim = setup.serve(&[
        "--platform-tools",
        "--platform-tools-file",
        tools.to_str().unwrap(),
    ]);
    shim.wait_type("ready");
    shim.prompt("r1", r#"mcp schedule_list {"limit":2}"#);
    let started = shim.wait_type("turn_started");
    assert_eq!(started["run_id"], "r1");
    let call = shim.wait_type("platform_tool_call");
    assert_eq!(
        call["run_id"], "r1",
        "the shim, not the agent, decides which run a call belongs to"
    );
    assert_eq!(call["name"], "schedule_list");
    assert_eq!(call["arguments"], json!({"limit": 2}));
    shim.send(json!({
        "type": "platform_tool_result",
        "call_id": call["call_id"],
        "content": [{"type": "text", "text": "two schedules"}],
    }));
    let (text, stop) = shim.finish_turn("r1");
    assert_eq!(stop, "end_turn");
    assert_eq!(
        text,
        "server=thinktin tools=1 error=false text=two schedules"
    );

    // 平台中途换了工具列表；没有的工具直接报错，不打扰平台。
    shim.send(json!({"type": "set_platform_tools", "tools": [
        {"name": "schedule_list", "description": "List", "input_schema": {"type": "object"}},
        {"name": "artifacts_get", "description": "Get", "input_schema": {"type": "object"}},
    ]}));
    shim.prompt("r2", "mcp nope {}");
    let (text, _) = shim.finish_turn("r2");
    assert_eq!(
        text,
        "server=thinktin tools=2 error=true text=unknown tool `nope`"
    );
    assert!(
        shim.seen
            .iter()
            .filter(|e| e["type"] == "platform_tool_call")
            .count()
            == 1
    );
    assert!(shim.shutdown().success());
}
