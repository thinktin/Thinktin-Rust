//! 这次任务里浏览器的“通行记录”（docs/browser.md 第 3.2、4.2 节）：守门批准过、拒绝过的网站，批准过的网页登记的资源网站，
//! 和每次问询的结果（工具层据此在结果第一行告诉 agent）。守门、转发口、工具层共用一份；每个任务开始和结束时清空。

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use proto::egress::{BROWSER_HOSTS_PER_PAGE, BROWSER_HOSTS_PER_RUN, site_of};
use tokio::sync::Notify;

/// 资源网站登记后多久内转发口放行。
pub const ANNOUNCE_TTL: Duration = Duration::from_secs(300);

/// 转发口为什么放行一个网站。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Grant {
    /// 批准过的主页面网站。
    Main,
    /// 批准过的网页登记过的资源；`page` 是那个网页的网站（只进日志）。
    Resource { page: Option<String> },
}

/// 一次打开网页的结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outcome {
    pub at: Instant,
    pub host: String,
    /// `allowed`、`pending`、`denied`，或者打不开的原因（`not_https`、`private_address` 等）。
    pub result: String,
    /// 问过用户（等过）。
    pub asked: bool,
}

#[derive(Default)]
struct Inner {
    /// 搜索、开发网站：只认完整网址。
    hosts: HashSet<String>,
    /// 访问一次、一直允许：整个网站（主域名）。
    sites: HashSet<String>,
    /// 这次任务拒绝过的网站。
    denied: HashSet<String>,
    /// 批准过的网页登记的资源网站：最近一次登记的时间、是哪个网站的网页。
    resources: HashMap<String, (Instant, Option<String>)>,
    /// 每个页面登记过哪些资源网站。
    per_page: HashMap<String, HashSet<String>>,
    outcomes: Vec<Outcome>,
    /// 正在问代理（等用户）的：编号 → (开始的时间, 网站)。
    asking: HashMap<u64, (Instant, String)>,
    next_ask: u64,
}

#[derive(Default)]
pub struct Approvals {
    inner: Mutex<Inner>,
    announced: Notify,
    /// 有一次问询结束了。
    ask_done: Notify,
}

/// 一次在进行的问询；放下时（问完了、或者任务被中止）登记结束。
pub struct Asking<'a> {
    approvals: &'a Approvals,
    id: u64,
}

impl Drop for Asking<'_> {
    fn drop(&mut self) {
        self.approvals.lock().asking.remove(&self.id);
        self.approvals.ask_done.notify_waiters();
    }
}

impl Approvals {
    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// 任务开始、结束：全部清掉（在进行的问询照样登记着，问完自己去掉）。
    pub fn clear(&self) {
        let mut i = self.lock();
        let asking = std::mem::take(&mut i.asking);
        let next_ask = i.next_ask;
        *i = Inner {
            asking,
            next_ask,
            ..Inner::default()
        };
    }

