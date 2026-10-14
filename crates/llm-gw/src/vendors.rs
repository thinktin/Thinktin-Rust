//! 厂商适配表（架构方案 5.3，WBS 9.7）。
//!
//! 每家厂商、每个区域一条记录（各家的国内站和国际站账号、key 互不相通，用错区域的地址会 401）。
//! base URL 的约定和 agent 侧一致：
//! - `anthropic_base` 不带 `/v1`（同 `ANTHROPIC_BASE_URL`），网关在后面拼 `/v1/messages`；
//! - `openai_base`、`responses_base` 是 `/chat/completions`、`/responses` 之前的部分。
//!   多数厂商两者相同；智谱的 Responses 在另一个前缀下。
//!
//! 内容按各家官方文档核对（2026-10-14），见 docs/llm-gateway.md 第 11 节。

use serde::Serialize;

/// 核对日期。
pub const VERIFIED: &str = "2026-10-14";

/// Anthropic 兼容接口认哪个鉴权头。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AnthropicAuth {
    /// `x-api-key: <key>`（Anthropic 官方的写法）。
    XApiKey,
    /// `Authorization: Bearer <key>`。
    Bearer,
    /// 两个头都带同一把 key。只用于自定义端点（不知道对方认哪个）。
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
    /// Chat Completions 的前缀。OpenAI 协议一律用 `Authorization: Bearer`。
    pub openai_base: Option<&'static str>,
    /// Responses API 的前缀（Codex 只会用这个协议）。
    pub responses_base: Option<&'static str>,
    /// Chat Completions 流式请求是否需要网关补 `stream_options.include_usage` 才能拿到用量。
    /// 本来就在最后一个分片里带用量、或者文档里没有这个参数的厂商为 false。
    pub chat_stream_usage: bool,
    /// 推荐的上游模型（给配置界面用，以厂商文档为准，变化很快）。
    pub models: &'static [&'static str],
    /// 订阅类 key（编程套餐等）的前缀。这类 key 按厂商条款只能在官方工具里用，不能经第三方平台中转，保存时拒绝。
    pub subscription_key_prefixes: &'static [&'static str],
    /// 校验 key 用的模型列表接口（Bearer），没有就为空（9.8）。
    pub models_url: Option<&'static str>,
    pub notes: &'static str,
}

/// 自定义端点（vLLM、OneAPI 等）：地址由凭证提供。
pub const CUSTOM: &str = "custom";

const DEEPSEEK_NOTES: &str = "Anthropic 接口会把不认识的模型名静默映射成 deepseek-flash；\
Chat Completions 默认开思考，带工具的请求必须回传之前每轮的 reasoning_content，否则 400；\
Responses 无状态（不支持 previous_response_id、store）。用量在最后一个内容分片里，不需要 include_usage";
const QWEN_NOTES: &str = "key 绑定区域，跨区域 401；用户可能给 key 设了来源 IP 和模型白名单；\
编程套餐（sk-sp-）和 Token 套餐的专用域名不能用；Anthropic 接口的完整用量在 message_delta 里";
const GLM_NOTES: &str = "Responses 在 /api/v1 下，不在 /api/paas/v4；编程套餐 key 按条款禁止中转，只接按量付费 key；\
用过编程套餐的账号暂时只能用 Chat Completions 调按量模型；流式中途失败不返回错误码，看最后一个分片的 finish_reason；\
Chat Completions 的用量在最后一个分片里，文档没有 stream_options";
const KIMI_NOTES: &str = "Anthropic 接口文档只写了 Bearer；Responses 目前只支持 kimi-k3、无状态；\
TPM 按 输入 + max_completion_tokens 预占（kimi-k3 默认 131072），同一账号的 key 共用额度；图片只收 data URL";
const MINIMAX_NOTES: &str = "Anthropic 接口 message_start 里的用量不可信，以 message_delta 为准；\
订阅 key（sk-cp-）和按量 key（sk-api-）不能混用；M2.5、M2.7 于 2026-11-18 下线；\
MiniMax-M3 不设 thinking 时各协议默认不同（Anthropic 关、Chat 开、Responses 关）";

