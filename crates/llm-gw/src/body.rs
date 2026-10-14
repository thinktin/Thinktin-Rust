//! 请求体的最小改写：只动顶层的 `model` 和 `stream_options`，其余字段按原始字节、原顺序转发。
//!
//! 网关和厂商必须对同一个请求读出同样的 `model`、`stream`：
//! - 顶层键按不区分大小写比较，重复就拒绝（Go 写的中转服务按不区分大小写匹配字段，后出现的覆盖前面的）；
//! - 网关关心的几个键必须是标准写法；
//! - 只解析这几个字段，而且先看长度，不把攻击者给的大值整个解析成 `Value`。

use std::collections::HashSet;

use serde::de::{self, MapAccess, Visitor};
use serde::ser::SerializeMap;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;
use serde_json::value::RawValue;

/// 顶层键最多这么多个（正常请求不到 50 个）。
pub const MAX_TOP_LEVEL_KEYS: usize = 256;
/// 网关会读或改的顶层键。
const SEMANTIC_KEYS: [&str; 4] = ["model", "stream", "stream_options", "background"];

/// 不区分大小写比较用的折叠形式（先转大写再转小写，覆盖 `ſ`、开尔文符号这类特殊折叠）。
fn fold(key: &str) -> String {
    key.chars()
        .flat_map(char::to_uppercase)
        .flat_map(char::to_lowercase)
        .collect()
}

/// 保留顺序的顶层 JSON 对象，值是原始 JSON 片段。
#[derive(Debug)]
pub struct JsonObject(Vec<(String, Box<RawValue>)>);

impl JsonObject {
    /// 只接受 JSON 对象；顶层出现重复键直接拒绝，免得网关和厂商对同一请求读出不同的 model。
    pub fn parse(bytes: &[u8]) -> Result<Self, String> {
        serde_json::from_slice(bytes)
            .map_err(|e| format!("request body must be a JSON object: {e}"))
    }

    pub fn get(&self, key: &str) -> Option<&RawValue> {
        self.0
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_ref())
    }

    /// 短字符串字段（比如 `model`）。
    pub fn get_str(&self, key: &str) -> Result<Option<String>, String> {
        match self.get(key) {
            None => Ok(None),
            Some(raw) if raw.get().len() > 1024 => Err(format!("`{key}` is too long")),
            Some(raw) => serde_json::from_str::<String>(raw.get())
                .map(Some)
                .map_err(|_| format!("`{key}` must be a string")),
        }
    }

    pub fn get_bool(&self, key: &str) -> Result<Option<bool>, String> {
        match self.get(key).map(RawValue::get) {
            None | Some("null") => Ok(None),
            Some("true") => Ok(Some(true)),
            Some("false") => Ok(Some(false)),
            Some(_) => Err(format!("`{key}` must be a boolean")),
        }
    }

    /// 非负整数字段（比如 `max_tokens`），不是整数就当作没有。
    pub fn get_u64(&self, key: &str) -> Option<u64> {
        self.get(key)
            .map(RawValue::get)
            .filter(|raw| raw.len() <= 20)
            .and_then(|raw| raw.parse().ok())
    }

    /// 替换已有字段（保持位置），没有就追加在末尾。
    pub fn set(&mut self, key: &str, value: &impl Serialize) {
        let raw = serde_json::value::to_raw_value(value).expect("value serializes");
        match self.0.iter_mut().find(|(k, _)| k == key) {
            Some((_, v)) => *v = raw,
            None => self.0.push((key.to_owned(), raw)),
        }
    }

    /// 流式 Chat Completions 请求打开 `stream_options.include_usage`。
    /// 返回 `true` 表示这是网关加的（agent 没要），转发响应时要去掉多出来的用量分片。
    pub fn ensure_include_usage(&mut self) -> Result<bool, String> {
        let mut options = match self.get("stream_options").map(RawValue::get) {
            None | Some("null") => serde_json::Map::new(),
            Some(raw) if raw.len() > 4096 => return Err("`stream_options` is too large".into()),
            Some(raw) => match serde_json::from_str::<Value>(raw) {
                Ok(Value::Object(map)) => map,
                _ => return Err("`stream_options` must be an object".into()),
            },
        };
        // 大小写变体（比如 `Include_Usage: false`）会让中转服务读出别的值，去掉。
        options.retain(|k, _| k == "include_usage" || fold(k) != "include_usage");
        if options.get("include_usage") == Some(&Value::Bool(true)) {
            return Ok(false);
        }
        options.insert("include_usage".into(), Value::Bool(true));
        self.set("stream_options", &options);
        Ok(true)
    }

    pub fn to_vec(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("raw values serialize")
    }
}

impl<'de> Deserialize<'de> for JsonObject {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct ObjectVisitor;

        impl<'de> Visitor<'de> for ObjectVisitor {
            type Value = JsonObject;

            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("a JSON object")
            }

            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<JsonObject, A::Error> {
                let mut entries: Vec<(String, Box<RawValue>)> = Vec::new();
                let mut seen = HashSet::new();
                while let Some(key) = map.next_key::<String>()? {
                    if entries.len() >= MAX_TOP_LEVEL_KEYS {
                        return Err(de::Error::custom("too many top-level keys"));
                    }
                    let folded = fold(&key);
                    if SEMANTIC_KEYS.contains(&folded.as_str()) && key != folded {
                        return Err(de::Error::custom(format!(
                            "`{key}` must be spelled `{folded}`"
                        )));
                    }
                    if !seen.insert(folded) {
                        return Err(de::Error::custom(format!(
                            "duplicate key `{key}` (keys are compared case-insensitively)"
                        )));
                    }
                    let value: Box<RawValue> = map.next_value()?;
                    entries.push((key, value));
                }
                Ok(JsonObject(entries))
            }
        }

        deserializer.deserialize_map(ObjectVisitor)
    }
}

