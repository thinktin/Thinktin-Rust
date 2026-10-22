//! 模型厂商适配表（架构方案 5.3，WBS 9.7、9.12）。
//!
//! 只预置模型品牌方自己的官方接口；聚合平台、中转站不预置，用户按自定义端点（`custom`）填地址。
//! 每家厂商、每个区域一条记录（各家的国内站和国际站账号、key 互不相通，用错区域的地址会 401）。
//! base URL 的约定和 agent 侧一致：
//! - `anthropic_base` 不带 `/v1`（同 `ANTHROPIC_BASE_URL`），网关在后面拼 `/v1/messages`；
//! - `openai_base`、`responses_base` 是 `/chat/completions`、`/responses` 之前的部分。
//!   多数厂商两者相同；智谱的 Responses 在另一个前缀下。
//!
//! 模型网关按它路由；接入网关按它校验 key，并通过 `GET /v1/vendors` 给 App 列出可选厂商。
//! 内容按各家官方文档核对，见 docs/llm-gateway.md 第 11 节。

use serde::Serialize;

/// 最近一次核对日期（各家的核对日期见 docs/llm-gateway.md 第 11 节）。
pub const VERIFIED: &str = "2026-10-16";

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
    pub anthropic_base: Option<&'static str>,
    pub anthropic_auth: AnthropicAuth,
    /// Chat Completions 的前缀。OpenAI 协议一律用 `Authorization: Bearer`。
    pub openai_base: Option<&'static str>,
    /// Responses API 的前缀（Codex 只会用这个协议）。
    pub responses_base: Option<&'static str>,
    /// Chat Completions 流式请求是否需要网关补 `stream_options.include_usage` 才能拿到用量。
    /// 本来就在分片里带用量、或者文档里没有这个参数的厂商为 false。
    pub chat_stream_usage: bool,
    /// 推荐的上游模型（给配置界面用，以厂商文档为准，变化很快）。
    pub models: &'static [&'static str],
    /// 订阅类 key（编程套餐等）的前缀。这类 key 按厂商条款只能在官方工具里用，不能经第三方平台中转，保存时拒绝
    /// （区分大小写，只查这家厂商的 key；自定义端点不查）。
    pub subscription_key_prefixes: &'static [&'static str],
    /// 这家厂商编程套餐、订阅套餐的专用地址（前缀，小写、不带结尾的 `/`）。自定义端点填了任何一家的这些地址时拒绝
    /// （去掉首尾空白、转小写后等于它或者接着是 `/`；见 [`plan_only_base`]）。只防误填，不是安全边界。
    pub plan_only_bases: &'static [&'static str],
    /// 校验 key 用的模型列表接口（Bearer），没有就为空（9.8）。
    pub models_url: Option<&'static str>,
    pub notes: &'static str,
}

/// 自定义端点（vLLM、OneAPI 等）：地址由凭证提供。
pub const CUSTOM: &str = "custom";

/// 模型协议的名字（接口里的）：Anthropic Messages、Chat Completions、Responses。顺序就是界面上显示的顺序。
pub const PROTOCOLS: [&str; 3] = ["anthropic", "chat", "responses"];

impl Vendor {
    /// 这家厂商提供哪些协议（按 [`PROTOCOLS`] 的顺序）。
    pub fn protocols(&self) -> Vec<&'static str> {
        protocols_of(
            self.anthropic_base.is_some(),
            self.openai_base.is_some(),
            self.responses_base.is_some(),
        )
    }
}

