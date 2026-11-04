//! 配对与验签协议的测试。向量由独立实现（Python `cryptography`，即 OpenSSL）按同一份规范生成：
//! 规范编码、参数摘要、DER 签名（随机 k，含高 S）都要和 Rust 这边对得上，原生端（Swift、Kotlin）
//! 用系统的 P-256 签名，输出也是这种 DER。

use super::*;
use p256::ecdsa::SigningKey;
use p256::ecdsa::signature::Signer;

const PHONE_KEY_COMPRESSED: &str = "A3ZBMie_HDnUDgWOHXgN_KgD1WVDY2JGkisQVOaV2ztZ";
const PHONE_KEY_UNCOMPRESSED: &str =
    "BHZBMie_HDnUDgWOHXgN_KgD1WVDY2JGkisQVOaV2ztZAvL_95KtnYg3KwlT12JH7OBPAxOJyHWZV2Zv7NQRWbE";
const DESKTOP_KEY: &str =
    "BHGPuO3emZZPoXZt1QKaW_v0vTGoCGWqM-dmhYZVc_9ziHw6tD4C6tX9UofXGOOguvAbH7jebXfPeeYP8l568Ps";
const NONCE: &str = "AAECAwQFBgcICQoLDA0ODw";
const ARGS_JSON: &str =
    r#"{"recursive":1,"paths":["/Users/me/old.log","/Users/me/tmp"],"note":"清理\n旧文件"}"#;
