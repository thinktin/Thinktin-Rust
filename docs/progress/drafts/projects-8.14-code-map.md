# 8.14 代码地图（原始结果，2026-11-04）

workflow `projects-8-14-plan` 第一步：3 路读代码（手机号和短信、接口和 FFI、worker 事务）。英文原样。

## Map: auth-sms

Findings for 8.14 (read-only; no files changed). Branch `claude/determined-lovelace-vn0j5h` @ e070d18.

## 1. Phone numbers
- `auth::secrets::normalize_phone` turns input into E.164. It strips spaces, `-` and parentheses. An 11-digit number starting with 1 becomes `+86`. Valid length is 8–15 digits, and `+0…` is rejected: `crates/auth/src/secrets.rs:25-47`. Every phone entry point calls it (`service.rs:250,349`, `server/src/admin.rs:20`).
- Schema: `users.phone text NOT NULL` (`migrations/0001_init.sql:31`). The partial unique index `users_phone_live ... WHERE status <> 'deleted'` (`0001:39`) lets a number register again after the account is erased.
- Lookup by phone (worker role only, because login happens before any tenant exists; `store/src/users.rs:1`):
  - `user_by_phone` excludes deleted accounts but returns frozen ones (`users.rs:67-78`).
  - `upsert_user_by_phone` (`users.rs:39-65`).
  - Other callers: `server/src/admin.rs:15-28` and the search alert (`orchestrator/src/search.rs:149-154`).
- There is no change-phone flow. `CodePurpose::ChangePhone` exists (`auth/src/sms.rs:14`), but no route uses it (`docs/ios-packages.md:142`). A plaintext `invitee_phone` therefore stays matched to `users.phone` until the account is erased.
- Phone exposure:
  - `proto::domain::User` includes `phone` (`proto/src/domain.rs:474-484`). It must not be reused as the creator or member type in an invite preview.
  - `display_name` can be null (`0001:32`).
  - `mask_phone` exists only in `server/src/admin.rs:222-232`, not in a shared crate.

## 2. Login codes
- Generation: 6 digits by rejection sampling over `getrandom` (`secrets.rs:49-60`). TTL is 5 minutes and a code allows 5 attempts (`secrets.rs:15,17`).
- Hash: `HMAC-SHA256(pepper, len‖purpose ‖ len‖phone ‖ len‖code)` (`secrets.rs:62-71`). Verification is constant-time with `subtle::ct_eq` (`secrets.rs:73-76`).
- The pepper is the private field `AuthService.pepper` (`service.rs:162`). It must be at least 32 bytes (`service.rs:220-224`) and comes from `THINKTIN_CODE_PEPPER` (`server/src/config.rs:176-177`, `server/src/api.rs:47-55`). It has no public accessor.
- Table `login_codes`: phone, purpose, code_hash, attempts, expires_at, consumed_at (`0001:42-52`).
- Send flow (`service.rs:248-296`):
  - worker transaction, `lock_phone` (`pg_advisory_xact_lock(hashtextextended('phone:'||phone,0))`, `store/src/sessions.rs:72-79`);
  - resend interval 60s and 10 per phone per 24h (`service.rs:44-45,254-266`);
  - insert a new code and void the older ones (`sessions.rs:92-120`);
  - commit, then send the SMS (`service.rs:292-294`).
  - It behaves the same whether or not the number is registered (`service.rs:248`). The only exception is the review account branch, which calls `user_by_phone` and sends no SMS (`service.rs:267-291`).
- The per-phone count `login_code_stats` does not filter by purpose (`sessions.rs:82-90`). All purposes share the 10-per-day budget.
- Check flow: `active_login_code ... FOR UPDATE` (`sessions.rs:122-147`), then `fail_login_code` with a separate commit so failures count (`service.rs:311-332`, `sessions.rs:150-161`), then `consume_login_code` (`sessions.rs:163-169`).
- Cleanup: the `maintain` job purges codes older than 7 days (`server/src/workers.rs:43,456-466`). That job is also the natural place to sweep expired invites.
- `AuthConfig` cannot be set from config: the server uses `AuthConfig::default()` (`server/src/api.rs:80`).

## 3. SMS sending
- `SmsSender` has a single method, `send_code(phone, code, purpose)` (`auth/src/sms.rs:40-49`). Implementations: `DevConsoleSms` (`sms.rs:51-65`) and `RecordingSms` for tests (`sms.rs:67-104`).
- `AliyunSms` (`auth/src/sms/aliyun.rs`):
  - calls `SendSms` with `TemplateParam {"code": …}` (`aliyun.rs:103-143`);
  - holds exactly one domestic sign and template plus an optional international pair (`aliyun.rs:24-37,52-58`);
  - routes `+86` numbers to the domestic template and other numbers to the international one, or errors if none is configured (`aliyun.rs:84-100`);
  - ignores `purpose` (`aliyun.rs:109`).
- Config `[sms.aliyun]` has only sign name, template code and the international pair (`server/src/config.rs:674-697`). Keys come from env (`config.rs:1036-1037`). Selection order is test hook > Aliyun > dev console (`server/src/api.rs:56-74`).
- An invite SMS is therefore not possible today. It would need a new trait method and template config. Sending it through `send_code` would also use up the invitee's login-code budget (§2).
- Inference, not in the repo: Aliyun approves code and notification templates separately, so an SMS to a non-user needs its own approval.

## 4. Freeze and erase
- Freeze or unfreeze (`orchestrator/src/account.rs:36-87`, CLI `server/src/admin.rs:47-78`): sets status, cancels runs, writes an audit row with actor `operator:<name>` (`account.rs:30-32`), and sends a notice. **It does not touch project membership or invites.**
- A frozen account is rejected at authenticate, refresh and login (`service.rs:499-503,433-435,358-360`).
- `set_user_status` (`users.rs:88-104`).
- `erase_account` (`users.rs:183-242`):
  - first locks the user row `FOR UPDATE` (`users.rs:186-189`);
  - project steps (`users.rs:214-223`): agents leave; projects the user created are deleted; their memberships elsewhere get `left_reason='erased'`; invites are deleted where `inviter_id = $1 OR invitee_id = $1 OR invitee_phone = <their phone>`. This runs before `phone='deleted'` (`users.rs:237`).
  - The delete does **not** cover `accepted_by = $1`.
  - Test: `store/src/tests.rs:1903-1950`.
