//! 出网要问用户的网站（WBS 2.7，docs/egress.md）：出口代理登记了“agent 想访问某个网站”，后台在这里给用户发提醒
//! （收件箱、高优先级推送；不发 IM 群：群里答不了，也不该让群里的人看到 agent 在访问什么），用户在 App 里选访问一次 /
//! 一直允许 / 拒绝。每条请求提醒一次；还在等的时候换了任务、上次提醒过了一小时以上的，出口代理会让它再提醒一次。
//! 用户答了、请求过期了，收件箱那条算已读。

use notify::PushKind;
use store::Db;
use tracing::info;

use crate::outbox::{Notice, notify};

/// 领走最多 `batch` 条还没提醒过的请求，给用户发提醒，返回领了几条。后台每隔几秒调一次。
pub async fn notify_requests(db: &Db, batch: i64) -> store::Result<usize> {
    let mut w = db.worker().await?;
    let claimed = w.claim_egress_asks(batch).await?;
    for ask in &claimed {
        let r = &ask.request;
        let locale = w.user_locale(ask.user_id).await?;
        let (title, body) = crate::texts::egress_request(locale, &ask.instance_name, &r.host);
        // 同一条请求换了任务再提醒时是新的一条（去重键带任务）。
        let key = format!(
            "egress_request:{}:{}",
            r.id,
            r.run_id
                .map_or_else(|| "none".to_owned(), |run| run.to_string())
        );
        let notice = Notice {
            instance: Some(r.instance_id),
            run: r.run_id,
            egress_request: Some(r.id),
            dedupe_key: Some(key),
            collapse_id: Some(format!("egress_request:{}", r.id)),
            ..Notice::new(PushKind::EgressRequest, title, body)
        };
        notify(&mut w, ask.user_id, &notice).await?;
    }
    w.commit().await?;
    if !claimed.is_empty() {
        info!(
            count = claimed.len(),
            "asked users about websites their agents want"
        );
    }
    Ok(claimed.len())
}