const ARGS_DIGEST: &str = "812063d33eea6eecb5b080fe8cf105b13725d48b04a57d198dd25781b9d48ce2";
const APPROVAL_MESSAGE: &str = "thinktin-approval-v1\ndesktop:mac-1\nrequest:req-42\ntool:delete_files\nargs-sha256:812063d33eea6eecb5b080fe8cf105b13725d48b04a57d198dd25781b9d48ce2\nsummary-sha256:4c33c19418c5481ea2fc3897035d3d724c56fbd6fdca1624d8e9132ab5100463\nissued:1760000000\nexpires:1760000600\ndecision:approve\n";
const APPROVAL_DER_LOW_S: &[u8] = &[
    0x30, 0x44, 0x02, 0x20, 0x22, 0x77, 0xa4, 0xbc, 0x36, 0x43, 0x57, 0xa5, 0x92, 0xdc, 0x02, 0xfb,
    0x15, 0x0a, 0xc6, 0xa0, 0xd1, 0x6a, 0xe1, 0x2e, 0xce, 0xdd, 0x2b, 0x9c, 0xbb, 0x1b, 0x87, 0xea,
    0x5f, 0x7a, 0x50, 0xd8, 0x02, 0x20, 0x27, 0x78, 0x5a, 0x06, 0x71, 0x3d, 0x12, 0xda, 0x73, 0xc2,
    0x20, 0x82, 0xaf, 0x45, 0xeb, 0xa2, 0xa0, 0x08, 0x34, 0x70, 0x00, 0xca, 0x1c, 0xa3, 0xb3, 0x13,
    0x0a, 0x06, 0x97, 0xe5, 0xc4, 0x13,
];
const APPROVAL_DER_HIGH_S: &[u8] = &[
    0x30, 0x45, 0x02, 0x20, 0x22, 0x77, 0xa4, 0xbc, 0x36, 0x43, 0x57, 0xa5, 0x92, 0xdc, 0x02, 0xfb,
    0x15, 0x0a, 0xc6, 0xa0, 0xd1, 0x6a, 0xe1, 0x2e, 0xce, 0xdd, 0x2b, 0x9c, 0xbb, 0x1b, 0x87, 0xea,
    0x5f, 0x7a, 0x50, 0xd8, 0x02, 0x21, 0x00, 0xd8, 0x87, 0xa5, 0xf8, 0x8e, 0xc2, 0xed, 0x26, 0x8c,
    0x3d, 0xdf, 0x7d, 0x50, 0xba, 0x14, 0x5d, 0x1c, 0xde, 0xc6, 0x3d, 0xa6, 0x4d, 0x81, 0xe1, 0x40,
    0xa6, 0xc0, 0xbc, 0x64, 0x7d, 0x61, 0x3e,
];
const APPROVAL_RAW: &[u8] = &[
    0x22, 0x77, 0xa4, 0xbc, 0x36, 0x43, 0x57, 0xa5, 0x92, 0xdc, 0x02, 0xfb, 0x15, 0x0a, 0xc6, 0xa0,
    0xd1, 0x6a, 0xe1, 0x2e, 0xce, 0xdd, 0x2b, 0x9c, 0xbb, 0x1b, 0x87, 0xea, 0x5f, 0x7a, 0x50, 0xd8,
    0x27, 0x78, 0x5a, 0x06, 0x71, 0x3d, 0x12, 0xda, 0x73, 0xc2, 0x20, 0x82, 0xaf, 0x45, 0xeb, 0xa2,
    0xa0, 0x08, 0x34, 0x70, 0x00, 0xca, 0x1c, 0xa3, 0xb3, 0x13, 0x0a, 0x06, 0x97, 0xe5, 0xc4, 0x13,
];
const RESPONSE_DER: &[u8] = &[
    0x30, 0x46, 0x02, 0x21, 0x00, 0xf8, 0x33, 0x69, 0x72, 0xf0, 0x1d, 0x9b, 0x00, 0x7d, 0xb1, 0xe5,
    0xb7, 0x17, 0x29, 0x77, 0xbe, 0x4b, 0xe1, 0xac, 0xf8, 0xaa, 0x93, 0x5b, 0x0d, 0x34, 0x80, 0x8f,
    0x16, 0xbd, 0x66, 0x6b, 0xbb, 0x02, 0x21, 0x00, 0x96, 0x88, 0x72, 0x49, 0x0f, 0x0f, 0x80, 0x87,
    0x09, 0x69, 0x36, 0x03, 0x19, 0xa7, 0xe6, 0x42, 0x1c, 0x75, 0x3e, 0xd0, 0xd4, 0xe6, 0xea, 0x7c,
    0xf7, 0x11, 0x76, 0x65, 0x0c, 0x61, 0x17, 0x89,
];
const CONFIRM_DER: &[u8] = &[
    0x30, 0x44, 0x02, 0x20, 0x0f, 0x92, 0x5e, 0x83, 0xfd, 0x16, 0xcc, 0xa4, 0x0f, 0x39, 0xae, 0x0b,
    0xb6, 0x70, 0x2c, 0x0d, 0x6b, 0x5c, 0x32, 0xbe, 0x6a, 0x3b, 0xc0, 0x08, 0xcb, 0x3f, 0xc8, 0x72,
    0x81, 0x91, 0x1d, 0xbc, 0x02, 0x20, 0x21, 0x3f, 0x97, 0x6a, 0xce, 0xfc, 0xdb, 0xef, 0xd7, 0x76,
    0xf1, 0x55, 0xa1, 0x63, 0x00, 0x41, 0x3e, 0x45, 0x27, 0xd0, 0x8a, 0x5d, 0x30, 0x3d, 0x93, 0x8c,
    0x7e, 0xa1, 0x27, 0x93, 0x43, 0x5a,
];
const CAPABILITY_DER: &[u8] = &[
    0x30, 0x44, 0x02, 0x20, 0x74, 0x1b, 0x81, 0xe7, 0x79, 0xd3, 0x0c, 0xc7, 0x55, 0x15, 0xb3, 0xc6,
    0x8f, 0xf0, 0x18, 0xae, 0x90, 0xe8, 0x91, 0x94, 0x7a, 0x75, 0x3c, 0x37, 0xf3, 0x27, 0x44, 0x86,
    0x03, 0xbe, 0xcd, 0xc6, 0x02, 0x20, 0x5b, 0x02, 0x0e, 0xf4, 0x04, 0x88, 0x60, 0x35, 0x0d, 0xf5,
    0x79, 0x56, 0x5f, 0x17, 0xf7, 0xaa, 0x4d, 0x78, 0xc3, 0x8a, 0x70, 0x64, 0x13, 0x21, 0x28, 0x36,
    0x8e, 0xbf, 0x5d, 0xc1, 0x41, 0x96,
];

/// 私钥是 32 个 0x07 的那把公钥（压缩格式）。
const SEVENS_KEY: &str = "Ax4YUy_UdUwC8wQdnHXOszuD_9gax85P6ILMscmLxYlu";

