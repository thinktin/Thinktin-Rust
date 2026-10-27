//! 输入里的密码拦截（WBS 11.6）：用户在对话框里发像密码、key 的内容时，App 发送前调 [`detect`]，
//! 有命中就拦下，提示“对话里不收明文密码”，弹表单（值已预填，可改）存进保险箱，再用 [`redact`]
//! 把消息里的值换成引用 `[vault:名字]`，和运行日志、模型网关抹值后的写法一致，agent 照常按名字用。
//!
//! 只在本机识别，不联网。宁可漏也不乱拦：只认
//!
//! - 带私钥的 PEM 块；
//! - 已知格式的 key（`sk-ant-`、`ghp_`、`AKIA`……）和 JWT；
//! - 网址里的密码（`postgres://user:密码@host`）；
//! - 跟在“密码”“password”“api key”“token”……后面的值（`密码是 Abc123`、`DB_PASSWORD=...`）；
//! - 足够长、大小写字母和数字都有的随机串（像 key）。
//!
//! 引用、占位符（`[vault:github]`、`${TOKEN}`、`<password>`、`****`）不算。
//! 位置都是 UTF-8 字节下标（给原生端的在 `ffi` 里换算成 UTF-16）。

use std::fmt;

/// 命中的是哪一类。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SecretKind {
    /// PEM 私钥块（多行，存不进保险箱，只能提示别发）。
    PrivateKey,
    /// 网址里的密码。
    UrlPassword,
    /// 已知格式的 key。
    ApiKey,
    /// JWT 之类的令牌。
    Token,
    /// 跟在“密码”“password”之类后面的值。
    Labeled,
    /// 像 key 的随机串。
    HighEntropy,
}

impl SecretKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::PrivateKey => "private_key",
            Self::UrlPassword => "url_password",
            Self::ApiKey => "api_key",
            Self::Token => "token",
            Self::Labeled => "labeled",
            Self::HighEntropy => "high_entropy",
        }
    }

    /// 范围重叠时谁优先（小的优先）。
    fn rank(self) -> u8 {
        match self {
            Self::PrivateKey => 0,
            Self::UrlPassword => 1,
            Self::ApiKey => 2,
            Self::Token => 3,
            Self::Labeled => 4,
            Self::HighEntropy => 5,
        }
    }
}

/// 一处命中。
#[derive(Clone, PartialEq, Eq)]
pub struct Found {
    pub kind: SecretKind,
    /// 原文里的字节范围 `start..end`，`&text[start..end] == value`。
    pub start: usize,
    pub end: usize,
    pub value: String,
    /// 建议的保险箱条目名（符合条目名规则），比如 `github`、`db_password`。
    pub suggested_name: String,
    /// 认出来的厂商或服务（`anthropic`、`github`……），认不出是空。
    pub service: String,
    /// 能直接存进保险箱：单行、4 个字符到 4096 字节。
    pub storable: bool,
}

impl fmt::Debug for Found {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Found")
            .field("kind", &self.kind)
            .field("start", &self.start)
            .field("end", &self.end)
            .field("suggested_name", &self.suggested_name)
            .field("service", &self.service)
            .field("storable", &self.storable)
            .finish_non_exhaustive()
    }
}

/// 和服务端保险箱的规则一致（`proto::domain::valid_vault_name`、密码长度）。
const MIN_LEN: usize = 4;
const MAX_LEN: usize = 4096;
const MAX_NAME: usize = 64;

/// 消息里的引用写法，和抹值后的写法一致。
pub fn reference(name: &str) -> String {
    format!("[vault:{name}]")
}

/// 找出文本里像密码、key 的内容，按位置排序，互不重叠。
pub fn detect(text: &str) -> Vec<Found> {
    let mut all = Vec::new();
    let blocks = private_keys(text);
    for &(s, e) in &blocks {
        all.push(found(text, SecretKind::PrivateKey, s, e, "private_key", ""));
    }
    for (s, e) in ascii_words(text) {
        if blocks.iter().any(|&(bs, be)| s < be && bs < e) {
            continue;
        }
        classify_word(text, s, e, &mut all);
    }
    labeled(text, &mut all);
    all.retain(|f| !f.value.is_empty() && !is_placeholder(&f.value));
    // 靠前的优先；同一起点取更长的、更具体的。
    all.sort_by_key(|f| (f.start, std::cmp::Reverse(f.end), f.kind.rank()));
    let mut out: Vec<Found> = Vec::new();
    for f in all {
        match out.last_mut() {
            Some(last) if f.start < last.end => {
                // 同一段值，更具体的类别覆盖（比如“api key: sk-ant-...”）。
                if f.start == last.start && f.end == last.end && f.kind.rank() < last.kind.rank() {
                    *last = f;
                }
            }
            _ => out.push(f),
        }
    }
    out
}

