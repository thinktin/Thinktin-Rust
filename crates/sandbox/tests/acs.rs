//! ACS 后端对着模拟的 sandbox-manager + envd 跑一遍：生命周期、Pod IP、进程、文件。
//! 模拟服务照 OpenKruise Agents（release-v0.6）的 E2B 兼容接口写：控制面只在 `/kruise/api` 下，
//! 数据面按 `/kruise/<沙箱 id>/<端口>/<路径>` 路由；envd 是 ACS 镜像里的版本（没有 CloseStdin，
//! `/files` 只收 multipart）。真实集群上的实测见 docs/sandbox-acs.md。

use std::collections::HashMap;
use std::os::unix::process::ExitStatusExt;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::Router;
use axum::body::{Body, Bytes};
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, Method, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{any, get, post};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use sandbox::acs::{AcsConfig, AcsProvider};
use sandbox::{
    CreateSpec, EnvValue, Error, ExecSpec, NetworkPolicy, SandboxProvider, SandboxState, SnapshotId,
};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc;

const KEY: &str = "e2b_test";
const TEMPLATE: &str = "agents-claude-0-90-0";
const EXT_NEVER_TIMEOUT: &str = "e2b.agents.kruise.io/never-timeout";
const EXT_RETURN_IP: &str = "e2b.agents.kruise.io/return-sandbox-ip";
const META_POD_IP: &str = "e2b.agents.kruise.io/sandbox-ip";

struct Sbx {
    state: &'static str,
    /// 存下来的 metadata（扩展参数已删掉）。
    metadata: serde_json::Map<String, Value>,
    return_ip: bool,
    ip: String,
    /// 还要被查几次才有 IP（模拟 Pod 刚就绪）。
    ip_hidden_for: u32,
}

#[derive(Default)]
struct Mock {
    next: AtomicU32,
    sandboxes: Mutex<HashMap<String, Sbx>>,
    /// `<沙箱>:<路径>` → 内容
    files: Mutex<HashMap<String, Vec<u8>>>,
    procs: Mutex<HashMap<u32, mpsc::UnboundedSender<Bytes>>>,
    created: Mutex<Vec<Value>>,
    connects: Mutex<Vec<Value>>,
    deletes: Mutex<Vec<String>>,
    pause_headers: Mutex<Vec<Option<String>>>,
    requests: AtomicU32,
    /// 新沙箱的 IP 要再查几次才出现；`u32::MAX` 表示一直没有。
    hide_ip: AtomicU32,
}

type S = Arc<Mock>;

fn frame(flags: u8, v: &Value) -> Bytes {
    let payload = serde_json::to_vec(v).unwrap();
    let mut out = Vec::with_capacity(5 + payload.len());
    out.push(flags);
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(&payload);
    Bytes::from(out)
}

fn api_err(code: StatusCode, message: &str) -> Response {
    (
        code,
        axum::Json(json!({ "code": code.as_u16(), "message": message })),
    )
        .into_response()
}

/// 没带对 API Key 时的响应。
fn unauthorized(m: &Mock, headers: &HeaderMap) -> Option<Response> {
    m.requests.fetch_add(1, Ordering::SeqCst);
    match headers.get("x-api-key").and_then(|v| v.to_str().ok()) {
        Some(KEY) => None,
        _ => Some(api_err(StatusCode::UNAUTHORIZED, "invalid api key")),
    }
}

/// sandbox-manager 的 convertToE2BSandbox：Pod IP 只在创建时要了才返回，写在存储的 metadata 之后。
fn sandbox_json(id: &str, s: &mut Sbx) -> Value {
    let mut metadata = s.metadata.clone();
    if s.return_ip {
        if s.ip_hidden_for == 0 {
            metadata.insert(META_POD_IP.into(), json!(s.ip));
        } else if s.ip_hidden_for != u32::MAX {
            s.ip_hidden_for -= 1;
        }
    }
    metadata.insert(
        "e2b.agents.kruise.io/sandbox-resource".into(),
        json!(format!("default/{id}")),
    );
    json!({
        "sandboxID": id,
        "templateID": TEMPLATE,
        "clientID": "c",
        "envdVersion": "0.2.10",
        "domain": "sbx.test",
        "envdAccessToken": format!("envd-{id}"),
        "state": s.state,
        "metadata": metadata,
    })
}

// ---------- 控制面（/kruise/api） ----------

