//! FCM：独立生成的签名向量，加上一个会验 JWT 签名的假 OAuth 端点和假 FCM。

use std::sync::{Arc, Mutex};

use aws_lc_rs::signature::{KeyPair, RSA_PKCS1_2048_8192_SHA256, UnparsedPublicKey};
use axum::extract::{Request, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};

use super::*;
use crate::PushTarget;

/// 测试用的 RSA 私钥（Python `cryptography` 生成，只用于测试）。
const TEST_KEY: &str = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDt1lFph25ALPjZ\n3gMY25SQZ+MfgSFVARa1oqxCFmXQQd2dSUGp8opnBz6TKi7I835u2CqPa74AdSj0\nlsnXvtR//dZ00+5ow8p+2ZhOdNiWD0zheXsTPF3ao07QaT/Aw2CVuAg5fh1m7AUF\nYTJPBj8ZVHW4IEBjy3ITD9rJCAbsqz7xkEM3pHloHX+tXHEQn6IWOgLTh2elhg6a\ngv9piUnaTeD5W8GDPU8moWDNDPzt3Km9ip/UuROLv60YqZGTutZQH4j+JaRiT+8Z\nGhzvEnhvgagyUgsIp8ea1MRqzccLr2I4600vkKEkhUZP2Hnz2Tw+rzsa8JLXHbFH\nKPvQ71WFAgMBAAECggEAOWECRSZiR+NRqiYwsxeOkQQvPFOH+h0IIIv9aPhEWej6\nEU8yI1EbaN3Lj++WV+6+qvlF01IYBb4+Qjv6uC0W0UYpLghPNUE/IjlW0F7KPfG1\nB5SqR6rBrdTGV+t8cQHx1E0Q1uYBK+p3D6QyYfRM1syUlfZZ8nmLrOOfUe641PHI\nbA9Yn9S0p8sL1yLT2l4j75DjZT+WlcYV2luEzQdIDnWrX3nlw5U3XomPzISDoaMb\ndKH+djLN09STSIPdVjne20J5a8m+NVoCYugnJNgk1m5GSFmMx0xjCyWk5fHZRDNy\nkbFrvCCMLUytN5KOzXHVUHDHSTljnVs90SB5JJ4LoQKBgQD6RqFpvqrdowae7WSA\nVHKh8RaqpRtAKz3JkvhsaU/Rs+Lw9pK5GHRmHzcTzjrkuTO+mg+xTasca4kX9wlx\n+szVqg95po01MJ0mjuwoaCeLAPjQ472e3OgqfrWNRIMxsOKdqnVPkoywaax6T3h9\nRksASd0MNEMQK5mJJaNmpjRo3QKBgQDzRtvMKRT/B8k24mmm2ectzyYttZ6oTj9W\njrMt6PTRKFlS/FY3flgbRkEvis4kN5g9cWbFqF8yS2vRS+5MFukYYgmzsgVeg/65\nf9thAi1VPaa8GHSB6w/NsPDb70cM4LTK0fqGgGafA9sKAoxYUghFiYD9DFPk+KM1\nc0yVx90AyQKBgQDRdcVnm9Si0+sZnbKsGIEr+Xsv7CjHZqk6h89z5BuSdQvtAWBA\nmy/nvB47bDEr9bhRv9x8VnVrvrApJ253PyCpfb+f331006/icmFBXBIkKvcS1FeB\nmn6P+iX2Ci4Gq3St4dh2dT9b8cURRGuh5O+mWSswKJkr8mF4P9DmexmH3QKBgFL4\nx95J5K9WqHnfnskZaI9nJ05Ps10T0uZipRnzagwsBssW5RDoNoSW4YSlgsk3bOUH\n2FVxp4Yv0wX/L7cj2TxHs6dmAA7MVgROZzQe2fdIn6VncdUdprYwsvVQFpt9yCuk\nkh1tjZKObhZr6BH3aHrO+v9TRQnDA2cne+dZ0zaBAoGAFsY5GVn5IVdksXkUgoSp\n3CtW+pDCOFEwemQTN8tQMlM7y/3fMHDhLYQ+xZdjMDHarhH0DAMUiNjYomCuAJqx\nK/Oyj6+IQv6oYlC8wFGLbbndlI7reJDlvJboJ6DMIYIdgGHg8rNO+JZk1XJqy9hc\n0tF/Txg6IsAwjwh75dQ6eyo=\n-----END PRIVATE KEY-----";