- `revoke_user_sessions` (`sessions.rs:430-447`).

## 5. Rate limiting
- The gateway `Limiter` is an in-memory token bucket per replica, so the real cap is N× with N replicas (`gateway/src/limits.rs:3-7`).
- `LimitConfig` fields and defaults (`limits.rs:26-75`):

| Field | Default |
|---|---|
| `device_per_minute` | 600 |
| `user_per_minute` | 1200 |
| `anonymous_per_minute` | 120 |
| `codes_per_ip_per_hour` | 60 |
| `signups_per_ip_per_day` | 50 |
| `signups_per_hour` | 5000 |
| `streams_per_user` | 32 |
| `im_tests_per_hour` | 10 |
| `reports_per_hour` | 30 |
| `hook_events_per_minute` | 30 |
| `instances_per_user` | 0 |

- Configured under `[api.limits]` (`server/src/config.rs:139-140`).
- Bucket keys are in `limits.rs:81-93`. Per-user hourly helpers to copy for invites: `im_tests` and `reports` (`limits.rs:165-173`). There is a hash-keyed bucket, `hook([u8;32])` (`limits.rs:216-223`), and a peek that does not consume, `anonymous_exhausted` (`limits.rs:193-214`).
- Every authed request goes through `limits().authed` (`gateway/src/extract.rs:35-36`).
- Login routes call `anonymous`, `codes` and the signup gate (`gateway/src/routes/account.rs:21-31,89-110`).
- Error mapping: `Limited` and `TooManyCodes` become 429 with Retry-After (`gateway/src/error.rs:82-117`).
- Accurate caps live in the database: an advisory lock, then count and insert in the same transaction. Examples:
  - `lock_instance_count` (`store/src/instances.rs:256-266`)
  - `create_im_channel` (`im_channels.rs:166-178`)
  - `post_to_board` (`board.rs:124-129`)
  - `hook_user/` (`hooks.rs:244-247`)
- A daily per-inviter invite cap needs this database pattern; index `project_invites_inviter (inviter_id, created_at)` is already there (`0039:95`).
- The per-project lock suggested in `docs/progress/drafts/projects-8.13-plan.md:724` follows the same pattern.

## 6. Blocking
- Nothing exists in code or migrations. Draft designs: `user_blocks` in `docs/progress/drafts/projects-design-A.md:1000-1006,1017` and `projects-design-C.md:961-972,1013`.
- Under A, blocking flips pending invites to `declined`, and later invites "succeed" but are never delivered.
- The 0039 status check allows only pending, accepted, declined, revoked and expired (`0039:82-83`). There is no `hidden` status, so a silently dropped invite needs a new status or must be filtered at read time.

## 7. What 0039 already gives invites (`0039_projects.sql:73-97`)
- Columns: `kind` phone/link; `invitee_phone` (plaintext E.164); `invitee_id`; `token_hash bytea UNIQUE`; `status`; `expires_at`; `settled_at`; `accepted_by`.
- Checks: phone xor link, `pending ⇔ settled_at IS NULL`, and `accepted ⇒ accepted_by`.
- Indexes: phone and invitee, both with `WHERE status='pending'`.
- No `max_uses` or `uses` columns, which fits single-use links.
- The tenant has no policy or grant on this table, so only the worker can touch it (`0039:212,224-225`).
- The inviter foreign key points to `project_members` (`0039:88`). Leaving only sets `left_at`, so **a pending invite survives the inviter leaving or being removed**. 8.14 has to revoke it explicitly.
- Open question: plaintext phone versus a keyed hash (`projects-8.13-plan.md:780`). Design A used `phone_hash` with the code pepper (`projects-design-A.md:986`).

## 8. Existing token patterns to reuse
- **HookToken, the best fit for link invites** (`secrets.rs:131-169`):
  - format `twh1_` + 32 random bytes in base64url (48 chars);
  - `parse` rejects a bad format without touching the database;
  - stored as SHA-256 and looked up by hash through a unique column (`0030_plan_hooks.sql:9`, `store/src/hooks.rs:205-214`);
  - row lock on use: `lock_hook` (`hooks.rs:219-247`);
  - anonymous-guess handling: `routes/hooks.rs:233-272`.
- **RefreshToken** (`secrets.rs:78-129`): `rtk1.<session id>.<32B>`, SHA-256 stored, constant-time match, rotated on use, reuse detection (`service.rs:418-474`).
- **Signed Ed25519 tokens**, `<prefix>.<kid>.<claims>.<sig>` (`auth/src/signed.rs:1-4`):
  - access token `tta1`, 15 minutes (`access_token.rs:9-11`);
  - `random_jti` is 12 bytes (`signed.rs:177-182`);
  - not suitable when the rule is "stored as hash".
- **Pairing** has no server-side code:
  - the desktop's 32-byte nonce, with TTL capped at 600s (`desktop/src/lib.rs:330-334`, `client-core/src/pairing.rs:30`), is single-use in desktop memory (`desktop/src/lib.rs:844`);
  - QR scheme `thinktin-pair:v1?` (`pairing.rs:28`).
- Deep links use only the custom `thinktin://` scheme (`notify/src/lib.rs:137`). There are no universal or https links.
- Random source everywhere: `getrandom::fill`. Secrets sit in `Zeroizing`.

## 9. Phone invite: SMS or in-app inbox?
- `notify(w, user, notice)` needs a `UserId`: it writes the inbox, then outbox push, then IM (`orchestrator/src/outbox.rs:198-218`). Dedupe is unique on `(user_id, dedupe_key)` (`0003_inbox.sql:10`).
- Subtypes are strings that older clients tolerate (`proto/src/domain.rs:1067-1089`); `PushKind::Info` is the generic kind (`notify/src/lib.rs:38-39`).
- So in-app delivery works only for registered numbers.
- For uniform results, the invite row can be written with `invitee_phone` for every number, and pending invites resolved by phone when listed. This needs no claim at login: there is an index and the phone does not change.
- `Login.new_user` (`service.rs:138`, used at `routes/account.rs:116-123`) is an optional hook for a welcome notice.
- Sending SMS only to non-users would differ by registration state on the invitee's side. It also needs §3's new template.
- `projects-impl.md` item 6 says invite and exit receipts go into the recipient's private inbox.

