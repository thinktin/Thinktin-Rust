//! 配对与验签协议（WBS 11.5）。手机和电脑各自在安全芯片里生成 P-256 密钥对（Secure Enclave、
//! Android Keystore；私钥不出芯片，签名由原生端在生物识别之后做）。这里负责消息的规范编码、解析和验签，
//! 手机、电脑两边用同一份实现，签的字节一定一致。
//!
//! - **配对**：电脑显示二维码（[`pairing_offer_uri`]），带电脑的设备 id、公钥、一次性随机数和过期时间。
//!   手机扫码（[`parse_pairing_offer`]）后签一条配对回复（[`pairing_response_message`]：电脑 id、随机数、
//!   手机 id、手机公钥），电脑验签（[`verify_pairing_response`]）、记下手机公钥；电脑再签一条确认
//!   （[`pairing_confirmation_message`]），手机用二维码里的电脑公钥验（[`verify_pairing_confirmation`]）。
//!   公钥只经二维码和双方的签名交换，云端只转发，冒充不了任何一方。
//! - **审批**：电脑上的高危操作（删除、执行命令、发送、支付）要手机签名批准（[`approval_message`]）：
//!   签的是电脑、请求、工具、参数的摘要、给人看的说明的摘要、签发和过期时间、决定。电脑本地验签
//!   （[`verify_approval`]）通过才执行，参数被改过、过期了、签的是“拒绝”都不行。
//! - **能力令牌**：普通操作用手机签发的令牌（[`capability_message`]）限定目录、应用和有效期，
//!   电脑本地验签（[`verify_capability`]），按令牌 id 吊销。
//!
//! 签名一律是 ECDSA P-256 + SHA-256，接受 DER（Secure Enclave、Android Keystore 的输出）和 64 字节的 r‖s；
//! 高 S 的签名先规整成低 S 再验（同一个签名的两种写法都有效）。公钥是 SEC1 格式（压缩 33 字节或
//! 不压缩 65 字节），传输时用不带填充的 base64url。

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use p256::ecdsa::signature::Verifier;
use p256::ecdsa::{Signature, VerifyingKey};
use serde_json::Value;
use sha2::{Digest, Sha256};

/// 二维码内容的前缀。
pub const OFFER_SCHEME: &str = "thinktin-pair:v1?";
/// 配对二维码最长有效期。
pub const MAX_OFFER_TTL_SECS: u64 = 10 * 60;
/// 两台设备的时钟允许差这么多。
pub const CLOCK_SKEW_SECS: u64 = 5 * 60;
/// 审批签名最长有效期。
pub const MAX_APPROVAL_TTL_SECS: u64 = 24 * 3600;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum PairingError {
    /// 格式不对：二维码、公钥、字段、签名的编码。
    #[error("malformed: {message}")]
    Malformed { message: String },
    /// 过期了（或者签发时间在将来太远）。
    #[error("expired")]
    Expired,
    /// 签名验不过：不是这把公钥签的，或者内容被改过。
    #[error("bad signature")]
    BadSignature,
}

fn malformed(message: impl Into<String>) -> PairingError {
    PairingError::Malformed {
        message: message.into(),
    }
}

/// 电脑给出的配对邀请（二维码里的内容）。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PairingOffer {
    pub desktop_id: String,
    /// 电脑的公钥（SEC1，base64url）。
    pub desktop_key: String,
    /// 一次性随机数（base64url，至少 16 字节）。
    pub nonce: String,
    /// 过期时间（Unix 秒）。
    pub expires_at: u64,
}

/// 手机签名批准（或拒绝）的高危操作。经设备中继转发时原样放进消息正文（JSON）。
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct ApprovalRequest {
    pub desktop_id: String,
    pub request_id: String,
    /// 工具名，比如 `delete_files`。
    pub tool: String,
    /// 工具参数（JSON）；签的是规范化之后的摘要，见 [`arguments_digest`]。
    pub arguments_json: String,
    /// 审批界面给人看的说明；签的是它的摘要，界面显示的和电脑要执行的对得上。
    pub summary: String,
    /// 签发和过期时间（Unix 秒）。
    pub issued_at: u64,
    pub expires_at: u64,
}

