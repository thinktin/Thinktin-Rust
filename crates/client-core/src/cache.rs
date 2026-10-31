//! 本地缓存（WBS 11.4）：SQLite 里存实例、运行、事件、收件箱，没网时也能看；
//! 离线时标的已读先记下来，联网后补发。
//!
//! 缓存属于一个用户：换用户登录时整个清空（[`Cache::bind_user`]）。对象按 JSON 存，
//! 需要查询、排序的字段单独成列。

use std::path::Path;
use std::sync::Mutex;

use proto::domain::{InboxItem, InboxItemId, Instance, InstanceEvent, InstanceId, Run};
use rusqlite::{Connection, OptionalExtension, params};
use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::api::InboxPage;
use crate::error::{ClientError, Result};

/// 每个实例最多缓存多少条事件（更早的从服务端补）。
pub const MAX_EVENTS_PER_INSTANCE: i64 = 2000;
/// 收件箱最多缓存多少条。
pub const MAX_INBOX: i64 = 1000;

const SCHEMA: &str = "
PRAGMA journal_mode = WAL;
PRAGMA secure_delete = ON;
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS instances (id TEXT PRIMARY KEY, json TEXT NOT NULL, position INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS runs (
    id TEXT PRIMARY KEY, instance_id TEXT NOT NULL, json TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS runs_instance ON runs (instance_id, id);
CREATE TABLE IF NOT EXISTS cursors (instance_id TEXT PRIMARY KEY, last_seq INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS events (
    instance_id TEXT NOT NULL, seq INTEGER NOT NULL, json TEXT NOT NULL,
    PRIMARY KEY (instance_id, seq));
CREATE TABLE IF NOT EXISTS inbox (id TEXT PRIMARY KEY, json TEXT NOT NULL, read INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS pending_reads (id TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS pending_read_through (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), id TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS inbox_totals (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), unread INTEGER NOT NULL);
";

const TABLES: &[&str] = &[
    "instances",
    "runs",
    "cursors",
    "events",
    "inbox",
    "pending_reads",
    "inbox_totals",
    "pending_read_through",
];

pub struct Cache {
    conn: Mutex<Connection>,
}

fn to_json<T: Serialize>(v: &T) -> Result<String> {
    serde_json::to_string(v).map_err(|e| ClientError::Cache {
        detail: e.to_string(),
    })
}

fn from_json<T: DeserializeOwned>(s: &str) -> Result<T> {
    serde_json::from_str(s).map_err(|e| ClientError::Cache {
        detail: e.to_string(),
    })
}

impl Cache {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Self::init(Connection::open(path)?)
    }

    pub fn in_memory() -> Result<Self> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> Result<Self> {
        conn.execute_batch(SCHEMA)?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    fn with<T>(&self, f: impl FnOnce(&mut Connection) -> rusqlite::Result<T>) -> Result<T> {
        let mut conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
        Ok(f(&mut conn)?)
    }

    /// 缓存属于 `user`：之前是别的用户的就清空。
    pub fn bind_user(&self, user: &str) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            let cur: Option<String> = tx
                .query_row("SELECT value FROM meta WHERE key = 'user_id'", [], |r| {
                    r.get(0)
                })
                .optional()?;
            if cur.as_deref() != Some(user) {
                for t in TABLES {
                    tx.execute(&format!("DELETE FROM {t}"), [])?;
                }
                tx.execute(
                    "INSERT INTO meta (key, value) VALUES ('user_id', ?1) \
                     ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                    [user],
                )?;
            }
            tx.commit()
        })
    }

    /// 退出登录、注销、会话被吊销：全部清空。删掉的内容用零覆盖（secure_delete），
    /// WAL 文件里的旧页也截掉，文件里不留上一个人的数据。
    pub fn clear(&self) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            for t in TABLES.iter().chain(&["meta"]) {
                tx.execute(&format!("DELETE FROM {t}"), [])?;
            }
            tx.commit()?;
            c.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()))
        })
    }

    // ---------- 实例 ----------

    /// 用服务端的完整列表替换。
    pub fn put_instances(&self, list: &[Instance]) -> Result<()> {
        let rows = list
            .iter()
            .map(|i| Ok((i.id.to_string(), to_json(i)?)))
            .collect::<Result<Vec<_>>>()?;
        self.with(|c| {
            let tx = c.transaction()?;
            tx.execute("DELETE FROM instances", [])?;
            for (pos, (id, json)) in rows.iter().enumerate() {
                tx.execute(
                    "INSERT INTO instances (id, json, position) VALUES (?1, ?2, ?3)",
                    params![id, json, pos as i64],
                )?;
            }
            tx.commit()
        })
    }

    pub fn instances(&self) -> Result<Vec<Instance>> {
        let rows: Vec<String> = self.with(|c| {
            let mut st = c.prepare("SELECT json FROM instances ORDER BY position")?;
            st.query_map([], |r| r.get(0))?.collect()
        })?;
        rows.iter().map(|j| from_json(j)).collect()
    }

    // ---------- 运行 ----------

    pub fn put_runs(&self, runs: &[Run]) -> Result<()> {
        let rows = runs
            .iter()
            .map(|r| Ok((r.id.to_string(), r.instance_id.to_string(), to_json(r)?)))
            .collect::<Result<Vec<_>>>()?;
        self.with(|c| {
            let tx = c.transaction()?;
            for (id, instance, json) in &rows {
                tx.execute(
                    "INSERT INTO runs (id, instance_id, json) VALUES (?1, ?2, ?3) \
                     ON CONFLICT (id) DO UPDATE SET json = excluded.json",
                    params![id, instance, json],
                )?;
            }
            tx.commit()
        })
    }

    /// 新的在前（运行 id 按时间递增）。
    pub fn runs(&self, instance: InstanceId, limit: u32) -> Result<Vec<Run>> {
        let rows: Vec<String> = self.with(|c| {
            let mut st = c.prepare(
                "SELECT json FROM runs WHERE instance_id = ?1 ORDER BY id DESC LIMIT ?2",
            )?;
            st.query_map(params![instance.to_string(), limit], |r| r.get(0))?
                .collect()
        })?;
        rows.iter().map(|j| from_json(j)).collect()
    }

    // ---------- 事件（续传位置） ----------

    /// 这个实例已经收到的最后一个序号。
    pub fn cursor(&self, instance: InstanceId) -> Result<Option<u64>> {
        let v: Option<i64> = self.with(|c| {
            c.query_row(
                "SELECT last_seq FROM cursors WHERE instance_id = ?1",
                [instance.to_string()],
                |r| r.get(0),
            )
            .optional()
        })?;
        Ok(v.map(|v| v.max(0) as u64))
    }

    /// 存一批事件（重复的忽略），续传位置推进到最大的序号，超出上限的旧事件删掉。
    pub fn put_events(&self, instance: InstanceId, events: &[InstanceEvent]) -> Result<()> {
        if events.is_empty() {
            return Ok(());
        }
        let id = instance.to_string();
        let rows = events
            .iter()
            .map(|e| Ok((e.seq as i64, to_json(e)?)))
            .collect::<Result<Vec<_>>>()?;
        let max = rows.iter().map(|(s, _)| *s).max().unwrap_or(0);
        self.with(|c| {
            let tx = c.transaction()?;
            for (seq, json) in &rows {
                tx.execute(
                    "INSERT OR IGNORE INTO events (instance_id, seq, json) VALUES (?1, ?2, ?3)",
                    params![id, seq, json],
                )?;
            }
            tx.execute(
                "INSERT INTO cursors (instance_id, last_seq) VALUES (?1, ?2) \
                 ON CONFLICT (instance_id) DO UPDATE SET last_seq = max(last_seq, excluded.last_seq)",
                params![id, max],
            )?;
            tx.execute(
                "DELETE FROM events WHERE instance_id = ?1 AND seq <= \
                 (SELECT seq FROM events WHERE instance_id = ?1 ORDER BY seq DESC LIMIT 1 OFFSET ?2)",
                params![id, MAX_EVENTS_PER_INSTANCE],
            )?;
            tx.commit()
        })
    }

    /// 服务端说续传位置已经过了保留期：丢掉这个实例的事件，从 `oldest` 重新开始。
    pub fn reset_events(&self, instance: InstanceId, oldest: u64) -> Result<()> {
        let id = instance.to_string();
        self.with(|c| {
            let tx = c.transaction()?;
            tx.execute("DELETE FROM events WHERE instance_id = ?1", [&id])?;
            tx.execute(
                "INSERT INTO cursors (instance_id, last_seq) VALUES (?1, ?2) \
                 ON CONFLICT (instance_id) DO UPDATE SET last_seq = excluded.last_seq",
                params![id, oldest.saturating_sub(1) as i64],
            )?;
            tx.commit()
        })
    }

    /// `after` 之后的事件，旧的在前。
    pub fn events(
        &self,
        instance: InstanceId,
        after: u64,
        limit: u32,
    ) -> Result<Vec<InstanceEvent>> {
        let rows: Vec<String> = self.with(|c| {
            let mut st = c.prepare(
                "SELECT json FROM events WHERE instance_id = ?1 AND seq > ?2 ORDER BY seq LIMIT ?3",
            )?;
            st.query_map(params![instance.to_string(), after as i64, limit], |r| {
                r.get(0)
            })?
            .collect()
        })?;
        rows.iter().map(|j| from_json(j)).collect()
    }

    /// `before` 之前的最多 `limit` 条，旧的在前（往上翻）；`None` 是最新的 `limit` 条（打开页面时的最后一屏）。
    pub fn events_before(
        &self,
        instance: InstanceId,
        before: Option<u64>,
        limit: u32,
    ) -> Result<Vec<InstanceEvent>> {
        let before = before.map_or(i64::MAX, |b| i64::try_from(b).unwrap_or(i64::MAX));
        let rows: Vec<String> = self.with(|c| {
            let mut st = c.prepare(
                "SELECT json FROM (SELECT seq, json FROM events WHERE instance_id = ?1 AND seq < ?2 \
                 ORDER BY seq DESC LIMIT ?3) ORDER BY seq",
            )?;
            st.query_map(params![instance.to_string(), before, limit], |r| {
                r.get(0)
            })?
            .collect()
        })?;
        rows.iter().map(|j| from_json(j)).collect()
    }

    // ---------- 收件箱 ----------

    /// 合并服务端的条目。本地已标已读、还没同步上去的，保持已读。
    pub fn put_inbox(&self, items: &[InboxItem]) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            Self::write_inbox(&tx, items)?;
            tx.commit()
        })
    }

    /// 用服务端返回的一页替换它覆盖的 ID 范围；更早的缓存仍可离线翻阅。
    pub(crate) fn reconcile_inbox_page(
        &self,
        page: &mut InboxPage,
        before: Option<InboxItemId>,
        limit: u32,
    ) -> Result<()> {
        let before = before.map(|id| id.to_string());
        // 网关把页长限制在 1..=200；只有最后一页覆盖游标之后的全部条目。
        let last = page
            .items
            .last()
            .filter(|_| page.items.len() == limit.clamp(1, 200) as usize)
            .map(|item| item.id.to_string());
        self.with(|c| {
            let tx = c.transaction()?;
            tx.execute(
                "DELETE FROM inbox WHERE (?1 IS NULL OR id < ?1) AND (?2 IS NULL OR id >= ?2)",
                params![before, last],
            )?;
            Self::write_inbox(&tx, &page.items)?;
            // 请求在途时也能标已读；只覆盖返回条目的已读位，不让旧缓存替换服务端给出的成员和顺序。
            let mut pending = tx.prepare(
                "SELECT EXISTS(SELECT 1 FROM pending_reads WHERE id = ?1) OR \
                 EXISTS(SELECT 1 FROM pending_read_through WHERE id >= ?1)",
            )?;
            for item in &mut page.items {
                if !item.read {
                    item.read = pending.query_row([item.id.to_string()], |r| r.get(0))?;
                }
            }
            drop(pending);
            let local_reads: i64 = tx.query_row(
                "SELECT COUNT(*) FROM pending_reads p JOIN inbox i ON i.id=p.id WHERE json_extract(i.json, '$.read')=0",
                [], |r| r.get(0),
            )?;
            // “全部已读”仍待补发时，较早、未缓存的通知也已在本机标记。
            let pending_range: bool = tx.query_row(
                "SELECT EXISTS (SELECT 1 FROM pending_read_through)", [], |r| r.get(0),
            )?;
            page.unread = if pending_range {
                tx.query_row("SELECT COUNT(*) FROM inbox WHERE read=0", [], |r| r.get(0))?
            } else {
                (page.unread - local_reads).max(0)
            };
            tx.execute(
                "INSERT OR REPLACE INTO inbox_totals(singleton, unread) VALUES (1, ?1)",
                [page.unread],
            )?;
            tx.commit()
        })
    }

    fn write_inbox(tx: &rusqlite::Transaction<'_>, items: &[InboxItem]) -> rusqlite::Result<()> {
        for item in items {
            let json = serde_json::to_string(item)
                .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
            tx.execute(
                "INSERT INTO inbox (id, json, read) VALUES (?1, ?2, \
                   ?3 OR EXISTS (SELECT 1 FROM pending_reads WHERE id = ?1) OR \
                   EXISTS (SELECT 1 FROM pending_read_through WHERE id >= ?1)) \
                 ON CONFLICT (id) DO UPDATE SET json = excluded.json, read = excluded.read",
                params![item.id.to_string(), json, item.read],
            )?;
        }
        tx.execute(
            "DELETE FROM inbox WHERE id NOT IN (SELECT id FROM inbox ORDER BY id DESC LIMIT ?1)",
            [MAX_INBOX],
        )?;
        Ok(())
    }

    /// 服务端删掉的条目。
    pub fn remove_inbox(&self, ids: &[InboxItemId]) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            for id in ids {
                tx.execute(
                    "UPDATE inbox_totals SET unread = MAX(0, unread - 1) WHERE EXISTS \
                     (SELECT 1 FROM inbox WHERE id = ?1 AND read = 0)",
                    [id.to_string()],
                )?;
                tx.execute("DELETE FROM inbox WHERE id = ?1", [id.to_string()])?;
                tx.execute("DELETE FROM pending_reads WHERE id = ?1", [id.to_string()])?;
            }
            tx.commit()
        })
    }

    /// 新的在前；`read` 字段按本地状态。
    pub fn inbox(&self, before: Option<InboxItemId>, limit: u32) -> Result<Vec<InboxItem>> {
        let before = before.map(|b| b.to_string());
        let rows: Vec<(String, bool)> = self.with(|c| {
            let mut st = c.prepare(
                "SELECT json, read FROM inbox WHERE (?1 IS NULL OR id < ?1) ORDER BY id DESC LIMIT ?2",
            )?;
            st.query_map(params![before, limit], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect()
        })?;
        rows.iter()
            .map(|(j, read)| {
                let mut item: InboxItem = from_json(j)?;
                item.read = *read;
                Ok(item)
            })
            .collect()
    }

    pub fn unread(&self) -> Result<i64> {
        self.with(|c| Self::inbox_unread(c))
    }

    fn inbox_unread(conn: &Connection) -> rusqlite::Result<i64> {
        conn.query_row(
            "SELECT COALESCE((SELECT unread FROM inbox_totals), (SELECT COUNT(*) FROM inbox WHERE read = 0))",
            [], |r| r.get(0),
        )
    }

    /// 本地先标已读，记进待同步队列。`ids` 为空时标全部（到 `up_to` 为止）。返回本地未读数。
    pub fn mark_read_local(&self, ids: &[InboxItemId], up_to: Option<InboxItemId>) -> Result<i64> {
        let ids: Vec<String> = ids.iter().map(ToString::to_string).collect();
        let up_to = up_to.map(|u| u.to_string());
        self.with(|c| {
            let tx = c.transaction()?;
            let bulk = ids.is_empty();
            let targets: Vec<String> = if bulk {
                let mut st =
                    tx.prepare("SELECT id FROM inbox WHERE read = 0 AND (?1 IS NULL OR id <= ?1)")?;
                st.query_map([&up_to], |r| r.get(0))?
                    .collect::<rusqlite::Result<_>>()?
            } else {
                ids
            };
            let mut changed = 0;
            for id in &targets {
                changed +=
                    tx.execute("UPDATE inbox SET read = 1 WHERE id = ?1 AND read = 0", [id])?;
                tx.execute("INSERT OR IGNORE INTO pending_reads (id) VALUES (?1)", [id])?;
            }
            tx.execute(
                "UPDATE inbox_totals SET unread = MAX(0, unread - ?1)",
                [changed as i64],
            )?;
            if bulk {
                // 记下游标，联网后连同尚未缓存的较早通知一起标记。新来的通知不计在内。
                let through: Option<String> = tx.query_row(
                    "SELECT COALESCE(?1, (SELECT MAX(id) FROM inbox))", [up_to], |r| r.get(0),
                )?;
                if let Some(through) = through {
                    tx.execute(
                        "INSERT INTO pending_read_through(singleton,id) VALUES(1,?1) \
                         ON CONFLICT(singleton) DO UPDATE SET id=MAX(id,excluded.id)", [&through],
                    )?;
                    tx.execute(
                        "UPDATE inbox_totals SET unread = (SELECT COUNT(*) FROM inbox WHERE read=0) \
                         WHERE NOT EXISTS (SELECT 1 FROM inbox WHERE id > ?1)", [&through],
                    )?;
                }
            }
            let unread = Self::inbox_unread(&tx)?;
            tx.commit()?;
            Ok(unread)
        })
    }

    pub(crate) fn contains_inbox_item(&self, id: InboxItemId) -> Result<bool> {
        self.with(|c| {
            c.query_row(
                "SELECT EXISTS(SELECT 1 FROM inbox WHERE id = ?1)",
                [id.to_string()],
                |r| r.get(0),
            )
        })
    }

    /// 标回未读（服务端已经改好了）：待同步的已读也去掉。返回本地未读数。
    pub fn mark_unread_local(&self, id: InboxItemId) -> Result<i64> {
        let id = id.to_string();
        self.with(|c| {
            let tx = c.transaction()?;
            let changed = tx.execute(
                "UPDATE inbox SET read = 0 WHERE id = ?1 AND read = 1",
                [&id],
            )?;
            tx.execute(
                "UPDATE inbox_totals SET unread = unread + ?1",
                [changed as i64],
            )?;
            tx.execute("DELETE FROM pending_reads WHERE id = ?1", [&id])?;
            let unread = Self::inbox_unread(&tx)?;
            tx.commit()?;
            Ok(unread)
        })
    }

    pub(crate) fn pending_read_through(&self) -> Result<Option<InboxItemId>> {
        let value: Option<String> = self.with(|c| {
            c.query_row("SELECT id FROM pending_read_through", [], |r| r.get(0))
                .optional()
        })?;
        value
            .map(|v| {
                v.parse().map_err(|_| ClientError::Cache {
                    detail: "invalid inbox id".into(),
                })
            })
            .transpose()
    }

    /// 还没同步到服务端的已读。
    pub fn pending_reads(&self) -> Result<Vec<InboxItemId>> {
        let rows: Vec<String> = self.with(|c| {
            let mut st = c.prepare("SELECT id FROM pending_reads ORDER BY id")?;
            st.query_map([], |r| r.get(0))?.collect()
        })?;
        Ok(rows.iter().filter_map(|r| r.parse().ok()).collect())
    }

    pub fn clear_pending_reads(&self, ids: &[InboxItemId]) -> Result<()> {
        self.acknowledge_reads(ids, None, None)
    }

    pub(crate) fn acknowledge_reads(
        &self,
        ids: &[InboxItemId],
        through: Option<InboxItemId>,
        server_unread: Option<i64>,
    ) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            if let Some(id) = through {
                tx.execute(
                    "DELETE FROM pending_read_through WHERE id <= ?1",
                    [id.to_string()],
                )?;
                tx.execute("DELETE FROM pending_reads WHERE id <= ?1", [id.to_string()])?;
            }
            for id in ids {
                tx.execute("DELETE FROM pending_reads WHERE id = ?1", [id.to_string()])?;
            }
            if let Some(unread) = server_unread {
                tx.execute(
                    "INSERT OR REPLACE INTO inbox_totals(singleton, unread) \
                     SELECT 1, MAX(0, ?1 - (SELECT COUNT(*) FROM pending_reads)) \
                     WHERE NOT EXISTS (SELECT 1 FROM pending_read_through)",
                    [unread],
                )?;
            }
            tx.commit()
        })
    }
}

