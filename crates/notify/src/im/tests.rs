use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use axum::extract::{Path, Query, State};
use axum::response::IntoResponse;
use axum::routing::post;

use super::*;

// 两家文档里的算法，用 Python 的 hmac 独立算出来的值（docs/im-channels.md 有算法出处）。
#[test]
fn signatures_match_independent_vectors() {
    assert_eq!(
        feishu_sign("demo", 1_599_360_473),
        "l1N0gAcBjdwBvGm1xMjOF0XSyaLRpR7tuO5dHfhAYc8="
    );
    let ding = dingtalk_sign("SECthisissecret", 1_700_000_000_000);
    assert_eq!(ding, "azrqDJMNHPof7+WgNaBmtWpetwsQOkG9SrD5xjc7Svs=");
    assert_eq!(
        url_encode_base64(&ding),
        "azrqDJMNHPof7%2BWgNaBmtWpetwsQOkG9SrD5xjc7Svs%3D"
    );
}

#[test]
fn text_is_cut_on_a_character_boundary() {
    let s = "任务完成".repeat(300);
    let t = truncate(&s, MAX_TEXT_BYTES);
    assert!(t.len() <= MAX_TEXT_BYTES && t.ends_with('…'));
    assert_eq!(truncate("短", 10), "短");
}

#[test]
fn the_production_client_builds() {
    assert!(ImClient::new().is_ok());
    let hook = ImHook {
        vendor: ImVendor::Dingtalk,
        token: Zeroizing::new("0123456789abcdef".into()),
        secret: Some(Zeroizing::new("SECsecret-value".into())),
    };
    assert!(!format!("{hook:?}").contains("0123456789abcdef"));
    assert!(!format!("{hook:?}").contains("secret-value"));
}

const FEISHU_SECRET: &str = "feishu-secret";
const DING_SECRET: &str = "SECding-secret";

/// 收到的请求：token、地址里的参数、请求体。
type Seen = (String, HashMap<String, String>, Value);

