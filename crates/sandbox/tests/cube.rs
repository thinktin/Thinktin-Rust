//! Cube 后端对着模拟的 CubeAPI + envd 跑一遍：生命周期、进程（Connect 流）、文件、卷。
//! 模拟服务照 CubeSandbox 的 openapi.yml 和 envd 的 Connect 协议写，真实集群上的联调见 docs/sandbox-cube.md。

use std::collections::HashMap;
use std::os::unix::process::ExitStatusExt;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use axum::Router;
use axum::body::{Body, Bytes};
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use sandbox::cube::{CubeConfig, CubeProvider};
use sandbox::{
    CreateSpec, EnvValue, Error, ExecSpec, NetworkPolicy, SandboxProvider, SandboxState, SnapshotId,
};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc;

const DOMAIN: &str = "cube.test";

struct Sbx {
    /// Cube 记的模板 id：从快照建的沙箱是快照 id。
    template: String,
    state: &'static str,
    metadata: Value,
}

#[derive(Default)]
struct Mock {
    next: AtomicU32,
    sandboxes: Mutex<HashMap<String, Sbx>>,
    snapshots: Mutex<Vec<String>>,
    /// （卷 id，卷名）
    volumes: Mutex<Vec<(String, String)>>,
    /// `<沙箱>:<路径>` → 内容
    files: Mutex<HashMap<String, Vec<u8>>>,
    dirs: Mutex<Vec<String>>,
    procs: Mutex<HashMap<u32, mpsc::UnboundedSender<Bytes>>>,
    created: Mutex<Vec<Value>>,
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

fn not_found() -> Response {
    (
        StatusCode::NOT_FOUND,
        axum::Json(json!({ "code": 404, "message": "not found" })),
    )
        .into_response()
}

fn sandbox_json(id: &str, template: &str) -> Value {
    json!({
        "sandboxID": id,
        "templateID": template,
        "clientID": "c",
        "envdVersion": "0.2.0",
        "domain": DOMAIN,
        "envdAccessToken": format!("envd-{id}"),
        "trafficAccessToken": format!("traffic-{id}"),
    })
}

// ---------- CubeAPI ----------

async fn create(State(m): State<S>, axum::Json(body): axum::Json<Value>) -> Response {
    let template = body["templateID"].as_str().unwrap_or_default().to_owned();
    if template.starts_with("snap-") && !m.snapshots.lock().unwrap().contains(&template) {
        return not_found();
    }
    let id = format!("sbx{}", m.next.fetch_add(1, Ordering::SeqCst));
    m.sandboxes.lock().unwrap().insert(
        id.clone(),
        Sbx {
            template: template.clone(),
            state: "running",
            metadata: body["metadata"].clone(),
        },
    );
    m.created.lock().unwrap().push(body);
    (
        StatusCode::CREATED,
        axum::Json(sandbox_json(&id, &template)),
    )
        .into_response()
}

async fn detail(State(m): State<S>, Path(id): Path<String>) -> Response {
    let map = m.sandboxes.lock().unwrap();
    let Some(s) = map.get(&id) else {
        return not_found();
    };
    axum::Json(json!({
        "sandboxID": id,
        "templateID": s.template,
        "clientID": "c",
        "startedAt": "2026-10-16T00:00:00Z",
        "envdVersion": "0.2.0",
        "cpuCount": 1,
        "memoryMB": 1024,
        "state": s.state,
        "metadata": s.metadata,
        "domain": DOMAIN,
        "envdAccessToken": format!("envd-{id}"),
    }))
    .into_response()
}

async fn kill(State(m): State<S>, Path(id): Path<String>) -> Response {
    match m.sandboxes.lock().unwrap().remove(&id) {
        Some(_) => StatusCode::NO_CONTENT.into_response(),
        None => not_found(),
    }
}

async fn pause(State(m): State<S>, Path(id): Path<String>) -> Response {
    let mut map = m.sandboxes.lock().unwrap();
    match map.get_mut(&id) {
        None => not_found(),
        Some(s) if s.state == "paused" => (
            StatusCode::CONFLICT,
            axum::Json(json!({ "code": 409, "message": "sandbox cannot be paused" })),
        )
            .into_response(),
        Some(s) => {
            s.state = "paused";
            StatusCode::NO_CONTENT.into_response()
        }
    }
}

async fn connect(
    State(m): State<S>,
    Path(id): Path<String>,
    axum::Json(_body): axum::Json<Value>,
) -> Response {
    let mut map = m.sandboxes.lock().unwrap();
    let Some(s) = map.get_mut(&id) else {
        return not_found();
    };
    s.state = "running";
    axum::Json(sandbox_json(&id, &s.template)).into_response()
}

async fn snapshot(State(m): State<S>, Path(id): Path<String>) -> Response {
    if !m.sandboxes.lock().unwrap().contains_key(&id) {
        return not_found();
    }
    let snap = format!("snap-{}", m.next.fetch_add(1, Ordering::SeqCst));
    m.snapshots.lock().unwrap().push(snap.clone());
    (
        StatusCode::CREATED,
        axum::Json(json!({ "snapshotID": snap, "names": [] })),
    )
        .into_response()
}

async fn list_volumes(State(m): State<S>) -> axum::Json<Value> {
    let list: Vec<Value> = m
        .volumes
        .lock()
        .unwrap()
        .iter()
        .map(|(id, name)| json!({ "volumeID": id, "name": name }))
        .collect();
    axum::Json(Value::Array(list))
}

async fn create_volume(State(m): State<S>, axum::Json(body): axum::Json<Value>) -> Response {
    let name = body["name"].as_str().unwrap_or_default().to_owned();
    let id = format!("vol-{name}");
    m.volumes.lock().unwrap().push((id.clone(), name.clone()));
    (
        StatusCode::CREATED,
        axum::Json(json!({ "volumeID": id, "name": name, "token": "" })),
    )
        .into_response()
}

async fn delete_volume(State(m): State<S>, Path(id): Path<String>) -> Response {
    let mut v = m.volumes.lock().unwrap();
    let before = v.len();
    v.retain(|(vid, _)| vid != &id);
    if v.len() < before {
        StatusCode::NO_CONTENT.into_response()
    } else {
        not_found()
    }
}

// ---------- envd（经 CubeProxy 按 Host 头路由） ----------

/// 按 Host 头找沙箱，核对 envd 令牌、流量令牌和用户；沙箱暂停时数据面不通。
fn sandbox_of(m: &Mock, headers: &HeaderMap) -> Result<String, StatusCode> {
    let host = headers
        .get("host")
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default();
    let suffix = format!(".{DOMAIN}");
    let id = host
        .strip_prefix("49983-")
        .and_then(|h| h.strip_suffix(suffix.as_str()))
        .ok_or(StatusCode::NOT_FOUND)?;
    let h = |k: &str| {
        headers
            .get(k)
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default()
            .to_owned()
    };
    if h("x-access-token") != format!("envd-{id}")
        || h("e2b-traffic-access-token") != format!("traffic-{id}")
        || h("authorization") != format!("Basic {}", STANDARD.encode("user:"))
    {
        return Err(StatusCode::UNAUTHORIZED);
    }
    match m.sandboxes.lock().unwrap().get(id) {
        Some(s) if s.state == "running" => Ok(id.to_owned()),
        Some(_) => Err(StatusCode::BAD_GATEWAY),
        None => Err(StatusCode::NOT_FOUND),
    }
}

async fn start(State(m): State<S>, headers: HeaderMap, body: Bytes) -> Response {
    if let Err(s) = sandbox_of(&m, &headers) {
        return s.into_response();
    }
    assert_eq!(
        headers.get("content-type").unwrap(),
        "application/connect+json"
    );
    assert_eq!(body[0], 0, "uncompressed message");
    let len = u32::from_be_bytes([body[1], body[2], body[3], body[4]]) as usize;
    let req: Value = serde_json::from_slice(&body[5..5 + len]).unwrap();
    assert_eq!(req["stdin"], true);
    let process = &req["process"];
    let pid = 100 + m.next.fetch_add(1, Ordering::SeqCst);
    let (tx, rx) = mpsc::unbounded_channel::<Bytes>();
    let started = json!({ "event": { "start": { "pid": pid } } });
    match process["cmd"].as_str().unwrap_or_default() {
        // 回显标准输入；关掉标准输入时正常退出。
        "cat" => {
            tx.send(frame(0, &started)).unwrap();
            m.procs.lock().unwrap().insert(pid, tx);
        }
        // 写一行标准错误，退出码 3（中间夹一个 keepalive）。
        "false" => {
            tx.send(frame(0, &started)).unwrap();
            tx.send(frame(0, &json!({ "event": { "keepalive": {} } })))
                .unwrap();
            tx.send(frame(
                0,
                &json!({ "event": { "data": { "stderr": STANDARD.encode("nope\n") } } }),
            ))
            .unwrap();
            tx.send(frame(
                0,
                &json!({ "event": { "end": { "exitCode": 3, "exited": true, "status": "exit status 3" } } }),
            ))
            .unwrap();
            tx.send(frame(2, &json!({}))).unwrap();
        }
        // 报告工作目录、HOME 和传进来的环境变量；退出码 0（JSON 里没有 exitCode）。
        "env" => {
            let out = format!(
                "{}\n{}\n{}\n",
                process["cwd"].as_str().unwrap_or_default(),
                process["envs"]["HOME"].as_str().unwrap_or_default(),
                process["envs"]["THINKTIN_SANDBOX_TOKEN"]
                    .as_str()
                    .unwrap_or_default(),
            );
            tx.send(frame(0, &started)).unwrap();
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
        // 找不到可执行文件：envd 不发 start，流结束时带错误。
        _ => {
            tx.send(frame(
                2,
                &json!({ "error": { "code": "not_found", "message": "executable file not found" } }),
            ))
            .unwrap();
        }
    }
    let stream = futures_util::stream::unfold(rx, |mut rx| async move {
        rx.recv().await.map(|b| (Ok::<_, std::io::Error>(b), rx))
    });
    Response::builder()
        .header("content-type", "application/connect+json")
        .body(Body::from_stream(stream))
        .unwrap()
}

fn pid_of(req: &Value) -> u32 {
    req["process"]["pid"].as_u64().unwrap() as u32
}

async fn send_input(
    State(m): State<S>,
    headers: HeaderMap,
    axum::Json(req): axum::Json<Value>,
) -> Response {
    if let Err(s) = sandbox_of(&m, &headers) {
        return s.into_response();
    }
    let data = req["input"]["stdin"].as_str().unwrap().to_owned();
    match m.procs.lock().unwrap().get(&pid_of(&req)) {
        Some(tx) => {
            let _ = tx.send(frame(
                0,
                &json!({ "event": { "data": { "stdout": data } } }),
            ));
            axum::Json(json!({})).into_response()
        }
        None => not_found(),
    }
}

async fn close_stdin(
    State(m): State<S>,
    headers: HeaderMap,
    axum::Json(req): axum::Json<Value>,
) -> Response {
    if let Err(s) = sandbox_of(&m, &headers) {
        return s.into_response();
    }
    if let Some(tx) = m.procs.lock().unwrap().remove(&pid_of(&req)) {
        let _ = tx.send(frame(
            0,
            &json!({ "event": { "end": { "exited": true, "status": "exit status 0" } } }),
        ));
        let _ = tx.send(frame(2, &json!({})));
    }
    axum::Json(json!({})).into_response()
}

async fn send_signal(
    State(m): State<S>,
    headers: HeaderMap,
    axum::Json(req): axum::Json<Value>,
) -> Response {
    if let Err(s) = sandbox_of(&m, &headers) {
        return s.into_response();
    }
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
        None => not_found(),
    }
}

async fn make_dir(
    State(m): State<S>,
    headers: HeaderMap,
    axum::Json(req): axum::Json<Value>,
) -> Response {
    if let Err(s) = sandbox_of(&m, &headers) {
        return s.into_response();
    }
    m.dirs
        .lock()
        .unwrap()
        .push(req["path"].as_str().unwrap().to_owned());
    axum::Json(json!({})).into_response()
}

#[derive(serde::Deserialize)]
struct FileQuery {
    path: String,
    username: String,
}

async fn write_file(
    State(m): State<S>,
    headers: HeaderMap,
    Query(q): Query<FileQuery>,
    body: Bytes,
) -> Response {
    let sbx = match sandbox_of(&m, &headers) {
        Ok(id) => id,
        Err(s) => return s.into_response(),
    };
    assert_eq!(q.username, "user");
    m.files
        .lock()
        .unwrap()
        .insert(format!("{sbx}:{}", q.path), body.to_vec());
    StatusCode::OK.into_response()
}

async fn read_file(State(m): State<S>, headers: HeaderMap, Query(q): Query<FileQuery>) -> Response {
    let sbx = match sandbox_of(&m, &headers) {
        Ok(id) => id,
        Err(s) => return s.into_response(),
    };
    match m.files.lock().unwrap().get(&format!("{sbx}:{}", q.path)) {
        Some(d) => d.clone().into_response(),
        None => (StatusCode::NOT_FOUND, "no such file").into_response(),
    }
}

async fn mock() -> (S, String) {
    let m: S = Arc::new(Mock::default());
    let app = Router::new()
        .route("/sandboxes", post(create))
        .route("/sandboxes/{id}", get(detail).delete(kill))
        .route("/sandboxes/{id}/pause", post(pause))
        .route("/sandboxes/{id}/connect", post(connect))
        .route("/sandboxes/{id}/snapshots", post(snapshot))
        .route("/volumes", get(list_volumes).post(create_volume))
        .route("/volumes/{id}", delete(delete_volume))
        .route("/process.Process/Start", post(start))
        .route("/process.Process/SendInput", post(send_input))
        .route("/process.Process/CloseStdin", post(close_stdin))
        .route("/process.Process/SendSignal", post(send_signal))
        .route("/filesystem.Filesystem/MakeDir", post(make_dir))
        .route("/files", get(read_file).post(write_file))
        .with_state(m.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (m, format!("http://{addr}"))
}

fn provider(url: &str) -> CubeProvider {
    CubeProvider::new(CubeConfig {
        api_url: url.to_owned(),
        proxy_url: Some(url.to_owned()),
        egress_address: Some("10.0.0.9".parse().unwrap()),
        ..CubeConfig::default()
    })
    .unwrap()
}

fn spec() -> CreateSpec {
    CreateSpec {
        template: "claude@0.90.0".into(),
        workspace: Some("ws-1".into()),
        network: NetworkPolicy {
            allow: vec!["gw.internal:8790".into(), "10.1.2.3:443".into()],
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
    assert_eq!(p.name(), "cube");

    let info = p.create(spec()).await.unwrap();
    assert_eq!(info.state, SandboxState::Running);
    assert_eq!(info.address, Some("10.0.0.9".parse().unwrap()));
    // 创建请求：不按空闲回收、默认拒绝出网只放行白名单、工作区卷挂到 <root>/workspace。
    let body = m.created.lock().unwrap()[0].clone();
    assert_eq!(body["templateID"], "claude@0.90.0");
    assert_eq!(body["timeout"], -1);
    assert_eq!(body["allow_internet_access"], false);
    assert_eq!(
        body["network"]["allowOut"],
        json!(["gw.internal", "10.1.2.3"])
    );
    assert_eq!(body["network"]["allowPublicTraffic"], false);
    assert_eq!(
        body["volumeMounts"],
        json!([{ "name": "vol-ws-1", "path": "/sandbox/workspace" }])
    );
    assert_eq!(m.volumes.lock().unwrap().len(), 1);

    let got = p.get(&info.id).await.unwrap().unwrap();
    assert_eq!(got.template, "claude@0.90.0");
    assert_eq!(got.workspace.as_deref(), Some("ws-1"));
    assert_eq!(got.metadata, spec().metadata, "internal keys are not shown");

    // 工作目录、HOME、环境变量都传进去了；退出码 0。
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

    // 标准输入原样回显；关掉标准输入后正常退出。
    let mut cat = p.exec(&info.id, run(&["cat"])).await.unwrap();
    cat.stdin.write_all(b"hello\n").await.unwrap();
    cat.stdin.flush().await.unwrap();
    let mut buf = [0u8; 6];
    cat.stdout.read_exact(&mut buf).await.unwrap();
    assert_eq!(&buf, b"hello\n");
    drop(cat.stdin);
    assert_eq!(cat.control.wait().await.unwrap().code(), Some(0));
    let mut rest = Vec::new();
    cat.stdout.read_to_end(&mut rest).await.unwrap();
    assert!(rest.is_empty(), "stdout closes when the process exits");

    // 标准错误和非零退出码。
    let mut f = p.exec(&info.id, run(&["false"])).await.unwrap();
    let mut err = String::new();
    f.stderr.read_to_string(&mut err).await.unwrap();
    assert_eq!(err, "nope\n");
    assert_eq!(f.control.wait().await.unwrap().code(), Some(3));

    // kill：envd 报 signal: killed；重复 kill、wait 都没问题。
    let mut c2 = p.exec(&info.id, run(&["cat"])).await.unwrap();
    c2.control.kill().await.unwrap();
    assert_eq!(c2.control.wait().await.unwrap().signal(), Some(9));
    c2.control.kill().await.unwrap();

    // 找不到可执行文件：exec 直接报错。
    assert!(p.exec(&info.id, run(&["nope"])).await.is_err());
    assert!(matches!(
        p.exec(&info.id, run(&[])).await,
        Err(Error::Invalid(_))
    ));

    // 文件：先建上级目录；读的上限；不存在；路径不能跳出沙箱。
    p.write_file(&info.id, "workspace/notes.txt", b"keep me")
        .await
        .unwrap();
    assert!(
        m.dirs
            .lock()
            .unwrap()
            .contains(&"/sandbox/workspace".to_owned())
    );
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

    // 暂停后不能执行；重复暂停没问题；恢复后接着用。
    p.pause(&info.id).await.unwrap();
    assert_eq!(
        p.get(&info.id).await.unwrap().unwrap().state,
        SandboxState::Paused
    );
    assert!(matches!(
        p.exec(&info.id, run(&["env"])).await,
        Err(Error::InvalidState { .. })
    ));
    p.pause(&info.id).await.unwrap();
    let resumed = p.resume(&info.id).await.unwrap();
    assert_eq!(resumed.state, SandboxState::Running);
    assert_eq!(resumed.workspace.as_deref(), Some("ws-1"));
    assert_eq!(
        p.read_file(&info.id, "workspace/notes.txt", 100)
            .await
            .unwrap(),
        b"keep me"
    );

    // 快照恢复成新沙箱：模板仍是原来的（Cube 记的是快照 id）。
    let snap = p.snapshot(&info.id).await.unwrap();
    let restored = p.restore(&snap, spec()).await.unwrap();
    assert_ne!(restored.id, info.id);
    assert_eq!(
        m.created.lock().unwrap()[1]["templateID"],
        json!(snap.0.clone())
    );
    assert_eq!(
        p.get(&restored.id).await.unwrap().unwrap().template,
        "claude@0.90.0"
    );
    assert!(matches!(
        p.restore(&SnapshotId("snap-missing".into()), spec()).await,
        Err(Error::SnapshotNotFound(_))
    ));

    // 销毁可以重复；工作区卷单独删除。
    p.destroy(&info.id).await.unwrap();
    p.destroy(&info.id).await.unwrap();
    assert!(p.get(&info.id).await.unwrap().is_none());
    assert!(matches!(
        p.write_file(&info.id, "workspace/x", b"x").await,
        Err(Error::NotFound(_))
    ));
    p.destroy(&restored.id).await.unwrap();
    p.delete_workspace("ws-1").await.unwrap();
    assert!(m.volumes.lock().unwrap().is_empty());
    p.delete_workspace("ws-1").await.unwrap();
}

#[tokio::test]
async fn restarted_control_plane_reconnects() {
    let (_m, url) = mock().await;
    let first = provider(&url);
    let info = first.create(spec()).await.unwrap();
    first
        .write_file(&info.id, "workspace/a.txt", b"a")
        .await
        .unwrap();
    // 新的进程没有缓存的令牌：确认在运行后经 connect 取回令牌。
    let second = provider(&url);
    assert_eq!(
        second
            .read_file(&info.id, "workspace/a.txt", 10)
            .await
            .unwrap(),
        b"a"
    );
}
