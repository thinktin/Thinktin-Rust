//! Claude Code 命令行的 stream-json 接入方式（占位，下一步实现）。

use anyhow::bail;
use catalog::Harness;
use proto::shim::ShimCommand;
use tokio::sync::mpsc;

use crate::acp::Outcome;
use crate::events::EventSink;
use crate::process::Launch;
use crate::shim::ShimConfig;

pub async fn run(
    _cfg: &ShimConfig,
    _harness: &Harness,
    _launch: &Launch,
    _cmds: &mut mpsc::UnboundedReceiver<ShimCommand>,
    _sink: &EventSink,
) -> anyhow::Result<Outcome> {
    bail!("claude-stream-json harness is not implemented yet")
}
