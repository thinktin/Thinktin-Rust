//! 给事件编号、打时间戳，交给输出端（stdout 或测试里的通道）。

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use proto::shim::{EventEnvelope, ShimEvent};
use tokio::sync::mpsc;

#[derive(Clone)]
pub struct EventSink {
    tx: mpsc::UnboundedSender<EventEnvelope>,
    seq: Arc<AtomicU64>,
}

impl EventSink {
    pub fn new() -> (Self, mpsc::UnboundedReceiver<EventEnvelope>) {
        let (tx, rx) = mpsc::unbounded_channel();
        let sink = Self {
            tx,
            seq: Arc::new(AtomicU64::new(1)),
        };
        (sink, rx)
    }

    pub fn emit(&self, event: ShimEvent) {
        let seq = self.seq.fetch_add(1, Ordering::Relaxed);
        let ts_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_millis() as u64);
        // 输出端已经关闭说明进程正在退出，丢掉即可。
        let _ = self.tx.send(EventEnvelope { seq, ts_ms, event });
    }
}
