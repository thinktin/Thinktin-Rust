# 东京服务机部署脚本的对抗评审

脚本作者：workflow wf_1699bd4c-2ca（作者 agent，提交 53e3a4b…55785a1）。评审分两轮：

- 第一轮（同一个 workflow，2026-11-11 07:06–13:20 UTC）：“机密和运维”角度的评审做完了，找出 S1–S6；“能不能起来”角度的评审和六个核实都因为额度用完失败了。
- 第二轮（workflow wf_dcedaa01-74d，14:15 UTC 起）：三个角度重新评审（配置和机密、06 在这台机器上能不能起来、每条真实请求从头到尾），逐条核实 S2–S6 和新发现，修确认的问题，再评审修改。

## Caddy 日志实测（S1，主会话 14:05 UTC 在服务机上做）

在服务机的 Caddy 2.6.2 上起临时实例（只听 127.0.0.1，上游不通，返回 502），请求头里放假值：

- 不加日志设置：`http.log.error` 那一行带了 `X-API-KEY`、`X-Access-Token` 的值和请求路径。**S1 成立。**
- 全局 `log { format filter { wrap json; fields { request>headers>X-Api-Key delete; request>headers>X-Access-Token delete; request>uri delete } } }`：校验通过，错误行还在，三个假值都没有了。修法用这个。
- 全局 `log { exclude http.log.error }`：校验通过，错误行整条没了。
- 正式 Caddy 的日志里提到 `X-Api-Key` / `X-Access-Token` 的行数是 0（只数行数，没打印），管理密钥还没漏过。

## 第一轮“机密和运维”评审的发现（原文）

### S1（medium）Caddy's error log writes the sandbox-manager admin key (X-API-KEY) into the journal, and the kit's own hints tell the operator to dump that journal through Cloud Assistant

位置：`deploy/aliyun/machine/03-k3s-caddy.sh:205`

情形：The Caddyfile written at 03:179-219 has no log filtering. Even with no `log` directive, Caddy 2.6 emits an `http.log.error` entry for every request a handler fails with 5xx (reverse_proxy dial failure -> 502). That entry contains the whole request object with all headers; only Cookie, Set-Cookie, Authorization and Proxy-Authorization are redacted. The worker and the kit's own probe (common.sh:206-233) send the admin key as `X-API-KEY` (crates/sandbox/src/acs.rs:36), and data-plane calls send the per-sandbox `X-Access-Token` (envd.rs:101).

So in exactly the incident the kit plans for (sandbox-manager Pod IP changed, 7788 answers 502), every worker request and every `06-deploy.sh --status` / `sandbox-upstream.sh` probe writes the admin key in clear text into the Caddy journal. The kit then points the operator at that journal:
- 03:253 `journalctl -u caddy -n 30 看原因`
- sandbox-upstream.sh:103 `journalctl -u caddy -n 20 看原因`
- README.md:240 and 249

Run as hinted via `run.sh ecs --run`, the key lands in the cloud session output and Cloud Assistant's invocation history. The automated prints at 03:246 and 03:266 and the README command are cut at 300 columns, which usually (not always) stops just before the headers; the two unbounded hints do not.

The same mechanism logs `uri` for api.thinktin.si whenever the API pod is unreachable, i.e. `/v1/webhooks/{token}`. That defeats the stated intent at 03:188 (no access log because paths may carry webhook tokens).

Not tested against a real Caddy here; this is from Caddy 2.6 behaviour as I know it.

建议：Add log filtering to the global options block of the generated Caddyfile (03:180-185), for example:

log {
	format filter {
		wrap json
		fields {
			request>headers>X-Api-Key delete
			request>headers>X-Access-Token delete
			request>uri delete
		}
	}
}

A blunter alternative is `log { exclude http.log.error }`. Either way 03's existing `caddy validate` step will reject it safely if Ubuntu's 2.6.2 does not accept the syntax.

