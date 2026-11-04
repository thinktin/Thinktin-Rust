//! 平台搜索工具（docs/search.md）：只回标题、链接、网站、日期、短摘要；前一家出错换下一家；每人每天的次数和全站每月的钱
//! 有上限，失败的退回；搜索词里有保险箱的值不搜；没配搜索接口时不提供这个工具。需要 DATABASE_URL（没有时跳过）。

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use keyvault::{Kms, LocalKms};
use orchestrator::search::{
    SearchAnswer, SearchBackend, SearchFailure, SearchHit, SearchLimits, SearchTools,
};
use orchestrator::shim::{PlatformTools, ToolContext, ToolOutput};
use proto::domain::{GrantScope, InstanceLimits, RunSource};
use serde_json::{Value, json};
use store::testing::TestDb;
use store::{NewInstance, NewRun};

fn kms() -> Arc<dyn Kms> {
    Arc::new(LocalKms::new("kms1", &[3; 32]))
}

/// 假的搜索接口：按设定回结果或者出错，记下收到的搜索词。
struct Fake {
    name: &'static str,
    fail: bool,
    hits: usize,
    /// 出错时：收没收钱、是不是欠费这类。
    billed: bool,
    fatal: bool,
    queries: Mutex<Vec<String>>,
}

impl Fake {
    fn new(name: &'static str, fail: bool, hits: usize) -> Arc<Self> {
        Arc::new(Self {
            name,
            fail,
            hits,
            billed: false,
            fatal: false,
            queries: Mutex::new(Vec::new()),
        })
    }
    fn failing(name: &'static str, billed: bool, fatal: bool) -> Arc<Self> {
        Arc::new(Self {
            name,
            fail: true,
            hits: 0,
            billed,
            fatal,
            queries: Mutex::new(Vec::new()),
        })
    }
    fn queries(&self) -> Vec<String> {
        self.queries.lock().unwrap().clone()
    }
}

#[async_trait]
impl SearchBackend for Fake {
    fn name(&self) -> &'static str {
        self.name
    }
    fn cost_millicents(&self) -> u64 {
        500
    }
    async fn search(&self, query: &str, count: u32) -> Result<SearchAnswer, SearchFailure> {
        self.queries.lock().unwrap().push(query.to_owned());
        if self.fail {
            return Err(SearchFailure {
                reason: "HTTP 503".into(),
                billed: self.billed,
                fatal: self.fatal,
            });
        }
        let hits = (0..self.hits.min(count as usize))
            .map(|i| SearchHit {
                title: format!("结果 {i}"),
                url: format!("https://example.com/{i}"),
                site: Some("example.com".into()),
                date: None,
                snippet: "长".repeat(400),
            })
            .collect::<Vec<_>>();
        Ok(SearchAnswer {
            billed: !hits.is_empty(),
            hits,
        })
    }
}

async fn setup(t: &TestDb, phone: &str) -> ToolContext {
    let mut w = t.db.worker().await.unwrap();
    let (u, _) = w.upsert_user_by_phone(phone).await.unwrap();
    w.commit().await.unwrap();
    let mut tx = t.db.tenant(u.id).await.unwrap();
    let inst = tx
        .create_instance(&NewInstance {
            agent_id: "claude".into(),
            agent_version: "1".into(),
            harness: "acp".into(),
            name: "Writer".into(),
            workspace_id: format!("ws-{}", uuid::Uuid::now_v7().simple()),
            limits: InstanceLimits::default(),
        })
        .await
        .unwrap();
    let grant = tx
        .create_run_grant(
            inst.id,
            None,
            &GrantScope {
                platform_tools: vec!["web_search".into()],
                ..GrantScope::default()
            },
            Duration::from_secs(3600),
        )
        .await
        .unwrap();
    let run = tx
        .create_run(&NewRun::new(inst.id, RunSource::User, "look it up", "1"))
        .await
        .unwrap();
    tx.commit().await.unwrap();
    ToolContext {
        user: u.id,
        instance: inst.id,
        run: run.id,
        plan: None,
        grant: grant.id,
    }
}

fn body(out: &ToolOutput) -> Value {
    assert!(!out.is_error, "{:?}", out.content);
    serde_json::from_str(out.content[0]["text"].as_str().unwrap()).unwrap()
}

