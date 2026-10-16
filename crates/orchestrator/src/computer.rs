//! 用用户电脑上的工具（WBS 14.1 的平台一侧）：按会话绑定找到用户自己在线的电脑，写一个调用，
//! 等连着这台电脑的设备中继（`relay`）转过去、电脑回结果。
//!
//! 目标电脑只由调用方给的用户决定（运行 → 实例 → 用户 → 这个用户没吊销、在线的电脑；有几台时取最近连上的），
//! 不取自 agent 的输出。电脑不在线时返回 [`CallError::Offline`]：执行器据此把运行转入“等待电脑上线”（7.11），
//! 电脑连上中继时唤醒。工具本身由电脑端的工具服务（14.2）提供。
//!
//! 等结果靠数据库通知（`thinktin_device_call`，调用结束时发），通知丢了也会定时去库里看，只是慢一点。

use std::collections::HashMap;
use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use proto::domain::{DeviceCallId, DeviceCallState, DeviceId, RunId, UserId};
use serde_json::Value;
use sqlx::postgres::PgListener;
use store::{DEVICE_CALL_CHANNEL, Db, NewDeviceCall};
use tokio::sync::broadcast;
use tokio::sync::broadcast::error::RecvError;
use tokio::time::Instant;
use tracing::{info, warn};

/// 没收到通知时多久去库里看一次。
const POLL: Duration = Duration::from_secs(2);

/// 电脑回的结果：MCP 的 content 数组；工具自己报错时 `is_error` 为真。
#[derive(Debug, Clone, PartialEq)]
pub struct CallOutput {
    pub device: DeviceId,
    pub content: Vec<Value>,
    pub is_error: bool,
}

#[derive(Debug, thiserror::Error)]
pub enum CallError {
    /// 这个账号没有登录着的电脑：提示用户在电脑上装 App、登录。
    #[error("no computer is signed in to this account")]
    NoComputer,
    /// 有电脑，但现在不在线：等它上线（7.11）。
    #[error("the computer is offline")]
    Offline,
    /// 电脑报上来的工具里没有它（比如没给屏幕录制权限）。
    #[error("the computer does not offer {0} right now")]
    Unsupported(String),
    /// 到时间电脑还没回。
    #[error("the computer did not answer in time")]
    Timeout,
    /// 转出去以后电脑断线了，或者回的结果不对。
    #[error("{0}")]
    Failed(String),
    #[error(transparent)]
    Store(#[from] store::Error),
}

/// 调用结束的通知：按调用 id 叫醒等结果的一方。
#[derive(Clone, Default)]
struct CallHub {
    subs: Arc<Mutex<HashMap<DeviceCallId, broadcast::Sender<()>>>>,
}

impl CallHub {
    fn subscribe(&self, call: DeviceCallId) -> broadcast::Receiver<()> {
        let mut subs = self.subs.lock().unwrap();
        subs.retain(|_, tx| tx.receiver_count() > 0);
        subs.entry(call)
            .or_insert_with(|| broadcast::channel(4).0)
            .subscribe()
    }

    fn notify(&self, call: DeviceCallId) {
        if let Some(tx) = self.subs.lock().unwrap().get(&call) {
            let _ = tx.send(());
        }
    }

    fn notify_all(&self) {
        for tx in self.subs.lock().unwrap().values() {
            let _ = tx.send(());
        }
    }
}

/// 发调用、等结果。一个进程一个，后台跑着 [`DeviceCalls::listen`]。
#[derive(Clone)]
pub struct DeviceCalls {
    db: Db,
    hub: CallHub,
}

impl DeviceCalls {
    pub fn new(db: Db) -> Self {
        Self {
            db,
            hub: CallHub::default(),
        }
    }

    /// 监听调用结束的通知，直到 `stop` 完成；连接断了按退避重连，重连后叫醒所有等着的去库里看。
    pub async fn listen(&self, stop: impl Future<Output = ()>) {
        tokio::pin!(stop);
        let mut backoff = Duration::from_millis(200);
        loop {
            let listener = async {
                let mut l = PgListener::connect_with(self.db.pool()).await?;
                l.listen(DEVICE_CALL_CHANNEL).await?;
                Ok::<_, sqlx::Error>(l)
            };
            let mut listener = tokio::select! {
                () = &mut stop => return,
                l = listener => match l {
                    Ok(l) => l,
                    Err(e) => {
                        warn!(error = %e, "device call listener cannot connect");
                        tokio::select! {
                            () = &mut stop => return,
                            () = tokio::time::sleep(backoff) => {}
                        }
                        backoff = (backoff * 2).min(Duration::from_secs(10));
                        continue;
                    }
                },
            };
            info!("device call listener connected");
            backoff = Duration::from_millis(200);
            self.hub.notify_all();
            loop {
                tokio::select! {
                    () = &mut stop => return,
                    n = listener.try_recv() => match n {
                        Ok(Some(n)) => {
                            if let Ok(id) = n.payload().parse::<DeviceCallId>() {
                                self.hub.notify(id);
                            }
                        }
                        // 断线后自己重连了：中间的通知可能丢了。
                        Ok(None) => self.hub.notify_all(),
                        Err(e) => {
                            warn!(error = %e, "device call listener lost its connection");
                            self.hub.notify_all();
                            break;
                        }
                    },
                }
            }
        }
    }