## 10. Server-derived actor
- `Principal::actor()` returns `user:<device id>` (`service.rs:152-157`); operator actions use `operator:<name>` (`orchestrator/src/account.rs:30-32`).
- Worker audit takes an explicit `Option<UserId>` (`store/src/outbox.rs:121-130`).
- Entry points: `Db::worker` and `Db::tenant` (`store/src/lib.rs:125,142`).
- A `ProjectActor` type does not exist yet.

## Map: gateway-ffi

## Findings for WP 8.14: gateway routes, inbox/push, client-core FFI, and the files new `/v1/projects*` and `/v1/project-invites*` routes would touch

No files were modified. All paths are relative to `/home/user/Thinktin-Rust`.

### 1. How gateway routes are structured

**Registration**
- All routes sit in one chain in `routes::router()` at `crates/gateway/src/routes/mod.rs:29-193`. Each handler module has a `mod x;` line at mod.rs:3-21, and blocks are grouped by WBS comment.
- Teams are at mod.rs:158-169 and inbox at mod.rs:180-184.
- The pattern is `.route("/v1/teams/{id}", get(teams::get).patch(teams::update).delete(teams::delete))`, with action sub-paths like `.route("/v1/team-templates/{id}/adopt", post(...))`.
- `gateway::router(state)` (`lib.rs:104-106`) wires the state. `AppState` derefs to `Inner { db, auth, templates, kms, hub, artifacts, cfg }` (lib.rs:63-101).

**Shared helpers in mod.rs**
- `default_scope` (196-201) gives the scope for new grants.
- `parse_id` (204-206): a bad path id returns 404 `"<what> not found"`.
- `present` (209-215) separates "field missing" from "field null" in PATCH bodies (used at account.rs:167 and credentials.rs:143).
- `check_len(field, value, min, max)` (218-231) counts characters and returns 422.

**Auth extractor**
- `Authed(pub Principal)` is at `extract.rs:15`, with `FromRequestParts` at extract.rs:28-39.
- It reads the bearer token, then `state.auth.authenticate(token)` (extract.rs:34) checks the session on every request through a worker transaction (`auth/src/service.rs:477-508`). A frozen account gives `AccountFrozen` (service.rs:500).
- It then applies the per-device and per-user limit, `state.limits().authed(..)` (extract.rs:36).
- `Principal { user, device, session }` is at service.rs:146-150. `actor()` returns `"user:<device id>"` (service.rs:154-156). This is the server-derived actor that audit rows use.
- `ApiJson<T>` (extract.rs:42-53) turns a JSON parse failure into a 422 `ApiError::invalid`.

**Tenant vs worker transactions**
- `Db::tenant(user)` (`store/src/lib.rs:125-139`) sets role `thinktin_app`, `app.user_id` and a 15s statement timeout.
- `Db::worker()` (lib.rs:142-151) sets `thinktin_worker`, bypasses RLS, and has a 60s timeout.
- Repository methods are attached to `Tx<Tenant>`, `Tx<Worker>` or `Tx<R>`, which gives a compile-time split by role (lib.rs:3-9, 180-212). A dropped `Tx` rolls back.
- **Reads:** `let mut t = s.db.tenant(who.user).await?; …; t.rollback().await?` (`teams.rs:28-33`, `inbox.rs:35-39`).
- **Writes:** `…; t.commit().await?`, returning 201 plus the object (teams.rs:41-52) or 204 (teams.rs:97-107).
- **Multi-step atomic tenant write:** `adopt_template` (teams.rs:184-227) does all of this in one `Tx<Tenant>`:
  - `lock_instance_count`, an advisory lock on `format!("instances/{user}")` (`store/src/instances.rs:259-270`);
  - `control::adopt_in`, which needs a `&mut Tx<Tenant>` (`control/src/lib.rs:216-224`);
  - `create_run_grant`;
  - `create_team`.
- **Worker in handlers:** only 4 places today.
  - `account.rs:279-282` (`set_push`: commit the tenant transaction first, then a separate worker transaction to release the token) and `account.rs:299-302`.
  - `hooks.rs:269-276`: an unlocked worker lookup, which rolls back and counts the anonymous limit on a miss.
  - `hooks.rs:284-291`: a second worker transaction with `lock_hook`, which uses FOR UPDATE with `lock_timeout` and returns `HookLock::Busy` on 55P03 (`store/src/hooks.rs:219-249`). This find → check → lock → re-check flow is the closest precedent for accepting an invite by token.
- **Worker audit:** `w.audit(Some(user), &who.actor(), action, target, &detail)` (`store/src/outbox.rs:121-130`). The tenant version is at outbox.rs:92-101.

**Error mapping** (`gateway/src/error.rs`)

| Source | Maps to |
|---|---|
| `store::Error::NotFound` | 404 |
| `Conflict(m)` | 409 |
| `Invalid(m)` | 422 |
| `InvalidTransition`, `LeaseLost` | 409 |
| Anything else, **including `Forbidden` (Postgres 42501)** | 500, logged via `internal` (error.rs:77) |
| `Limited` | 429 with `Retry-After` (error.rs:111-118, header at 61) |
| `control::InstanceLimit` | 409 `instance_limit` (error.rs:130) |

- `From<store::Error>` is at error.rs:67-80.
- Postgres codes map to store errors in `store/src/error.rs:37-55`: 23505 → Conflict(constraint name); 23503 → Invalid("reference …"); 23514/23502/22P02 → Invalid; 42501 → Forbidden.
- `ErrorCode` values are snake_case (`proto/src/api.rs:36-60`), with HTTP statuses at api.rs:63-75. Quota errors end in `_limit` and return 409 (`is_limit`, api.rs:83-85). A project-cap error would follow that pattern, for example `project_limit`.
- The body is `ErrorBody { code, message, retry_after_secs? }` (api.rs:89-95).
- `API_VERSION` changes only on incompatible changes (api.rs:9-11). New routes and fields do not bump it.

**Pagination**
- Cursor is `before=<id>`; `limit` defaults to 50 and is clamped to 1..=200 (`routes/inbox.rs:29-34`, `board.rs:134-143`, `runs.rs:106-111`).
- Ids are UUIDv7, so ordered by time (`proto/src/domain.rs:18-22`). The store side uses `($1::uuid IS NULL OR id < $1) … ORDER BY id DESC LIMIT $3` (`store/src/inbox.rs:182-201`).

