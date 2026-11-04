# 8.14 实现方案定稿（2026-11-04）

草稿按评审改过（采纳和不采纳的理由在附录）。英文原样，按这个实现。

# WP 8.14 implementation plan (final): invites and joining (phone and link invites, choosing agents, budgets, consent; adding, withdrawing, leaving, removing; invite limits and blocking)

Branch `claude/determined-lovelace-vn0j5h` @ `e070d18`. The last migration is `0046_validate_run_space_keys.sql`, so this package starts at **0047**. I re-read every file:line below at HEAD and checked each critic correction against the code. No files were changed. Appendix A lists each critic item with its verdict; the one rejection (F3) is explained there. Appendix B lists the extra issues I found while verifying.

---

## 0. Decisions

| # | Decision | Why / evidence |
|---|---|---|
| D1 | **One new migration, `0047_project_invites.sql`, in a single transaction.** It contains:<br>• `user_blocks`;<br>• `project_invites.suppressed_at` plus indexes;<br>• `project_agents.consented_at`;<br>• `inbox_items.project_id` and `project_invite_id`, with the `inbox_project_guard` trigger;<br>• `GRANT INSERT (goal) ON projects TO thinktin_app`.<br>No CONCURRENTLY file is needed. | **Why one transaction is fine:** the project tables are new and empty, since no route wrote invites before 8.14 (`0039:73`). On `inbox_items` the migration only adds nullable columns and a trigger, which are catalog-only changes.<br>**No new inbox index:** inbox cleanup always filters on `user_id`, which `inbox_unread` (`0001:384`) serves.<br>**Locks:** the transaction holds `users` SHARE ROW EXCLUSIVE (from the `user_blocks` FK) and `inbox_items` ACCESS EXCLUSIVE until commit. That is fine under the 0039 precondition (released before the first deployment). If a live database exists by then, split the migration or set `lock_timeout`; the migration header says so. |
| D2 | **Every cross-user write goes through `Tx<Worker>`, inside one store method that takes its own locks.**<br>• The acting `UserId` always comes from `Authed` (`gateway/src/extract.rs:28-39`), never from the request body.<br>• The store builds a crate-private **`ProjectActor`** (project, user, role, creator) from locked and verified rows, inside the same method that uses it.<br>• Gateway and orchestrator code can never construct or carry one. | projects-impl item 3. The 8.13 rule is that only the worker writes cross-user rows (`0039:3-4,212,224-225`). The tenant has no policy on `project_invites`, and none is added. |
| D3 | **Global lock order (rule R1):**<br>1. `users` rows `FOR KEY SHARE`, in id order: the actor, the creator, every target, and every user whose inbox the flow writes.<br>2. Project advisory lock `project/{id}`; for several projects, in id order.<br>3. The acting user's own `project_members` row `FOR NO KEY UPDATE`. `project_actor` takes it; accept reads it here even when the row is absent.<br>4. Narrower advisory keys, in this order: `project_invites/{inviter}` → `project_invite_phone/{e164}` → `user_blocks/{user}`. **Every advisory key is taken before the first `project_invites` row lock.**<br>5. `project_invites` rows `FOR UPDATE`.<br>6. Other `project_members` rows (a target member) `FOR NO KEY UPDATE`.<br>7. `project_agents` rows `FOR NO KEY UPDATE`.<br>8. `runs` (`lock_runs_where!`).<br>9. `instances`: `FOR SHARE` when checking; `UPDATE token_epoch` via `bump_epochs_where!`.<br><br>**Variants:**<br>• **Erase** follows the same order, with users `FOR UPDATE` in step 1 and then `lock_projects` in step 2.<br>• **Tenant solo writes** start at step 2.<br>• **Block** and **decline-and-block** use steps 1, 4 and 5 only.<br>• **Sweeps never wait.** Invite and inbox rows are taken `FOR UPDATE SKIP LOCKED`; the retire sweep uses `pg_try_advisory_xact_lock`.<br>• A user's inbox rows are written only by a flow that holds that user's step-1 row, or with SKIP LOCKED. | **Users first.**<br>• Inbox inserts (`inbox_items.user_id` FK, `0001:372`) and the `project_members` and `accepted_by` FKs take `KEY SHARE` on users rows.<br>• Erase takes `users FOR UPDATE` (`users.rs:186-189`), then changes project rows (`users.rs:214-223`).<br>• Precedent: `lock_hook` takes users first (`hooks.rs:219-223`).<br>**Erase takes project locks too (Appendix A, F3).** Tenant `update_team` updates the `projects` row (`projects.rs:130`) and then the `project_agents` rows (`projects.rs:153`). Erase does the reverse: it updates `project_agents` (`users.rs:216`) and then deletes `projects` (`users.rs:218`). The shared project lock serializes them.<br>**Runs before instances:** `runs.rs:345-366`.<br>**`FOR SHARE` on instances** serializes with a delete (`projects.rs:224-230`). |
| D4 | **Tenant solo writes also take the project lock.** `writable_solo` (`projects.rs:203-212`) calls `lock_project` first. | Without it, a tenant `PATCH /v1/teams` can add agents while a worker join is counting them, and the 30-agent cap can be exceeded. After the join commits, the tenant re-reads `shared` and returns 409, as today. |
| D5 | **Phone invites are delivered in-app only; there is no SMS in 8.14.**<br>• The row stores `invitee_phone` as plaintext E.164, like `login_codes` (`0039:73,79`).<br>• `invitee_id` (`0039:80`) now means **"a notice was delivered to this user"**. It is set only when all of these hold: the number is registered, the recipient has not blocked the inviter, the recipient is not a live member, and the number's delivered-notice count in the last 24h is under the cap. It is never returned to the inviter.<br>• A registered number without a delivered notice, or an unregistered number that registers later, finds the invite at read time by phone match. There is no change-phone flow (`auth/src/sms.rs:14` is unused).<br>• **Every phone input gives 201 with the same body**, whether the number is unregistered, registered, blocking, already a member, over the per-phone cap, or already invited. | `SmsSender` only sends codes (`auth/src/sms.rs:40-49`). Using `send_code` would also spend the invitee's login-code budget (`sessions.rs:82-90`). |
| D6 | **Suppression is for blocks only.** `suppressed_at` is set in two cases: the invitee had already blocked the inviter when the invite was created, or blocks the inviter later.<br>• The inviter keeps seeing `pending`, and later `expired`.<br>• The invitee never sees the invite and cannot accept it.<br>• "Decline and block" does **not** mark the invite `declined`.<br>**The per-phone cap only withholds the notice.** The invite stays valid and visible in `invites_for`. | Silent suppression avoids a "was I blocked?" probe (projects.md §9). The 0039 status CHECK is unchanged (`0039:82-83`).<br>If the cap also suppressed invites, anyone could flood a number and make its real invites silently disappear (critic B3). |
| D7 | **Link token is `tpi1_` + base64url(32 random bytes)**, 48 characters.<br>• Stored as SHA-256 in `token_hash` (`0039:81`).<br>• Single use; TTL 72h. Phone invites last 7 days.<br>• The token travels only in request **bodies**, never in a URL path, so it stays out of access logs. Hook tokens do the opposite (`gateway/src/routes/hooks.rs:30`).<br>• The App link is `thinktin://join/{token}`.<br>• A malformed token gets 404 without a database query. | Same construction as `HookToken` (`auth/src/secrets.rs:131-169`). Deep links use only the custom scheme (`notify/src/lib.rs:137`). |
| D8 | **Caps are checked under the project lock:**<br>• 10 live users, the creator included → **409 `project_member_limit`**;<br>• 30 live agents. Only requested ids without a live row count as new, and agents whose instance is deleted do not count → **409 `project_agent_limit`**;<br>• 20 pending invites per project → **409 `project_invite_limit`**.<br>**Per-inviter limit:** invites per inviter per 24h are counted in the DB under `project_invites/{inviter}`. Exceeding it gives **429** with an exact `Retry-After`.<br>**A cap of 0 means unlimited.** | Product rule (projects-impl:9).<br>• The codes end in `_limit` as `proto/src/api.rs:34-35,83-85` requires. `ErrorBody` carries only `code` and `message` (`api.rs:89-95`), so the App needs three distinct codes to tell the limits apart.<br>• "0 = unlimited" follows `gateway/src/limits.rs:25`.<br>• Index `project_invites_inviter (inviter_id, created_at)` already exists (`0039:95`). |
| D9 | **Read model in 8.14:**<br>• `GET /v1/projects` and `GET /v1/projects/{id}` are **narrow worker queries that check live membership in the same SQL** and return a fixed JSON shape. 8.15 swaps the implementation to `ProjectTx`/`thinktin_member` without changing the JSON.<br>• Invite previews for non-members are worker reads filtered by the actor's phone or the token hash. They show the creator (id and name) and, for other members, only display name, role and agent count. | The tenant cannot read the `projects` row of a joined project: `tenant_read` is creator-only (`0039:181`). Without these reads, joined projects are invisible, and "leave → immediately gone" cannot be tested. projects-impl:54 says 8.14 and 8.15 set the shape together. |
| D10 | **Old `/v1/teams*` stays as is:**<br>• `PATCH` and `DELETE` on a shared project return 409 (`projects.rs:208-210`; header `gateway/src/routes/teams.rs:1-2`);<br>• `GET` lists only projects I created and shows only my agents (`projects.rs:98-125`);<br>• joined projects never appear there. | D3 of the 8.13 plan; old clients cannot render members. |
| D11 | **Consent is an explicit `"consent": true`, enforced twice.**<br>• The gateway returns 422 without it, as in `routes/hooks.rs:41,52-55`.<br>• The store requires it too: `JoinTerms.consent: Consent { version }`, and `add_project_agents(…, consent: Option<Consent>)`, which must be `Some` for members. The creator is exempt, matching `0039:45`.<br>**Where it is recorded:**<br>• `project_members.consented_at`;<br>• `project_agents.consented_at` for each agent a member adds;<br>• an audit row whose detail holds the instance ids, the vendors, the budgets and `consent_version: 1`. The server computes the vendors from `model_routes ∪ model_route_fallbacks → credentials.vendor` (`0001:99,145-155`, `0008:3-15`). | projects-impl "受邀加入"; projects.md §4.3 and §10. |
| D12 | **Only the creator invites** (projects.md §4.2) **and removes.**<br>• Members may add, withdraw or leave only with their own agents.<br>• The creator may also withdraw any agent.<br>• Changing the lead across users belongs to 8.17.<br>• Deleting or archiving a *shared* project belongs to 8.15 (soft delete); until then it returns 409. | The FK from inviter to member (`0039:88`) still lets 8.17 or later allow member invites. |
| D13 | **Cross-user switch.** New `GatewayConfig.cross_user_projects`, set from `[api] cross_user_projects`, default **false**.<br>• When it is off, invite creation, preview, accept and the invitee's invite list return 404.<br>• Solo `/v1/projects` and `/v1/teams` keep working.<br>• Tests turn it on. | projects-impl "迁移与放量": open to many users only after the 15.7 security review. |
| D14 | **Withdraw, leave and remove handle grants and epochs now**, even though they touch 0 rows until 8.17. Each runs in one worker transaction, in this order:<br>1. lock the project runs;<br>2. bump epochs;<br>3. cancel the runs;<br>4. revoke project grants, recursively;<br>5. mark the agent rows left. | 8.13 never writes `project_id` (`0040:3`), and claim and takeover skip project runs (`runs.rs:203-206`). The steps are forward-compatible. Tests seed rows with raw worker SQL, as in `tests.rs:1084-1104`. |
| D15 | **No new `PushKind`.** Receipts use `PushKind::Info` plus new `notice_subtype` strings.<br>• `Info` has no IM fan-out (`orchestrator/src/outbox.rs:65-76`).<br>• The invite push to a stranger carries **no text the inviter controls**. | The push is a lock-screen spam vector. Older clients tolerate unknown subtypes (`proto/src/domain.rs:1067-1069`). |
| D16 | **`/v1/project-templates*` is not in 8.14.** `/v1/team-templates*` (`gateway/src/routes/mod.rs:164-169`) already reads and writes `project_templates` (`store/src/teams.rs:88-140`). Templates are private (projects.md §11), so they are not part of invite and join. The alias and its FFI move to 8.15, ahead of the 12.25/13.18 template UI. | The 8.13 plan's 8.14 row listed it (`projects-8.13-plan.md` §8). This is an explicit deferral, not a silent drop. |
| D17 | **Adopting a new instance during join is two calls.** The App adopts first (tenant `POST /v1/instances`, unchanged), then accepts with the new id. If the accept fails, the new instance stays a private one and the App offers to delete it. Marking an agent `dedicated` is 8.16. | projects.md §4.3 allows adopting during join. Keeping adoption in its own tenant transaction keeps the accept transaction small and worker-only. |