async fn create(
    State(m): State<S>,
    headers: HeaderMap,
    axum::Json(body): axum::Json<Value>,
) -> Response {
    if let Some(r) = unauthorized(&m, &headers) {
        return r;
    }
    let timeout = body["timeout"].as_i64().unwrap_or(0);
    let timeout = if timeout == 0 { 300 } else { timeout };
    if !(30..=2_592_000).contains(&timeout) {
        return api_err(
            StatusCode::BAD_REQUEST,
            "timeout should between 30 and 2592000",
        );
    }
    if body["templateID"] != TEMPLATE {
        return api_err(StatusCode::BAD_REQUEST, "Template or Checkpoint not found");
    }
    if let Some(allow) = body["network"]["allowOut"].as_array()
        && allow
            .iter()
            .any(|a| a.as_str().unwrap_or("*").contains('*'))
    {
        return api_err(StatusCode::BAD_REQUEST, "invalid allowOut");
    }
    let mut metadata = body["metadata"].as_object().cloned().unwrap_or_default();
    let return_ip = metadata.remove(EXT_RETURN_IP) == Some(json!("true"));
    metadata.remove(EXT_NEVER_TIMEOUT);
    metadata.remove("e2b.agents.kruise.io/reserve-paused-sandbox-duration");
    if metadata
        .keys()
        .any(|k| k.starts_with("e2b.agents.kruise.io/") || k.starts_with("agents.kruise.io/"))
    {
        return api_err(StatusCode::BAD_REQUEST, "Forbidden metadata key");
    }
    let n = m.next.fetch_add(1, Ordering::SeqCst);
    let id = format!("sbx-{n}");
    let mut s = Sbx {
        state: "running",
        metadata,
        return_ip,
        ip: format!("10.0.1.{}", 5 + n),
        ip_hidden_for: m.hide_ip.load(Ordering::SeqCst),
    };
    let out = sandbox_json(&id, &mut s);
    m.sandboxes.lock().unwrap().insert(id, s);
    m.created.lock().unwrap().push(body);
    (StatusCode::CREATED, axum::Json(out)).into_response()
}

async fn detail(State(m): State<S>, headers: HeaderMap, Path(id): Path<String>) -> Response {
    if let Some(r) = unauthorized(&m, &headers) {
        return r;
    }
    let mut map = m.sandboxes.lock().unwrap();
    match map.get_mut(&id) {
        Some(s) => axum::Json(sandbox_json(&id, s)).into_response(),
        None => api_err(StatusCode::NOT_FOUND, "sandbox not found"),
    }
}

async fn kill(State(m): State<S>, headers: HeaderMap, Path(id): Path<String>) -> Response {
    if let Some(r) = unauthorized(&m, &headers) {
        return r;
    }
    m.sandboxes.lock().unwrap().remove(&id);
    m.deletes.lock().unwrap().push(id);
    // 不存在也报 204。
    StatusCode::NO_CONTENT.into_response()
}

async fn pause(State(m): State<S>, headers: HeaderMap, Path(id): Path<String>) -> Response {
    if let Some(r) = unauthorized(&m, &headers) {
        return r;
    }
    m.pause_headers.lock().unwrap().push(
        headers
            .get("x-e2b-kruise-reserve-paused-sandbox-duration")
            .map(|v| v.to_str().unwrap().to_owned()),
    );
    let mut map = m.sandboxes.lock().unwrap();
    match map.get_mut(&id) {
        None => api_err(StatusCode::NOT_FOUND, "sandbox not found"),
        Some(s) if s.state == "paused" => api_err(StatusCode::CONFLICT, "already paused"),
        Some(s) => {
            s.state = "paused";
            StatusCode::NO_CONTENT.into_response()
        }
    }
}

async fn connect(
    State(m): State<S>,
    headers: HeaderMap,
    Path(id): Path<String>,
    axum::Json(body): axum::Json<Value>,
) -> Response {
    if let Some(r) = unauthorized(&m, &headers) {
        return r;
    }
    if body["timeout"].as_i64().unwrap_or(0) <= 0 {
        return api_err(StatusCode::BAD_REQUEST, "timeout must be positive");
    }
    m.connects.lock().unwrap().push(body);
    let mut map = m.sandboxes.lock().unwrap();
    let Some(s) = map.get_mut(&id) else {
        return api_err(StatusCode::NOT_FOUND, "sandbox not found");
    };
    if s.state == "paused" {
        // 恢复后换了一个 Pod IP。
        s.ip = s.ip.replace("10.0.1.", "10.0.2.");
        s.state = "running";
        return (StatusCode::CREATED, axum::Json(sandbox_json(&id, s))).into_response();
    }
    axum::Json(sandbox_json(&id, s)).into_response()
}