/// 手机签发给电脑的能力令牌：普通操作能碰哪些目录、哪些应用，到什么时候。
/// 经设备中继转发时原样放进消息正文（JSON）。
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct CapabilityGrant {
    pub desktop_id: String,
    pub token_id: String,
    /// 能读写的目录（绝对路径）；空表示一个都不行。
    pub dirs: Vec<String>,
    /// 能操作的应用（bundle id）；空表示一个都不行。
    pub apps: Vec<String>,
    pub expires_at: u64,
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn b64(data: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(data)
}

fn unb64(field: &str, s: &str) -> Result<Vec<u8>, PairingError> {
    URL_SAFE_NO_PAD
        .decode(s.trim_end_matches('='))
        .map_err(|_| malformed(format!("{field} is not base64url")))
}

/// 解析公钥（SEC1 压缩或不压缩格式，base64url）。
fn verifying_key(field: &str, key: &str) -> Result<VerifyingKey, PairingError> {
    let bytes = unb64(field, key)?;
    VerifyingKey::from_sec1_bytes(&bytes)
        .map_err(|_| malformed(format!("{field} is not a P-256 public key")))
}

/// 标识符：1 到 128 个可见 ASCII 字符（不含 `&`、`=`、`:`，二维码和规范编码里不用转义）。
fn check_id(field: &str, v: &str) -> Result<(), PairingError> {
    let ok = (1..=128).contains(&v.len())
        && v.bytes()
            .all(|b| b.is_ascii_graphic() && !matches!(b, b'&' | b'=' | b':'));
    if ok {
        Ok(())
    } else {
        Err(malformed(format!(
            "{field} must be 1-128 printable ASCII characters"
        )))
    }
}

/// 规范编码：第一行是带版本的种类（不同种类的消息签名不能互换），后面每行一个 `键:值`。
/// 值里不能有换行，否则一个字段能伪装成两个。
fn canonical(kind: &str, fields: &[(&str, &str)]) -> Result<Vec<u8>, PairingError> {
    let mut out = format!("thinktin-{kind}-v1\n");
    for (k, v) in fields {
        if v.contains(['\n', '\r']) {
            return Err(malformed(format!("{k} must not contain line breaks")));
        }
        out.push_str(k);
        out.push(':');
        out.push_str(v);
        out.push('\n');
    }
    Ok(out.into_bytes())
}

fn sha256_hex(data: &[u8]) -> String {
    Sha256::digest(data)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// P-256 的阶 n（大端）。
const ORDER: [u8; 32] = [
    0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84, 0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
];
/// ⌊n / 2⌋（大端）：S 大于它就是“高 S”。
const HALF_ORDER: [u8; 32] = [
    0x7f, 0xff, 0xff, 0xff, 0x80, 0x00, 0x00, 0x00, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xde, 0x73, 0x7d, 0x56, 0xd3, 0x8b, 0xcf, 0x42, 0x79, 0xdc, 0xe5, 0x61, 0x7e, 0x31, 0x92, 0xa8,
];

/// 大端减法 a - b（a ≥ b）。
fn sub_be(a: &[u8; 32], b: &[u8; 32]) -> [u8; 32] {
    let mut out = [0u8; 32];
    let mut borrow = 0i16;
    for i in (0..32).rev() {
        let mut d = i16::from(a[i]) - i16::from(b[i]) - borrow;
        borrow = 0;
        if d < 0 {
            d += 256;
            borrow = 1;
        }
        out[i] = d as u8;
    }
    out
}

/// DER 里的一个 INTEGER，去掉符号位补的 0，左边补 0 到 32 字节。
fn der_int(input: &[u8]) -> Result<([u8; 32], &[u8]), PairingError> {
    let bad = || malformed("signature is not DER or 64-byte r||s");
    let (&tag, rest) = input.split_first().ok_or_else(bad)?;
    let (&len, rest) = rest.split_first().ok_or_else(bad)?;
    if tag != 0x02 || len == 0 || len > 33 || rest.len() < usize::from(len) {
        return Err(bad());
    }
    let (int, rest) = rest.split_at(usize::from(len));
    let int = match int {
        [0, tail @ ..] if !tail.is_empty() => tail,
        other => other,
    };
    if int.len() > 32 {
        return Err(bad());
    }
    let mut out = [0u8; 32];
    out[32 - int.len()..].copy_from_slice(int);
    Ok((out, rest))
}

/// 签名：64 字节的 r‖s，或者 DER。高 S 规整成低 S。
fn signature(sig: &[u8]) -> Result<Signature, PairingError> {
    let (r, mut s) = if sig.len() == 64 {
        let mut r = [0u8; 32];
        let mut s = [0u8; 32];
        r.copy_from_slice(&sig[..32]);
        s.copy_from_slice(&sig[32..]);
        (r, s)
    } else {
        let bad = || malformed("signature is not DER or 64-byte r||s");
        let (&tag, rest) = sig.split_first().ok_or_else(bad)?;
        let (&len, body) = rest.split_first().ok_or_else(bad)?;
        if tag != 0x30 || usize::from(len) != body.len() {
            return Err(bad());
        }
        let (r, rest) = der_int(body)?;
        let (s, rest) = der_int(rest)?;
        if !rest.is_empty() {
            return Err(bad());
        }
        (r, s)
    };
    if s > HALF_ORDER {
        s = sub_be(&ORDER, &s);
    }
    let mut raw = [0u8; 64];
    raw[..32].copy_from_slice(&r);
    raw[32..].copy_from_slice(&s);
    Signature::from_slice(&raw).map_err(|_| malformed("signature is out of range"))
}

fn verify(key: &VerifyingKey, message: &[u8], sig: &[u8]) -> Result<(), PairingError> {
    let sig = signature(sig)?;
    key.verify(message, &sig)
        .map_err(|_| PairingError::BadSignature)
}

// ---------- 配对 ----------

/// 电脑这边：把配对邀请编成二维码内容。
#[uniffi::export]
pub fn pairing_offer_uri(offer: PairingOffer) -> Result<String, PairingError> {
    check_offer(&offer)?;
    Ok(format!(
        "{OFFER_SCHEME}d={}&k={}&n={}&e={}",
        offer.desktop_id, offer.desktop_key, offer.nonce, offer.expires_at
    ))
}

fn check_offer(offer: &PairingOffer) -> Result<(), PairingError> {
    check_id("desktop_id", &offer.desktop_id)?;
    verifying_key("desktop_key", &offer.desktop_key)?;
    if unb64("nonce", &offer.nonce)?.len() < 16 {
        return Err(malformed("nonce must be at least 16 bytes"));
    }
    Ok(())
}

/// 手机这边：解析扫到的二维码。过期的、有效期长得不合理的都拒绝。
#[uniffi::export]
pub fn parse_pairing_offer(uri: String) -> Result<PairingOffer, PairingError> {
    parse_offer_at(&uri, now_secs())
}

fn parse_offer_at(uri: &str, now: u64) -> Result<PairingOffer, PairingError> {
    let query = uri
        .trim()
        .strip_prefix(OFFER_SCHEME)
        .ok_or_else(|| malformed("not a ThinkTin pairing code"))?;
    let (mut d, mut k, mut n, mut e) = (None, None, None, None);
    for pair in query.split('&') {
        let (key, value) = pair
            .split_once('=')
            .ok_or_else(|| malformed("malformed pairing code"))?;
        let slot = match key {
            "d" => &mut d,
            "k" => &mut k,
            "n" => &mut n,
            "e" => &mut e,
            _ => continue,
        };
        if slot.replace(value.to_owned()).is_some() {
            return Err(malformed(format!("duplicate field {key}")));
        }
    }
    let missing = |f: &str| malformed(format!("pairing code has no {f}"));
    let offer = PairingOffer {
        desktop_id: d.ok_or_else(|| missing("d"))?,
        desktop_key: k.ok_or_else(|| missing("k"))?,
        nonce: n.ok_or_else(|| missing("n"))?,
        expires_at: e
            .ok_or_else(|| missing("e"))?
            .parse()
            .map_err(|_| malformed("e must be a Unix time"))?,
    };
    check_offer(&offer)?;
    if offer.expires_at + CLOCK_SKEW_SECS <= now {
        return Err(PairingError::Expired);
    }
    if offer.expires_at > now + MAX_OFFER_TTL_SECS + CLOCK_SKEW_SECS {
        return Err(malformed("pairing code is valid for too long"));
    }
    Ok(offer)
}

/// 手机要签的配对回复。
#[uniffi::export]
pub fn pairing_response_message(
    offer: PairingOffer,
    phone_id: String,
    phone_key: String,
) -> Result<Vec<u8>, PairingError> {
    check_offer(&offer)?;
    check_id("phone_id", &phone_id)?;
    verifying_key("phone_key", &phone_key)?;
    canonical(
        "pair-response",
        &[
            ("desktop", &offer.desktop_id),
            ("nonce", &offer.nonce),
            ("phone", &phone_id),
            ("phone-key", &phone_key),
        ],
    )
}

/// 电脑这边：验手机的配对回复（邀请是自己发出的那一个、没过期、是这把手机公钥签的）。
#[uniffi::export]
pub fn verify_pairing_response(
    offer: PairingOffer,
    phone_id: String,
    phone_key: String,
    signature: Vec<u8>,
) -> Result<(), PairingError> {
    verify_response_at(&offer, &phone_id, &phone_key, &signature, now_secs())
}

fn verify_response_at(
    offer: &PairingOffer,
    phone_id: &str,
    phone_key: &str,
    sig: &[u8],
    now: u64,
) -> Result<(), PairingError> {
    if offer.expires_at + CLOCK_SKEW_SECS <= now {
        return Err(PairingError::Expired);
    }
    let message =
        pairing_response_message(offer.clone(), phone_id.to_owned(), phone_key.to_owned())?;
    verify(&verifying_key("phone_key", phone_key)?, &message, sig)
}

/// 电脑要签的配对确认：告诉手机“我记下了你这把公钥”。
#[uniffi::export]
pub fn pairing_confirmation_message(
    offer: PairingOffer,
    phone_id: String,
    phone_key: String,
) -> Result<Vec<u8>, PairingError> {
    check_offer(&offer)?;
    check_id("phone_id", &phone_id)?;
    verifying_key("phone_key", &phone_key)?;
    canonical(
        "pair-confirm",
        &[
            ("desktop", &offer.desktop_id),
            ("desktop-key", &offer.desktop_key),
            ("nonce", &offer.nonce),
            ("phone", &phone_id),
            ("phone-key", &phone_key),
        ],
    )
}

/// 手机这边：用二维码里的电脑公钥验配对确认。
#[uniffi::export]
pub fn verify_pairing_confirmation(
    offer: PairingOffer,
    phone_id: String,
    phone_key: String,
    signature: Vec<u8>,
) -> Result<(), PairingError> {
    let key = verifying_key("desktop_key", &offer.desktop_key)?;
    let message = pairing_confirmation_message(offer, phone_id, phone_key)?;
    verify(&key, &message, &signature)
}

// ---------- 审批 ----------

/// 工具参数的摘要：JSON 规范化（对象的键排序、没有多余空白）后的 SHA-256（十六进制）。
/// 手机、电脑两边对同一份参数一定算出同一个值，不受键的顺序、空白的影响。
#[uniffi::export]
pub fn arguments_digest(arguments_json: String) -> Result<String, PairingError> {
    let v: Value = serde_json::from_str(&arguments_json)
        .map_err(|e| malformed(format!("arguments are not JSON: {e}")))?;
    let mut out = String::new();
    canonical_json(&v, &mut out);
    Ok(sha256_hex(out.as_bytes()))
}

fn canonical_json(v: &Value, out: &mut String) {
    match v {
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            out.push('{');
            for (i, k) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&Value::String(k.clone()).to_string());
                out.push(':');
                canonical_json(&map[k.as_str()], out);
            }
            out.push('}');
        }
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                canonical_json(item, out);
            }
            out.push(']');
        }
        other => out.push_str(&other.to_string()),
    }
}

