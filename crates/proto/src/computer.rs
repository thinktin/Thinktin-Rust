//! “我的电脑”的工具（WBS 14.2）：平台交给 agent 的电脑工具清单，名字都以 `computer_` 开头。
//!
//! 电脑端（`desktop` 库 + macOS App）实现它们，连上设备中继时在 `hello` 里报上现在能用的
//! （随系统权限变化，比如没给屏幕录制权限就没有截图）。平台只把清单交给有电脑的用户的 agent，
//! 调用按会话绑定转给用户自己的电脑（见 docs/relay.md）。
//!
//! 风险分三档，由电脑端把关（平台只转发，见 docs/pairing.md）：
//! - **只读**：看目录、读文件、截图——要手机签发的能力令牌覆盖这个目录；
//! - **普通操作**：写文件、键鼠输入、打开网页和应用——要能力令牌覆盖目录或应用；
//! - **高危操作**：删除、执行命令——每次都要用户在手机上签名批准，不能预授权（架构方案 4.7、7）。

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::shim::PlatformTool;

/// 工具名的前缀。
pub const PREFIX: &str = "computer_";

/// 只读、普通操作等电脑多久（秒）。
pub const TIMEOUT_SECS: u64 = 60;
/// 高危操作等多久（秒）：要等用户在手机上批准。
pub const HIGH_RISK_TIMEOUT_SECS: u64 = 15 * 60;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Risk {
    /// 看目录、读文件、截图：能力令牌覆盖就行。
    ReadOnly,
    /// 写文件、键鼠输入、打开网页和应用：能力令牌覆盖就行。
    Normal,
    /// 删除、执行命令：每次都要手机签名批准。
    High,
}

/// 一个电脑工具。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ComputerTool {
    pub name: &'static str,
    /// 给 agent 看的说明（英文，和别的平台工具一样）。
    pub description: &'static str,
    pub risk: Risk,
    /// 参数的 JSON Schema。
    pub schema: &'static str,
}

impl ComputerTool {
    pub fn input_schema(&self) -> Value {
        serde_json::from_str(self.schema).expect("the built-in schemas are valid JSON")
    }

    /// 交给 shim 的平台工具。
    pub fn platform_tool(&self) -> PlatformTool {
        PlatformTool {
            name: self.name.into(),
            description: self.description.into(),
            input_schema: self.input_schema(),
        }
    }

    /// 平台最多等电脑多久（秒）。
    pub fn timeout_secs(&self) -> u64 {
        match self.risk {
            Risk::High => HIGH_RISK_TIMEOUT_SECS,
            Risk::ReadOnly | Risk::Normal => TIMEOUT_SECS,
        }
    }
}

