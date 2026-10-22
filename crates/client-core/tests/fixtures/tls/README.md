# 测试用的 TLS 证书（只给 `tests/tls.rs` 用）

一个测试 CA（`ca.pem`）和它签的 `localhost` / `127.0.0.1` 证书（`localhost.pem`、私钥 `localhost.key`），有效期 100 年。
私钥只用于本地测试，不要用在任何别的地方；CA 的私钥生成后就扔了。重新生成：

```sh
openssl ecparam -name prime256v1 -genkey -noout -out ca.key
openssl req -x509 -new -key ca.key -sha256 -days 36500 -subj "/CN=ThinkTin test CA (tests only)" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -out ca.pem
openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out localhost.key
openssl req -new -key localhost.key -subj "/CN=localhost" -out leaf.csr
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n' > ext
openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 36500 -sha256 -extfile ext -out localhost.pem
rm ca.key ca.srl leaf.csr ext
```

`other-ca.pem` 是另一个不相干的测试 CA（只有证书），用来测“不认识的签发者”。