#[derive(Default)]
struct Fake {
    seen: Mutex<Vec<Seen>>,
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

async fn feishu(
    State(fake): State<Arc<Fake>>,
    Path(token): Path<String>,
    axum::Json(v): axum::Json<Value>,
) -> axum::response::Response {
    fake.seen
        .lock()
        .unwrap()
        .push((token.clone(), HashMap::new(), v.clone()));
    let code = if token.starts_with("signed") {
        let ts: u64 = v["timestamp"].as_str().unwrap_or("0").parse().unwrap_or(0);
        let fresh = now_secs().abs_diff(ts) < 3600;
        if fresh && v["sign"] == json!(feishu_sign(FEISHU_SECRET, ts)) {
            0
        } else {
            19021
        }
    } else {
        match &token[..4] {
            "gone" => 19001,
            "keyw" => 19024,
            "busy" => 11232,
            _ => 0,
        }
    };
    axum::Json(json!({ "code": code, "msg": "whatever", "data": {} })).into_response()
}

async fn wecom(
    State(fake): State<Arc<Fake>>,
    Query(q): Query<HashMap<String, String>>,
    axum::Json(v): axum::Json<Value>,
) -> axum::response::Response {
    let key = q["key"].clone();
    fake.seen.lock().unwrap().push((key.clone(), q, v));
    let code = match &key[..4] {
        "gone" => 93000,
        "busy" => 45009,
        _ => 0,
    };
    axum::Json(json!({ "errcode": code, "errmsg": "invalid webhook url, from ip: 203.0.113.9" }))
        .into_response()
}

async fn dingtalk(
    State(fake): State<Arc<Fake>>,
    Query(q): Query<HashMap<String, String>>,
    axum::Json(v): axum::Json<Value>,
) -> axum::response::Response {
    let token = q["access_token"].clone();
    fake.seen
        .lock()
        .unwrap()
        .push((token.clone(), q.clone(), v));
    let code = if token.starts_with("signed") {
        let ts: u64 = q.get("timestamp").and_then(|t| t.parse().ok()).unwrap_or(0);
        let fresh = (now_secs() * 1000).abs_diff(ts) < 3_600_000;
        if fresh && q.get("sign") == Some(&dingtalk_sign(DING_SECRET, ts)) {
            0
        } else {
            310000
        }
    } else {
        match &token[..4] {
            "gone" => 300005,
            "busy" => 410100,
            _ => 0,
        }
    };
    // 钉钉文档的例子里 errcode 是字符串。
    axum::Json(json!({ "errcode": code.to_string(), "errmsg": "ok" })).into_response()
}

async fn setup() -> (ImClient, Arc<Fake>, String) {
    let fake = Arc::new(Fake::default());
    let app = axum::Router::new()
        .route("/open-apis/bot/v2/hook/{token}", post(feishu))
        .route("/cgi-bin/webhook/send", post(wecom))
        .route("/robot/send", post(dingtalk))
        .route(
            "/moved/{token}",
            post(|| async {
                (
                    axum::http::StatusCode::FOUND,
                    [("location", "/open-apis/bot/v2/hook/x")],
                )
                    .into_response()
            }),
        )
        .with_state(fake.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap().to_string();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let http = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap();
    let a = addr.clone();
    let client = ImClient::with_bases(http, move |v| match v {
        ImVendor::Feishu | ImVendor::Lark => format!("http://{a}/open-apis/bot/v2/hook/"),
        ImVendor::Wecom => format!("http://{a}/cgi-bin/webhook/send?key="),
        ImVendor::Dingtalk => format!("http://{a}/robot/send?access_token="),
    });
    (client, fake, addr)
}

fn hook(vendor: ImVendor, token: &str, secret: Option<&str>) -> ImHook {
    ImHook {
        vendor,
        token: Zeroizing::new(token.into()),
        secret: secret.map(|s| Zeroizing::new(s.into())),
    }
}

fn message(locale: Locale) -> ImMessage {
    ImMessage {
        title: "【ThinkTin】每日新闻".into(),
        text: "【AI 生成】今天的要点…… <at user_id=\"all\">所有人</at>".into(),
        locale,
    }
}

#[tokio::test]
async fn messages_are_signed_and_never_mention_anyone() {
    let (client, fake, _) = setup().await;
    let msg = message(Locale::ZhCn);
    for h in [
        hook(ImVendor::Feishu, "signed-feishu-0001", Some(FEISHU_SECRET)),
        hook(ImVendor::Lark, "plain-lark-0001", None),
        hook(ImVendor::Wecom, "plain-wecom-0001", None),
        hook(ImVendor::Dingtalk, "signed-ding-0001", Some(DING_SECRET)),
        hook(ImVendor::Dingtalk, "plain-ding-0001", None),
    ] {
        let out = client.send(&h, &msg).await;
        assert!(
            matches!(out, PushOutcome::Delivered { .. }),
            "{:?}: {out:?}",
            h.vendor
        );
    }
    let seen = fake.seen.lock().unwrap();
    // 飞书：富文本的纯文本节点（不解析 <at>），中文的 zh_cn，签名在请求体里。
    let (_, _, f) = &seen[0];
    assert_eq!(f["msg_type"], "post");
    let post = &f["content"]["post"]["zh_cn"];
    assert_eq!(post["title"], "【ThinkTin】每日新闻");
    assert_eq!(post["content"][0][0]["tag"], "text");
    assert_eq!(post["content"][0][0]["text"], msg.text);
    assert!(f["timestamp"].is_string() && f["sign"].is_string());
    assert!(seen[1].2.get("sign").is_none());
    // 企业微信：纯文本，没有 mentioned_list。
    let (_, _, w) = &seen[2];
    assert_eq!(w["msgtype"], "text");
    assert_eq!(w["text"]["content"], format!("{}\n{}", msg.title, msg.text));
    assert!(w["text"].get("mentioned_list").is_none());
    // 钉钉：签名在地址里，不 @ 人。
    let (_, q, d) = &seen[3];
    assert!(q.contains_key("timestamp") && q.contains_key("sign"));
    assert_eq!(d["at"]["isAtAll"], false);
    assert!(!seen[4].1.contains_key("sign"));
}

#[tokio::test]
async fn english_users_get_the_en_us_post() {
    let (client, fake, _) = setup().await;
    let out = client
        .send(
            &hook(ImVendor::Lark, "plain-lark-0002", None),
            &message(Locale::En),
        )
        .await;
    assert!(matches!(out, PushOutcome::Delivered { .. }));
    assert!(fake.seen.lock().unwrap()[0].2["content"]["post"]["en_us"].is_object());
}

#[tokio::test]
async fn vendor_errors_map_to_disable_fix_or_retry() {
    let (client, _, _) = setup().await;
    let msg = message(Locale::ZhCn);
    let cases = [
        (hook(ImVendor::Feishu, "gone-feishu-01", None), "gone"),
        (hook(ImVendor::Feishu, "keyw-feishu-01", None), "rejected"),
        (hook(ImVendor::Feishu, "busy-feishu-01", None), "retry"),
        (
            hook(ImVendor::Feishu, "signed-feishu-02", Some("wrong-secret-x")),
            "rejected",
        ),
        (hook(ImVendor::Wecom, "gone-wecom-001", None), "gone"),
        (hook(ImVendor::Wecom, "busy-wecom-001", None), "retry"),
        (hook(ImVendor::Dingtalk, "gone-ding-0001", None), "gone"),
        (hook(ImVendor::Dingtalk, "busy-ding-0001", None), "retry"),
        (
            hook(
                ImVendor::Dingtalk,
                "signed-ding-02",
                Some("SECwrong-secret"),
            ),
            "rejected",
        ),
        (hook(ImVendor::Dingtalk, "bad/token?x=1", None), "gone"),
    ];
    for (h, want) in cases {
        let out = client.send(&h, &msg).await;
        let (got, reason) = match &out {
            PushOutcome::InvalidToken { reason } => ("gone", reason),
            PushOutcome::Rejected { reason } => ("rejected", reason),
            PushOutcome::Retry { reason, .. } => ("retry", reason),
            PushOutcome::Delivered { .. } => panic!("{}: delivered", h.token.as_str()),
        };
        assert_eq!(got, want, "{}: {out:?}", h.token.as_str());
        // 原因是我们自己写的：不带 token，也不照抄对方的 errmsg（企业微信的带调用方 IP）。
        assert!(
            !reason.contains(h.token.as_str()) && !reason.contains("203.0.113.9"),
            "{reason}"
        );
    }
    let PushOutcome::Retry { after, .. } = client
        .send(&hook(ImVendor::Dingtalk, "busy-ding-0002", None), &msg)
        .await
    else {
        panic!("dingtalk throttle");
    };
    assert_eq!(after, Some(DINGTALK_THROTTLE));
}

#[tokio::test]
async fn redirects_are_not_followed_and_network_errors_hide_the_token() {
    let (_, _, addr) = setup().await;
    let http = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap();
    let a = addr.clone();
    let moved = ImClient::with_bases(http.clone(), move |_| format!("http://{a}/moved/"));
    let out = moved
        .send(
            &hook(ImVendor::Feishu, "redirected-0001", None),
            &message(Locale::ZhCn),
        )
        .await;
    assert!(matches!(out, PushOutcome::Rejected { .. }), "{out:?}");
    let closed = ImClient::with_bases(http, |_| {
        "http://127.0.0.1:9/robot/send?access_token=".into()
    });
    let out = closed
        .send(
            &hook(ImVendor::Dingtalk, "secret-token-0001", None),
            &message(Locale::ZhCn),
        )
        .await;
    let PushOutcome::Retry { reason, .. } = out else {
        panic!("{out:?}")
    };
    assert!(!reason.contains("secret-token-0001"), "{reason}");
}
