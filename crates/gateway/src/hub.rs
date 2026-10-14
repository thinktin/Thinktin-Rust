//! 事件流的唤醒：监听 Postgres 的 `thinktin_events` 通知（事件追加时发出，载荷是实例 id），
//! 叫醒订阅这个实例的连接；连接被叫醒后按自己的序号去库里取，所以通知丢了、重复了都不影响正确性。

use std::collections::HashMap;
use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use proto::domain::InstanceId;
use sqlx::PgPool;
use sqlx::postgres::PgListener;
use tokio::sync::broadcast;
use tracing::{info, warn};

#[derive(Clone, Default)]
pub struct EventHub {
    subs: Arc<Mutex<HashMap<InstanceId, broadcast::Sender<()>>>>,
}

impl EventHub {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn subscribe(&self, instance: InstanceId) -> broadcast::Receiver<()> {
        let mut subs = self.subs.lock().unwrap();
        subs.retain(|_, tx| tx.receiver_count() > 0);
        subs.entry(instance)
            .or_insert_with(|| broadcast::channel(8).0)
            .subscribe()
    }

    pub fn notify(&self, instance: InstanceId) {
        if let Some(tx) = self.subs.lock().unwrap().get(&instance) {
            let _ = tx.send(());
        }
    }

    /// 监听断过（期间的通知可能丢了）：叫醒所有订阅者各自去库里对一遍。
    pub fn notify_all(&self) {
        for tx in self.subs.lock().unwrap().values() {
            let _ = tx.send(());
        }
    }

    /// 一直监听，直到 `stop` 完成；连接断了按退避重连。
    pub async fn listen(self, pool: PgPool, stop: impl Future<Output = ()>) {
        tokio::pin!(stop);
        let mut backoff = Duration::from_millis(200);
        loop {
            let mut listener = match PgListener::connect_with(&pool).await {
                Ok(l) => l,
                Err(e) => {
                    warn!(error = %e, "event listener cannot connect");
                    tokio::select! {
                        () = &mut stop => return,
                        () = tokio::time::sleep(backoff) => {}
                    }
                    backoff = (backoff * 2).min(Duration::from_secs(10));
                    continue;
                }
            };
            if let Err(e) = listener.listen(store::EVENTS_CHANNEL).await {
                warn!(error = %e, "event listener cannot subscribe");
                continue;
            }
            info!("event listener connected");
            backoff = Duration::from_millis(200);
            self.notify_all();
            loop {
                tokio::select! {
                    () = &mut stop => return,
                    n = listener.recv() => match n {
                        Ok(n) => {
                            if let Ok(id) = n.payload().parse::<InstanceId>() {
                                self.notify(id);
                            }
                        }
                        Err(e) => {
                            warn!(error = %e, "event listener lost its connection");
                            self.notify_all();
                            break;
                        }
                    }
                }
            }
        }
    }
}
