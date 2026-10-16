//! S3 兼容的对象存储（8.4）：放产出物的密文（按用户 DEK 加密后才上传）。AWS S3、阿里云 OSS、
//! 腾讯云 COS、MinIO 的 S3 兼容接口都能用。
//!
//! 请求用 AWS Signature V4 签名，正文的 SHA-256 一起签（不用 `UNSIGNED-PAYLOAD`），存储服务能发现传输中被改过的正文。
//! 只用到三个操作：上传（PUT）、下载（GET）、删除（DELETE）。

use std::fmt;
use std::io;
use std::time::Duration;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use hmac::{Hmac, KeyInit, Mac};
use sha2::{Digest, Sha256};

use crate::artifacts::BlobStore;

type HmacSha256 = Hmac<Sha256>;

/// S3 兼容存储的配置。
#[derive(Clone)]
pub struct S3Config {
    /// 服务地址：`https://s3.us-east-1.amazonaws.com`、`https://oss-cn-hangzhou.aliyuncs.com`、
    /// `http://127.0.0.1:9000`（MinIO）之类，不带桶名。
    pub endpoint: String,
    /// 签名用的区域：AWS 是 `us-east-1` 之类；OSS 的 S3 兼容接口是 `oss-cn-hangzhou` 之类。
    pub region: String,
    pub bucket: String,
    /// 对象键的前缀，比如 `prod/`（一个桶给几套环境用时分开）。
    pub prefix: String,
    /// 路径风格（`endpoint/桶/键`，MinIO 常用）；否则虚拟主机风格（`桶.endpoint/键`，AWS、OSS 要求的）。
    pub path_style: bool,
    pub access_key_id: String,
    pub secret_access_key: String,
    /// 单个请求的超时。
    pub timeout: Duration,
}

impl fmt::Debug for S3Config {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("S3Config")
            .field("endpoint", &self.endpoint)
            .field("region", &self.region)
            .field("bucket", &self.bucket)
            .field("prefix", &self.prefix)
            .field("path_style", &self.path_style)
            .field("access_key_id", &self.access_key_id)
            .field("secret_access_key", &"***")
            .finish()
    }
}

pub struct S3BlobStore {
    cfg: S3Config,
    /// `http` 或 `https`。
    scheme: String,
    /// 请求的主机（虚拟主机风格时带桶名），也是签名里的 host。
    host: String,
    /// 路径前缀：路径风格时是 `/桶`，否则为空。
    base_path: String,
    http: reqwest::Client,
}

impl fmt::Debug for S3BlobStore {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("S3BlobStore")
            .field("cfg", &self.cfg)
            .finish_non_exhaustive()
    }
}

impl S3BlobStore {
    pub fn new(cfg: S3Config) -> io::Result<Self> {
        let invalid = |m: String| io::Error::new(io::ErrorKind::InvalidInput, m);
        let (scheme, rest) = cfg
            .endpoint
            .split_once("://")
            .ok_or_else(|| invalid(format!("storage endpoint {:?} has no scheme", cfg.endpoint)))?;
        if scheme != "https" && scheme != "http" {
            return Err(invalid(format!(
                "storage endpoint must be http(s), got {scheme:?}"
            )));
        }
        let authority = rest.trim_end_matches('/');
        // 默认端口不写进 host：HTTP 客户端发的 Host 头里没有它，签名要和 Host 头一致。
        let authority = match scheme {
            "https" => authority.strip_suffix(":443").unwrap_or(authority),
            _ => authority.strip_suffix(":80").unwrap_or(authority),
        };
        if authority.is_empty() || authority.contains(['/', '?', '#', '@']) {
            return Err(invalid(format!(
                "storage endpoint {:?} must be scheme://host[:port]",
                cfg.endpoint
            )));
        }
        // 桶名按 S3 的规则：小写字母、数字、点和连字符，3 到 63 个字符。
        let bucket_ok = (3..=63).contains(&cfg.bucket.len())
            && cfg
                .bucket
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'.' || b == b'-');
        if !bucket_ok {
            return Err(invalid(format!("invalid bucket name {:?}", cfg.bucket)));
        }
        if cfg.region.is_empty() || cfg.access_key_id.is_empty() || cfg.secret_access_key.is_empty()
        {
            return Err(invalid(
                "storage needs a region and an access key".to_owned(),
            ));
        }
        let (host, base_path) = if cfg.path_style {
            (authority.to_owned(), format!("/{}", cfg.bucket))
        } else {
            (format!("{}.{authority}", cfg.bucket), String::new())
        };
        let http = reqwest::Client::builder()
            .timeout(cfg.timeout)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(io::Error::other)?;
        Ok(Self {
            scheme: scheme.to_owned(),
            host,
            base_path,
            http,
            cfg,
        })
    }

    /// 对象在桶里的路径（已编码），比如 `/prod/artifacts/ab/cd`。
    fn object_path(&self, key: &str) -> String {
        let full = format!("{}{key}", self.cfg.prefix);
        format!("{}/{}", self.base_path, uri_encode_path(&full))
    }

    async fn send(
        &self,
        method: reqwest::Method,
        key: &str,
        body: Option<&[u8]>,
    ) -> io::Result<reqwest::Response> {
        let path = self.object_path(key);
        let payload: [u8; 32] = Sha256::digest(body.unwrap_or_default()).into();
        let payload = hex(&payload);
        let amz_date = Utc::now().format("%Y%m%dT%H%M%SZ").to_string();
        let mut headers = vec![
            ("host".to_owned(), self.host.clone()),
            ("x-amz-content-sha256".to_owned(), payload.clone()),
            ("x-amz-date".to_owned(), amz_date.clone()),
        ];
        let auth = authorization(
            &Credentials {
                access_key_id: &self.cfg.access_key_id,
                secret_access_key: &self.cfg.secret_access_key,
                region: &self.cfg.region,
            },
            method.as_str(),
            &path,
            &mut headers,
            &payload,
            &amz_date,
        );
        let url = format!("{}://{}{path}", self.scheme, self.host);
        let mut req = self
            .http
            .request(method, url)
            .header("x-amz-content-sha256", payload)
            .header("x-amz-date", amz_date)
            .header("authorization", auth);
        if let Some(b) = body {
            req = req.body(b.to_vec());
        }
        req.send().await.map_err(io::Error::other)
    }
}