/// 把消息里出现的每个值（所有出现的地方）换成 `[vault:名字]`。`pairs` 是 `(值, 条目名)`；
/// 长的值先换，免得一个值是另一个的一部分时只换掉一半。
pub fn redact(text: &str, pairs: &[(String, String)]) -> String {
    let mut pairs: Vec<&(String, String)> = pairs.iter().filter(|(v, _)| !v.is_empty()).collect();
    pairs.sort_by_key(|(v, _)| std::cmp::Reverse(v.len()));
    let mut out = text.to_owned();
    for (value, name) in pairs {
        out = out.replace(value.as_str(), &reference(name));
    }
    out
}

/// 把任意文字变成合法的条目名：小写，非法字符换成 `_`，去掉开头的 `_`、`-`，最长 64；空了用 `fallback`。
pub fn sanitize_name(raw: &str, fallback: &str) -> String {
    let mut s: String = raw
        .chars()
        .map(|c| {
            let c = c.to_ascii_lowercase();
            if c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect();
    while s.contains("__") {
        s = s.replace("__", "_");
    }
    let s = s.trim_matches(|c| c == '_' || c == '-');
    let s: String = s.chars().take(MAX_NAME).collect();
    let s = s.trim_end_matches(['_', '-']);
    if s.is_empty() {
        fallback.to_owned()
    } else {
        s.to_owned()
    }
}

/// 名字已经有了就加 `_2`、`_3`……
pub fn unique_name(base: &str, taken: &[String]) -> String {
    if !taken.iter().any(|t| t == base) {
        return base.to_owned();
    }
    (2..)
        .map(|n| {
            let suffix = format!("_{n}");
            let head: String = base.chars().take(MAX_NAME - suffix.len()).collect();
            format!("{head}{suffix}")
        })
        .find(|c| !taken.iter().any(|t| t == c))
        .expect("unbounded")
}

fn found(text: &str, kind: SecretKind, s: usize, e: usize, name: &str, service: &str) -> Found {
    let value = &text[s..e];
    let chars = value.chars().count();
    Found {
        kind,
        start: s,
        end: e,
        value: value.to_owned(),
        suggested_name: sanitize_name(name, "secret"),
        service: service.to_owned(),
        storable: chars >= MIN_LEN
            && value.len() <= MAX_LEN
            && !value.chars().any(char::is_control),
    }
}

// ---------- 私钥块 ----------

fn private_keys(text: &str) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut from = 0;
    while let Some(i) = text[from..].find("-----BEGIN ") {
        let s = from + i;
        let header_end = match text[s + 11..].find("-----") {
            Some(j) => s + 11 + j + 5,
            None => break,
        };
        let header = &text[s..header_end];
        if !header.contains("PRIVATE KEY") || header.contains('\n') {
            from = header_end;
            continue;
        }
        // 到 END 行结束；没有 END（只贴了一半）就到文本末尾。
        let e = match text[header_end..].find("-----END ") {
            Some(j) => {
                let end_start = header_end + j + 9;
                match text[end_start..].find("-----") {
                    Some(k) => end_start + k + 5,
                    None => text.len(),
                }
            }
            None => text.len(),
        };
        out.push((s, e));
        from = e;
    }
    out
}

// ---------- 单个词：已知格式的 key、JWT、网址里的密码、随机串 ----------

/// 连续的可见 ASCII 字符（中文、空白把它们隔开）。
fn ascii_words(text: &str) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut start = None;
    for (i, b) in text.bytes().enumerate() {
        let graphic = b.is_ascii_graphic();
        match (graphic, start) {
            (true, None) => start = Some(i),
            (false, Some(s)) => {
                out.push((s, i));
                start = None;
            }
            _ => {}
        }
    }
    if let Some(s) = start {
        out.push((s, text.len()));
    }
    out
}