Also change every `journalctl -u caddy` hint (03:253, sandbox-upstream.sh:98/103, README:240/249) to a form that cannot print headers, e.g. `journalctl -u caddy -n 30 --no-pager -o cat | grep -v '"request"' | cut -c1-200`.

If the machine has already run with the unfiltered config while the upstream was down, treat the admin key as having been logged.

### S2（medium）README tells the user to read review.code and back up kms.key / gen-secrets.txt with Cloud Assistant `cat`, which stores the values in the invocation history

位置：`deploy/aliyun/machine/README.md:175`

情形：README:175-176 says the user reads the review code by running `cat /opt/thinktin/secrets/review.code` in the console's Cloud Assistant. README:161-163 says the backup of `kms.key` and `gen-secrets.txt` is read out with 云助手或 Workbench. needs_from_main_session items 5 and 7 repeat this.

Cloud Assistant output from the console is the same invocation-result store the kit otherwise keeps secrets out of. It is retained for weeks and is readable through DescribeInvocations / DescribeInvocationResults by any RAM identity with ECS access, including the AccessKey in the cloud session's environment (ecs.py calls exactly that API).

Following the README, the local KMS master key, both token signing seeds, the code pepper and all four database passwords end up in a shared, API-readable log. "不经过聊天" holds; "不进日志" (README:145) does not. For review.code alone the impact is small (one shared test account). For kms.key and gen-secrets.txt it is everything.

建议：In README sections 6 and 7 and the handoff notes, say explicitly: never `cat` these files through Cloud Assistant's run-command, from the console or from `run.sh ecs --run`.

- Use the interactive terminal instead (Workbench / 会话管理 Session Manager, which needs no port 22 or password); its output is not kept in invocation results.
- If only run-command is available, emit ciphertext only, e.g. `openssl pkeyutl -encrypt -pubin -inkey <user's public key>` or `age -r <recipient>` over kms.key and gen-secrets.txt.
- For the review code, the cleaner path is the one 05 already supports: the user types their own 6 digits into /opt/thinktin/secrets/review.code from that interactive terminal before running 05.

### S3（low）05 echoes kubectl apply's error text for Secrets; a failed update prints the patch with base64 secret values

位置：`deploy/aliyun/machine/05-secrets.sh:181`

情形：`apply_from_env_file` (05:177-187) captures `kubectl apply -f - 2>&1` and on failure prints `${result:0:200}`.

When the Secret already exists and a value changed (sms.env added later, OSS key rotated, DATABASE_URL after a password sync, review code removed) and the PATCH fails (API server timeout or restart on the loaded 2-vCPU node, conflict retries exhausted), kubectl's error is `error when applying patch:\n{"data":{"<first changed key>":"<base64>",...` followed by the last-applied annotation. I confirmed the format string `applying patch:\n%s\nto:\n%v\nfor:` is in the kubectl v1.36.5 binary.

The first 200 characters therefore carry the base64 (trivially decodable) of the first changed key or keys: the SMS AccessKey ID plus part of its secret, the S3 key, or a DATABASE_URL including the database password. This goes to stdout, hence to Cloud Assistant and the cloud session.

Not triggered on first creation (create errors carry no patch) or on unchanged re-runs.

建议：Never print kubectl's raw error for `kind=secret`. On failure print a fixed message plus only a safe fragment, for example the text after the last `for: "STDIN": `, or just the `Error from server (Reason)` class extracted with `grep -o`. The ConfigMap branch can keep the current behaviour.

### S4（low）05 (and 04) silently regenerate kms.key / gen-secrets.txt when the file is missing, even though the cluster Secret and database already depend on the old values

位置：`deploy/aliyun/machine/05-secrets.sh:47`

情形：`ensure_kms_key` (05:46-54) and `gen_secrets_once` (common.sh:150-176) use "file exists and is non-empty" as the only guard. Nothing in the normal run order removes these files, so this needs an outside cause: a mistaken rm, a restore of /opt without the secrets directory, or a directory `--push` onto /opt/thinktin/secrets (ecs.py does `rm -rf` on the remote path first).

