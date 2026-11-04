//! 守门（docs/browser.md 第 3.1、3.2 节）：在 CDP 根会话上让所有新页面先停住，装好拦截再放行；主页面的网页请求按
//! [`decide`] 判断，新网站经出口代理的 `POST /v1/browser/ask` 问用户；页面的其他请求只登记给转发口，不拦。

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine;
use proto::egress::{AskCause, BROWSER_ASK_WAIT_SECS, BrowserAsk, BrowserAskReply};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc;

use super::Pass;
use super::approvals::Approvals;
use super::cdp::{Cdp, Event};
use super::pages;

/// 主页面请求怎么处理。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    /// 放行。`approved`：主页面是批准过的网站（它加载的资源可以登记）；`about:blank`、`data:`、`blob:` 不算。
    Continue { approved: bool },
    /// `Fetch.failRequest`（`chrome://`、`file://` 这类，或者没批准的预渲染）。
    Block,
    /// 换成说明页。
    Explain { reason: &'static str, host: String },
    /// 去问出口代理。
    Ask { host: String },
}

/// 主页面要打开 `url`，按 docs/browser.md 第 3.2 节的表判断（第一条命中就定）。
pub fn decide(url: &str, prerender: bool, approvals: &Approvals, insecure: bool) -> Verdict {
    let lower = url.trim().to_ascii_lowercase();
    if lower == "about:blank" || lower.starts_with("data:") || lower.starts_with("blob:") {
        return Verdict::Continue { approved: false };
    }
    let Ok(parsed) = url::Url::parse(url) else {
        return Verdict::Block;
    };
    let raw_host = parsed.host_str().unwrap_or_default().to_owned();
    match parsed.scheme() {
        "https" => {}
        "http" => {
            return Verdict::Explain {
                reason: "not_https",
                host: raw_host,
            };
        }
        _ => return Verdict::Block,
    }
    let port_ok = parsed.port().is_none_or(|p| p == 443 || insecure);
    let host = match proto::egress::normalize_host(&raw_host, insecure) {
        Ok(h) if port_ok => h,
        _ => {
            return Verdict::Explain {
                reason: "bad_address",
                host: raw_host,
            };
        }
    };
    if approvals.denied(&host) {
        return Verdict::Explain {
            reason: "user_denied",
            host,
        };
    }
    if approvals.main_allowed(&host) {
        return Verdict::Continue { approved: true };
    }
    if prerender {
        return Verdict::Block;
    }
    Verdict::Ask { host }
}

/// 问出口代理（`POST /v1/browser/ask`，带浏览器通行证）。
pub struct Asker {
    /// 出口代理 `host:port`。
    pub proxy: String,
    pub pass: Pass,
}

impl Asker {
    pub async fn ask(&self, ask: &BrowserAsk) -> BrowserAskReply {
        let wait = Duration::from_secs(ask.wait_secs.unwrap_or(BROWSER_ASK_WAIT_SECS));
        match tokio::time::timeout(wait + Duration::from_secs(5), self.post(ask)).await {
            Ok(Ok(r)) => r,
            Ok(Err(e)) => {
                tracing::warn!(error = %e, "asking the egress proxy failed");
                unavailable()
            }
            Err(_) => unavailable(),
        }
    }

    async fn post(&self, ask: &BrowserAsk) -> anyhow::Result<BrowserAskReply> {
        let Some(pass) = super::pass_value(&self.pass) else {
            anyhow::bail!("no browser pass");
        };
        let body = serde_json::to_vec(ask)?;
        let mut s = tokio::net::TcpStream::connect(&self.proxy).await?;
        let mut req = format!(
            "POST /v1/browser/ask HTTP/1.1\r\nHost: {}\r\nAuthorization: Bearer {}\r\n\
             Content-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            self.proxy,
            pass.as_str(),
            body.len()
        )
        .into_bytes();
        req.extend_from_slice(&body);
        s.write_all(&req).await?;
        zeroize::Zeroize::zeroize(&mut req);
        let mut out = Vec::new();
        (&mut s).take(64 << 10).read_to_end(&mut out).await?;
        let text = String::from_utf8_lossy(&out);
        let (_, body) = text
            .split_once("\r\n\r\n")
            .ok_or_else(|| anyhow::anyhow!("no response body"))?;
        Ok(serde_json::from_str(body.trim()).unwrap_or_else(|_| unavailable()))
    }
}

fn unavailable() -> BrowserAskReply {
    BrowserAskReply {
        result: "unavailable".into(),
        scope: None,
        request_id: None,
    }
}

