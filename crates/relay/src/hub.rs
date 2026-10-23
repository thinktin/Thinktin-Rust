//! 设备频道的通知：平台写了给某台电脑的调用或消息、或者这台电脑在别处又连了一次时，库里发
//! `thinktin_device`（载荷是设备 id）。这里监听它，叫醒连着这台电脑的连接，连接被叫醒后去库里取，
//! 所以通知丢了、重复了都不影响正确性；监听断过就叫醒所有连接各自对一遍。

use std::collections::HashMap;
use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use proto::domain::DeviceId;
use sqlx::PgPool;
use sqlx::postgres::PgListener;
use tokio::sync::broadcast;
use tracing::{info, warn};

#[derive(Clone, Default)]
pub struct DeviceHub {
    subs: Arc<Mutex<HashMap<DeviceId, broadcast::Sender<()>>>>,
}

impl DeviceHub {
    pub fn subscribe(&self, device: DeviceId) -> broadcast::Receiver<()> {
        let mut subs = self.subs.lock().unwrap();
        subs.retain(|_, tx| tx.receiver_count() > 0);
        subs.entry(device)
            .or_insert_with(|| broadcast::channel(8).0)
            .subscribe()
    }

    pub fn notify(&self, device: DeviceId) {
        if let Some(tx) = self.subs.lock().unwrap().get(&device) {
            let _ = tx.send(());
        }
    }

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
            let connect = async {
                let mut l = PgListener::connect_with(&pool).await?;
                l.listen(store::DEVICE_CHANNEL).await?;
                Ok::<_, sqlx::Error>(l)
            };
            let mut listener = tokio::select! {
                () = &mut stop => return,
                l = connect => match l {
                    Ok(l) => l,
                    Err(e) => {
                        warn!(error = %e, "device listener cannot connect");
                        tokio::select! {
                            () = &mut stop => return,
                            () = tokio::time::sleep(backoff) => {}
                        }
                        backoff = (backoff * 2).min(Duration::from_secs(10));
                        continue;
                    }
                },
            };
            info!("device listener connected");
            backoff = Duration::from_millis(200);
            self.notify_all();
            loop {
                tokio::select! {
                    () = &mut stop => return,
                    // recv() 断线后会自己悄悄重连，中间的通知丢了也不知道；try_recv() 断线时返回 None。
                    n = listener.try_recv() => match n {
                        Ok(Some(n)) => {
                            if let Ok(id) = n.payload().parse::<DeviceId>() {
                                self.notify(id);
                            }
                        }
                        Ok(None) => {
                            warn!("device listener reconnecting");
                            self.notify_all();
                        }
                        Err(e) => {
                            warn!(error = %e, "device listener lost its connection");
                            self.notify_all();
                            break;
                        }
                    },
                }
            }
        }
    }
}