#[cfg(test)]
mod tests {
    use chrono::Utc;
    use proto::domain::{InboxItem, InboxItemId, InstanceEvent, InstanceId};
    use serde_json::json;

    use super::*;

    fn item(read: bool) -> InboxItem {
        InboxItem {
            id: InboxItemId::new(),
            instance_id: None,
            run_id: None,
            plan_id: None,
            approval_id: None,
            kind: "run_finished".into(),
            title: "早报".into(),
            body: "完成".into(),
            ai_generated: true,
            read,
            created_at: Utc::now(),
            subtype: None,
            vault_request_id: None,
        }
    }

    fn event(instance: InstanceId, seq: u64) -> InstanceEvent {
        InstanceEvent {
            instance_id: instance,
            seq,
            run_id: None,
            kind: "agent.message".into(),
            payload: json!({ "text": seq }),
            created_at: Utc::now(),
        }
    }

    #[test]
    fn events_advance_the_cursor_and_are_capped() {
        let c = Cache::in_memory().unwrap();
        let i = InstanceId::new();
        assert_eq!(c.cursor(i).unwrap(), None);
        c.put_events(i, &[event(i, 1), event(i, 2), event(i, 3)])
            .unwrap();
        c.put_events(i, &[event(i, 2)]).unwrap();
        assert_eq!(c.cursor(i).unwrap(), Some(3));
        let got = c.events(i, 1, 10).unwrap();
        assert_eq!(got.iter().map(|e| e.seq).collect::<Vec<_>>(), [2, 3]);
        let many: Vec<_> = (4..=2100).map(|s| event(i, s)).collect();
        c.put_events(i, &many).unwrap();
        let kept = c.events(i, 0, 5000).unwrap();
        assert_eq!(kept.len() as i64, MAX_EVENTS_PER_INSTANCE);
        assert_eq!(kept.last().unwrap().seq, 2100);
        c.reset_events(i, 5000).unwrap();
        assert_eq!(c.cursor(i).unwrap(), Some(4999));
        assert!(c.events(i, 0, 10).unwrap().is_empty());
    }