impl Serialize for JsonObject {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(Some(self.0.len()))?;
        for (k, v) in &self.0 {
            map.serialize_entry(k, v)?;
        }
        map.end()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rewrites_model_and_keeps_everything_else() {
        let input = br#"{"z":1,"model":"main","messages":[{"role":"user","content":"hi \u00e9"}],"temperature":0.70,"big":12345678901234567890123}"#;
        let mut obj = JsonObject::parse(input).unwrap();
        assert_eq!(obj.get_str("model").unwrap().as_deref(), Some("main"));
        obj.set("model", &"deepseek-chat");
        let out = String::from_utf8(obj.to_vec()).unwrap();
        // 顺序、数字写法、转义都不变。
        assert_eq!(
            out,
            r#"{"z":1,"model":"deepseek-chat","messages":[{"role":"user","content":"hi \u00e9"}],"temperature":0.70,"big":12345678901234567890123}"#
        );
    }

    #[test]
    fn rejects_case_variants_and_key_floods() {
        for body in [
            r#"{"model":"a","MODEL":"b"}"#,
            r#"{"Model":"a"}"#,
            r#"{"model":"a","STREAM":true}"#,
            "{\"model\":\"a\",\"\\u017ftream\":true}", // JSON 转义的 ſ，折叠成 s
            r#"{"x":1,"X":2}"#,
        ] {
            assert!(JsonObject::parse(body.as_bytes()).is_err(), "{body}");
        }
        let many: Vec<String> = (0..=MAX_TOP_LEVEL_KEYS)
            .map(|i| format!("\"k{i}\":0"))
            .collect();
        let flood = format!("{{{}}}", many.join(","));
        assert!(
            JsonObject::parse(flood.as_bytes())
                .unwrap_err()
                .contains("too many")
        );
        // 大量键也是线性时间：上限以内很快。
        let ok: Vec<String> = (0..MAX_TOP_LEVEL_KEYS)
            .map(|i| format!("\"k{i}\":0"))
            .collect();
        assert!(JsonObject::parse(format!("{{{}}}", ok.join(",")).as_bytes()).is_ok());
    }

    #[test]
    fn scalar_checks_do_not_parse_big_values() {
        let big = format!(r#"{{"stream":[{}0]}}"#, "0,".repeat(100_000));
        assert!(
            JsonObject::parse(big.as_bytes())
                .unwrap()
                .get_bool("stream")
                .is_err()
        );
        let big = format!(r#"{{"stream_options":{{"x":"{}"}}}}"#, "a".repeat(5000));
        assert!(
            JsonObject::parse(big.as_bytes())
                .unwrap()
                .ensure_include_usage()
                .unwrap_err()
                .contains("too large")
        );
        let long = format!(r#"{{"model":"{}"}}"#, "m".repeat(2000));
        assert!(
            JsonObject::parse(long.as_bytes())
                .unwrap()
                .get_str("model")
                .is_err()
        );
        let mut v = JsonObject::parse(
            br#"{"stream_options":{"Include_Usage":false,"include_usage":false}}"#,
        )
        .unwrap();
        assert_eq!(v.ensure_include_usage(), Ok(true));
        assert_eq!(
            String::from_utf8(v.to_vec()).unwrap(),
            r#"{"stream_options":{"include_usage":true}}"#
        );
    }

    #[test]
    fn rejects_duplicates_and_non_objects() {
        assert!(
            JsonObject::parse(br#"{"model":"a","model":"b"}"#)
                .unwrap_err()
                .contains("duplicate")
        );
        assert!(JsonObject::parse(b"[1]").is_err());
        assert!(
            JsonObject::parse(b"{\"model\":1}")
                .unwrap()
                .get_str("model")
                .is_err()
        );
        assert!(JsonObject::parse(b"{} trailing").is_err());
    }

    #[test]
    fn include_usage_injection() {
        let mut a = JsonObject::parse(br#"{"model":"m","stream":true}"#).unwrap();
        assert_eq!(a.get_bool("stream"), Ok(Some(true)));
        assert_eq!(a.ensure_include_usage(), Ok(true));
        assert_eq!(
            String::from_utf8(a.to_vec()).unwrap(),
            r#"{"model":"m","stream":true,"stream_options":{"include_usage":true}}"#
        );

        let mut b = JsonObject::parse(br#"{"stream_options":{"include_usage":true}}"#).unwrap();
        assert_eq!(b.ensure_include_usage(), Ok(false));

        let mut c =
            JsonObject::parse(br#"{"stream_options":{"include_obfuscation":false}}"#).unwrap();
        assert_eq!(c.ensure_include_usage(), Ok(true));
        assert!(
            String::from_utf8(c.to_vec())
                .unwrap()
                .contains(r#""include_obfuscation":false"#)
        );

        let mut d = JsonObject::parse(br#"{"stream_options":"x"}"#).unwrap();
        assert!(d.ensure_include_usage().is_err());
    }
}
