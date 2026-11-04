# 8.14 实现方案草稿（原始结果，2026-11-04）

workflow `projects-8-14-plan` 第二步。英文原样。

# WP 8.14 implementation plan: invites and joining (phone and link invites, choosing agents, budgets, consent; adding, withdrawing, leaving, removing; invite limits and blocking)

Branch `claude/determined-lovelace-vn0j5h` @ `e070d18`. Last migration is `0046_validate_run_space_keys.sql`, so this package starts at **0047**. Every file:line below was re-read at HEAD. No files were changed.

---

## 0. Decisions

| # | Decision | Why / evidence |
|---|---|---|
| D1 | **One new migration, `0047_project_invites.sql`, in a single transaction.** Contents: `user_blocks`; `project_invites.suppressed_at` plus indexes; `project_agents.consented_at`; `inbox_items.project_id` and `project_invite_id`; `GRANT INSERT (goal) ON projects TO thinktin_app`. No CONCURRENTLY file is needed. | The project tables are new and empty: no route wrote invites before 8.14 (`0039:73`). The only large table touched is `inbox_items`, and only by a nullable `ADD COLUMN`, which is a catalog-only change. Settled-invite cleanup of inbox items filters on `user_id` (served by `inbox_unread`, `0001:384`), so `inbox_items` needs no new index. |
| D2 | **Every cross-user write goes through `Tx<Worker>`, inside one store method that takes its own locks.** The acting `UserId` always comes from `Authed` (`gateway/src/extract.rs:28-39`) and is never read from the request body. The store builds a crate-private **`ProjectActor`** (project, user, role, creator) from locked and verified rows, inside the same method that uses it. Gateway and orchestrator code can never construct or carry one. | projects-impl item 3. The 8.13 rule is that only the worker writes cross-user rows (`0039:3-4,212,224-225`). The tenant has no policy on `project_invites`, and none is added. |
| D3 | **Global lock order (rule R1):**<br>1. `users` rows `FOR KEY SHARE`, in id order (actor, creator, and any target or recipient)<br>2. project advisory lock `project/{id}` (several projects: in id order)<br>3. narrower advisory keys (`project_invites/{inviter}`, `project_invite_phone/{e164}`, `user_blocks/{user}`)<br>4. `project_invites` row `FOR UPDATE`<br>5. `project_members` rows `FOR NO KEY UPDATE`<br>6. `project_agents` rows `FOR NO KEY UPDATE`<br>7. `runs` (`lock_runs_where!`)<br>8. `instances`: `FOR SHARE` when checking, `UPDATE token_epoch` via `bump_epochs_where!`<br>**Erase** follows the same order, with users `FOR UPDATE` in step 1.<br>**Tenant solo writes** start at step 2. | **Users first.** Inbox inserts (`inbox_items.user_id` FK, `0001:372`) and `project_members`/`accepted_by` FKs take `KEY SHARE` on users rows. Erase takes `users FOR UPDATE` and then updates project rows (`users.rs:186-189,214-223`). Taking users later would form a cycle. Precedent: `lock_hook` takes users first (`hooks.rs:219-223`).<br>**Runs before instances:** `runs.rs:345-366`.<br>**`FOR SHARE` on instances** serialises with a delete: `projects.rs:224-230`. |
| D4 | **Tenant solo writes also take the project lock.** `writable_solo` (`projects.rs:203-212`) first calls `lock_project`. | Otherwise a tenant `PATCH /v1/teams` can add agents while a worker join is counting agents, and the 30-agent cap can be exceeded. After the join commits, the tenant re-reads `shared` and returns 409, as today. |
| D5 | **Phone invites are delivered in-app only; no SMS in 8.14.**<br>• The row stores `invitee_phone` as plaintext E.164, the same as `login_codes` (`0039:73,79`).<br>• `invitee_id` (`0039:80`) now means "delivered to this registered user". It is set only when a notice was sent, and is never returned to the inviter.<br>• Unregistered numbers find their invite at read time by phone match. There is no change-phone flow (`auth/src/sms.rs:14`, unused).<br>Every phone input gives **201 with the same body**, whether the number is nonexistent, registered, blocking, already a member, or over the per-phone cap. | `SmsSender` only sends codes (`auth/src/sms.rs:40-49`). `send_code` would also spend the invitee's login-code budget (`sessions.rs:82-90`). |
| D6 | **Suppressed invites are silent.** A new `suppressed_at` column is set in three cases: the invitee has blocked the inviter, the number has had more than N invites in 24h, or the invitee blocks the inviter later.<br>• The inviter keeps seeing `pending`, and later `expired`.<br>• The invitee never sees or accepts the invite.<br>• "Decline and block" does **not** mark the invite `declined`. | Avoids a "was I blocked?" probe (projects.md §9). The 0039 status CHECK is unchanged (`0039:82-83`), so no CHECK rewrite is needed. |
| D7 | **Link token is `tpi1_` + base64url(32 random bytes)**, 48 characters.<br>• Stored as SHA-256 in `token_hash` (`0039:81`).<br>• Single use; TTL 72h.<br>• Phone-invite TTL is 7 days.<br>• The token travels only in request **bodies**, never in a URL path, so it stays out of access logs.<br>• The App link is `thinktin://join/{token}`. | Copies `HookToken` (`auth/src/secrets.rs:131-169`), whose hash lookup is `hooks.rs:205-214`. Deep links use the custom scheme only (`notify/src/lib.rs:137`). |
| D8 | **Caps are checked under the project lock:**<br>• 10 live users (creator included);<br>• 30 live agents (agents whose instance is deleted do not count);<br>• 20 pending invites per project.<br>Exceeding any of them gives **409 `project_limit`**, a new `ErrorCode` that ends in `_limit` as `proto/src/api.rs:34-35,83-85` requires.<br>Invites per inviter per 24h are counted in the DB under `project_invites/{inviter}`; exceeding gives **429** with an exact `Retry-After`. | Product rule (projects-impl:9). Index `project_invites_inviter (inviter_id, created_at)` already exists (`0039:95`). |
| D9 | **Read model in 8.14:**<br>• `GET /v1/projects` and `GET /v1/projects/{id}` are **narrow worker queries that check live membership in the same SQL**, returning a fixed JSON shape.<br>• 8.15 swaps the implementation to `ProjectTx`/`thinktin_member` without changing the JSON.<br>• Invite previews for non-members are worker reads filtered by the actor's phone or token hash. | The tenant cannot read the `projects` row of a joined project: `tenant_read` is creator-only (`0039:181`). Without these reads, joined projects are invisible, and "leave → immediately gone" cannot be tested. projects-impl:54 says the shape is set jointly by 8.14 and 8.15. |
| D10 | **Old `/v1/teams*` stays as is:**<br>• `PATCH` and `DELETE` on a shared project return 409 (`projects.rs:208-210`; header `gateway/src/routes/teams.rs:1-2`).<br>• `GET` lists only projects I created and shows only my agents (`projects.rs:98-125`).<br>• Joined projects never appear there. | D3 of the 8.13 plan; old clients cannot render members. |
| D11 | **Consent is an explicit `"consent": true`.** The server checks it and returns 422 without it, as in `hooks.rs:38-55`. It is recorded in three places:<br>• `project_members.consented_at` (the CHECK already exists, `0039:45`);<br>• `project_agents.consented_at` for each agent a member adds;<br>• an audit row whose detail holds the instance ids, the vendors computed by the server from `model_routes → credentials.vendor` (`0001:99,145-155`), the budgets and `consent_version: 1`. | projects-impl "受邀加入"; projects.md §4.3 and §10. |
| D12 | **Only the creator invites** (projects.md §4.2) **and removes.**<br>• Members may add, withdraw or leave only with their own agents.<br>• The creator may also withdraw any agent.<br>• Changing the lead across users belongs to 8.17.<br>• Deleting or archiving a *shared* project belongs to 8.15 (soft delete); it returns 409 until then. | The FK from inviter to member (`0039:88`) still lets 8.17 or later allow member invites. |
| D13 | **Cross-user switch.** New `GatewayConfig.cross_user_projects`, from `[api] cross_user_projects`, defaulting to **false**.<br>• When it is off, invite creation, preview, accept and the invite list return 404.<br>• Solo `/v1/projects` and `/v1/teams` keep working.<br>• Tests turn it on. | projects-impl "迁移与放量": open to many users only after the 15.7 security review. |
| D14 | **Withdraw, leave and remove handle grants and epochs now**, even though they touch 0 rows until 8.17. All in one worker transaction:<br>1. lock project runs<br>2. bump epochs<br>3. cancel the runs<br>4. revoke project grants, recursively<br>5. mark the agent rows left | 8.13 never writes `project_id` (`0040:3`), and claim/takeover skip project runs (`runs.rs:203-206`). The steps are forward-compatible, and tests seed rows with raw worker SQL, as in `tests.rs:1056-1110`. |
| D15 | **No new `PushKind`.** Receipts use `PushKind::Info` plus new `notice_subtype` strings.<br>• `Info` has no IM fan-out (`orchestrator/src/outbox.rs:65-76`).<br>• The invite push to a stranger carries **no attacker-controlled text**. | Lock-screen spam vector. Older clients tolerate unknown subtypes (`proto/src/domain.rs:1067-1069`). |

