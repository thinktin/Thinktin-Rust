//! 停机信号和后台任务。

use std::future::Future;
use std::time::Duration;

use tokio::sync::watch;
use tokio::task::JoinSet;
use tracing::{info, warn};

/// 停机信号：触发后所有监听者都能看到，后来订阅的也一样。
#[derive(Clone)]
pub struct ShutdownSignal {
    tx: watch::Sender<bool>,
}

impl ShutdownSignal {
    pub fn new() -> Self {
        Self {
            tx: watch::Sender::new(false),
        }
    }

    pub fn trigger(&self) {
        self.tx.send_replace(true);
    }

    pub fn subscribe(&self) -> ShutdownListener {
        ShutdownListener {
            rx: self.tx.subscribe(),
        }
    }
}

impl Default for ShutdownSignal {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Clone)]
pub struct ShutdownListener {
    rx: watch::Receiver<bool>,
}

impl ShutdownListener {
    pub fn is_shutting_down(&self) -> bool {
        *self.rx.borrow()
    }

    /// 等到停机开始。后台循环在 `select!` 里和自己的工作一起等它。
    pub async fn wait(&mut self) {
        // 发送端在 ShutdownSignal 里，只要进程在跑就不会关；关了也当作停机。
        let _ = self.rx.wait_for(|stopping| *stopping).await;
    }
}

/// 后台任务：每个任务拿到一个停机监听，停机开始后应尽快收尾（放掉租约、提交进度）。
pub struct Background {
    tasks: JoinSet<(&'static str, anyhow::Result<()>)>,
    shutdown: ShutdownSignal,
}

impl Background {
    pub fn new(shutdown: ShutdownSignal) -> Self {
        Self {
            tasks: JoinSet::new(),
            shutdown,
        }
    }

    pub fn spawn<F, Fut>(&mut self, name: &'static str, task: F)
    where
        F: FnOnce(ShutdownListener) -> Fut,
        Fut: Future<Output = anyhow::Result<()>> + Send + 'static,
    {
        let fut = task(self.shutdown.subscribe());
        self.tasks.spawn(async move { (name, fut.await) });
    }

    /// 下一个结束的任务；没有任务时返回 None。panic 也算结束（带错误）。
    pub async fn next_exit(&mut self) -> Option<(&'static str, anyhow::Result<()>)> {
        match self.tasks.join_next().await? {
            Ok(exit) => Some(exit),
            Err(e) => Some(("<panicked>", Err(anyhow::anyhow!("task panicked: {e}")))),
        }
    }

    /// 停机：通知所有任务，最多等 `grace`，还没结束的强行中止。
    pub async fn shutdown(mut self, grace: Duration) {
        self.shutdown.trigger();
        let wait_all = async {
            while let Some(exit) = self.next_exit().await {
                match exit {
                    (name, Ok(())) => info!(task = name, "background task stopped"),
                    (name, Err(e)) => {
                        warn!(task = name, error = %e, "background task failed while stopping")
                    }
                }
            }
        };
        if tokio::time::timeout(grace, wait_all).await.is_err() {
            warn!(
                remaining = self.tasks.len(),
                "background tasks still running after grace period, aborting"
            );
            self.tasks.shutdown().await;
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    use super::*;

    #[tokio::test]
    async fn tasks_see_shutdown_and_stragglers_are_aborted() {
        let signal = ShutdownSignal::new();
        let mut bg = Background::new(signal.clone());
        let cleaned = Arc::new(AtomicBool::new(false));
        let c = cleaned.clone();
        bg.spawn("polite", move |mut stop| async move {
            stop.wait().await;
            c.store(true, Ordering::SeqCst);
            Ok(())
        });
        bg.spawn("stubborn", |_stop| async move {
            std::future::pending::<()>().await;
            Ok(())
        });
        let late = signal.subscribe();
        let started = std::time::Instant::now();
        bg.shutdown(Duration::from_millis(200)).await;
        assert!(cleaned.load(Ordering::SeqCst));
        assert!(late.is_shutting_down());
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[tokio::test]
    async fn early_exit_is_reported() {
        let mut bg = Background::new(ShutdownSignal::new());
        bg.spawn("broken", |_stop| async { Err(anyhow::anyhow!("boom")) });
        let (name, res) = bg.next_exit().await.unwrap();
        assert_eq!(name, "broken");
        assert!(res.is_err());
        assert!(bg.next_exit().await.is_none());
    }
}
