//! 宽松解析列表：服务端以后加了这个版本不认识的值（运行的新来源、新状态、新种类），这一条跳过，整页照样解析，
//! 不会让老版本 App 的列表打不开。跳过的不显示，不会被当成别的（比如把新来源当成用户发的）。

use serde::Deserialize;
use serde::de::{DeserializeOwned, Deserializer};

/// 当 `#[serde(deserialize_with = "crate::lenient::vec")]` 用：解析不了的元素跳过并记日志。
pub fn vec<'de, D, T>(d: D) -> Result<Vec<T>, D::Error>
where
    D: Deserializer<'de>,
    T: DeserializeOwned,
{
    let raw = Vec::<serde_json::Value>::deserialize(d)?;
    Ok(raw.into_iter().filter_map(item).collect())
}

/// 解析一个元素，解析不了返回 None 并记日志。
pub fn item<T: DeserializeOwned>(v: serde_json::Value) -> Option<T> {
    match serde_json::from_value(v) {
        Ok(t) => Some(t),
        Err(e) => {
            tracing::warn!(error = %e, "skipping an item this version cannot read");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use proto::domain::Run;
    use serde::Deserialize;
    use serde_json::json;

    #[derive(Deserialize)]
    struct Page {
        #[serde(deserialize_with = "super::vec")]
        runs: Vec<Run>,
    }

    fn run(source: &str) -> serde_json::Value {
        json!({
            "id": "01890000-0000-7000-8000-000000000001",
            "kind": "agent",
            "instance_id": "01890000-0000-7000-8000-000000000002",
            "plan_id": null,
            "parent_run_id": null,
            "root_run_id": "01890000-0000-7000-8000-000000000001",
            "step_key": null,
            "source": source,
            "prompt": "hi",
            "state": "succeeded",
            "state_reason": null,
            "attempt": 1,
            "tokens_used": 0,
            "summary": null,
            "error": null,
            "created_at": "2026-10-29T00:00:00Z",
            "started_at": null,
            "finished_at": null
        })
    }

    #[test]
    fn unknown_values_are_skipped_not_fatal() {
        let page: Page =
            serde_json::from_value(json!({ "runs": [run("user"), run("from_the_future")] }))
                .unwrap();
        assert_eq!(page.runs.len(), 1);
        assert_eq!(page.runs[0].prompt, "hi");
        // 不是数组还是报错。
        assert!(serde_json::from_value::<Page>(json!({ "runs": 3 })).is_err());
    }
}
