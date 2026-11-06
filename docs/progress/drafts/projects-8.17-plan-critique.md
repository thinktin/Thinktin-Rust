# 8.17 方案的两份评审（workflow `projects-8-17-plan`）

## 跨用户安全

# 8.17 plan cross-user security review

Result: 3 high, 8 medium and 9 low findings. The plan holds in most places. The DB fences, the separate board table, the space keys and target-side revocation all check out against the code. The one direct cross-user leak is the pipeline root copying a child run's private `error`. The other material gaps are an operator safeguard that cannot see old replicas, budgets nobody enforces, and other owners' runs left running after a cancel.

Shared projects need `cross_user_projects`, which stays off in production until 8.19 (`projects-impl.md:150`). So exposure is limited to pilot and test environments, but each item below must be fixed before any two-owner pilot.

## High

**F1. A pipeline root copies a child run's private `error` to another owner.**
- **Evidence:**
  - `advance` builds `why = "step {key} {state}: {error or state_reason}"` (`orchestrator/src/pipeline.rs:149-157`).
  - `finish` stores it in the root's `error` and `state_reason` (`pipeline.rs:332-333`), and puts the reason in the root's `run.state` event (`:340-346`).
- **Attack:** D14 anchors the root on the first step's agent, so `root.user_id` can be Bob. Carol's step fails with a key or vendor message. Bob reads it through the tenant `GET /v1/runs/{root}` (`gateway/src/routes/runs.rs:170-182`). That breaks "成员不会从失败原因…读到他人的私人活动" (`projects-impl.md:13`). D12 covers only delegate and ask results.
- **Corrected text (§3.4):** "For project roots, `advance` writes only `step {key} {ProjectRunState::coarse(state)}` (failed, cancelled). It never copies the child's `error` or `state_reason` into the root's `error`, `state_reason` or events."
- **Test O8b:** Carol's step error contains `sk-test-…`. Neither the root row nor any root event contains it.

**F2. `legacy_sessions()` returns no rows when run inside `Db::worker`, so `on` never refuses.**
- **Evidence:**
  - §2.5 puts it in the dispatcher (`Tx<Worker>`). `Db::worker` runs `set_config('role','thinktin_worker',true)` (`store/src/lib.rs:166-177`).
  - `pg_stat_activity` checks privileges against `current_user` (thinktin_worker), not the login. For other sessions it fills only datid, pid, usesysid, application_name and backend xid/xmin. `backend_type` is NULL, so `backend_type = 'client backend'` matches nothing.
  - The test harness connects as the admin superuser (`store/src/testing.rs:126-133`), so S14 would pass anyway.
- **Correction:**
  - Make it `Db::legacy_sessions(&self)` on a plain pool connection with no role switch, so it runs as the login.
  - Drop the `backend_type` predicate, and count a NULL `application_name` as legacy.
  - Rewrite V5 and S14 to connect as a non-superuser login granted `thinktin_worker` (as in production), and assert that a second `thinktin/i1` session is listed.

**F3. Cross-owner spending has no cap while 8.17 opens cross-owner dispatch.**
- **Evidence:**
  - `RunBudget::default()` has `max_tokens: None` (`proto/src/domain.rs:376-383`). D13 gives cross-owner children the default, and creator tasks get it too.
  - Joining requires `daily_token_limit` (`store/src/project_invites.rs:98`; `gateway/src/routes/project_invites.rs:82`). The product promises "不会花超" and "在主人设的预算内自动执行" (`projects.md:82,113`).
- **Attack:** the creator, the lead, or any member's agent (through `ask`) spends another owner's tokens. There is no token limit, each run can last 6 hours, and there is no limit on the number of runs. This includes the founder's two-account check with real keys.
- **Correction (new D13b):** "Every project dispatch (creator task, delegate, ask, pipeline step) reads the target owner's `project_members.daily_token_limit` and `total_token_limit`, and sums `runs.tokens_used` for (p, owner) today and in total. If either limit is reached, it refuses (409 `project_budget_reached` / `ChildRefusal::OwnerBudget`). Otherwise it sets `budget.max_tokens = min(daily remaining, total remaining)`, and `on_renew` enforces it per owner (D13). The llm-gw reservation stays in 8.18."
- **Release note to add:** this is approximate (it can overshoot with several agents per owner); no money pilot before 8.18.

## Medium