/// 同一把私钥、同样的头和声明，由 Python `cryptography` 独立签出来的 JWT（RS256 是确定性签名）。
const EXPECTED_JWT: &str = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6IjAxMjM0NTY3ODlhYmNkZWYifQ.eyJpc3MiOiJwdXNoQHRoaW5rdGluLXRlc3QuaWFtLmdzZXJ2aWNlYWNjb3VudC5jb20iLCJzY29wZSI6Imh0dHBzOi8vd3d3Lmdvb2dsZWFwaXMuY29tL2F1dGgvZmlyZWJhc2UubWVzc2FnaW5nIiwiYXVkIjoiaHR0cHM6Ly9vYXV0aDIuZ29vZ2xlYXBpcy5jb20vdG9rZW4iLCJpYXQiOjE3NjAwMDAwMDAsImV4cCI6MTc2MDAwMzYwMH0.jVCRjmeyfc5ipsT2KSKIT41hOOJpH8X6KF289NGl730fT7zWNfBwMC0ydKJ8hUyYWepST-USpEruvmst6NQRvC1Ytj5-Gfhz250cMQdKDYRnm0p6fgxt88GK7EdoLcwv1odYfToWvwfY7IdO6JIp9gsbsmiNjDwkQZq_PWya1Y65tVx_1fk1OTMyK247kPKB26hvSWT26VI59TNHv_teO2sErTqGgSQQwzGq4yX8uqmhSoU4ja-I_s5q1WRHb6P0iHgGqrH83Kdk1WGJ1gmb0qQppcGdTG7MVTNsvl7xxWjxtF_S1HT3rluI237slCZgG1BOdYpW1BnAiQTmRmHikQ";

fn account(token_uri: &str) -> ServiceAccount {
    ServiceAccount {
        project_id: "thinktin-test".into(),
        private_key_id: "0123456789abcdef".into(),
        private_key: TEST_KEY.into(),
        client_email: "push@thinktin-test.iam.gserviceaccount.com".into(),
        token_uri: token_uri.into(),
    }
}

fn config(endpoint: &str, token_uri: &str) -> FcmConfig {
    FcmConfig {
        endpoint: endpoint.into(),
        account: account(token_uri),
        approval_channel: "tt_approval".into(),
        default_channel: "tt_results".into(),
    }
}

#[test]
fn jwts_match_an_independent_signature() {
    let client = FcmClient::new(config(ENDPOINT, TOKEN_URI)).unwrap();
    assert_eq!(client.jwt(1_760_000_000).unwrap(), EXPECTED_JWT);
    // 私钥不对就建不起来；调试输出不带私钥。
    let mut bad = config(ENDPOINT, TOKEN_URI);
    bad.account.private_key = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----".into();
    assert!(FcmClient::new(bad).is_err());
    assert!(!format!("{:?}", account(TOKEN_URI)).contains("BEGIN"));
}

#[derive(Default)]
struct Fake {
    /// 发出去的访问令牌数。
    tokens: Mutex<usize>,
    sent: Mutex<Vec<(String, Value)>>,
    /// 收到过的“stale”令牌的请求（第一次按过期拒绝）。
    stale_seen: Mutex<bool>,
}

fn fcm_error(status: StatusCode, code: &str, grpc: &str, message: &str) -> Response {
    (
        status,
        [("retry-after", "17")],
        axum::Json(json!({ "error": {
            "code": status.as_u16(), "message": message, "status": grpc,
            "details": [{ "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", "errorCode": code }]
        }})),
    )
        .into_response()
}

