//! 工具层（docs/browser.md 第 2.6、6 节）：只给白名单里的 Playwright MCP 工具；网址只收 http(s)（http 改成 https）；
//! 结果第一行写这次调用里打开网页的结果（批准了、在等用户、被拒绝……），快照太长就截断。

use serde_json::{Value, json};

use super::approvals::Outcome;
use super::pages;
use crate::bridge::ToolResult;

/// 给 agent 的浏览器工具（以 Playwright MCP 0.0.84 实际的工具名为准，`tools.json` 由构建镜像时生成）。去掉的：
/// `browser_evaluate`、`browser_run_code_unsafe`（执行任意脚本）、`browser_file_upload`、`browser_drop`（往网页里放文件）、
/// `browser_emulate_media`，以及网页自己注册的工具。
pub const KEEP: &[&str] = &[
    "browser_navigate",
    "browser_navigate_back",
    "browser_snapshot",
    "browser_find",
    "browser_click",
    "browser_type",
    "browser_press_key",
    "browser_hover",
    "browser_select_option",
    "browser_fill_form",
    "browser_drag",
    "browser_wait_for",
    "browser_tabs",
    "browser_take_screenshot",
    "browser_handle_dialog",
    "browser_resize",
    "browser_close",
    "browser_console_messages",
    "browser_network_requests",
    "browser_network_request",
];

/// 结果里一段文字最多这么多字（页面快照）。
const MAX_TEXT: usize = 30_000;

const ASK_NOTE: &str =
    " Opening a website the user has not approved yet asks them first (up to 40 s).";

/// 从 `tools.json`（Playwright MCP `tools/list` 的结果，或者它的 `tools` 数组）读出要给 agent 的工具。
pub fn load(text: &str) -> Vec<Value> {
    let Ok(v) = serde_json::from_str::<Value>(text) else {
        return Vec::new();
    };
    let list = v
        .get("tools")
        .and_then(Value::as_array)
        .or_else(|| v.as_array())
        .cloned()
        .unwrap_or_default();
    list.into_iter()
        .filter(|t| t["name"].as_str().is_some_and(|n| KEEP.contains(&n)))
        .map(|mut t| {
            if matches!(
                t["name"].as_str(),
                Some("browser_navigate" | "browser_tabs")
            ) && let Some(d) = t["description"].as_str()
            {
                t["description"] = Value::from(format!("{d}.{ASK_NOTE}").replace("..", "."));
            }
            t
        })
        .collect()
}

/// 核对、改写参数：`browser_navigate` 和新开标签页的网址。
pub fn check(name: &str, args: &mut Value) -> Result<(), String> {
    let field = match name {
        "browser_navigate" => Some("url"),
        "browser_tabs" if args["action"] == "new" && args.get("url").is_some() => Some("url"),
        _ => None,
    };
    if let Some(f) = field {
        let url = args[f].as_str().unwrap_or_default();
        args[f] = Value::from(fix_url(url)?);
    }
    Ok(())
}

/// 只收 `http://`、`https://`（`http` 改成 `https`）和 `about:blank`；没写协议的当 https。
pub fn fix_url(url: &str) -> Result<String, String> {
    let u = url.trim();
    let lower = u.to_ascii_lowercase();
    if lower == "about:blank" {
        return Ok("about:blank".into());
    }
    if lower.starts_with("https://") {
        return Ok(u.to_owned());
    }
    if lower.starts_with("http://") {
        return Ok(format!("https://{}", &u[7..]));
    }
    if !u.contains("://") {
        // 没写协议的 `www.zhihu.com/q`、`a.com:8443/x` 当 https；`javascript:`、`data:`、`about:config` 这类不收。
        let head = u.split(['/', '?', '#']).next().unwrap_or_default();
        let host = match head.rsplit_once(':') {
            Some((h, p)) if p.chars().all(|c| c.is_ascii_digit()) => h,
            Some(_) => "",
            None => head,
        };
        if host.contains('.')
            && host
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-'))
        {
            return Ok(format!("https://{u}"));
        }
    }
    Err(format!(
        "only https:// web pages can be opened (got {})",
        u.chars().take(80).collect::<String>()
    ))
}

