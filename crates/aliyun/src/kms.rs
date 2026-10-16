//! 阿里云 KMS（2016-01-20 版的 Encrypt / Decrypt）包裹用户的数据密钥（DEK）：主密钥不出 KMS，
//! 控制面只拿到包裹后的密文。
//!
//! - 加密上下文（EncryptionContext）绑定用户 id：包裹的 DEK 挪到别的用户名下解不开。
//! - 存库的主密钥 id 是 `aliyun:<KeyId>`，换主密钥时 [`keyvault::KmsRing`] 按它找对应的 KMS。
//! - 解开的 DEK 由 [`keyvault::CachingKms`] 在进程里缓存一会儿，不必每次都调 KMS。

use async_trait::async_trait;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use keyvault::{Kms, WrappedKey};
use zeroize::Zeroizing;

use crate::{Error, RpcClient};

/// KMS 接口的版本。
pub const VERSION: &str = "2016-01-20";

const DEK_LEN: usize = 32;

pub struct AliyunKms {
    client: RpcClient,
    key_id: String,
    label: String,
}

impl AliyunKms {
    /// `client` 用 [`VERSION`] 建（接口地址 `https://kms.<地域>.aliyuncs.com`）；`key_id` 是主密钥的
    /// KeyId 或别名（`alias/...`）。
    pub fn new(client: RpcClient, key_id: impl Into<String>) -> Self {
        let key_id = key_id.into();
        Self {
            label: format!("aliyun:{key_id}"),
            client,
            key_id,
        }
    }

    fn context(user: &str) -> String {
        serde_json::json!({ "purpose": "thinktin-dek", "user": user }).to_string()
    }
}

/// 解不开（密文或加密上下文不对）的不细分原因；其余的（网络、权限、限流）报 KMS 不可用。
fn kms_error(e: Error) -> keyvault::Error {
    match e {
        Error::Api { code, .. } if code.starts_with("Rejected") || code.contains("Ciphertext") => {
            keyvault::Error::Decrypt
        }
        e => keyvault::Error::Kms(e.to_string()),
    }
}

#[async_trait]
impl Kms for AliyunKms {
    fn current_key_id(&self) -> &str {
        &self.label
    }

    async fn wrap(&self, dek: &[u8; DEK_LEN], context: &str) -> keyvault::Result<WrappedKey> {
        let plain = Zeroizing::new(STANDARD.encode(dek));
        let reply = self
            .client
            .call(
                "Encrypt",
                &[
                    ("KeyId", self.key_id.clone()),
                    ("Plaintext", plain.as_str().to_owned()),
                    ("EncryptionContext", Self::context(context)),
                ],
            )
            .await
            .map_err(kms_error)?;
        let blob = reply["CiphertextBlob"]
            .as_str()
            .filter(|b| !b.is_empty())
            .ok_or_else(|| keyvault::Error::Kms("Encrypt returned no CiphertextBlob".into()))?;
        Ok(WrappedKey {
            kms_key_id: self.label.clone(),
            ciphertext: blob.as_bytes().to_vec(),
        })
    }