If kms.key is gone when 05 is re-run (README section 3 tells the operator to re-run 05 for any key-file change):
- 05 prints one `[已生成]` line and creates a new key.
- It then overwrites `THINKTIN_KMS_KEY` in Secrets thinktin-api, thinktin-worker and thinktin-llm-gw, which were the last surviving copies of the old key.
- The next 06 rolls it out. Every stored user key, artifact and workspace archive is permanently undecryptable.

The same path for gen-secrets.txt replaces both token seeds and writes DATABASE_URLs whose passwords no longer match the roles. That one is recoverable with SYNC_PASSWORDS=1, but it is an outage and invalidates all tokens.

建议：Before generating, check for existing dependants and refuse.

- In 05: if `k -n thinktin get secret thinktin-api` exists (go-template test on `.data.THINKTIN_KMS_KEY`, as 06:393 does for the review code) and kms.key is missing, die with instructions to restore the file from the Secret on the machine: `k get secret ... -o go-template='{{index .data "THINKTIN_KMS_KEY" | base64decode}}' > kms.key` under umask 077, never printed.
- In `gen_secrets_once`: if gen-secrets.txt is missing but role thinktin_owner already exists in Postgres (04) or Secret thinktin-api exists (05), refuse unless an explicit override such as `REGENERATE_SECRETS=1` is given.

### S5（low）Model gateway metrics listen on the host's 0.0.0.0:9090 with no auth; only the security group keeps the VPC and internet out

位置：`deploy/k8s/overlays/tokyo/kustomization.yaml:70`

情形：The Tokyo overlay puts thinktin-llm-gw on hostNetwork but keeps the base argument `--metrics-listen=0.0.0.0:9090` (deploy/k8s/base/workloads/llm-gw.yaml:50; rendered bundle line 307). After 06 the service machine itself listens on 172.16.0.168:9090, which is also the address the public IP maps to, serving `/metrics` unauthenticated.

For 7788 the kit adds a bind plus a remote_ip ACL, and for 5432 it adds pg_hba. For 9090 there is nothing behind the security group. Any later SG change (a widened VPC rule, a temporary debugging rule) exposes version, traffic and egress counters to the VPC or the internet. Nothing scrapes it on this single node.

建议：In the llm-gw patch of overlays/tokyo/kustomization.yaml add:

- op: replace
  path: /spec/template/spec/containers/0/args/2
  value: --metrics-listen=127.0.0.1:9090

Index 2 is the base's metrics argument. Alternatively drop the flag for Tokyo. Re-render with `bundle.sh tokyo` and check the arg list.

### S6（low）pg_hba.conf is rewritten in place (truncate, then write); a full system disk or a kill at that moment leaves it empty or partial

位置：`deploy/aliyun/machine/04-database.sh:159`

