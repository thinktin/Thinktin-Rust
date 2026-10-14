//! 计量（架构方案 5.7，WBS 9.4）：从响应里取 usage，不记录对话内容。
//!
//! - Anthropic 协议：流式在 `message_start` 和 `message_delta` 事件里，非流式在响应体的 `usage`；
//! - Chat Completions：流式要开 `stream_options.include_usage`，最后一个分片带 `usage`；
//! - Responses：`response.completed`（或 `incomplete`、`failed`）事件里的 `response.usage`。

use std::sync::Mutex;

use serde::Serialize;
use serde_json::Value;

/// 单个 SSE 事件或 JSON 响应体最多解析这么大，超过就放弃取用量（照常转发）。
pub const MAX_PARSE_BYTES: usize = 8 << 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Protocol {
    Anthropic,
    Chat,
    Responses,
}

/// 统一后的用量。`input_tokens` 不含缓存命中和缓存写入。
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Usage {
    pub input_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub output_tokens: u64,
}

impl Usage {
    pub fn total(&self) -> u64 {
        self.input_tokens
            .saturating_add(self.cache_read_tokens)
            .saturating_add(self.cache_write_tokens)
            .saturating_add(self.output_tokens)
    }
}

fn num(v: &Value, path: &[&str]) -> Option<u64> {
    let mut cur = v;
    for key in path {
        cur = cur.get(key)?;
    }
    cur.as_u64()
}

/// 边收边算用量。
#[derive(Debug)]
pub struct UsageMeter {
    protocol: Protocol,
    usage: Option<Usage>,
}

impl UsageMeter {
    pub fn new(protocol: Protocol) -> Self {
        Self {
            protocol,
            usage: None,
        }
    }

    pub fn usage(&self) -> Option<Usage> {
        self.usage
    }

    /// 处理一个 SSE 事件的 data。
    pub fn on_event(&mut self, data: &Value) {
        match self.protocol {
            Protocol::Anthropic => match data.get("type").and_then(Value::as_str) {
                Some("message_start") => {
                    if let Some(u) = data.get("message").and_then(|m| m.get("usage")) {
                        self.merge_anthropic(u);
                    }
                }
                Some("message_delta") => {
                    if let Some(u) = data.get("usage") {
                        self.merge_anthropic(u);
                    }
                }
                _ => {}
            },
            Protocol::Chat => {
                if let Some(u) = data.get("usage").filter(|u| u.is_object()) {
                    self.usage = Some(openai_usage(u, "prompt_tokens", "completion_tokens"));
                }
            }
            Protocol::Responses => {
                let ty = data.get("type").and_then(Value::as_str).unwrap_or("");
                if matches!(
                    ty,
                    "response.completed" | "response.incomplete" | "response.failed"
                ) && let Some(u) = data
                    .get("response")
                    .and_then(|r| r.get("usage"))
                    .filter(|u| u.is_object())
                {
                    self.usage = Some(openai_usage(u, "input_tokens", "output_tokens"));
                }
            }
        }
    }

    /// 处理非流式响应体。
    pub fn on_body(&mut self, body: &Value) {
        let Some(u) = body.get("usage").filter(|u| u.is_object()) else {
            return;
        };
        match self.protocol {
            Protocol::Anthropic => self.merge_anthropic(u),
            Protocol::Chat => {
                self.usage = Some(openai_usage(u, "prompt_tokens", "completion_tokens"))
            }
            Protocol::Responses => {
                self.usage = Some(openai_usage(u, "input_tokens", "output_tokens"))
            }
        }
    }

    /// `message_delta` 里的数字是累计值，出现的字段覆盖 `message_start` 的值。
    fn merge_anthropic(&mut self, u: &Value) {
        let usage = self.usage.get_or_insert_default();
        if let Some(n) = num(u, &["input_tokens"]) {
            usage.input_tokens = n;
        }
        if let Some(n) = num(u, &["cache_read_input_tokens"]) {
            usage.cache_read_tokens = n;
        }
        if let Some(n) = num(u, &["cache_creation_input_tokens"]) {
            usage.cache_write_tokens = n;
        }
        if let Some(n) = num(u, &["output_tokens"]) {
            usage.output_tokens = n;
        }
    }
}

/// OpenAI 风格：输入数含缓存命中，单独给出命中数（DeepSeek 用 `prompt_cache_hit_tokens`）。
fn openai_usage(u: &Value, input_key: &str, output_key: &str) -> Usage {
    let input = num(u, &[input_key]).unwrap_or(0);
    let cached = num(u, &[&format!("{input_key}_details"), "cached_tokens"])
        .or_else(|| num(u, &["prompt_cache_hit_tokens"]))
        .unwrap_or(0)
        .min(input);
    Usage {
        input_tokens: input - cached,
        cache_read_tokens: cached,
        cache_write_tokens: 0,
        output_tokens: num(u, &[output_key]).unwrap_or(0),
    }
}