**JSON conventions**
- Lists are wrapped in a named object: `{"teams":[…]}`, `{"templates":[…]}`, `{"items":[…],"unread":n}`, `{"posts":[…]}`.
- A single object is returned bare as the `proto::domain` type.
- Fields are snake_case. Ids are UUID strings and times are RFC 3339 (chrono serde).
- Enums are lowercase strings through the `str_enum!` macro (domain.rs:93-127), which provides `ALL`, `as_str` and `FromStr`.
- Request structs are plain `#[derive(Deserialize)]`; `reports.rs:18` adds `deny_unknown_fields`.
- Consent is an explicit request flag that the server checks. Precedent: `hooks.rs:38-55` returns 422 when `consent` is not true.
- Idempotent create returns 201 when new and 200 when it already existed, and audits only on create (`reports.rs:58-93`).
- One-time secrets are returned once in the create response (`hooks.rs:66-70`).

**Rate limits**
- `Limiter` is an in-memory token bucket **per replica** (`limits.rs:3-4`). `LimitConfig` uses `deny_unknown_fields` (limits.rs:26-55, defaults 57-74) and is configured as `[api.limits]` (`server/src/config.rs:140,166`).
- Per-user hourly buckets work like `reports()`/`im_tests()` (limits.rs:166-173), each with a `Key` variant (limits.rs:81-93).
- A per-day invite cap must be counted in the database under a lock. The index for it already exists: `project_invites_inviter (inviter_id, created_at)` (0039:95). Lock idioms to copy: `lock_phone` (`store/src/sessions.rs:73-79`, Worker) and `instances/{user}` (instances.rs:259-263).

### 2. How inbox items and pushes are created for a user

**Store: inbox**
- `NewInboxItem` (`store/src/inbox.rs:12-30`) has `kind`, `title`, `body`, `instance_id`, `run_id`, `plan_id`, `approval_id`, `dedupe_key`, `ai_generated`, `subtype`, `vault_request_id` and `egress_request_id`.
- `insert_inbox(user, &new)` is on `impl<R> Tx<R>`, so any role can call it (inbox.rs:94-129). It validates `subtype` and uses `ON CONFLICT (user_id, dedupe_key) DO NOTHING`, returning `None` on a duplicate.
- The worker-only `unread_inbox_count` (inbox.rs:169-177) supplies the badge.

**Store: outbox**
- `NewOutboxItem { kind: "push"|"im"|…, payload, dedupe_key, available_at }` (`store/src/outbox.rs:16-24`).
- `Tx<Tenant>::enqueue_outbox(&item)` (outbox.rs:86-89) and `Tx<Worker>::enqueue_outbox(user, &item)` (outbox.rs:105-107).
- `thinktin_app` may INSERT into the outbox but not read it (0001_init.sql:457-476).

**The single entry point**
- `orchestrator::outbox::notify(&mut Tx<Worker>, user, &Notice)` (`orchestrator/src/outbox.rs:201-218`) does four things:
  1. writes the inbox item;
  2. reads the recipient's `user_locale` (`store/src/users.rs:276-285`, any role);
  3. enqueues the push with `push_item` (outbox.rs:88-95);
  4. fans out to IM channels only for `im_event` kinds (outbox.rs:65-76).
- `notify_tenant` (outbox.rs:221-240) is the same in the caller's own tenant transaction. Gateway precedent: `routes/plans.rs:353-358` calls `orchestrator::scheduler::trigger_disabled_notice` and then `notify_tenant`.
- A **cross-user invite notice must use `notify` with a worker transaction**. The tenant variant can only write the caller's own rows.

**`Notice` and push types**
- `Notice` (outbox.rs:100-126) has `kind: PushKind`, title/body, the target ids, `subtype`, `thread_id`, `collapse_id`, `ttl`, `dedupe_key` and `ai_generated`. Builder: `Notice::new(kind, title, body).subtype(..)`. `inbox()` is at 149-164 and `push()` at 173-195. Example: `scheduler.rs:27-38`.
- Title and body are localized `(title, body)` pairs per `Locale` in `orchestrator/src/texts.rs`, for example `trigger_disabled` at 99-116 and `report_handled` at 200-211.
- `notify::PushKind` (`crates/notify/src/lib.rs:22-40`) is RunFinished, RunFailed, Approval, ComputerApproval, VaultRequest, EgressRequest, PlanConfirm, Info, with `as_str` (44-55, the inbox kind) and `category` (58-69, the iOS category).
- The cheapest path is `PushKind::Info` plus new `proto::domain::notice_subtype` constants (domain.rs:1070-1088). `valid_subtype` matches `^[a-z][a-z_]{0,31}$` (domain.rs:1125-1130; database CHECK in 0021).
- A new `PushKind` variant would also need the exhaustive `im_event` match (outbox.rs:65-76), `as_str`/`category`, and an iOS category.

**Gaps for project invites**

| Gap | Where |
|---|---|
| `PushTarget` has no project or invite id | notify `lib.rs:131-143`; per-channel key lists at `apns.rs:138-147`, `fcm.rs:243-251`, `jpush.rs:107-116` |
| `inbox_items` has no `project_id` or invite column | — |
| Inbox foreign keys `(instance_id,user_id)` and `(run_id,user_id)` stop an invitee's item from pointing at the inviter's instance or run | `0001_init.sql:380-381` |
| `inbox_items.kind` has no CHECK (free text) | 0001:375 |

- New fields follow the `#[serde(default, skip_serializing_if = "Option::is_none")]` pattern: `PushTarget` lib.rs:138-142; `proto::InboxItem` domain.rs:1133-1155.
- The 8.13 plan defers `inbox_items.project_id`, filled by a trigger, to 8.15 (`projects-8.13-plan.md:725`). 8.14 has to either add an invite or project column now, or put the ids only into `subtype` and body.
- The client cache stores each `InboxItem` as JSON (`client-core/src/cache.rs:35, 357-372`), so optional serde-default fields are safe there.

### 3. How client-core exposes endpoints through FFI

**Layers**
- `api::Api` holds typed HTTP calls: `send` (`api.rs:616-666`) handles the version header, token refresh and the `WireError` → `ClientError` mapping. Helpers are `json::<T>()` (722-730) and `empty()` (732-735).
- Team methods (api.rs:1722-1818) show the pattern:
  - lists use a local wrapper `#[derive(Deserialize)] struct R { teams: Vec<Team> }`;
  - bodies are built with `json!({...})`;
  - PATCH bodies are a `serde_json::Map` holding only the fields that were given.
