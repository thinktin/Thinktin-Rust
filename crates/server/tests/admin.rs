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

#[tokio::test]
async fn reports_are_queued_shown_and_closed() {
    use proto::domain::{ReportReason, RunSource};
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let mut w = db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone("+8613800138002").await.unwrap();
    w.commit().await.unwrap();
    let mut tx = db.tenant(user.id).await.unwrap();
    let inst = tx
        .create_instance(&store::NewInstance {
            agent_id: "claude".into(),
            agent_version: "1".into(),
            harness: "acp".into(),
            name: "助手".into(),
            workspace_id: "ws".into(),
            limits: Default::default(),
        })
        .await
        .unwrap();
    let run = tx
        .create_run(&store::NewRun::new(
            inst.id,
            RunSource::User,
            "写一首诗",
            "1",
        ))
        .await
        .unwrap();
    let (report, created) = tx
        .create_report(&store::NewReport {
            run_id: run.id,
            event_seq: None,
            artifact_id: None,
            reason: ReportReason::Hateful,
            note: Some("侮辱人".into()),
        })
        .await
        .unwrap();
    assert!(created);
    tx.commit().await.unwrap();

    // 队列里有它；详情里是举报的人（打码）、原因和复制下来的内容。
    let mut out = Vec::new();
    admin::reports(db, &mut out).await.unwrap();
    let text = take(&mut out);
    assert!(
        text.contains(&report.id.to_string()) && text.contains("hateful"),
        "{text}"
    );
    admin::report(db, &report.id.to_string(), &mut out)
        .await
        .unwrap();
    let text = take(&mut out);
    assert!(
        text.contains("+86138****8002") && !text.contains("13800138002"),
        "{text}"
    );
    assert!(
        text.contains("侮辱人") && text.contains("写一首诗"),
        "{text}"
    );

    // 处理：结果必填；处理完告诉举报的人，队列里没有了，不能再处理一次。
    assert!(
        admin::close_report(db, &report.id.to_string(), "ops-li", " ", &mut out)
            .await
            .is_err()
    );
    admin::close_report(
        db,
        &report.id.to_string(),
        "ops-li",
        "已删除相关内容并调整了过滤规则",
        &mut out,
    )
    .await
    .unwrap();
    assert!(take(&mut out).starts_with("closed "));
    let mut tx = db.tenant(user.id).await.unwrap();
    let mine = tx.reports(10).await.unwrap();
    let inbox = tx.inbox(None, 10, false).await.unwrap();
    tx.rollback().await.unwrap();
    assert_eq!(
        (mine[0].state, mine[0].resolution.as_deref()),
        (
            proto::domain::ReportState::Closed,
            Some("已删除相关内容并调整了过滤规则")
        )
    );
    assert!(
        inbox
            .iter()
            .any(|i| i.body.contains("已删除相关内容并调整了过滤规则")),
        "{inbox:?}"
    );
    admin::reports(db, &mut out).await.unwrap();
    assert_eq!(take(&mut out), "no open reports\n");
    assert!(
        admin::close_report(db, &report.id.to_string(), "ops-li", "again", &mut out)
            .await
            .is_err()
    );

    // 注销账号：举报（和复制下来的内容）一起删掉。
    let mut w = db.worker().await.unwrap();
    w.erase_account(user.id).await.unwrap();
    w.commit().await.unwrap();
    assert!(
        admin::report(db, &report.id.to_string(), &mut out)
            .await
            .is_err()
    );
}

/// 项目派单开关（8.17）：status 看现状；off 关上并取消没结束的项目运行、记审计；还有别的程序版本连着库时 on 拒绝，
/// `--force` 才开；没有原因、操作人的拒绝。
#[tokio::test]
async fn project_dispatch_switch() {
    use proto::domain::InstanceLimits;
    use server::admin::DispatchAction;
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let mut w = db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone("+8613800138031").await.unwrap();
    w.commit().await.unwrap();
    let mut tx = db.tenant(user.id).await.unwrap();
    let inst = tx
        .create_instance(&store::NewInstance {
            agent_id: "claude".into(),
            agent_version: "1".into(),
            harness: "acp".into(),
            name: "lead".into(),
            workspace_id: "vol-1".into(),
            limits: InstanceLimits::default(),
        })
        .await
        .unwrap();
    let p = tx
        .create_solo_project(
            "p",
            "",
            &[store::SoloAgent {
                instance_id: inst.id,
                is_lead: true,
                position: 0,
            }],
        )
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let (run, _) = store::testing::seed_project_run(db, p, inst.id, "task").await;

    let mut out = Vec::new();
    admin::project_dispatch(db, DispatchAction::Status, "", None, &mut out)
        .await
        .unwrap();
    let text = take(&mut out);
    assert!(text.contains("project dispatch   on"), "{text}");
    assert!(text.contains("unfinished runs    1"), "{text}");

    assert!(
        admin::project_dispatch(db, DispatchAction::Off, "ops-li", Some(" "), &mut out)
            .await
            .is_err()
    );
    admin::project_dispatch(
        db,
        DispatchAction::Off,
        "ops-li",
        Some("incident 42"),
        &mut out,
    )
    .await
    .unwrap();
    let text = take(&mut out);
    assert!(
        text.contains("project dispatch is off; 1 unfinished project runs cancelled"),
        "{text}"
    );
    let (state, reason): (String, Option<String>) =
        sqlx::query_as("SELECT state, state_reason FROM runs WHERE id = $1")
            .bind(run.0)
            .fetch_one(db.pool())
            .await
            .unwrap();
    assert_eq!(
        (state.as_str(), reason.as_deref()),
        ("cancelled", Some("project dispatch switched off"))
    );
    admin::project_dispatch(db, DispatchAction::Status, "", None, &mut out)
        .await
        .unwrap();
    let text = take(&mut out);
    assert!(
        text.contains("project dispatch   off") && text.contains("unfinished runs    0"),
        "{text}"
    );

    // 一个老版本的连接还连着：不加 --force 开不了。
    let mut old = db.pool().acquire().await.unwrap();
    sqlx::query("SET application_name = 'thinktin/i1'")
        .execute(&mut *old)
        .await
        .unwrap();
    let err = admin::project_dispatch(
        db,
        DispatchAction::On { force: false },
        "ops-li",
        Some("all upgraded"),
        &mut out,
    )
    .await
    .unwrap_err();
    assert!(err.to_string().contains("thinktin/i1 x1"), "{err}");
    admin::project_dispatch(
        db,
        DispatchAction::On { force: true },
        "ops-li",
        Some("old node is draining"),
        &mut out,
    )
    .await
    .unwrap();
    assert_eq!(take(&mut out), "project dispatch is on\n");
    sqlx::query("RESET application_name")
        .execute(&mut *old)
        .await
        .unwrap();
    drop(old);

    let audit: Vec<(String, String, serde_json::Value)> = sqlx::query_as(
        "SELECT action, actor, detail FROM audit_log WHERE action LIKE 'project_dispatch.%' ORDER BY id",
    )
    .fetch_all(db.pool())
    .await
    .unwrap();
    assert_eq!(audit.len(), 2, "{audit:?}");
    assert_eq!(
        (audit[0].0.as_str(), audit[0].1.as_str()),
        ("project_dispatch.off", "ops-li")
    );
    assert_eq!(audit[0].2["reason"], "incident 42");
    assert_eq!(audit[1].0, "project_dispatch.on");
    assert_eq!(audit[1].2["force"], true);
    assert_eq!(audit[1].2["other_sessions"][0], "thinktin/i1 x1");
}
