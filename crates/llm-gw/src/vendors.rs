//! 厂商适配表（架构方案 5.3，WBS 9.7）。
//!
//! 每家厂商记录两种协议的 base URL 和各自的差异。约定和 agent 侧一致：
//! - `anthropic_base` 不带 `/v1`（同 `ANTHROPIC_BASE_URL`），网关在后面拼 `/v1/messages`；
//! - `openai_base` 带版本段（同 `OPENAI_BASE_URL`），网关在后面拼 `/chat/completions`、`/responses`。
//!
//! 表里的地址以各厂商官方文档为准，逐家验证后更新（`verified` 标记）。

use serde::Serialize;

/// Anthropic 兼容接口认哪个鉴权头。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AnthropicAuth {
    /// `x-api-key: <key>`（Anthropic 官方的写法）。
    XApiKey,
    /// `Authorization: Bearer <key>`。
    Bearer,
    /// 两个头都带同一把 key。厂商文档只给了其中一种、另一种未验证时用。
    Both,
}

#[derive(Debug, Clone, Serialize)]
pub struct Vendor {
    pub id: &'static str,
    pub name: &'static str,
    /// 适用站点：`cn`、`global`。
    pub sites: &'static [&'static str],
    pub anthropic_base: Option<&'static str>,
    pub anthropic_auth: AnthropicAuth,
    pub openai_base: Option<&'static str>,
    /// OpenAI 兼容接口是否提供 Responses API（Codex 只会用这个协议）。
    pub responses: bool,
    /// Chat Completions 流式请求是否认 `stream_options.include_usage`。
    /// 认的话，agent 没开时网关替它补上（透传原则唯一的例外）。
    pub chat_stream_usage: bool,
    /// 已按官方文档逐项核对。
    pub verified: bool,
    pub notes: &'static str,
}

/// 自定义端点（vLLM、OneAPI 等）：地址由凭证提供。
pub const CUSTOM: &str = "custom";

pub static VENDORS: &[Vendor] = &[
    Vendor {
        id: "deepseek",
        name: "DeepSeek",
        sites: &["cn", "global"],
        anthropic_base: Some("https://api.deepseek.com/anthropic"),
        anthropic_auth: AnthropicAuth::Both,
        openai_base: Some("https://api.deepseek.com/v1"),
        responses: false,
        chat_stream_usage: true,
        verified: false,
        notes: "",
    },
    Vendor {
        id: "qwen",
        name: "阿里百炼（通义千问）",
        sites: &["cn"],
        anthropic_base: Some("https://dashscope.aliyuncs.com/apps/anthropic"),
        anthropic_auth: AnthropicAuth::Both,
        openai_base: Some("https://dashscope.aliyuncs.com/compatible-mode/v1"),
        responses: false,
        chat_stream_usage: true,
        verified: false,
        notes: "",
    },
    Vendor {
        id: "glm",
        name: "智谱 GLM",
        sites: &["cn"],
        anthropic_base: Some("https://open.bigmodel.cn/api/anthropic"),
        anthropic_auth: AnthropicAuth::Both,
        openai_base: Some("https://open.bigmodel.cn/api/paas/v4"),
        responses: false,
        chat_stream_usage: true,
        verified: false,
        notes: "",
    },
    Vendor {
        id: "kimi",
        name: "Kimi（月之暗面）",
        sites: &["cn"],
        anthropic_base: Some("https://api.moonshot.cn/anthropic"),
        anthropic_auth: AnthropicAuth::Both,
        openai_base: Some("https://api.moonshot.cn/v1"),
        responses: false,
        chat_stream_usage: true,
        verified: false,
        notes: "",
    },
    Vendor {
        id: "minimax",
        name: "MiniMax",
        sites: &["cn"],
        anthropic_base: Some("https://api.minimaxi.com/anthropic"),
        anthropic_auth: AnthropicAuth::Both,
        openai_base: Some("https://api.minimaxi.com/v1"),
        responses: false,
        chat_stream_usage: true,
        verified: false,
        notes: "",
    },
];

pub fn vendor(id: &str) -> Option<&'static Vendor> {
    VENDORS.iter().find(|v| v.id == id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ssrf::check_upstream_url;

    #[test]
    fn table_is_consistent() {
        let mut ids = std::collections::HashSet::new();
        for v in VENDORS {
            assert!(ids.insert(v.id), "duplicate vendor {}", v.id);
            assert_ne!(v.id, CUSTOM);
            assert!(
                v.anthropic_base.is_some() || v.openai_base.is_some(),
                "{} has no endpoint",
                v.id
            );
            for base in [v.anthropic_base, v.openai_base].into_iter().flatten() {
                let url = url::Url::parse(base).unwrap();
                assert_eq!(check_upstream_url(&url, false), Ok(()), "{base}");
                assert!(!base.ends_with('/'), "{base} must not end with '/'");
            }
            if let Some(base) = v.anthropic_base {
                assert!(
                    !base.ends_with("/v1"),
                    "{base}: anthropic base excludes /v1"
                );
            }
            assert!(!v.responses || v.openai_base.is_some());
        }
    }
}
