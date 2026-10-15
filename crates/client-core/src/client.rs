//! 客户端门面：接口 + 缓存。读接口的结果顺手写进缓存；离线时标的已读先记在本地，联网后补发。

use std::sync::Arc;

use proto::domain::{InboxItem, InboxItemId, Instance, InstanceEvent, InstanceId, Run, User};

use crate::api::{Api, InboxPage, LoginResult};
use crate::cache::Cache;
use crate::error::{ClientError, Result};
use crate::events::{self, EventSink, StreamConfig, StreamHandle};

pub struct Client {
    pub api: Arc<Api>,
    cache: Option<Arc<Cache>>,
}

impl Client {
    /// `cache` 为空时不缓存（测试、命令行工具）。已经登录的话缓存绑定到当前用户。
    pub fn new(api: Api, cache: Option<Cache>) -> Result<Self> {
        let api = Arc::new(api);
        let cache = cache.map(Arc::new);
        if let (Some(c), Some(s)) = (&cache, api.session()) {
            c.bind_user(&s.user_id)?;
        }
        // 会话没了（远程下线、被吊销、退出）：不管是从哪个接口、事件流发现的，都清掉本地缓存。
        if let Some(c) = &cache {
            let c = c.clone();
            api.on_signed_out(move || {
                let _ = c.clear();
            });
        }
        Ok(Self { api, cache })
    }

    /// 读缓存前先看还登录着没有：没登录就什么都不给（缓存里可能还是上一个人的）。
    fn signed_in_cache(&self) -> Option<&Cache> {
        self.api.session()?;
        self.cache.as_deref()
    }

    pub fn cache(&self) -> Option<&Cache> {
        self.cache.as_deref()
    }

    pub async fn login(
        &self,
        phone: &str,
        code: &str,
        push: Option<(proto::domain::PushChannelKind, String)>,
    ) -> Result<LoginResult> {
        let r = self.api.login(phone, code, push).await?;
        if let Some(c) = &self.cache {
            c.bind_user(&r.user.id.to_string())?;
        }
        Ok(r)
    }

    /// 退出登录：服务端下线本设备，本地会话和缓存都清掉。
    pub async fn logout(&self) -> Result<()> {
        let r = self.api.logout().await;
        if let Some(c) = &self.cache {
            c.clear()?;
        }
        r
    }

    pub async fn me(&self) -> Result<User> {
        self.signed_out_clears(self.api.me().await)
    }

    /// 登录失效时顺手清掉缓存（换人登录前不留上一个人的数据）。
    fn signed_out_clears<T>(&self, r: Result<T>) -> Result<T> {
        if matches!(r, Err(ClientError::SignedOut))
            && let Some(c) = &self.cache
        {
            let _ = c.clear();
        }
        r
    }

    // ---------- 实例、运行 ----------

    pub async fn instances(&self) -> Result<Vec<Instance>> {
        let list = self.signed_out_clears(self.api.instances().await)?;
        if let Some(c) = &self.cache {
            c.put_instances(&list)?;
        }
        Ok(list)
    }

    pub fn cached_instances(&self) -> Result<Vec<Instance>> {
        match self.signed_in_cache() {
            Some(c) => c.instances(),
            None => Ok(Vec::new()),
        }
    }

    pub async fn runs(&self, instance: InstanceId, limit: u32) -> Result<Vec<Run>> {
        let runs = self.signed_out_clears(self.api.runs(instance, None, limit).await)?;
        if let Some(c) = &self.cache {
            c.put_runs(&runs)?;
        }
        Ok(runs)
    }

    pub fn cached_runs(&self, instance: InstanceId, limit: u32) -> Result<Vec<Run>> {
        match self.signed_in_cache() {
            Some(c) => c.runs(instance, limit),
            None => Ok(Vec::new()),
        }
    }

    // ---------- 事件 ----------

    /// 开始收实例的事件（续传位置取缓存里的）。
    pub fn subscribe(
        &self,
        rt: &tokio::runtime::Handle,
        instance: InstanceId,
        sink: Arc<dyn EventSink>,
        cfg: StreamConfig,
    ) -> StreamHandle {
        events::spawn(
            rt,
            self.api.clone(),
            self.cache.clone(),
            instance,
            None,
            sink,
            cfg,
        )
    }

    pub fn cached_events(
        &self,
        instance: InstanceId,
        after: u64,
        limit: u32,
    ) -> Result<Vec<InstanceEvent>> {
        match self.signed_in_cache() {
            Some(c) => c.events(instance, after, limit),
            None => Ok(Vec::new()),
        }
    }

    // ---------- 收件箱 ----------

    /// 先把离线时标的已读补发，再拉最新一页并合并进缓存。返回服务端的这一页（已读状态以本地为准）。
    pub async fn sync_inbox(&self, limit: u32) -> Result<InboxPage> {
        self.flush_reads().await?;
        let mut page = self.signed_out_clears(self.api.inbox(None, limit, false).await)?;
        if let Some(c) = &self.cache {
            c.put_inbox(&page.items)?;
            page.items = c.inbox(None, limit)?;
            page.unread = c.unread()?;
        }
        Ok(page)
    }

    /// 更早的一页（直接问服务端，也写进缓存）。
    pub async fn older_inbox(&self, before: InboxItemId, limit: u32) -> Result<Vec<InboxItem>> {
        let page = self.signed_out_clears(self.api.inbox(Some(before), limit, false).await)?;
        if let Some(c) = &self.cache {
            c.put_inbox(&page.items)?;
        }
        Ok(page.items)
    }

    pub fn cached_inbox(&self, before: Option<InboxItemId>, limit: u32) -> Result<Vec<InboxItem>> {
        match self.signed_in_cache() {
            Some(c) => c.inbox(before, limit),
            None => Ok(Vec::new()),
        }
    }

    pub fn cached_unread(&self) -> Result<i64> {
        match self.signed_in_cache() {
            Some(c) => c.unread(),
            None => Ok(0),
        }
    }

    /// 标已读：本地立即生效；联网就同步，没网先记下来（下次 [`Self::sync_inbox`] 时补发）。
    /// `ids` 为空表示全部已读（到 `up_to` 为止）。返回未读数。
    pub async fn mark_inbox_read(
        &self,
        ids: &[InboxItemId],
        up_to: Option<InboxItemId>,
    ) -> Result<i64> {
        let Some(c) = &self.cache else {
            let ids = (!ids.is_empty()).then_some(ids);
            return self.api.mark_inbox_read(ids, up_to).await;
        };
        let local = c.mark_read_local(ids, up_to)?;
        match self.flush_reads().await {
            Ok(()) => Ok(local),
            Err(e) if e.retryable() => Ok(local),
            Err(e) => Err(e),
        }
    }

    /// 补发离线时标的已读。
    pub async fn flush_reads(&self) -> Result<()> {
        let Some(c) = &self.cache else {
            return Ok(());
        };
        let pending = c.pending_reads()?;
        for chunk in pending.chunks(500) {
            match self.api.mark_inbox_read(Some(chunk), None).await {
                Ok(_) => c.clear_pending_reads(chunk)?,
                Err(e) => return self.signed_out_clears(Err(e)),
            }
        }
        Ok(())
    }
}
