//! AI 生成内容的标识（WBS 16.3，《人工智能生成合成内容标识办法》）。
//!
//! - 显式标识：给用户看的文字提示。客户端在 agent 输出旁边显示；系统通知、下载的文本文件里
//!   由服务端加上 [`EXPLICIT_LABEL`]。
//! - 隐式标识：写进文件元数据的制作要素（生成合成内容属性、服务提供者、内容编号），见 [`AigcMetadata`]。
//!   字段名按 GB 45438-2025 附录 E 的公开解读，上线前要拿标准原文核对。

use serde::{Deserialize, Serialize};

/// 显式标识的文字。
pub const EXPLICIT_LABEL: &str = "AI 生成";

/// 下载的文本文件末尾追加的显式标识。
pub fn text_footer(provider: &str) -> String {
    format!("\n\n——本内容由人工智能生成（{provider}）\n")
}

/// 这类事件的内容是 agent（模型）生成的，客户端显示时要带显式标识。
pub fn is_ai_generated_event(kind: &str) -> bool {
    matches!(kind, "agent.message" | "agent.thought" | "agent.plan")
}

/// 隐式标识（文件元数据）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AigcMetadata {
    /// 生成合成内容属性："1" 表示是人工智能生成合成内容。
    #[serde(rename = "Label")]
    pub label: String,
    /// 服务提供者名称或编码。
    #[serde(rename = "ContentProducer")]
    pub content_producer: String,
    /// 内容编号。
    #[serde(rename = "ProduceID")]
    pub produce_id: String,
}

impl AigcMetadata {
    pub fn generated(provider: &str, content_id: &str) -> Self {
        Self {
            label: "1".into(),
            content_producer: provider.into(),
            produce_id: content_id.into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn metadata_and_labels() {
        let m = AigcMetadata::generated("thinktin", "a1");
        assert_eq!(
            serde_json::to_value(&m).unwrap(),
            serde_json::json!({"Label": "1", "ContentProducer": "thinktin", "ProduceID": "a1"})
        );
        assert!(is_ai_generated_event("agent.message"));
        assert!(!is_ai_generated_event("run.state"));
        assert!(text_footer("ThinkTin").contains("人工智能生成"));
    }
}