**F4. Other owners' runs keep running after a cancel.**
- **Evidence:**
  - `cancel_project_agent_runs` and `cancel_project_member_runs` match only trees rooted on the instance or user (`store/src/runs.rs:899-942`, `944-988`). Children of a non-root run (the lead answering an ask, or running a step) are missed.
  - `cancel_user_runs` (`runs.rs:873-897`, used by stop-all, freeze and erase) touches only that user's rows.
  - The tenant `cancel_run` (`:564-596`), `cancel_run_tree` (`:599-624`) and `cancel_instance_runs` (`:821-854`, called from `remove_instance`, `instances.rs:396`) run under RLS.
  - Freeze revokes no grants (`orchestrator/src/account.rs:36-63`), so children's ancestor grants stay usable.
  - The proposed sweep covers only `source='delegate'`. A step under a terminal root is never advanced or cancelled (`due_pipelines` only takes queued or waiting_children roots, `runs.rs:1727`).
  - The sweep runs hourly (`server/src/config.rs:862`).
- **Corrections:**
  - (a) Both project cancels lock, bump and cancel the recursive subtree, in D13 order:
    ```sql
    WITH RECURSIVE tree AS (SELECT id FROM runs WHERE project_id=$1 AND instance_id=$2
      UNION SELECT r.id FROM runs r JOIN tree t ON r.parent_run_id=t.id)
    ```
    Use `user_id=$2` for the member variant.
  - (b) `cancel_user_runs` then calls `cancel_project_subtree` on each project run it cancelled.
  - (c) `gateway runs::cancel` (`routes/runs.rs:189-225`) sends runs with `project_id` to the worker `cancel_project_run`.
  - (d) The sweep picks
    ```sql
    c.source IN ('delegate','pipeline') AND p.state IN ('succeeded','failed','cancelled')
    ```
    and runs in the executor's takeover tick next to `expire_asks` (`executor.rs:500-511`, every 15 s, `config.rs:864`), not in `projects::sweep`.

**F5. Anchoring the pipeline on another member's agent gives that member control of the creator's pipeline.**
- **Evidence:**
  - The tenant cancel of a pipeline root cancels the whole tree (`routes/runs.rs:198-213`).
  - Withdrawing the anchor cancels `root_run_id IN (roots on B)` (`runs.rs:906-909`) and recursively revokes every step grant (`grants.rs:228-246`).
  - The anchor's stop-all makes every step grant fail `ancestors_usable!` (`grants.rs:46-55`). F1's leak also lands on the anchor's owner.
- **Corrected D14:**
  - "The root is anchored on a live dedicated agent owned by the creator; with none, 422 `add one of your own dedicated botins to run a pipeline`."
  - "Each step's grant is a child of the step target's own standing grant, not the root's."
  - "Only the creator cancels a pipeline root (D16)."

**F6. D20 lets another member override "stop all".**
- **Evidence:** `stop_all` revokes with reason `stop_all` (`account.rs:91-96`). D20 lets the next creator task, delegate or ask reissue the standing grant, so Bob's kill switch is undone by Alice within seconds. The same happens if Bob revokes the grant through the grant API (`auth/src/grants.rs:89-104`).
- **Correction:** "`ensure_project_agent_grant` refuses (`ChildRefusal::OwnerPaused` / 409 `agent_paused`) when the newest standing grant for (p, instance) was revoked for `stop_all` or by its owner. Only the owner reissues it (`POST /v1/projects/{id}/agents/{instance}/resume`). Revocations from withdraw or leave are cleared on rejoin." Keep D20 in the founder questions as "no reissue by others".

**F7. Prompt-injection marking is missing in several places.**
- **Missing notes:**
  - The pipeline handoff puts other owners' step summaries into the prompt unmarked (`pipeline.rs:418-440`; `texts.rs:880-885`).
  - `artifact_list` and `artifact_read` return other owners' content with no note (`tools.rs:584-662`).
- **The creator shown as "the user":**
  - A queued creator task (`source='user'`) is piggybacked into the agent's current project run as "新消息" (`runs.rs:1487-1508`, `texts.rs:797-810`). The current run may be an ask answer or another owner's subtask.
  - The interrupt preface says "用户打断了你" (`texts.rs:757-770`).
  - An agent reads "用户" as its own owner.
- **Unchecked strings in platform notes:** the owner display names and botin names that D12 puts into notes come from users and are not sanitized.
- **Corrections:**
  - Add the untrusted note to the handoff and to artifact tool output in project runs, and fence other owners' content with an unguessable boundary, as `event_input` already does (`texts.rs:814-834`).
  - `unannounced_messages` returns nothing for project runs in 8.17. Urgent and interrupt texts say "项目「{p}」的创建者{name}" instead of "用户".
  - Strip control characters and brackets from names and clip them to 40 characters.