/// 配了哪几种接口地址就提供哪几种协议（自定义端点的 key 也按这个算）。
pub fn protocols_of(anthropic: bool, chat: bool, responses: bool) -> Vec<&'static str> {
    [anthropic, chat, responses]
        .into_iter()
        .zip(PROTOCOLS)
        .filter_map(|(has, name)| has.then_some(name))
        .collect()
}

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
const ANTHROPIC_NOTES: &str = "原生 Messages 接口；OpenAI 兼容层（/v1/chat/completions）官方定位是测试和对比用，\
不返回思考内容、不支持提示缓存，Chat 类 agent 能用，但 Claude 建议走 Anthropic 协议；\
Claude 订阅（Free、Pro、Max）的 OAuth 令牌（sk-ant-oat…）按条款不得经第三方平台居间，保存时拒绝；\
Opus 5.5 不能关思考、强制工具调用会报错、思考块绑定模型和会话，同一会话中途换上游模型（包括降级链换到别的模型）会出错；\
模型列表 GET /v1/models 要 x-api-key 加 anthropic-version，不是 Bearer，所以 models_url 留空";
const OPENAI_NOTES: &str = "Responses 有状态（支持 previous_response_id、store），新功能优先在 Responses 上提供；\
Codex 用自定义供应商时每次发完整上下文，不依赖服务端存储";
const GEMINI_NOTES: &str = "只接 Gemini API（Google AI Studio）的 key，不是 Vertex AI；没有 Responses，Codex 不能用；\
思考签名要原样回传（OpenAI 兼容层支持，网关透传不受影响）；reasoning_effort 和 extra_body 里的 thinking_level、thinking_budget 不能同时给；\
已弃用的模型 id 会被静默转到新模型，实际用的模型可能和配置的不同";
const XAI_NOTES: &str = "官方把 Chat Completions 标为旧接口，新功能在 Responses 上；文档没有 Anthropic 兼容接口；\
Chat Completions 流式每个分片都带累计用量，不用补 include_usage（网关取最后一个）；\
推理模型首字节可能很慢，官方示例把超时设到 3600 秒";
const MISTRAL_NOTES: &str = "接口文档没有 stream_options，网关不补 include_usage，流式拿不到用量时按估算记账（待联调）；\
没有 Responses，Codex 不能用；Codestral 的专用域名和 key 不在这里；模型用 -latest 别名，实际版本以 /v1/models 为准";
const DOUBAO_NOTES: &str = "Responses 默认开启存储（store 默认 true），要无状态得显式传 store: false；\
Coding Plan、Agent Plan 用专属 key 和专属地址（/api/coding、/api/plan），套餐额度按条款只能在 AI 编程工具里用，这里只接按量付费 key；\
model 也可以填推理接入点 id（ep-…）";
const BYTEPLUS_NOTES: &str = "火山方舟的国际版，账号和 key 与火山方舟不通；默认新加坡区（ap-southeast-1），\
欧洲区地址是 https://ark.eu-west.bytepluses.com/api/v3，需要时按自定义端点填；\
Coding Plan 有专属地址（/api/coding/v3），这里只接按量付费 key；文档没写 Anthropic 兼容接口；模型 id 以控制台为准";
const ERNIE_NOTES: &str = "千帆上的对话模型（包括第三方模型）都能走这两种协议；没有 Responses，Codex 不能用；\
Coding Plan 用专属地址（/v2/coding、/anthropic/coding），套餐 key 调普通接口会 401；\
Anthropic 接口 input_tokens 的含义官方发过更新公告，计量待联调核对；\
Chat Completions 流式用量的位置文档没写，网关不补 include_usage；模型 id 以千帆控制台为准";
const HUNYUAN_NOTES: &str = "原混元 API（api.hunyuan.cloud.tencent.com）已于 2026-09-30 停服，统一走 TokenHub（也托管其他厂商的模型）；\
国内站和国际站（新加坡）控制台、key 分开，美国站是 tokenhub-us.tencentcloudmaas.com；\
Chat Completions 流式要 include_usage 才在最后一个分片给用量；Token Plan 的 key（sk-tp-）按条款严禁 API 调用，保存时拒绝；\
Anthropic 接口的缓存用量字段不完整；部分模型开思考时 temperature 必须为 1；hy4-preview 支持 Responses";
const STEPFUN_NOTES: &str = "Chat Completions 流式每个分片都带累计用量，不用补 include_usage；\
Anthropic 接口文档只列了部分请求字段（没有 thinking、metadata，思考强度用 output_config.effort）；\
Step Plan 和按量付费用同一把 key、按地址计费（/step_plan 走套餐），这里固定走按量付费地址；没有 Responses，Codex 不能用";