---

## 1. Migration `crates/store/migrations/0047_project_invites.sql` (one transaction)

```sql
-- 邀请与加入（WBS 8.14，docs/projects.md 第 4、9 节，docs/projects-impl.md“受邀加入”，progress/drafts/projects-8.14-plan.md）。
-- 沿用 0039：跨用户的写（建邀请、接受、拒绝、撤回邀请、加入、增派、撤回 agent、退出、移出、拉黑）只走 thinktin_worker，
-- 动作人由服务端从登录态得到；这里不给 thinktin_app 新的表权限，只多一个 projects.goal 的 INSERT 列权限（自己建单人项目时
-- 写目标；改目标走 worker）。邀请相关的表 8.13 才建、8.14 之前没有接口写过，加列、建索引都放在这一个事务里。

-- 拉黑（第 4、9 节）：被拉黑的人再发来的手机号邀请照样“发出”（接口结果一样），但不送达、不通知、到期变“已过期”，
-- 免得被用来探测“有没有被拉黑”。只有 worker 读写；列表经接口给出（对方的 id 和显示名）。
CREATE TABLE user_blocks (
    blocker_id uuid NOT NULL REFERENCES users (id),
    blocked_id uuid NOT NULL REFERENCES users (id),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (blocker_id, blocked_id),
    CHECK (blocker_id <> blocked_id)
);
CREATE INDEX user_blocks_blocked ON user_blocks (blocked_id);   -- 注销时按被拉黑的人删
ALTER TABLE user_blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_blocks FORCE ROW LEVEL SECURITY;
-- 没有给 thinktin_app 的策略和权限（默认拒绝）。0001 的 ON ALL TABLES 只覆盖当时的表。
GRANT SELECT, INSERT, DELETE ON user_blocks TO thinktin_worker;

-- 不送达（只有手机号邀请）：发的时候对方已拉黑邀请人、这个号码 24 小时内收到的邀请到了上限；对方拉黑时把还没处理的也标上。
-- 对邀请人照样是“待接受”、到期“已过期”；被邀请人看不到、接受不了。
-- invitee_id（0039）从这一版起表示“送达给了谁”：发出时号码已注册、没有不送达才填；接口从不给邀请人看。
ALTER TABLE project_invites
    ADD COLUMN suppressed_at timestamptz,
    ADD CONSTRAINT project_invites_suppressed CHECK (suppressed_at IS NULL OR kind = 'phone');
-- 同一个项目同一个号码只留一条待处理的（重复邀请返回原来那条，不多数一次）。
CREATE UNIQUE INDEX project_invites_one_pending ON project_invites (project_id, invitee_phone)
    WHERE status = 'pending' AND kind = 'phone';
-- 一个号码 24 小时收到几条（0039 的 project_invites_phone 只含待处理的）。
CREATE INDEX project_invites_phone_day ON project_invites (invitee_phone, created_at) WHERE kind = 'phone';
-- 后台：到期的标成过期、结束 30 天的删掉（明文手机号不久留）；注销时按接受人删。
CREATE INDEX project_invites_expiry ON project_invites (expires_at) WHERE status = 'pending';
CREATE INDEX project_invites_settled ON project_invites (settled_at) WHERE status <> 'pending';
CREATE INDEX project_invites_accepted_by ON project_invites (accepted_by) WHERE accepted_by IS NOT NULL;

-- 成员（不是创建者）派 agent 进来时确认“项目内容会发给项目里各 agent 用的模型厂商”的时间：加入、增派各记各的。
ALTER TABLE project_agents ADD COLUMN consented_at timestamptz;

-- 收件箱、推送的跳转目标（邀请、加入、退出回执，docs/projects-impl.md 第 6 条）。不加外键（同 vault_request_id、
-- egress_request_id）：项目删了、邀请清理了，回执照样留着，打开时接口回 404。
-- 8.15 的触发器只在 project_id 为空时按运行填；按成员关系收窄的读策略不管 run_id 为空的回执。
ALTER TABLE inbox_items ADD COLUMN project_id uuid, ADD COLUMN project_invite_id uuid;

-- 自己建单人项目时写目标（POST /v1/projects，租户事务，策略 tenant_insert 不变）。
GRANT INSERT (goal) ON projects TO thinktin_app;
```

Notes:
- `tools/ci/check_migrations.py` requires contiguous numbering (`:318`). No statement needs `deploy-safe:`: every change adds a table, a nullable column, an index or a grant, and there is no `v*` tag yet.
- Tenant `GRANT SELECT, INSERT, UPDATE ON … inbox_items` is table-level (`0001:463-464`), so it covers the new columns.

---

## 2. Store API (`crates/store`)

### 2.1 Errors (`crates/store/src/error.rs:5-35`)

```rust
/// 项目人数、agent 数、待处理邀请数到了上限（8.14）：接口回 409 `project_limit`。
#[error("project limit: {0}")]
ProjectLimit(String),
/// 按时间窗数的上限（每个邀请人 24 小时的邀请数）：接口回 429，过这么多秒再试。
#[error("retry after {0}s")]
RetryAfter(u64),
/// 是成员，但这件事只有创建者（或 agent 的主人）能做：接口回 403。
#[error("not permitted: {0}")]
NotPermitted(String),
```

### 2.2 Proto types (`crates/proto/src/domain.rs`)

**Ids** (`id_type!` at `:52-77`): add `ProjectInviteId`.

**Enums** (`str_enum!`, after `ProjectStatus` at `:545-554`):
- `ProjectRole { Creator = "creator", Member = "member" }`
- `ProjectInviteKind { Phone = "phone", Link = "link" }`
- `ProjectInviteStatus { Pending, Accepted, Declined, Revoked, Expired }`

**Constants:**
- `MAX_PROJECT_USERS: u64 = 10`
- `MAX_PROJECT_AGENTS: u64 = 30`
- `MAX_PENDING_PROJECT_INVITES: u64 = 20`
- `PROJECT_INVITE_LINK_TTL_SECS = 72*3600`
- `PROJECT_INVITE_PHONE_TTL_SECS = 7*24*3600`
- `MAX_BLOCKS: u64 = 1000`
- `MAX_PROJECT_GOAL_CHARS = 4000`
- `MAX_TOKEN_LIMIT: u64 = 1_000_000_000_000`
- `PROJECT_INVITE_LINK_PREFIX = "thinktin://join/"`
- `PROJECT_CONSENT_VERSION: u32 = 1`