// ---------- 数据面（/kruise/<沙箱>/<端口>/<路径>） ----------

/// 核对端口、envd 令牌和用户；沙箱暂停时数据面不通。
fn data_auth(m: &Mock, sid: &str, port: u16, headers: &HeaderMap) -> Result<(), StatusCode> {
    if port != 49983 {
        return Err(StatusCode::BAD_GATEWAY);
    }
    let h = |k: &str| {
        headers
            .get(k)
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default()
            .to_owned()
    };
    if h("x-access-token") != format!("envd-{sid}")
        || h("authorization") != format!("Basic {}", STANDARD.encode("user:"))
        || headers.contains_key("x-api-key")
    {
        return Err(StatusCode::UNAUTHORIZED);
    }
    match m.sandboxes.lock().unwrap().get(sid) {
        Some(s) if s.state == "running" => Ok(()),
        Some(_) => Err(StatusCode::BAD_GATEWAY),
        None => Err(StatusCode::NOT_FOUND),
    }
}

async fn data(
    State(m): State<S>,
    method: Method,
    Path((sid, port, rest)): Path<(String, u16, String)>,
    Query(q): Query<HashMap<String, String>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    if let Err(s) = data_auth(&m, &sid, port, &headers) {
        return s.into_response();
    }
    let json_body = || serde_json::from_slice::<Value>(&body).unwrap_or_default();
    match (method.as_str(), rest.as_str()) {
        ("POST", "process.Process/Start") => start(&m, &headers, &body),
        ("POST", "process.Process/SendInput") => {
            let req = json_body();
            let data = req["input"]["stdin"].as_str().unwrap().to_owned();
            match m.procs.lock().unwrap().get(&pid_of(&req)) {
                Some(tx) => {
                    let _ = tx.send(frame(
                        0,
                        &json!({ "event": { "data": { "stdout": data } } }),
                    ));
                    axum::Json(json!({})).into_response()
                }
                None => StatusCode::NOT_FOUND.into_response(),
            }
        }
        ("POST", "process.Process/SendSignal") => {
            let req = json_body();
            assert_eq!(req["signal"], "SIGNAL_SIGKILL");
            match m.procs.lock().unwrap().remove(&pid_of(&req)) {
                Some(tx) => {
                    let _ = tx.send(frame(
                        0,
                        &json!({ "event": { "end": { "exitCode": -1, "status": "signal: killed" } } }),
                    ));
                    let _ = tx.send(frame(2, &json!({})));
                    axum::Json(json!({})).into_response()
                }
                None => StatusCode::NOT_FOUND.into_response(),
            }
        }
        ("POST", "filesystem.Filesystem/MakeDir") => axum::Json(json!({})).into_response(),
        ("POST", "files") => {
            assert_eq!(q["username"], "user");
            let ct = headers
                .get("content-type")
                .and_then(|v| v.to_str().ok())
                .unwrap_or_default();
            // ACS 镜像里的 envd：不是 multipart 就报 500。
            let Some(boundary) = ct.strip_prefix("multipart/form-data; boundary=") else {
                return StatusCode::INTERNAL_SERVER_ERROR.into_response();
            };
            let Some(content) = multipart_file(&body, boundary) else {
                return StatusCode::BAD_REQUEST.into_response();
            };
            m.files
                .lock()
                .unwrap()
                .insert(format!("{sid}:{}", q["path"]), content);
            StatusCode::OK.into_response()
        }
        ("GET", "files") => match m.files.lock().unwrap().get(&format!("{sid}:{}", q["path"])) {
            Some(d) => d.clone().into_response(),
            None => (StatusCode::NOT_FOUND, "no such file").into_response(),
        },
        // 包括 CloseStdin：这个版本的 envd 没有。
        _ => StatusCode::NOT_FOUND.into_response(),
    }
}

fn multipart_file(body: &[u8], boundary: &str) -> Option<Vec<u8>> {
    let head = format!("--{boundary}\r\n");
    let tail = format!("\r\n--{boundary}--\r\n");
    let rest = body.strip_prefix(head.as_bytes())?;
    let start = rest.windows(4).position(|w| w == b"\r\n\r\n")? + 4;
    let content = rest.get(start..)?.strip_suffix(tail.as_bytes())?;
    Some(content.to_vec())
}