/// 网关替 agent 补上 `include_usage` 后，厂商多发的那个分片：`choices` 为空、只带 `usage`。
/// agent 没要这个分片，转发前去掉。
pub fn is_injected_usage_chunk(data: &Value) -> bool {
    data.get("choices")
        .and_then(Value::as_array)
        .is_some_and(Vec::is_empty)
        && data.get("usage").is_some_and(Value::is_object)
}

/// 增量 SSE 解析。按行切分（兼容 `\n` 和 `\r\n`），空行结束一个事件。
#[derive(Debug, Default)]
pub struct SseParser {
    /// 还没凑成整行的字节。
    line: Vec<u8>,
    /// 当前事件的原始字节（需要按事件过滤时才保留）。
    raw: Vec<u8>,
    data: Vec<u8>,
    has_data: bool,
    /// 某个事件或行超过上限后放弃解析，之后只透传。
    pub broken: bool,
}

#[derive(Debug)]
pub struct SseEvent {
    /// 事件的原始字节，包括结尾的空行。只有 `keep_raw` 时才有。
    pub raw: Vec<u8>,
    /// `data:` 行拼起来的内容；没有 data 行时为 `None`。
    pub data: Option<Vec<u8>>,
}

impl SseParser {
    /// 喂入一段字节，返回其中完整的事件。`keep_raw` 为真时，事件带原始字节，调用方据此决定转发哪些。
    pub fn push(&mut self, mut chunk: &[u8], keep_raw: bool) -> Vec<SseEvent> {
        let mut events = Vec::new();
        if self.broken {
            return events;
        }
        while !chunk.is_empty() {
            let (part, rest, complete) = match chunk.iter().position(|&b| b == b'\n') {
                Some(i) => (&chunk[..=i], &chunk[i + 1..], true),
                None => (chunk, &chunk[..0], false),
            };
            chunk = rest;
            if keep_raw {
                self.raw.extend_from_slice(part);
            }
            self.line.extend_from_slice(part);
            if self.line.len() + self.data.len() > MAX_PARSE_BYTES
                || self.raw.len() > MAX_PARSE_BYTES
            {
                // 调用方之后用 take_rest 取回已缓存的字节，再直接透传后续数据。
                self.broken = true;
                if keep_raw {
                    self.raw.extend_from_slice(chunk);
                }
                return events;
            }
            if !complete {
                break;
            }
            let mut line = std::mem::take(&mut self.line);
            while matches!(line.last(), Some(b'\n' | b'\r')) {
                line.pop();
            }
            if line.is_empty() {
                events.push(SseEvent {
                    raw: std::mem::take(&mut self.raw),
                    data: self.has_data.then(|| std::mem::take(&mut self.data)),
                });
                self.has_data = false;
                self.data.clear();
            } else if let Some(value) = line.strip_prefix(b"data:") {
                let value = value.strip_prefix(b" ").unwrap_or(value);
                if self.has_data {
                    self.data.push(b'\n');
                }
                self.data.extend_from_slice(value);
                self.has_data = true;
            }
            // event:、id:、retry: 和注释行不影响用量，原样留在 raw 里。
        }
        events
    }

    /// 流结束时还没凑成事件的原始字节（只在 `keep_raw` 时有意义）。
    pub fn take_rest(&mut self) -> Vec<u8> {
        self.line.clear();
        std::mem::take(&mut self.raw)
    }
}

/// 一次调用的计量记录。不含请求和响应内容。
#[derive(Debug, Clone, Serialize)]
pub struct UsageRecord {
    pub ts_ms: u64,
    pub instance: String,
    pub user: String,
    pub grant: String,
    pub sandbox: String,
    pub token_id: String,
    pub alias: String,
    pub credential: String,
    pub vendor: String,
    pub upstream_model: String,
    pub endpoint: &'static str,
    pub stream: bool,
    pub status: u16,
    pub outcome: Outcome,
    pub usage: Option<Usage>,
    pub duration_ms: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    /// 正常读完响应。
    Complete,
    /// 客户端在响应读完前断开（agent 取消或退出）。
    ClientClosed,
    /// 上游连接中途出错。
    UpstreamError,
    /// 上游返回了非 2xx 状态。
    UpstreamStatus,
}

/// 计量记录的去处。生产环境写入控制面的用量表（WBS 9.10），开发环境打日志。
pub trait UsageSink: Send + Sync {
    fn record(&self, record: UsageRecord);
}