    #[test]
    fn events_read_backwards() {
        let c = Cache::in_memory().unwrap();
        let i = InstanceId::new();
        let other = InstanceId::new();
        c.put_events(i, &(1..=10).map(|s| event(i, s)).collect::<Vec<_>>())
            .unwrap();
        c.put_events(other, &[event(other, 11)]).unwrap();
        let seqs = |before, limit| {
            c.events_before(i, before, limit)
                .unwrap()
                .iter()
                .map(|e| e.seq)
                .collect::<Vec<_>>()
        };
        assert_eq!(seqs(None, 3), [8, 9, 10]);
        assert_eq!(seqs(Some(8), 3), [5, 6, 7]);
        assert_eq!(seqs(Some(2), 5), [1]);
        assert!(seqs(Some(1), 5).is_empty());
        assert_eq!(seqs(Some(u64::MAX), 3), [8, 9, 10]);
        assert!(seqs(None, 0).is_empty());
        c.reset_events(i, 20).unwrap();
        assert!(seqs(None, 5).is_empty());
        let gaps = InstanceId::new();
        c.put_events(gaps, &[event(gaps, 1), event(gaps, 5), event(gaps, 9)])
            .unwrap();
        let got: Vec<u64> = c
            .events_before(gaps, Some(9), 5)
            .unwrap()
            .iter()
            .map(|e| e.seq)
            .collect();
        assert_eq!(got, [1, 5]);
    }