const NOW: u64 = 1_760_000_100;

fn request() -> ApprovalRequest {
    ApprovalRequest {
        desktop_id: "mac-1".into(),
        request_id: "req-42".into(),
        tool: "delete_files".into(),
        arguments_json: ARGS_JSON.into(),
        summary: "删除 2 个文件".into(),
        issued_at: 1_760_000_000,
        expires_at: 1_760_000_600,
    }
}

fn offer() -> PairingOffer {
    PairingOffer {
        desktop_id: "mac-1".into(),
        desktop_key: DESKTOP_KEY.into(),
        nonce: NONCE.into(),
        expires_at: NOW + 300,
    }
}

#[test]
fn approval_messages_match_the_independent_implementation() {
    assert_eq!(arguments_digest(ARGS_JSON.into()).unwrap(), ARGS_DIGEST);
    // 键的顺序、空白不影响摘要。
    let reordered = r#"{ "note": "清理\n旧文件", "paths": ["/Users/me/old.log", "/Users/me/tmp"], "recursive": 1 }"#;
    assert_eq!(arguments_digest(reordered.into()).unwrap(), ARGS_DIGEST);
    assert!(matches!(
        arguments_digest("{not json".into()),
        Err(PairingError::Malformed { .. })
    ));
    let message = approval_message(request(), true).unwrap();
    assert_eq!(String::from_utf8(message).unwrap(), APPROVAL_MESSAGE);
}

#[test]
fn approvals_verify_in_every_encoding() {
    for sig in [APPROVAL_DER_LOW_S, APPROVAL_DER_HIGH_S, APPROVAL_RAW] {
        verify_approval_at(&request(), true, sig, PHONE_KEY_COMPRESSED, NOW).unwrap();
        verify_approval_at(&request(), true, sig, PHONE_KEY_UNCOMPRESSED, NOW).unwrap();
    }
}

#[test]
fn tampered_or_stale_approvals_are_refused() {
    let sig = APPROVAL_DER_LOW_S;
    // 签的是“批准”，拿去当“拒绝”或者反过来都不行；说明、参数改了也不行。
    assert_eq!(
        verify_approval_at(&request(), false, sig, PHONE_KEY_COMPRESSED, NOW),
        Err(PairingError::BadSignature)
    );
    let mut other = request();
    other.summary = "删除 1 个文件".into();
    assert_eq!(
        verify_approval_at(&other, true, sig, PHONE_KEY_COMPRESSED, NOW),
        Err(PairingError::BadSignature)
    );
    let mut other = request();
    other.arguments_json = r#"{"paths":["/"],"recursive":1}"#.into();
    assert_eq!(
        verify_approval_at(&other, true, sig, PHONE_KEY_COMPRESSED, NOW),
        Err(PairingError::BadSignature)
    );
    // 别的设备的公钥。
    assert_eq!(
        verify_approval_at(&request(), true, sig, DESKTOP_KEY, NOW),
        Err(PairingError::BadSignature)
    );
    // 过期了；签发时间在将来太远。
    assert_eq!(
        verify_approval_at(
            &request(),
            true,
            sig,
            PHONE_KEY_COMPRESSED,
            1_760_000_600 + CLOCK_SKEW_SECS
        ),
        Err(PairingError::Expired)
    );
    assert_eq!(
        verify_approval_at(&request(), true, sig, PHONE_KEY_COMPRESSED, 1_759_000_000),
        Err(PairingError::Expired)
    );
    // 编码坏了的签名、公钥。
    for bad in [&[0x30, 0x02, 0x02, 0x00][..], &[1u8; 63][..], &[][..]] {
        assert!(matches!(
            verify_approval_at(&request(), true, bad, PHONE_KEY_COMPRESSED, NOW),
            Err(PairingError::Malformed { .. })
        ));
    }
    assert!(matches!(
        verify_approval_at(&request(), true, sig, "not-a-key", NOW),
        Err(PairingError::Malformed { .. })
    ));
    // 字段里有换行、有效期不合理：编码前就拒绝。
    let mut other = request();
    other.tool = "delete\nfiles".into();
    assert!(approval_message(other, true).is_err());
    let mut other = request();
    other.expires_at = other.issued_at + MAX_APPROVAL_TTL_SECS + 1;
    assert!(approval_message(other, true).is_err());
}

