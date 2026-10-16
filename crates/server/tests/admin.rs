//! 运维命令（4.6）：冻结、查看、解冻。需要 DATABASE_URL（没有时跳过）。

use server::admin;
use store::testing::TestDb;

fn take(out: &mut Vec<u8>) -> String {
    String::from_utf8(std::mem::take(out)).unwrap()
}

#[tokio::test]
async fn freeze_show_and_unfreeze_by_phone_or_id() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let mut w = db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone("+8613800138000").await.unwrap();
    w.commit().await.unwrap();

    let mut out = Vec::new();
    admin::freeze(db, "138 0013 8000", "ops-li", "suspicious login", &mut out)
        .await
        .unwrap();
    let text = take(&mut out);
    assert!(text.starts_with(&format!("frozen {}", user.id)), "{text}");

    admin::show(db, &user.id.to_string(), &mut out)
        .await
        .unwrap();
    let text = take(&mut out);
    assert!(text.contains("+86138****8000"), "{text}");
    assert!(text.contains("status      frozen"), "{text}");
    assert!(
        !text.contains("13800138000"),
        "the phone number is masked: {text}"
    );

    // 已经冻结的不能再冻结；操作人和原因必填。
    assert!(
        admin::freeze(db, "13800138000", "ops-li", "again", &mut out)
            .await
            .is_err()
    );
    assert!(
        admin::unfreeze(db, "13800138000", "", "ok", &mut out)
            .await
            .is_err()
    );
    assert!(
        admin::unfreeze(db, "13800138000", "ops-li", " ", &mut out)
            .await
            .is_err()
    );
    admin::unfreeze(db, "13800138000", "ops-li", "verified by phone", &mut out)
        .await
        .unwrap();
    assert_eq!(take(&mut out), format!("unfrozen {}\n", user.id));

    // 找不到的账号：报错里的手机号也打码。
    let err = admin::show(db, "13900000000", &mut out).await.unwrap_err();
    assert!(err.to_string().contains("+86139****0000"), "{err}");
    assert!(admin::show(db, "not-a-phone", &mut out).await.is_err());
}

#[tokio::test]
async fn versions_count_instances_per_agent_version() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let mut w = db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone("+8613800138001").await.unwrap();
    w.commit().await.unwrap();
    let claude = catalog::builtin("claude").unwrap().agent.version;
    let mut tx = db.tenant(user.id).await.unwrap();
    for (i, version) in [claude.as_str(), claude.as_str(), "0.0.1-gone"]
        .into_iter()
        .enumerate()
    {
        tx.create_instance(&store::NewInstance {
            agent_id: "claude".into(),
            agent_version: version.into(),
            harness: "acp".into(),
            name: format!("c{i}"),
            workspace_id: format!("ws-{i}"),
            limits: Default::default(),
        })
        .await
        .unwrap();
    }
    tx.commit().await.unwrap();

    let mut out = Vec::new();
    admin::versions(db, &mut out).await.unwrap();
    let text = take(&mut out);
    let line = |v: &str| {
        text.lines()
            .find(|l| l.split_whitespace().nth(1) == Some(v))
            .unwrap_or_else(|| panic!("no line for {v}: {text}"))
            .to_owned()
    };
    let cur = line(&claude);
    assert!(
        cur.split_whitespace().nth(2) == Some("2") && cur.ends_with("current"),
        "{text}"
    );
    assert!(line("0.0.1-gone").ends_with("unknown version"), "{text}");
}