- `client::Client` (`client.rs:16-`) wraps Api plus the cache. Only cached resources (inbox, runs, instances, events) pass through it.
- `ffi.rs` holds the UniFFI layer. `ThinktinClient` (`#[derive(uniffi::Object)]`, ffi.rs:1600-1630) runs every call on its own tokio runtime through `self.run(|c| async move {...})`. Exported methods are in the `#[uniffi::export] impl ThinktinClient` block starting at ffi.rs:1632. Team methods are at ffi.rs:2592-2708.

**Conventions** (ffi.rs:1-2 and 21-45)
- Ids are `String`; parameters are named `<thing>_id: String` and parsed with `parse(&x, "team")?`, which gives `ClientError::InvalidArgument`.
- Times are `*_ms: i64` via `ms`/`ms_opt`. Enums are strings via `.as_str()` outbound and `from_enum_str` inbound. Free-form structure goes in `*_json: String`.
- Records are `#[derive(Debug, Clone, uniffi::Record)]` with `From<d::X>` and, for inputs, `TryFrom<Rec> for d::X` (Team at ffi.rs:816-918, InboxItem at 998-1040).
- **New fields on existing records must have `#[uniffi(default = None)]`** (for example ffi.rs:63 and InboxItem 1014-1023). `tools/client-core/ffi_smoke.py` asserts these defaults.
- Tolerant list decoding (skip unknown elements) is `#[serde(deserialize_with = "crate::lenient::vec")]` (`lenient.rs:8-15`).
- Errors use `ClientError` (`error.rs:6-46`). Server errors become `Api { status, code, detail, retry_after_secs }`, where `code` is the raw snake_case `ErrorCode`, so unknown future codes pass through.

**Binding regeneration**
- `tools/client-core/gen-bindings.sh` (lines 14-25) builds the library and runs `uniffi-bindgen` into `target/bindings/{swift,kotlin}`. `uniffi.toml` sets Kotlin package `cn.thinktin.core`.
- The committed Android file is `apps/android/core/src/main/kotlin/cn/thinktin/core/client_core.kt` (13,514 lines, do not hand-edit).
- Regenerate with `apps/android/scripts/sync-core.sh --bindings-only` (it calls gen-bindings.sh, sync-core.sh:98-102). CI enforces it with `sync-core.sh --check` (`.github/workflows/android.yml:59`).
- Commit the regenerated `.kt` on its own, as in `4f4950d` and `c2b8892`. iOS regenerates at build time.
- The app-side adapters `apps/android/data/.../CoreThinktinService.kt` and `apps/apple/ThinktinKit/Sources/ThinktinCoreAdapter/CoreClient.swift` belong to 12.25/13.18.

### 4. Store state 8.14 builds on, and gaps found in the code

**Tables and columns**
- `projects` (0039:15-30): `goal` exists, but tenant grants cover only INSERT(id, creator_id, name) and UPDATE(name, updated_at) (0039:215-216). Setting `goal` needs new column grants.
- `project_members` (0039:32-48):
  - per-(project, owner) `daily_token_limit`/`total_token_limit`, each CHECK > 0 (enforcement is 8.18);
  - `consented_at`, which must be set for `role='member'` (CHECK at 45);
  - `left_reason` in {left, removed, erased};
  - the creator cannot leave (44).
- The share trigger `project_members_share` sets `shared_at` on the first member insert (0039:159-167). After that, every tenant write path returns 409 through `writable_solo` (`projects.rs:203-212`).
- `project_agents` (0039:50-71):
  - foreign key `(project_id,user_id)` → `project_members`, so the member row must exist before its agents;
  - foreign key `(instance_id,user_id)` → `instances`, which enforces ownership but not "not deleted". Check that with `FOR SHARE`, as `check_agents` does (`projects.rs:224-230`);
  - one lead per project (68).
- `project_invites` (0039:74-97):
  - kind is phone (E.164, `invitee_phone`) or link (`token_hash bytea UNIQUE`);
  - status is pending, accepted, declined, revoked or expired;
  - `(status='pending') = (settled_at IS NULL)`, and accepted requires `accepted_by`.
- **`project_invites` has no tenant policy or grant** (0039:212). Every invite read and write, including "invites addressed to me", goes through the worker, filtered by `who.user` and that user's phone (`Tx<Worker>::user`, `users.rs:80-86`; `user_by_phone` 68-78).
- The worker has full DML on all project tables (0039:224-225).

**Tenant visibility for a joined member**
- A member can read their own `project_members` row (0039:190) and their own `project_agents` rows (0039:198), but **not the `projects` row**: `tenant_read` is creator-only (0039:181).
- So `GET /v1/projects` for joined projects needs a worker read until 8.15 member reads.
- `own_project(s)` and `my_project_agents` (`projects.rs:87-125`) are creator-only and own-agents-only. As a result, `GET /v1/teams/{id}` on a shared project shows only the caller's agents.

**What does not exist yet**
- Worker functions in `projects.rs` (its only impl block is `Tx<Tenant>`, line 51).
- A blocks table.
- Invite token type. Copy `HookToken` in `auth/src/secrets.rs:133-169` (prefixed base64url of 32 random bytes, `parse` validates the format, `hash()` is SHA-256) with a new prefix.
- Phone normalization exists: `auth::secrets::normalize_phone` (secrets.rs:26-47).
- The SMS trait only sends codes (`auth/src/sms.rs:32-40`), so invites to unregistered numbers have no SMS path. They can only match the phone later.
- Phone masking for showing the creator: `server/src/admin.rs:222`.

**Project lock**
- Planned key: `pg_advisory_xact_lock(hashtextextended('project/'||id,0))` (plan:724). Existing key style is `format!("instances/{}", user)` (instances.rs:260-263).

**Withdraw, remove and leave helpers**
- `bump_token_epoch` is Worker-only (`instances.rs:658-664`).
- `revoke_instance_grants` (`grants.rs:212-230`, `impl<R>`) revokes **all** of an instance's grants, private ones included. 8.14 needs a project-scoped variant.
- `cancel_instance_runs` is tenant-only (`runs.rs:783`); `cancel_user_runs` is Worker (`runs.rs:835`). Nothing is scoped to a (project, instance) pair. 8.13 never claims project runs, so none are live yet.

**Instance delete**
- `delete_instance` (`instances.rs:384-402`) marks `project_agents` as left inside the tenant transaction. RLS `tenant_update` (0039:203-209) silently skips shared projects. The gateway delete handler (`routes/instances.rs:372-393`) needs an added worker step.