    async fn unwrap(
        &self,
        wrapped: &WrappedKey,
        context: &str,
    ) -> keyvault::Result<Zeroizing<[u8; DEK_LEN]>> {
        if wrapped.kms_key_id != self.label {
            return Err(keyvault::Error::UnknownKmsKey(wrapped.kms_key_id.clone()));
        }
        let blob =
            std::str::from_utf8(&wrapped.ciphertext).map_err(|_| keyvault::Error::Malformed)?;
        let reply = self
            .client
            .call(
                "Decrypt",
                &[
                    ("CiphertextBlob", blob.to_owned()),
                    ("EncryptionContext", Self::context(context)),
                ],
            )
            .await
            .map_err(kms_error)?;
        let plain = reply["Plaintext"]
            .as_str()
            .ok_or_else(|| keyvault::Error::Kms("Decrypt returned no Plaintext".into()))?;
        let bytes = Zeroizing::new(
            STANDARD
                .decode(plain)
                .map_err(|_| keyvault::Error::Malformed)?,
        );
        if bytes.len() != DEK_LEN {
            return Err(keyvault::Error::Malformed);
        }
        let mut dek = Zeroizing::new([0u8; DEK_LEN]);
        dek.copy_from_slice(&bytes);
        Ok(dek)
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use axum::extract::State;
    use axum::http::StatusCode;
    use axum::response::{IntoResponse, Response};
    use keyvault::secrecy::{ExposeSecret, SecretString};
    use keyvault::{CachingKms, KeyVault, KmsRing, LocalKms, MemoryKeyStore};

    use super::*;
    use crate::{parse_form, rpc_signature};

    /// 假的阿里云 KMS：验签名；Encrypt 把（明文、加密上下文）存下、返回一个编号当密文；
    /// Decrypt 按编号取回，加密上下文对不上就拒绝。
    #[derive(Default)]
    struct Fake {
        blobs: Mutex<HashMap<String, (String, String)>>,
        calls: Mutex<Vec<String>>,
    }

    fn reject(status: StatusCode, code: &str) -> Response {
        (
            status,
            axum::Json(serde_json::json!({ "Code": code, "Message": code, "RequestId": "r" })),
        )
            .into_response()
    }

    async fn handler(State(fake): State<Arc<Fake>>, body: String) -> Response {
        let params: HashMap<String, String> = parse_form(&body).into_iter().collect();
        let signed: Vec<(&str, String)> = params
            .iter()
            .filter(|(k, _)| k.as_str() != "Signature")
            .map(|(k, v)| (k.as_str(), v.clone()))
            .collect();
        if rpc_signature("POST", &signed, "kms-secret") != params["Signature"] {
            return reject(StatusCode::BAD_REQUEST, "IncompleteSignature");
        }
        if params["Version"] != VERSION {
            return reject(StatusCode::BAD_REQUEST, "InvalidVersion");
        }
        let action = params["Action"].clone();
        fake.calls.lock().unwrap().push(action.clone());
        let context = params["EncryptionContext"].clone();
        match action.as_str() {
            "Encrypt" => {
                if params["KeyId"] != "alias/thinktin-dek" {
                    return reject(StatusCode::NOT_FOUND, "Forbidden.KeyNotFound");
                }
                let mut blobs = fake.blobs.lock().unwrap();
                let blob = format!("blob-{}", blobs.len() + 1);
                blobs.insert(blob.clone(), (params["Plaintext"].clone(), context));
                axum::Json(serde_json::json!({ "KeyId": "key-1", "CiphertextBlob": blob }))
                    .into_response()
            }
            "Decrypt" => match fake.blobs.lock().unwrap().get(&params["CiphertextBlob"]) {
                Some((plain, ctx)) if *ctx == context => {
                    axum::Json(serde_json::json!({ "KeyId": "key-1", "Plaintext": plain }))
                        .into_response()
                }
                Some(_) => reject(StatusCode::BAD_REQUEST, "Rejected.ValueNotMatch"),
                None => reject(StatusCode::BAD_REQUEST, "InvalidCiphertext"),
            },
            _ => reject(StatusCode::BAD_REQUEST, "InvalidAction.NotFound"),
        }
    }

    async fn setup(secret: &str) -> (AliyunKms, Arc<Fake>) {
        let fake = Arc::new(Fake::default());
        let app = axum::Router::new()
            .route("/", axum::routing::post(handler))
            .with_state(fake.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let client = RpcClient::new(
            format!("http://{addr}"),
            VERSION,
            "kms-id",
            Zeroizing::new(secret.into()),
            Duration::from_secs(5),
        )
        .unwrap();
        (AliyunKms::new(client, "alias/thinktin-dek"), fake)
    }

    #[tokio::test]
    async fn data_keys_round_trip_and_stay_with_their_user() {
        let (kms, fake) = setup("kms-secret").await;
        assert_eq!(kms.current_key_id(), "aliyun:alias/thinktin-dek");
        let wrapped = kms.wrap(&[7; 32], "u1").await.unwrap();
        assert_eq!(wrapped.kms_key_id, "aliyun:alias/thinktin-dek");
        assert_eq!(wrapped.ciphertext, b"blob-1");
        assert_eq!(*kms.unwrap(&wrapped, "u1").await.unwrap(), [7; 32]);
        // 挪到别的用户名下：加密上下文对不上，解不开（不细分原因）。
        assert!(matches!(
            kms.unwrap(&wrapped, "u2").await,
            Err(keyvault::Error::Decrypt)
        ));
        // 别的主密钥包裹的：不发请求，直接报不认识。
        let other = WrappedKey {
            kms_key_id: "local-1".into(),
            ciphertext: b"x".to_vec(),
        };
        let before = fake.calls.lock().unwrap().len();
        assert!(matches!(
            kms.unwrap(&other, "u1").await,
            Err(keyvault::Error::UnknownKmsKey(_))
        ));
        assert_eq!(fake.calls.lock().unwrap().len(), before);
    }

    #[tokio::test]
    async fn the_vault_runs_on_aliyun_kms_with_a_cache_and_older_keys() {
        let (kms, fake) = setup("kms-secret").await;
        // 迁移前用本地主密钥包裹的 DEK。
        let local: Arc<dyn Kms> = Arc::new(LocalKms::new("local-1", &[4; 32]));
        let legacy = local.wrap(&[9; 32], "old-user").await.unwrap();
        let ring: Arc<dyn Kms> = Arc::new(CachingKms::new(
            KmsRing::new(Arc::new(kms)).with_older(local),
            Duration::from_secs(300),
        ));
        assert_eq!(*ring.unwrap(&legacy, "old-user").await.unwrap(), [9; 32]);
        assert!(
            fake.calls.lock().unwrap().is_empty(),
            "local keys stay local"
        );

        // 新用户的 DEK 由阿里云 KMS 包裹，加解密几次只解包一次（缓存）。
        let vault = KeyVault::new(ring, MemoryKeyStore::default());
        vault.create_user_key("u1").await.unwrap();
        let sealed = vault
            .seal(
                "u1",
                "k1",
                &SecretString::from("sk-live-1234567890".to_owned()),
            )
            .await
            .unwrap();
        for _ in 0..3 {
            let opened = vault.open("u1", "k1", &sealed).await.unwrap();
            assert_eq!(opened.expose_secret(), "sk-live-1234567890");
        }
        assert_eq!(*fake.calls.lock().unwrap(), ["Encrypt", "Decrypt"]);
    }

    #[tokio::test]
    async fn kms_failures_are_reported_without_detail_leaks() {
        // 密钥不对：签名对不上，报 KMS 不可用（带阿里云的错误码）。
        let (kms, _) = setup("wrong-secret").await;
        match kms.wrap(&[1; 32], "u1").await {
            Err(keyvault::Error::Kms(m)) => assert!(m.contains("IncompleteSignature"), "{m}"),
            other => panic!("unexpected {other:?}"),
        }
        // 主密钥不存在。
        let (kms, _) = setup("kms-secret").await;
        let kms = AliyunKms::new(kms.client, "alias/missing");
        match kms.wrap(&[1; 32], "u1").await {
            Err(keyvault::Error::Kms(m)) => assert!(m.contains("KeyNotFound"), "{m}"),
            other => panic!("unexpected {other:?}"),
        }
        // 密文坏了。
        let (kms, _) = setup("kms-secret").await;
        let bogus = WrappedKey {
            kms_key_id: "aliyun:alias/thinktin-dek".into(),
            ciphertext: b"blob-404".to_vec(),
        };
        assert!(matches!(
            kms.unwrap(&bogus, "u1").await,
            Err(keyvault::Error::Decrypt)
        ));
    }
}