/// 手机要签的审批消息。`approve` 为假时签的是“拒绝”（电脑据此确认用户确实拒绝了，不会误当成批准）。
#[uniffi::export]
pub fn approval_message(request: ApprovalRequest, approve: bool) -> Result<Vec<u8>, PairingError> {
    check_id("desktop_id", &request.desktop_id)?;
    check_id("request_id", &request.request_id)?;
    check_id("tool", &request.tool)?;
    if request.expires_at <= request.issued_at
        || request.expires_at - request.issued_at > MAX_APPROVAL_TTL_SECS
    {
        return Err(malformed(
            "approval must expire after it is issued, within 24 hours",
        ));
    }
    let args = arguments_digest(request.arguments_json.clone())?;
    let summary = sha256_hex(request.summary.as_bytes());
    canonical(
        "approval",
        &[
            ("desktop", &request.desktop_id),
            ("request", &request.request_id),
            ("tool", &request.tool),
            ("args-sha256", &args),
            ("summary-sha256", &summary),
            ("issued", &request.issued_at.to_string()),
            ("expires", &request.expires_at.to_string()),
            ("decision", if approve { "approve" } else { "reject" }),
        ],
    )
}

/// 电脑这边：验手机的审批签名（配对时记下的手机公钥；没过期；签发时间不在将来太远）。
#[uniffi::export]
pub fn verify_approval(
    request: ApprovalRequest,
    approve: bool,
    signature: Vec<u8>,
    phone_key: String,
) -> Result<(), PairingError> {
    verify_approval_at(&request, approve, &signature, &phone_key, now_secs())
}