    #[test]
    fn offline_reads_survive_a_sync_until_flushed() {
        let c = Cache::in_memory().unwrap();
        let a = item(false);
        let b = item(false);
        let d = item(true);
        c.put_inbox(&[a.clone(), b.clone(), d.clone()]).unwrap();
        assert_eq!(c.unread().unwrap(), 2);
        assert_eq!(c.mark_read_local(&[a.id], None).unwrap(), 1);
        // 服务端的旧数据（还没收到已读）不会把本地已读改回去。
        c.put_inbox(&[a.clone(), b.clone()]).unwrap();
        assert_eq!(c.unread().unwrap(), 1);
        assert_eq!(c.pending_reads().unwrap(), [a.id]);
        c.clear_pending_reads(&[a.id]).unwrap();
        c.put_inbox(std::slice::from_ref(&a)).unwrap();
        assert_eq!(c.unread().unwrap(), 2, "after the flush the server wins");
        // 全部已读（到某条为止）。
        assert_eq!(c.mark_read_local(&[], Some(b.id)).unwrap(), 0);
        let list = c.inbox(None, 10).unwrap();
        assert_eq!(list[0].id, d.id, "newest first");
        assert!(list.iter().all(|i| i.read));
        assert_eq!(c.inbox(Some(b.id), 10).unwrap()[0].id, a.id);
        c.remove_inbox(&[d.id]).unwrap();
        assert_eq!(c.inbox(None, 10).unwrap().len(), 2);
    }

    #[test]
    fn cache_belongs_to_one_user() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("cache.db");
        let c = Cache::open(&path).unwrap();
        c.bind_user("u1").unwrap();
        c.put_inbox(&[item(false)]).unwrap();
        drop(c);
        let c = Cache::open(&path).unwrap();
        c.bind_user("u1").unwrap();
        assert_eq!(c.unread().unwrap(), 1, "persisted across opens");
        c.bind_user("u2").unwrap();
        assert_eq!(c.unread().unwrap(), 0, "another user starts empty");
        c.put_inbox(&[item(false)]).unwrap();
        c.clear().unwrap();
        assert_eq!(c.unread().unwrap(), 0);
    }
}