**Account erase**
- `erase_account` (`users.rs:183-243`, project lines 214-222) already handles projects and invites. A new blocks table needs its own DELETE there.

**Joining with a newly adopted agent**
- `control::adopt_in` needs a `Tx<Tenant>`, so "adopt a dedicated agent while joining" cannot share the worker transaction. Adopt first (`POST /v1/instances`, or a tenant transaction), then join in a worker transaction.

**42501**
- 42501 still maps to 500 (error.rs:77). Mapping it to 404 on member paths is scheduled for 8.15.

### 5. Files a new `/v1/projects*` and `/v1/project-invites*` API would touch

| Area | Files |
|---|---|
| **Migration** | New `crates/store/migrations/0047_*.sql`: blocks table, invite-related columns/indexes, tenant column grants for `goal`, optionally `inbox_items` project/invite columns. Linted by `tools/ci/check_migrations.py` (contiguous numbering, `deploy-safe:` notes). |
| **Store** | `crates/store/src/projects.rs` (Worker impl: invite, accept/decline/revoke, join, add/withdraw, leave/remove, caps, blocks), or a new module registered in `store/src/lib.rs:11-38`; re-exports at lib.rs:75; `store/src/inbox.rs` (if inbox columns change); `store/src/users.rs` erase; `store/src/instances.rs` (shared-project retirement); `store/src/grants.rs` and `store/src/runs.rs` (project-scoped revoke/cancel); tests in `store/src/tests.rs` (project tests start at 903, 1056, 1329, 1484) |
| **Proto** | `crates/proto/src/domain.rs`: Project/Invite/Member DTOs, `ProjectRole` and invite status via `str_enum!`, `notice_subtype` constants, optional `InboxItem` fields; `crates/proto/src/api.rs` if adding a `*_limit` `ErrorCode` |
| **Auth** | `crates/auth/src/secrets.rs` (invite token type) |
| **Gateway** | New `crates/gateway/src/routes/projects.rs` (and/or `project_invites.rs`); `routes/mod.rs` (mod line plus `.route` block); `routes/teams.rs` (module doc says shared projects return 409; decide that behavior); `routes/instances.rs:372-393` (worker retirement on delete); `gateway/src/limits.rs` (new `Key` and config field if an in-memory throttle is added); `gateway/src/error.rs` (if new error kinds); `crates/server/src/config.rs:140` (only through `LimitConfig`); tests in `crates/gateway/tests/api.rs` (harness 35-166; precedents `old_team_api_is_backed_by_projects` 2800 and `rate_limits_and_signup_cap` 2938) |
| **Notifications** | `crates/orchestrator/src/texts.rs` (localized invite/join/leave texts); `crates/orchestrator/src/outbox.rs` (`Notice` fields, `inbox()`/`push()`, and `im_event` only if a new `PushKind` is added); `crates/notify/src/lib.rs` (`PushTarget` and, optionally, `PushKind`); `notify/src/apns.rs:138-147`, `fcm.rs:243-251`, `jpush.rs:107-116` and their tests (`apns.rs:420`, `fcm/tests.rs:200`, `jpush.rs:350`) |
| **Background expiry** (optional) | `crates/server/src/workers.rs:457-519` (`maintain` purge chain), or expire lazily with `expires_at > now()` at accept time |
| **Client-core** | `crates/client-core/src/api.rs` (new section after teams, around 1722); `crates/client-core/src/ffi.rs` (Project* records near 816-918, methods after 2708, `InboxItem` additions at 998-1040 with `#[uniffi(default = None)]`); tests in `crates/client-core/tests/client.rs` (precedent `ffi_teams_and_templates` 1641); `tools/client-core/ffi_smoke.py` (record default assertions) |
| **Generated binding** | `apps/android/core/src/main/kotlin/cn/thinktin/core/client_core.kt` via `apps/android/scripts/sync-core.sh --bindings-only`, in its own commit |
| **Docs** | `docs/projects-impl.md` (add an "8.14 做了什么" section), `docs/progress/claude-determined-lovelace-vn0j5h.md`, and a drafts plan following the 8.13 workflow |

## Map: worker-tx

Facts on worker-side flows, with file:line references. Nothing was modified.

## 1. Transaction roles
- `Db::tenant(user)` sets the role to `thinktin_app` and sets `app.user_id`, so RLS applies (`crates/store/src/lib.rs:125-139`). `Db::worker()` sets the role to `thinktin_worker`, which bypasses RLS, has no user identity and a 60s statement timeout (`lib.rs:142-151`, `:91`). `llmgw()` and `relay()` are narrow roles (`lib.rs:154-176`).
- Worker-only methods live on `impl Tx<Worker>`, so the tenant cannot reach them (`lib.rs:8-9`). Methods on `impl<R> Tx<R>` work under both roles; under the tenant, RLS limits them to the caller's own rows.
- Worker methods take an explicit `user: UserId` argument, for example `cancel_user_runs(user,…)` (`runs.rs:835`), `create_run(user,…)` (`runs.rs:880`) and `audit(Some(user),…)` (`outbox.rs:121`). Nothing in the database ties a worker transaction to a user. The code must pass a user it derived itself.

## 2. How gateway handlers reach the worker
- **Almost every authenticated handler uses `s.db.tenant(who.user)` only.** The flows the task called worker-side are in fact tenant-only:
  - egress decide: `instances.rs:304-332`
  - remove egress host: `:247-268`
  - device messages, the phone side of pairing: `device_messages.rs:39,59,79`
  - vault fulfill and decline: `vault.rs:316-460`, tenant at `:332,:358,:447`
  - instance delete: `instances.rs:372-393`
  - run cancel: `runs.rs:185-221`
  - teams: `teams.rs`, all tenant
