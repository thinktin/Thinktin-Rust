# 8.14 方案评审（原始结果，2026-11-04）

对草稿逐条核对代码。英文原样。

**Verdict:** the plan is close, but it has 2 compile blockers, 1 real deadlock, 3 security gaps, 1 forward-compatibility hole in `inbox_items`, and several commit-order breaks. Corrections are listed most severe first.

## A. Won't compile or won't work

**A1. `store` cannot call `auth::secrets::mask_phone` (dependency cycle).** `auth` depends on `store` (`crates/auth/Cargo.toml`: `store = { path = "../store" }`), and `store` depends only on `proto`. §2.5 `project_invites()` fills `phone_masked` from `auth::secrets::mask_phone`, and C1 moves the function into `auth`. That cannot build.
*Corrected text (C1 and §2.5):* "Move `mask_phone` from `server/src/admin.rs:222-232` to `proto` (`proto::domain::mask_phone`). `server` and `store` both import it from there. C1 = `auth`: `InviteToken`; `proto`: `mask_phone`."

**A2. sqlx cannot bind `u64` to Postgres.** `JoinTerms.daily_token_limit: u64`, `ProjectBudget: Option<u64>`, the `MAX_*: u64` constants and the count comparisons (`count(*)` returns `i64`) are affected.
*Add to §2.5/§2.6:* "Store converts with `i64::try_from` (`MAX_TOKEN_LIMIT` = 1e12 fits) and compares counts through `crate::unsigned` (precedent `instances.rs:269`)."

**A3. Commit order breaks the build or the tests (§8):**
- C2's erase calls `lock_projects`, but that helper is only added in C5. Move `lock_project`/`lock_projects` into C2.
- C2's test 10 needs `accept_invite` (C7) and `leave_project` (C8). Keep only the cleanup assertions in C2, seeded with raw worker SQL. Move the concurrent erase-vs-accept/leave part to C8.
- C3 adds `InboxItem.project_invite_id: Option<ProjectInviteId>`, but `ProjectInviteId` arrives in C4. Move the id type into C3.
- C5's test 12 needs `accept_invite` (C7). Move it to C7. Test 8 can stay in C5 by sharing the project with raw worker SQL.
- C6's tests 1, 2 and 9 assert inbox rows. Inbox rows are written by the orchestrator's `notify` (`orchestrator/src/outbox.rs:201-218`, C9), not by the store. Store tests should assert `CreatedInvite.deliver_to` and `suppressed_at`. The inbox assertions belong in the gateway tests (C10), or the test inserts the item by hand.
- C11: the client-core test harness builds `GatewayConfig {` literally at `crates/client-core/tests/client.rs:64`. It must set `cross_user_projects: true`, otherwise `ffi_projects_invites_and_join` gets 404.

**A4. `project_actor` step 4 contradicts itself.** It says "Not active → NotFound" and also "exits are allowed for any non-deleted status".
*Corrected text:* "`project_actor(user, project, also, allow: ProjectStatusSet)`. Writes require `active`. `leave`/`withdraw` accept `active | archived`."

**A5. The cap check counts already-live agents as new.** "live + new > 30" in `add_project_agents` treats re-sent, already-live agents as new. At 30 agents, re-adding one would wrongly return `ProjectLimit`.
*Corrected text:* "new = requested ids that have no live row."

## B. Security

**B1. A link invite can be accepted by id, without the token.** Accept step 1 says "Unlocked find by id or by hash" with no `kind` filter. Step 3's checks apply only to phone invites. So `POST /v1/project-invites/{id}/accept` with a link invite's id skips the token entirely. That id is exposed in the link preview (`invite_id`) and in the creator's invite list.
*Corrected text:* "Id key: `WHERE id=$1 AND kind='phone'`. Hash key: `WHERE token_hash=$1 AND kind='link'`. This applies to preview, accept and decline. A link invite is never reachable through `/v1/project-invites/{id}/*`."

**B2. `inbox_items.project_id` can be written by the tenant, and the planned 8.15 rule is unsound.**
- Tenant `UPDATE` on `inbox_items` is table-level (`0001_init.sql:468-469`; the plan cites 463-464), so it covers the new columns.
- projects-impl item 1 says project ownership is derived by the server and cannot be changed on update ("更新时不可改"). The 0047 comment instead plans an 8.15 trigger that fills `project_id` only when it is NULL. That means a value the tenant set earlier wins.
- The plan exempts receipts from 8.15's membership narrowing by `run_id IS NULL`. But `run_id` is `ON DELETE SET NULL (run_id)` (`0001:381`). Once project runs are purged, their notices would look like receipts and become readable after leaving.