#[test]
fn pairing_codes_round_trip_and_expire() {
    let uri = pairing_offer_uri(offer()).unwrap();
    assert!(uri.starts_with(OFFER_SCHEME));
    assert_eq!(parse_offer_at(&uri, NOW).unwrap(), offer());
    assert_eq!(
        parse_offer_at(&uri, NOW + 300 + CLOCK_SKEW_SECS),
        Err(PairingError::Expired)
    );
    let long = PairingOffer {
        expires_at: NOW + MAX_OFFER_TTL_SECS + CLOCK_SKEW_SECS + 1,
        ..offer()
    };
    assert!(parse_offer_at(&pairing_offer_uri(long).unwrap(), NOW).is_err());
    for bad in [
        "https://example.com".to_owned(),
        format!("{OFFER_SCHEME}d=mac-1&k={DESKTOP_KEY}&n={NONCE}"),
        format!(
            "{OFFER_SCHEME}d=mac-1&d=mac-2&k={DESKTOP_KEY}&n={NONCE}&e={}",
            NOW + 60
        ),
        format!("{OFFER_SCHEME}d=mac-1&k=AAAA&n={NONCE}&e={}", NOW + 60),
        format!(
            "{OFFER_SCHEME}d=mac-1&k={DESKTOP_KEY}&n=AAAA&e={}",
            NOW + 60
        ),
    ] {
        assert!(parse_offer_at(&bad, NOW).is_err(), "{bad}");
    }
}

#[test]
fn both_sides_verify_the_pairing() {
    // 电脑验手机的回复（高 S 的 DER）。
    verify_response_at(
        &offer(),
        "iphone-7",
        PHONE_KEY_COMPRESSED,
        RESPONSE_DER,
        NOW,
    )
    .unwrap();
    assert_eq!(
        verify_response_at(
            &offer(),
            "iphone-8",
            PHONE_KEY_COMPRESSED,
            RESPONSE_DER,
            NOW
        ),
        Err(PairingError::BadSignature)
    );
    let other_nonce = PairingOffer {
        nonce: "BBECAwQFBgcICQoLDA0ODw".into(),
        ..offer()
    };
    assert_eq!(
        verify_response_at(
            &other_nonce,
            "iphone-7",
            PHONE_KEY_COMPRESSED,
            RESPONSE_DER,
            NOW
        ),
        Err(PairingError::BadSignature)
    );
    assert_eq!(
        verify_response_at(
            &offer(),
            "iphone-7",
            PHONE_KEY_COMPRESSED,
            RESPONSE_DER,
            NOW + 3600
        ),
        Err(PairingError::Expired)
    );
    // 手机用二维码里的电脑公钥验确认。
    verify_pairing_confirmation(
        offer(),
        "iphone-7".into(),
        PHONE_KEY_COMPRESSED.into(),
        CONFIRM_DER.to_vec(),
    )
    .unwrap();
    // 回复的签名不能拿来冒充确认（种类不同，签的字节不同）。
    assert_eq!(
        verify_pairing_confirmation(
            offer(),
            "iphone-7".into(),
            PHONE_KEY_COMPRESSED.into(),
            RESPONSE_DER.to_vec(),
        ),
        Err(PairingError::BadSignature)
    );
}