fn pid_of(req: &Value) -> u32 {
    req["process"]["pid"].as_u64().unwrap() as u32
}

fn start(m: &Mock, headers: &HeaderMap, body: &[u8]) -> Response {
    assert_eq!(
        headers.get("content-type").unwrap(),
        "application/connect+json"
    );
    let len = u32::from_be_bytes([body[1], body[2], body[3], body[4]]) as usize;
    let req: Value = serde_json::from_slice(&body[5..5 + len]).unwrap();
    let process = &req["process"];
    let pid = 100 + m.next.fetch_add(1, Ordering::SeqCst);
    let (tx, rx) = mpsc::unbounded_channel::<Bytes>();
    tx.send(frame(0, &json!({ "event": { "start": { "pid": pid } } })))
        .unwrap();
    match process["cmd"].as_str().unwrap_or_default() {
        // 回显标准输入，直到被结束。
        "cat" => {
            m.procs.lock().unwrap().insert(pid, tx);
        }
        // 报告工作目录、HOME 和传进来的环境变量。
        "env" => {
            let out = format!(
                "{}\n{}\n{}\n",
                process["cwd"].as_str().unwrap_or_default(),
                process["envs"]["HOME"].as_str().unwrap_or_default(),
                process["envs"]["THINKTIN_SANDBOX_TOKEN"]
                    .as_str()
                    .unwrap_or_default(),
            );
            tx.send(frame(
                0,
                &json!({ "event": { "data": { "stdout": STANDARD.encode(out) } } }),
            ))
            .unwrap();
            tx.send(frame(
                0,
                &json!({ "event": { "end": { "exited": true, "status": "exit status 0" } } }),
            ))
            .unwrap();
            tx.send(frame(2, &json!({}))).unwrap();
        }
        _ => unreachable!(),
    }
    let stream = futures_util::stream::unfold(rx, |mut rx| async move {
        rx.recv().await.map(|b| (Ok::<_, std::io::Error>(b), rx))
    });
    Response::builder()
        .header("content-type", "application/connect+json")
        .body(Body::from_stream(stream))
        .unwrap()
}