    /// 在用户自己在线的电脑上调用 `tool`，最多等 `timeout`。
    pub async fn call(
        &self,
        user: UserId,
        run: Option<RunId>,
        tool: &str,
        arguments: Value,
        timeout: Duration,
    ) -> Result<CallOutput, CallError> {
        let mut w = self.db.worker().await?;
        let Some((device, tools)) = w.online_computer(user).await? else {
            let any = w.has_computer(user).await?;
            w.rollback().await?;
            return Err(if any {
                CallError::Offline
            } else {
                CallError::NoComputer
            });
        };
        // 电脑没报工具（老版本、还没发 hello）时不拦，让电脑自己回错。
        if !tools.is_empty() && !tools.iter().any(|t| t == tool) {
            w.rollback().await?;
            return Err(CallError::Unsupported(tool.to_owned()));
        }
        let id = w
            .create_device_call(&NewDeviceCall {
                user,
                device,
                run,
                tool: tool.to_owned(),
                arguments,
                timeout,
            })
            .await?;
        // 通知在提交时才发出：提交前订阅，不会漏。
        let mut wake = self.hub.subscribe(id);
        w.commit().await?;

        let deadline = Instant::now() + timeout;
        let mut notified = true;
        loop {
            let mut w = self.db.worker().await?;
            let rec = w.device_call(id).await?;
            w.rollback().await?;
            match rec.state {
                DeviceCallState::Done => return output(device, rec.result),
                DeviceCallState::Failed => {
                    return Err(CallError::Failed(
                        rec.error
                            .unwrap_or_else(|| "the computer could not run the tool".into()),
                    ));
                }
                DeviceCallState::Expired => return Err(CallError::Timeout),
                DeviceCallState::Pending | DeviceCallState::Sent => {}
            }
            let now = Instant::now();
            if now >= deadline {
                let mut w = self.db.worker().await?;
                let expired = w.expire_device_call(id).await?;
                w.commit().await?;
                if expired {
                    return Err(CallError::Timeout);
                }
                // 刚好在这之前回了结果：再读一次。
                continue;
            }
            let wait = (deadline - now).min(POLL);
            if notified {
                tokio::select! {
                    r = wake.recv() => {
                        if let Err(RecvError::Closed) = r {
                            notified = false;
                        }
                    }
                    () = tokio::time::sleep(wait) => {}
                }
            } else {
                tokio::time::sleep(wait).await;
            }
        }
    }
}

fn output(device: DeviceId, result: Option<Value>) -> Result<CallOutput, CallError> {
    let mut result = result.unwrap_or(Value::Null);
    let content = match result.get_mut("content").map(Value::take) {
        Some(Value::Array(items)) => items,
        _ => {
            return Err(CallError::Failed(
                "the computer sent a malformed result".into(),
            ));
        }
    };
    let is_error = result
        .get("is_error")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    Ok(CallOutput {
        device,
        content,
        is_error,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn results_need_a_content_array() {
        let d = DeviceId::new();
        let ok = output(
            d,
            Some(json!({ "content": [{ "type": "text", "text": "hi" }], "is_error": true })),
        )
        .unwrap();
        assert_eq!(ok.content.len(), 1);
        assert!(ok.is_error);
        assert!(!output(d, Some(json!({ "content": [] }))).unwrap().is_error);
        assert!(matches!(
            output(d, Some(json!({ "content": "hi" }))),
            Err(CallError::Failed(_))
        ));
        assert!(matches!(output(d, None), Err(CallError::Failed(_))));
    }

    #[test]
    fn the_hub_wakes_only_the_waiting_call() {
        let hub = CallHub::default();
        let (a, b) = (DeviceCallId::new(), DeviceCallId::new());
        let mut ra = hub.subscribe(a);
        let mut rb = hub.subscribe(b);
        hub.notify(a);
        assert!(ra.try_recv().is_ok());
        assert!(rb.try_recv().is_err());
        hub.notify_all();
        assert!(rb.try_recv().is_ok());
        drop(ra);
        // 没人等的不留着。
        let _rc = hub.subscribe(DeviceCallId::new());
        assert_eq!(hub.subs.lock().unwrap().len(), 2);
    }
}
