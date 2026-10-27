//! 模型网关：令牌校验、路由、换 key、流式透传、计量、限额（架构方案第 5 节，WBS 9.2–9.7）。
//!
//! agent 在沙箱里只拿到短期沙箱令牌。网关校验令牌后按"令牌 → 实例 → 别名"查出用户的 key 和上游模型，
//! 换上 key 转发给厂商，响应原样流回，同时记录用量。用户 key 的明文只在这里短暂出现。

pub mod body;
pub mod limits;
pub mod pg;
pub mod proxy;
pub mod serve;
pub mod ssrf;
pub mod store;
pub mod usage;

/// 厂商适配表在 `proto` 里（接入网关也要用它校验 key、列出预置厂商）。
pub use proto::vendors;

pub use proxy::{Gateway, Options, build_client, router};
pub use serve::{ServeOptions, serve};
