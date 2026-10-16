//! 账号冻结、解冻、全部停止（4.6）。需要 DATABASE_URL（没有时跳过）。

use std::time::Duration;

use orchestrator::account::{self, Stopped};
use proto::domain::{
    CatchUp, GrantScope, InstanceLimits, PlanAuthor, PlanPolicy, RunSource, RunState, UserStatus,
};
use store::testing::TestDb;
use store::{NewInstance, NewPlan, NewRun};

const TTL: Duration = Duration::from_secs(3600);

#[tokio::test]
async fn freeze_unfreeze_and_stop_all() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let mut w = db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone("+8613800000001").await.unwrap();
    let (other, _) = w.upsert_user_by_phone("+8613800000002").await.unwrap();
    w.commit().await.unwrap();
    let (user, other) = (user.id, other.id);

    let mut tx = db.tenant(user).await.unwrap();
    let inst = tx
        .create_instance(&NewInstance {
            agent_id: "claude".into(),
            agent_version: "1".into(),
            harness: "acp".into(),
            name: "main".into(),
            workspace_id: "vol-1".into(),
            limits: InstanceLimits::default(),
        })
        .await
        .unwrap();
    tx.create_run_grant(inst.id, None, &GrantScope::default(), TTL)
        .await
        .unwrap();
    let plan = tx
        .create_plan(&NewPlan {
            instance_id: inst.id,
            title: "daily".into(),
            goal: "summarize".into(),
            policy: PlanPolicy::default(),
            catch_up: CatchUp::Once,
            created_by: PlanAuthor::User,
            run_grant_id: None,
        })
        .await
        .unwrap();
    let grant = tx
        .create_run_grant(inst.id, Some(plan.id), &GrantScope::default(), TTL)
        .await
        .unwrap();
    tx.set_plan_grant(plan.id, grant.id).await.unwrap();
    let run = tx
        .create_run(&NewRun::new(inst.id, RunSource::User, "hello", "1"))
        .await
        .unwrap();
    tx.commit().await.unwrap();

    // 冻结：运行取消；授权和计划留着（冻结期间用不了，解冻后照常）。
    let stopped = account::freeze(db, user, "ops-li", "suspicious login")
        .await
        .unwrap();
    assert_eq!(
        stopped,
        Stopped {
            runs_cancelled: 1,
            ..Stopped::default()
        }
    );
    assert!(matches!(
        account::freeze(db, user, "ops-li", "again").await,
        Err(store::Error::Conflict(_))
    ));
    let mut w = db.worker().await.unwrap();
    let summary = w.account_summary(user).await.unwrap();
    assert_eq!(summary.user.status, UserStatus::Frozen);
    assert_eq!(
        (
            summary.active_runs,
            summary.active_plans,
            summary.active_grants
        ),
        (0, 1, 2)
    );
    let rec = w.run_record(run.id).await.unwrap();
    assert_eq!(rec.run.state, RunState::Cancelled);
    assert_eq!(rec.run.state_reason.as_deref(), Some("account frozen"));
    assert_eq!(
        w.user(other).await.unwrap().status,
        UserStatus::Active,
        "other accounts are untouched"
    );
    w.rollback().await.unwrap();

    // 解冻。没冻结的解冻不了。
    account::unfreeze(db, user, "ops-li", "verified by phone")
        .await
        .unwrap();
    assert!(matches!(
        account::unfreeze(db, user, "ops-li", "again").await,
        Err(store::Error::Conflict(_))
    ));

    // 全部停止：运行取消、授权吊销、计划暂停。
    let mut tx = db.tenant(user).await.unwrap();
    tx.create_run(&NewRun::new(inst.id, RunSource::User, "again", "1"))
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let stopped = account::stop_all(db, user, "user:test").await.unwrap();
    assert_eq!(
        stopped,
        Stopped {
            runs_cancelled: 1,
            grants_revoked: 2,
            plans_paused: 1,
        }
    );
    let mut tx = db.tenant(user).await.unwrap();
    assert!(tx.plan(plan.id).await.unwrap().paused);
    assert!(tx.run_grants(inst.id).await.unwrap().is_empty());
    // 每一步都通知了用户。
    let titles: Vec<String> = tx
        .inbox(None, 10, false)
        .await
        .unwrap()
        .into_iter()
        .map(|i| i.title)
        .collect();
    assert_eq!(titles, ["已全部停止", "账号已恢复", "账号已冻结"]);
    tx.rollback().await.unwrap();

    // 注销了的账号：冻结、解冻都当不存在。
    let mut w = db.worker().await.unwrap();
    w.erase_account(other).await.unwrap();
    w.commit().await.unwrap();
    assert!(matches!(
        account::freeze(db, other, "ops-li", "too late").await,
        Err(store::Error::NotFound)
    ));
    assert!(matches!(
        account::unfreeze(db, other, "ops-li", "too late").await,
        Err(store::Error::NotFound)
    ));
}