const OPEN: &[u8] = b"\"'`([{<";
const CLOSE: &[u8] = b"\"'`)]}>,;.:!?";

/// 去掉包在两头的引号、括号和句末标点。
fn trim_word(text: &str, mut s: usize, mut e: usize) -> (usize, usize) {
    let b = text.as_bytes();
    while s < e && OPEN.contains(&b[s]) {
        s += 1;
    }
    while e > s && CLOSE.contains(&b[e - 1]) {
        e -= 1;
    }
    (s, e)
}

/// 已知格式：前缀、建议名、整串最短长度。前缀后面只能是 `[A-Za-z0-9_-]`。
const PREFIXES: &[(&str, &str, usize)] = &[
    ("sk-ant-", "anthropic", 40),
    ("sk-proj-", "openai", 40),
    ("sk-svcacct-", "openai", 40),
    ("sk-or-v1-", "openrouter", 40),
    ("sk_live_", "stripe", 24),
    ("rk_live_", "stripe", 24),
    ("sk_test_", "stripe", 24),
    ("github_pat_", "github", 40),
    ("ghp_", "github", 36),
    ("gho_", "github", 36),
    ("ghu_", "github", 36),
    ("ghs_", "github", 36),
    ("ghr_", "github", 36),
    ("glpat-", "gitlab", 24),
    ("xoxb-", "slack", 24),
    ("xoxp-", "slack", 24),
    ("xoxa-", "slack", 24),
    ("xapp-", "slack", 24),
    ("hf_", "huggingface", 32),
    ("npm_", "npm", 36),
    ("xai-", "xai", 40),
    ("AIza", "google", 39),
    ("AKIA", "aws", 20),
    ("ASIA", "aws", 20),
    ("LTAI", "aliyun", 16),
    // 很多国内厂商（DeepSeek、通义、Kimi……）也是 sk- 开头，放最后兜底。
    ("sk-", "api_key", 32),
];

fn key_chars(s: &str) -> bool {
    s.bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

fn known_key(v: &str) -> Option<&'static str> {
    PREFIXES.iter().find_map(|&(prefix, name, min)| {
        let body = v.strip_prefix(prefix)?;
        (v.len() >= min && key_chars(body) && body.bytes().any(|b| b.is_ascii_digit()))
            .then_some(name)
    })
}

fn is_jwt(v: &str) -> bool {
    let parts: Vec<&str> = v.split('.').collect();
    v.len() >= 36
        && v.starts_with("eyJ")
        && parts.len() == 3
        && parts[..2].iter().all(|p| p.len() >= 8)
        && parts.iter().all(|p| key_chars(p))
}

fn entropy(v: &str) -> f64 {
    let mut counts = [0u32; 128];
    for b in v.bytes() {
        counts[usize::from(b & 0x7f)] += 1;
    }
    let n = v.len() as f64;
    counts
        .iter()
        .filter(|&&c| c > 0)
        .map(|&c| {
            let p = f64::from(c) / n;
            -p * p.log2()
        })
        .sum()
}

/// 像随机生成的 key：够长，大写、小写、数字都有不少，不是十六进制（提交号、哈希、UUID），
/// 不带 `.`、`/`（文件名、路径、域名）。
fn looks_random(v: &str) -> bool {
    let count = |f: fn(&u8) -> bool| v.bytes().filter(&f).count();
    (32..=512).contains(&v.len())
        && v.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-+=".contains(&b))
        && !v.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
        && count(u8::is_ascii_uppercase) >= 3
        && count(u8::is_ascii_lowercase) >= 3
        && count(u8::is_ascii_digit) >= 3
        && entropy(v) >= 4.0
}