/// 存储服务的错误：状态码加上响应里的错误码（S3 的 `<Code>`），不带别的内容。
async fn failure(op: &str, resp: reqwest::Response) -> io::Error {
    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    let code = body
        .split_once("<Code>")
        .and_then(|(_, rest)| rest.split_once("</Code>"))
        .map(|(code, _)| code.chars().take(64).collect::<String>())
        .unwrap_or_default();
    io::Error::other(format!("storage {op} failed: {status} {code}"))
}

#[async_trait]
impl BlobStore for S3BlobStore {
    async fn put(&self, key: &str, bytes: &[u8]) -> io::Result<()> {
        let resp = self.send(reqwest::Method::PUT, key, Some(bytes)).await?;
        if resp.status().is_success() {
            Ok(())
        } else {
            Err(failure("put", resp).await)
        }
    }

    async fn get(&self, key: &str) -> io::Result<Vec<u8>> {
        let resp = self.send(reqwest::Method::GET, key, None).await?;
        match resp.status().as_u16() {
            200 => Ok(resp.bytes().await.map_err(io::Error::other)?.to_vec()),
            404 => Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("no such object {key}"),
            )),
            _ => Err(failure("get", resp).await),
        }
    }

    async fn delete(&self, key: &str) -> io::Result<()> {
        let resp = self.send(reqwest::Method::DELETE, key, None).await?;
        match resp.status().as_u16() {
            200 | 204 | 404 => Ok(()),
            _ => Err(failure("delete", resp).await),
        }
    }
}

/// 签名用的访问密钥和区域。
pub struct Credentials<'a> {
    pub access_key_id: &'a str,
    pub secret_access_key: &'a str,
    pub region: &'a str,
}

/// AWS Signature V4 的 Authorization 头（S3，不带查询参数）。`headers` 是要签的请求头，
/// 名字小写、必须有 host；`path` 是已编码的路径；`amz_date` 形如 `20130524T000000Z`。
/// 公开出来给测试里的假存储服务验签用。
pub fn authorization(
    creds: &Credentials<'_>,
    method: &str,
    path: &str,
    headers: &mut [(String, String)],
    payload_sha256: &str,
    amz_date: &str,
) -> String {
    headers.sort();
    let signed = headers
        .iter()
        .map(|(k, _)| k.as_str())
        .collect::<Vec<_>>()
        .join(";");
    let canonical_headers: String = headers
        .iter()
        .map(|(k, v)| format!("{k}:{}\n", v.trim()))
        .collect();
    let canonical = format!("{method}\n{path}\n\n{canonical_headers}\n{signed}\n{payload_sha256}");
    let date = &amz_date[..8.min(amz_date.len())];
    let scope = format!("{date}/{}/s3/aws4_request", creds.region);
    let digest: [u8; 32] = Sha256::digest(canonical.as_bytes()).into();
    let to_sign = format!("AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{}", hex(&digest));
    let mut key = hmac(
        format!("AWS4{}", creds.secret_access_key).as_bytes(),
        date.as_bytes(),
    );
    for part in [creds.region, "s3", "aws4_request"] {
        key = hmac(&key, part.as_bytes());
    }
    let signature = hex(&hmac(&key, to_sign.as_bytes()));
    format!(
        "AWS4-HMAC-SHA256 Credential={}/{scope}, SignedHeaders={signed}, Signature={signature}",
        creds.access_key_id
    )
}