*Add to 0047 (same pattern as the `fill_space` allowlist, `0040:19-22`):*
```sql
CREATE FUNCTION inbox_project_guard() RETURNS trigger LANGUAGE plpgsql
    SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    IF current_user <> 'thinktin_worker' AND (
         (TG_OP = 'INSERT' AND (NEW.project_id IS NOT NULL OR NEW.project_invite_id IS NOT NULL))
      OR (TG_OP = 'UPDATE' AND (NEW.project_id IS DISTINCT FROM OLD.project_id
             OR NEW.project_invite_id IS DISTINCT FROM OLD.project_invite_id
             OR NEW.subtype IS DISTINCT FROM OLD.subtype))) THEN
        RAISE EXCEPTION 'project fields in inbox_items are written by the server only'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION inbox_project_guard() FROM PUBLIC;
CREATE TRIGGER inbox_project_guard BEFORE INSERT OR UPDATE OF project_id, project_invite_id, subtype
    ON inbox_items FOR EACH ROW EXECUTE FUNCTION inbox_project_guard();
```
This is safe for current callers: every store `UPDATE inbox_items` sets only `read_at` (`inbox.rs:134-254`, `egress.rs:691`, `approvals.rs:160,194`, `instances.rs:412`). `ON DELETE SET NULL (run_id)` is not in the `UPDATE OF` list.
*Replace the 0047 comment and the 8.15 §9 bullet with:* "8.15 的触发器从运行算 project_id，和传入的不一致就报错；按成员关系收窄读策略时，回执按 subtype（回执那几种，已不可改）放行，不能按 run_id 为空。"

**B3. The per-phone cap turns into a targeted denial of service.** Step 8 *suppresses* (hides) every invite once a number has had N invites in 24h, and the count includes suppressed rows. Anyone can burn a victim's daily quota, and the victim's real invites then disappear silently. There is no SMS in 8.14, so the cap only protects registered users from push spam.
*Corrected text (D6, step 7/8, test 1):* "The per-phone cap only withholds the notice: `deliver_to=None` (`invitee_id` NULL), `suppressed_at` NULL, and the invite stays visible in `invites_for`. Count notices actually sent: `… AND invitee_id IS NOT NULL AND created_at > now()-'24h'`. `suppressed_at` is set only for blocks. Update the column comment to match."

**B4. Zero would mean "suppress everything".** `LimitConfig` defines 0 as unlimited (`gateway/src/limits.rs:25`). The plan's `count >= cap` would answer 429 on every invite when `invites_per_day = 0`, and would suppress every invite when `per_phone = 0`.
*Add:* "`InviteCaps`: a cap of 0 skips the check."

**B5. A block can lose a race with a new invite.** `create_phone_invite` reads `EXISTS user_blocks` without a lock, and `block_user` and invite creation both take only `KEY SHARE` on users, so they don't serialize. If a block commits while the invite transaction is open, the new row is delivered unsuppressed and the push goes out. `invites_for` and accept do hide it afterwards.
*Corrected text (step order in §2.5):* "Right after `lock_project`, and before any `project_invites` row is touched (step 4's expire UPDATE included), take advisory keys in this order: `project_invites/{inviter}` → `project_invite_phone/{e164}` → `user_blocks/{recipient}` (if registered). Then steps 4–9." `block_user` already takes `user_blocks/{blocker}` before its UPDATE, so the two now serialize.

**B6. Vendors listed for consent leave out fallback vendors.** Content also goes to the credentials in the fallback chain (`0008_route_fallbacks.sql:3-15`).
*Corrected SQL:*
```sql
SELECT DISTINCT c.vendor FROM (
  SELECT credential_id, user_id FROM model_routes WHERE user_id=$1 AND instance_id=ANY($2)
  UNION SELECT credential_id, user_id FROM model_route_fallbacks WHERE user_id=$1 AND instance_id=ANY($2)
) r JOIN credentials c ON c.id=r.credential_id AND c.user_id=r.user_id ORDER BY 1
```

**B7. Consent is enforced only at the gateway.** `JoinTerms` carries no consent, yet `add_project_agents` takes `consent`. Any future caller of `accept_invite` would write `consented_at=now()` without the user's confirmation.
*Corrected text:* "`JoinTerms { …, consent: Consent }` with `pub struct Consent { pub version: u32 }`, required by both `accept_invite` and `add_project_agents`. The store refuses with `Invalid` without it."

**B8. Minor data minimisation.**
- `ProjectMemberBrief.user_id` in the non-member preview is not needed. Only the creator's id is needed, for blocking. Drop it for non-members.
- Specify the creator's `project.member_joined` audit detail as `{project, invite, member}` only, with no joiner vendors or instance ids (impl item 4).

## C. Locks and races

**C1. Real deadlock: "decline and block" against "block".** `decline_invite(block=true)` locks project → invite row `FOR UPDATE`, then `user_blocks/{user}` via `block_user_locked`. `block_user` locks `user_blocks/{user}`, then UPDATEs that same invite row. Two concurrent requests from the same user (two devices, or a double tap) deadlock with 40P01, which surfaces as a 500.
*Corrected text:* "`decline(block=true)`: `lock_users({user, inviter})` → `user_blocks/{user}` → the same suppress UPDATE as `block_user` (no project lock is needed: accept re-checks `suppressed_at` after its own `FOR UPDATE`) → mark the inbox item read. Only `decline(block=false)` uses users → project → invite `FOR UPDATE`. Rule R1 gains: every advisory key is taken before the first `project_invites` row lock."

