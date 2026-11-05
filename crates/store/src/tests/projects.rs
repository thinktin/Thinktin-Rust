//! 项目与跨用户协作（8.14 起）的库测试。需要真实 Postgres，没设置 DATABASE_URL 时跳过。

use proto::domain::{ProjectId, ProjectInviteId, TeamMember, TeamRole};

use super::{instance, queue_run, user};
use crate::testing::TestDb;
use crate::{Error, NewInboxItem};

/// 收件箱里项目回执的字段（8.14，0047 的 inbox_project_guard）：只有 worker 写得出；写了以后谁都不能改它们和子类型；
/// 租户照样能标已读；运行删掉以后 run_id 置空、project_id 留着。
#[tokio::test]
async fn inbox_project_fields_are_server_only() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800001001").await;
    let i = instance(db, alice).await;
    let mut ta = db.tenant(alice).await.unwrap();
    let team = ta
        .create_team(
            "p",
            &[TeamMember {
                instance_id: i.id,
                role: TeamRole::Lead,
                position: 0,
            }],
        )
        .await
        .unwrap();
    ta.commit().await.unwrap();
    let project: ProjectId = team.id.into();
    let run = queue_run(db, alice, &i, "x").await;
    let item = |project_id: Option<ProjectId>| NewInboxItem {
        kind: "info".into(),
        title: "t".into(),
        body: "b".into(),
        run_id: Some(run.id),
        project_id,
        project_invite_id: project_id.map(|_| ProjectInviteId::new()),
        ..NewInboxItem::default()
    };
    // 租户写不出带项目字段的行。
    let mut ta = db.tenant(alice).await.unwrap();
    let err = ta
        .insert_inbox(alice, &item(Some(project)))
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Forbidden(_)), "{err:?}");
    ta.rollback().await.unwrap();
    // worker 写得出；之后谁都改不了。
    let mut w = db.worker().await.unwrap();
    let id = w
        .insert_inbox(alice, &item(Some(project)))
        .await
        .unwrap()
        .unwrap();
    w.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    let err = sqlx::query("UPDATE inbox_items SET project_id = NULL WHERE id = $1")
        .bind(id.0)
        .execute(w.conn())
        .await
        .map_err(Error::from)
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    w.rollback().await.unwrap();
    let mut ta = db.tenant(alice).await.unwrap();
    let err = sqlx::query("UPDATE inbox_items SET subtype = 'report_handled' WHERE id = $1")
        .bind(id.0)
        .execute(ta.conn())
        .await
        .map_err(Error::from)
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    ta.rollback().await.unwrap();
    // 租户标已读不受影响；读出来带着项目和邀请。
    let mut ta = db.tenant(alice).await.unwrap();
    assert_eq!(ta.mark_inbox_read(Some(&[id]), None).await.unwrap(), 1);
    ta.commit().await.unwrap();
    let mut ta = db.tenant(alice).await.unwrap();
    let got = ta
        .inbox(None, 10, false)
        .await
        .unwrap()
        .into_iter()
        .find(|x| x.id == id)
        .unwrap();
    assert_eq!(got.project_id, Some(project));
    assert!(got.project_invite_id.is_some() && got.read);
    ta.rollback().await.unwrap();
    // 运行删掉：run_id 置空（外键 ON DELETE SET NULL 不触发守卫），项目还在。
    sqlx::query("DELETE FROM runs WHERE id = $1")
        .bind(run.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    let (run_id, project_id): (Option<uuid::Uuid>, Option<uuid::Uuid>) =
        sqlx::query_as("SELECT run_id, project_id FROM inbox_items WHERE id = $1")
            .bind(id.0)
            .fetch_one(db.pool())
            .await
            .unwrap();
    assert_eq!((run_id, project_id), (None, Some(project.0)));
}