/// 一个词里的网址密码 / key / 令牌 / 随机串。`KEY=值`、`key:值` 这种取等号、冒号后面的部分。
fn classify_word(text: &str, s: usize, e: usize, out: &mut Vec<Found>) {
    let (s, e) = trim_word(text, s, e);
    if s >= e {
        return;
    }
    let w = &text[s..e];
    if let Some(i) = w.find("://") {
        url_password(text, s + i + 3, e, out);
        return;
    }
    let mut candidates = vec![(s, e)];
    if let Some(i) = w.find(['=', ':']) {
        let (cs, ce) = trim_word(text, s + i + 1, e);
        if cs < ce {
            candidates.insert(0, (cs, ce));
        }
    }
    for (cs, ce) in candidates {
        let v = &text[cs..ce];
        let hit = if let Some(name) = known_key(v) {
            Some((
                SecretKind::ApiKey,
                name,
                if name == "api_key" { "" } else { name },
            ))
        } else if is_jwt(v) {
            Some((SecretKind::Token, "token", ""))
        } else if looks_random(v) {
            Some((SecretKind::HighEntropy, "secret", ""))
        } else {
            None
        };
        if let Some((kind, name, service)) = hit {
            out.push(found(text, kind, cs, ce, name, service));
            return;
        }
    }
}

/// `scheme://user:password@host/...`：取密码那段，名字用主机名的第一段。
fn url_password(text: &str, auth_start: usize, e: usize, out: &mut Vec<Found>) {
    let rest = &text[auth_start..e];
    let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..authority_end];
    let Some(at) = authority.rfind('@') else {
        return;
    };
    let userinfo = &authority[..at];
    let Some(colon) = userinfo.find(':') else {
        return;
    };
    let ps = auth_start + colon + 1;
    let pe = auth_start + at;
    if ps >= pe {
        return;
    }
    let host = &authority[at + 1..];
    let host = host.split([':', '.']).next().unwrap_or("");
    let name = if host.is_empty() || host == "localhost" || host.bytes().all(|b| b.is_ascii_digit())
    {
        "password".to_owned()
    } else {
        format!("{host}_password")
    };
    out.push(found(text, SecretKind::UrlPassword, ps, pe, &name, ""));
}

// ---------- 跟在“密码”“password”后面的值 ----------

/// 关键字（ASCII 的不分大小写）、默认名字、值最短几个字符。
const LABELS: &[(&str, &str, usize)] = &[
    ("password", "password", MIN_LEN),
    ("passwd", "password", MIN_LEN),
    ("passcode", "password", MIN_LEN),
    ("pwd", "password", MIN_LEN),
    ("密码", "password", MIN_LEN),
    ("口令", "password", MIN_LEN),
    ("授权码", "password", MIN_LEN),
    ("密钥", "secret", 8),
    ("秘钥", "secret", 8),
    ("api key", "api_key", 8),
    ("api_key", "api_key", 8),
    ("api-key", "api_key", 8),
    ("apikey", "api_key", 8),
    ("access key", "access_key", 8),
    ("access_key", "access_key", 8),
    ("secret", "secret", 8),
    ("token", "token", 8),
];

/// 关键字后面、值前面可以有的连接词（会被跳过）。`strong` 表示这个连接词明确说了“后面就是值”。
const JOINERS: &[(&str, bool)] = &[
    ("：", true),
    (":", true),
    ("=", true),
    ("就是", true),
    ("是", true),
    ("为", true),
    ("為", true),
    ("is", false),
    ("还是", false),
];

/// 关键字后面不像值的常见词（`password is required`、`token 数量`）。
const NOT_VALUES: &[&str] = &[
    "required",
    "optional",
    "missing",
    "invalid",
    "incorrect",
    "wrong",
    "expired",
    "empty",
    "none",
    "null",
    "nil",
    "true",
    "false",
    "reset",
    "field",
    "manager",
    "policy",
    "hash",
    "hashes",
    "length",
    "strength",
    "count",
    "limit",
    "limits",
    "usage",
    "file",
    "here",
    "below",
    "above",
    "same",
    "again",
    "please",
    "should",
    "must",
    "will",
    "and",
    "the",
];