/// 接上的一个目标。
#[derive(Debug, Clone)]
struct Target {
    target_id: String,
    kind: Kind,
    /// 属于哪个页面（页面会话 id；页面自己就是自己）。
    page: String,
    opener: bool,
    prerender: bool,
    /// 主页面现在是批准过的网站。
    approved: bool,
    /// 换成说明页的那个网址（提交时 `frameNavigated` 报的就是它，不当成漏网）。
    explained: Option<String>,
    /// 主页面现在的网站（问用户时报“从哪个网站过来”，登记资源时记进日志）。
    site: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Page,
    Frame,
    Worker,
    Other,
}

/// 屏蔽 Service Worker 注册（它能绕开页面的拦截）。
const NO_SERVICE_WORKERS: &str = "(() => { try { if (navigator.serviceWorker) { \
navigator.serviceWorker.register = () => Promise.reject(new DOMException('service workers are disabled', \
'SecurityError')); } } catch (e) {} })();";

pub struct Gate {
    pub cdp: Arc<Cdp>,
    pub approvals: Arc<Approvals>,
    pub asker: Asker,
    /// 工具层正在执行 `browser_navigate` 或带网址的 `browser_tabs`（原因记 navigate）。
    pub navigating: Arc<AtomicBool>,
    pub insecure: bool,
    targets: Mutex<HashMap<String, Target>>,
    /// 一次打开（按 networkId）共用的 40 秒：开始的时间。
    chains: Mutex<HashMap<String, Instant>>,
}

impl Gate {
    pub fn new(
        cdp: Arc<Cdp>,
        approvals: Arc<Approvals>,
        asker: Asker,
        navigating: Arc<AtomicBool>,
        insecure: bool,
    ) -> Arc<Self> {
        Arc::new(Self {
            cdp,
            approvals,
            asker,
            navigating,
            insecure,
            targets: Mutex::default(),
            chains: Mutex::default(),
        })
    }