pub static VENDORS: &[Vendor] = &[
    Vendor {
        id: "deepseek",
        name: "DeepSeek",
        anthropic_base: Some("https://api.deepseek.com/anthropic"),
        anthropic_auth: AnthropicAuth::XApiKey,
        openai_base: Some("https://api.deepseek.com"),
        responses_base: Some("https://api.deepseek.com"),
        chat_stream_usage: false,
        models: &["deepseek-v4-pro", "deepseek-flash"],
        subscription_key_prefixes: &[],
        plan_only_bases: &[],
        models_url: Some("https://api.deepseek.com/models"),
        notes: DEEPSEEK_NOTES,
    },
    Vendor {
        id: "qwen-cn",
        name: "阿里云百炼（北京）",
        anthropic_base: Some("https://dashscope.aliyuncs.com/apps/anthropic"),
        anthropic_auth: AnthropicAuth::XApiKey,
        openai_base: Some("https://dashscope.aliyuncs.com/compatible-mode/v1"),
        responses_base: Some("https://dashscope.aliyuncs.com/compatible-mode/v1"),
        chat_stream_usage: true,
        models: &["qwen3.8-max", "qwen3.8-flash", "qwen3.7-plus"],
        subscription_key_prefixes: &["sk-sp-"],
        plan_only_bases: &[],
        models_url: None,
        notes: QWEN_NOTES,
    },
    Vendor {
        id: "qwen-intl",
        name: "Alibaba Cloud Model Studio (Singapore)",
        anthropic_base: Some("https://dashscope-intl.aliyuncs.com/apps/anthropic"),
        anthropic_auth: AnthropicAuth::XApiKey,
        openai_base: Some("https://dashscope-intl.aliyuncs.com/compatible-mode/v1"),
        responses_base: Some("https://dashscope-intl.aliyuncs.com/compatible-mode/v1"),
        chat_stream_usage: true,
        models: &["qwen3.8-max", "qwen3.8-flash", "qwen3.7-plus"],
        subscription_key_prefixes: &["sk-sp-"],
        plan_only_bases: &[],
        models_url: None,
        notes: QWEN_NOTES,
    },
    Vendor {
        id: "qwen-us",
        name: "Alibaba Cloud Model Studio (US Virginia)",
        anthropic_base: Some("https://dashscope-us.aliyuncs.com/apps/anthropic"),
        anthropic_auth: AnthropicAuth::XApiKey,
        openai_base: Some("https://dashscope-us.aliyuncs.com/compatible-mode/v1"),
        responses_base: Some("https://dashscope-us.aliyuncs.com/compatible-mode/v1"),
        chat_stream_usage: true,
        models: &["qwen3.8-max", "qwen3.8-flash", "qwen3.7-plus"],
        subscription_key_prefixes: &["sk-sp-"],
        plan_only_bases: &[],
        models_url: None,
        notes: QWEN_NOTES,
    },
    Vendor {
        id: "qwen-hk",
        name: "阿里云百炼（中国香港）",
        anthropic_base: Some("https://cn-hongkong.dashscope.aliyuncs.com/apps/anthropic"),
        anthropic_auth: AnthropicAuth::XApiKey,
        openai_base: Some("https://cn-hongkong.dashscope.aliyuncs.com/compatible-mode/v1"),
        responses_base: Some("https://cn-hongkong.dashscope.aliyuncs.com/compatible-mode/v1"),
        chat_stream_usage: true,
        models: &["qwen3.8-max", "qwen3.8-flash", "qwen3.7-plus"],
        subscription_key_prefixes: &["sk-sp-"],
        plan_only_bases: &[],
        models_url: None,
        notes: QWEN_NOTES,
    },
    Vendor {
        id: "glm-cn",
        name: "智谱 BigModel",
        anthropic_base: Some("https://open.bigmodel.cn/api/anthropic"),
        anthropic_auth: AnthropicAuth::XApiKey,
        openai_base: Some("https://open.bigmodel.cn/api/paas/v4"),
        responses_base: Some("https://open.bigmodel.cn/api/v1"),
        chat_stream_usage: false,
        models: &["glm-5.3", "glm-5.3-flash"],
        subscription_key_prefixes: &[],
        plan_only_bases: &["https://open.bigmodel.cn/api/coding"],
        models_url: None,
        notes: GLM_NOTES,
    },
    Vendor {
        id: "glm-intl",
        name: "Z.ai",
        anthropic_base: Some("https://api.z.ai/api/anthropic"),
        anthropic_auth: AnthropicAuth::XApiKey,
        openai_base: Some("https://api.z.ai/api/paas/v4"),
        responses_base: Some("https://api.z.ai/api/v1"),
        chat_stream_usage: false,
        models: &["glm-5.3", "glm-5.3-flash"],
        subscription_key_prefixes: &[],
        plan_only_bases: &["https://api.z.ai/api/coding"],
        models_url: None,
        notes: GLM_NOTES,
    },
    Vendor {
        id: "kimi-cn",
        name: "Kimi 开放平台",
        anthropic_base: Some("https://api.moonshot.cn/anthropic"),
        anthropic_auth: AnthropicAuth::Bearer,
        openai_base: Some("https://api.moonshot.cn/v1"),
        responses_base: Some("https://api.moonshot.cn/v1"),
        chat_stream_usage: true,
        models: &["kimi-k3"],
        subscription_key_prefixes: &[],
        plan_only_bases: &[],
        models_url: Some("https://api.moonshot.cn/v1/models"),
        notes: KIMI_NOTES,
    },
    Vendor {
        id: "kimi-intl",
        name: "Kimi Platform (international)",
        anthropic_base: Some("https://api.moonshot.ai/anthropic"),
        anthropic_auth: AnthropicAuth::Bearer,
        openai_base: Some("https://api.moonshot.ai/v1"),
        responses_base: Some("https://api.moonshot.ai/v1"),
        chat_stream_usage: true,
        models: &["kimi-k3"],
        subscription_key_prefixes: &[],
        plan_only_bases: &[],
        models_url: Some("https://api.moonshot.ai/v1/models"),
        notes: KIMI_NOTES,
    },
    Vendor {
        id: "minimax-cn",
        name: "MiniMax 开放平台",
        anthropic_base: Some("https://api.minimax.cn/anthropic"),
        anthropic_auth: AnthropicAuth::Bearer,
        openai_base: Some("https://api.minimax.cn/v1"),
        responses_base: Some("https://api.minimax.cn/v1"),
        chat_stream_usage: true,
        models: &["MiniMax-M3"],
        subscription_key_prefixes: &["sk-cp-"],
        plan_only_bases: &[],
        models_url: Some("https://api.minimax.cn/v1/models"),
        notes: MINIMAX_NOTES,
    },
    Vendor {
        id: "minimax-intl",
        name: "MiniMax (international)",
        anthropic_base: Some("https://api.minimax.io/anthropic"),
        anthropic_auth: AnthropicAuth::Bearer,
        openai_base: Some("https://api.minimax.io/v1"),
        responses_base: Some("https://api.minimax.io/v1"),
        chat_stream_usage: true,
        models: &["MiniMax-M3"],
        subscription_key_prefixes: &["sk-cp-"],
        plan_only_bases: &[],
        models_url: Some("https://api.minimax.io/v1/models"),
        notes: MINIMAX_NOTES,
    },
    // ---- 9.12：海外品牌方 ----
    Vendor {
        id: "anthropic",
        name: "Anthropic (Claude)",
        anthropic_base: Some("https://api.anthropic.com"),
        anthropic_auth: AnthropicAuth::XApiKey,
        openai_base: Some("https://api.anthropic.com/v1"),
        responses_base: None,
        chat_stream_usage: true,
        models: &[
            "claude-opus-5-5",
            "claude-sonnet-5-5",
            "claude-haiku-5-5",
            "claude-fable-5-1",
        ],
        subscription_key_prefixes: &["sk-ant-oat", "sk-ant-ort"],
        plan_only_bases: &[],
        models_url: None,
        notes: ANTHROPIC_NOTES,
    },
    Vendor {
        id: "openai",
        name: "OpenAI",
        anthropic_base: None,
        anthropic_auth: AnthropicAuth::Bearer,
        openai_base: Some("https://api.openai.com/v1"),
        responses_base: Some("https://api.openai.com/v1"),
        chat_stream_usage: true,
        models: &["gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna"],
        subscription_key_prefixes: &[],
        plan_only_bases: &[],
        models_url: Some("https://api.openai.com/v1/models"),
        notes: OPENAI_NOTES,
    },
    Vendor {
        id: "gemini",
        name: "Google Gemini",
        anthropic_base: None,
        anthropic_auth: AnthropicAuth::Bearer,
        openai_base: Some("https://generativelanguage.googleapis.com/v1beta/openai"),
        responses_base: None,
        chat_stream_usage: true,
        models: &[
            "gemini-4-argon",
            "gemini-3.8-flash",
            "gemini-3.5-flash-lite",
        ],
        subscription_key_prefixes: &[],
        plan_only_bases: &[],
        models_url: Some("https://generativelanguage.googleapis.com/v1beta/openai/models"),
        notes: GEMINI_NOTES,
    },
    Vendor {
        id: "xai",
        name: "xAI (Grok)",
        anthropic_base: None,
        anthropic_auth: AnthropicAuth::Bearer,
        openai_base: Some("https://api.x.ai/v1"),
        responses_base: Some("https://api.x.ai/v1"),
        chat_stream_usage: false,
        models: &["grok-4.7"],
        subscription_key_prefixes: &[],
        plan_only_bases: &[],
        models_url: Some("https://api.x.ai/v1/models"),
        notes: XAI_NOTES,
    },
    Vendor {
        id: "mistral",
        name: "Mistral AI",
        anthropic_base: None,
        anthropic_auth: AnthropicAuth::Bearer,
        openai_base: Some("https://api.mistral.ai/v1"),
        responses_base: None,
        chat_stream_usage: false,
        models: &[
            "mistral-large-latest",
            "mistral-medium-latest",
            "mistral-small-latest",
        ],
        subscription_key_prefixes: &[],
        plan_only_bases: &[],
        models_url: Some("https://api.mistral.ai/v1/models"),
        notes: MISTRAL_NOTES,
    },
    // ---- 9.12：国内品牌方 ----
    Vendor {
        id: "doubao-cn",
        name: "火山方舟（豆包）",
        anthropic_base: Some("https://ark.cn-beijing.volces.com/api/compatible"),
        anthropic_auth: AnthropicAuth::Bearer,
        openai_base: Some("https://ark.cn-beijing.volces.com/api/v3"),
        responses_base: Some("https://ark.cn-beijing.volces.com/api/v3"),
        chat_stream_usage: true,
        models: &["doubao-seed-2-1-pro-260628"],
        subscription_key_prefixes: &[],
        plan_only_bases: &[
            "https://ark.cn-beijing.volces.com/api/coding",
            "https://ark.cn-beijing.volces.com/api/plan",
        ],
        models_url: None,
        notes: DOUBAO_NOTES,
    },
    Vendor {
        id: "doubao-intl",
        name: "BytePlus ModelArk",
        anthropic_base: None,
        anthropic_auth: AnthropicAuth::Bearer,
        openai_base: Some("https://ark.ap-southeast.bytepluses.com/api/v3"),
        responses_base: Some("https://ark.ap-southeast.bytepluses.com/api/v3"),
        chat_stream_usage: true,
        models: &[],
        subscription_key_prefixes: &[],
        plan_only_bases: &["https://ark.ap-southeast.bytepluses.com/api/coding"],
        models_url: None,
        notes: BYTEPLUS_NOTES,
    },
    Vendor {
        id: "ernie",
        name: "百度千帆（文心）",
        anthropic_base: Some("https://qianfan.baidubce.com/anthropic"),
        anthropic_auth: AnthropicAuth::XApiKey,
        openai_base: Some("https://qianfan.baidubce.com/v2"),
        responses_base: None,
        chat_stream_usage: false,
        models: &[],
        subscription_key_prefixes: &[],
        plan_only_bases: &[
            "https://qianfan.baidubce.com/v2/coding",
            "https://qianfan.baidubce.com/anthropic/coding",
        ],
        models_url: None,
        notes: ERNIE_NOTES,
    },
    Vendor {
        id: "hunyuan-cn",
        name: "腾讯混元 TokenHub",
        anthropic_base: Some("https://tokenhub.tencentmaas.com"),
        anthropic_auth: AnthropicAuth::XApiKey,
        openai_base: Some("https://tokenhub.tencentmaas.com/v1"),
        responses_base: Some("https://tokenhub.tencentmaas.com/v1"),
        chat_stream_usage: true,
        models: &["hy3", "hy4-preview"],
        subscription_key_prefixes: &["sk-tp-"],
        plan_only_bases: &["https://api.lkeap.cloud.tencent.com/plan"],
        models_url: None,
        notes: HUNYUAN_NOTES,
    },
    Vendor {
        id: "hunyuan-intl",
        name: "Tencent Hunyuan TokenHub (Singapore)",
        anthropic_base: Some("https://tokenhub-intl.tencentcloudmaas.com"),
        anthropic_auth: AnthropicAuth::Bearer,
        openai_base: Some("https://tokenhub-intl.tencentcloudmaas.com/v1"),
        responses_base: Some("https://tokenhub-intl.tencentcloudmaas.com/v1"),
        chat_stream_usage: true,
        models: &["hy3", "hy4-preview"],
        subscription_key_prefixes: &["sk-tp-"],
        plan_only_bases: &["https://tokenhub-intl.tencentcloudmaas.com/plan"],
        models_url: None,
        notes: HUNYUAN_NOTES,
    },
    Vendor {
        id: "stepfun",
        name: "阶跃星辰",
        anthropic_base: Some("https://api.stepfun.com"),
        anthropic_auth: AnthropicAuth::Bearer,
        openai_base: Some("https://api.stepfun.com/v1"),
        responses_base: None,
        chat_stream_usage: false,
        models: &["step-5-preview", "step-3.7-flash"],
        subscription_key_prefixes: &[],
        plan_only_bases: &["https://api.stepfun.com/step_plan"],
        models_url: None,
        notes: STEPFUN_NOTES,
    },
];