---

## 1. Migration `crates/store/migrations/0047_project_invites.sql` (one transaction)

```sql
-- 邀请与加入（WBS 8.14，docs/projects.md 第 4、9 节，docs/projects-impl.md“受邀加入”，progress/drafts/projects-8.14-plan.md）。
-- 沿用 0039：跨用户的写（建邀请、接受、拒绝、撤回邀请、加入、增派、撤回 agent、退出、移出、拉黑）只走 thinktin_worker，
-- 动作人由服务端从登录态得到；这里不给 thinktin_app 新的表权限，只多一个 projects.goal 的 INSERT 列权限（自己建单人项目时
-- 写目标；改目标走 worker）。邀请相关的表 8.13 才建、8.14 之前没有接口写过，加列、建索引都放在这一个事务里。
-- 锁：这个事务从建 user_blocks（外键）起拿着 users 的 SHARE ROW EXCLUSIVE，从改 inbox_items 起拿着它的 ACCESS EXCLUSIVE，
-- 都到提交。按 0039 的前提（第一次部署之前发布、没有流量）没问题；如果发布时已经有线上库，拆成两个迁移（user_blocks 一个、
-- inbox_items 一个），各自开头 SET LOCAL lock_timeout = '5s'，等不到就失败重跑。

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

-- 不送达（只有手机号邀请）：对方拉黑了邀请人——发的时候已经拉黑，或者之后拉黑时把还没处理的标上。对邀请人照样是
-- “待接受”、到期“已过期”；被邀请人看不到、接受不了。
-- invitee_id（0039）从这一版起表示“通知送达了谁”：号码已注册、对方没拉黑邀请人、不是现有成员、这个号码 24 小时内收到的
-- 通知没到上限才填；接口从不给邀请人看。通知到了上限的邀请照样有效（被邀请人在 App 里按手机号看得到、接受得了），只是
-- 不推送：不能因为别人先发满了，就让这个号码当天真正的邀请悄悄消失。
ALTER TABLE project_invites
    ADD COLUMN suppressed_at timestamptz,
    ADD CONSTRAINT project_invites_suppressed CHECK (suppressed_at IS NULL OR kind = 'phone');
-- 同一个项目同一个号码只留一条待处理的（重复邀请返回原来那条，不多数一次）。
CREATE UNIQUE INDEX project_invites_one_pending ON project_invites (project_id, invitee_phone)
    WHERE status = 'pending' AND kind = 'phone';
-- 一个号码 24 小时收到了几条通知（送达的才算；0039 的 project_invites_phone 只含待处理的）。
CREATE INDEX project_invites_delivered_day ON project_invites (invitee_phone, created_at)
    WHERE invitee_id IS NOT NULL;
-- 后台：到期的标成过期、结束 30 天的删掉（明文手机号不久留）；注销时按接受人删。
CREATE INDEX project_invites_expiry ON project_invites (expires_at) WHERE status = 'pending';
CREATE INDEX project_invites_settled ON project_invites (settled_at) WHERE status <> 'pending';
CREATE INDEX project_invites_accepted_by ON project_invites (accepted_by) WHERE accepted_by IS NOT NULL;

-- 成员（不是创建者）派 agent 进来时确认“项目内容会发给项目里各 agent 用的模型厂商”的时间：加入、增派各记各的。
ALTER TABLE project_agents ADD COLUMN consented_at timestamptz;

-- 收件箱、推送的跳转目标（邀请、加入、退出回执，docs/projects-impl.md 第 6 条）。不加外键（同 vault_request_id、
-- egress_request_id）：项目删了、邀请清理了，回执照样留着，打开时接口回 404。
ALTER TABLE inbox_items ADD COLUMN project_id uuid, ADD COLUMN project_invite_id uuid;
-- 这两列和 subtype 由服务端写（第 1 条：项目归属由服务端派生，更新时不可改）：租户对 inbox_items 有整表的 INSERT、UPDATE
-- （0001），所以靠触发器挡。带项目字段的行只有 thinktin_worker 写得出（白名单，同 0040 的 fill_space）；建了以后谁都不能改
-- 这三列。现有的 UPDATE 只改 read_at，外键的 ON DELETE SET NULL (run_id) 也不在 UPDATE OF 里，都不受影响。
-- 8.15：从运行算 project_id 的逻辑并进这个函数（CREATE OR REPLACE），和传入的不一致就报错；按成员关系收窄读策略时，回执按
-- subtype（回执那几种，已不可改）放行，不能按 run_id 为空放行（run_id 是 ON DELETE SET NULL，运行清掉以后项目运行的通知
-- 也会变成 run_id 为空）。
CREATE FUNCTION inbox_project_guard() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.project_id IS DISTINCT FROM OLD.project_id
           OR NEW.project_invite_id IS DISTINCT FROM OLD.project_invite_id
           OR NEW.subtype IS DISTINCT FROM OLD.subtype THEN
            RAISE EXCEPTION 'inbox_items project fields and subtype cannot change'
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF (NEW.project_id IS NOT NULL OR NEW.project_invite_id IS NOT NULL)
       AND current_user <> 'thinktin_worker' THEN
        RAISE EXCEPTION 'project fields in inbox_items are written by the server only'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION inbox_project_guard() FROM PUBLIC;
CREATE TRIGGER inbox_project_guard BEFORE INSERT OR UPDATE OF project_id, project_invite_id, subtype
    ON inbox_items FOR EACH ROW EXECUTE FUNCTION inbox_project_guard();

-- 自己建单人项目时写目标（POST /v1/projects，租户事务，策略 tenant_insert 不变）。
GRANT INSERT (goal) ON projects TO thinktin_app;
```

Notes:
- **Migration checks.** `tools/ci/check_migrations.py` requires contiguous numbering (`:318`). No statement needs `deploy-safe:`: every change adds a table, a nullable column, an index, a trigger or a grant, and there is no `v*` tag yet.
- **Why the trigger is needed.** Tenant `GRANT SELECT, INSERT, UPDATE ON … inbox_items` is table-level (`0001:468-469`), so without the trigger the tenant could write the new columns.
  - Every existing `UPDATE inbox_items` sets only `read_at`: `inbox.rs:134-254`, `egress.rs:691`, `approvals.rs:160,194`, `instances.rs:412`.
  - `insert_inbox` (`inbox.rs:94-129`) is generic, and tenant callers (`notify_tenant`, `orchestrator/src/outbox.rs:221`) never set the new fields.
  - **The trigger is stricter than the critic's version.** On UPDATE it refuses every role, the worker included, which matches `fill_space` (`0040:9-16`) and impl item 1's "更新时不可改".
- **No other triggers on the table.** No existing trigger on `inbox_items` could fire ahead of this one.

---

## 2. Store API (`crates/store`)

### 2.1 Errors (`crates/store/src/error.rs:5-35`)

```rust
/// 项目人数、agent 数、待处理邀请数到了上限（8.14）：接口回 409 `project_member_limit` / `project_agent_limit` /
/// `project_invite_limit`。
#[error("project limit: {0:?}")]
ProjectLimit(ProjectCap),
/// 按时间窗数的上限（每个邀请人 24 小时的邀请数）：接口回 429，过这么多秒再试。
#[error("retry after {0}s")]
RetryAfter(u64),
/// 是成员，但这件事只有创建者（或 agent 的主人）能做：接口回 403。
#[error("not permitted: {0}")]
NotPermitted(String),

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProjectCap { Members, Agents, PendingInvites }
```

**Numeric conversions.** sqlx cannot bind `u64` to Postgres. All counts read as `i64` go through `crate::unsigned` (`lib.rs:243`; precedent `instances.rs:269`). Every `u64` bound as a parameter (budgets, caps) goes through `crate::signed` (`lib.rs:247`); `MAX_TOKEN_LIMIT = 1e12` fits. Positions use `i32::try_from`, as `projects.rs:79`.

### 2.2 Proto types (`crates/proto/src/domain.rs`)

- **Ids** (`id_type!` at `:52-77`): `ProjectInviteId`. It lands in C3 with the `InboxItem` fields.
- **Enums** (`str_enum!`, after `ProjectStatus` at `:545-554`):
  - `ProjectRole { Creator = "creator", Member = "member" }`
  - `ProjectInviteKind { Phone = "phone", Link = "link" }`
  - `ProjectInviteStatus { Pending, Accepted, Declined, Revoked, Expired }`
- **Constants:**
  - `MAX_PROJECT_USERS: u64 = 10`, `MAX_PROJECT_AGENTS: u64 = 30`, `MAX_PENDING_PROJECT_INVITES: u64 = 20`
  - `PROJECT_INVITE_LINK_TTL_SECS = 72*3600`, `PROJECT_INVITE_PHONE_TTL_SECS = 7*24*3600`
  - `MAX_BLOCKS: u64 = 1000`, `MAX_PROJECT_GOAL_CHARS = 4000`, `MAX_TOKEN_LIMIT: u64 = 1_000_000_000_000`
  - `PROJECT_INVITE_LINK_PREFIX = "thinktin://join/"`, `PROJECT_CONSENT_VERSION: u32 = 1`
