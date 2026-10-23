//! 计量（架构方案 5.7，WBS 9.4）：从响应里取 usage，不记录对话内容。
//!
//! - Anthropic 协议：流式在 `message_start` 和 `message_delta` 事件里，非流式在响应体的 `usage`；
//! - Chat Completions：最后一个分片带 `usage`（有的厂商要开 `stream_options.include_usage`）；
//! - Responses：`response.completed`（或 `incomplete`、`failed`）事件里的 `response.usage`。
//!
//! 响应内容由厂商控制，可能很大：只按需取出 `usage` 等几个字段（其余字段跳过，不解析成 `Value`），
//! 超大的事件跳过、不影响后面的事件。取不到用量时由调用方按保守估算记账。

use std::borrow::Cow;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use serde_json::value::RawValue;

/// 单个 SSE 事件最多解析这么大，超过的事件照常转发、不取用量。
pub const MAX_EVENT_BYTES: usize = 8 << 20;
/// 非流式响应体最多攒这么大用来取用量，超过就当作取不到。
pub const MAX_BODY_BYTES: usize = 16 << 20;
/// `usage` 对象本身的上限。
const MAX_USAGE_BYTES: usize = 64 << 10;

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

/// 只取计量需要的几个顶层字段，其余字段跳过。
#[derive(Deserialize)]
struct Probe<'a> {
    #[serde(rename = "type", default, borrow)]
    ty: Option<Cow<'a, str>>,
    #[serde(default, borrow)]
    usage: Option<&'a RawValue>,
    #[serde(default, borrow)]
    message: Option<&'a RawValue>,
    #[serde(default, borrow)]
    response: Option<&'a RawValue>,
    #[serde(default, borrow)]
    choices: Option<&'a RawValue>,
}

/// 只取 `usage` 的嵌套对象（`message`、`response`、`choices[i]`）。
#[derive(Deserialize)]
struct UsageHolder<'a> {
    #[serde(default, borrow)]
    usage: Option<&'a RawValue>,
}

fn usage_value(raw: Option<&RawValue>) -> Option<Value> {
    let raw = raw?.get();
    if raw.len() > MAX_USAGE_BYTES || !raw.starts_with('{') {
        return None;
    }
    serde_json::from_str(raw).ok()
}

fn nested_usage(raw: Option<&RawValue>) -> Option<Value> {
    let holder: UsageHolder = serde_json::from_str(raw?.get()).ok()?;
    usage_value(holder.usage)
}

fn first_choice_usage(raw: Option<&RawValue>) -> Option<Value> {
    let choices: Vec<UsageHolder> = serde_json::from_str(raw?.get()).ok()?;
    usage_value(choices.first()?.usage)
}