    /// 开始问代理 `host`（问完放下返回值）。
    pub fn asking(&self, host: &str) -> Asking<'_> {
        let mut i = self.lock();
        i.next_ask += 1;
        let id = i.next_ask;
        i.asking.insert(id, (Instant::now(), host.to_owned()));
        Asking {
            approvals: self,
            id,
        }
    }

    /// `since` 以后开始、还没问完的网站。
    pub fn asking_since(&self, since: Instant) -> Vec<String> {
        self.lock()
            .asking
            .values()
            .filter(|(at, _)| *at >= since)
            .map(|(_, h)| h.clone())
            .collect()
    }

    /// 等 `since` 以后开始的问询都问完，最多等到 `deadline`（点了链接、问询比工具调用晚结束时，结果还能算进这次调用）。
    pub async fn wait_asks(&self, since: Instant, deadline: tokio::time::Instant) {
        loop {
            let done = self.ask_done.notified();
            tokio::pin!(done);
            done.as_mut().enable();
            if self.asking_since(since).is_empty() {
                return;
            }
            if tokio::time::timeout_at(deadline, done).await.is_err() {
                return;
            }
        }
    }

    /// 打开 `host` 的网页不用再问吗。
    pub fn main_allowed(&self, host: &str) -> bool {
        let i = self.lock();
        i.hosts.contains(host) || i.sites.contains(&site_of(host))
    }

    pub fn denied(&self, host: &str) -> bool {
        self.lock().denied.contains(&site_of(host))
    }

    /// 代理答应了：`scope` 是 `default` 时只记完整网址，否则记整个网站。
    pub fn approve(&self, host: &str, scope: Option<&str>) {
        let mut i = self.lock();
        if scope == Some("default") {
            i.hosts.insert(host.to_owned());
        } else {
            let site = site_of(host);
            i.denied.remove(&site);
            i.sites.insert(site);
        }
        drop(i);
        self.announced.notify_waiters();
    }

    pub fn deny(&self, host: &str) {
        let site = site_of(host);
        let mut i = self.lock();
        i.sites.remove(&site);
        i.denied.insert(site);
    }

    /// 批准过的网页 `page`（页面的 targetId，网站是 `page_site`）要加载 `host` 上的东西。超过每页、每次任务的上限时
    /// 不登记，返回 false。
    pub fn announce(&self, page: &str, page_site: Option<&str>, host: &str) -> bool {
        let mut i = self.lock();
        let known = i.resources.contains_key(host);
        if !known && i.resources.len() >= BROWSER_HOSTS_PER_RUN {
            return false;
        }
        let set = i.per_page.entry(page.to_owned()).or_default();
        if !set.contains(host) && set.len() >= BROWSER_HOSTS_PER_PAGE {
            return false;
        }
        set.insert(host.to_owned());
        i.resources.insert(
            host.to_owned(),
            (Instant::now(), page_site.map(str::to_owned)),
        );
        drop(i);
        self.announced.notify_waiters();
        true
    }

    /// 页面关了：它的每页计数不再占。
    pub fn page_closed(&self, page: &str) {
        self.lock().per_page.remove(page);
    }

    /// 最近 [`ANNOUNCE_TTL`] 内有批准过的网页登记过 `host` 吗：有的话是哪个网站的网页。
    pub fn resource(&self, host: &str) -> Option<Option<String>> {
        self.lock()
            .resources
            .get(host)
            .filter(|(at, _)| at.elapsed() < ANNOUNCE_TTL)
            .map(|(_, page)| page.clone())
    }

    #[cfg(test)]
    pub fn resource_allowed(&self, host: &str) -> bool {
        self.resource(host).is_some()
    }

    /// 转发口用：`host` 现在能连吗（批准过的主页面网站，或者登记过的资源）。不能的话最多等 `wait` 看有没有登记。
    pub async fn wait_allowed(&self, host: &str, wait: Duration) -> Option<Grant> {
        let deadline = tokio::time::Instant::now() + wait;
        loop {
            let notified = self.announced.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.denied(host) {
                return None;
            }
            if self.main_allowed(host) {
                return Some(Grant::Main);
            }
            if let Some(page) = self.resource(host) {
                return Some(Grant::Resource { page });
            }
            if tokio::time::timeout_at(deadline, notified).await.is_err() {
                return None;
            }
        }
    }

    pub fn record(&self, host: &str, result: &str, asked: bool) {
        let mut i = self.lock();
        if i.outcomes.len() >= 1000 {
            i.outcomes.drain(..500);
        }
        i.outcomes.push(Outcome {
            at: Instant::now(),
            host: host.to_owned(),
            result: result.to_owned(),
            asked,
        });
    }

    /// `since` 以后的结果（工具层看这次调用里发生了什么）。
    pub fn outcomes_since(&self, since: Instant) -> Vec<Outcome> {
        self.lock()
            .outcomes
            .iter()
            .filter(|o| o.at >= since)
            .cloned()
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scopes_sites_and_resources() {
        let a = Approvals::default();
        a.approve("github.com", Some("default"));
        assert!(a.main_allowed("github.com"));
        assert!(
            !a.main_allowed("gist.github.com"),
            "default scope is the exact host"
        );
        a.approve("www.zhihu.com", Some("once"));
        assert!(
            a.main_allowed("zhuanlan.zhihu.com"),
            "once covers the whole site"
        );
        a.deny("news.example.co.uk");
        assert!(a.denied("www.example.co.uk"));
        assert!(!a.main_allowed("www.example.co.uk"));
        assert!(a.announce("page-1", Some("zhihu.com"), "static.zhimg.com"));
        assert_eq!(
            a.resource("static.zhimg.com"),
            Some(Some("zhihu.com".into()))
        );
        assert!(a.resource_allowed("static.zhimg.com"));
        assert!(!a.resource_allowed("cdn.other.com"));
        a.clear();
        assert!(!a.main_allowed("www.zhihu.com"));
        assert!(!a.resource_allowed("static.zhimg.com"));
    }

    #[test]
    fn resource_hosts_are_capped_per_page() {
        let a = Approvals::default();
        for i in 0..BROWSER_HOSTS_PER_PAGE {
            assert!(a.announce("p", None, &format!("h{i}.example.com")));
        }
        assert!(!a.announce("p", None, "one-more.example.com"));
        // 已经登记过的照样续。
        assert!(a.announce("p", None, "h0.example.com"));
        // 别的页面另算。
        assert!(a.announce("q", None, "one-more.example.com"));
    }

    #[tokio::test]
    async fn calls_wait_for_asks_that_started_during_them() {
        let a = std::sync::Arc::new(Approvals::default());
        let before = Instant::now();
        let guard = a.asking("www.zhihu.com");
        assert_eq!(a.asking_since(before), ["www.zhihu.com"]);
        let deadline = tokio::time::Instant::now() + Duration::from_millis(30);
        a.wait_asks(before, deadline).await;
        assert_eq!(a.asking_since(before).len(), 1, "gave up at the deadline");
        let b = a.clone();
        let waiter = tokio::spawn(async move {
            b.wait_asks(before, tokio::time::Instant::now() + Duration::from_secs(5))
                .await
        });
        tokio::time::sleep(Duration::from_millis(20)).await;
        a.record("www.zhihu.com", "pending", true);
        drop(guard);
        waiter.await.unwrap();
        assert!(a.asking_since(before).is_empty());
        // 调用开始之前就在问的不算这次调用的。
        let _old = a.asking("old.example.com");
        assert!(a.asking_since(Instant::now()).is_empty());
    }

    #[tokio::test]
    async fn the_forward_port_waits_briefly_for_an_announcement() {
        let a = std::sync::Arc::new(Approvals::default());
        assert_eq!(
            a.wait_allowed("late.example.com", Duration::from_millis(20))
                .await,
            None
        );
        let b = a.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(30)).await;
            b.announce("p", Some("news.com"), "late.example.com");
        });
        assert_eq!(
            a.wait_allowed("late.example.com", Duration::from_secs(2))
                .await,
            Some(Grant::Resource {
                page: Some("news.com".into())
            })
        );
        a.approve("www.example.com", Some("once"));
        assert_eq!(
            a.wait_allowed("example.com", Duration::ZERO).await,
            Some(Grant::Main)
        );
    }
}