**F8. A dispatch already in flight survives `off`.**
- **Evidence:** the fence reads the switch with no lock. A transaction that inserted before `off` committed, but commits after `cancel_all_project_runs` has scanned, leaves a project run that 8.16 cannot claim after rollback.
- **Correction (0060):** `IF NOT coalesce((SELECT d.enabled FROM public.project_dispatch d FOR SHARE), false)`. `off` commits the flip (its UPDATE waits for inserters still in flight), then cancels, then re-counts until 0 and prints the count.

**F9. The savepoint error mapping in §3.4 is incomplete.**
- **Evidence:** errors that are neither Conflict nor Forbidden reach `Err(e)` (`pipeline.rs:226-248`):
  - a `runs_project_agent` FK violation (23503 → `Invalid`);
  - `runs_grant_space` (`Invalid`);
  - `project_run_shape` (`Invalid`).

  `Err(e)` aborts the whole tick, which brings back the 8.16 high finding for every user's pipelines.
- **Correction:** for project roots, every `store::Error` except `Error::Db(_)` rolls back to the savepoint and returns `Ok(Err("the agent for step {key} cannot take project work now"))`.

**F10. The worker urgent path and the executor skip the D13 settling order.**
- **Evidence:**
  - `queue_urgent_run`'s Stopped branch locks the tree, bumps epochs and cancels, with no approval or request settling (`runs.rs:707-737`). The tenant role cannot run `settle_cancelled_approvals`, so the "shared body" needs a worker branch.
  - The executor's `cancel_descendants` (`executor.rs:1183-1187`; `runs.rs:1306-1339`) and `cancel_asks` (`runs.rs:428-467`) also skip it.
- **Effect:** another owner's pending approvals and egress requests stay pending.
- **Correction:** for project runs, insert `settle_cancelled_approvals(tree)` then `expire_run_requests(tree)` before the epoch bump, or call `cancel_project_subtree`.

**F11. There are no fan-out or flood limits.**
- **Gaps:**
  - There is no cap on creator tasks, on cross-owner asks per target, or on member board posts. The 200-post cap with archive-oldest lets one member push everyone else's posts off the board.
  - A cross-owner delegate child sitting in `waiting_approval` holds the lead's instance with no deadline.
- **Correction:**
  - At most 10 queued project runs per target agent (409 `agent_busy`).
  - At most 5 open cross-owner asks per target (`TooMany`).
  - At most 30 creator tasks per project per hour.
  - At most 50 member posts per day.
  - A 2-hour deadline on cross-owner delegate children, swept the same way as `answer_deadline`.

## Low

**F12. Push notices carry AI text the creator controls.**
- Creator tasks are `source=User`, so they are not quiet. The push body is the AI summary (`executor.rs:1210-1244`). 8.14 deliberately kept writer-controlled text out of pushes (`projects-impl.md:85-86`).
- **Corrected D21:** "Runs not dispatched by the owner go to the inbox only. Any push body is platform-written ('「botin」 finished a project task'). Waits for a key or an approval still push."

**F13. Erasure leaves names behind.**
- Owner display names and botin names written into stored prompts by D12 stay after erase. Erase blanks only `users.display_name` and `instances.name` (`users.rs:336,339`), and members read the prompt (`0054:34-42`).
- **Correction:** stored prompts use name-free platform headers; the executor renders names at launch from `project_agent_names`.

**F14. Inconsistencies inside the plan:**
- §3.2 strips the header from project User runs with `split_once("\n\n")`, but D12 stores creator text raw. Strip only for Delegate and Ask.
- V4: a missing parent raises `project_run_shape`, not an FK error, because `(NEW.source='pipeline') IS DISTINCT FROM NULL` is true.

**F15. `project_agent_names` returns names of withdrawn or deleted agents.**
- The member policy hides them (`0049:96-98`), but the lead's `agent.message` would show them to members.
- **Correction:** `CASE WHEN a.left_at IS NULL AND i.state <> 'deleted' THEN i.name END`.

**F16. Errors reveal another member's account state.**
- A 409 `conflict` for "target owner not active", and `OwnerUnavailable`, tell other members that someone is frozen or stopped.
- **Correction:** use one generic 409 `agent_unavailable` for left, frozen and paused.

**F17. Target checks do not reject deleted instances.**
- They miss `instances.state <> 'deleted'` for the window between the tenant `remove_instance` and the worker retire (`instances.rs:385-420`). Add the check to the dispatcher and to `project_agent_live`.