- **`pub fn mask_phone(phone: &str) -> String`** moves here from `server/src/admin.rs:221-232`, together with its unit test (`admin.rs:234-246`). The reason is the dependency graph: `auth` depends on `store` (`crates/auth/Cargo.toml`), and `store` depends only on `proto`, so `store` cannot call `auth`. `server` imports the function from `proto`.
- **DTOs**, after `Team` (`:949-961`). None of them carries a phone number. `domain::User` includes `phone` (`:474-484`) and must not be reused.
  - `ProjectPerson { user_id, display_name: Option<String> }`
  - `ProjectSummary { id, name, goal, status, role: ProjectRole, shared, creator: ProjectPerson, member_count: u32, agent_count: u32, my_agent_count: u32, created_at, joined_at }`
  - `ProjectMemberView { user_id, display_name, role, joined_at, agent_count: u32, is_me }` (members' view only)
  - `ProjectAgentView { instance_id, owner_id: UserId, agent_id, name, is_lead, position: u32, added_at, mine }`
  - `ProjectBudget { daily_token_limit: Option<u64>, total_token_limit: Option<u64> }`
  - `ProjectLimits { max_users, max_agents }`
  - `ProjectDetail { #[serde(flatten)] summary: ProjectSummary, members, agents, my_budget: ProjectBudget, limits: ProjectLimits }`
  - `ProjectInvite { id, project_id, kind, status, phone_masked: Option<String>, created_at, expires_at, settled_at: Option<_>, accepted_by: Option<ProjectPerson> }` (the creator's view)
  - `ProjectInvitePreview { invite_id, kind, expires_at, project: ProjectBrief { id, name, goal }, creator: ProjectPerson, members: Vec<ProjectMemberBrief { display_name, role, agent_count }>, users: u32, agents: u32, limits: ProjectLimits, shared_with_project: Vec<String>, kept_private: Vec<String> }`
    - The non-member preview carries **no member `user_id`**. Only the creator's id is included, because blocking needs it.
    - `shared_with_project` keys: `project_goal_and_tasks`, `project_board`, `project_artifacts`, `your_agents_project_runs`, `sent_to_all_agents_vendors`.
    - `kept_private` keys: `private_runs`, `private_board`, `private_artifacts`, `vault`, `computer`, `model_keys`, `costs`, `approvals`.
    - The keys are stable strings that the App localises.
  - `BlockedUser { user_id, display_name, created_at }`
- **Notice subtypes** (`notice_subtype`, `:1070-1088`): `PROJECT_INVITE = "project_invite"`, `PROJECT_JOINED`, `PROJECT_LEFT`, `PROJECT_REMOVED`, `PROJECT_AGENT_LEFT`, `PROJECT_AGENT_REMOVED`. All pass `valid_subtype` (`:1125-1130`); the longest is 21 characters.
- **`InboxItem`** (`:1133-1155`): add `project_id: Option<ProjectId>` and `project_invite_id: Option<ProjectInviteId>`, both `#[serde(default, skip_serializing_if = "Option::is_none")]`.
- **Errors** (`crates/proto/src/api.rs`):
  - add `ErrorCode::ProjectMemberLimit`, `ProjectAgentLimit` and `ProjectInviteLimit`;
  - map all three to 409 in `http_status` (`:63-75`) and include them in `is_limit` (`:83-85`);
  - extend the `limit_codes` test (`:167-175`);
  - `API_VERSION` is not bumped (`:9-11`).

### 2.3 Shared helpers (`crates/store/src/projects.rs`)

- **`impl<R> Tx<R> { pub async fn lock_project(&mut self, id: ProjectId) -> Result<()> }`** runs `SELECT pg_advisory_xact_lock(hashtextextended($1,0))` with `format!("project/{id}")`. The key matches `projects-8.13-plan.md:724`. It is added in **C2**, because erase uses it.
- **`impl Tx<Worker> { pub(crate) async fn lock_projects(&mut self, ids: &mut Vec<ProjectId>) }`** sorts, dedups, then locks in a loop. Do not lock inside a `SELECT … ORDER BY`: Postgres does not guarantee that target-list functions run in sort order. Also added in C2.
- **`pub(crate) async fn lock_users(&mut self, ids: &[UserId]) -> Result<Vec<LockedUser>>`**
  - SQL: `SELECT id, status, phone, display_name FROM users WHERE id = ANY($1) ORDER BY id FOR KEY SHARE`.
  - Missing or deleted users are reported in the result, not raised as errors.
- **`pub(crate) struct ProjectActor { project, user, role: ProjectRole, creator: UserId }`**, built by `async fn project_actor(&mut self, user, project, also: &[UserId], allow: &[ProjectStatus]) -> Result<ProjectActor>`:
  1. Read `creator_id` from `projects` (no lock). Missing → NotFound.
  2. `lock_users({user, creator} ∪ also)`. Actor deleted → NotFound.
  3. `lock_project`.
  4. `SELECT status FROM projects WHERE id=$1`. A status not in `allow` → NotFound.
     - Writes pass `&[Active]`.
     - `leave_project` and `withdraw_project_agent` pass `&[Active, Archived]`.
     - Nothing writes `archived` before 8.15.
  5. `SELECT role FROM project_members WHERE project_id=$1 AND user_id=$2 AND left_at IS NULL FOR NO KEY UPDATE`. No row → NotFound.
  - Helper: `require_creator()` returns `NotPermitted("only the project creator can …")`.
- **Changes to the tenant code:**
  - `writable_solo` (`projects.rs:203`) calls `self.lock_project(id)` first (D4).
  - `create_solo_project(name, goal, agents)` gains `goal` (`projects.rs:53-84`, insert at `:59`). `create_team` (`teams.rs:26-29`) passes `""`.

### 2.4 Worker reads (`crates/store/src/projects.rs`, new `impl Tx<Worker>`)

| Function | SQL / rule |
|---|---|
| `my_projects(user) -> Vec<ProjectSummary>` | `FROM project_members m JOIN projects p ON p.id=m.project_id JOIN users cu ON cu.id=p.creator_id WHERE m.user_id=$1 AND m.left_at IS NULL AND p.status='active' ORDER BY p.created_at, p.id`.<br>Counts come from subqueries on live members, and on live agents joined to `instances.state <> 'deleted'`.<br>Projects I created are included, because every project has a creator row (`0039:128-129`, `projects.rs:64-69`). |
| `project_detail(user, project) -> ProjectDetail` | The same filter with `p.id=$2`; without live membership → NotFound.<br>Members: live rows only, creator first.<br>Agents: live rows only, instance not deleted, `ORDER BY position, instance_id`, with `mine = (a.user_id = $1)`.<br>`my_budget` comes only from the caller's own member row, because budgets belong to each owner (impl item 1). |
| `update_project(user, project, name, goal)` | `project_actor(.., &[Active])` → `require_creator` → `UPDATE projects SET name=coalesce($2,name), goal=coalesce($3,goal), updated_at=now()`. |

### 2.5 Invites and blocks

New file `crates/store/src/project_invites.rs`, registered in `lib.rs:11-38` and re-exported near `lib.rs:75`.

```rust
/// Phone 只找 kind = 'phone' 的邀请；Link 只按哈希找 kind = 'link' 的。链接邀请永远不能按 id 找到。
pub enum InviteKey<'a> { Phone(ProjectInviteId), Link(&'a [u8; 32]) }
/// 0 表示不限（同 LimitConfig）。
pub struct InviteCaps { pub per_inviter_per_day: u64, pub per_phone_per_day: u64 }
pub struct Consent { pub version: u32 }   // 必须等于 PROJECT_CONSENT_VERSION，否则 Invalid
pub struct CreatedInvite { pub invite: ProjectInvite, pub created: bool, pub deliver_to: Option<UserId>, pub project_name: String }
pub struct JoinTerms { pub agents: Vec<InstanceId>, pub daily_token_limit: u64, pub total_token_limit: u64, pub consent: Consent }
pub struct Accepted { pub created: bool, pub project: ProjectId, pub creator: UserId, pub invite: ProjectInviteId,
                      pub project_name: String, pub member_name: Option<String>, pub agents: Vec<InstanceId>, pub vendors: Vec<String> }
```

**`create_phone_invite(user, project, phone /* normalized */, recipient: Option<UserId>, caps, ttl) -> CreatedInvite`**

The orchestrator looks up `recipient` with `user_by_phone` (`users.rs:67-78`) *before* any lock, so R1 can lock it first.

1. `project_actor(user, project, also = recipient, &[Active])` → `require_creator`.
   - The creator must have a `display_name`; otherwise `Invalid("set a display name before inviting")`.
   - Inviting your own phone is `Invalid`.
2. Take the advisory keys (R1 step 4), before any `project_invites` row is touched:
   - `project_invites/{user}` → `project_invite_phone/{phone}` → `user_blocks/{recipient}` when the number is registered.
   - `block_user` takes `user_blocks/{blocker}` before its UPDATE, so the two now serialize.
3. Expire stale pending rows in place: `UPDATE project_invites SET status='expired', settled_at=now() WHERE project_id=$1 AND invitee_phone=$2 AND status='pending' AND expires_at <= now()`.
4. If a live pending row exists for (project, phone), return it with `created=false`: no count, no notice, no cap. A repeat is idempotent even when the inviter is at the cap.
5. Per-inviter cap (skipped when it is 0): `SELECT count(*), min(created_at) FROM project_invites WHERE inviter_id=$1 AND created_at > now() - interval '24 hours'`. If the count ≥ cap → `RetryAfter(ceil(min + 24h − now))`.
6. Live members ≥ 10 → `ProjectLimit(Members)`.
7. Pending invites in the project ≥ 20 → `ProjectLimit(PendingInvites)`.
8. Delivered-notice count, always run so every number costs the same work: `SELECT count(*) FROM project_invites WHERE invitee_phone=$1 AND invitee_id IS NOT NULL AND created_at > now() - interval '24 hours'` (index `project_invites_delivered_day`).
9. Decide.
   - `suppressed` = `recipient` is set and `EXISTS user_blocks(blocker=recipient, blocked=user)`.
   - `deliver_to` = `recipient`, except when the invite is suppressed, the recipient is a live member, or `per_phone_per_day > 0` and the count ≥ the cap.
10. `INSERT … (id, project_id, inviter_id, kind='phone', invitee_phone, invitee_id = deliver_to, expires_at = now()+ttl, suppressed_at = CASE WHEN suppressed THEN now() END)`.

**The returned `ProjectInvite` is identical in every case:** `status=pending`, `phone_masked`, and no recipient or suppression field.

**`create_link_invite(user, project, token_hash: &[u8;32], caps, ttl)`**
- `project_actor(.., &[Active])` → `require_creator` (display name required) → advisory `project_invites/{user}`.
- Then the per-inviter cap, the members cap and the pending cap, as above.
- Insert with `kind='link'`.

**`project_invites(user, project) -> Vec<ProjectInvite>`** (creator only)
- Status is computed lazily: `CASE WHEN status='pending' AND expires_at <= now() THEN 'expired' ELSE status END`.
- Neither `suppressed_at` nor `invitee_id` is ever read into the DTO.
- `phone_masked` comes from `proto::domain::mask_phone`.
- `accepted_by` is joined to the person.
- Order `created_at DESC`, limit 100.

**`revoke_invite(user, project, invite)`**
1. Unlocked read of `(project_id, invitee_id)`. The project id must match, else NotFound.
2. `project_actor(user, project, also = [invitee_id], &[Active])`. The invitee's users row is locked because this flow writes the invitee's inbox (R1, Appendix B V1).
3. `require_creator`, then `SELECT … FOR UPDATE` on the invite.
4. Status `accepted` → `Conflict("invite already accepted")`. Already settled → Ok, idempotent.
5. Otherwise `UPDATE … SET status='revoked', settled_at=now() WHERE id=$1 AND status='pending'`.
6. Mark the delivered item read: `UPDATE inbox_items SET read_at=now() WHERE user_id=$invitee_id AND project_invite_id=$1 AND read_at IS NULL` (uses `inbox_unread`, `0001:384`).

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

The preview fills in the creator (id and name), the members (name, role and agent count only), the counts and the static keys.

**`invite_preview(user, key)`**
- Phone key: the same filter plus `i.id=$2`. The SQL already has `kind='phone'`.
- Link key: `token_hash=$1 AND kind='link' AND status='pending' AND expires_at > now()`, project active.
- Links are **not** filtered by blocks: the user opened the link deliberately (open question).
- Every other case returns one uniform `NotFound`.

**`accept_invite(user, key, terms) -> Accepted`** (R1 order, one transaction)
1. Validate `terms` without the DB:
   - agents 1..=30, distinct;
   - each budget in 1..=`MAX_TOKEN_LIMIT`, with daily ≤ total;
   - `terms.consent.version == PROJECT_CONSENT_VERSION`.
   - Otherwise `Invalid`.
2. Unlocked find → `(invite_id, project_id, creator)`. Phone key: `WHERE id=$1 AND kind='phone'`. Link key: `WHERE token_hash=$1 AND kind='link'`. Miss → NotFound.
3. `lock_users({user, creator})`. Actor deleted → NotFound. Then `lock_project`. Project not active → NotFound.
4. Read the actor's member row: `SELECT role, left_at FROM project_members WHERE project_id=$1 AND user_id=$2 FOR NO KEY UPDATE` (it may be absent).
5. `SELECT status, expires_at > statement_timestamp(), accepted_by, kind, invitee_phone, suppressed_at, inviter_id FROM project_invites WHERE id=$1 FOR UPDATE`.
   - **Idempotency:** `status='accepted' AND accepted_by=user`, and the step-4 row is live → return `Accepted{created:false,…}` without writing anything.
   - A phone invite must also hold `invitee_phone = actor.phone`, `suppressed_at IS NULL`, and the actor must not have blocked the inviter.
   - Anything else (expired, revoked, declined, accepted by someone else, wrong phone) → NotFound.
   - The step-4 row is live → `Conflict("already a member")`. The invite is **not** consumed.
6. Caps:
   - live users + 1 > 10 → `ProjectLimit(Members)`;
   - live agents + new > 30 → `ProjectLimit(Agents)`, where new = requested ids that have no live row. On join that is all of them, because leaving marks every agent row left.
7. Instances: `SELECT id FROM instances WHERE id = ANY($1) AND user_id=$2 AND state <> 'deleted' ORDER BY id FOR SHARE`. The row count must equal the number of distinct ids; otherwise NotFound (`instance`). The error says nothing about whose instance it is.
8. Member upsert: a first-time insert, or a rejoin after leaving or removal.
   - The AFTER INSERT trigger sets `shared_at` on the first insert (`0039:158-167`).
   - A rejoin takes the DO UPDATE path, which does not fire that trigger; `shared_at` is already set.

   ```sql
   INSERT INTO project_members (project_id,user_id,role,daily_token_limit,total_token_limit,consented_at)
   VALUES ($1,$2,'member',$3,$4,now())
   ON CONFLICT (project_id,user_id) DO UPDATE SET daily_token_limit=EXCLUDED.daily_token_limit,
     total_token_limit=EXCLUDED.total_token_limit, consented_at=now(), joined_at=now(), left_at=NULL, left_reason=NULL
   WHERE project_members.role='member' AND project_members.left_at IS NOT NULL
   ```
9. Agents, updated in place (mirrors `projects.rs:171-177`).
   - `dedicated=false` avoids clashing with `project_agent_dedicated` (`0039:69`).
   - Positions start at `coalesce(max(position),-1)+1`.

   ```sql
   INSERT INTO project_agents (project_id,instance_id,user_id,position,consented_at) VALUES ($1,$2,$3,$4,now())
   ON CONFLICT (project_id,instance_id) DO UPDATE SET left_at=NULL, is_lead=false, dedicated=false,
     added_at=now(), consented_at=now(), position=EXCLUDED.position WHERE project_agents.left_at IS NOT NULL
   ```
10. Settle: `UPDATE project_invites SET status='accepted', settled_at=now(), accepted_by=$2 WHERE id=$1 AND status='pending' AND expires_at > statement_timestamp()`. It must affect 1 row; otherwise NotFound, and the transaction rolls back. `statement_timestamp()` keeps the boundary exact for an accept that waited on locks.
11. Mark the actor's inbox item for this invite read (`user_id=$2 AND project_invite_id=$1`).
12. Compute `vendors`, fallback routes included:

    ```sql
    SELECT DISTINCT c.vendor FROM (
      SELECT credential_id, user_id FROM model_routes WHERE user_id=$1 AND instance_id=ANY($2)
      UNION SELECT credential_id, user_id FROM model_route_fallbacks WHERE user_id=$1 AND instance_id=ANY($2)
    ) r JOIN credentials c ON c.id=r.credential_id AND c.user_id=r.user_id ORDER BY 1
    ```

**`decline_invite(user, invite, block: bool)`**
1. Unlocked read: `WHERE id=$1 AND kind='phone'` gives (project, inviter, phone, status, suppressed_at, expiry). The invite must be addressed to me (phone match), pending, unexpired and not suppressed; otherwise NotFound.
2. `block=false`:
   - `lock_users({user, inviter})` → `lock_project` → invite row `FOR UPDATE`;
   - re-check, then `UPDATE … SET status='declined', settled_at=now() WHERE id=$1 AND status='pending'`;
   - mark my inbox item read.
3. `block=true` follows the same path as `block_user`, with no project lock:
   - `lock_users({user, inviter})` → `user_blocks/{user}` → insert the block;
   - the suppress UPDATE, which covers this invite and leaves it `pending` (D6);
   - mark my inbox items read.
   - **Why no project lock:** accept re-checks `suppressed_at` after its own `FOR UPDATE`. If accept committed first, the suppress UPDATE skips the now-accepted row and the block still applies.

**`block_user(user, blocked)` / `unblock_user(user, blocked)` / `blocks(user) -> Vec<BlockedUser>`**
- **Checks.** Self → `Invalid`. `lock_users({user, blocked})`; an unknown or deleted target → **NotFound** (404).
- **Count.** Advisory `user_blocks/{user}`. Count ≥ `MAX_BLOCKS` → `Invalid`.
- **Write.** `INSERT … ON CONFLICT DO NOTHING`.
- **Suppress.**
  - `UPDATE project_invites SET suppressed_at=now() WHERE kind='phone' AND inviter_id=$2 AND invitee_phone=$phone AND status='pending' AND suppressed_at IS NULL RETURNING id`.
  - Then `UPDATE inbox_items SET read_at=now() WHERE user_id=$1 AND project_invite_id = ANY($ids) AND read_at IS NULL`.
  - The suppressed rows can belong to other projects. Row locks are enough here: accept re-checks `suppressed_at` after its own `FOR UPDATE`.
- **Unblock.** `lock_users({user})` → DELETE. It is idempotent and does not resurrect suppressed invites.

**Background sweeps** (each in its own transaction, §3)
- **`expire_project_invites(batch: i64) -> u64`**
  1. `UPDATE project_invites SET status='expired', settled_at=now() WHERE id IN (SELECT id FROM project_invites WHERE status='pending' AND expires_at <= now() ORDER BY expires_at LIMIT $1 FOR UPDATE SKIP LOCKED) RETURNING id, invitee_id`.
  2. `UPDATE inbox_items SET read_at=now() WHERE id IN (SELECT id FROM inbox_items WHERE user_id = ANY($users) AND project_invite_id = ANY($invites) AND read_at IS NULL FOR UPDATE SKIP LOCKED)`.
  - The sweep never waits. A skipped inbox row is being deleted (erase or the tenant) or marked read by its owner (Appendix B V2).
- **`purge_project_invites(older_than, batch) -> u64`**: `DELETE FROM project_invites WHERE id IN (SELECT id FROM project_invites WHERE status <> 'pending' AND settled_at < now() - $1 LIMIT $2)` (30 days), so plaintext phone numbers do not linger.

### 2.6 Membership changes (new `crates/store/src/project_members.rs`)

**Run and grant helpers**
- **New `impl Tx<Worker>` functions in `runs.rs`**, after `cancel_user_runs` (`:835-855`). Each one uses `lock_runs_where!`, then `bump_epochs_where!`, then an `UPDATE … state='cancelled'`, all with literal filters (macros at `:345-366`).
  - `cancel_project_agent_runs(project, instance, reason)` with the filter `"(project_id = $1 AND instance_id = $2 OR root_run_id IN (SELECT id FROM runs WHERE project_id = $1 AND instance_id = $2 AND parent_run_id IS NULL))"`. This mirrors `cancel_instance_runs` (`:783-813`).
  - `cancel_project_member_runs(project, user, reason)`: the same with `user_id = $2`.
- **New functions in `grants.rs`**, next to `revoke_instance_grants` (`:210-230`):
  - `revoke_project_agent_grants(project, instance, reason)`: `WITH RECURSIVE tree AS (SELECT id FROM run_grants WHERE project_id=$1 AND instance_id=$2 UNION SELECT g.id FROM run_grants g JOIN tree t ON g.parent_id=t.id) UPDATE … revoked_at=now()`. Index `run_grants_project` (`0044:3`) serves it.
  - `revoke_project_member_grants(project, user, reason)`: the same with `user_id = $2`.
- **Private runs and grants on the same instance are untouched.** `bump_epochs_where!` bumps an instance only when the matching project run is its active agent run. `runs_one_active_per_instance` (`0002_collaboration.sql:49`) allows only one such run, so private sandbox tokens survive.

**Functions** (all `impl Tx<Worker>`; the user is always server-derived; ints converted per §2.1):

| Function | Locks (R1) | Checks | Writes | Idempotency |
|---|---|---|---|---|
| `add_project_agents(user, project, agents, consent: Option<Consent>) -> Vec<InstanceId>` | `project_actor(.., &[Active])` → own member row → agent rows → instances `FOR SHARE` (id order) | Live member.<br>Members need `Some(consent)` with the current version, else `Invalid`.<br>Agents 1..=30 and distinct.<br>new = requested ids with no live row; live + new > 30 → `ProjectLimit(Agents)`.<br>Instances must be the caller's own and not deleted, else NotFound. | Agent upsert as in accept step 9. `consented_at=now()` for members, NULL for the creator. | Already-live agents are skipped. Returns only the agents actually added; at 30 agents, re-sending a live one returns `[]`. |
| `withdraw_project_agent(user, project, instance) -> Withdrawn{owner, name, already_left, runs, grants}` | Unlocked read of the owner → `project_actor(also=[owner], &[Active, Archived])` → owner's member row → agent row `FOR NO KEY UPDATE` → runs → instances (epoch) | The actor is the owner or the creator, else `NotPermitted`. No agent row → NotFound. | `cancel_project_agent_runs`, `revoke_project_agent_grants`, `UPDATE project_agents SET is_lead=false, left_at=now()` (CHECK `0039:65`). | `left_at` already set → `already_left=true`, no writes. |
| `leave_project(user, project) -> Exit` | `project_actor(&[Active, Archived])` → own agent rows → runs → instances | Creator → `Conflict("the creator cannot leave; delete the project instead")`; CHECK at `0039:44`. | `exit_member(project, user, 'left')`. | A former member gets NotFound: they no longer see the project. |
| `remove_project_member(user, project, member) -> Exit` | `project_actor(also=[member], &[Active])` → member row → that member's agent rows → runs → instances | `require_creator`. Target is the creator → `Invalid`. Never a member → NotFound. | `exit_member(project, member, 'removed')`. | Already left or removed → Ok, no writes. |
| `set_project_budget(user, project, budget)` | `project_actor(&[Active])` | Members need both values, each in 1..=`MAX_TOKEN_LIMIT`, with daily ≤ total. The creator may use null. | `UPDATE project_members SET daily_token_limit, total_token_limit`. | Plain set. |
| `retire_deleted_instance(user, instance) -> u64` | projects in id order (`lock_projects`) → agent rows | `instances.state='deleted' AND user_id=$1`. | `UPDATE project_agents SET is_lead=false, left_at=now() WHERE project_id=$p AND instance_id=$2 AND left_at IS NULL`.<br>Runs and grants were already cancelled by the tenant delete, because those rows carry the owner's `user_id`. | Repeatable. |
| `retire_deleted_project_agents(batch) -> u64` | `pg_try_advisory_xact_lock` per project; busy projects are skipped | Live agent rows whose instance is deleted. | The same update. | Sweep backstop. |

**`exit_member(project, uid, reason)`** is private. It runs these steps in order:
1. `cancel_project_member_runs`.
2. `revoke_project_member_grants`.
3. `UPDATE project_agents SET is_lead=false, left_at=now() WHERE project_id=$1 AND user_id=$2 AND left_at IS NULL`.
4. `UPDATE project_members SET left_at=now(), left_reason=$3 WHERE project_id=$1 AND user_id=$2 AND left_at IS NULL`.
5. `UPDATE project_invites SET status='revoked', settled_at=now() WHERE project_id=$1 AND inviter_id=$2 AND status='pending'`. This touches 0 rows in 8.14, because only creators invite. It covers `0039:88`: leaving only sets `left_at`, so the FK cascade never fires.

The result `Exit { creator, member_name, project_name, runs_cancelled, grants_revoked }` feeds the receipts.

### 2.7 Changes to existing store code

- **`users.rs::erase_account`** (`:183-242`):
  - Right after the `users … FOR UPDATE` at `:186-189`, collect `projects WHERE creator_id=$1` ∪ live `project_members` ∪ live `project_agents`, and call `lock_projects`.
    - This keeps erase ordered against D4's tenant lock: `update_team` locks the `projects` row and then `project_agents` rows, while erase's statements at `:216` and `:218` go the other way.
    - The comment in the code says so.
  - Add `OR accepted_by = $1` to the invite DELETE at `:221-222`.
  - Add `"DELETE FROM user_blocks WHERE blocker_id = $1 OR blocked_id = $1"`.
- **`teams.rs:27`**: pass `""` as the goal.
- **`inbox.rs`**:
  - add `project_id` and `project_invite_id` to `NewInboxItem` (`:12-30`), to `columns!()` (`:32-37`), to the `Row` mapping (`:39-89`) and to `insert_inbox` (`:94-129`);
  - fix the literal at `client-core/src/cache.rs:566-567`.

---

## 3. Orchestrator (`crates/orchestrator/src/projects.rs`, new; `texts.rs`; `outbox.rs`)

Each wrapper:
- opens one `db.worker()`;
- calls the store function;
- writes audit rows with `w.audit(Some(uid), actor, …)` (`store/src/outbox.rs:121-130`). A cross-user action gets one row per affected user. Audit detail never contains phone numbers, and a row for one user never contains the other user's instance ids or vendors;
- sends receipts through `notify(&mut w, uid, &notice)` (`outbox.rs:201-218`);
- commits.

The gateway calls only these wrappers. Precedent: `orchestrator::account::stop_all` (`account.rs:91-112`).

| Wrapper | Audit rows (action → user) | Receipt (subtype → recipient) |
|---|---|---|
| `invite_phone(db, user, actor, project, phone, caps)` (looks up `user_by_phone` first) | `project.invite.create` → creator (`{project, invite, kind}`), when `created` | `project_invite` → `deliver_to`, when `created` and `deliver_to` is set. Dedupe `project_invite:{id}`, collapse `project_invite:{id}`, `project_invite_id` set, TTL 7d. |
| `invite_link(…, token_hash)` | the same | none |
| `revoke_invite` | `project.invite.revoke` → creator | none (the invitee's item is marked read) |
| `accept(db, user, actor, key, terms)` | `project.join` → joiner (`{project, invite, instances, vendors, daily, total, consent_version}`); `project.member_joined` → creator (`{project, invite, member}` only) | `project_joined` → creator, dedupe `project_joined:{invite}`, when `created` |
| `decline(…, block)` | `project.invite.decline` or `user.block` → invitee | none |
| `add_agents` | `project.agents.add` → owner (`{instances, vendors, consented}`) | none |
| `withdraw_agent` | `project.agent.withdraw` → actor, plus the owner if different | `project_agent_removed` → owner, if the creator did it; `project_agent_left` → creator, if the owner did it |
| `leave` | `project.leave` → leaver; `project.member_left` → creator | `project_left` → creator |
| `remove_member` | `project.member.remove` → creator; `project.removed` → member | `project_removed` → member |
| `set_budget`, `update_project`, `block`, `unblock` | `project.budget.set`, `project.update`, `user.block`, `user.unblock` | none |
| `retire_deleted_instance(db, user, instance)` | none (the tenant delete already wrote `instance.delete`) | none (8.19) |

**`Notice`** (`outbox.rs:99-126`):
- add `project: Option<ProjectId>` and `project_invite: Option<ProjectInviteId>`;
- copy them in `inbox()` (`:149-164`), and in `push()` (`:173-195`) into `PushTarget`.

**Texts** (`texts.rs`, in the style of `report_handled` at `:200-211`):
- `project_invite(locale) -> (&str, &str)`: zh `("项目邀请", "有人邀请你加入一个项目，打开 App 查看")`, en `("Project invite", "Someone invited you to a project. Open the app to see it.")`. It contains no names (D15).
- `project_joined(locale, who: Option<&str>, project, agents: usize)`
- `project_left(locale, who, project)`
- `project_removed(locale, project)`
- `project_agent_removed(locale, agent, project)`
- `project_agent_left(locale, who, agent, project)`
- A missing display name falls back to 「一位成员」 / "A member".

**`server/src/workers.rs::maintain`** (`:457-517`): the first transaction (`:460-487`) is **not** changed. It runs event-partition DDL (`ensure_event_partitions` / `drop_event_partitions_before`, `0001:288-316`), and anything that waits there would hold those locks. After its commit, and in the style of the egress purge loop (`:488-503`), add:
- `expire_project_invites(PROJECT_INVITE_BATCH)` in its own worker transactions, looping until a batch comes back short or a max-batches bound is reached;
- `retire_deleted_project_agents(PROJECT_INVITE_BATCH)` in its own transaction; busy projects are skipped with `pg_try_advisory_xact_lock`;
- `purge_project_invites(PROJECT_INVITE_RETENTION /* 30 d */, batch)`, batched the same way and added to `purged`.

---

## 4. Gateway

### 4.1 Routes (`crates/gateway/src/routes/mod.rs`)

- Add `mod projects; mod project_invites;` (`:3-21`).
- Add a block after teams (`:158-169`), marked `// 项目、邀请与加入（8.14）`.
- Static segments next to `{id}` follow the precedent of `/v1/inbox/read` and `/v1/inbox/{id}` (`:181-183`).

| Method & path | Handler | Transaction | Who | Request | Success |
|---|---|---|---|---|---|
| `GET /v1/projects` | `projects::list` | worker read | any | – | 200 `{"projects":[ProjectSummary]}` |
| `POST /v1/projects` | `projects::create` | tenant `create_solo_project`, then worker `project_detail` | any | `{"name","goal"?:"","agents":[{"instance_id","is_lead"?}]}`. Name 1–64, goal ≤4000, agents 1–30, at most one lead. | 201 `ProjectDetail` |
| `GET /v1/projects/{id}` | `projects::get` | worker read | live member | – | 200 `ProjectDetail` |
| `PATCH /v1/projects/{id}` | `projects::update` | worker | creator | `{"name"?, "goal"?}` (`present`, `mod.rs:208-215`) | 200 `ProjectDetail` |
| `DELETE /v1/projects/{id}` | `projects::delete` | tenant `delete_solo_project` | creator | – | 204. A shared project gives 409 until 8.15. |
| `POST /v1/projects/{id}/agents` | `projects::add_agents` | worker | member (own agents) | `{"agents":[{"instance_id"}],"consent":bool}` | 200 `ProjectDetail` |
| `DELETE /v1/projects/{id}/agents/{instance_id}` | `projects::withdraw_agent` | worker | owner or creator | – | 204 |
| `PUT /v1/projects/{id}/budget` | `projects::set_budget` | worker | member | `{"daily_token_limit","total_token_limit"}` | 200 `ProjectBudget` |
| `POST /v1/projects/{id}/leave` | `projects::leave` | worker | member, not creator | – | 204 |
| `DELETE /v1/projects/{id}/members/{user_id}` | `projects::remove_member` | worker | creator | – | 204 |
| `GET /v1/projects/{id}/invites` | `projects::invites` | worker | creator | – | 200 `{"invites":[ProjectInvite]}` |
| `POST /v1/projects/{id}/invites` | `projects::create_invite` | worker | creator; gated (D13) | `{"phone":"138…"}` xor `{"link":true}` | Phone: **always 201** `{"invite":ProjectInvite}`, new or existing.<br>Link: 201 `{"invite":…,"token":"tpi1_…","link":"thinktin://join/tpi1_…"}`; the token is shown only this once. |
| `DELETE /v1/projects/{id}/invites/{invite_id}` | `projects::revoke_invite` | worker | creator | – | 204 |
| `GET /v1/project-invites` | `project_invites::mine` | worker read | any; gated | – | 200 `{"invites":[ProjectInvitePreview]}` |
| `GET /v1/project-invites/{id}` | `project_invites::get` | worker read | addressee; gated; phone invites only | – | 200 `ProjectInvitePreview` |
| `POST /v1/project-invites/resolve` | `project_invites::resolve` | worker read | any; gated | `{"token"}` | 200 `ProjectInvitePreview` |
| `POST /v1/project-invites/{id}/accept` | `project_invites::accept` | worker | addressee; gated; phone invites only | JoinReq | 201 `ProjectDetail` (joined now) / 200 (repeat) |
| `POST /v1/project-invites/accept` | `project_invites::accept_link` | worker | token holder; gated | JoinReq + `"token"` | 201 / 200 `ProjectDetail` |
| `POST /v1/project-invites/{id}/decline` | `project_invites::decline` | worker | addressee; phone invites only | `{"block"?:false}` | 204 |
| `GET /v1/blocks` | `project_invites::blocks` | worker read | any | – | 200 `{"blocks":[BlockedUser]}` |
| `PUT /v1/blocks/{user_id}` | `project_invites::block` | worker | any | – | 204; 404 for an unknown or deleted user |
| `DELETE /v1/blocks/{user_id}` | `project_invites::unblock` | worker | any | – | 204 |

A link invite is never reachable through `/v1/project-invites/{id}/*`: the store's phone key filters `kind='phone'`.

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
| 422 `invalid` | bad phone (`auth::secrets::normalize_phone`, `secrets.rs:26-47`); both or neither of phone and link; inviting your own phone; creator has no display name; missing consent; budgets missing, ≤0, over `MAX_TOKEN_LIMIT` or daily > total; agents empty, duplicated or more than 30; goal or name length (`check_len`, `mod.rs:218-231`); blocking yourself; more than `MAX_BLOCKS` blocks |
| 404 `not_found` | non-member; unknown project, invite, instance or block target; malformed, unknown, used, expired or revoked token (one uniform body, `"invite not found"`); a link invite's id used on an `/{id}` route; bad path id (`parse_id`, `mod.rs:203-206`); cross-user routes while D13 is off |
| 403 `forbidden` | a member calling a creator-only route; a non-owner withdrawing someone else's agent. New helper `ApiError::forbidden`. |
| 409 `project_member_limit` / `project_agent_limit` / `project_invite_limit` | the caps in D8 |
| 409 `conflict` | already a member; the creator leaves; revoking an accepted invite; old teams writes and `DELETE /v1/projects/{id}` on a shared project |
| 429 `rate_limited` + `Retry-After` | the per-inviter daily cap |

**Error mapping** (`gateway/src/error.rs:67-80`):
- `store::Error::ProjectLimit(ProjectCap::Members | Agents | PendingInvites)` → `ProjectMemberLimit` / `ProjectAgentLimit` / `ProjectInviteLimit` (409);
- `RetryAfter(s)` → `RateLimited` with `retry_after_secs`;
- `NotPermitted(m)` → `Forbidden` (403).

`Forbidden` (42501) still maps to 500 until 8.15 (`error.rs:77`).

### 4.2 Rate limits

Additions to `LimitConfig` (`gateway/src/limits.rs:26-55`, defaults at `:57-74`, configured as `[api.limits]`). **0 = unlimited** (`:25`).

| Field | Default | Mechanism |
|---|---|---|
| `invites_per_day` | 20 | DB count under `project_invites/{inviter}`. Exceeding it gives `RetryAfter` → 429. Applies to phone and link invites alike. |
| `invites_per_phone_per_day` | 5 | DB count of **delivered notices** under `project_invite_phone/{e164}`. Over it, the invite is still created and visible in-app; only the notice is withheld. Never an error. |

- The handler reads both values through `s.limits().config()` (`limits.rs:131`), as `teams.rs:191` does, and passes them as `InviteCaps`.
- No in-memory invite buckets. The per-user limiter (`limits.rs:176-179`, 1200/min) covers floods, and 256-bit tokens cannot be brute-forced.
- Document both fields in `docs/compliance.md` next to `reports_per_hour` (`:34`).

### 4.3 Uniform phone results, token handling and consent

**Phone invite path** (`projects::create_invite`):
1. `normalize_phone`.
2. `orchestrator::projects::invite_phone(&s.db, who.user, &who.actor(), id, &e164, caps)`.
3. Respond **201** with `{"invite": …}`.

Registration, blocking and the per-phone cap only decide `deliver_to` and `suppressed_at` inside the store; neither is ever serialised. Residual risk: for a delivered number, the notice adds two inserts (inbox and outbox), so timing can differ slightly (open question).

**Link tokens:**
- New `auth::secrets::InviteToken` with `generate`, `parse` (prefix `tpi1_` plus 43 base64url characters), `as_str` and `hash() -> [u8;32]` (SHA-256). Build it and `HookToken` (`secrets.rs:131-169`) from a shared private helper.
- A `parse` failure → 404 without a database query, with the same body as an unknown token.

**Consent:**
- The handler returns 422 when `consent != true`, except when the creator adds their own agents.
- It then passes `Consent { version: PROJECT_CONSENT_VERSION }`. The store refuses without it (D11).
- The orchestrator writes the `project.join` or `project.agents.add` audit row, with server-computed vendors and `consent_version`.

**Gate:** `fn cross_user(s) -> ApiResult<()>` returns `not_found("route")` unless `s.cfg.cross_user_projects` is set.
- New field in `GatewayConfig` (`gateway/src/lib.rs:29-61`, default `false`).
- New field in the `Api` struct of `server/src/config.rs` (`:123-141`; `deny_unknown_fields`; default `false`).
- Wired in `server/src/api.rs:105-111`.

### 4.4 Instance delete (`gateway/src/routes/instances.rs:372-393`)

- After `t.commit()`, call `orchestrator::projects::retire_deleted_instance(&s.db, who.user, id)`.
- On error, `warn!` and still return 204; the `maintain` sweep is the backstop.
- The tenant UPDATE at `store/src/instances.rs:396-402` silently skips shared projects because of the policy at `0039:203-209`.
- Readers already ignore deleted instances (`i.state <> 'deleted'` in every count and list).

### 4.5 `/v1/teams`

No behaviour change. Add tests on a shared project:
- `PATCH` and `DELETE` return 409;
- `GET /v1/teams/{id}` shows only the creator's agents;
- the joined member's `GET /v1/teams` does not list the project.

`writable_solo` now takes the project lock (D4).

---

## 5. Notifications: minimal receipts for 8.14 (projects-impl item 6)

- **What 8.14 sends:** six subtypes (§3), always `PushKind::Info`, always written to the recipient's private inbox through `notify`, in the same worker transaction as the state change.
  - `project_invite` goes only to a delivered registered number (D5). Its text is generic (D15).
  - Settling an invite (accepted, declined, revoked, expired, suppressed) marks the invitee's item read.
- **Not sent in 8.14:**
  - no notice for decline; the creator sees `declined` in the invite list;
  - no notice when someone later registers with a number that has a pending invite (8.19 can hook `Login.new_user`, `auth/src/service.rs:138`);
  - no notice for an erased member, a deleted project or task results (8.19);
  - nothing for IM.
- **`notify::PushTarget`** (`crates/notify/src/lib.rs:130-143`): add `project_id` and `project_invite_id` with `serde(default, skip_serializing_if)`. Add the keys to each channel's list:
  - APNs: `("project", …)` and `("project_invite", …)` (`apns.rs:138-147`);
  - FCM: `tt_project` and `tt_project_invite` (`fcm.rs:243-251`);
  - JPush: the same `tt_*` keys (`jpush.rs:107-116`);
  - extend the channel tests at `apns.rs:414-422`, `fcm/tests.rs:194` and `jpush.rs:344`.
- **`docs/push.md`:**
  - add the new keys to the payload section (`:58-68`) and the subtypes to the table (`:80-89`);
  - App routing (12.25/13.18): `project_invite` → `thinktin://project-invite/{id}`; the other subtypes → `thinktin://project/{id}`.

---

## 6. client-core FFI

**`crates/client-core/src/api.rs`:** a new section `// ---------- 项目、邀请（8.14） ----------` after teams (`:1722-1818`), in the same style: a local `R` wrapper for lists, `json!` bodies, and a PATCH body built as a `Map` of the fields present. Lists use `#[serde(deserialize_with = "crate::lenient::vec")]`. Methods:
- `projects`, `project`, `create_project`, `update_project`, `delete_project`
- `add_project_agents`, `withdraw_project_agent`, `set_project_budget`, `leave_project`, `remove_project_member`
- `project_invites`, `invite_by_phone`, `create_invite_link`, `revoke_project_invite`
- `my_project_invites`, `project_invite`, `resolve_invite_link`
- `accept_project_invite`, `accept_invite_link`, `decline_project_invite`
- `blocks`, `block_user`, `unblock_user`

**`crates/client-core/src/ffi.rs` records**, near `Team` (`:848`). All are `#[derive(Debug, Clone, uniffi::Record)]` with `From<d::…>`:
- `ProjectPerson`
- `Project` (summary)
- `ProjectMember`
- `ProjectMemberBrief` (preview: no `user_id`)
- `ProjectAgent`
- `ProjectBudget { daily_token_limit: Option<u64>, total_token_limit: Option<u64> }`
- `ProjectDetail { project: Project, members, agents, my_budget, max_users: u32, max_agents: u32 }`
- `ProjectInvite`
- `ProjectInviteLink { invite, token, link }`
- `ProjectInvitePreview`
- `BlockedUser`
- Inputs: `ProjectAgentInput { instance_id, is_lead }` and `ProjectJoin { instance_ids: Vec<String>, daily_token_limit: u64, total_token_limit: u64, consent: bool }`.
- Conventions (`ffi.rs:1-45`): ids are `String`, times are `*_ms: i64`, enums are strings.

**`InboxItem` record** (`:998-1040`): add `project_id` and `project_invite_id` with `#[uniffi(default = None)]`. Add an assertion of the defaults to `tools/client-core/ffi_smoke.py`, which has no `InboxItem` check yet.

**Exported methods** on `ThinktinClient`, after the team block (`:2594-2708`), via `self.run(|c| …)`:
- `projects()`, `project(project_id)`, `create_project(name, goal, agents)`, `update_project(project_id, name, goal)`, `delete_project`
- `add_project_agents(project_id, instance_ids, consent)`, `withdraw_project_agent(project_id, instance_id)`, `set_project_budget(project_id, budget)`, `leave_project`, `remove_project_member(project_id, user_id)`
- `project_invites(project_id)`, `invite_to_project_by_phone(project_id, phone)`, `create_project_invite_link(project_id)`, `revoke_project_invite(project_id, invite_id)`
- `my_project_invites()`, `project_invite(invite_id)`, `resolve_project_invite_link(link_or_token)`
- `accept_project_invite(invite_id, join)`, `accept_project_invite_link(link_or_token, join)`, `decline_project_invite(invite_id, block)`
- `blocked_users()`, `block_user(user_id)`, `unblock_user(user_id)`

**Free function:** `#[uniffi::export] fn project_invite_token(text: String) -> Option<String>` accepts `thinktin://join/<tok>` or a bare token, and checks the `tpi1_` + 43 base64url format locally. A malformed link gives `ClientError::InvalidArgument` without a network call.

**Errors:**
- The mechanism is unchanged: `ClientError::Api { status, code, … }` passes the three `project_*_limit` codes (409) through raw (`error.rs:19-29`), and 429 arrives with `retry_after_secs`.
- Document the three codes in the `Api` variant doc (`error.rs:19-21`).

**Bindings:**
- **Android:** `apps/android/scripts/sync-core.sh --bindings-only` regenerates `apps/android/core/src/main/kotlin/cn/thinktin/core/client_core.kt`, committed on its own (precedents `4f4950d`, `c2b8892`). CI runs `sync-core.sh --check` (`.github/workflows/android.yml:59`).
- **Apple: no `apps/apple/**` commit is expected.** Swift bindings are generated at build time, and the only change to an existing record is two defaulted fields on `InboxItem`, which keeps the generated inits source-compatible. If a Swift test helper turns out to build the generated record positionally, fix it in a separate `apps/apple/**` commit.
- **Adapters:** the App adapters (`CoreThinktinService.kt`, `CoreClient.swift`) belong to 12.25 and 13.18.

---

## 7. Tests

### 7.1 Store, against real Postgres

New file `crates/store/src/tests/projects.rs`, declared with `mod projects;` inside `tests.rs`. `tests.rs` is a single non-mod-rs file (6520 lines), so the child module lives in `src/tests/`. It reuses `super::user()` and `super::instance()` (`tests.rs:20-42`) and TestDb, which migrates as the non-superuser owner (8.13 D8).

Users: alice is the creator, bob the invitee, carol the outsider or blocker, dave and erin for the cap, plus one unregistered number. Where a store test needs an inbox row, it inserts one with `insert_inbox` (worker) and `project_invite_id` set, because only the orchestrator writes notices.

1. **`phone_invites_look_the_same_whoever_owns_the_number`** (C6)
   - alice invites five numbers: bob's (registered); an unregistered one; carol's (after carol blocks alice); dave's (with `per_phone_per_day = 1`, after erin's invite has already been delivered to dave today); and an existing member's.
   - Every returned `ProjectInvite` is equal after normalising the id, time fields and `phone_masked`.
   - `deliver_to` is `Some(bob)` for bob and `None` for the others.
   - `suppressed_at` is set only on carol's row. dave's row has `invitee_id IS NULL` and `suppressed_at IS NULL`.
   - `invites_for(carol)` is empty, and `invites_for(dave)` contains the invite (visible, no notice).
   - The unregistered number registers (`upsert_user_by_phone`) and then sees the invite.
   - Re-inviting bob returns the same id with `created=false`, is not counted, and still succeeds with the inviter at the daily cap.
   - Caps of 0 skip both checks.
2. **`link_invites_are_hashed_single_use_and_idempotent`** (C7)
   - No column holds the raw token: `token_hash = sha256(token)`, and a scan of `project_invites` for the token text finds nothing.
   - bob accepts → `created=true`; bob again → `created=false` with the same detail. carol with the same hash → NotFound.
   - **Accepting a link invite through `InviteKey::Phone(its id)` → NotFound, and `invite_preview` by id → NotFound.**
   - Forced expiry with worker SQL `expires_at = now() - '1s'` → NotFound. Then `expire_project_invites` flips the status, and the hand-inserted inbox item is read.
3. **`accept_races_revoke_and_expiry`** (C7)
   - 20 rounds with a `tokio::sync::Barrier`, running `accept_invite` (bob) against `revoke_invite` (alice).
   - 20 more rounds against `expire_project_invites`, with `expires_at` forced to just after the barrier.
   - Exactly one wins each round. Final state: `accepted` ⇔ bob is a live member; `revoked` or `expired` ⇔ he is not.
4. **`concurrent_accepts_respect_ten_users`** (C7): alice plus 8 members, then two invitees accept at once. Exactly one succeeds; the other gets `ProjectLimit(Members)`, and its invite stays `pending`. Live members = 10.
5. **`thirty_agents_per_project`** (C7)
   - alice has 28 agents (`instance()` in a loop). bob accepting with 3 → `ProjectLimit(Agents)`; with 2 → ok.
   - `add_project_agents` with 1 new agent → `ProjectLimit(Agents)`. **At 30, re-sending an already-live agent → Ok(`[]`).**
   - At 29, two concurrent adds of 1 each → exactly one wins.
   - An agent whose instance is deleted does not count.
   - A member's `add_project_agents` with `consent: None` → `Invalid`; a wrong consent version → `Invalid`.
6. **`withdraw_leave_remove_and_rejoin`** (C8)
   - bob joins with b1 and b2. bob (the owner) withdraws b1 → `left_at` is set; repeating gives `already_left`.
   - alice withdraws b2 → the owner check passes. carol (outsider) → NotFound. bob withdrawing one of alice's agents → `NotPermitted`.
   - bob `remove_project_member` → `NotPermitted`. alice `leave_project` → `Conflict`.
   - bob `leave_project` → `left_reason='left'`. Then `project_detail(bob)` → NotFound, `my_projects(bob)` excludes the project, and `leave_project` again → NotFound.
   - A new invite brings bob back: the same member and agent rows are reactivated, and `joined_at` moves.
   - alice removes bob → `'removed'`; removing again → Ok. `shared_at` stays set.
7. **`exits_stop_project_runs_and_grants`** (C8)
   - Seed with the worker "copy row" SQL from `tests.rs:1084-1104`: one `running` project run on b1, a child grant of a project grant, and a private run plus a private grant on the same instance.
   - After `withdraw_project_agent`: the project run is `cancelled`, `token_epoch` rose by 1, the project grant tree is revoked, and the private run and grant are untouched.
   - After `leave_project`, the same holds for all of bob's project rows.
8. **`cross_user_rows_are_worker_only`** (C5; the project is shared with raw worker SQL)
   - As tenant: SELECT and INSERT on `project_invites` and `user_blocks` → `Forbidden`.
   - Inserting a `role='member'` row → `Forbidden`.
   - Updating a shared project's `project_agents` affects 0 rows.
   - bob as tenant cannot read alice's `projects` row even after joining (`0039:181`).
   - A tenant teams update on the shared project → `Conflict`.
9. **`blocks_hide_invites_silently`** (C6)
   - carol `decline_invite(block=true)`: the inviter's view still says `pending`; carol's list is empty; her hand-inserted inbox item is read.
   - A later invite to carol returns `deliver_to=None` with `suppressed_at` set.
   - Unblocking does not resurrect the suppressed invites. Blocking an unknown user id → NotFound.
   - **Race (critic B5):** a barrier runs `block_user(carol, alice)` against `create_phone_invite(alice → carol)`. Afterwards no pending, unsuppressed invite from alice to carol exists.
   - **Deadlock check (critic C1):** a barrier runs `decline_invite(block=true)` against `block_user` from carol, twice. No 40P01.
10. **Erase.**
    - **10a `erase_cleans_blocks_and_accepted_invites`** (C2): extend `erasing_an_account_deletes_its_content` (`tests.rs:1634`; project part `:1883-1945`). Seed blocks in both directions and an `accepted_by` invite with raw worker SQL; after erase, all are gone. No project runs are seeded: `runs_project_agent` is NO ACTION (`0045:6-7`), and erasing a creator would fail if other members had project runs (§9).
    - **10b `erase_and_project_flows_do_not_deadlock`** (C8). Concurrently:
      - erase bob while bob accepts;
      - erase alice while bob leaves alice's project;
      - erase alice while alice's tenant `update_team` renames her solo project and replaces its agents (the F3 evidence).
      - All finish with no 40P01, and the final state is consistent. No project runs are seeded for other members in a project whose creator is erased.
11. **`deleted_instances_leave_shared_projects`** (C8): a tenant delete followed by `retire_deleted_instance` marks the agent left in alice's shared project. Without that call, `retire_deleted_project_agents` does it; and while another transaction holds the project lock, the sweep skips the project instead of waiting.
12. **`team_edits_and_joins_serialize`** (C7): a concurrent tenant `update_team` (adding agents) and `accept_invite`, on a project at 29 agents. The count never exceeds 30; the team edit either finishes first or gets 409.
13. **`inbox_project_fields_are_server_only`** (C3)
    - A tenant `insert_inbox` with `project_id` → `Forbidden`.
    - A tenant raw `UPDATE inbox_items SET subtype` → `Invalid`.
    - A worker insert with `project_id` → ok; a worker `UPDATE … SET project_id` → `Invalid`.
    - Tenant mark-read still works.
    - Deleting the referenced run sets `run_id` NULL and keeps `project_id`.

### 7.2 Gateway (`crates/gateway/tests/api.rs`)

The harness is at `:35-166`. `api()` (`:35-41`) adds `cross_user_projects: true`. Tests that build their own config through `api_with` set it explicitly.

- **`project_phone_invites_are_uniform_over_http`**
  - bob is logged in. carol is logged in and blocks alice via `PUT /v1/blocks/{alice}`; alice's id comes from a preview.
  - Numbers: the unregistered `13800139999`, and an existing member's number.
  - Every response is **201** with the same sorted key set and `status=="pending"`. Re-inviting bob is also 201, with the same id.
  - bob's `/v1/inbox` has `subtype=project_invite` with `project_invite_id`, and its body contains neither the project name nor alice's name.
  - No phone digits appear in `GET /v1/project-invites/{id}` (assert `!body.to_string().contains("1380013")`).
  - The preview's `members[]` has no `user_id`.
- **`project_link_invite_join_and_exit_over_http`**
  - The token appears only in the create response; `GET …/invites` does not contain it. A malformed token → 404.
  - **`POST /v1/project-invites/{link_invite_id}/accept` with consent → 404.**
  - Resolve → a preview with the goal, the creator's `display_name`, members and the share keys.
  - Accept without consent → 422; with consent → 201; repeated → 200 with the same body; carol with the same token → 404.
  - bob's `GET /v1/projects` includes the project with `role:"member"`, and the detail shows both owners' agents with the `mine` flags. alice's inbox has `project_joined`.
  - Withdraw → 204, and alice gets `project_agent_left`.
  - bob leaves → 204; then `GET /v1/projects/{id}` → 404, bob's list no longer includes it, and alice gets `project_left`.
  - Rejoin with a new link, then alice removes bob → bob gets `project_removed`.
- **`project_limits_and_invite_rate_limits_over_http`**
  - With `invites_per_day: 2`, the third invite → 429 with `Retry-After`. With `invites_per_day: 0` there is no limit.
  - Ten users join, and the eleventh accept → 409 `project_member_limit`.
  - The 21st pending invite → 409 `project_invite_limit`.
  - Precedent: `rate_limits_and_signup_cap` at `:2938`.
- **`outsiders_see_nothing_of_a_project`**: carol gets 404 on detail, invites, member delete, agent delete and accept-by-id, and never a 403. bob (a member) gets 403 on creator-only routes.
- **`old_team_api_on_a_shared_project`**, next to `old_team_api_is_backed_by_projects` (`:2800`): `PATCH` and `DELETE /v1/teams/{id}` → 409; `GET` shows only alice's agents; bob's `/v1/teams` does not list the project.
- **`cross_user_projects_are_off_by_default`**: with `api_with(GatewayConfig { ..GatewayConfig::default() })`, invite create, resolve and accept return 404, while `POST /v1/projects` works.
- **`deleting_an_instance_leaves_shared_projects_over_http`**.

### 7.3 client-core (`crates/client-core/tests/client.rs`)

- **The harness** builds `GatewayConfig { ws_heartbeat, ..GatewayConfig::default() }` at `:64-67`. Add `cross_user_projects: true` there.
- **`ffi_projects_invites_and_join`**, after `ffi_teams_and_templates` (`:1641`):
  - two `ffi_login` clients; `create_project`, then `create_project_invite_link`;
  - `project_invite_token(link)` round-trips, and a bad link → `InvalidArgument`;
  - `resolve_project_invite_link` → `accept_project_invite_link` → `projects()` and `project()`;
  - the creator's `InboxItem.project_id` is set;
  - `withdraw_project_agent` → `leave_project` → `project()` gives `Api{status:404}`.
- A unit test for `project_invite_token`.
- `ffi_smoke.py` asserts `InboxItem(...).project_id is None`.

### 7.4 Other crates

- notify: channel payload tests for the new keys.
- auth: `InviteToken` generate and parse tests, next to the existing token tests in `secrets.rs`.
- proto: serde and status tests for the three limit codes; the `mask_phone` test moves with the function.

---

## 8. Commit sequence

Every commit builds and passes `cargo test --workspace`. Push after each one, and update `docs/progress/claude-determined-lovelace-vn0j5h.md` in the same commit.

| # | Commit | Files |
|---|---|---|
| C1 | auth: `InviteToken`; proto: `mask_phone`, moved from `server/src/admin.rs` | `crates/auth/src/secrets.rs`, `crates/proto/src/domain.rs`, `crates/server/src/admin.rs` |
| C2 | Migration 0047 (with `inbox_project_guard`); `lock_project`/`lock_projects`; erase takes project locks and deletes blocks and accepted invites; store test 10a | `migrations/0047_project_invites.sql`, `store/src/{projects,users}.rs`, `store/src/tests.rs` (`mod projects;`), `store/src/tests/projects.rs` (new) |
| C3 | `ProjectInviteId`; inbox and push carry project and invite ids; store test 13 | `proto/src/domain.rs` (id + InboxItem), `store/src/inbox.rs`, `notify/src/{lib,apns,fcm,jpush}.rs` + tests, `orchestrator/src/outbox.rs` (Notice), `client-core/src/{ffi.rs,cache.rs}`, `tools/client-core/ffi_smoke.py`, `docs/push.md` |
| C4 | Proto project types; the three `project_*_limit` codes; store and gateway error variants | `proto/src/{domain,api}.rs`, `store/src/error.rs`, `gateway/src/error.rs` |
| C5 | store: `lock_users`, `ProjectActor`, the tenant lock in `writable_solo`, goal on create, worker reads, `update_project`; test 8 | `store/src/{projects,teams,lib}.rs` |
| C6 | store: invites and blocks (create, list, revoke, preview, decline, block, expire, purge); tests 1 and 9 | `store/src/project_invites.rs` |
| C7 | store: accept, join and add agents with caps and consent; tests 2, 3, 4, 5 and 12 | `store/src/{project_invites,project_members}.rs` |
| C8 | store: withdraw, leave and remove; project-scoped run cancel and grant revoke; retiring deleted instances; tests 6, 7, 10b and 11 | `store/src/{project_members,runs,grants}.rs` |
| C9 | orchestrator: project wrappers, texts, notices; the `maintain` sweeps in their own transactions | `orchestrator/src/{projects,texts,lib}.rs`, `server/src/workers.rs` |
| C10 | gateway: routes, limits, cross-user switch, the instance-delete worker step; API tests; `api()` turns the switch on | `gateway/src/routes/{mod,projects,project_invites,instances}.rs`, `gateway/src/{limits,lib}.rs`, `server/src/{config,api}.rs`, `gateway/tests/api.rs`, `docs/compliance.md` |
| C11 | client-core: project API, FFI and tests; the harness turns the switch on | `client-core/src/{api,ffi,error}.rs`, `client-core/tests/client.rs`, `tools/client-core/ffi_smoke.py` |
| C12 | Android bindings, regenerated (its own commit) | `apps/android/core/src/main/kotlin/cn/thinktin/core/client_core.kt` |
| C13 | Docs | `docs/projects-impl.md` (new "8.14 做了什么"), `docs/projects.md` status line, `docs/progress/drafts/projects-8.14-plan.md`, progress file |

C3 is cross-crate but has to be atomic: adding fields to `InboxItem` breaks every struct literal. After merging, delete `autosave/<branch>` as CLAUDE.md says.

---

## 9. What 8.14 leaves for 8.15–8.19

**8.15**
- Replace the worker reads `my_projects` and `project_detail` (and the preview's member list) with `ProjectTx`/`thinktin_member` member policies and definer functions. The JSON stays the same.
- Map 42501 to 404 on project paths.
- Fold "derive `inbox_items.project_id` from `runs.project_id`" into `inbox_project_guard` (CREATE OR REPLACE), raising when a supplied value disagrees. When the inbox read policy is narrowed by membership, exempt receipts **by `subtype`** (the receipt subtypes, now immutable), never by `run_id IS NULL`: `run_id` is `ON DELETE SET NULL` (`0001:381`).
- Soft-delete and archive shared projects: `DELETE /v1/projects/{id}` for shared projects, a `project_deleted` receipt, and erase switching to soft delete. Every writer of `projects.status` takes `lock_project`.
- **Precondition for erase:** erasing a creator hard-deletes their projects (`users.rs:218`). That cascades into other members' `project_agents`, and `runs_project_agent` is NO ACTION (`0045:6-7`). So once project runs exist, the soft-delete flow must clear or detach those runs first. Until then nothing writes project runs (8.13 claim guard).
- `/v1/project-templates*` as an alias over `project_templates`, plus its FFI (D16).
- Project keys and content.

**8.16**
- `agents[].dedicated` and `ack_shared_memory` in JoinReq and in the add-agents call (the worker writes `project_agents.dedicated`). Adopt-for-this-project marks the new instance dedicated (D17).
- The non-dedicated warning.
- Before lifting the claim guard, re-validate the existing live `project_agents` rows: the pilot accepts only instances that can be isolated (projects-impl "受邀加入").
- Claims must check `project_agents.left_at IS NULL` and live membership ("停领").

**8.17**
- Changing the lead across users (`PUT /v1/projects/{id}/lead`).
- Project dispatch and creating project grants, through a `ProjectActor` that is exposed then.
- What happens to cross-owner children when an agent is withdrawn; 8.14 cancels trees rooted on the withdrawn agent.
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
- Project UI, the invite and join flow (adopt, then accept), and blocks.
- Deep links `thinktin://join/{token}`, `thinktin://project/{id}` and `thinktin://project-invite/{id}`.
- Routing for the new subtypes, and the adapters.

**15.7 / 16.6**
- **15.7:** the residual timing gap; link leakage; the preview's exposure of member names; the plaintext phone; `declined` revealing that a number is registered; erase deleting pending invites addressed to the erased number (the inviter sees the invite vanish).
- **16.6:** the privacy-policy text and `consent_version`; the erase rules for invites.

**After the security review:** set `[api] cross_user_projects = true` in production.

---

## Appendix A. Critic corrections: verdicts

| # | Correction | Verdict | Evidence / what changed |
|---|---|---|---|
| A1 | `store` cannot call `auth::mask_phone` | **Applied** | `crates/auth/Cargo.toml` has `store = { path = "../store" }`; `crates/store/Cargo.toml` depends only on `proto`. `mask_phone` (`server/src/admin.rs:221-232`) moves to `proto::domain` in C1. |
| A2 | sqlx cannot bind `u64` | **Applied** | §2.1: counts through `crate::unsigned` (`lib.rs:243`, precedent `instances.rs:269`); binds through `crate::signed` (`lib.rs:247`). |
| A3-1 | C2's erase needs `lock_projects` from C5 | **Applied** | Kept, because F3 is rejected. `lock_project`/`lock_projects` move into C2. |
| A3-2 | Test 10 needs accept and leave | **Applied** | Split into 10a (C2, raw SQL) and 10b (C8). |
| A3-3 | `ProjectInviteId` needed in C3 | **Applied** | The id type moves to C3. |
| A3-4 | Test 12 needs accept | **Applied** | Moved to C7; test 8 stays in C5 with raw worker SQL. Test 2 also needs accept, so it moves to C7 too (not flagged by the critic). |
| A3-5 | Store tests asserted inbox rows that only `notify` writes | **Applied** | Verified: `notify` is in `orchestrator/src/outbox.rs:201-218`. Store tests now assert `deliver_to`/`suppressed_at` and insert inbox items by hand; the HTTP tests assert real notices. |
| A3-6 | client-core harness gets 404 | **Applied** | `client-core/tests/client.rs:64-67` uses `..GatewayConfig::default()`. It now sets `cross_user_projects: true`. |
| A4 | `project_actor` step 4 contradicted itself | **Applied** | An `allow: &[ProjectStatus]` parameter. Writes pass `[Active]`; leave and withdraw pass `[Active, Archived]`. |
| A5 | Re-sent live agents counted as new | **Applied** | new = requested ids with no live row; test 5 checks the case at 30. |
| B1 | Link invite accepted by id without the token | **Applied** | Phone key `kind='phone'`, link key `kind='link'`, in preview, accept and decline; tests 2 and HTTP added. |
| B2 | Tenant can write `inbox_items.project_id`; the 8.15 exemption by `run_id IS NULL` is unsound | **Applied, tightened** | The tenant grant is table-level (`0001:468-469`; the draft wrongly cited 463-464). `run_id` is `ON DELETE SET NULL (run_id)` (`0001:381`). All existing UPDATEs set only `read_at`.<br>The trigger also refuses UPDATEs by the worker (immutable for everyone), matching `fill_space` (`0040:9-16`). The comment and the 8.15 bullet were replaced. |
| B3 | The per-phone cap became a targeted denial of service | **Applied** | The cap now only withholds the notice. It counts `invitee_id IS NOT NULL`; the index is `project_invites_delivered_day … WHERE invitee_id IS NOT NULL`. `suppressed_at` is set only for blocks. |
| B4 | 0 must mean unlimited | **Applied** | `limits.rs:25`; `InviteCaps` skips a cap of 0. |
| B5 | A block could lose a race with a new invite | **Applied** | Advisory keys `project_invites/{inviter}` → `project_invite_phone/{e164}` → `user_blocks/{recipient}` are taken right after `project_actor`, before any invite row (step 4's expire included). Race test in test 9. |
| B6 | Fallback vendors omitted | **Applied** | `model_route_fallbacks` carries `credential_id` (`0008:3-15`); vendor SQL updated. |
| B7 | Consent enforced only at the gateway | **Applied, with creator exemption** | `JoinTerms.consent: Consent` is required. `add_project_agents(…, Option<Consent>)` requires `Some` for members; the creator is exempt, per `0039:45`. |
| B8 | Data minimisation | **Applied** | No member `user_id` in the non-member preview; `project.member_joined` detail is `{project, invite, member}`. |
| C1 | Decline-and-block deadlocks with block | **Applied** | `decline(block=true)` takes users → `user_blocks/{user}` → suppress UPDATE, with no project lock. R1 gains "all advisory keys before the first invite row lock". Test 9 checks for no 40P01. |
| C2 | Sweeps must not run in `maintain`'s first transaction | **Applied** | Verified: partition DDL at `workers.rs:460-464` and commit at `:487`. Sweeps run in their own batched transactions; the retire sweep try-locks. |
| C3 | Accept used transaction-start `now()` | **Applied** | `statement_timestamp()` in accept steps 5 and 10. |
| D1 | Erasing a creator with other members' project runs fails | **Applied** | `0045:6-7` NO ACTION. Noted in test 10 and as an 8.15 precondition. |
| D2 | `/v1/project-templates*` silently dropped | **Applied as an explicit deferral** | D16. `/v1/team-templates*` already uses `project_templates` (`teams.rs:88-140`). |
| D3 | Adopting during join | **Applied** | D17. |
| D4 | Teams 409, claim guard, `shared_at` | **No change** | Confirmed. |
| D5 | Erase and `declined` reveal registration | **Applied as open items** | `users.rs:221-222` deletes invites addressed to the erased number. Listed under 15.7/16.6 and in the open questions. |
| D6 | 0047 lock footprint after a first deployment | **Applied** | Header note: split the migration or use `SET LOCAL lock_timeout`. There is no `lock_timeout` precedent in migrations; the runtime precedent is `hooks.rs:224`. |
| E1 | 201 vs 200 for repeated phone invites | **Applied** | Always 201. |
| E2 | One free-text `project_limit` | **Applied (three codes)** | `project_member_limit`, `project_agent_limit`, `project_invite_limit`; `ErrorBody` is only `code`/`message` (`api.rs:89-95`). |
| E3 | Test 1 must normalise `phone_masked` | **Applied** | |
| F1 | Drop `invites_per_hour` and `invite_lookups_per_hour` | **Applied** | The default of 30/hour exceeds the DB's 20/day; the per-user limiter is at `limits.rs:176-179`; the tokens are 256-bit. The in-memory 429 test was removed. |
| F2 | `PUT /v1/blocks/{unknown}` → 404 | **Applied** | `GET /v1/blocks` shows the difference anyway, and user ids appear in previews and member lists. |
| F3 | Erase's `lock_projects` is not needed for correctness | **Rejected** | The critic's reasoning covers worker flows only, and **tenant solo writes take no users lock** (R1: they start at step 2).<br>• `update_team` → `update_solo_project` updates the `projects` row (`projects.rs:130`), then `replace_my_project_agents` updates `project_agents` rows (`projects.rs:153`).<br>• `erase_account` does the reverse: it updates the user's `project_agents` (`users.rs:216`) before `DELETE FROM projects` (`users.rs:218`).<br>• So the user's own tenant edit and erase can deadlock on those rows. With D4's tenant project lock, erase taking `lock_projects` right after `users FOR UPDATE` serializes them.<br>The lock stays, with that reason in the code comment; test 10b covers it. |

## Appendix B. Issues found while verifying (not raised by the critic)

| # | Issue | Change |
|---|---|---|
| V1 | `revoke_invite` writes the invitee's inbox without locking the invitee's users row. Erase deletes inbox rows (`users.rs:206`) before invites (`:221-222`), while revoke locks the invite row and then updates the inbox, so the two can deadlock. | Revoke pre-reads `invitee_id` and passes it in `also` (R1 step 1 covers inbox recipients). |
| V2 | The expire sweep's inbox step waited on row locks (contradicting "never waits"), and without `user_id` it could not use `inbox_unread`. | `RETURNING id, invitee_id`; inbox update filtered by `user_id = ANY` with `FOR UPDATE SKIP LOCKED`. |
| V3 | A repeat phone invite at the inviter's cap returned 429 instead of the existing invite. | The existing-pending check now comes before the caps. |
| V4 | Accept took the invite row before the actor's member row, unlike the `project_actor` flows. | Accept reads the member row first (R1 step 3). |
| V5 | Citation fixes. | Tenant inbox grant `0001:468-469`; erase invite DELETE `users.rs:221-222`; erase test `tests.rs:1634` (project part `:1883-1945`); `mask_phone` at `admin.rs:221-232`; `cancel_instance_runs` at `runs.rs:783-813`; `normalize_phone` at `secrets.rs:26-47`. |


## 待定问题

- Link invites are not filtered by the invitee's blocks (the user opened the link on purpose): confirm, or should a link from a user I blocked also resolve to 404?
- Residual timing difference: a delivered phone invite does two extra inserts (inbox and outbox), so response time can hint that a number is registered. Accept this for 8.14 and hand it to 15.7, or pad the other cases with equivalent work?
- invitee_phone stays as plaintext E.164 (like login_codes) and is purged 30 days after settlement. Keep this, or switch to a keyed hash (open since 8.13)?
- Erase deletes pending phone invites addressed to the erased number (users.rs:221-222), so the inviter sees the invite vanish, which reveals 'was registered, then erased'. The 'declined' status also reveals registration. Accept both, or define a different rule in 16.6/15.7 (for example, show such invites as 'expired')?
- Defaults: 20 invites per inviter per 24h, 5 delivered invite notices per number per 24h, 20 pending invites per project, 1000 blocks per user, link TTL 72h, phone TTL 7 days. Confirm.
- The invite preview shows existing members' display names, roles and agent counts to a non-member (phone invitee or link holder). Acceptable for the pilot, or show only the creator and counts?
- Joining with a newly adopted instance is two calls: adopt (tenant), then accept. If the accept fails, the new instance stays as a private one. Acceptable, or should the server offer one atomic adopt-and-join?
- /v1/project-templates* is deferred to 8.15 (D16), because /v1/team-templates* already serves project_templates. Confirm that this deferral from the 8.13 plan's 8.14 row is acceptable.
- cross_user_projects stays false in production until the 15.7 review. Confirm that no staging or pilot environment needs it on during 8.14-8.16.