pub static VENDORS: &[Vendor] = &[
    Vendor {
        id: "deepseek",
        name: "DeepSeek",
        sites: &["cn", "global"],
        anthropic_base: Some("https://api.deepseek.com/anthropic"),
        anthropic_auth: AnthropicAuth::XApiKey,
        openai_base: Some("https://api.deepseek.com"),
        responses_base: Some("https://api.deepseek.com"),
        chat_stream_usage: false,
        models: &["deepseek-v4-pro", "deepseek-flash"],
        subscription_key_prefixes: &[],
        models_url: Some("https://api.deepseek.com/models"),
        notes: DEEPSEEK_NOTES,
    },
    Vendor {
        id: "qwen-cn",
        name: "阿里云百炼（北京）",
        sites: &["cn"],
        anthropic_base: Some("https://dashscope.aliyuncs.com/apps/anthropic"),
        anthropic_auth: AnthropicAuth::XApiKey,
        openai_base: Some("https://dashscope.aliyuncs.com/compatible-mode/v1"),
        responses_base: Some("https://dashscope.aliyuncs.com/compatible-mode/v1"),
        chat_stream_usage: true,
        models: &["qwen3.8-max", "qwen3.8-flash", "qwen3.7-plus"],
        subscription_key_prefixes: &["sk-sp-"],
        models_url: None,
        notes: QWEN_NOTES,
    },
    Vendor {
        id: "qwen-intl",
        name: "Alibaba Cloud Model Studio (Singapore)",
        sites: &["global"],
        anthropic_base: Some("https://dashscope-intl.aliyuncs.com/apps/anthropic"),
        anthropic_auth: AnthropicAuth::XApiKey,
        openai_base: Some("https://dashscope-intl.aliyuncs.com/compatible-mode/v1"),
        responses_base: Some("https://dashscope-intl.aliyuncs.com/compatible-mode/v1"),
        chat_stream_usage: true,
        models: &["qwen3.8-max", "qwen3.8-flash", "qwen3.7-plus"],
        subscription_key_prefixes: &["sk-sp-"],
        models_url: None,
        notes: QWEN_NOTES,
    },
    Vendor {
        id: "qwen-us",
        name: "Alibaba Cloud Model Studio (US Virginia)",
        sites: &["global"],
        anthropic_base: Some("https://dashscope-us.aliyuncs.com/apps/anthropic"),
        anthropic_auth: AnthropicAuth::XApiKey,
        openai_base: Some("https://dashscope-us.aliyuncs.com/compatible-mode/v1"),
        responses_base: Some("https://dashscope-us.aliyuncs.com/compatible-mode/v1"),
        chat_stream_usage: true,
        models: &["qwen3.8-max", "qwen3.8-flash", "qwen3.7-plus"],
        subscription_key_prefixes: &["sk-sp-"],
        models_url: None,
        notes: QWEN_NOTES,
    },
    Vendor {
        id: "qwen-hk",
        name: "阿里云百炼（中国香港）",
        sites: &["global"],
        anthropic_base: Some("https://cn-hongkong.dashscope.aliyuncs.com/apps/anthropic"),
        anthropic_auth: AnthropicAuth::XApiKey,
        openai_base: Some("https://cn-hongkong.dashscope.aliyuncs.com/compatible-mode/v1"),
        responses_base: Some("https://cn-hongkong.dashscope.aliyuncs.com/compatible-mode/v1"),
        chat_stream_usage: true,
        models: &["qwen3.8-max", "qwen3.8-flash", "qwen3.7-plus"],
        subscription_key_prefixes: &["sk-sp-"],
        models_url: None,
        notes: QWEN_NOTES,
    },
    Vendor {
        id: "glm-cn",
        name: "智谱 BigModel",
        sites: &["cn"],
        anthropic_base: Some("https://open.bigmodel.cn/api/anthropic"),
        anthropic_auth: AnthropicAuth::XApiKey,
        openai_base: Some("https://open.bigmodel.cn/api/paas/v4"),
        responses_base: Some("https://open.bigmodel.cn/api/v1"),
        chat_stream_usage: false,
        models: &["glm-5.3", "glm-5.3-flash"],
        subscription_key_prefixes: &[],
        models_url: None,
        notes: GLM_NOTES,
    },
    Vendor {
        id: "glm-intl",
        name: "Z.ai",
        sites: &["global"],
        anthropic_base: Some("https://api.z.ai/api/anthropic"),
        anthropic_auth: AnthropicAuth::XApiKey,
        openai_base: Some("https://api.z.ai/api/paas/v4"),
        responses_base: Some("https://api.z.ai/api/v1"),
        chat_stream_usage: false,
        models: &["glm-5.3", "glm-5.3-flash"],
        subscription_key_prefixes: &[],
        models_url: None,
        notes: GLM_NOTES,
    },
    Vendor {
        id: "kimi-cn",
        name: "Kimi 开放平台",
        sites: &["cn"],
        anthropic_base: Some("https://api.moonshot.cn/anthropic"),
        anthropic_auth: AnthropicAuth::Bearer,
        openai_base: Some("https://api.moonshot.cn/v1"),
        responses_base: Some("https://api.moonshot.cn/v1"),
        chat_stream_usage: true,
        models: &["kimi-k3"],
        subscription_key_prefixes: &[],
        models_url: Some("https://api.moonshot.cn/v1/models"),
        notes: KIMI_NOTES,
    },
    Vendor {
        id: "kimi-intl",
        name: "Kimi Platform (international)",
        sites: &["global"],
        anthropic_base: Some("https://api.moonshot.ai/anthropic"),
        anthropic_auth: AnthropicAuth::Bearer,
        openai_base: Some("https://api.moonshot.ai/v1"),
        responses_base: Some("https://api.moonshot.ai/v1"),
        chat_stream_usage: true,
        models: &["kimi-k3"],
        subscription_key_prefixes: &[],
        models_url: Some("https://api.moonshot.ai/v1/models"),
        notes: KIMI_NOTES,
    },
    Vendor {
        id: "minimax-cn",
        name: "MiniMax 开放平台",
        sites: &["cn"],
        anthropic_base: Some("https://api.minimax.cn/anthropic"),
        anthropic_auth: AnthropicAuth::Bearer,
        openai_base: Some("https://api.minimax.cn/v1"),
        responses_base: Some("https://api.minimax.cn/v1"),
        chat_stream_usage: true,
        models: &["MiniMax-M3"],
        subscription_key_prefixes: &["sk-cp-"],
        models_url: Some("https://api.minimax.cn/v1/models"),
        notes: MINIMAX_NOTES,
    },
    Vendor {
        id: "minimax-intl",
        name: "MiniMax (international)",
        sites: &["global"],
        anthropic_base: Some("https://api.minimax.io/anthropic"),
        anthropic_auth: AnthropicAuth::Bearer,
        openai_base: Some("https://api.minimax.io/v1"),
        responses_base: Some("https://api.minimax.io/v1"),
        chat_stream_usage: true,
        models: &["MiniMax-M3"],
        subscription_key_prefixes: &["sk-cp-"],
        models_url: Some("https://api.minimax.io/v1/models"),
        notes: MINIMAX_NOTES,
    },
];