fn hmac(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut mac = HmacSha256::new_from_slice(key).expect("hmac accepts any key length");
    mac.update(data);
    mac.finalize().into_bytes().into()
}

fn hex(bytes: &[u8]) -> String {
    use fmt::Write;
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        let _ = write!(s, "{b:02x}");
    }
    s
}

/// S3 的路径编码：除了不保留字符（字母、数字、`-_.~`）和 `/`，每个字节都编码成 `%XX`（大写）。
fn uri_encode_path(path: &str) -> String {
    use fmt::Write;
    let mut out = String::with_capacity(path.len());
    for b in path.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~' | b'/') {
            out.push(b as char);
        } else {
            let _ = write!(out, "%{b:02X}");
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const AKID: &str = "AKIAIOSFODNN7EXAMPLE";
    const SECRET: &str = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";

    fn creds() -> Credentials<'static> {
        Credentials {
            access_key_id: AKID,
            secret_access_key: SECRET,
            region: "us-east-1",
        }
    }

    fn header(k: &str, v: &str) -> (String, String) {
        (k.to_owned(), v.to_owned())
    }

    /// AWS 文档里的签名示例（Signature V4，单块正文）：GET 带 Range，PUT 带 Date 和存储类型。
    #[test]
    fn signatures_match_the_aws_examples() {
        let empty = hex(&<[u8; 32]>::from(Sha256::digest(b"")));
        let mut headers = vec![
            header("x-amz-date", "20130524T000000Z"),
            header("host", "examplebucket.s3.amazonaws.com"),
            header("range", "bytes=0-9"),
            header("x-amz-content-sha256", &empty),
        ];
        let auth = authorization(
            &creds(),
            "GET",
            "/test.txt",
            &mut headers,
            &empty,
            "20130524T000000Z",
        );
        assert_eq!(
            auth,
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, \
             SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, \
             Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
        );

        let body = hex(&<[u8; 32]>::from(Sha256::digest(b"Welcome to Amazon S3.")));
        assert_eq!(
            body,
            "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"
        );
        let mut headers = vec![
            header("host", "examplebucket.s3.amazonaws.com"),
            header("date", "Fri, 24 May 2013 00:00:00 GMT"),
            header("x-amz-date", "20130524T000000Z"),
            header("x-amz-storage-class", "REDUCED_REDUNDANCY"),
            header("x-amz-content-sha256", &body),
        ];
        let auth = authorization(
            &creds(),
            "PUT",
            &format!("/{}", uri_encode_path("test$file.text")),
            &mut headers,
            &body,
            "20130524T000000Z",
        );
        assert!(
            auth.ends_with(
                "SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class, \
                 Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
            ),
            "{auth}"
        );
    }

    fn cfg(endpoint: &str, path_style: bool) -> S3Config {
        S3Config {
            endpoint: endpoint.into(),
            region: "oss-cn-hangzhou".into(),
            bucket: "thinktin-artifacts".into(),
            prefix: "prod/".into(),
            path_style,
            access_key_id: AKID.into(),
            secret_access_key: SECRET.into(),
            timeout: Duration::from_secs(5),
        }
    }

    #[test]
    fn addressing_styles_and_validation() {
        let s = S3BlobStore::new(cfg("https://oss-cn-hangzhou.aliyuncs.com", false)).unwrap();
        assert_eq!(s.host, "thinktin-artifacts.oss-cn-hangzhou.aliyuncs.com");
        assert_eq!(s.object_path("a/b c"), "/prod/a/b%20c");
        let s = S3BlobStore::new(cfg("http://127.0.0.1:9000/", true)).unwrap();
        assert_eq!(s.host, "127.0.0.1:9000");
        assert_eq!(s.object_path("x"), "/thinktin-artifacts/prod/x");
        assert!(
            !format!("{s:?}").contains(SECRET),
            "the secret is not printed"
        );
        for bad in [
            "oss-cn-hangzhou.aliyuncs.com",
            "ftp://host",
            "https://host/path",
            "https://user@host",
        ] {
            assert!(S3BlobStore::new(cfg(bad, false)).is_err(), "{bad}");
        }
        let mut c = cfg("https://s3.amazonaws.com", false);
        c.bucket = "Bad_Bucket".into();
        assert!(S3BlobStore::new(c).is_err());
        assert_eq!(uri_encode_path("ab/中~"), "ab/%E4%B8%AD~");
    }
}