**F18. `GrantScope::intersect` mixes alias names across owners.**
- Aliases are per instance (`domain.rs:423`). For a cross-owner child, take the target's aliases and intersect only the platform tools.

**F19. 0062 can refuse legitimate re-asks while llm-gw is mid-rollout.**
- On an UPDATE that changes `asked_at`, a row first asked through 8.17 keeps `OLD.asked_epoch`. An 8.16 llm-gw re-ask on it fails with 23514.
- **Correction:** document "upgrade llm-gw before `on`", or accept and record it.

**F20. DB backstops worth adding:**
- `runs_project_tree` requires the parent run to be non-terminal, and project agent runs to have a non-NULL `run_grant_id`.
- Triggers on `project_pipelines`, `project_pipeline_steps` and `project_board_posts` check that `project_id` matches the root or run and the agent, because their member policies trust `project_id`.

## Checked and correct
- **Grant revocation.** Target side: the child grant matches by `instance_id` and `user_id` (`grants.rs:211-291`, `378-389`). Lead side: `ancestors_usable!` in `touch_run_grant` (`grants.rs:334-360`, called from `auth/src/grants.rs:113-126`) and in llm-gw's `usable_grant_aliases` (`store/src/llmgw.rs:128-147`).
  - Two caveats. `revoke_user_grants` is not recursive. The tenant revoke cannot see other owners' rows. Both are safe only because of `ancestors_usable!`, cached for the llm-gw directory TTL.
- **Dropping the two `(x, user_id)` FKs.** Private trees stay same-owner: `fill_space` forces `space_id = user_id` (`0040:19-24`), plus the 0045 space keys. The `runs (run_grant_id, user_id)` FK stays (`0001:255`), as do the events and approvals `(run_id, user_id)` FKs.
  - Cascades never cross owners: no `DELETE FROM users`; erase deletes only private runs (`users.rs:292`); instances are soft-deleted (`instances.rs:406`). Update `projects-impl.md:24` ("解除父关联") to match.
- **Old binaries.** 8.16 cannot lease once 0060 replaces the lease fence. The trigger name order in V1 is correct. The separate board table avoids the tenant reads (`board.rs:125-244`) and erase (`users.rs:335`). `delegation_targets` excludes dedicated agents (`instances.rs:593-611`), and `is_team_lead` requires creator = owner (`instances.rs:617-627`).
- **Lock order.** No cycle with withdraw, release (`instances.rs:1251`) or artifact registration (`artifacts.rs:128-136`).

## Tests to add
- F2: S14 run as the production-style login.
- F1: O8b, the pipeline root does not copy a child's error.
- F4: withdraw a lead while it answers an ask, then check other owners' grandchildren are cancelled at once. Check the pipeline-step orphan sweep. Check tenant cancel of a project run.
- F6: stop-all is not reissued by others.
- F3: budget refusal and `max_tokens`.
- F7: the untrusted note in the handoff and in artifact tools.
- F8: a barrier between dispatch and `off`.
- F9: inject an FK error inside the savepoint.
- F10: approvals are settled on an urgent stop.
- F11: the caps.
- Mutation rows for each of these.

## 实现

# Review of the WP 8.17 implementation plan (branch `claude/determined-lovelace-vn0j5h` @ `1afbb1a`)

I checked the plan's claims and references against the code. Most of the plan's file:line references are correct. The corrections and new findings below are ordered by severity. I ran nothing on PostgreSQL. Where a finding depends on PostgreSQL behaviour, I say so.

## High