情形：04:157-160 does `printf '%s\n' "$new" > "$hba"`. /etc is on the 40 GB system disk that the kit itself warns about filling (docker build cache, imported images, the worker's 10Gi emptyDir).

If that write hits ENOSPC, or the script is killed between truncate and write, pg_hba.conf is left empty or cut off and `set -e` aborts. The running Postgres keeps its in-memory rules, so nothing looks wrong. At the next restart or reboot it refuses to start (no hba entries) or starts without the thinktin lines, and every service loses the database until someone restores `pg_hba.conf.before-thinktin` by hand.

Only reachable when the block actually changes: first run, or after a manual edit.

建议：Write to `$hba.new` in the same directory, copy owner and mode (`chown --reference="$hba" "$hba.new"; chmod --reference="$hba" "$hba.new"`), then `mv -f "$hba.new" "$hba"`. That is the same write-then-rename pattern 03 already uses for the Caddyfile and 05 for the key files.

### 评审查过、没发现问题的地方

Scope: read all of common.sh, 03, 04, 05, 06, sandbox-upstream.sh, README.md, run.sh, ecs.py (push/invoke), the Tokyo overlay, server.toml, tokyo/migrate, bundle.sh, the base llm-gw/api/services/migrate manifests, secrets.rs, the review-code checks in config.rs and auth/service.rs, the header code in sandbox acs.rs/envd.rs, and the 01/02 scripts. No files edited; nothing run against the cloud, the machine, a cluster or docker. Tree is clean.

Local checks I ran:
- `bash -n` on every machine script, bundle.sh and run.sh: clean.
- `bundle.sh tokyo thinktin.local/tokyo 0.1.0-tokyo.b1309ba` with target/bin/kubectl (sha256 33bc88a2… matches): renders, 4 x `imagePullPolicy: Never`, no Secret objects, static ClusterIPs 10.43.0.80/.81.
- Re-downloaded the k3s v1.36.6+k3s1 `sha256sum-amd64.txt` and `install.sh`: both match the two pins in 03. Read install.sh: with `env -i` and SKIP_DOWNLOAD it writes no token or env into the unit.
- Scanned the kit's commits for secret-looking strings: none.
- `.gitignore` covers `target`, so target/thinktin-secrets stays out of git and autosave.

Looked for and found no defect:
- **Secrets on stdout or in ps:** none in the normal run order. Passwords reach psql via stdin `\set` with statement logging disabled for the session; pgpass, curl -K and env files are mktemp 0600 under /run; Secrets are created with `--from-env-file`; `crictl inspect` output (which contains env) is only piped through a pid-extracting sed; outputs list key names and file modes only.
- **File modes:** /opt/thinktin/secrets 0700, files 0600, .new files under umask 077, render dir 0700, k3s kubeconfig 0600. sandbox.json and the ACS kubeconfig are 0600 locally and 05 tightens their directory.
- **Idempotency:** gen-secrets.txt, kms.key and review.code are generated once via temp file, validation, then mv; roles use CREATE … WHERE NOT EXISTS; passwords change only with SYNC_PASSWORDS=1; the pg_hba block rewrite and k3s config are stable on re-run; Caddy keeps its certificates, so re-running 03 does not re-issue (no Let's Encrypt rate-limit exposure).
- **Review code:** CSPRNG, same rule as `check_review_code`, never logged by the server ("review account code issued (no SMS)" carries no code).
- **Network:**
  - Postgres listens on localhost and 172.16.0.168 only; pg_hba admits only 10.42.0.0/16 and 172.16.0.168/32, database thinktin, the four logins, scram. Sandbox and public sources are rejected even if the SG opened.
  - 7788 is bound to 172.16.0.168 with a remote_ip ACL, and `respond` is ordered before `reverse_proxy`.
  - The relay exposes only /v1/connect, /healthz and /readyz; the API has no internal routes on its service port.
  - The llm-gw egress proxy refuses private and loopback targets, so the hostNetwork pod is not a pivot to 5432, 2019 or 7788.
  - k3s 6443 and 10250 listen on all addresses and rely on the security group plus their own authentication.
  - Caddy's admin API stays at the default localhost:2019: not network-reachable, but reachable from the hostNetwork llm-gw container.
- **Host header:** ACS uses path routing (`/kruise/<id>/49983`), so the `header_up Host` rewrite does not break the data plane.

Not verified:
- The Caddyfile against a real Caddy 2.6.2. I did not attempt the download the author reported as blocked.
- S1 rests on Caddy's http.log.error behaviour as I know it, not on a test.
- Docker/k3s iptables coexistence, OSS signing, and anything else that needs the real machine.

Outside the kit:
- HEAD is now 6ca6de1 (`oss.py --service-key`, added after the author's report). It writes target/thinktin-secrets/oss.env 0600 without printing the key; I did not review it further.
- `ecs.py --push` writes chunk files to /tmp with mode 0644 for a few seconds and leaves the pushed content in Cloud Assistant's command history. The author already notes the latter for oss.env.
- `docker run … gen-secrets` output passes through docker's json-file log until `--rm` removes the container; `--log-driver none` would avoid that.