- **Gateway handlers that open `db.worker()` directly:**
  - `account::set_push` (`account.rs:268-284`) and `set_live_activity_start` (`:288-304`). Each commits a tenant transaction, then opens a **separate** worker transaction (`release_push_token`, which clears the same token on other users' devices, `sessions.rs:209-231`). The two steps are not atomic.
  - `hooks::receive` (`hooks.rs:233-335`) is anonymous. The user comes from the token hash: an unlocked worker lookup, then rollback (`:269-276`), then a second worker transaction with `lock_hook` that creates the run (`:284-334`).
- **Helpers outside the gateway, called with `who` from the handler:**
  - `orchestrator::account::stop_all(&s.db, who.user, &who.actor())` (`account.rs:329-332`, `:343-351`). It runs one worker transaction: cancel runs, revoke grants, pause plans, audit, notify (`orchestrator/src/account.rs:91-112`).
  - `AuthService` uses the worker for code send and check (`lock_phone`), login, refresh, authenticate and erase (`auth/src/service.rs:249-573`).
  - `GrantService::sandbox_token` uses the worker (`auth/src/grants.rs:107-170`).
- **The device relay** runs as its own process on the `relay()` role. It re-checks the session on every heartbeat (`relay/src/conn.rs:269-297`). Its store methods are on `impl Tx<Relay>` (`device_relay.rs:213-408`).

## 3. How the acting user is verified
- The `Authed` extractor reads the bearer token, calls `auth.authenticate`, then applies the per-device and per-user limits (`gateway/src/extract.rs:28-39`).
- `authenticate` (`service.rs:477-510`) checks the token signature and expiry, then reads `session_state` in a worker transaction (`sessions.rs:452-469`). It rejects the request if the session's user or device does not match the token, if the user is frozen or deleted, or if the session is not live.
- `Principal { user, device, session }` and `actor()` produce `"user:<device id>"` (`service.rs:145-157`).
- Other actor strings in use:
  - `"system"` (`service.rs:279,402`)
  - `"operator:<name>"` (`orchestrator/src/account.rs:30-32`)
  - `agent:<instance>`, documented in `0001_init.sql:418`
- Agent tools get a server-built `ToolContext { user, instance, run, plan, grant }` from the claimed run record (`orchestrator/src/executor.rs:958-964`, `shim.rs:69-75`). The ask tool, for example, uses `ctx.user` for its worker transaction (`ask.rs:83-84`).

## 4. Advisory locks in use
All are transaction-scoped `pg_advisory_xact_lock(hashtextextended(key,0))`, released at commit.

| Key | Where |
|---|---|
| `instances/{user}`, then count non-deleted instances (tenant) | `lock_instance_count`, `instances.rs:259-271`; used in `control::adopt_capped` (`control/src/lib.rs:195-212`) and team template adopt (`teams.rs:196`) |
| `phone:{e164}` (worker) | `lock_phone`, `sessions.rs:73-79` |
| `run_waits/{user}` (any role) | `lock_run_waits`, `runs.rs:432-438`; taken before switching `peer_access` off (`gateway/instances.rs:148-160`) and in ask (`ask.rs:84`) |
| `instance_plans/{id}`, exclusive / shared | `plans.rs:24-26,314-318` / `share_instances`, `plans.rs:422-440` |
| `interrupts/{instance}` | `runs.rs:609` |
| `hook_user/{user}`, after `users FOR KEY SHARE` and a 2s `lock_timeout` on the hook row | `hooks.rs:219-249` |
| `board/{user}` | `board.rs:126,196` |
| `im_channels/{user}` | `im_channels.rs:170` |
| `live_activities/{device}`, `live_starts/{user}` | `live_activities.rs:154,293` |
| `artifact:{root}:{name}` | `artifacts.rs:121` |
| global `SEARCH_LOCK` | `search.rs:39` |
| two-key `(hashtext(instance), hashtext(site))` | `egress.rs:378` |

The 8.13 plan fixes the project key as `'project/'||id` (`docs/progress/drafts/projects-8.13-plan.md:724`). No project lock or `ProjectActor` exists in code yet; grep finds no matches.

## 5. Lock-order rules already documented
- **Runs before instances.** Lock runs in id order with `FOR NO KEY UPDATE`, then update `instances.token_epoch`. This matches the executor (`runs.rs:368-372`; `lock_runs_where!`, `runs.rs:358-366`).
- **`cancel_run` uses `NO KEY UPDATE`, not `FOR UPDATE`.** This avoids a deadlock with event foreign-key `KEY SHARE` locks (`runs.rs:526-530`).
- **Advisory lock instead of an instance row lock for deletes.** Deletes then lock plans, triggers and runs; the executor locks runs, then updates the instance row. Queueing on the instance row would form a cycle (`plans.rs:422-425`). `retire_instance_plans` must run before anything else is locked (`plans.rs:305-312`).
- **`erase_account` locks the user row `FOR UPDATE` first** (`users.rs:184-189`). The hook path follows the same order (`hooks.rs:216-223`).
- **The solo-project `check_agents` takes `FOR SHARE` on instance rows** so it serialises with a concurrent delete (`projects.rs:224-230`).

## 6. Audit
- Table `audit_log(user_id, actor, action, target, detail)` (`0001_init.sql:415-424`). The tenant can only INSERT rows with `user_id = app_user_id()` and cannot read them (`0001_init.sql:449`).
- Tenant `audit(actor, action, target, detail)` always writes `self.user()` (`outbox.rs:92-102`). Worker `audit(Some(user), actor, …)` can write for any user (`outbox.rs:121-130`).
- Each row has a single `user_id`. A cross-user action such as "creator removes member" can only be recorded under both users through the worker, as two rows.
- Existing action names include `instance.delete`, `account.stop_all`, `egress.decide`, `grant.revoke` and `auth.delete_account`.
- Receipts to a recipient's private inbox use `orchestrator::outbox::notify(&mut Tx<Worker>, user, &Notice)` (`outbox.rs:201-218`). It writes the inbox row, the push outbox entry and IM fan-out in the same transaction.

## 7. Cancellation and revocation primitives

| Primitive | Role | What it does |
|---|---|---|
| `cancel_run(id)` | Tenant (`runs.rs:526-556`) | Locks the run, `bump_epochs_where!("id = $1")`, sets state to cancelled |
| `cancel_instance_runs(inst, reason)` | **Tenant only** (in `impl Tx<Tenant>` 559-830; `runs.rs:783-828`) | Locks runs, bumps epochs, cancels runs on the instance and on run trees rooted there |
| `cancel_user_runs(user, reason)` | Worker (`runs.rs:835-855`) | Same three steps, keyed by `user_id` |
| `cancel_descendants` | Worker (`runs.rs:1021`) | Cancels a run's children |
| `bump_token_epoch(inst)` | Worker (`instances.rs:658-664`) | Bare `+1`; the executor calls it at the end of every attempt (`executor.rs:1171-1174`) |
| `bump_epochs_where!(filter)` | macro (`runs.rs:345-355`) | Bumps only instances that have a matching agent run in an active or waiting state (at most one per instance) |
| `revoke_run_grant`, `revoke_plan_grants`, `revoke_instance_grants` | any role (`grants.rs:177-230`) | Recursive over `parent_id` |
| `revoke_user_grants(user)` | Worker (`grants.rs:319-329`) | **Not recursive** (`WHERE user_id = $1`). Descendants are still blocked by `ancestors_usable!` (`grants.rs:47-55`), which `touch_run_grant` (`:279-300`) and llm-gw `usable_grant_aliases` (`llmgw.rs:116-120`) both check |
| `pause_user_plans` | Worker (`plans.rs:604`) | Pauses all of the user's plans |

The `lock_runs_where!` and `bump_epochs_where!` macros take `$filter:literal`, so a new filter such as `"project_id = $1 AND instance_id = $2"` has to be a literal passed through `concat!`.

**How a cancellation takes effect:**
- **Executor.** `on_renew` sees `renew_lease` return false (`runs.rs:957-969`). It reads the state, and if the run is `Cancelled` it calls `cancel_turn()` and ends with `Outcome::Cancelled` (`executor.rs:2379-2450`).
- **Sandbox tokens.** Each token carries `ep`. llm-gw rejects the request if `epoch != claims.ep` or the grant is revoked (`llm-gw/src/proxy.rs:404-430`). The directory cache defaults to 5s (`llm-gw/src/main.rs:75-77`).
- **New tokens.** `sandbox_token` refuses revoked or expired grants and deleted or archived instances (`auth/src/grants.rs:107-135`).
- **Open egress or browser tunnels** re-verify the token every 30s and close with `"revoked"` (`egress.rs:113,1969-1993,1776-1790`).
- **The app's event WebSocket** re-runs `authenticate` on heartbeat (`gateway/routes/events.rs:195-202`). It does not check membership.

## 8. Instance delete path
`instances::delete` (`gateway/routes/instances.rs:372-393`) runs one tenant transaction:
1. `instance`
2. `retire_instance_plans`
3. `cancel_instance_runs`
4. `revoke_instance_grants`
5. `delete_instance`
6. `audit("instance.delete")`

`delete_instance` (`instances.rs:384-419`) does the following:
- marks the instance deleted;
- runs `UPDATE project_agents SET is_lead=false, left_at=now() WHERE instance_id=$1 AND left_at IS NULL`;
- deletes the instance's model routes;
- expires its pending egress requests.

Under the tenant, the `project_agents` UPDATE policy USING clause requires `creator_id = app_user_id() AND shared_at IS NULL` (`0039:203-209`). **For a shared project, or another user's project, it silently updates 0 rows**, so the instance stays listed in that project. Project-space runs and grants on the instance are still cancelled and revoked: their rows carry the owner's `user_id`, which the tenant RLS allows (`0001_init.sql:433-439`). Cross-owner descendants (8.17) would not be visible to the tenant. The 8.13 plan records the fix: "`delete_instance` must also retire the instance from *shared* projects via the worker" (`projects-8.13-plan.md:724`).

## 9. Project-specific facts that affect withdraw, leave and remove
- **Project agents are only ever marked.** `project_agents.left_at` (0039:59) has no reason column. `runs_project_agent` is a NO ACTION foreign key (`0045:6-7`), so an agent row cannot be deleted once a project run references it. Grants cascade (`0045:8-9`).
- **Member rows:** `left_at` and `left_reason ∈ {left, removed, erased}` (0039:40-41). The creator cannot leave (`CHECK role='member' OR left_at IS NULL`, 0039:44). A member row needs `consented_at` (0039:45).
- **Shared flag:** inserting a `role='member'` row fires a trigger that sets `projects.shared_at` (0039:158-167). From then on every tenant write policy fails, and the old team writes return 409 (`projects.rs:202-212`).
- **Grants:** the worker has full DML on all project tables. The tenant has no grant or policy on `project_invites` or `project_keys` (0039:212,224-225; test `tests.rs:~1405-1418`).
- **Invite cascade:** `project_invites (project_id, inviter_id)` references `project_members ON DELETE CASCADE` (0039:88). Removing a member only marks the row, so **that member's pending invites survive unless they are explicitly revoked**.
- **No project runs or grants exist yet.** Only the worker may write `project_id`, enforced by `fill_space()` (0040:19-22). Nothing in 8.13 writes it (0040:3). Claim and takeover filter on `project_id IS NULL` (`runs.rs:203-206,884,1005,1304,1437`), and private grant lookups exclude project grants (`grants.rs:141,309`). The run and grant cancellation steps of withdraw and remove in 8.14 will therefore touch 0 rows until 8.17. They are forward-compatible only.
- **Error mapping:** `store::Error::Forbidden` (42501) currently becomes HTTP 500 (`gateway/src/error.rs:67-79`). NotFound maps to 404 and Conflict to 409.
- **Erase pitfall:** `erase_account` runs `DELETE FROM projects WHERE creator_id=$1` (`users.rs:216`). That cascades to other members' `project_agents` and would hit the NO ACTION `runs_project_agent` key once they have project runs. Soft delete is scheduled for 8.15.
- **Rate limiting** is in-memory token buckets per replica (`gateway/src/limits.rs:1-7,135-163`); there is no per-invite key yet. Durable per-phone throttling uses the `lock_phone` and count pattern (`service.rs:249-268`).
- **Hashed-token pattern to reuse:** `HookToken` (`auth/src/secrets.rs:133-168`) is 32 random bytes with a prefix, a parse check before any database query, and `Sha256` storage. Lookup is by hash (`hooks.rs:269-276`).

**Withdraw and remove, drawn from these facts:**
- Run one worker transaction with the actor taken from `Authed`, auditing both users' rows with the worker `audit`.
- Lock order:
  1. project advisory lock
  2. `lock_runs_where!` on (project, instance) runs
  3. `bump_epochs_where!` with the same filter
  4. cancel those runs
  5. revoke grants with `project_id`/`instance_id` filters, recursing over `parent_id`
  6. set `project_agents.left_at` and `is_lead=false`; for a member, also set `project_members.left_at`/`left_reason` and revoke their pending invites
  7. `notify` each recipient
- Avoid instance row locks after run locks (`plans.rs:422-425`).