/// 这次调用里打开网页的结果写成结果的第一行：有打不开的就写最后一个打不开的，否则等过用户、用户答应了的写“approved”。
pub fn status(outcomes: &[Outcome]) -> Option<String> {
    let bad = outcomes.iter().rev().find(|o| o.result != "allowed");
    if let Some(o) = bad {
        return pages::status_line(&o.result, &o.host, o.asked);
    }
    outcomes
        .iter()
        .rev()
        .find(|o| o.asked)
        .and_then(|o| pages::status_line(&o.result, &o.host, true))
}

/// Playwright MCP 的 `tools/call` 结果 → 给 agent 的结果。
pub fn finish(result: Value, outcomes: &[Outcome]) -> ToolResult {
    let is_error = result["isError"].as_bool().unwrap_or(false);
    let mut content: Vec<Value> = result["content"].as_array().cloned().unwrap_or_default();
    for item in &mut content {
        if item["type"] == "text"
            && let Some(t) = item["text"].as_str()
            && t.chars().count() > MAX_TEXT
        {
            let cut: String = t.chars().take(MAX_TEXT).collect();
            item["text"] = Value::from(format!(
                "{cut}\n[truncated: the page is longer than {MAX_TEXT} characters; use browser_find or a smaller snapshot depth]"
            ));
        }
    }
    if let Some(line) = status(outcomes) {
        content.insert(0, json!({"type": "text", "text": line}));
    }
    ToolResult { content, is_error }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    #[test]
    fn only_listed_tools_and_the_ask_note() {
        let list = json!({"tools": [
            {"name": "browser_navigate", "description": "Navigate to a URL", "inputSchema": {}},
            {"name": "browser_run_code_unsafe", "description": "x", "inputSchema": {}},
            {"name": "browser_evaluate", "description": "x", "inputSchema": {}},
            {"name": "browser_snapshot", "description": "Capture", "inputSchema": {}},
        ]});
        let tools = load(&list.to_string());
        let names: Vec<_> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["browser_navigate", "browser_snapshot"]);
        assert!(
            tools[0]["description"]
                .as_str()
                .unwrap()
                .ends_with("(up to 40 s).")
        );
        assert!(load("not json").is_empty());
    }

    #[test]
    fn urls_are_https_only() {
        assert_eq!(fix_url("http://a.com/x").unwrap(), "https://a.com/x");
        assert_eq!(fix_url("https://a.com").unwrap(), "https://a.com");
        assert_eq!(
            fix_url("www.zhihu.com/q/1").unwrap(),
            "https://www.zhihu.com/q/1"
        );
        assert_eq!(fix_url("about:blank").unwrap(), "about:blank");
        for bad in [
            "javascript:alert(1)",
            "data:text/html,hi",
            "file:///etc/passwd",
            "chrome://settings",
            "blob:https://a.com/x",
            "view-source:https://a.com",
            "about:config",
            "",
        ] {
            assert!(fix_url(bad).is_err(), "{bad}");
        }
        let mut args = json!({"action": "new", "url": "http://b.com"});
        check("browser_tabs", &mut args).unwrap();
        assert_eq!(args["url"], "https://b.com");
        let mut args = json!({"url": "file:///x"});
        assert!(check("browser_navigate", &mut args).is_err());
    }

    #[test]
    fn the_first_line_says_what_happened() {
        let at = Instant::now();
        let o = |host: &str, result: &str, asked| Outcome {
            at,
            host: host.into(),
            result: result.into(),
            asked,
        };
        assert_eq!(status(&[]), None);
        assert!(
            status(&[o("www.zhihu.com", "allowed", true)])
                .unwrap()
                .starts_with("approved:")
        );
        assert_eq!(status(&[o("www.zhihu.com", "allowed", false)]), None);
        assert!(
            status(&[
                o("a.com", "allowed", true),
                o("www.zhihu.com", "pending", true)
            ])
            .unwrap()
            .starts_with("pending_approval:")
        );
        let r = finish(
            json!({"content": [{"type": "text", "text": "x".repeat(MAX_TEXT + 5)}]}),
            &[o("b.com", "denied", true)],
        );
        assert!(
            r.content[0]["text"]
                .as_str()
                .unwrap()
                .starts_with("user_denied:")
        );
        assert!(
            r.content[1]["text"]
                .as_str()
                .unwrap()
                .contains("[truncated")
        );
        assert!(!r.is_error);
    }
}