**C2. The sweeps must not run in maintain's first transaction.**
- That transaction runs partition DDL (`CREATE TABLE … PARTITION OF events` / `DROP TABLE`, `0001:296,316`), and those locks on `events` last until commit (`server/src/workers.rs:460-486`).
- `retire_deleted_project_agents` waits on project locks and `expire_project_invites` waits on inbox rows, which would stall event writes.

*Corrected text:* "Run each sweep in its own worker transaction after the first commit, in batches like the egress purge (`workers.rs:488-503`). `retire_deleted_project_agents` uses `pg_try_advisory_xact_lock` and skips projects that are busy."

**C3. The accept/expiry boundary uses transaction-start time.** Accept steps 3 and 9 use `now()`, the transaction start. An accept that waited on locks can still pass an invite that expired while it waited. Using `statement_timestamp()` in step 9 makes the boundary exact. Low impact.

**Verified correct, no change:**
- users-first order against erase (`users.rs:186`, `hooks.rs:219-222`);
- D4 tenant lock: the re-read of `shared` after the join commits gives 409, otherwise the 42501 race maps to 500 via `gateway/src/error.rs:77`;
- `instances FOR SHARE` against tenant delete (`instances.rs:396-402`; order is runs → instances → unshared `project_agents` only);
- `FOR NO KEY UPDATE` on `project_agents` does not block run-FK `KEY SHARE`;
- `ORDER BY id FOR KEY SHARE` locks in sorted order;
- `ON CONFLICT DO UPDATE` does not fire the AFTER INSERT share trigger (`0039:166-167`), and `shared_at` is already set on a rejoin;
- one exactly-one-winner path for accept/revoke/expire;
- `bump_epochs_where!` cannot hit a private run, because `runs_one_active_per_instance` (`0002_collaboration.sql:49`) allows one active agent run per instance.

## D. 8.13 compatibility and 8.15+ re-migration risk

- **D1.** Test 10 (erase alice) must not seed project runs. `DELETE FROM projects WHERE creator_id` (`users.rs:218`) cascades into `project_agents`, and `runs_project_agent` is NO ACTION (`0045:6-7`), so erasing a creator fails whenever another member has project runs. State this in §9 as an 8.15 precondition for erase.
- **D2.** The 8.13 row for 8.14 lists `/v1/project-templates*` (`projects-8.13-plan.md`, §8 table). The plan drops it silently. Add it, or add an explicit deferral: "`/v1/team-templates` covers the same rows; deferred to 12.25".
- **D3.** projects.md §4.3 allows adopting a new instance during join. Add a decision: "the App adopts first (tenant `POST /v1/instances`), then accepts. A failed accept leaves the user's own instance in place."
- **D4.** `/v1/teams` 409, the claim guard and `shared_at` are preserved. No change needed.
- **D5.** Low: erase deletes invites addressed to the erased number (`users.rs:221`), so the inviter sees a pending invite vanish. That reveals "was registered and was erased". Also note that the `declined` status reveals registration. Record both for 16.6/15.7.
- **D6.** Low: if 0047 ships after a first deployment, `CREATE TABLE user_blocks … REFERENCES users` and `ALTER TABLE inbox_items` in one transaction hold users `SHARE ROW EXCLUSIVE` plus inbox `ACCESS EXCLUSIVE` together. Split them or set `lock_timeout`, as the 0039 header warns.

## E. Smaller inconsistencies

- D5 says every phone input gives 201, but §4.1 says "200 existing". Pick one. A single 201 is simplest; 200 only depends on the caller's own earlier invite, so it is not a leak.
- `project_limit` with a free-text message gives the App no stable way to tell users, agents and pending invites apart. `ErrorBody` has only `code`/`message` (`proto/src/api.rs:89-95`). Either use three `_limit` codes (`project_member_limit`, `project_agent_limit`, `project_invite_limit`) or document fixed message strings.
- Test 1's "equal after normalising id/time" must also normalise `phone_masked`.

## F. Over-engineering

- Drop `invites_per_hour` and `invite_lookups_per_hour`. The DB daily cap plus the per-user limiter (`limits.rs:177-180`) cover floods, 256-bit tokens can't be brute-forced, and the default of 30/hour exceeds 20/day anyway.
- `PUT /v1/blocks/{unknown}` answering 204 "uniformly" buys nothing: user ids appear in previews and member lists, and `GET /v1/blocks` shows the difference anyway. Return 404.
- Erase's `lock_projects` is not needed for correctness, since every project flow locks the creator and target users first and erase only lowers counts. Keep it only as groundwork for 8.15's status writes, and say so.