fn labeled(text: &str, out: &mut Vec<Found>) {
    let lower = text.to_ascii_lowercase();
    for &(kw, default_name, min) in LABELS {
        let mut from = 0;
        while let Some(i) = lower[from..].find(kw) {
            let ks = from + i;
            let ke = ks + kw.len();
            from = ke;
            let ascii_kw = kw.is_ascii();
            let prev = lower[..ks].chars().next_back();
            // ASCII 关键字要在词的开头或者 `DB_PASSWORD` 这种标识符里。
            if ascii_kw && prev.is_some_and(|c| c.is_ascii_alphanumeric()) {
                // `dbpassword` 这种连写也算：前面是字母，后面紧跟分隔符。
                let next = lower[ke..].chars().next();
                if !matches!(next, Some(':' | '=' | '"' | '\'')) {
                    continue;
                }
            }
            // 标识符的其余部分（`api_key_v2`、`password2`）。
            let mut ve = ke;
            if ascii_kw {
                ve += lower[ke..]
                    .bytes()
                    .take_while(|b| b.is_ascii_alphanumeric() || *b == b'_' || *b == b'-')
                    .count();
            }
            let ident_end = ve;
            // 跳过空白、引号前的连接词。
            let mut strong = false;
            loop {
                let rest = &text[ve..];
                let trimmed = rest.trim_start_matches([' ', '\t', '\u{3000}']);
                ve += rest.len() - trimmed.len();
                let lrest = &lower[ve..];
                let Some(&(j, st)) = JOINERS.iter().find(|(j, _)| {
                    lrest.starts_with(j)
                        && (!j.is_ascii()
                            || !j.bytes().all(|b| b.is_ascii_alphabetic())
                            || !lrest[j.len()..]
                                .bytes()
                                .next()
                                .is_some_and(|b| b.is_ascii_alphanumeric()))
                }) else {
                    break;
                };
                strong |= st;
                ve += j.len();
            }
            // 引号括起来的整段（可以有空格）；否则是一串可见 ASCII 字符。
            let rest = &text[ve..];
            let quote = rest.chars().next().filter(|c| "\"'`“‘「『".contains(*c));
            let (vs, vend) = if let Some(q) = quote {
                let close = match q {
                    '“' => '”',
                    '‘' => '’',
                    '「' => '」',
                    '『' => '』',
                    c => c,
                };
                let vs = ve + q.len_utf8();
                match text[vs..].find(close) {
                    Some(k) if !text[vs..vs + k].contains('\n') => {
                        strong = true;
                        (vs, vs + k)
                    }
                    _ => continue,
                }
            } else {
                let n = rest.bytes().take_while(u8::is_ascii_graphic).count();
                let mut e = ve + n;
                // 句末的标点不算：后面是空白或者结尾的 `,`、`;`、`.`，以及右括号。
                while e > ve && b",;.)]}>".contains(&text.as_bytes()[e - 1]) {
                    e -= 1;
                }
                (ve, e)
            };
            let value = &text[vs..vend];
            let chars = value.chars().count();
            if chars < min || value.len() > MAX_LEN {
                continue;
            }
            if value.starts_with(['(', '[', '{', '<', '$', '%', '#', '/', '&', '*']) {
                continue;
            }
            let lv = value.to_ascii_lowercase();
            if NOT_VALUES.contains(&lv.as_str()) {
                continue;
            }
            // 没有“是 / : / =”这类明确的连接词时，全是字母的多半是普通的词（`password manager`）。
            if !strong && value.bytes().all(|b| b.is_ascii_alphabetic()) {
                continue;
            }
            let name = label_name(text, ks, ident_end, default_name, ascii_kw);
            out.push(found(text, SecretKind::Labeled, vs, vend, &name, ""));
        }
    }
}

/// 起名：`DB_PASSWORD=` 用整个标识符；“github 的密码”“GitHub password”用前面那个词加默认名。
fn label_name(
    text: &str,
    ks: usize,
    ident_end: usize,
    default_name: &str,
    ascii_kw: bool,
) -> String {
    let before = &text[..ks];
    // 和关键字连在一起的标识符前缀（`DB_`、`github-`）。
    let attached = before
        .bytes()
        .rev()
        .take_while(|b| b.is_ascii_alphanumeric() || *b == b'_' || *b == b'-')
        .count();
    if ascii_kw && attached > 0 {
        return sanitize_name(&text[ks - attached..ident_end], default_name);
    }
    // 隔开的前一个词（中间可以有空白、“的”）。
    let trimmed = before.trim_end_matches([' ', '\t', '\u{3000}']);
    let trimmed = trimmed.strip_suffix("的").unwrap_or(trimmed);
    let trimmed = trimmed.trim_end_matches([' ', '\t', '\u{3000}']);
    let word_len = trimmed
        .bytes()
        .rev()
        .take_while(|b| b.is_ascii_alphanumeric() || *b == b'_' || *b == b'-')
        .count();
    let word = &trimmed[trimmed.len() - word_len..];
    const STOP: &[&str] = &[
        "my", "the", "a", "an", "your", "our", "his", "her", "new", "old", "is",
    ];
    if word_len >= 2 && !STOP.contains(&word.to_ascii_lowercase().as_str()) {
        return sanitize_name(word, default_name);
    }
    default_name.to_owned()
}