**H1. The pipeline driver can deadlock against account erase (D14, §3.4).**
- The driver's batch transaction locks every due root `FOR UPDATE` (`due_pipelines`, `runs.rs:1723-1737`). The plan then takes `pg_try_advisory_xact_lock('project/{p}')` and creates step grants and runs.
- Those INSERTs take FK `KEY SHARE` locks on `users`: `runs.user_id` and `run_grants.user_id`, and also through `ensure_project_agent_grant`.
- `erase_account` takes `users … FOR UPDATE` (`users.rs:186`), then a blocking `lock_projects` (`users.rs:207`).
- Erase holds Bob's user row and waits for `project/{p}`, which the driver holds. The driver waits for Bob's user row. The result is 40P01, which aborts either the erase or the whole tick (every user's pipelines).
- The try-lock only avoids the deadlock with withdraw. It also breaks D3 order (users → project → rows).
- **Correction:**
  - Keep `due_pipelines` private-only (`project_id IS NULL`, unchanged).
  - Add `due_project_pipelines(limit)`: a plain read with no locks.
  - Advance each project root in its own worker transaction, in D3 order: `lock_users(anchor owner, creator, step owners)` → `lock_project(p)` (blocking is fine) → `SELECT … FROM runs WHERE id=$1 AND state IN ('queued','waiting_children') FOR UPDATE SKIP LOCKED` (skip if none) → `advance`.
  - Any `store::Error` then fails or retries only that root, and no savepoint is needed.
  - This also removes the plan's incomplete error whitelist. Today `pipeline.rs:247` (`Err(e) => Err(e)`) propagates `Invalid` (`project_run_shape`, 23514) without rolling back the savepoint, so the batch transaction is left aborted (25P02).
  - Drop `try_lock_project` and the `isolated!`/`live_space!` change to `due_pipelines`.

**H2. The 0062 trigger refuses legitimate re-asks, and `touch_request!` cannot take the new column as written.**
- **Problem 1, the trigger.** On a touch (`asked_at` changes), the UPDATE does not set `asked_epoch`, so `NEW.asked_epoch` keeps `OLD.asked_epoch` (the stale epoch of an earlier run). The trigger then raises `egress_stale_token`.
  - Every re-ask of the same host fails while the request is pending. This hits an 8.16 llm-gw during the rollout or a rollback, and any 8.17 path that forgets the column. It is not deploy-safe.
- **Problem 2, the macro.** `touch_request!` (`egress.rs:94-101`) is spliced into two 3-parameter statements (`:385`, `:478`, where `$3` is the run) and the 9-parameter INSERT (`:425-447`, where `$4` is the new id). No single `$n` works in all three.
- **Corrected trigger body** (after the unchanged-`asked_at` branch):
  ```sql
  SELECT i.workspace_id, i.token_epoch INTO ws, ep FROM public.instances i WHERE i.id = NEW.instance_id;
  -- 沿用上一次问的代数、不是这句带的：过时了就当“不知道”（上一版的出口代理不填，和 0059 一样放行）
  IF TG_OP = 'UPDATE' AND NEW.asked_epoch IS NOT DISTINCT FROM OLD.asked_epoch
     AND NEW.asked_epoch IS DISTINCT FROM ep THEN
      NEW.asked_epoch := NULL;
  END IF;
  IF NEW.asked_epoch IS NOT NULL AND NEW.asked_epoch <> ep THEN
      RAISE EXCEPTION 'egress ask from an outdated sandbox token'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'egress_stale_token';
  END IF;
  NEW.workspace_id := ws;
  ```
  Add `-- deploy-safe:` on the `CREATE OR REPLACE`.
- **Corrected macro:** `touch_request!($epoch:literal)` adds `asked_epoch = <epoch>`.
  - The browser UPDATE and `touch_egress_ask` bind it as `$4`.
  - The INSERT adds `asked_epoch` to its column list as `$10` and uses `touch_request!("EXCLUDED.asked_epoch")`.
  - Both `asked_epoch` and `token_epoch` are `bigint` (`0007:23`) and `claims.ep` is a `u64` (`auth/src/sandbox_token.rs:37`). Convert with `crate::signed`, because sqlx cannot bind a `u64`.
- **Test gap:** a touch through `egress_ask` with `AskMeta::default()` on a request whose `asked_epoch` is stale must still return `Asked`.

**H3. `legacy_sessions()` returns nothing in production (§2.5, D7).**
- This depends on PostgreSQL 16's `pg_stat_activity` behaviour; I did not run it.
- `backend_type` is a privileged column. It is NULL unless `current_user` has the privileges of the session's role, or `pg_read_all_stats`.
- Under `set_config('role','thinktin_worker')` (`lib.rs:166-177`), `current_user` is `thinktin_worker`. The grants in `release.md:73-75` go the other way (the login inherits worker), so worker does not have the login's privileges.
- `backend_type = 'client backend'` therefore filters out every row. `usesysid`, `application_name`, `pid` and `datid` stay visible.
- **Correction:** add `Db::legacy_sessions(&self)` on `self.pool()` with no role switch, and drop the `backend_type` filter:
  ```sql
  SELECT coalesce(a.application_name, ''), count(*)::bigint FROM pg_stat_activity a
   WHERE a.datname = current_database()
     AND a.usesysid = (SELECT oid FROM pg_roles WHERE rolname = session_user)
     AND a.pid <> pg_backend_pid() AND a.application_name IS DISTINCT FROM $1
   GROUP BY 1 ORDER BY 1
  ```
- V5 and S14 must use the non-superuser `thinktin_test_owner` login (`testing.rs:105-107`), not the admin pool.

**H4. Commit 3 will not pass `cargo test`: the fixture list is incomplete.**
After 0060, every worker INSERT of a project row needs the switch on, and every lease of a project run needs `thinktin.project_protocol`. Fixtures the plan misses:

| Fixture | What breaks |
|---|---|
| `store/src/tests.rs:1192-1206` | worker insert of a project grant and run (mixed instance, so it also needs isolation 2) |
| `store/src/tests.rs:1238` | isolation-2 lease is expected to succeed |
| `store/src/tests/projects.rs:1757-1800` `copy_into_project` | 10 call sites, including `boundary.rs:445,623,687,1755,2336`; also its lease at `:1797` |
| `store/src/tests/boundary.rs:2410-2422` `seed_run` | lease |
| `store/src/tests/isolation.rs:544,1171` | raw leases expected to succeed |
| `client-core/tests/client.rs:2316-2331` | raw worker insert |

New assertions also fail:
- **`isolation.rs:476`** asserts `thinktin/i{ISOLATION_LEVEL}`.
- **`boundary.rs:2078` `run_linked_rows_carry_the_project` and `boundary.rs:2255` `purge_clears_run_linked_project_rows`** insert project-stamped `board_posts`, and the worker insert at `:2114-2121` is commented "8.17 的项目看板". Both violate the new `board_posts_private` CHECK. Rewrite them to assert the CHECK and drop `board_posts` from the stamp and purge tables.

**Correction:**
- `TestDb::new()` turns the switch on through `db.worker()`. The owner and member logins cannot see the row: the table has FORCE RLS and no policy, and only worker is BYPASSRLS (`0001:19`).
- S1 checks the default on a separate `TestDb::up_to(63)`.
- One helper, `store::testing::project_writer(conn, level)`, sets the role, isolation and protocol for raw fixtures.

**H5. Project pipelines leak other owners' failure text (D12 does not cover pipelines).**
- `pipeline.rs:149-157` builds `why` from `bad.run.error`/`state_reason`.
- `finish` stores it as the root's `error`/`state_reason` (`pipeline.rs:333`). The root belongs to the anchor's owner, who sees it in their own run view.
- `handoff_prompt` (`pipeline.rs:418-436`) also puts other agents' summaries into the step prompt without the "written by other agents" note, in the anchor owner's locale (`pipeline.rs:281`).
- **Correction:**
  - For project roots, `why = format!("step {key} {coarse_state}")`.
  - On failure, use `cancel_project_subtree`, not `cancel_children` (`runs.rs:1803-1822`, which skips the D13 approvals and requests steps).
  - Add the untrusted note to project handoffs, and use the step owner's locale.

## Medium

**M1. The orphan sweep is too narrow and too slow (D16).**
- A tenant `cancel_run_tree` (`runs.rs:599-624`, limited by RLS) on a pipeline root leaves other owners' steps running forever. `due_pipelines` only advances queued or `waiting_children` roots.
- `projects::sweep` runs on `maintenance_every_secs`, which defaults to 3600 (`server/src/config.rs:862`).
- **Correction:**
  - Select `c.source IN ('delegate','pipeline')`.
  - Call it from the executor takeover tick next to `expire_asks` (`executor.rs:503-511`, every 15 s per `executor.rs:85`).
  - Lock with `SKIP LOCKED` throughout, including the subtree lock.

**M2. Owner cancel crosses owners (D16 and D14).**
- An owner may cancel "its own agent's runs", and the plan always cancels the subtree across owners.
- With the anchor rule, the owner of the first step's agent owns the pipeline root, so that owner can stop every member's steps.
- **Correction:** the creator cancels the subtree across owners. A non-creator owner cancels only rows with `user_id = caller` in the subtree, and the sweeps handle the rest. Refuse `kind='pipeline'` roots for non-creators.
- Also prefer a creator-owned step agent as the anchor when the creator has one.

**M3. D20 contradicts the private "stop all" semantics. Decide before coding.**
- `account.rs:88-90` reissues grants only on the owner's own action.
- A private `ask` refuses when the target has no active grant (`ask.rs:136-147`).
- The plan's lazy reissue lets the creator, the lead or any other agent restart a botin its owner just stopped.
- **Recommended default:** `ensure_project_agent_grant` refuses (`ChildRefusal::OwnerUnavailable`, or 409 on the route) when the newest standing grant for that agent has `revoke_reason IN ('stop_all','account_deleted')` or similar, and record how the owner re-enables it. Alternatively, accept the plan's behaviour explicitly in the founder questions.

**M4. The creator-task preface is wired wrong (§3.3.3).**
- `Preface` is a single enum (`executor.rs:265-270`). `drive_inner` re-sends the base prompt inside `resume_note` when `attempt > 1` (`executor.rs:1744`), so the `attempt == 1` condition drops the preface on retries. It also cannot coexist with `Interrupted`/`Announced`.
- **Correction:** prepend the project preface to the base prompt string for every attempt of a `project_id.is_some() && source == User` run, before the Interrupted, Announced and resume wrapping.
- §3.2 `agent_status` must not `split_once("\n\n")` project User runs: the stored creator text has no header, and stripping would cut the creator's first paragraph. Keep the `peers.rs` `task()` rule (Delegate and Ask only).

**M5. `GrantScope::intersect` over aliases is meaningless.**
- Aliases are route names of one instance (`domain.rs:423`; the executor filters `route_aliases(instance)` at `executor.rs:767-772`). Intersecting the lead's aliases with Bob's compares two unrelated sets of names.
- **Correction:** the child scope is the target's standing scope, with `platform_tools ∩ parent.platform_tools`. `max_tokens` is the minimum. Aliases come from the target only.
- Drop the proto `intersect` and do this inline in `create_project_child_grant`.

**M6. The board table should use the repository's composite-FK convention (0061).**
The private board uses `(x, user_id)` FKs (`0025:20-22`). Replace the single-column FKs and the convoluted CHECK with:
```sql
FOREIGN KEY (project_id, author_user_id) REFERENCES project_members (project_id, user_id),
FOREIGN KEY (author_instance_id, author_user_id) REFERENCES instances (id, user_id) ON DELETE SET NULL (author_instance_id),
FOREIGN KEY (run_id, author_user_id) REFERENCES runs (id, user_id) ON DELETE SET NULL (run_id),
CHECK (by_agent OR (run_id IS NULL AND author_instance_id IS NULL))
```
- The trigger then only checks `r.project_id = NEW.project_id`.
- The cap query must bind `MAX_BOARD_LIVE_POSTS - 1`, as the private board does (`board.rs:136-145`), not the cap itself.

**M7. Decide board encryption now, or it forces a re-migration.**
- `projects.md:40` says the project board is "用项目密钥加密". The plan stores plaintext and leaves it as an open question.
- If someone later decides to encrypt, `body` changes type and `project_board_posts` has to be migrated again.
- **Recommendation:** plaintext, like prompts, summaries and events. Unreadable-on-delete comes from `member_projects()` and the purge. Update `projects.md:40` in the docs commit.

**M8. Turning the switch off has a race (D7).**
- The fence reads `project_dispatch.enabled` without a lock. A dispatcher transaction that passed the fence before the flip can commit after `off`'s cancel loop, leaving a project run during rollback.
- **Correction:** in `project_rows_fence`, use `SELECT d.enabled INTO on_ FROM public.project_dispatch d FOR SHARE;`. Worker's column UPDATE grant is enough for `FOR SHARE`. This conflicts only with the flip's UPDATE, not with other inserts.

**M9. D15 (urgent creator messages) belongs to 8.18.**
- `wbs.md:221` lists "打断规则" under 8.18, and the plan already defers the lead-interrupt half.
- Splitting interrupt rules means refactoring `queue_urgent_run` (`runs.rs:644-748`, tenant `self.instance()` and `self.user()`) twice.
- Drop `queue_urgent_inner`, `delivery`, and the `urgent` parameter from the API and FFI. Drop test O10.

## Low and factual corrections

1. **The `schema.rs` item is spurious.** It has no "expected latest migration" (`schema.rs:16-18` uses `sqlx::migrate!`). Drop it.
2. **8.16 review #15 is already fixed.** `isolation.rs:456-477` uses `Db::connect` (`:465`). Only `:476` needs to change, to `format!("thinktin/i{}p{}", ISOLATION_LEVEL, PROJECT_PROTOCOL)`.
3. **The late-tool-call check already exists in `ArtifactTools::origin`** (`tools.rs:514-517`). `run_space_state` is unnecessary: extract that check (`run_record` plus `instance_runtime`) into `live_project_call`.
4. **V4's expectation is wrong.** With no parent row, `parent.kind` is NULL, so `(NEW.source='pipeline') IS DISTINCT FROM NULL` is true and the trigger raises `project_run_shape` (Invalid), not an FK error. `insert_run` already returns `Invalid("parent run … not found")` (`runs.rs:279-287`).
5. **O1's count is off.** 12 tools minus the two delegate tools is 10, not 11.
6. **There is no fake server.** `ffi_smoke.py` uses `http://127.0.0.1:9` (`:57`). Test the record defaults (`can_dispatch`, `EgressRequest.project_id`) and the InvalidArgument and Network paths.
7. **§3.6 contradicts §5.5.** The memory ledger "ignores" the epoch, yet §5.5 tests a stale ask on it. Either give the memory ledger a current epoch, or test stale asks on pg only.
8. **Commit 2 will not compile.** The new proto fields break struct literals at `store/src/egress.rs:75-83`, `store/src/project_reads.rs:478` and `proto/src/domain.rs:1957`. Update them there, or add the fields in commits 8 and 9.
9. **Android CI fails on commit 11 alone.** `sync-core.sh --check` runs in CI (`.github/workflows/android.yml:59`). Regenerate the bindings in the same push.
10. **Keep `allow_secrets` for project text.** `refuse_secrets` is pattern detection (`client.rs:417-428`), not a vault check. Without the override, false positives cannot be sent at all. The server-side vault 422 stays the hard block.
11. **Reuse the member projection for names.** `project_agent_names` exposes withdrawn agents' names, unlike the member policy (`0049`, member_read on instances, lines 105-107). Use `Db::member(rec.user_id).project_detail(p)` for names and the creator, and drop `project_agent_names` and `project_brief`.
12. **Over-engineering:**
    - `project_pipeline_steps` can be a `steps jsonb` column on `project_pipelines`: steps are immutable once started and are validated by `order_steps`.
    - `PROJECT_GRANT_TTL` duplicates `cfg.grant_ttl` and the auth renew TTL; `PROJECT_CHILD_GRANT_TTL` duplicates `delegate.rs:35`.
    - The shim `INSTRUCTIONS` text (`agent-shim/src/bridge.rs:40`) is baked into the sandbox image. Neutral tool descriptions from the orchestrator are enough.
    - `EgressRequest.project_id` labelling is 8.18 UI.
13. **Dispatcher-only is not enforced in Rust.** `NewRun.project_id` is a `pub` field and `Tx<Worker>::create_run` is `pub` (`runs.rs:1127-1129`). Make the field `pub(crate)`, or add a crate-private `insert_project_run`.
14. **Budget inheritance.** In A(Alice) → B(Bob) → A2(Alice), A2 gets the default budget while the root's per-owner sum includes it. Use the budget of the nearest same-owner ancestor.
15. **Cross-owner children are uncapped until 8.18.** `RunBudget::default().max_tokens` is None (`domain.rs:376-383`). Note in `release.md` that `cross_user_projects` stays off until 8.18 budgets, as well as 8.19 reports.
16. **Record two decisions.** D2's rejection of "team runs as project runs" (listed in the 8.16 plan §8) goes in `wbs.md` and the progress file. The `0056:2` comment ("8.17 的项目看板") is now stale.

## Missing tests

- Erase racing with project pipeline step creation (H1).
- A touch from an epoch-less ask (H2).
- `legacy_sessions` under the non-superuser login (H3).
- A pipeline root's error contains no step error text (H5).
- Steps of a tenant-cancelled pipeline root get swept (M1).
- Non-creator cancel scope (M2).
- Dispatch after the target owner's stop-all (M3).
- Preface on attempt 2, and `agent_status` keeping the creator's first paragraph (M4).
- `off` racing an in-flight dispatch (M8).
- A tenant `board_posts` insert with a project `run_id` gives 23514.

## Verified as correct

- The `project_dispatch` setup works as written: RLS with no policy is fine because worker is BYPASSRLS, and the insert happens before RLS is enabled.
- The CHECK validation and `CREATE OR REPLACE` are fine under the non-superuser owner.
- The trigger name order is as stated: `runs_instance_space` < `runs_project_fence` < `runs_project_tree` < `runs_space`.
- The FK names are `runs_parent_run_id_user_id_fkey` and `run_grants_parent_id_user_id_fkey`.
- Revocation in either direction works through `ancestors_usable!`, which llm-gw also checks (`store/src/llmgw.rs:133`).
- The D3/D13 lock order holds for the creator-task, child-run, lead and board paths.
- Withdraw and release take `project/{p}` first (`project_members.rs:460`, `instances.rs:1251`).
- `Error::DispatchOff` compiles through the gateway's catch-all arm (`gateway/src/error.rs:104`).
- Team, Teams FFI and old-App flows are unaffected.