pub fn vendor(id: &str) -> Option<&'static Vendor> {
    VENDORS.iter().find(|v| v.id == id)
}

/// 保存 key 前的检查：不能是订阅类 key，不能带空白或控制字符（会被拼进请求头）。
pub fn check_key(vendor_id: &str, key: &str) -> Result<(), String> {
    if key.is_empty() || key.len() > 4096 {
        return Err("API key is empty or too long".into());
    }
    if key.bytes().any(|b| !(0x21..=0x7e).contains(&b)) {
        return Err("API key contains whitespace or non-printable characters".into());
    }
    if let Some(v) = vendor(vendor_id)
        && let Some(prefix) = v
            .subscription_key_prefixes
            .iter()
            .find(|p| key.starts_with(**p))
    {
        return Err(format!(
            "{} subscription keys ({prefix}...) can only be used in the vendor's own tools; use a pay-as-you-go API key",
            v.name
        ));
    }
    Ok(())
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
            assert_ne!(
                v.anthropic_auth,
                AnthropicAuth::Both,
                "{}: pick the documented header",
                v.id
            );
            assert!(
                v.anthropic_base.is_some() || v.openai_base.is_some(),
                "{} has no endpoint",
                v.id
            );
            assert!(!v.sites.is_empty() && v.sites.iter().all(|s| matches!(*s, "cn" | "global")));
            for base in [
                v.anthropic_base,
                v.openai_base,
                v.responses_base,
                v.models_url,
            ]
            .into_iter()
            .flatten()
            {
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
        }
    }

    #[test]
    fn subscription_keys_are_refused() {
        assert!(
            check_key("qwen-cn", "sk-sp-abcdef0123456789")
                .unwrap_err()
                .contains("subscription")
        );
        assert!(check_key("minimax-intl", "sk-cp-abcdef0123456789").is_err());
        assert_eq!(check_key("minimax-cn", "sk-api-abcdef0123456789"), Ok(()));
        assert_eq!(check_key(CUSTOM, "sk-sp-whatever"), Ok(()));
        assert!(check_key("deepseek", "sk-abc\n").is_err());
        assert!(check_key("deepseek", "sk abc").is_err());
        assert!(check_key("deepseek", "").is_err());
    }
}