    fn targets(&self) -> std::sync::MutexGuard<'_, HashMap<String, Target>> {
        self.targets.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// 让所有新目标先停住、自动接上（拦截装好之前任何网页都打不开）。
    pub async fn install(&self) -> anyhow::Result<()> {
        self.cdp
            .call("Target.setDiscoverTargets", json!({"discover": true}), None)
            .await?;
        self.cdp
            .call(
                "Target.setAutoAttach",
                json!({"autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true}),
                None,
            )
            .await?;
        Ok(())
    }

    /// 处理事件，直到 pipe 断开。
    pub async fn run(self: Arc<Self>, mut events: mpsc::UnboundedReceiver<Event>) {
        while let Some(ev) = events.recv().await {
            match ev.method.as_str() {
                "Target.attachedToTarget" => {
                    let this = self.clone();
                    tokio::spawn(async move { this.on_attached(ev.session, ev.params).await });
                }
                "Target.detachedFromTarget" => {
                    if let Some(s) = ev.params["sessionId"].as_str() {
                        let removed = self.targets().remove(s);
                        if let Some(t) = removed
                            && t.kind == Kind::Page
                        {
                            self.approvals.page_closed(&t.target_id);
                        }
                    }
                }
                "Fetch.requestPaused" => {
                    if let Some(session) = ev.session {
                        let this = self.clone();
                        tokio::spawn(async move { this.on_paused(session, ev.params).await });
                    }
                }
                "Network.requestWillBeSent" => {
                    if let (Some(s), Some(url)) =
                        (&ev.session, ev.params["request"]["url"].as_str())
                        && !self.is_main_document(s, &ev.params)
                    {
                        self.on_resource(s, url);
                    }
                }
                "Network.webSocketCreated" => {
                    if let (Some(s), Some(url)) = (&ev.session, ev.params["url"].as_str()) {
                        self.on_resource(s, url);
                    }
                }
                "Page.frameNavigated" => {
                    if let Some(s) = &ev.session {
                        self.on_navigated(s, &ev.params).await;
                    }
                }
                "Inspector.targetCrashed" => {
                    tracing::warn!(session = ?ev.session, "a browser page crashed");
                }
                _ => {}
            }
        }
    }

    async fn on_attached(&self, parent: Option<String>, params: Value) {
        let Some(session) = params["sessionId"].as_str().map(str::to_owned) else {
            return;
        };
        let info = &params["targetInfo"];
        let kind = match info["type"].as_str().unwrap_or_default() {
            "page" => Kind::Page,
            "iframe" => Kind::Frame,
            "worker" | "shared_worker" | "service_worker" => Kind::Worker,
            _ => Kind::Other,
        };
        let page = match kind {
            Kind::Page => session.clone(),
            _ => parent
                .as_deref()
                .and_then(|p| self.targets().get(p).map(|t| t.page.clone()))
                .unwrap_or_default(),
        };
        self.targets().insert(
            session.clone(),
            Target {
                target_id: info["targetId"].as_str().unwrap_or_default().to_owned(),
                kind,
                page,
                opener: info["openerId"].as_str().is_some_and(|o| !o.is_empty()),
                prerender: info["subtype"].as_str() == Some("prerender"),
                approved: false,
                explained: None,
                site: None,
            },
        );
        let s = Some(session.as_str());
        let auto = json!({"autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true});
        let setup: Vec<(&str, Value)> = match kind {
            Kind::Page => vec![
                (
                    "Fetch.enable",
                    json!({"patterns": [
                        {"resourceType": "Document", "requestStage": "Request"},
                        {"resourceType": "Media", "requestStage": "Request"},
                    ]}),
                ),
                ("Network.enable", json!({})),
                ("Page.enable", json!({})),
                ("Network.setBypassServiceWorker", json!({"bypass": true})),
                (
                    "Page.addScriptToEvaluateOnNewDocument",
                    json!({"source": NO_SERVICE_WORKERS, "runImmediately": true}),
                ),
                ("Target.setAutoAttach", auto),
            ],
            Kind::Frame => vec![
                (
                    "Fetch.enable",
                    json!({"patterns": [{"resourceType": "Media", "requestStage": "Request"}]}),
                ),
                ("Network.enable", json!({})),
                ("Target.setAutoAttach", auto),
            ],
            Kind::Worker => vec![("Network.enable", json!({}))],
            Kind::Other => vec![("Target.setAutoAttach", auto)],
        };
        for (method, p) in setup {
            if let Err(e) = self.cdp.call(method, p, s).await {
                tracing::debug!(error = %e, "setting up a browser target failed");
            }
        }
        self.cdp
            .fire("Runtime.runIfWaitingForDebugger", json!({}), s);
    }

    /// 主页面自己的网页请求（打开新网站）：不能当成当前网页的资源登记，否则没批准的网站也能经转发口连出去（预连接、
    /// 说明页的图标）。它由 `Fetch.requestPaused` 按 [`decide`] 处理。
    fn is_main_document(&self, session: &str, params: &Value) -> bool {
        params["type"].as_str() == Some("Document")
            && self.targets().get(session).is_some_and(|t| {
                t.kind == Kind::Page && params["frameId"].as_str() == Some(t.target_id.as_str())
            })
    }

    /// 页面（或它的 iframe、worker）要加载 `url`：主页面是批准过的网站就登记给转发口。
    fn on_resource(&self, session: &str, url: &str) {
        let Some(host) = https_host(url) else {
            return;
        };
        let (page, page_site) = {
            let t = self.targets();
            let Some(target) = t.get(session) else {
                return;
            };
            match t.get(&target.page) {
                Some(p) if p.approved => (p.target_id.clone(), p.site.clone()),
                _ => return,
            }
        };
        if !self.approvals.announce(&page, page_site.as_deref(), &host) {
            tracing::info!(%host, "browser resource host over the limit");
        }
    }

    async fn on_paused(&self, session: String, params: Value) {
        let request_id = params["requestId"].as_str().unwrap_or_default().to_owned();
        let s = Some(session.as_str());
        let kind = params["resourceType"].as_str().unwrap_or_default();
        if kind == "Media" {
            // A 阶段不放音视频（省流量，第 11 节第 8 条）。
            self.cdp.fire(
                "Fetch.failRequest",
                json!({"requestId": request_id, "errorReason": "BlockedByClient"}),
                s,
            );
            return;
        }
        let target = self.targets().get(&session).cloned();
        let url = params["request"]["url"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let main = kind == "Document"
            && target.as_ref().is_some_and(|t| {
                t.kind == Kind::Page && params["frameId"].as_str() == Some(t.target_id.as_str())
            });
        if !main {
            // 同一进程里的 iframe 的网页：放行，登记给转发口。
            self.on_resource(&session, &url);
            self.cdp
                .fire("Fetch.continueRequest", json!({"requestId": request_id}), s);
            return;
        }
        let target = target.expect("checked above");
        let verdict = decide(&url, target.prerender, &self.approvals, self.insecure);
        match verdict {
            Verdict::Continue { approved } => {
                self.set_approved(&session, approved, None);
                if approved {
                    self.set_site(&session, https_host(&url));
                }
                self.cdp
                    .fire("Fetch.continueRequest", json!({"requestId": request_id}), s);
            }
            Verdict::Block => {
                self.cdp.fire(
                    "Fetch.failRequest",
                    json!({"requestId": request_id, "errorReason": "BlockedByClient"}),
                    s,
                );
            }
            Verdict::Explain { reason, host } => {
                self.approvals.record(&host, reason, false);
                self.explain(&session, &request_id, &url, reason, &host);
            }
            Verdict::Ask { host } => {
                let cause = if self.navigating.load(Ordering::Acquire) {
                    AskCause::Navigate
                } else if params["redirectedRequestId"].is_string() {
                    AskCause::Redirect
                } else if target.opener {
                    AskCause::Popup
                } else if params["request"]["method"].as_str() == Some("POST") {
                    AskCause::Form
                } else {
                    AskCause::Link
                };
                let wait = self.remaining(params["networkId"].as_str().unwrap_or(&request_id));
                let from = self.targets().get(&session).and_then(|t| t.site.clone());
                let reply = self
                    .asker
                    .ask(&BrowserAsk {
                        host: host.clone(),
                        url: Some(url.chars().take(300).collect()),
                        from,
                        cause,
                        wait_secs: Some(wait.as_secs()),
                    })
                    .await;
                let result = match reply.result.as_str() {
                    "allowed" => "allowed",
                    "pending" => "pending",
                    "denied" => "denied",
                    other => leak_reason(other),
                };
                self.approvals.record(&host, result, true);
                match result {
                    "allowed" => {
                        self.approvals.approve(&host, reply.scope.as_deref());
                        self.set_approved(&session, true, None);
                        self.set_site(&session, Some(host.clone()));
                        self.cdp
                            .fire("Fetch.continueRequest", json!({"requestId": request_id}), s);
                    }
                    "denied" => {
                        self.approvals.deny(&host);
                        self.explain(&session, &request_id, &url, "user_denied", &host);
                    }
                    "pending" => {
                        self.explain(&session, &request_id, &url, "pending_approval", &host)
                    }
                    other => self.explain(&session, &request_id, &url, other, &host),
                }
            }
        }
    }

    /// 这次打开还剩多少秒可以等用户（一次打开里的跳转共用 40 秒）。
    fn remaining(&self, chain: &str) -> Duration {
        let total = Duration::from_secs(BROWSER_ASK_WAIT_SECS);
        let mut c = self.chains.lock().unwrap_or_else(|e| e.into_inner());
        if c.len() > 1000 {
            c.retain(|_, at| at.elapsed() < Duration::from_secs(120));
        }
        let started = *c.entry(chain.to_owned()).or_insert_with(Instant::now);
        total.saturating_sub(started.elapsed())
    }

    fn set_site(&self, session: &str, host: Option<String>) {
        if let Some(t) = self.targets().get_mut(session) {
            t.site = host.map(|h| proto::egress::site_of(&h));
        }
    }

    fn set_approved(&self, session: &str, approved: bool, explained: Option<String>) {
        if let Some(t) = self.targets().get_mut(session) {
            t.approved = approved;
            t.explained = explained;
        }
    }

    /// 换成说明页：403，带 `X-Thinktin-Egress: <原因>`。
    fn explain(&self, session: &str, request_id: &str, url: &str, reason: &str, host: &str) {
        self.set_approved(session, false, Some(url.to_owned()));
        let body = base64::engine::general_purpose::STANDARD.encode(pages::html(reason, host));
        self.cdp.fire(
            "Fetch.fulfillRequest",
            json!({
                "requestId": request_id,
                "responseCode": 403,
                "responseHeaders": [
                    {"name": "Content-Type", "value": "text/html; charset=utf-8"},
                    {"name": "Cache-Control", "value": "no-store"},
                    {"name": "X-Thinktin-Egress", "value": reason},
                ],
                "body": body,
            }),
            Some(session),
        );
    }

    /// 补漏：主页面提交到一个没批准的网站（比如弹窗的第一个请求没停住）时，马上换成空白页。
    async fn on_navigated(&self, session: &str, params: &Value) {
        let frame = &params["frame"];
        let target = self.targets().get(session).cloned();
        let Some(target) = target else {
            return;
        };
        if target.kind != Kind::Page
            || frame["parentId"].is_string()
            || frame["id"].as_str() != Some(target.target_id.as_str())
        {
            return;
        }
        let url = frame["url"].as_str().unwrap_or_default();
        if target.explained.as_deref() == Some(url) {
            return;
        }
        let Some(host) = https_host(url).or_else(|| http_host(url)) else {
            self.set_approved(session, false, None);
            self.set_site(session, None);
            return;
        };
        if self.approvals.main_allowed(&host) && !self.approvals.denied(&host) {
            self.set_approved(session, true, None);
            self.set_site(session, Some(host));
            return;
        }
        tracing::warn!(%host, "a page committed to a site the gate did not approve; blanking it");
        self.set_approved(session, false, None);
        let _ = self
            .cdp
            .call(
                "Page.navigate",
                json!({"url": "about:blank"}),
                Some(session),
            )
            .await;
    }
}

/// 代理回的结果里认得的原因（别的一律 `unavailable`），换成 `'static` 字符串。
fn leak_reason(r: &str) -> &'static str {
    match r {
        "private_address" => "private_address",
        "resolve" => "resolve",
        "not_allowed" => "not_allowed",
        "quota" => "quota",
        "too_many_asks" => "too_many_asks",
        "ask_rate" => "ask_rate",
        "bad_address" => "bad_address",
        _ => "unavailable",
    }
}

/// `https://` 网址的网站名（整理过的）。
pub fn https_host(url: &str) -> Option<String> {
    let u = url::Url::parse(url).ok()?;
    if u.scheme() != "https" && u.scheme() != "wss" {
        return None;
    }
    u.host_str()
        .map(|h| h.trim_end_matches('.').to_ascii_lowercase())
}

fn http_host(url: &str) -> Option<String> {
    let u = url::Url::parse(url).ok()?;
    (u.scheme() == "http")
        .then(|| u.host_str().map(str::to_ascii_lowercase))
        .flatten()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn main_frame_requests_follow_the_table() {
        let a = Approvals::default();
        assert_eq!(
            decide("about:blank", false, &a, false),
            Verdict::Continue { approved: false }
        );
        assert_eq!(
            decide("data:text/html,hi", false, &a, false),
            Verdict::Continue { approved: false }
        );
        assert_eq!(
            decide("chrome://settings", false, &a, false),
            Verdict::Block
        );
        assert_eq!(
            decide("file:///etc/passwd", false, &a, false),
            Verdict::Block
        );
        assert_eq!(
            decide("view-source:https://a.com", false, &a, false),
            Verdict::Block
        );
        assert!(matches!(
            decide("http://www.zhihu.com/", false, &a, false),
            Verdict::Explain {
                reason: "not_https",
                ..
            }
        ));
        for bad in [
            "https://1.2.3.4/",
            "https://[::1]/",
            "https://localhost/",
            "https://intranet/",
            "https://www.zhihu.com:8443/",
        ] {
            assert!(
                matches!(
                    decide(bad, false, &a, false),
                    Verdict::Explain {
                        reason: "bad_address",
                        ..
                    }
                ),
                "{bad}"
            );
        }
        assert_eq!(
            decide("https://www.zhihu.com/question/1", false, &a, false),
            Verdict::Ask {
                host: "www.zhihu.com".into()
            }
        );
        // 没批准的预渲染：不问，直接不让加载。
        assert_eq!(
            decide("https://www.zhihu.com/", true, &a, false),
            Verdict::Block
        );
        a.approve("www.zhihu.com", Some("once"));
        assert_eq!(
            decide("https://zhuanlan.zhihu.com/p/1", false, &a, false),
            Verdict::Continue { approved: true }
        );
        a.deny("example.com");
        assert!(matches!(
            decide("https://www.example.com/", false, &a, false),
            Verdict::Explain {
                reason: "user_denied",
                ..
            }
        ));
        // 测试模式：本机名和别的端口也能打开（还是要问）。
        assert_eq!(
            decide("https://localhost:8443/", false, &a, true),
            Verdict::Ask {
                host: "localhost".into()
            }
        );
    }

    #[test]
    fn hosts_of_urls() {
        assert_eq!(
            https_host("https://WWW.Zhihu.com./a").as_deref(),
            Some("www.zhihu.com")
        );
        assert_eq!(
            https_host("wss://push.example.com/ws").as_deref(),
            Some("push.example.com")
        );
        assert_eq!(https_host("http://a.com/"), None);
        assert_eq!(https_host("data:x"), None);
    }
}