**DTOs** (after `Team`, `:949-961`). None of them carries a phone number; `domain::User` includes `phone` (`:472-484`) and must not be reused.
- `ProjectPerson { user_id, display_name: Option<String> }`
- `ProjectSummary { id, name, goal, status, role: ProjectRole, shared, creator: ProjectPerson, member_count: u32, agent_count: u32, my_agent_count: u32, created_at, joined_at }`
- `ProjectMemberView { user_id, display_name, role, joined_at, agent_count: u32, is_me }`
- `ProjectAgentView { instance_id, owner_id: UserId, agent_id, name, is_lead, position: u32, added_at, mine }`
- `ProjectBudget { daily_token_limit: Option<u64>, total_token_limit: Option<u64> }`
- `ProjectLimits { max_users, max_agents }`
- `ProjectDetail { #[serde(flatten)] summary: ProjectSummary, members, agents, my_budget: ProjectBudget, limits: ProjectLimits }`
- `ProjectInvite { id, project_id, kind, status, phone_masked: Option<String>, created_at, expires_at, settled_at: Option<_>, accepted_by: Option<ProjectPerson> }` (the creator's view)
- `ProjectInvitePreview { invite_id, kind, expires_at, project: ProjectBrief { id, name, goal }, creator: ProjectPerson, members: Vec<ProjectMemberBrief { user_id, display_name, role, agent_count }>, users: u32, agents: u32, limits: ProjectLimits, shared_with_project: Vec<String>, kept_private: Vec<String> }`
  - `shared_with_project` keys: `project_goal_and_tasks`, `project_board`, `project_artifacts`, `your_agents_project_runs`, `sent_to_all_agents_vendors`
  - `kept_private` keys: `private_runs`, `private_board`, `private_artifacts`, `vault`, `computer`, `model_keys`, `costs`, `approvals`
  - The keys are stable strings that the App localises.
- `BlockedUser { user_id, display_name, created_at }`

**Notice subtypes** (`notice_subtype`, `:1070-1088`): `PROJECT_INVITE = "project_invite"`, `PROJECT_JOINED`, `PROJECT_LEFT`, `PROJECT_REMOVED`, `PROJECT_AGENT_LEFT`, `PROJECT_AGENT_REMOVED`. All of them pass `valid_subtype` (`:1125-1130`).

**`InboxItem`** (`:1133-1155`): add `project_id: Option<ProjectId>` and `project_invite_id: Option<ProjectInviteId>`, both `#[serde(default, skip_serializing_if = "Option::is_none")]`.

**Errors** (`crates/proto/src/api.rs`): `ErrorCode::ProjectLimit`, mapped to 409 in `http_status` (`:63-75`) and included in `is_limit` (`:83-85`). Add a serde test next to the `instance_limit` one at `:167-170`. `API_VERSION` is not bumped (`:9-11`).

### 2.3 Shared helpers (`crates/store/src/projects.rs`)

- `impl<R> Tx<R> { pub async fn lock_project(&mut self, id: ProjectId) -> Result<()> }` runs `SELECT pg_advisory_xact_lock(hashtextextended($1,0))` with `format!("project/{id}")`. The key matches `projects-8.13-plan.md:724`.
- `impl Tx<Worker> { pub(crate) async fn lock_projects(&mut self, ids: &mut Vec<ProjectId>) }`: sort, dedup, then lock in a loop. Do not lock inside a `SELECT … ORDER BY`, because Postgres does not guarantee that target-list functions are evaluated in sort order.
- `pub(crate) async fn lock_users(&mut self, ids: &[UserId]) -> Result<Vec<LockedUser>>`:
  - SQL: `SELECT id, status, phone, display_name FROM users WHERE id = ANY($1) ORDER BY id FOR KEY SHARE`.
  - Missing or deleted users are reported in the result, not raised as errors.
- `pub(crate) struct ProjectActor { project, user, role: ProjectRole, creator: UserId }`, built by `async fn project_actor(&mut self, user, project, also: &[UserId]) -> Result<ProjectActor>`:
  1. Read `creator_id` from `projects` (no lock). Missing → NotFound.
  2. `lock_users({user, creator} ∪ also)`. Actor deleted → NotFound.
  3. `lock_project`.
  4. `SELECT status FROM projects WHERE id=$1`. Not `active` → NotFound. Archive arrives in 8.15; exits are allowed for any non-deleted status.
  5. `SELECT role FROM project_members WHERE project_id=$1 AND user_id=$2 AND left_at IS NULL FOR NO KEY UPDATE`. None → NotFound.
  - Helper methods: `require_creator()` returns `NotPermitted("only the project creator can …")`.
- Changes to the tenant code:
  - `writable_solo` (`projects.rs:203`) first calls `self.lock_project(id)` (D4).
  - `create_solo_project(name, goal, agents)` gains `goal` (`projects.rs:53-84`, insert at `:59`). `create_team` (`teams.rs:26-29`) passes `""`.

### 2.4 Worker reads (`crates/store/src/projects.rs`, new `impl Tx<Worker>`)

| Function | SQL / rule |
|---|---|
| `my_projects(user) -> Vec<ProjectSummary>` | `FROM project_members m JOIN projects p ON p.id=m.project_id JOIN users cu ON cu.id=p.creator_id WHERE m.user_id=$1 AND m.left_at IS NULL AND p.status='active' ORDER BY p.created_at, p.id`. Counts come from subqueries on live members and on live agents joined to `instances.state <> 'deleted'`. Projects I created are included: every project has a creator row (`0039:128-129`). |
| `project_detail(user, project) -> ProjectDetail` | The same filter with `p.id=$2` and live membership; otherwise NotFound. Members: live rows only, creator first. Agents: live rows only, instance not deleted, `ORDER BY position, instance_id`, with `mine = (a.user_id = $1)`. `my_budget` comes from the caller's own member row only; budgets belong to each owner (impl item 1). |
| `update_project(user, project, name, goal)` | `project_actor` → `require_creator` → `UPDATE projects SET name=coalesce($2,name), goal=coalesce($3,goal), updated_at=now()`. |

### 2.5 Invites and blocks (new `crates/store/src/project_invites.rs`, registered in `lib.rs:11-38`, re-exported near `lib.rs:75`)

```rust
pub enum InviteKey<'a> { Phone(ProjectInviteId), Link(&'a [u8; 32]) }
pub struct InviteCaps { pub per_inviter_per_day: u64, pub per_phone_per_day: u64 }
pub struct CreatedInvite { pub invite: ProjectInvite, pub created: bool, pub deliver_to: Option<UserId>, pub project_name: String }
pub struct JoinTerms { pub agents: Vec<InstanceId>, pub daily_token_limit: u64, pub total_token_limit: u64 } // consent checked at the gateway; the store writes consented_at
pub struct Accepted { pub created: bool, pub project: ProjectId, pub creator: UserId, pub invite: ProjectInviteId,
                      pub project_name: String, pub member_name: Option<String>, pub agents: Vec<InstanceId>, pub vendors: Vec<String> }
```

**`create_phone_invite(user, project, phone /* normalized */, recipient: Option<UserId>, caps, ttl) -> CreatedInvite`**
- The orchestrator looks up `recipient` with `user_by_phone` (`users.rs:68-78`) *before* any lock, so it can be locked first under R1.
1. `project_actor(user, project, also = recipient)` → `require_creator`. The creator must have a `display_name`; otherwise `Invalid("set a display name before inviting")`. Inviting your own phone is also `Invalid`.
2. Advisory `project_invites/{user}`. `SELECT count(*), min(created_at) FROM project_invites WHERE inviter_id=$1 AND created_at > now()-'24h'`. If the count is ≥ cap → `RetryAfter(ceil(min+24h-now))`.
3. Live members ≥ 10 → `ProjectLimit("users")`.
4. Expire stale pending rows in place: `UPDATE project_invites SET status='expired', settled_at=now() WHERE project_id=$1 AND invitee_phone=$2 AND status='pending' AND expires_at <= now()`.
5. If a live pending row exists for (project, phone) → return it with `created=false`. No count, no notice.
6. Pending in the project ≥ 20 → `ProjectLimit("pending invites")`.
7. Advisory `project_invite_phone/{phone}`. Count rows with `kind='phone' AND invitee_phone=$1 AND created_at > now()-'24h'`.
8. Decide suppression. `suppressed` = the recipient blocked the inviter (`EXISTS user_blocks(recipient, user)`), or the phone count ≥ `per_phone_per_day`.
   - `deliver_to` = `recipient` unless the invite is suppressed or the recipient is already a live member.
9. `INSERT … (id, project_id, inviter_id, kind, invitee_phone, invitee_id = deliver_to, expires_at = now()+ttl, suppressed_at = CASE WHEN suppressed THEN now() END)`.
- **The returned `ProjectInvite` is identical in every case**: `status=pending`, `phone_masked`, and no recipient or suppression field.

**`create_link_invite(user, project, token_hash: &[u8;32], caps, ttl)`**: steps 1–3 and 6 as above, then insert `kind='link'`.

**`project_invites(user, project) -> Vec<ProjectInvite>`** (creator only)
- Status is computed lazily: `CASE WHEN status='pending' AND expires_at <= now() THEN 'expired' ELSE status END`.
- `suppressed_at` is never read into the DTO, and neither is `invitee_id`.
- `phone_masked` comes from `auth::secrets::mask_phone`; the function moves from `server/src/admin.rs:222-232` in C1.
- `accepted_by` is joined to the person.
- Order `created_at DESC`, limit 100.

**`revoke_invite(user, project, invite)`**
- `project_actor` → `require_creator`, then `SELECT … FOR UPDATE` on the invite (the project id must match).
- Status `accepted` → `Conflict("invite already accepted")`. Already settled → Ok, idempotent.
- Otherwise `UPDATE … SET status='revoked', settled_at=now() WHERE id=$1 AND status='pending'`.
- Mark the delivered item read: `UPDATE inbox_items SET read_at=now() WHERE user_id=$invitee_id AND project_invite_id=$1 AND read_at IS NULL` (uses `inbox_unread`, `0001:384`).

**`invites_for(user) -> Vec<ProjectInvitePreview>`** (invitee side, no membership required)
```sql
FROM users me
JOIN project_invites i ON i.kind='phone' AND i.invitee_phone = me.phone AND i.status='pending'
     AND i.expires_at > now() AND i.suppressed_at IS NULL
JOIN projects p ON p.id = i.project_id AND p.status = 'active'
WHERE me.id = $1 AND me.status <> 'deleted'
  AND NOT EXISTS (SELECT 1 FROM user_blocks b WHERE b.blocker_id=$1 AND b.blocked_id=i.inviter_id)
  AND NOT EXISTS (SELECT 1 FROM project_members m WHERE m.project_id=p.id AND m.user_id=$1 AND m.left_at IS NULL)
ORDER BY i.created_at DESC LIMIT 50
```
The preview fills in creator, members (display names only), counts and static keys.

**`invite_preview(user, key)`**
- Phone key: the same filter by id.
- Link key: `token_hash=$1 AND kind='link' AND status='pending' AND expires_at > now()`, project active.
- Links are **not** filtered by blocks: the user opened the link deliberately (open question).
- Every other case returns one uniform `NotFound`.

**`accept_invite(user, key, terms) -> Accepted`** (D3 order, one transaction)
1. Unlocked find by id or by hash → `(invite_id, project_id, creator)`. Miss → NotFound.
2. `lock_users({user, creator})`. Actor deleted → NotFound. `lock_project`. Project not active → NotFound.
3. `SELECT status, expires_at > now(), accepted_by, kind, invitee_phone, suppressed_at, inviter_id FROM project_invites WHERE id=$1 FOR UPDATE`.
   - **Idempotency:** `status='accepted' AND accepted_by=user`, and the actor is still a live member → return `Accepted{created:false,…}` without writing anything.
   - Phone invite: it must hold `invitee_phone = actor.phone`, `suppressed_at IS NULL`, and the actor must not have blocked the inviter.
   - Anything else (expired, revoked, declined, accepted by someone else, wrong phone) → NotFound.
4. Read the actor's member row `FOR NO KEY UPDATE`. Already live → `Conflict("already a member")`; the invite is **not** consumed.
5. Caps:
   - live users (+1 if the actor is new or returning) > 10 → `ProjectLimit("users")`;
   - live agents + `terms.agents.len()` > 30 → `ProjectLimit("agents")`.
6. Instances: `SELECT id FROM instances WHERE id = ANY($1) AND user_id=$2 AND state <> 'deleted' ORDER BY id FOR SHARE`. The row count must equal the number of distinct ids; otherwise NotFound (`instance`), which says nothing about whose instance it is.
7. Member upsert. This is a first-time insert, or a rejoin after leaving or removal. The AFTER INSERT trigger sets `shared_at` on the first insert (`0039:158-167`); a rejoin goes through the DO UPDATE path and does not fire it, and `shared_at` is already set.
   ```sql
   INSERT INTO project_members (project_id,user_id,role,daily_token_limit,total_token_limit,consented_at)
   VALUES ($1,$2,'member',$3,$4,now())
   ON CONFLICT (project_id,user_id) DO UPDATE SET daily_token_limit=EXCLUDED.daily_token_limit,
     total_token_limit=EXCLUDED.total_token_limit, consented_at=now(), joined_at=now(), left_at=NULL, left_reason=NULL
   WHERE project_members.role='member' AND project_members.left_at IS NOT NULL
   ```
8. Agents, in place (mirrors `projects.rs:171-177`). `dedicated=false` avoids clashing with `project_agent_dedicated` (`0039:69`). Positions start at `coalesce(max(position),-1)+1`.
   ```sql
   INSERT INTO project_agents (project_id,instance_id,user_id,position,consented_at) VALUES ($1,$2,$3,$4,now())
   ON CONFLICT (project_id,instance_id) DO UPDATE SET left_at=NULL, is_lead=false, dedicated=false,
     added_at=now(), consented_at=now(), position=EXCLUDED.position WHERE project_agents.left_at IS NOT NULL
   ```
9. Settle: `UPDATE project_invites SET status='accepted', settled_at=now(), accepted_by=$2 WHERE id=$1 AND status='pending' AND expires_at > now()`. It must affect 1 row; otherwise NotFound, and the transaction rolls back.
10. Mark the actor's inbox item for this invite read. Compute `vendors`: `SELECT DISTINCT c.vendor FROM model_routes r JOIN credentials c ON c.id=r.credential_id AND c.user_id=r.user_id WHERE r.user_id=$1 AND r.instance_id=ANY($2) ORDER BY 1`.

**`decline_invite(user, invite, block: bool)`**
1. Unlocked find. `lock_users({user, inviter})` → `lock_project` → invite row `FOR UPDATE`.
2. It must be a phone invite addressed to me, pending, and not suppressed; otherwise NotFound.
3. `block=false` → `declined`.
4. `block=true` → call `block_user_locked`, which leaves the invite `pending` with `suppressed_at=now()` (D6).
5. Mark the inbox item read.

**`block_user(user, blocked)` / `unblock_user(user, blocked)` / `blocks(user) -> Vec<BlockedUser>`**
- `lock_users({user, blocked})`. Unknown or deleted target → Ok with no write, so the result is uniform. Self → `Invalid`.
- Advisory `user_blocks/{user}`. Count ≥ `MAX_BLOCKS` → `Invalid`.
- `INSERT … ON CONFLICT DO NOTHING`.
- `UPDATE project_invites SET suppressed_at=now() WHERE kind='phone' AND inviter_id=$2 AND invitee_phone=$phone AND status='pending' AND suppressed_at IS NULL RETURNING id`, then mark those inbox items read. These rows can belong to other projects. Row locks are enough here: an accept re-checks `suppressed_at` after its own `FOR UPDATE`.
- Unblocking does not resurrect suppressed invites.

**Background sweeps**
- `expire_project_invites(batch: i64) -> u64`: `UPDATE project_invites SET status='expired', settled_at=now() WHERE id IN (SELECT id FROM project_invites WHERE status='pending' AND expires_at <= now() ORDER BY expires_at LIMIT $1 FOR UPDATE SKIP LOCKED)`. It never waits, so it cannot join a lock cycle. Afterwards it marks the related inbox items read.
- `purge_project_invites(older_than) -> u64`: `DELETE … WHERE status <> 'pending' AND settled_at < now() - $1` (30 days), so plaintext phone numbers do not linger.

### 2.6 Membership changes (new `crates/store/src/project_members.rs`)

**Run and grant helpers.**
- New `impl Tx<Worker>` functions in `runs.rs`, after `cancel_user_runs` (`:835-855`). Each uses `lock_runs_where!`, then `bump_epochs_where!`, then an `UPDATE … state='cancelled'`, all with literal filters (macros at `:345-366`):
  - `cancel_project_agent_runs(project, instance, reason)`, filter `"(project_id = $1 AND instance_id = $2 OR root_run_id IN (SELECT id FROM runs WHERE project_id = $1 AND instance_id = $2 AND parent_run_id IS NULL))"`. This mirrors `cancel_instance_runs` (`:783-828`).
  - `cancel_project_member_runs(project, user, reason)`, the same with `user_id = $2`.
- In `grants.rs`, next to `revoke_instance_grants` (`:210-230`):
  - `revoke_project_agent_grants(project, instance, reason)`: `WITH RECURSIVE tree AS (SELECT id FROM run_grants WHERE project_id=$1 AND instance_id=$2 UNION SELECT g.id FROM run_grants g JOIN tree t ON g.parent_id=t.id) UPDATE … revoked_at=now()`. Served by index `run_grants_project` (`0044`).
  - `revoke_project_member_grants(project, user, reason)`: the same with `user_id = $2`.
- **Private runs and grants of the same instance are untouched.** `bump_epochs_where!` bumps an instance only when the matching project run is its active agent run, so private sandbox tokens survive.

**Functions** (all `impl Tx<Worker>`; the user is always server-derived):

| Function | Locks (R1) | Checks | Writes | Idempotency |
|---|---|---|---|---|
| `add_project_agents(user, project, agents, consent) -> Vec<InstanceId>` | users{user, creator} → project → own member row → instances `FOR SHARE` (id order) | Live member. Members need `consent`; otherwise `Invalid`. Agents 1..=30 and distinct. Live + new > 30 → `ProjectLimit("agents")`. Instances must be own and not deleted, else NotFound. | Agent upsert as in step 8 of accept; `consented_at=now()` for members, NULL for the creator. | Already-live agents are skipped; returns only the ones actually added. |
| `withdraw_project_agent(user, project, instance) -> Withdrawn{owner, name, already_left, runs, grants}` | Unlocked read of the owner → users{user, creator, owner} → project → owner member row → agent row `FOR NO KEY UPDATE` → runs → instances (epoch) | The actor is the owner or the creator, else `NotPermitted`. No agent row → NotFound. | `cancel_project_agent_runs`, `revoke_project_agent_grants`, `UPDATE project_agents SET is_lead=false, left_at=now()` (CHECK `0039:65`). | `left_at` already set → `already_left=true`, no writes. |
| `leave_project(user, project) -> Exit` | users{user, creator} → project → own member row → own agent rows → runs → instances | Creator → `Conflict("the creator cannot leave; delete the project instead")`; CHECK at `0039:44`. | `exit_member(project, user, 'left')`. | A former member is NotFound (they no longer see the project). |
| `remove_project_member(user, project, member) -> Exit` | users{user, member} → project → member row → that member's agent rows → runs → instances | `require_creator`. Target is the creator → `Invalid`. Never a member → NotFound. | `exit_member(project, member, 'removed')`. | Already left or removed → Ok, no writes. |
| `set_project_budget(user, project, budget)` | users{user} → project → own member row | Members need both values, each in 1..=`MAX_TOKEN_LIMIT`, with daily ≤ total; the creator may use null. | `UPDATE project_members SET daily_token_limit, total_token_limit`. | Plain set. |
| `retire_deleted_instance(user, instance) -> u64` | projects in id order → agent rows | `instances.state='deleted' AND user_id=$1`. | `UPDATE project_agents SET is_lead=false, left_at=now() WHERE project_id=$p AND instance_id=$2 AND left_at IS NULL`. Runs and grants were already cancelled by the tenant delete: those rows carry the owner's `user_id`. | Repeatable. |
| `retire_deleted_project_agents(batch) -> u64` | the same, for a batch | Live agent rows whose instance is deleted. | The same update. | Sweep backstop. |

`exit_member(project, uid, reason)` is private:
1. `cancel_project_member_runs`
2. `revoke_project_member_grants`
3. `UPDATE project_agents SET is_lead=false, left_at=now() WHERE project_id=$1 AND user_id=$2 AND left_at IS NULL`
4. `UPDATE project_members SET left_at=now(), left_reason=$3 WHERE project_id=$1 AND user_id=$2 AND left_at IS NULL`
5. `UPDATE project_invites SET status='revoked', settled_at=now() WHERE project_id=$1 AND inviter_id=$2 AND status='pending'`. This touches 0 rows in 8.14, because only creators invite, but it covers `0039:88`: leaving only sets `left_at`, so the FK cascade never fires.

The result `Exit { creator, member_name, project_name, runs_cancelled, grants_revoked }` feeds the receipts.

### 2.7 Changes to existing store code

- **`users.rs::erase_account`** (`:183-243`):
  - Right after the `users … FOR UPDATE` at `:186-189`, collect `projects WHERE creator_id=$1` ∪ live `project_members` ∪ live `project_agents` and call `lock_projects`.
  - Add `OR accepted_by = $1` to the invite DELETE (`:220-221`).
  - Add `"DELETE FROM user_blocks WHERE blocker_id = $1 OR blocked_id = $1"`.
- **`teams.rs:27`**: pass `""` as the goal.
- **`inbox.rs`**:
  - add `project_id` and `project_invite_id` to `NewInboxItem` (`:12-30`), to `columns!()` (`:32-37`), to the `Row` mapping and to `insert_inbox` (`:94-129`);
  - fix the literal at `client-core/src/cache.rs:566-567`.

---

## 3. Orchestrator (`crates/orchestrator/src/projects.rs`, new; `texts.rs`; `outbox.rs`)

Each wrapper:
- opens one `db.worker()`;
- calls the store function;
- writes audit rows with `w.audit(Some(uid), actor, …)` (`store/src/outbox.rs:121-130`); a cross-user action gets one row per affected user, and audit detail never contains phone numbers;
- sends receipts through `notify(&mut w, uid, &notice)` (`outbox.rs:201-218`);
- commits.

The gateway calls these wrappers only. Precedent: `orchestrator::account::stop_all` (`account.rs:91-112`).

| Wrapper | Audit rows (action → user) | Receipt (subtype → recipient) |
|---|---|---|
| `invite_phone(db, user, actor, project, phone, caps)` | `project.invite.create` → creator (`{project, invite, kind}`) | `project_invite` → `deliver_to`, when `created` and `deliver_to` is set. Dedupe `project_invite:{id}`, collapse `project_invite:{id}`, `project_invite_id` set, TTL 7d. |
| `invite_link(…, token_hash)` | the same | none |
| `revoke_invite` | `project.invite.revoke` → creator | none (the invitee's item is marked read) |
| `accept(db, user, actor, key, terms)` | `project.join` → joiner (`{project, invite, instances, vendors, daily, total, consent_version}`); `project.member_joined` → creator | `project_joined` → creator, dedupe `project_joined:{invite}`, when `created` |
| `decline(…, block)` | `project.invite.decline` or `user.block` → invitee | none |
| `add_agents` | `project.agents.add` → owner (`{instances, vendors, consented}`) | none |
| `withdraw_agent` | `project.agent.withdraw` → actor, plus the owner if different | `project_agent_removed` → owner if the creator did it; `project_agent_left` → creator if the owner did it |
| `leave` | `project.leave` → leaver; `project.member_left` → creator | `project_left` → creator |
| `remove_member` | `project.member.remove` → creator; `project.removed` → member | `project_removed` → member |
| `set_budget`, `update_project`, `block`, `unblock` | `project.budget.set`, `project.update`, `user.block`, `user.unblock` | none |
| `retire_deleted_instance(db, user, instance)` | none (the tenant delete already wrote `instance.delete`) | none (8.19) |

**`Notice`** (`outbox.rs:100-126`):
- add `project: Option<ProjectId>` and `project_invite: Option<ProjectInviteId>`;
- copy them in `inbox()` (`:149-164`) and in `push()` (`:173-195`) into `PushTarget`.

**Texts** (`texts.rs`; style of `report_handled`, `:200-211`):
- `project_invite(locale) -> (&str, &str)`: zh `("项目邀请", "有人邀请你加入一个项目，打开 App 查看")`, en `("Project invite", "Someone invited you to a project. Open the app to see it.")`. It contains no names (D15).
- `project_joined(locale, who: Option<&str>, project, agents: usize)`
- `project_left(locale, who, project)`
- `project_removed(locale, project)`
- `project_agent_removed(locale, agent, project)`
- `project_agent_left(locale, who, agent, project)`
- A missing display name falls back to 「一位成员」 / "A member".

**`server/src/workers.rs::maintain`** (`:457-519`):
- add `w.expire_project_invites(BATCH)` and `w.retire_deleted_project_agents(BATCH)` to the first transaction;
- add `w.purge_project_invites(PROJECT_INVITE_RETENTION /* 30 d */)` to the `purged` sum.

---

## 4. Gateway

### 4.1 Routes (`crates/gateway/src/routes/mod.rs`)

- Add `mod projects; mod project_invites;` (`:3-21`).
- Add a block after teams (`:158-169`), marked `// 项目、邀请与加入（8.14）`.
- Static segments next to `{id}` follow the precedent of `/v1/inbox/read` and `/v1/inbox/{id}` (`:181-183`).

| Method & path | Handler | Transaction | Who | Request | Success |
|---|---|---|---|---|---|
| `GET /v1/projects` | `projects::list` | worker read | any | – | 200 `{"projects":[ProjectSummary]}` |
| `POST /v1/projects` | `projects::create` | tenant `create_solo_project`, then worker `project_detail` | any | `{"name","goal"?:"","agents":[{"instance_id","is_lead"?}]}`: name 1–64, goal ≤4000, agents 1–30, at most one lead | 201 `ProjectDetail` |
| `GET /v1/projects/{id}` | `projects::get` | worker read | live member | – | 200 `ProjectDetail` |
| `PATCH /v1/projects/{id}` | `projects::update` | worker | creator | `{"name"?, "goal"?}` (`present`, `mod.rs:209-215`) | 200 `ProjectDetail` |
| `DELETE /v1/projects/{id}` | `projects::delete` | tenant `delete_solo_project` | creator | – | 204. A shared project gives 409 until 8.15. |
| `POST /v1/projects/{id}/agents` | `projects::add_agents` | worker | member (own agents) | `{"agents":[{"instance_id"}],"consent":bool}` | 200 `ProjectDetail` |
| `DELETE /v1/projects/{id}/agents/{instance_id}` | `projects::withdraw_agent` | worker | owner or creator | – | 204 |
| `PUT /v1/projects/{id}/budget` | `projects::set_budget` | worker | member | `{"daily_token_limit","total_token_limit"}` | 200 `ProjectBudget` |
| `POST /v1/projects/{id}/leave` | `projects::leave` | worker | member, not creator | – | 204 |
| `DELETE /v1/projects/{id}/members/{user_id}` | `projects::remove_member` | worker | creator | – | 204 |
| `GET /v1/projects/{id}/invites` | `projects::invites` | worker | creator | – | 200 `{"invites":[ProjectInvite]}` |
| `POST /v1/projects/{id}/invites` | `projects::create_invite` | worker | creator; gated (D13) | `{"phone":"138…"}` xor `{"link":true}` | Phone: 201 new, 200 existing, `{"invite":ProjectInvite}`. Link: 201 `{"invite":…,"token":"tpi1_…","link":"thinktin://join/tpi1_…"}`; the token is shown only this once. |
| `DELETE /v1/projects/{id}/invites/{invite_id}` | `projects::revoke_invite` | worker | creator | – | 204 |
| `GET /v1/project-invites` | `project_invites::mine` | worker read | any; gated | – | 200 `{"invites":[ProjectInvitePreview]}` |
| `GET /v1/project-invites/{id}` | `project_invites::get` | worker read | addressee; gated | – | 200 `ProjectInvitePreview` |
| `POST /v1/project-invites/resolve` | `project_invites::resolve` | worker read | any; gated | `{"token"}` | 200 `ProjectInvitePreview` |
| `POST /v1/project-invites/{id}/accept` | `project_invites::accept` | worker | addressee; gated | JoinReq | 201 `ProjectDetail` (joined now) / 200 (repeat) |
| `POST /v1/project-invites/accept` | `project_invites::accept_link` | worker | token holder; gated | JoinReq + `"token"` | 201 / 200 `ProjectDetail` |
| `POST /v1/project-invites/{id}/decline` | `project_invites::decline` | worker | addressee | `{"block"?:false}` | 204 |
| `GET /v1/blocks` | `project_invites::blocks` | worker read | any | – | 200 `{"blocks":[BlockedUser]}` |
| `PUT /v1/blocks/{user_id}` | `project_invites::block` | worker | any | – | 204, also for an unknown id (uniform) |
| `DELETE /v1/blocks/{user_id}` | `project_invites::unblock` | worker | any | – | 204 |

**JoinReq.** The agent entries are objects, so 8.16 can add `dedicated` and `ack_shared_memory`. No `deny_unknown_fields`.
```json
{"agents":[{"instance_id":"0193…"}],"daily_token_limit":200000,"total_token_limit":5000000,"consent":true}
```

**ProjectDetail** (a member's view):
```json
{"id":"…","name":"设计组","goal":"两周内出首页改版","status":"active","role":"member","shared":true,
 "creator":{"user_id":"…","display_name":"小李"},"member_count":2,"agent_count":3,"my_agent_count":1,
 "created_at":"…","joined_at":"…",
 "members":[{"user_id":"…","display_name":"小李","role":"creator","joined_at":"…","agent_count":2,"is_me":false},
            {"user_id":"…","display_name":null,"role":"member","joined_at":"…","agent_count":1,"is_me":true}],
 "agents":[{"instance_id":"…","owner_id":"…","agent_id":"claude","name":"主编","is_lead":true,"position":0,"added_at":"…","mine":false}],
 "my_budget":{"daily_token_limit":200000,"total_token_limit":5000000},
 "limits":{"max_users":10,"max_agents":30}}
```

**ProjectInvite** (the creator's view; the same keys for every phone):
```json
{"id":"…","project_id":"…","kind":"phone","status":"pending","phone_masked":"+86138****0962",
 "created_at":"…","expires_at":"…","settled_at":null,"accepted_by":null}
```

**Status codes**

| Status | Cases |
|---|---|
| 422 `invalid` | bad phone (`auth::secrets::normalize_phone`, `secrets.rs:25-47`); both or neither of phone/link; inviting your own phone; creator has no display name; missing consent; budgets missing, ≤0 or daily > total; agents empty, duplicated or more than 30; goal or name length (`check_len`, `mod.rs:218-231`) |
| 404 `not_found` | non-member; unknown project, invite or instance; malformed, unknown, used, expired or revoked token (one uniform body, `"invite not found"`); bad path id (`parse_id`, `mod.rs:204-206`); cross-user routes when D13 is off |
| 403 `forbidden` | member calling a creator-only route; non-owner withdrawing someone else's agent. New helper `ApiError::forbidden`. |
| 409 `project_limit` | caps (D8) |
| 409 `conflict` | already a member; the creator leaves; revoking an accepted invite; old teams writes and `DELETE /v1/projects/{id}` on a shared project |
| 429 `rate_limited` + `Retry-After` | invite limits (below) |

**Error mapping** (`gateway/src/error.rs:67-80`):
- `store::Error::ProjectLimit(m)` → `ErrorCode::ProjectLimit` (409)
- `RetryAfter(s)` → `RateLimited` with `retry_after_secs`
- `NotPermitted(m)` → `Forbidden` (403)

`Forbidden` (42501) still maps to 500 until 8.15 (`error.rs:77`).

### 4.2 Rate limits

**Additions to `LimitConfig`** (`gateway/src/limits.rs:26-55`, defaults at `:57-74`; configured as `[api.limits]`):

| Field | Default | Mechanism |
|---|---|---|
| `invites_per_hour` | 30 | In-memory, per user. New `Key::Invites(UserId)`, helper `invites()`, modelled on `reports()` (`:170-173`). Applied to both phone and link creation, so it is uniform. |
| `invites_per_day` | 20 | DB count under an advisory lock. Exceeding gives `RetryAfter`. |
| `invites_per_phone_per_day` | 5 | DB count under an advisory lock. Exceeding gives **silent suppression**, never an error. |
| `invite_lookups_per_hour` | 60 | In-memory, per user, `Key::InviteLookups(UserId)`. Applied on every `resolve` and `accept_link`, ahead of hashing. |

- The handler reads the DB caps through `s.limits().config()` (`limits.rs:131`), as `teams.rs:191` does.
- Document the new fields in `docs/compliance.md`, which lists `reports_per_hour`.

### 4.3 Uniform phone results, token handling and consent

**Phone invite path** (`projects::create_invite`):
1. `normalize_phone`
2. `limits().invites(who.user)?`
3. `orchestrator::projects::invite_phone(&s.db, who.user, &who.actor(), id, &e164, caps)`
4. Respond with `{"invite": …}`.

Registration, blocking and the per-phone cap only decide `deliver_to` and `suppressed_at` inside the store; neither is ever serialised. Residual risk: the invite notice adds two inserts (inbox and outbox) for registered numbers, so timing can differ slightly (see open questions).

**Link tokens:**
- New `auth::secrets::InviteToken`, with `generate`, `parse` (prefix `tpi1_` plus 43 base64url characters), `as_str` and `hash() -> [u8;32]` as SHA-256. Build it from a shared private helper for HookToken and InviteToken (`secrets.rs:131-169`).
- `parse` failure → 404 without a database query, after `invite_lookups`. The response is the same as for an unknown token.

**Consent:**
- The handler returns 422 when `consent != true`, except when the creator adds their own agents.
- The store writes `consented_at`; the orchestrator writes the `project.join` or `project.agents.add` audit row with server-computed vendors and `consent_version`.

**Gate:** `fn cross_user(s) -> ApiResult<()>` returns `not_found("route")` unless `s.cfg.cross_user_projects` is set.
- New field in `GatewayConfig` (`gateway/src/lib.rs:29-61`, default `false`).
- New field in `server/src/config.rs` `Api` (`:123-141`, default `false`).
- Wired in `server/src/api.rs:105-111`.

### 4.4 Instance delete (`gateway/src/routes/instances.rs:372-393`)

- After `t.commit()`, call `orchestrator::projects::retire_deleted_instance(&s.db, who.user, id)`.
- On error, `warn!` and still return 204; the `maintain` sweep is the backstop. The tenant UPDATE at `store/src/instances.rs:396-402` silently skips shared projects because of the policy at `0039:203-209`.
- Readers already ignore deleted instances (`i.state <> 'deleted'` in every count and list).

### 4.5 `/v1/teams`

No behaviour change. Add tests on a shared project:
- `PATCH` and `DELETE` return 409;
- `GET /v1/teams/{id}` shows only the creator's agents;
- the joined member's `GET /v1/teams` does not list the project.

`writable_solo` now takes the project lock (D4).

---

## 5. Notifications: minimal receipts for 8.14 (projects-impl item 6)

- **What 8.14 sends:** six subtypes (§3), always `PushKind::Info`, always written to the recipient's private inbox through `notify` in the same worker transaction as the state change.
  - `project_invite` is sent only to a delivered registered number. Its text is generic (D15).
  - Settling an invite (accepted, declined, revoked, expired, suppressed) marks the invitee's item read.
- **Not sent in 8.14:**
  - no notice for decline (the creator sees `declined` in the invite list);
  - no notice when someone registers later with a number that has a pending invite (8.19 can hook `Login.new_user`, `auth/src/service.rs:138`);
  - no notice for an erased member, a deleted project or task results (8.19);
  - nothing for IM.
- **`notify::PushTarget`** (`crates/notify/src/lib.rs:130-143`): add `project_id` and `project_invite_id` with `serde(default, skip_serializing_if)`. Add the keys to each channel's list:
  - APNs: `("project", …)` and `("project_invite", …)` (`apns.rs:138-147`);
  - FCM: `tt_project` and `tt_project_invite` (`fcm.rs:243-251`);
  - JPush: the same `tt_*` keys (`jpush.rs:107-116`);
  - extend the channel tests at `apns.rs:420`, `fcm/tests.rs:200` and `jpush.rs:350`.
- **`docs/push.md`:**
  - add the new keys to the payload section (`:58-68`) and the subtypes to the table (`:80-89`);
  - App routing (12.25/13.18): `project_invite` → `thinktin://project-invite/{id}`; the other subtypes → `thinktin://project/{id}`.

---

## 6. client-core FFI

**`crates/client-core/src/api.rs`:** a new section `// ---------- 项目、邀请（8.14） ----------` after teams (`:1722-1818`), in the same style: a local `R` wrapper for lists, `json!` bodies, a PATCH body as a `Map` of present fields. Lists use `#[serde(deserialize_with = "crate::lenient::vec")]`. Methods:
- `projects`, `project`, `create_project`, `update_project`, `delete_project`
- `add_project_agents`, `withdraw_project_agent`, `set_project_budget`, `leave_project`, `remove_project_member`
- `project_invites`, `invite_by_phone`, `create_invite_link`, `revoke_project_invite`
- `my_project_invites`, `project_invite`, `resolve_invite_link`
- `accept_project_invite`, `accept_invite_link`, `decline_project_invite`
- `blocks`, `block_user`, `unblock_user`

**`crates/client-core/src/ffi.rs` records**, near Team at `:816-918`, all `#[derive(Debug, Clone, uniffi::Record)]` with `From<d::…>`:
- `ProjectPerson`
- `Project` (summary)
- `ProjectMember`
- `ProjectAgent`
- `ProjectBudget { daily_token_limit: Option<u64>, total_token_limit: Option<u64> }`
- `ProjectDetail { project: Project, members, agents, my_budget, max_users: u32, max_agents: u32 }`
- `ProjectInvite`
- `ProjectInviteLink { invite, token, link }`
- `ProjectInvitePreview`
- `BlockedUser`
- Inputs: `ProjectAgentInput { instance_id, is_lead }` and `ProjectJoin { instance_ids: Vec<String>, daily_token_limit: u64, total_token_limit: u64, consent: bool }`.
- Conventions (`ffi.rs:1-45`): ids are `String`, times are `*_ms: i64`, enums are strings.

**`InboxItem` record** (`:998-1040`): add `project_id` and `project_invite_id` with `#[uniffi(default = None)]`, and assert the defaults in `tools/client-core/ffi_smoke.py`.

**Exported methods** on `ThinktinClient`, after the team block (`:2592-2708`), via `self.run(|c| …)`:
- `projects()`, `project(project_id)`, `create_project(name, goal, agents)`, `update_project(project_id, name, goal)`, `delete_project`
- `add_project_agents(project_id, instance_ids, consent)`, `withdraw_project_agent(project_id, instance_id)`, `set_project_budget(project_id, budget)`, `leave_project`, `remove_project_member(project_id, user_id)`
- `project_invites(project_id)`, `invite_to_project_by_phone(project_id, phone)`, `create_project_invite_link(project_id)`, `revoke_project_invite(project_id, invite_id)`
- `my_project_invites()`, `project_invite(invite_id)`, `resolve_project_invite_link(link_or_token)`
- `accept_project_invite(invite_id, join)`, `accept_project_invite_link(link_or_token, join)`, `decline_project_invite(invite_id, block)`
- `blocked_users()`, `block_user(user_id)`, `unblock_user(user_id)`

**Free function:** `#[uniffi::export] fn project_invite_token(text: String) -> Option<String>` accepts `thinktin://join/<tok>` or a bare token and checks the `tpi1_` + 43 base64url format locally. A malformed link gives `ClientError::InvalidArgument` without a network call.

**Errors:**
- Unchanged mechanism: `ClientError::Api { status, code, … }` passes `project_limit` (409) through raw (`error.rs:20-29`); 429 arrives with `retry_after_secs`.
- Document `project_limit` in the `Api` variant doc (`error.rs:19-21`).

**Bindings:**
- Android: `apps/android/scripts/sync-core.sh --bindings-only` regenerates `apps/android/core/src/main/kotlin/cn/thinktin/core/client_core.kt`, committed on its own (precedents `4f4950d`, `c2b8892`). CI runs `sync-core.sh --check` (`.github/workflows/android.yml:59`).
- **No `apps/apple/**` commit is expected.** Swift bindings are generated at build time, and the only change to an existing record is two defaulted fields on `InboxItem`, which keeps the generated inits source-compatible. If a Swift test helper turns out to build the generated record positionally, fix it in a separate `apps/apple/**` commit.
- App adapters (`CoreThinktinService.kt`, `CoreClient.swift`) belong to 12.25 and 13.18.

---

## 7. Tests

### 7.1 Store, against real Postgres

New file `crates/store/src/tests/projects.rs`, declared with `mod projects;` in `tests.rs`, reusing `user()` and `instance()` (`tests.rs:20-42`). It uses TestDb, which migrates as the non-superuser owner (8.13 D8). Users: alice is the creator, bob the invitee, carol the outsider or blocker, plus one unregistered number.

1. **`phone_invites_look_the_same_whoever_owns_the_number`**
   - Invite four numbers: bob's (registered), an unregistered one, carol's (after carol blocks alice), and one over the per-phone cap. Use `invites_per_phone_per_day = 1` with a second inviter.
   - Each returned `ProjectInvite` is equal after normalising id and time fields.
   - Only bob has an inbox row with `project_invite_id`; carol and the capped number have none.
   - `invites_for(carol)` is empty.
   - The unregistered number registers (`upsert_user_by_phone`) and then sees the invite.
   - Re-inviting bob returns the same id with `created=false` and is not counted again.
2. **`link_invites_are_hashed_single_use_and_idempotent`**
   - No column holds the raw token: `token_hash = sha256(token)`, and a scan of `project_invites` for the token text finds nothing.
   - bob accepts → `created=true`; bob again → `created=false` with the same detail.
   - carol with the same hash → NotFound.
   - Expiry forced with worker SQL `expires_at = now() - '1s'` → NotFound. `expire_project_invites` flips the status, and the inbox item is read.
3. **`accept_races_revoke`**: 20 rounds with a `tokio::sync::Barrier`, running `accept_invite` (bob) and `revoke_invite` (alice) concurrently. Exactly one wins each round. Final state: invite `accepted` ⇔ bob is a live member, and `revoked` ⇔ he is not.
4. **`concurrent_accepts_respect_ten_users`**: alice plus 8 members, then two invitees accept at once. Exactly one succeeds; the other gets `ProjectLimit`, and its invite stays `pending`. Live members = 10.
5. **`thirty_agents_per_project`**
   - alice has 28 agents (`instance()` in a loop). bob accepting with 3 → `ProjectLimit`; with 2 → ok.
   - `add_project_agents` with 1 → `ProjectLimit`.
   - At 29, two concurrent adds of 1 each → exactly one wins.
   - An agent whose instance is deleted does not count.
6. **`withdraw_leave_remove_and_rejoin`**
   - bob joins with b1 and b2. Withdrawing b1 (owner) sets `left_at`; repeating it gives `already_left`.
   - alice withdraws b2 → the owner check passes. carol (outsider) withdrawing → NotFound; bob withdrawing an alice agent → `NotPermitted`.
   - bob `remove_project_member` → `NotPermitted`. alice `leave_project` → `Conflict`.
   - bob `leave_project` → `left_reason='left'`; then `project_detail(bob)` → NotFound, `my_projects(bob)` excludes the project, and `leave_project` again → NotFound.
   - A new invite brings bob back: the same member and agent rows are reactivated and `joined_at` moves.
   - alice removes bob → `'removed'`; removing again → Ok.
   - `shared_at` stays set.
7. **`exits_stop_project_runs_and_grants`**
   - Seed project runs and grants with the worker "copy row" SQL from `tests.rs:1084-1104`: one project run in `running` on b1, a child grant of a project grant, and a private run plus private grant on the same instance.
   - After `withdraw_project_agent`: the project run is `cancelled`, `token_epoch` rose by 1, the project grant tree is revoked, and the private run and private grant are untouched.
   - After `leave_project`, the same holds for all of bob's project rows.
8. **`cross_user_rows_are_worker_only`**
   - As tenant: SELECT and INSERT on `project_invites` and `user_blocks` → `Forbidden`.
   - Inserting a `role='member'` row → `Forbidden`.
   - Updating a shared project's `project_agents` affects 0 rows.
   - bob as tenant cannot read alice's `projects` row even after joining (`0039:181`).
   - Tenant teams update on the shared project → `Conflict`.
9. **`blocks_hide_invites_silently`**
   - carol `decline_invite(block=true)`: the inviter's view still says `pending`; carol's list is empty; her inbox item is read.
   - A later invite to carol is created, with no inbox row.
   - Unblocking does not resurrect the suppressed invites.
   - Blocking an unknown user id → Ok with no row.
10. **`erase_and_project_flows_do_not_deadlock`**
    - Extend the erase test (`tests.rs:1903-1950`): blocks and `accepted_by` invites are gone.
    - Concurrently, erase bob while bob accepts; then erase alice while bob leaves. Both finish (no 40P01), and the final state is consistent.
11. **`deleted_instances_leave_shared_projects`**: a tenant delete followed by `retire_deleted_instance` marks the agent left in alice's shared project. Without the call, `retire_deleted_project_agents` does it.
12. **`team_edits_and_joins_serialize`**: a concurrent tenant `update_team` (adding agents) and `accept_invite` on a project at 29 agents. Never more than 30; the team edit either finishes first or gets 409.

### 7.2 Gateway (`crates/gateway/tests/api.rs`)

The harness is at `:35-166`. `api_with` sets `cross_user_projects: true` and test-sized limits.

- **`project_phone_invites_are_uniform_over_http`**
  - bob is logged in. carol is logged in and blocks alice via `PUT /v1/blocks/{alice}`; alice's id comes from a preview.
  - Unregistered number `13800139999`; an existing member's number.
  - All give 201, the same sorted key set and `status=="pending"`.
  - bob's `/v1/inbox` has `subtype=project_invite` with `project_invite_id`, and its body contains neither the project name nor alice's name.
  - No phone digits appear in `GET /v1/project-invites/{id}` (assert `!body.to_string().contains("1380013")`).
- **`project_link_invite_join_and_exit_over_http`**
  - The token appears only in the create response; `GET …/invites` does not contain it.
  - A malformed token → 404.
  - Resolve → preview with goal, creator `display_name`, members and the shares keys.
  - Accept without consent → 422; with consent → 201; repeated → 200 with the same body; carol with the same token → 404.
  - bob's `GET /v1/projects` includes it with `role:"member"`, and the detail shows both owners' agents with the `mine` flags.
  - alice's inbox has `project_joined`.
  - Withdraw → 204 and alice gets `project_agent_left`. bob leaves → 204; `GET /v1/projects/{id}` → 404; bob's list no longer includes it; alice gets `project_left`.
  - Rejoin with a new link, then alice removes bob → bob gets `project_removed`.
- **`project_limits_and_invite_rate_limits_over_http`**
  - With `invites_per_day: 2` and `invites_per_hour: 0`, the third invite → 429 with `Retry-After`.
  - With `invites_per_hour: 1` → 429 from the in-memory bucket.
  - Ten users join, and the eleventh accept → 409 `project_limit`.
  - Precedent: `rate_limits_and_signup_cap` at `:2938`.
- **`outsiders_see_nothing_of_a_project`**: carol gets 404 on detail, invites, members delete, agents delete and accept-by-id, and 403 is never reached. bob (a member) gets 403 on creator-only routes.
- **`old_team_api_on_a_shared_project`**: next to `old_team_api_is_backed_by_projects` (`:2800`). `PATCH`/`DELETE /v1/teams/{id}` → 409; `GET` shows only alice's agents; bob's `/v1/teams` does not list it.
- **`cross_user_projects_are_off_by_default`**: default config → invite create, resolve and accept return 404, while `POST /v1/projects` works.
- **`deleting_an_instance_leaves_shared_projects_over_http`**.

### 7.3 client-core (`crates/client-core/tests/client.rs`)

- **`ffi_projects_invites_and_join`**, after `ffi_teams_and_templates` (`:1641`):
  - two `ffi_login` clients; `create_project`, `create_project_invite_link`;
  - `project_invite_token(link)` round-trips; a bad link → `InvalidArgument`;
  - `resolve_project_invite_link` → `accept_project_invite_link` → `projects()` and `project()`;
  - the creator's `InboxItem.project_id` is set;
  - `withdraw_project_agent` → `leave_project` → `project()` gives `Api{status:404}`.
- Plus a unit test for `project_invite_token`.
- `ffi_smoke.py` asserts `InboxItem(...).project_id is None`.

### 7.4 Other crates

- notify: channel payload tests for the new keys.
- auth: `InviteToken` generate and parse tests, next to the existing token tests in `secrets.rs`.
- proto: `ErrorCode::ProjectLimit` serde and status test.

---

## 8. Commit sequence

Every commit builds and passes `cargo test --workspace`. Push after each one, and update `docs/progress/claude-determined-lovelace-vn0j5h.md` in the same commit.

| # | Commit | Files |
|---|---|---|
| C1 | auth: `InviteToken`; `mask_phone` moves to `auth::secrets` | `crates/auth/src/secrets.rs`, `crates/server/src/admin.rs` |
| C2 | migration 0047; erase takes project locks and deletes blocks and accepted invites; store test 10 | `migrations/0047_project_invites.sql`, `store/src/users.rs`, `store/src/tests/projects.rs` (new) |
| C3 | inbox and push carry project and invite ids | `store/src/inbox.rs`, `proto/src/domain.rs` (InboxItem), `notify/src/{lib,apns,fcm,jpush}.rs` + tests, `orchestrator/src/outbox.rs` (Notice), `client-core/src/{ffi.rs,cache.rs}`, `tools/client-core/ffi_smoke.py`, `docs/push.md` |
| C4 | proto project types; `project_limit`; store and gateway error variants | `proto/src/{domain,api}.rs`, `store/src/error.rs`, `gateway/src/error.rs` |
| C5 | store: project lock, ProjectActor, tenant lock in `writable_solo`, goal on create, worker reads, `update_project`; tests 8 and 12 | `store/src/{projects,teams,lib}.rs` |
| C6 | store: invites and blocks (create, list, revoke, preview, decline, block, expire, purge); tests 1, 2 and 9 | `store/src/project_invites.rs` |
| C7 | store: accept, join and add agents with caps; tests 3, 4 and 5 | `store/src/{project_invites,project_members}.rs` |
| C8 | store: withdraw, leave and remove; project-scoped run cancel and grant revoke; retiring deleted instances; tests 6, 7 and 11 | `store/src/{project_members,runs,grants}.rs` |
| C9 | orchestrator: project wrappers, texts, notices; maintain sweeps | `orchestrator/src/{projects,texts,lib}.rs`, `server/src/workers.rs` |
| C10 | gateway: routes, limits, cross-user switch, instance-delete worker step; API tests | `gateway/src/routes/{mod,projects,project_invites,instances}.rs`, `gateway/src/{limits,lib}.rs`, `server/src/{config,api}.rs`, `gateway/tests/api.rs`, `docs/compliance.md` |
| C11 | client-core: project API, FFI and tests | `client-core/src/{api,ffi,error}.rs`, `client-core/tests/client.rs`, `tools/client-core/ffi_smoke.py` |
| C12 | Android bindings, regenerated (its own commit) | `apps/android/core/src/main/kotlin/cn/thinktin/core/client_core.kt` |
| C13 | docs | `docs/projects-impl.md` (new "8.14 做了什么"), `docs/projects.md` status line, `docs/progress/drafts/projects-8.14-plan.md`, progress file |

C3 is cross-crate but has to be atomic: adding fields to `InboxItem` breaks every struct literal. After merging, delete `autosave/<branch>` as CLAUDE.md says.

---

## 9. What 8.14 leaves for 8.15–8.19

**8.15**
- Replace the worker reads `my_projects` and `project_detail` (and the preview's member list) with `ProjectTx` / `thinktin_member` member policies and definer functions. The JSON stays the same.
- Map 42501 to 404 on project paths.
- Add the `inbox_items.project_id` trigger from `runs.project_id`, filling it only when NULL. Membership narrowing must exempt receipts (`run_id IS NULL`).
- Soft-delete and archive shared projects: `DELETE /v1/projects/{id}` for shared projects, a `project_deleted` receipt, and erase switching to soft delete. Every writer of `projects.status` takes `lock_project`.
- Project keys and content.

**8.16**
- `agents[].dedicated` and `ack_shared_memory` in JoinReq and in the add-agents call (the worker writes `project_agents.dedicated`).
- The non-dedicated warning.
- Before lifting the claim guard, re-validate the existing live `project_agents` rows: the pilot accepts only instances that can be isolated (projects-impl "受邀加入").
- Claims must check `project_agents.left_at IS NULL` and live membership ("停领").

**8.17**
- Changing the lead across users (`PUT /v1/projects/{id}/lead`).
- Project dispatch and creating project grants via a `ProjectActor` that is exposed then.
- Deciding what happens to cross-owner children when an agent is withdrawn; 8.14 cancels trees rooted on the withdrawn agent.
- Member-sent invites, if wanted (the inviter FK already allows them).

**8.18**
- Enforce `project_members.daily_token_limit` and `total_token_limit` in llm-gw.
- Approvals go to the owner.
- Computer and vault per project agent.
- How freezing an account interacts with membership.

**8.19**
- The full notification set: decline, member erased, project deleted or archived, task results, and the invite notice when someone registers later with an invited number.
- The project feed (`project_seq`) and live revocation of open project streams.
- Possibly a project `PushKind` and iOS category.
- Changing the inbox FK for cross-owner notices.

**12.25 / 13.18**
- Project UI, the invite and join flow, and blocks.
- Deep links `thinktin://join/{token}`, `thinktin://project/{id}` and `thinktin://project-invite/{id}`.
- Routing for the new subtypes, and the adapters.

**15.7 / 16.6**
- 15.7: the residual timing gap, link leakage, the preview's exposure of member names, and the plaintext phone.
- 16.6: the privacy-policy text and `consent_version`, and the erase rules for invites.

**After the security review:** set `[api] cross_user_projects = true` in production.


## 待定问题

- SMS invites to unregistered numbers: 8.14 delivers phone invites in-app only (SmsSender only has send_code, auth/src/sms.rs:40-49, which would also spend the invitee's login-code budget). Should a separate Aliyun notification template and SmsSender::send_invite be added now or later? If added, unregistered numbers would get an SMS while registered ones get a push; the inviter still sees the same 201 either way.
- Keep project_invites.invitee_phone as plaintext E.164 (same as login_codes, needed for later matching and the masked display; erase deletes it, and settled invites are purged after 30 days), or store a keyed HMAC as design A did (projects-design-A.md:986)?
- Should creating an invite require the creator to have a display_name (422 otherwise)? Default yes, so invitees can recognise who invited them without seeing any part of the creator's phone. The alternative is to show a masked creator phone in the preview.
- Link invites from someone the invitee has blocked: default is not filtered (the user chose to open the link). Should they be filtered (404) like phone invites?
- Should the GET /v1/projects and GET /v1/projects/{id} reads ship in 8.14 as worker queries that check live membership in SQL (the 8.15 ProjectTx swap keeps the JSON), or wait for 8.15? If they wait, 8.14 has no way to show a joined project, and the leave/remove visibility tests have nothing to assert against.
- Add a cross_user_projects switch, default off in production until the 15.7 review, which hides the invite, preview and accept routes? Or rely on the release not exposing the App UI?
- Deleting or archiving a shared project: 409 until 8.15's soft delete (default), or add an interim worker hard delete in 8.14? No project runs can exist yet, so the NO ACTION runs_project_agent FK would not block a hard delete.
- Proposed numbers: link TTL 72h, phone-invite TTL 7 days, 20 invites per inviter per 24h, 30 per hour in memory, 5 per phone per 24h (over that, invites are silently suppressed), 20 pending per project, settled invites purged after 30 days, at most 1000 blocks per user. Confirm or change.
- Residual timing side channel: the invite notice (an inbox and an outbox insert) runs in the same transaction only for registered numbers. Accept it, or send invite notices from a background job after the response so the response time does not depend on whether the number is registered?
- Should the invite preview show existing members' display names to anyone holding a link (projects.md §4.3 says the invitee sees the current members)? A link that leaks reveals those names.
- Should the inviter see 'declined' (the default for an explicit decline) or only pending/expired? 'Decline and block' is always silent: the invite stays pending, then expires.