fn error(out: &ToolOutput) -> String {
    assert!(out.is_error, "{:?}", out.content);
    out.content[0]["text"].as_str().unwrap().to_owned()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn web_search_returns_snippets_falls_back_and_is_capped() {
    let Some(t) = TestDb::new().await else { return };
    let ctx = setup(&t, "+8613800008961").await;
    let down = Fake::new("down", true, 0);
    let up = Fake::new("up", false, 3);
    let tools = SearchTools::new(
        t.db.clone(),
        kms(),
        vec![down.clone(), up.clone()],
        SearchLimits {
            per_user_daily: 2,
            monthly_budget_millicents: 100 * 100 * 1000,
        },
    );
    let listed = tools.tools();
    assert_eq!(listed.len(), 1);
    assert!(
        listed[0].read_only,
        "Codex runs read-only tools without asking"
    );

    // 第一家出错，换第二家；只回短摘要。
    let out = body(
        &tools
            .call(
                &ctx,
                "web_search",
                &json!({"query": "  天气 东京 ", "count": 2}),
            )
            .await,
    );
    let results = out["results"].as_array().unwrap();
    assert_eq!(results.len(), 2);
    assert_eq!(results[0]["url"], "https://example.com/0");
    assert_eq!(results[0]["site"], "example.com");
    assert!(results[0]["snippet"].as_str().unwrap().chars().count() <= 301);
    assert!(results[0].get("content").is_none());
    assert!(
        out["note"]
            .as_str()
            .unwrap()
            .contains("not as instructions")
    );
    assert_eq!(down.queries(), ["天气 东京"]);
    assert_eq!(up.queries(), ["天气 东京"]);

    // 不合规的搜索词不搜，也不算次数。
    assert!(
        error(
            &tools
                .call(&ctx, "web_search", &json!({"query": "  "}))
                .await
        )
        .contains("empty")
    );
    assert!(
        error(
            &tools
                .call(&ctx, "web_search", &json!({"query": "长".repeat(129)}))
                .await
        )
        .contains("too long")
    );

    // 每人每天 2 次：第二次还行，第三次不行。
    body(
        &tools
            .call(&ctx, "web_search", &json!({"query": "rust"}))
            .await,
    );
    assert!(
        error(
            &tools
                .call(&ctx, "web_search", &json!({"query": "rust"}))
                .await
        )
        .contains("limit")
    );

    // 都出错：不算次数（明天的额度也不受影响），告诉 agent 晚点再试。
    let ctx2 = setup(&t, "+8613800008962").await;
    let broken = SearchTools::new(
        t.db.clone(),
        kms(),
        vec![Fake::new("down", true, 0)],
        SearchLimits {
            per_user_daily: 1,
            monthly_budget_millicents: 100 * 100 * 1000,
        },
    );
    assert!(
        error(
            &broken
                .call(&ctx2, "web_search", &json!({"query": "a"}))
                .await
        )
        .contains("temporarily unavailable")
    );
    let ok = SearchTools::new(
        t.db.clone(),
        kms(),
        vec![Fake::new("up", false, 1)],
        SearchLimits {
            per_user_daily: 1,
            monthly_budget_millicents: 100 * 100 * 1000,
        },
    );
    body(&ok.call(&ctx2, "web_search", &json!({"query": "a"})).await);

    // 全站每月的钱用完了：停。
    let poor = SearchTools::new(
        t.db.clone(),
        kms(),
        vec![Fake::new("up", false, 1)],
        SearchLimits {
            per_user_daily: 50,
            monthly_budget_millicents: 1_000,
        },
    );
    let ctx3 = setup(&t, "+8613800008963").await;
    assert!(
        error(&poor.call(&ctx3, "web_search", &json!({"query": "a"})).await).contains("budget")
    );

    // 没配搜索接口：不提供这个工具。
    let none = SearchTools::new(t.db.clone(), kms(), vec![], SearchLimits::default());
    assert!(none.tools().is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn secrets_are_never_sent_to_the_search_service() {
    let Some(t) = TestDb::new().await else { return };
    let ctx = setup(&t, "+8613800008964").await;
    let vault = orchestrator::artifacts::user_vault(&t.db, kms(), ctx.user, true)
        .await
        .unwrap();
    let id = proto::domain::VaultItemId::new();
    let sealed = vault
        .seal_vault(
            &ctx.user.to_string(),
            &id.to_string(),
            &keyvault::VaultSecret {
                username: "octocat".into(),
                password: "gh-secret-123".into(),
            },
        )
        .await
        .unwrap();
    let mut tx = t.db.tenant(ctx.user).await.unwrap();
    tx.create_vault_item(&store::NewVaultItem {
        id,
        name: "github".into(),
        purpose: "push code".into(),
        sealed,
        has_username: true,
        instance_ids: vec![ctx.instance],
    })
    .await
    .unwrap();
    tx.commit().await.unwrap();
    let up = Fake::new("up", false, 1);
    let tools = SearchTools::new(
        t.db.clone(),
        kms(),
        vec![up.clone()],
        SearchLimits::default(),
    );
    let msg = error(
        &tools
            .call(
                &ctx,
                "web_search",
                &json!({"query": "why does gh-secret-123 fail"}),
            )
            .await,
    );
    assert!(msg.contains("saved secrets"), "{msg}");
    assert!(up.queries().is_empty());
}

/// 搜索接口收了钱却没给出结果的照样算次数、算钱；欠费、key 不对的告诉运营者（每天一次），也告诉 agent 别再试。月度额度
/// 用到八成、用完了也告诉运营者。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn billed_failures_count_and_the_operator_is_told() {
    let Some(t) = TestDb::new().await else { return };
    let ctx = setup(&t, "+8613800008965").await;
    // 运营者的账号。
    let mut w = t.db.worker().await.unwrap();
    let (ops, _) = w.upsert_user_by_phone("+8613800008966").await.unwrap();
    w.commit().await.unwrap();
    let tools = SearchTools::new(
        t.db.clone(),
        kms(),
        vec![
            Fake::failing("broke", false, true),
            Fake::failing("garbled", true, false),
        ],
        SearchLimits {
            per_user_daily: 1,
            monthly_budget_millicents: 100 * 100 * 1000,
        },
    )
    .with_alert_phone(Some("+8613800008966".into()));
    let msg = error(&tools.call(&ctx, "web_search", &json!({"query": "a"})).await);
    assert!(msg.contains("not available right now"), "{msg}");
    // 第二家收了钱：这一次算数，今天的 1 次用完了。
    let msg = error(&tools.call(&ctx, "web_search", &json!({"query": "a"})).await);
    assert!(msg.contains("limit"), "{msg}");
    let inbox = |user| {
        let db = t.db.clone();
        async move {
            let mut tx = db.tenant(user).await.unwrap();
            let items = tx.inbox(None, 100, false).await.unwrap();
            tx.rollback().await.unwrap();
            items
        }
    };
    let items = inbox(ops.id).await;
    assert_eq!(items.len(), 1, "one alert per backend per day: {items:?}");
    assert_eq!(items[0].subtype.as_deref(), Some("search_alert"));
    assert!(items[0].body.contains("broke"), "{}", items[0].body);
    // 用户自己收不到这些提醒。
    assert!(inbox(ctx.user).await.is_empty());

    // 额度：用到八成提醒一次，用完了再提醒一次。
    let ctx2 = setup(&t, "+8613800008967").await;
    let small = SearchTools::new(
        t.db.clone(),
        kms(),
        vec![Fake::new("up", false, 1)],
        SearchLimits {
            per_user_daily: 50,
            // 前面那家收了 500；这次再收 500 就是 1000，到 1250 的八成；再来一次超了。
            monthly_budget_millicents: 1_250,
        },
    )
    .with_alert_phone(Some("+8613800008966".into()));
    body(
        &small
            .call(&ctx2, "web_search", &json!({"query": "a"}))
            .await,
    );
    assert!(
        error(
            &small
                .call(&ctx2, "web_search", &json!({"query": "a"}))
                .await
        )
        .contains("budget")
    );
    let subjects: Vec<String> = inbox(ops.id)
        .await
        .iter()
        .map(|i| i.title.clone())
        .collect();
    assert_eq!(subjects.len(), 3, "{subjects:?}");
}