/// 引用、占位符、打码的值，不算泄露。
fn is_placeholder(v: &str) -> bool {
    let lv = v.to_ascii_lowercase();
    let first = v.chars().next().unwrap_or(' ');
    v.starts_with("[vault:")
        || v.starts_with("{{")
        || v.starts_with("${")
        || v.chars().all(|c| c == first)
        || v.chars()
            .all(|c| c == '*' || c == 'x' || c == 'X' || c == '•' || c == '.')
        || lv.contains("your_")
        || lv.contains("your-")
        || lv.starts_with("your")
        || lv.contains("example")
        || lv.contains("placeholder")
        || lv.contains("xxxx")
        || lv.contains("****")
        || lv.contains("redacted")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(text: &str) -> Vec<(SecretKind, String, String)> {
        detect(text)
            .into_iter()
            .map(|f| {
                assert_eq!(&text[f.start..f.end], f.value);
                (f.kind, f.value, f.suggested_name)
            })
            .collect()
    }

    fn one(text: &str) -> (SecretKind, String, String) {
        let mut v = kinds(text);
        assert_eq!(v.len(), 1, "{text}: {v:?}");
        v.remove(0)
    }

    #[test]
    fn known_keys() {
        let k = "sk-ant-api03-AbCdEf0123456789AbCdEf0123456789xyzXYZ";
        assert_eq!(
            one(&format!("帮我用这个 key：{k}，谢谢")),
            (SecretKind::ApiKey, k.into(), "anthropic".into())
        );
        let gh = "ghp_0123456789abcdefABCDEF0123456789abcd";
        assert_eq!(one(&format!("GH_TOKEN={gh}")).1, gh);
        assert_eq!(one(&format!("GH_TOKEN={gh}")).0, SecretKind::ApiKey);
        assert_eq!(one("AKIAIOSFODNN7EXAMPL3").2, "aws");
        let ds = "sk-0123456789abcdef0123456789abcdef";
        let (kind, v, name) = one(&format!("deepseek 的 key 是 {ds}"));
        assert_eq!((kind, v.as_str()), (SecretKind::ApiKey, ds));
        // 通用 sk- 没认出厂商时，用前面那个词起名。
        assert!(name == "api_key" || name == "deepseek", "{name}");
        // 前缀对、但太短或者没有数字的不算（比如讲解文字里的 `sk-ant-` 本身）。
        assert!(kinds("Anthropic 的 key 以 sk-ant- 开头").is_empty());
        assert!(kinds("用 sk-your-key-here 代替").is_empty());
    }

    #[test]
    fn jwt_and_random() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U";
        assert_eq!(one(&format!("Bearer {jwt}")).0, SecretKind::Token);
        let r = "Zq8Xw3Lm9Pa2Rt7Kv5Nb1Cy6Hd4Gf0Js";
        assert_eq!(one(&format!("用这个：{r}")).0, SecretKind::HighEntropy);
        // 提交号、UUID、路径、驼峰名字都不算。
        assert!(kinds("看看 3a7dc4f9e2b1c0d8e7f6a5b4c3d2e1f0a9b8c7d6 这个提交").is_empty());
        assert!(kinds("实例 0199f1e2-3c4d-7e8f-9a0b-1c2d3e4f5a6b 挂了").is_empty());
        assert!(kinds("crates/client-core/src/SecretsDetector2Test99.rs").is_empty());
        assert!(kinds("ThisIsAVeryLongJavaClassNameWithoutDigitsAtAll").is_empty());
    }

    #[test]
    fn url_passwords() {
        let (kind, v, name) = one("连 postgres://app:S3cret!pw@db.internal:5432/prod 看看");
        assert_eq!(
            (kind, v.as_str(), name.as_str()),
            (SecretKind::UrlPassword, "S3cret!pw", "db_password")
        );
        assert!(kinds("https://user@example.com/path").is_empty());
        assert!(kinds("https://docs.rs/tokio/latest/tokio/").is_empty());
    }

    #[test]
    fn labeled_values() {
        assert_eq!(
            one("我的 github 密码是 Abc12345，帮我登录"),
            (SecretKind::Labeled, "Abc12345".into(), "github".into())
        );
        assert_eq!(one("密码：hunter2!").1, "hunter2!");
        assert_eq!(
            one("export DB_PASSWORD=pa55word"),
            (SecretKind::Labeled, "pa55word".into(), "db_password".into())
        );
        assert_eq!(
            one("password: \"correct horse battery\"").1,
            "correct horse battery"
        );
        assert_eq!(one("邮箱密码「qwer 1234」").1, "qwer 1234");
        assert_eq!(one("The password is s3cr3t.").1, "s3cr3t");
        // 不是值的。
        for t in [
            "密码是什么来着",
            "password is required",
            "我在用 password manager",
            "token 数量超了",
            "忘记密码了怎么办",
            "请把密码存进保险箱",
            "api key: ${OPENAI_API_KEY}",
            "密码：[vault:github]",
            "password: ********",
            "password=<your password>",
            "token limit 100000",
            "fn check_password(password: &str)",
        ] {
            assert!(kinds(t).is_empty(), "{t}: {:?}", kinds(t));
        }
    }

    #[test]
    fn labeled_and_key_on_the_same_value_reports_once() {
        let k = "sk-proj-AbCdEf0123456789AbCdEf0123456789xy";
        let v = kinds(&format!("api key: {k}"));
        assert_eq!(v.len(), 1, "{v:?}");
        assert_eq!(v[0].0, SecretKind::ApiKey);
        assert_eq!(v[0].2, "openai");
    }

    #[test]
    fn private_key_block() {
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU=\n-----END OPENSSH PRIVATE KEY-----";
        let text = format!("这是我的私钥\n{pem}\n帮我配上");
        let f = detect(&text);
        assert_eq!(f.len(), 1, "{f:?}");
        assert_eq!(f[0].kind, SecretKind::PrivateKey);
        assert_eq!(f[0].value, pem);
        assert!(!f[0].storable, "multi-line values can't go into the vault");
        assert!(kinds("-----BEGIN PUBLIC KEY-----\nMFkw\n-----END PUBLIC KEY-----").is_empty());
    }

    #[test]
    fn several_hits_in_order() {
        let text = "账号 bob 密码 Pw0rd!23，key 是 ghp_0123456789abcdefABCDEF0123456789abcd";
        let v = kinds(text);
        assert_eq!(v.len(), 2, "{v:?}");
        assert_eq!(v[0].1, "Pw0rd!23");
        assert_eq!(v[1].0, SecretKind::ApiKey);
        assert!(detect(text).iter().all(|f| f.storable));
    }

    #[test]
    fn redact_replaces_every_occurrence() {
        let text = "密码是 Abc12345，再说一遍 Abc12345；另一个 Abc123456789";
        let out = redact(
            text,
            &[
                ("Abc12345".into(), "github".into()),
                ("Abc123456789".into(), "mail".into()),
            ],
        );
        assert_eq!(
            out,
            "密码是 [vault:github]，再说一遍 [vault:github]；另一个 [vault:mail]"
        );
        assert!(
            detect(&out).is_empty(),
            "redacted text passes: {:?}",
            detect(&out)
        );
    }

    #[test]
    fn names() {
        assert_eq!(sanitize_name("GitHub Token!", "x"), "github_token");
        assert_eq!(sanitize_name("__", "secret"), "secret");
        assert_eq!(sanitize_name("中文", "password"), "password");
        assert_eq!(sanitize_name(&"a".repeat(100), "x").len(), 64);
        let taken = vec!["github".to_owned(), "github_2".to_owned()];
        assert_eq!(unique_name("github", &taken), "github_3");
        assert_eq!(unique_name("mail", &taken), "mail");
        assert_eq!(unique_name(&"a".repeat(64), &["a".repeat(64)]).len(), 64);
    }

    #[test]
    fn debug_hides_the_value() {
        let f = detect("密码：Abc12345");
        assert!(!format!("{f:?}").contains("Abc12345"));
    }
}