/// 编程套餐、订阅套餐的专用地址（前缀）。套餐额度按各家条款只能在官方支持的编程工具里用，
/// 平台不接：用户按自定义端点填这些地址时拒绝。只防误填，不是安全边界。和各厂商的 `plan_only_bases`
/// 合起来一样（测试保证）：接口按厂商给出（11.9），App 不用再抄这一份。
pub const PLAN_ONLY_BASES: &[&str] = &[
    "https://ark.cn-beijing.volces.com/api/coding",
    "https://ark.cn-beijing.volces.com/api/plan",
    "https://ark.ap-southeast.bytepluses.com/api/coding",
    "https://qianfan.baidubce.com/v2/coding",
    "https://qianfan.baidubce.com/anthropic/coding",
    "https://api.lkeap.cloud.tencent.com/plan",
    "https://tokenhub-intl.tencentcloudmaas.com/plan",
    "https://api.stepfun.com/step_plan",
    "https://open.bigmodel.cn/api/coding",
    "https://api.z.ai/api/coding",
];

pub fn vendor(id: &str) -> Option<&'static Vendor> {
    VENDORS.iter().find(|v| v.id == id)
}

/// 凭证能用的厂商 id：预置厂商或自定义端点。
pub fn is_known(id: &str) -> bool {
    id == CUSTOM || vendor(id).is_some()
}