async fn mock() -> (S, String) {
    let m: S = Arc::new(Mock::default());
    let app = Router::new()
        .route("/kruise/api/sandboxes", post(create))
        .route("/kruise/api/sandboxes/{id}", get(detail).delete(kill))
        .route("/kruise/api/sandboxes/{id}/pause", post(pause))
        .route("/kruise/api/sandboxes/{id}/connect", post(connect))
        .route("/kruise/{sid}/{port}/{*rest}", any(data))
        .with_state(m.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (m, format!("http://{addr}"))
}

fn provider(url: &str) -> AcsProvider {
    AcsProvider::new(AcsConfig {
        api_url: format!("{url}/kruise/api"),
        api_key: Some(KEY.into()),
        paused_retention: Some("720h".into()),
        ip_wait: Duration::from_secs(2),
        ..AcsConfig::default()
    })
    .unwrap()
}

fn spec() -> CreateSpec {
    CreateSpec {
        template: "agents/claude:0.90.0".into(),
        workspace: Some("ws-1".into()),
        network: NetworkPolicy {
            allow: vec!["10.0.0.20:8790".into()],
        },
        metadata: [("instance".to_owned(), "inst-1".to_owned())].into(),
        ..CreateSpec::default()
    }
}

fn run(argv: &[&str]) -> ExecSpec {
    ExecSpec {
        argv: argv.iter().map(|s| s.to_string()).collect(),
        ..ExecSpec::default()
    }
}

#[tokio::test]
async fn sandboxes_processes_and_files() {
    let (m, url) = mock().await;
    let p = provider(&url);
    assert_eq!(p.name(), "acs");
    assert!(!p.workspace_persists());

    let info = p.create(spec()).await.unwrap();
    assert_eq!(info.state, SandboxState::Running);
    // 令牌绑到这个沙箱的 Pod IP。
    assert_eq!(info.address, Some("10.0.1.5".parse().unwrap()));
    // 创建请求：SandboxSet 名、合法的 timeout 加不按空闲回收、默认拒绝出网只放行白名单、没有卷。
    let body = m.created.lock().unwrap()[0].clone();
    assert_eq!(body["templateID"], TEMPLATE);
    assert_eq!(body["timeout"], 300);
    assert_eq!(body["allow_internet_access"], false);
    assert_eq!(body["network"], json!({ "allowOut": ["10.0.0.20"] }));
    assert_eq!(body["metadata"][EXT_NEVER_TIMEOUT], "true");
    assert_eq!(body["metadata"][EXT_RETURN_IP], "true");
    assert_eq!(
        body["metadata"]["e2b.agents.kruise.io/reserve-paused-sandbox-duration"],
        "720h"
    );
    assert!(body.get("volumeMounts").is_none());
    assert!(body.get("secure").is_none());

    let got = p.get(&info.id).await.unwrap().unwrap();
    assert_eq!(got.template, "agents/claude:0.90.0");
    assert_eq!(got.workspace.as_deref(), Some("ws-1"));
    assert_eq!(got.address, Some("10.0.1.5".parse().unwrap()));
    assert_eq!(got.metadata, spec().metadata, "internal keys are not shown");

    // 工作目录、HOME、环境变量都传进去了。
    let mut env = p
        .exec(
            &info.id,
            ExecSpec {
                argv: vec!["env".into()],
                env: [(
                    "THINKTIN_SANDBOX_TOKEN".to_owned(),
                    EnvValue::Secret("tts1.x".into()),
                )]
                .into(),
                cwd: Some("workspace/sub".into()),
            },
        )
        .await
        .unwrap();
    let mut out = String::new();
    env.stdout.read_to_string(&mut out).await.unwrap();
    assert_eq!(out, "/sandbox/workspace/sub\n/sandbox/home\ntts1.x\n");
    assert_eq!(env.control.wait().await.unwrap().code(), Some(0));

    // 标准输入原样回显；没有 CloseStdin 也不影响，kill 结束进程。
    let mut cat = p.exec(&info.id, run(&["cat"])).await.unwrap();
    cat.stdin.write_all(b"hello\n").await.unwrap();
    cat.stdin.flush().await.unwrap();
    let mut buf = [0u8; 6];
    cat.stdout.read_exact(&mut buf).await.unwrap();
    assert_eq!(&buf, b"hello\n");
    drop(cat.stdin);
    cat.control.kill().await.unwrap();
    assert_eq!(cat.control.wait().await.unwrap().signal(), Some(9));

    // 文件只发 multipart；读的上限；不存在；路径不能跳出沙箱。
    p.write_file(&info.id, "workspace/notes.txt", b"keep me")
        .await
        .unwrap();
    assert_eq!(
        p.read_file(&info.id, "workspace/notes.txt", 100)
            .await
            .unwrap(),
        b"keep me"
    );
    assert!(matches!(
        p.read_file(&info.id, "workspace/notes.txt", 3).await,
        Err(Error::Invalid(_))
    ));
    assert!(matches!(
        p.read_file(&info.id, "workspace/missing.txt", 100).await,
        Err(Error::Io(e)) if e.kind() == std::io::ErrorKind::NotFound
    ));
    assert!(matches!(
        p.write_file(&info.id, "../escape", b"x").await,
        Err(Error::Invalid(_))
    ));

    // 暂停带保留时长；暂停后不能执行；重复暂停没问题。
    p.pause(&info.id).await.unwrap();
    assert_eq!(m.pause_headers.lock().unwrap()[0].as_deref(), Some("720h"));
    assert_eq!(
        p.get(&info.id).await.unwrap().unwrap().state,
        SandboxState::Paused
    );
    assert!(matches!(
        p.exec(&info.id, run(&["env"])).await,
        Err(Error::InvalidState { .. })
    ));
    p.pause(&info.id).await.unwrap();

    // 恢复：connect 带正的 timeout；Pod IP 换了，返回新的。
    let resumed = p.resume(&info.id).await.unwrap();
    assert_eq!(m.connects.lock().unwrap()[0], json!({ "timeout": 300 }));
    assert_eq!(resumed.state, SandboxState::Running);
    assert_eq!(resumed.address, Some("10.0.2.5".parse().unwrap()));
    assert_eq!(resumed.workspace.as_deref(), Some("ws-1"));
    assert_eq!(
        p.read_file(&info.id, "workspace/notes.txt", 100)
            .await
            .unwrap(),
        b"keep me"
    );

    // 没有快照。
    assert!(matches!(
        p.snapshot(&info.id).await,
        Err(Error::Provider(_))
    ));
    assert!(matches!(
        p.restore(&SnapshotId("x".into()), spec()).await,
        Err(Error::Provider(_))
    ));

    // 销毁可以重复；没有卷可删。
    p.destroy(&info.id).await.unwrap();
    p.destroy(&info.id).await.unwrap();
    assert!(p.get(&info.id).await.unwrap().is_none());
    assert!(matches!(
        p.write_file(&info.id, "workspace/x", b"x").await,
        Err(Error::NotFound(_))
    ));
    p.delete_workspace("ws-1").await.unwrap();
}

#[tokio::test]
async fn bad_requests_fail_early() {
    let (m, url) = mock().await;
    let p = provider(&url);
    // 出网规则不能用通配符：一个请求都不发。
    let wildcard = CreateSpec {
        network: NetworkPolicy {
            allow: vec!["*.example.com:443".into()],
        },
        ..spec()
    };
    assert!(matches!(p.create(wildcard).await, Err(Error::Invalid(_))));
    let reserved = CreateSpec {
        metadata: [(EXT_NEVER_TIMEOUT.to_owned(), "false".to_owned())].into(),
        ..spec()
    };
    assert!(matches!(p.create(reserved).await, Err(Error::Invalid(_))));
    assert_eq!(m.requests.load(Ordering::SeqCst), 0);

    // 没有这个 SandboxSet：sandbox-manager 报 400。
    let unknown = CreateSpec {
        template: "agents/nope:1".into(),
        ..spec()
    };
    match p.create(unknown).await {
        Err(Error::Invalid(msg)) => {
            assert!(msg.contains("Template or Checkpoint not found"), "{msg}")
        }
        other => panic!("{other:?}"),
    }

    // 模板映射优先于规整后的名字。
    let mapped = AcsProvider::new(AcsConfig {
        api_url: format!("{url}/kruise/api"),
        api_key: Some(KEY.into()),
        templates: [("claude".to_owned(), TEMPLATE.to_owned())].into(),
        ..AcsConfig::default()
    })
    .unwrap();
    let info = mapped
        .create(CreateSpec {
            template: "claude".into(),
            ..spec()
        })
        .await
        .unwrap();
    assert_eq!(
        mapped.get(&info.id).await.unwrap().unwrap().template,
        "claude"
    );

    // 没有 API Key。
    let anonymous = AcsProvider::new(AcsConfig {
        api_url: format!("{url}/kruise/api"),
        ..AcsConfig::default()
    })
    .unwrap();
    assert!(matches!(
        anonymous.get(&info.id).await,
        Err(Error::Provider(msg)) if msg.contains("401")
    ));
}

#[tokio::test]
async fn pod_ip_is_required() {
    let (m, url) = mock().await;
    let p = provider(&url);

    // 创建响应里还没有 IP，第二次查才有：等到就行。
    m.hide_ip.store(2, Ordering::SeqCst);
    let info = p.create(spec()).await.unwrap();
    assert_eq!(info.address, Some("10.0.1.5".parse().unwrap()));
    assert!(m.deletes.lock().unwrap().is_empty());

    // 一直没有 IP：创建失败，刚建的沙箱删掉。
    m.hide_ip.store(u32::MAX, Ordering::SeqCst);
    let err = p.create(spec()).await.unwrap_err();
    assert!(err.to_string().contains("did not report the IP"), "{err}");
    assert_eq!(m.deletes.lock().unwrap().as_slice(), ["sbx-1"]);
    assert!(!m.sandboxes.lock().unwrap().contains_key("sbx-1"));
}

#[tokio::test]
async fn dead_sandboxes_are_removed() {
    let (m, url) = mock().await;
    let p = provider(&url);
    let info = p.create(spec()).await.unwrap();
    m.sandboxes
        .lock()
        .unwrap()
        .get_mut(&info.id.0)
        .unwrap()
        .state = "dead";
    assert!(p.get(&info.id).await.unwrap().is_none());
    assert_eq!(m.deletes.lock().unwrap().as_slice(), [info.id.0.as_str()]);
}

#[tokio::test]
async fn restarted_control_plane_reconnects() {
    let (m, url) = mock().await;
    let first = provider(&url);
    let info = first.create(spec()).await.unwrap();
    first
        .write_file(&info.id, "workspace/a.txt", b"a")
        .await
        .unwrap();
    // 新的进程没有缓存的令牌：查一次就有，运行中的沙箱不用 connect。
    let second = provider(&url);
    assert_eq!(
        second
            .read_file(&info.id, "workspace/a.txt", 10)
            .await
            .unwrap(),
        b"a"
    );
    assert!(m.connects.lock().unwrap().is_empty());
}