#[test]
fn capabilities_verify_and_scope_paths() {
    let grant = CapabilityGrant {
        desktop_id: "mac-1".into(),
        token_id: "cap-1".into(),
        dirs: vec!["/Users/me/Documents".into()],
        apps: vec!["com.apple.Safari".into()],
        expires_at: 1_760_003_600,
    };
    verify_capability_at(&grant, CAPABILITY_DER, PHONE_KEY_COMPRESSED, NOW).unwrap();
    let wider = CapabilityGrant {
        dirs: vec!["/Users/me".into()],
        ..grant.clone()
    };
    assert_eq!(
        verify_capability_at(&wider, CAPABILITY_DER, PHONE_KEY_COMPRESSED, NOW),
        Err(PairingError::BadSignature)
    );
    assert_eq!(
        verify_capability_at(
            &grant,
            CAPABILITY_DER,
            PHONE_KEY_COMPRESSED,
            1_760_003_600 + CLOCK_SKEW_SECS
        ),
        Err(PairingError::Expired)
    );
    for (path, ok) in [
        ("/Users/me/Documents", true),
        ("/Users/me/Documents/a/b.txt", true),
        ("/Users/me/Documents2/x", false),
        ("/Users/me/Documents/../.ssh/id_rsa", false),
        ("Users/me/Documents/x", false),
        ("/etc/passwd", false),
        // macOS 的令牌管不到 Windows 的路径。
        (r"C:\Users\me\Documents", false),
    ] {
        assert_eq!(
            capability_allows_path(grant.clone(), path.into()),
            ok,
            "{path}"
        );
    }
    // Windows：盘符、两种分隔符、不分大小写、`\\?\` 前缀（canonicalize 给出的写法）、UNC 共享。
    let windows = CapabilityGrant {
        dirs: vec![
            r"C:\Users\me\Documents".into(),
            r"\\nas\share\photos".into(),
        ],
        ..grant.clone()
    };
    verify_capability_at(&windows, CAPABILITY_DER, PHONE_KEY_COMPRESSED, NOW).unwrap_err();
    for (path, ok) in [
        (r"C:\Users\me\Documents", true),
        (r"c:\users\ME\documents\a\b.txt", true),
        ("C:/Users/me/Documents/x", true),
        (r"\\?\C:\Users\me\Documents\x", true),
        (r"C:\Users\me\Documents2\x", false),
        (r"C:\Users\me\Documents\..\.ssh\id_rsa", false),
        (r"D:\Users\me\Documents", false),
        (r"Users\me\Documents", false),
        ("/Users/me/Documents", false),
        (r"\\NAS\Share\photos\2026", true),
        (r"\\nas\other\photos", false),
        (r"\\nas", false),
    ] {
        assert_eq!(
            capability_allows_path(windows.clone(), path.into()),
            ok,
            "{path}"
        );
    }
    for d in [r"C:\Users\..\x", r"C:Users", r"\\nas", "relative/dir"] {
        let bad = CapabilityGrant {
            dirs: vec![d.into()],
            ..grant.clone()
        };
        assert!(capability_message(bad).is_err(), "{d}");
    }
}

#[test]
fn signatures_from_rust_keys_verify_too() {
    let key = SigningKey::from_slice(&[7u8; 32]).unwrap();
    let message = approval_message(request(), false).unwrap();
    let sig: Signature = key.sign(&message);
    verify_approval_at(&request(), false, &sig.to_bytes(), SEVENS_KEY, NOW).unwrap();
    assert_eq!(
        verify_approval_at(&request(), true, &sig.to_bytes(), SEVENS_KEY, NOW),
        Err(PairingError::BadSignature)
    );
    assert_eq!(
        encode_public_key(unb64("k", SEVENS_KEY).unwrap()).unwrap(),
        SEVENS_KEY
    );
    assert!(encode_public_key(vec![4; 65]).is_err());
}

#[test]
fn high_s_signatures_are_normalized() {
    // 规整前后是同一个签名：r 相同，s 互补。
    let low = signature(APPROVAL_DER_LOW_S).unwrap().to_bytes();
    let high = signature(APPROVAL_DER_HIGH_S).unwrap().to_bytes();
    assert_eq!(low.to_vec(), high.to_vec());
    assert_eq!(low.to_vec(), APPROVAL_RAW.to_vec());
    let mut sub = [0u8; 32];
    sub[31] = 1;
    assert_eq!(sub_be(&ORDER, &sub)[31], 0x50);
}

#[test]
fn pairing_bodies_have_the_documented_wire_format() {
    let response = PairResponseBody {
        nonce: "bm9uY2U".into(),
        phone_key: "a2V5".into(),
        signature: "c2ln".into(),
    };
    assert_eq!(
        serde_json::to_value(&response).unwrap(),
        serde_json::json!({"nonce": "bm9uY2U", "phone_key": "a2V5", "signature": "c2ln"})
    );
    let confirm: PairConfirmBody =
        serde_json::from_str(r#"{"nonce":"bm9uY2U","signature":"c2ln"}"#).unwrap();
    assert_eq!(confirm.signature, "c2ln");
    assert_eq!(confirm.nonce, "bm9uY2U");
}