/// 地址是不是某家的套餐专用地址，是的话返回命中的前缀（不区分大小写，按路径段匹配）。
pub fn plan_only_base(base: &str) -> Option<&'static str> {
    let base = base.trim().to_ascii_lowercase();
    PLAN_ONLY_BASES.iter().copied().find(|&prefix| {
        base.strip_prefix(prefix)
            .is_some_and(|rest| rest.is_empty() || rest.starts_with('/'))
    })
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

    #[test]
    fn plan_only_bases_are_per_vendor() {
        let mut union: Vec<&str> = VENDORS
            .iter()
            .flat_map(|v| v.plan_only_bases.iter().copied())
            .collect();
        let mut all = PLAN_ONLY_BASES.to_vec();
        union.sort_unstable();
        all.sort_unstable();
        assert_eq!(
            union, all,
            "each plan-only base belongs to exactly one vendor"
        );
        for v in VENDORS {
            for &b in v.plan_only_bases {
                assert!(b.starts_with("https://") && !b.ends_with('/'), "{b}");
                assert_eq!(b, b.to_ascii_lowercase(), "{b}");
                assert_eq!(plan_only_base(b), Some(b));
            }
            for p in v.subscription_key_prefixes {
                assert!(p.bytes().all(|c| (0x21..=0x7e).contains(&c)), "{p}");
            }
        }
        assert_eq!(
            vendor("doubao-cn").unwrap().plan_only_bases,
            [
                "https://ark.cn-beijing.volces.com/api/coding",
                "https://ark.cn-beijing.volces.com/api/plan"
            ]
        );
        assert!(vendor("deepseek").unwrap().plan_only_bases.is_empty());
    }

    #[test]
    fn table_is_consistent() {
        let mut ids = std::collections::HashSet::new();
        for v in VENDORS {
            assert!(ids.insert(v.id), "duplicate vendor {}", v.id);
            assert_ne!(v.id, CUSTOM);
            assert!(
                v.id.bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-'),
                "{}: ids are lowercase letters, digits and '-'",
                v.id
            );
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
            for base in [
                v.anthropic_base,
                v.openai_base,
                v.responses_base,
                v.models_url,
            ]
            .into_iter()
            .flatten()
            {
                assert!(base.starts_with("https://"), "{base} must be https");
                assert!(!base.ends_with('/'), "{base} must not end with '/'");
                assert_eq!(plan_only_base(base), None, "{base} is a plan-only address");
            }
            if let Some(base) = v.anthropic_base {
                assert!(
                    !base.ends_with("/v1"),
                    "{base}: anthropic base excludes /v1"
                );
            }
            for p in v.subscription_key_prefixes {
                assert!(p.len() >= 4, "{}: prefix {p} is too broad", v.id);
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
        assert!(check_key("hunyuan-cn", "sk-tp-abcdef0123456789").is_err());
        assert!(check_key("hunyuan-intl", "sk-tp-abcdef0123456789").is_err());
        assert!(check_key("anthropic", "sk-ant-oat01-abcdef0123456789").is_err());
        assert_eq!(
            check_key("anthropic", "sk-ant-api03-abcdef0123456789"),
            Ok(())
        );
        assert_eq!(check_key(CUSTOM, "sk-sp-whatever"), Ok(()));
        assert!(check_key("deepseek", "sk-abc\n").is_err());
        assert!(check_key("deepseek", "sk abc").is_err());
        assert!(check_key("deepseek", "").is_err());
    }

    #[test]
    fn plan_only_bases_are_detected() {
        assert_eq!(
            plan_only_base("https://ark.cn-beijing.volces.com/api/coding/v3"),
            Some("https://ark.cn-beijing.volces.com/api/coding")
        );
        assert!(plan_only_base("https://ARK.cn-beijing.volces.com/api/plan").is_some());
        assert!(plan_only_base(" https://api.stepfun.com/step_plan/v1 ").is_some());
        assert!(plan_only_base("https://api.z.ai/api/coding/paas/v4").is_some());
        assert!(plan_only_base("https://api.lkeap.cloud.tencent.com/plan/anthropic").is_some());
        assert_eq!(
            plan_only_base("https://ark.cn-beijing.volces.com/api/v3"),
            None
        );
        assert_eq!(
            plan_only_base("https://ark.cn-beijing.volces.com/api/codingx"),
            None
        );
        assert_eq!(plan_only_base("https://api.stepfun.com/v1"), None);
    }

    #[test]
    fn known_vendor_ids() {
        assert!(is_known(CUSTOM));
        assert!(is_known("anthropic"));
        assert!(is_known("hunyuan-intl"));
        assert!(!is_known("deepseek:cn"));
        assert!(!is_known(""));
    }
}