/// 以结构化日志输出，target 为 `llm_gw::usage`。
pub struct LogSink;

impl UsageSink for LogSink {
    fn record(&self, record: UsageRecord) {
        let json = serde_json::to_string(&record).unwrap_or_default();
        tracing::info!(target: "llm_gw::usage", usage = %json);
    }
}

/// 测试用。
#[derive(Default)]
pub struct MemorySink(pub Mutex<Vec<UsageRecord>>);

impl UsageSink for MemorySink {
    fn record(&self, record: UsageRecord) {
        self.0.lock().unwrap().push(record);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn parse_all(input: &[u8], step: usize) -> Vec<(Vec<u8>, Option<String>)> {
        let mut p = SseParser::default();
        let mut out = Vec::new();
        for chunk in input.chunks(step) {
            for e in p.push(chunk, true) {
                out.push((e.raw, e.data.map(|d| String::from_utf8(d).unwrap())));
            }
        }
        out
    }

    #[test]
    fn sse_parser_handles_any_split() {
        let input = b"event: message_start\ndata: {\"a\":1}\n\n: comment\r\ndata: x\r\ndata: y\r\n\r\ndata: [DONE]\n\n";
        for step in 1..input.len() {
            let events = parse_all(input, step);
            assert_eq!(events.len(), 3, "step {step}");
            assert_eq!(events[0].1.as_deref(), Some("{\"a\":1}"));
            assert_eq!(events[1].1.as_deref(), Some("x\ny"));
            assert_eq!(events[2].1.as_deref(), Some("[DONE]"));
            let raw: Vec<u8> = events.iter().flat_map(|e| e.0.clone()).collect();
            assert_eq!(raw, input, "raw bytes must round-trip at step {step}");
        }
    }

    #[test]
    fn sse_parser_gives_up_on_huge_lines() {
        let mut p = SseParser::default();
        let big = vec![b'a'; MAX_PARSE_BYTES + 1];
        assert!(p.push(&big, false).is_empty());
        assert!(p.broken);
        assert!(p.push(b"\n\ndata: 1\n\n", false).is_empty());
    }

    #[test]
    fn anthropic_stream_usage() {
        let mut m = UsageMeter::new(Protocol::Anthropic);
        m.on_event(&json!({"type":"message_start","message":{"usage":{"input_tokens":12,"cache_read_input_tokens":100,"cache_creation_input_tokens":5,"output_tokens":1}}}));
        m.on_event(&json!({"type":"content_block_delta","delta":{"text":"hi"}}));
        m.on_event(&json!({"type":"message_delta","usage":{"output_tokens":42}}));
        assert_eq!(
            m.usage(),
            Some(Usage {
                input_tokens: 12,
                cache_read_tokens: 100,
                cache_write_tokens: 5,
                output_tokens: 42
            })
        );
        assert_eq!(m.usage().unwrap().total(), 159);
    }

    #[test]
    fn chat_and_responses_usage() {
        let mut m = UsageMeter::new(Protocol::Chat);
        m.on_event(&json!({"choices":[{"delta":{"content":"x"}}],"usage":null}));
        assert_eq!(m.usage(), None);
        let last = json!({"choices":[],"usage":{"prompt_tokens":30,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":10}}});
        assert!(is_injected_usage_chunk(&last));
        m.on_event(&last);
        assert_eq!(
            m.usage(),
            Some(Usage {
                input_tokens: 20,
                cache_read_tokens: 10,
                cache_write_tokens: 0,
                output_tokens: 7
            })
        );

        let mut d = UsageMeter::new(Protocol::Chat);
        d.on_body(&json!({"usage":{"prompt_tokens":30,"completion_tokens":7,"prompt_cache_hit_tokens":25}}));
        assert_eq!(d.usage().unwrap().cache_read_tokens, 25);

        let mut r = UsageMeter::new(Protocol::Responses);
        r.on_event(&json!({"type":"response.output_text.delta","delta":"x"}));
        r.on_event(&json!({"type":"response.completed","response":{"usage":{"input_tokens":50,"input_tokens_details":{"cached_tokens":40},"output_tokens":9}}}));
        assert_eq!(
            r.usage(),
            Some(Usage {
                input_tokens: 10,
                cache_read_tokens: 40,
                cache_write_tokens: 0,
                output_tokens: 9
            })
        );
    }

    #[test]
    fn content_chunks_are_not_mistaken_for_injected_usage() {
        assert!(!is_injected_usage_chunk(
            &json!({"choices":[{"delta":{}}],"usage":{"prompt_tokens":1}})
        ));
        assert!(!is_injected_usage_chunk(
            &json!({"choices":[],"usage":null})
        ));
    }
}