fn is_empty_array(raw: Option<&RawValue>) -> bool {
    raw.is_some_and(|r| {
        r.get()
            .strip_prefix('[')
            .is_some_and(|rest| rest.trim_start().starts_with(']'))
    })
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

    /// 处理一个 SSE 事件的 data。返回 `true` 表示这是只带用量、`choices` 为空的 Chat 分片
    /// （网关替 agent 打开 `include_usage` 时厂商多发的那个）。
    pub fn on_event(&mut self, data: &[u8]) -> bool {
        let Ok(p) = serde_json::from_slice::<Probe>(data) else {
            return false;
        };
        match self.protocol {
            Protocol::Anthropic => match p.ty.as_deref() {
                Some("message_start") => {
                    if let Some(u) = nested_usage(p.message) {
                        self.merge_anthropic(&u);
                    }
                }
                Some("message_delta") => {
                    if let Some(u) = usage_value(p.usage) {
                        self.merge_anthropic(&u);
                    }
                }
                _ => {}
            },
            Protocol::Chat => {
                // 一般在顶层 `usage`；Kimi 有时放在结束分片的 `choices[0].usage` 里。
                let top = usage_value(p.usage);
                let injected = top.is_some() && is_empty_array(p.choices);
                if let Some(u) = top.or_else(|| first_choice_usage(p.choices)) {
                    self.usage = Some(openai_usage(&u, "prompt_tokens", "completion_tokens"));
                }
                return injected;
            }
            Protocol::Responses => {
                if matches!(
                    p.ty.as_deref(),
                    Some("response.completed" | "response.incomplete" | "response.failed")
                ) && let Some(u) = nested_usage(p.response)
                {
                    self.usage = Some(openai_usage(&u, "input_tokens", "output_tokens"));
                }
            }
        }
        false
    }

    /// 处理非流式响应体。
    pub fn on_body(&mut self, body: &[u8]) {
        let Ok(p) = serde_json::from_slice::<Probe>(body) else {
            return;
        };
        let Some(u) = usage_value(p.usage) else {
            return;
        };
        match self.protocol {
            Protocol::Anthropic => self.merge_anthropic(&u),
            Protocol::Chat => {
                self.usage = Some(openai_usage(&u, "prompt_tokens", "completion_tokens"))
            }
            Protocol::Responses => {
                self.usage = Some(openai_usage(&u, "input_tokens", "output_tokens"))
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

/// OpenAI 风格：输入数含缓存命中和缓存写入，单独给出这两个数。
/// 命中数：`*_details.cached_tokens`，DeepSeek 用 `prompt_cache_hit_tokens`；写入数：Kimi 的 `*_details.cache_write_tokens`。
fn openai_usage(u: &Value, input_key: &str, output_key: &str) -> Usage {
    let details = format!("{input_key}_details");
    let input = num(u, &[input_key]).unwrap_or(0);
    let cached = num(u, &[&details, "cached_tokens"])
        .or_else(|| num(u, &["prompt_cache_hit_tokens"]))
        .unwrap_or(0)
        .min(input);
    let written = num(u, &[&details, "cache_write_tokens"])
        .or_else(|| num(u, &[&details, "cache_creation_input_tokens"]))
        .unwrap_or(0)
        .min(input - cached);
    Usage {
        input_tokens: input - cached - written,
        cache_read_tokens: cached,
        cache_write_tokens: written,
        output_tokens: num(u, &[output_key]).unwrap_or(0),
    }
}

/// 增量 SSE 解析。按行切分（兼容 `\n` 和 `\r\n`），空行结束一个事件。
/// 超过上限的事件放弃解析：已缓存的原始字节和这个事件余下的字节原样交还调用方，下一个事件照常解析。
#[derive(Debug, Default)]
pub struct SseParser {
    /// 还没凑成整行的字节。
    line: Vec<u8>,
    /// 当前事件的原始字节（需要按事件过滤时才保留）。
    raw: Vec<u8>,
    data: Vec<u8>,
    has_data: bool,
    /// 正在跳过一个超大事件，等它的结束空行。
    skipping: bool,
    /// 跳过时，当前行是否已有内容（只有 `\r`、`\n` 的行是空行）。
    skip_line_has_content: bool,
    /// 跳过的超大事件数。
    pub skipped: u64,
}

#[derive(Debug)]
pub enum SsePiece {
    /// 一个完整事件。`raw` 是原始字节（包括结尾的空行，只有 `keep_raw` 时才有）；
    /// `data` 是 `data:` 行拼起来的内容，没有 data 行时为 `None`。
    Event { raw: Vec<u8>, data: Option<Vec<u8>> },
    /// 不解析、原样转发的字节（只有 `keep_raw` 时才有）。
    Pass(Vec<u8>),
}

fn has_content(bytes: &[u8]) -> bool {
    bytes.iter().any(|&b| b != b'\r' && b != b'\n')
}

fn pass(out: &mut Vec<SsePiece>, keep_raw: bool, bytes: &[u8]) {
    if !keep_raw || bytes.is_empty() {
        return;
    }
    match out.last_mut() {
        Some(SsePiece::Pass(prev)) => prev.extend_from_slice(bytes),
        _ => out.push(SsePiece::Pass(bytes.to_vec())),
    }
}

impl SseParser {
    /// 喂入一段字节，返回其中完整的事件。`keep_raw` 为真时，事件带原始字节，调用方据此决定转发哪些，
    /// 并按顺序转发 `Pass` 片段。
    pub fn push(&mut self, mut chunk: &[u8], keep_raw: bool) -> Vec<SsePiece> {
        let mut out = Vec::new();
        while !chunk.is_empty() {
            let (part, rest, complete) = match chunk.iter().position(|&b| b == b'\n') {
                Some(i) => (&chunk[..=i], &chunk[i + 1..], true),
                None => (chunk, &chunk[..0], false),
            };
            chunk = rest;

            if self.skipping {
                pass(&mut out, keep_raw, part);
                self.skip_line_has_content |= has_content(part);
                if complete {
                    if !self.skip_line_has_content {
                        self.skipping = false;
                    }
                    self.skip_line_has_content = false;
                }
                continue;
            }

            if keep_raw {
                self.raw.extend_from_slice(part);
            }
            self.line.extend_from_slice(part);
            if self.line.len() + self.data.len() > MAX_EVENT_BYTES
                || self.raw.len() > MAX_EVENT_BYTES
            {
                let raw = std::mem::take(&mut self.raw);
                pass(&mut out, keep_raw, &raw);
                // 越界的这一行肯定有内容；它要是已经完整了，就从下一行开始找空行。
                self.skip_line_has_content = !complete;
                self.skipping = true;
                self.skipped += 1;
                self.line.clear();
                self.data.clear();
                self.has_data = false;
                continue;
            }
            if !complete {
                break;
            }
            let mut line = std::mem::take(&mut self.line);
            while matches!(line.last(), Some(b'\n' | b'\r')) {
                line.pop();
            }
            if line.is_empty() {
                out.push(SsePiece::Event {
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
        out
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
    /// 厂商报告的用量（取不到为空）。
    pub usage: Option<Usage>,
    /// 记进每日预算的 token 数。厂商没报用量时按保守估算。
    pub charged_tokens: u64,
    /// `charged_tokens` 含估算部分。
    pub estimated: bool,
    pub duration_ms: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    /// 正常读完响应。
    Complete,
    /// 客户端在响应读完前断开（agent 取消或退出），包括还没等到厂商响应头就断开。
    ClientClosed,
    /// 上游连接中途出错或超时。
    UpstreamError,
    /// 连不上上游（请求没发出去）。
    ConnectFailed,
    /// 上游返回了非 2xx 状态。
    UpstreamStatus,
    /// 降级链里一把 key 都没用上，请求没发出去（都停用了、当日预算用完、解不开、地址被拦）。
    /// 执行器据此让运行转入“等待额度 / key”（7.11）。不计费。
    Unavailable,
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

    fn bytes(v: Value) -> Vec<u8> {
        serde_json::to_vec(&v).unwrap()
    }

    /// 解析并按 keep_raw 的方式重组输出，返回 (事件 data 列表, 重组后的字节)。
    fn run(p: &mut SseParser, input: &[u8], step: usize) -> (Vec<Option<String>>, Vec<u8>) {
        let mut datas = Vec::new();
        let mut out = Vec::new();
        for chunk in input.chunks(step) {
            for piece in p.push(chunk, true) {
                match piece {
                    SsePiece::Event { raw, data } => {
                        datas.push(data.map(|d| String::from_utf8(d).unwrap()));
                        out.extend(raw);
                    }
                    SsePiece::Pass(b) => out.extend(b),
                }
            }
        }
        out.extend(p.take_rest());
        (datas, out)
    }

    #[test]
    fn sse_parser_handles_any_split() {
        let input = b"event: message_start\ndata: {\"a\":1}\n\n: comment\r\ndata: x\r\ndata: y\r\n\r\ndata: [DONE]\n\n";
        for step in 1..input.len() {
            let (datas, out) = run(&mut SseParser::default(), input, step);
            assert_eq!(
                datas,
                [
                    Some("{\"a\":1}".into()),
                    Some("x\ny".into()),
                    Some("[DONE]".into())
                ],
                "step {step}"
            );
            assert_eq!(out, input, "raw bytes must round-trip at step {step}");
        }
    }

    #[test]
    fn oversized_event_is_skipped_and_parsing_resumes() {
        let big = "a".repeat(MAX_EVENT_BYTES + 10);
        let input =
            format!("data: {{\"x\":1}}\n\ndata: {big}\ndata: more\n\ndata: {{\"usage\":2}}\n\n");
        for step in [7, 4096, 1 << 20] {
            let mut p = SseParser::default();
            let (datas, out) = run(&mut p, input.as_bytes(), step);
            assert_eq!(
                datas,
                [Some("{\"x\":1}".into()), Some("{\"usage\":2}".into())],
                "step {step}"
            );
            assert_eq!(
                out,
                input.as_bytes(),
                "everything is still forwarded at step {step}"
            );
            assert_eq!(p.skipped, 1);
        }
        // 不保留原始字节时，同样能继续解析。
        let mut p = SseParser::default();
        let mut datas = Vec::new();
        for chunk in input.as_bytes().chunks(65536) {
            for piece in p.push(chunk, false) {
                if let SsePiece::Event { data, .. } = piece {
                    datas.push(data);
                }
            }
        }
        assert_eq!(datas.len(), 2);
    }

    #[test]
    fn anthropic_stream_usage() {
        let mut m = UsageMeter::new(Protocol::Anthropic);
        m.on_event(&bytes(json!({"type":"message_start","message":{"content":[],"usage":{"input_tokens":12,"cache_read_input_tokens":100,"cache_creation_input_tokens":5,"output_tokens":1}}})));
        m.on_event(&bytes(
            json!({"type":"content_block_delta","delta":{"text":"hi"}}),
        ));
        m.on_event(&bytes(
            json!({"type":"message_delta","usage":{"output_tokens":42}}),
        ));
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
        // MiniMax：message_start 的数不可信，message_delta 带全四项，以它为准。
        let mut mm = UsageMeter::new(Protocol::Anthropic);
        mm.on_event(&bytes(json!({"type":"message_start","message":{"usage":{"input_tokens":0,"cache_read_input_tokens":1365,"output_tokens":0}}})));
        mm.on_event(&bytes(json!({"type":"message_delta","usage":{"input_tokens":1251,"cache_read_input_tokens":114,"cache_creation_input_tokens":0,"output_tokens":9}})));
        assert_eq!(
            mm.usage(),
            Some(Usage {
                input_tokens: 1251,
                cache_read_tokens: 114,
                cache_write_tokens: 0,
                output_tokens: 9
            })
        );
    }

    #[test]
    fn chat_and_responses_usage() {
        let mut m = UsageMeter::new(Protocol::Chat);
        assert!(!m.on_event(&bytes(
            json!({"choices":[{"delta":{"content":"x"}}],"usage":null})
        )));
        assert_eq!(m.usage(), None);
        let last = json!({"choices":[],"usage":{"prompt_tokens":30,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":10}}});
        assert!(
            m.on_event(&bytes(last)),
            "the usage-only chunk is recognised"
        );
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
        d.on_body(&bytes(json!({"choices":[{"message":{"content":"x"}}],"usage":{"prompt_tokens":30,"completion_tokens":7,"prompt_cache_hit_tokens":25}})));
        assert_eq!(d.usage().unwrap().cache_read_tokens, 25);

        // Kimi：用量在结束分片的 choices[0].usage 里，还带缓存写入数。
        let mut k = UsageMeter::new(Protocol::Chat);
        assert!(!k.on_event(&bytes(json!({"choices":[{"delta":{},"finish_reason":"stop","usage":{"prompt_tokens":100,"completion_tokens":3,"prompt_tokens_details":{"cached_tokens":60,"cache_write_tokens":30}}}]}))));
        assert_eq!(
            k.usage(),
            Some(Usage {
                input_tokens: 10,
                cache_read_tokens: 60,
                cache_write_tokens: 30,
                output_tokens: 3
            })
        );

        let mut r = UsageMeter::new(Protocol::Responses);
        r.on_event(&bytes(
            json!({"type":"response.output_text.delta","delta":"x"}),
        ));
        r.on_event(&bytes(json!({"type":"response.completed","response":{"output":[{"type":"message"}],"usage":{"input_tokens":50,"input_tokens_details":{"cached_tokens":40},"output_tokens":9}}})));
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
        let mut m = UsageMeter::new(Protocol::Chat);
        assert!(!m.on_event(&bytes(
            json!({"choices":[{"delta":{}}],"usage":{"prompt_tokens":1}})
        )));
        assert!(!m.on_event(&bytes(json!({"choices":[],"usage":null}))));
        assert!(!m.on_event(b"[DONE]"));
    }

    #[test]
    fn hostile_payloads_do_not_break_metering() {
        let mut m = UsageMeter::new(Protocol::Chat);
        // 巨大的内容字段跳过不解析；巨大的 usage 被忽略；重复字段整个事件作废。
        let huge = json!({"choices":[{"delta":{"content":"x".repeat(1 << 20)}}],"usage":null});
        assert!(!m.on_event(&bytes(huge)));
        let fat_usage =
            json!({"choices":[],"usage":{"prompt_tokens":1,"pad":"x".repeat(MAX_USAGE_BYTES)}});
        assert!(!m.on_event(&bytes(fat_usage)));
        assert_eq!(m.usage(), None);
        assert!(!m.on_event(br#"{"usage":{"prompt_tokens":1},"usage":{"prompt_tokens":2}}"#));
        assert_eq!(m.usage(), None);
    }
}