pub const TOOLS: &[ComputerTool] = &[
    ComputerTool {
        name: "computer_list_dir",
        description: "List a folder on the user's own computer: names, kinds, sizes and modification times. \
            Only folders the user allowed from their phone can be read.",
        risk: Risk::ReadOnly,
        schema: r#"{"type":"object","properties":{"path":{"type":"string","description":"Absolute path, e.g. /Users/me/Documents"}},"required":["path"],"additionalProperties":false}"#,
    },
    ComputerTool {
        name: "computer_read_file",
        description: "Read a file on the user's own computer. Text comes back as text and images as images; \
            read big files in pieces with offset and max_bytes. Only folders the user allowed from their phone can be read.",
        risk: Risk::ReadOnly,
        schema: r#"{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","minimum":0},"max_bytes":{"type":"integer","minimum":1,"maximum":4194304}},"required":["path"],"additionalProperties":false}"#,
    },
    ComputerTool {
        name: "computer_screenshot",
        description: "Take a screenshot of the user's computer screen. Coordinates for computer_click are pixels of this image.",
        risk: Risk::ReadOnly,
        schema: r#"{"type":"object","properties":{},"additionalProperties":false}"#,
    },
    ComputerTool {
        name: "computer_write_file",
        description: "Create or overwrite a text file on the user's own computer (or append to it). \
            Only folders the user allowed from their phone can be written.",
        risk: Risk::Normal,
        schema: r#"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"append":{"type":"boolean"}},"required":["path","content"],"additionalProperties":false}"#,
    },
    ComputerTool {
        name: "computer_open",
        description: "Open a web page, an app (by bundle id, e.g. com.apple.Safari) or a file on the user's computer.",
        risk: Risk::Normal,
        schema: r#"{"type":"object","properties":{"target":{"type":"string","description":"An https URL, an app bundle id or an absolute file path"}},"required":["target"],"additionalProperties":false}"#,
    },
    ComputerTool {
        name: "computer_click",
        description: "Click at a point on the user's screen, in pixels of the latest computer_screenshot. \
            Only apps the user allowed from their phone can be controlled.",
        risk: Risk::Normal,
        schema: r#"{"type":"object","properties":{"x":{"type":"integer","minimum":0},"y":{"type":"integer","minimum":0},"button":{"type":"string","enum":["left","right"]},"double":{"type":"boolean"}},"required":["x","y"],"additionalProperties":false}"#,
    },
    ComputerTool {
        name: "computer_type",
        description: "Type text into the app in front on the user's computer.",
        risk: Risk::Normal,
        schema: r#"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}"#,
    },
    ComputerTool {
        name: "computer_key",
        description: "Press a key or a key combination on the user's computer, e.g. return, cmd+s, cmd+shift+t.",
        risk: Risk::Normal,
        schema: r#"{"type":"object","properties":{"keys":{"type":"string"}},"required":["keys"],"additionalProperties":false}"#,
    },
    ComputerTool {
        name: "computer_delete",
        description: "Move a file or folder on the user's computer to the Trash. The user approves this on their phone \
            every time, so it may take a while; if they decline, do not try another way.",
        risk: Risk::High,
        schema: r#"{"type":"object","properties":{"path":{"type":"string"},"reason":{"type":"string","description":"Why, shown to the user"}},"required":["path","reason"],"additionalProperties":false}"#,
    },
    ComputerTool {
        name: "computer_run",
        description: "Run a shell command on the user's computer. The user approves this on their phone every time, \
            so it may take a while; if they decline, do not try another way.",
        risk: Risk::High,
        schema: r#"{"type":"object","properties":{"command":{"type":"string"},"cwd":{"type":"string"},"reason":{"type":"string","description":"Why, shown to the user"}},"required":["command","reason"],"additionalProperties":false}"#,
    },
];

/// 按名字找电脑工具。
pub fn tool(name: &str) -> Option<&'static ComputerTool> {
    TOOLS.iter().find(|t| t.name == name)
}

/// 全部电脑工具的名字（运行授权的范围、默认给 agent 的工具里用）。
pub fn names() -> impl Iterator<Item = &'static str> {
    TOOLS.iter().map(|t| t.name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_catalogue_is_well_formed() {
        let mut seen = std::collections::HashSet::new();
        for t in TOOLS {
            assert!(t.name.starts_with(PREFIX), "{}", t.name);
            assert!(PlatformTool::valid_name(t.name), "{}", t.name);
            assert!(seen.insert(t.name), "duplicate {}", t.name);
            let schema = t.input_schema();
            assert_eq!(schema["type"], "object", "{}", t.name);
            assert!(!t.description.is_empty());
            // 高危操作要说明理由（手机上给用户看）。
            if t.risk == Risk::High {
                assert!(
                    schema["required"]
                        .as_array()
                        .is_some_and(|r| r.iter().any(|f| f == "reason")),
                    "{}",
                    t.name
                );
                assert!(t.timeout_secs() > TIMEOUT_SECS);
            }
        }
        assert_eq!(
            tool("computer_screenshot").map(|t| t.risk),
            Some(Risk::ReadOnly)
        );
        assert!(tool("delegate").is_none());
        assert_eq!(names().count(), TOOLS.len());
    }
}
