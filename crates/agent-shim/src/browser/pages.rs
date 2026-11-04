//! 说明页和给 agent 的状态行（docs/browser.md 第 3.5、6 节）：打不开的网页换成一张 403 页面，agent 读快照就能看到原因；
//! 工具层在结果第一行写同样的意思。

use proto::egress::site_of;

/// 打不开的原因给 agent 看的英文（模型读英文最稳）和给人看的一行中文。
pub fn message(reason: &str, host: &str) -> (String, &'static str) {
    let site = site_of(host);
    match reason {
        "pending" | "pending_approval" => (
            format!(
                "Opening {host} needs the user's approval. They have been asked in the ThinkTin app and have not \
                 answered yet. Do other work first, then open this address again later. Do not try to reach this \
                 site another way."
            ),
            "在等用户同意。",
        ),
        "denied" | "user_denied" => (
            format!(
                "The user declined {site} for this task. Do not open it again in this task; find another way."
            ),
            "用户拒绝了这个网站。",
        ),
        "too_many_asks" | "ask_rate" => (
            "Too many sites are waiting for the user's answer. Wait for those answers or find another way.".into(),
            "在等用户回答的网站太多了。",
        ),
        "not_https" | "bad_address" => (
            "Only https:// sites on the standard port can be opened.".into(),
            "只能打开 https 网页。",
        ),
        "private_address" | "resolve" => (
            "This address cannot be reached from the sandbox (not a public site, or it does not exist).".into(),
            "这个地址打不开。",
        ),
        "quota" => (
            "Today's internet allowance is used up; it resets at midnight Beijing time.".into(),
            "今天的流量用完了。",
        ),
        "rate" => (
            "Too many pages were opened this minute. Wait a little, then open this address again.".into(),
            "这一分钟打开的网页太多了。",
        ),
        "not_allowed" => (
            "This agent may not open websites.".into(),
            "这个 agent 不能上网。",
        ),
        _ => (
            "The platform's internet service is unavailable right now.".into(),
            "平台的上网服务暂时不可用。",
        ),
    }
}

/// 换掉网页的说明页（`Fetch.fulfillRequest` 的正文）。
pub fn html(reason: &str, host: &str) -> String {
    let (en, zh) = message(reason, host);
    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>Not opened: {host}</title></head>\
         <body><h1>{reason}</h1><p>{en}</p><p>{zh}</p></body></html>",
        host = escape(host),
        reason = escape(reason),
        en = escape(&en),
    )
}

/// 工具结果的第一行。`asked`：这次调用里等过用户。
pub fn status_line(result: &str, host: &str, asked: bool) -> Option<String> {
    let site = site_of(host);
    Some(match result {
        "allowed" if asked => format!("approved: the user allowed {host} for this task."),
        "allowed" => return None,
        "pending" | "pending_approval" => format!(
            "pending_approval: opening {host} needs the user's approval. They were asked in the ThinkTin app and \
             have not answered. Do other work first and call browser_navigate with this URL again later; if it is \
             still pending, continue without this site."
        ),
        "denied" | "user_denied" => format!(
            "user_denied: the user declined {site} for this task. Do not open it again in this task; find another way."
        ),
        other => format!("{other}: {}", message(other, host).0),
    })
}

fn escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pages_and_status_lines() {
        let page = html("pending_approval", "www.zhihu.com");
        assert!(page.contains("needs the user's approval"));
        assert!(page.contains("在等用户同意"));
        assert!(html("x", "<script>").contains("&lt;script&gt;"));
        assert_eq!(status_line("allowed", "a.com", false), None);
        assert!(
            status_line("allowed", "www.zhihu.com", true)
                .unwrap()
                .starts_with("approved:")
        );
        assert!(
            status_line("denied", "www.zhihu.com", false)
                .unwrap()
                .contains("declined zhihu.com")
        );
        assert!(
            status_line("quota", "a.com", false)
                .unwrap()
                .starts_with("quota: Today's")
        );
    }
}