fn verify_approval_at(
    request: &ApprovalRequest,
    approve: bool,
    sig: &[u8],
    phone_key: &str,
    now: u64,
) -> Result<(), PairingError> {
    if request.expires_at + CLOCK_SKEW_SECS <= now || request.issued_at > now + CLOCK_SKEW_SECS {
        return Err(PairingError::Expired);
    }
    let message = approval_message(request.clone(), approve)?;
    verify(&verifying_key("phone_key", phone_key)?, &message, sig)
}

// ---------- 能力令牌 ----------

/// 手机要签的能力令牌。
#[uniffi::export]
pub fn capability_message(grant: CapabilityGrant) -> Result<Vec<u8>, PairingError> {
    check_id("desktop_id", &grant.desktop_id)?;
    check_id("token_id", &grant.token_id)?;
    for d in &grant.dirs {
        if !d.starts_with('/') || d.split('/').any(|seg| seg == "..") {
            return Err(malformed(format!(
                "{d:?} must be an absolute path without .."
            )));
        }
    }
    for a in &grant.apps {
        check_id("app", a)?;
    }
    let expires = grant.expires_at.to_string();
    let mut fields: Vec<(&str, &str)> = vec![
        ("desktop", &grant.desktop_id),
        ("token", &grant.token_id),
        ("expires", &expires),
    ];
    fields.extend(grant.dirs.iter().map(|d| ("dir", d.as_str())));
    fields.extend(grant.apps.iter().map(|a| ("app", a.as_str())));
    canonical("capability", &fields)
}

