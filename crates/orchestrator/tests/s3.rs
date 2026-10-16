//! S3 兼容存储：对着一个会验签名的假 S3 服务上传、下载、删除。
//! 假服务按收到的请求（Host 头、线上的路径、正文）重新算签名，和请求里的对得上才处理。

use std::collections::HashMap;
use std::io;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::{Request, State};
use axum::http::{Method, StatusCode};
use axum::response::{IntoResponse, Response};
use orchestrator::artifacts::BlobStore;
use orchestrator::s3::{Credentials, S3BlobStore, S3Config, authorization};
use sha2::{Digest, Sha256};

const AKID: &str = "AKIDTHINKTINTEST";
const SECRET: &str = "s3-test-secret/with+symbols";
const REGION: &str = "oss-cn-hangzhou";

#[derive(Default)]
struct Fake {
    objects: Mutex<HashMap<String, Vec<u8>>>,
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn error(status: StatusCode, code: &str) -> Response {
    (
        status,
        format!("<?xml version=\"1.0\"?><Error><Code>{code}</Code></Error>"),
    )
        .into_response()
}

async fn s3(State(fake): State<Arc<Fake>>, req: Request) -> Response {
    let (parts, body) = req.into_parts();
    let body = axum::body::to_bytes(body, 1 << 24).await.unwrap();
    let header = |k: &str| {
        parts
            .headers
            .get(k)
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default()
            .to_owned()
    };
    let payload: [u8; 32] = Sha256::digest(&body).into();
    let payload = hex(&payload);
    if header("x-amz-content-sha256") != payload {
        return error(StatusCode::BAD_REQUEST, "XAmzContentSHA256Mismatch");
    }
    let path = parts.uri.path().to_owned();
    let mut signed = vec![
        ("host".to_owned(), header("host")),
        ("x-amz-content-sha256".to_owned(), payload.clone()),
        ("x-amz-date".to_owned(), header("x-amz-date")),
    ];
    let want = authorization(
        &Credentials {
            access_key_id: AKID,
            secret_access_key: SECRET,
            region: REGION,
        },
        parts.method.as_str(),
        &path,
        &mut signed,
        &payload,
        &header("x-amz-date"),
    );
    if header("authorization") != want {
        return error(StatusCode::FORBIDDEN, "SignatureDoesNotMatch");
    }
    let mut objects = fake.objects.lock().unwrap();
    match parts.method {
        Method::PUT => {
            objects.insert(path, body.to_vec());
            StatusCode::OK.into_response()
        }
        Method::GET => match objects.get(&path) {
            Some(b) => (StatusCode::OK, b.clone()).into_response(),
            None => error(StatusCode::NOT_FOUND, "NoSuchKey"),
        },
        Method::DELETE => {
            objects.remove(&path);
            StatusCode::NO_CONTENT.into_response()
        }
        _ => StatusCode::METHOD_NOT_ALLOWED.into_response(),
    }
}

#[tokio::test]
async fn objects_round_trip_through_a_signing_s3() {
    let fake = Arc::new(Fake::default());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let app = axum::Router::new().fallback(s3).with_state(fake.clone());
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let cfg = S3Config {
        endpoint: format!("http://{addr}"),
        region: REGION.into(),
        bucket: "artifacts".into(),
        prefix: "test/".into(),
        path_style: true,
        access_key_id: AKID.into(),
        secret_access_key: SECRET.into(),
        timeout: Duration::from_secs(5),
    };
    let store = S3BlobStore::new(cfg.clone()).unwrap();

    // 上传：键里的空格、中文按 S3 的规则编码，签名和线上的路径一致。
    store.put("ab/报告 1.md", b"ciphertext").await.unwrap();
    let keys: Vec<String> = fake.objects.lock().unwrap().keys().cloned().collect();
    assert_eq!(
        keys,
        ["/artifacts/test/ab/%E6%8A%A5%E5%91%8A%201.md".to_string()]
    );
    assert_eq!(
        store.get("ab/报告 1.md").await.unwrap(),
        b"ciphertext".to_vec()
    );
    // 空正文也能传。
    store.put("empty", b"").await.unwrap();
    assert_eq!(store.get("empty").await.unwrap(), Vec::<u8>::new());

    // 不存在的：下载报“没有”，删除算成功。
    let missing = store.get("nope").await.unwrap_err();
    assert_eq!(missing.kind(), io::ErrorKind::NotFound);
    store.delete("ab/报告 1.md").await.unwrap();
    store.delete("ab/报告 1.md").await.unwrap();
    assert_eq!(
        store.get("ab/报告 1.md").await.unwrap_err().kind(),
        io::ErrorKind::NotFound
    );

    // 密钥不对：签名对不上，错误里带存储服务给的错误码，不带别的内容。
    let wrong = S3BlobStore::new(S3Config {
        secret_access_key: "wrong".into(),
        ..cfg
    })
    .unwrap();
    let err = wrong.put("x", b"y").await.unwrap_err();
    assert!(err.to_string().contains("403"), "{err}");
    assert!(err.to_string().contains("SignatureDoesNotMatch"), "{err}");
    assert!(
        !fake
            .objects
            .lock()
            .unwrap()
            .contains_key("/artifacts/test/x")
    );
}