async fn handler(State(fake): State<Arc<Fake>>, req: Request) -> Response {
    let path = req.uri().path().to_owned();
    let auth = req
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default()
        .to_owned();
    let body = axum::body::to_bytes(req.into_body(), 1 << 20)
        .await
        .unwrap();
    let body = String::from_utf8(body.to_vec()).unwrap();
    if path == "/token" {
        // 验 JWT：签名、受众、范围。
        let assertion = body
            .split('&')
            .find_map(|kv| kv.strip_prefix("assertion="))
            .unwrap_or_default();
        assert!(body.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer"));
        let (input, sig) = assertion.rsplit_once('.').unwrap();
        let der = pem_der(TEST_KEY).unwrap();
        let key = RsaKeyPair::from_pkcs8(&der).unwrap();
        let public = UnparsedPublicKey::new(&RSA_PKCS1_2048_8192_SHA256, key.public_key().as_ref());
        if public
            .verify(input.as_bytes(), &URL_SAFE_NO_PAD.decode(sig).unwrap())
            .is_err()
        {
            return (
                StatusCode::BAD_REQUEST,
                axum::Json(json!({ "error": "invalid_grant" })),
            )
                .into_response();
        }
        let claims: Value = serde_json::from_slice(
            &URL_SAFE_NO_PAD
                .decode(input.split('.').nth(1).unwrap())
                .unwrap(),
        )
        .unwrap();
        assert_eq!(claims["scope"], SCOPE);
        assert!(claims["aud"].as_str().unwrap().ends_with("/token"));
        let mut n = fake.tokens.lock().unwrap();
        *n += 1;
        return axum::Json(json!({ "access_token": format!("at-{n}"), "expires_in": 3599, "token_type": "Bearer" }))
            .into_response();
    }
    assert_eq!(path, "/v1/projects/thinktin-test/messages:send");
    let v: Value = serde_json::from_str(&body).unwrap();
    let token = v["message"]["token"].as_str().unwrap().to_owned();
    fake.sent.lock().unwrap().push((auth.clone(), v));
    match token.split(':').next().unwrap() {
        "gone" => fcm_error(
            StatusCode::NOT_FOUND,
            "UNREGISTERED",
            "NOT_FOUND",
            "Requested entity was not found.",
        ),
        "other" => fcm_error(
            StatusCode::FORBIDDEN,
            "SENDER_ID_MISMATCH",
            "PERMISSION_DENIED",
            "SenderId mismatch",
        ),
        "busy" => fcm_error(
            StatusCode::TOO_MANY_REQUESTS,
            "QUOTA_EXCEEDED",
            "RESOURCE_EXHAUSTED",
            "quota",
        ),
        "down" => fcm_error(
            StatusCode::SERVICE_UNAVAILABLE,
            "UNAVAILABLE",
            "UNAVAILABLE",
            "try later",
        ),
        "bad0" => fcm_error(
            StatusCode::BAD_REQUEST,
            "INVALID_ARGUMENT",
            "INVALID_ARGUMENT",
            "The registration token is not a valid FCM registration token",
        ),
        "json" => fcm_error(
            StatusCode::BAD_REQUEST,
            "INVALID_ARGUMENT",
            "INVALID_ARGUMENT",
            "Invalid JSON payload received.",
        ),
        "stale" => {
            let mut seen = fake.stale_seen.lock().unwrap();
            if !*seen && auth == "Bearer at-1" {
                *seen = true;
                return (StatusCode::UNAUTHORIZED, axum::Json(json!({ "error": { "code": 401, "status": "UNAUTHENTICATED", "message": "expired" } })))
                    .into_response();
            }
            axum::Json(json!({ "name": "projects/thinktin-test/messages/2" })).into_response()
        }
        _ => axum::Json(json!({ "name": "projects/thinktin-test/messages/1" })).into_response(),
    }
}

async fn setup() -> (FcmClient, Arc<Fake>) {
    let fake = Arc::new(Fake::default());
    let app = axum::Router::new()
        .fallback(handler)
        .with_state(fake.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let base = format!("http://{addr}");
    let client = FcmClient::new(config(&base, &format!("{base}/token"))).unwrap();
    (client, fake)
}

fn device(prefix: &str) -> String {
    format!("{prefix}:{}", "A1b2_c3-".repeat(8))
}

fn message(kind: PushKind) -> PushMessage {
    PushMessage {
        kind,
        title: "Research helper".into(),
        body: "Needs your approval: run `rm -rf build`".into(),
        thread_id: Some("run-1".into()),
        collapse_id: Some("approval-9".into()),
        target: PushTarget {
            instance_id: Some("inst-1".into()),
            run_id: Some("run-1".into()),
            approval_id: Some("appr-9".into()),
            plan_id: None,
            inbox_id: Some("inbox-3".into()),
            vault_request_id: None,
        },
        ttl: Some(Duration::from_secs(3600)),
        ai_generated: false,
        locale: proto::domain::Locale::En,
        subtype: None,
        badge: None,
    }
}

#[tokio::test]
async fn notifications_go_out_with_ids_only_and_one_access_token() {
    let (client, fake) = setup().await;
    let out = client
        .send(&device("ok"), &message(PushKind::Approval))
        .await;
    assert_eq!(
        out,
        PushOutcome::Delivered {
            id: Some("projects/thinktin-test/messages/1".into())
        }
    );
    let mut m = message(PushKind::RunFinished);
    m.collapse_id = None;
    m.ttl = None;
    m.ai_generated = true;
    m.body = "Sunny today".into();
    client.send(&device("ok"), &m).await;
    // 访问令牌缓存着：两条通知只换一次。
    assert_eq!(*fake.tokens.lock().unwrap(), 1);
    let sent = fake.sent.lock().unwrap().clone();
    let (auth, v) = &sent[0];
    assert_eq!(auth, "Bearer at-1");
    let msg = &v["message"];
    assert_eq!(msg["notification"]["title"], "Research helper");
    assert_eq!(msg["data"]["tt_kind"], "approval");
    assert_eq!(msg["data"]["tt_approval"], "appr-9");
    assert_eq!(msg["data"]["tt_inbox"], "inbox-3");
    assert!(msg["data"].get("tt_plan").is_none());
    let a = &msg["android"];
    assert_eq!(a["priority"], "HIGH");
    assert_eq!(a["ttl"], "3600s");
    assert_eq!(a["collapse_key"], "approval-9");
    assert_eq!(a["notification"]["channel_id"], "tt_approval");
    assert_eq!(a["notification"]["tag"], "approval-9");
    // 普通结果：默认渠道、普通优先级、默认保留一天；agent 写的正文带英文的 AI 标识。
    let a = &sent[1].1["message"];
    assert_eq!(a["android"]["priority"], "NORMAL");
    assert_eq!(a["android"]["ttl"], "86400s");
    assert_eq!(a["android"]["notification"]["channel_id"], "tt_results");
    assert!(a["android"].get("collapse_key").is_none());
    assert_eq!(a["notification"]["body"], "[AI-generated] Sunny today");
    drop(sent);
    // 保险箱请求（10.7）：和审批一样走审批渠道、高优先级，带请求 id；提醒带子类型。
    let mut m = message(PushKind::VaultRequest);
    m.target.vault_request_id = Some("vr-7".into());
    m.subtype = Some("x_y".into());
    m.badge = Some(4);
    let p = client.payload(&device("ok"), &m)["message"].clone();
    assert_eq!(p["android"]["notification"]["notification_count"], 4);
    assert_eq!(
        (
            &p["data"]["tt_kind"],
            &p["data"]["tt_vault_request"],
            &p["data"]["tt_subtype"]
        ),
        (&json!("vault_request"), &json!("vr-7"), &json!("x_y"))
    );
    assert_eq!(p["android"]["priority"], "HIGH");
    assert_eq!(p["android"]["notification"]["channel_id"], "tt_approval");
}

#[tokio::test]
async fn errors_map_to_outcomes() {
    let (client, fake) = setup().await;
    let m = message(PushKind::RunFailed);
    let outcome = |o: PushOutcome| match o {
        PushOutcome::Delivered { .. } => "delivered",
        PushOutcome::InvalidToken { .. } => "invalid",
        PushOutcome::Retry { .. } => "retry",
        PushOutcome::Rejected { .. } => "rejected",
    };
    for (prefix, want) in [
        ("gone", "invalid"),
        ("other", "invalid"),
        ("bad0", "invalid"),
        ("busy", "retry"),
        ("down", "retry"),
        ("json", "rejected"),
    ] {
        assert_eq!(
            outcome(client.send(&device(prefix), &m).await),
            want,
            "{prefix}"
        );
    }
    match client.send(&device("busy"), &m).await {
        PushOutcome::Retry { after, reason } => {
            assert_eq!(after, Some(Duration::from_secs(17)));
            assert!(reason.contains("QUOTA_EXCEEDED"), "{reason}");
        }
        other => panic!("unexpected {other:?}"),
    }
    // 格式不对的令牌不发请求。
    let before = fake.sent.lock().unwrap().len();
    assert_eq!(outcome(client.send("short", &m).await), "invalid");
    assert_eq!(fake.sent.lock().unwrap().len(), before);
    // 访问令牌被拒：换一个再发一次就成了。
    assert_eq!(
        outcome(client.send(&device("stale"), &m).await),
        "delivered"
    );
    assert_eq!(*fake.tokens.lock().unwrap(), 2);
}