/// 电脑这边：验能力令牌（配对时记下的手机公钥；没过期）。吊销由电脑按 `token_id` 自己记。
#[uniffi::export]
pub fn verify_capability(
    grant: CapabilityGrant,
    signature: Vec<u8>,
    phone_key: String,
) -> Result<(), PairingError> {
    verify_capability_at(&grant, &signature, &phone_key, now_secs())
}

fn verify_capability_at(
    grant: &CapabilityGrant,
    sig: &[u8],
    phone_key: &str,
    now: u64,
) -> Result<(), PairingError> {
    if grant.expires_at + CLOCK_SKEW_SECS <= now {
        return Err(PairingError::Expired);
    }
    let message = capability_message(grant.clone())?;
    verify(&verifying_key("phone_key", phone_key)?, &message, sig)
}

/// 令牌允不允许碰这个路径：在某个目录之内（按路径段比较，`/a/bc` 不在 `/a/b` 里）、不含 `..`。
#[uniffi::export]
pub fn capability_allows_path(grant: CapabilityGrant, path: String) -> bool {
    if !path.starts_with('/') || path.split('/').any(|seg| seg == "..") {
        return false;
    }
    let path = path.trim_end_matches('/');
    grant.dirs.iter().any(|d| {
        let d = d.trim_end_matches('/');
        d.is_empty()
            || path == d
            || path
                .strip_prefix(d)
                .is_some_and(|rest| rest.starts_with('/'))
    })
}

/// 给原生端用：把公钥字节（SEC1）编成传输用的 base64url，顺便检查是不是 P-256 公钥。
#[uniffi::export]
pub fn encode_public_key(sec1: Vec<u8>) -> Result<String, PairingError> {
    VerifyingKey::from_sec1_bytes(&sec1).map_err(|_| malformed("not a P-256 public key"))?;
    Ok(b64(&sec1))
}

// ---------- 经设备中继转发的消息正文（14.1、14.2） ----------
//
// 手机和电脑之间的消息由平台转发（`proto::domain::DeviceMessageKind`），正文是下面这些 JSON。
// 签名都是 base64url（不带填充）编码的 DER 或 r‖s。

/// 手机 → 电脑（`capability`）：签过名的能力令牌。
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct CapabilityBody {
    pub grant: CapabilityGrant,
    /// 手机对 [`capability_message`] 的签名。
    pub signature: String,
}

/// 手机 → 电脑（`revocation`）：吊销能力令牌。不用签名：吊销只会收紧权限，
/// 平台伪造了也只能让电脑少做事（平台本来就可以不转发消息）。
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct RevocationBody {
    pub token_id: String,
}

/// 电脑 → 手机（`approval_request`）：请手机签名批准的高危操作。
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ApprovalRequestBody {
    pub request: ApprovalRequest,
}

/// 手机 → 电脑（`approval_decision`）：签过名的批准或拒绝（[`approval_message`]）。
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ApprovalDecisionBody {
    pub request_id: String,
    pub approve: bool,
    pub signature: String,
}

/// 签名放进消息正文的编码。
pub fn encode_signature(signature: &[u8]) -> String {
    b64(signature)
}

/// 消息正文里的签名解出字节。
pub fn decode_signature(signature: &str) -> Result<Vec<u8>, PairingError> {
    unb64("signature", signature)
}

#[cfg(test)]
mod tests;
