# 8.13 代码地图（原始结果，2026-11-04）

workflow `projects-8-13-plan` 的第一步：4 路读代码（团队、行级安全、运行和授权的键、会话和工作区）。英文原样。

## Map: teams

Everything below comes from reading branch `claude/determined-lovelace-vn0j5h` at HEAD `be8afae`; I modified nothing. Paths are relative to /home/user/Thinktin-Rust. Line numbers cited in projects-design-A.md are out of date, so the corrected ones are given here.

## 0. Facts that change the plan before any code

1. **Migration numbers are taken.** Design A calls its migrations 0031–0036, but the branch already has 0031_windows_devices.sql up to 0038_browser.sql. The next free number is **0039**. origin/main stops at 0031 and has no backend changes since the merge base.
2. **Nothing has been released yet.** There are no `v*` tags, so `tools/ci/check_migrations.py` only checks file names and numbering for now (docstring lines 16-17). The `deploy-safe:` rule is not enforced yet.
3. **Tests run as a superuser.** `tools/dev/setup-db.sh:14-19` creates `thinktin_dev SUPERUSER`, and `store/src/testing.rs:17-44` makes one database per test and migrates it as that user. A superuser ignores RLS, including FORCE. No test migrates as a non-superuser owner like production's `thinktin_owner` (`docs/deploy-checklist.md:57-71`).
4. **Roles are shared across parallel test databases.** Roles are cluster-wide, so new roles must use the existing pattern `DO $$ BEGIN CREATE ROLE … EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $$;` (`0001_init.sql:16-18`).
5. **The approved plan overrides design A on who writes single-user projects.**
   - Design A routes `POST /v1/teams` to `Tx<Worker>::create_project` and gives `thinktin_app` no write access to project tables (design-A.md lines 501, 540).
   - projects-impl.md says the restricted write path for single-user projects must reuse the existing tenant transaction, and only the server may do cross-user writes.
   - This decides atomic adoption. `control::adopt_in` takes `&mut Tx<Tenant>` (`control/src/lib.rs:216-224`) and `create_run_grant` is a tenant method (`store/src/grants.rs:67-83`). Creating the project in a worker transaction would break today's single-transaction adoption.
   - So project tables need tenant write policies (or a hardened SECURITY DEFINER function) limited to: creator is me, the only member is me, the agents are mine.
6. **Invites are in scope for 8.13.** WBS 8.13 (`docs/wbs.md:216`) and projects.md section 3 list `ProjectInvite` in 8.13. Design A defers invites to its phase P6 (design-A.md lines 70, 1145).

## 1. Store: tables and migrations

**`crates/store/migrations/0002_collaboration.sql`**
- Lines 5-13, `teams(id, user_id → users ON DELETE CASCADE, name, created_at, updated_at, UNIQUE(id,user_id))`, plus index `teams_user`.
  - Becomes `projects` with `creator_id`, `goal`, `status`. Keep `id`, so `TeamId == ProjectId`.
- Lines 16-25, `team_members(team_id, instance_id, user_id, role CHECK IN ('lead','member') DEFAULT 'member', position, PK(team_id,instance_id))`.
  - Composite foreign keys `(team_id,user_id)→teams` and `(instance_id,user_id)→instances` cascade, which keeps a team to one user.
  - Becomes `project_members` (the creator row) plus `project_agents(project_id, instance_id, user_id, is_lead, position, left_at, …)`. Keep `FOREIGN KEY (instance_id,user_id) REFERENCES instances(id,user_id)` and add `(project_id,user_id)→project_members`.
- Line 27, `team_one_lead`: unique index on `(team_id) WHERE role='lead'`.
  - It also counts rows whose instance was soft-deleted, because instance delete only sets `state='deleted'`.
  - Replace it with a unique index on `(project_id) WHERE is_lead AND left_at IS NULL`.
- Lines 30-37, `team_templates(id, user_id, name, spec jsonb NOT NULL, created_at, UNIQUE(id,user_id))`. There is no CHECK on `spec`.
  - Becomes `project_templates`; design A keeps the same columns and spec format.
- Lines 95-105: ENABLE plus FORCE RLS, and policy `tenant TO thinktin_app USING/WITH CHECK (user_id = app_user_id())` on teams, team_members and team_templates.
- Line 107: app gets SELECT/INSERT/UPDATE/DELETE. Line 110: worker gets the same.
  - The new tables need explicit grants. The worker grant `ON ALL TABLES` in `0001_init.sql:477` only covered tables that existed at the time.
- Lines 57-68, `plan_steps`: foreign key `(instance_id,user_id)→instances`. Pipelines are tied to one user, not to a team.

**Related run constraints in `0001_init.sql`**
- Line 252: `runs (parent_run_id,user_id)→runs`. Lines 250 and 253: the plan and grant foreign keys also include `user_id`. Line 172: `run_grants (parent_id,user_id)`.
- So the database forbids run trees that span users. 8.13 can leave this alone for single-user projects. Design A's `scope_id` replacement belongs to 8.15.
- Line 21: `app_user_id()` reads `app.user_id`.

**`crates/store/src/teams.rs`** (all methods are on `Tx<Tenant>` and rely on RLS; none filter by `user_id` themselves)

| Lines | Method | What it does | Change for 8.13 |
|---|---|---|---|
| 13-22 | `create_team` | `TeamId::new()` (UUIDv7), insert with `user_id = app_user_id()`, then `insert_members`, then re-reads with `team()` | Insert into `projects`, `project_members` (creator) and `project_agents` instead |
| 24-42 | `insert_members` | Rejects more than one lead (`Error::Invalid` → 422); calls `self.instance()` per member (RLS plus not deleted, so another user's instance gives NotFound → 404) | Same checks, written to `project_agents` |
| 44-74 | `team` | Reads name and created_at; members joined to `instances` with `state <> 'deleted'`, ordered by position, then instance_id | Read from project tables. Filter on my non-deleted, not-left agents |
| 76-85 | `teams` | All teams ordered by created_at, one query per team | Design A: only projects I created that are active |
| 88-112 | `update_team` | Renames with `coalesce`; if members are given, deletes every member row and re-inserts | Delete-and-reinsert would wipe per-agent settings (`purpose`, vault and computer grants) and `added_at`. Needs a diff over my own agents only |
| 114-123 | `delete_team` | Deletes the team; members cascade | Deletes the project. Design A: return 409 if other members exist |
| 125-189 | template methods | `create_team_template`, `team_templates`, `team_template`, `delete_team_template` on the `team_templates` table | Point at `project_templates` |

**Other store code**
- `instances.rs:562-577`, `Tx<Tenant>::delegation_targets(lead)`.
  - Returns non-deleted instances other than `lead` that belong to any team where `lead` has role `lead`.
  - It has no `user_id` condition and relies on tenant RLS.
  - Rewrite it over `project_agents` (`is_lead AND left_at IS NULL`).
  - The tenant policy on `project_agents` must stay `user_id = app_user_id()`, otherwise private runs would start delegating to other users' agents.
- `instances.rs:580-590`, `Tx<Worker>::is_team_lead(instance)`: `EXISTS team_members WHERE instance_id=$1 AND role='lead'`.
  - It is global: it ignores which team, whether the instance is deleted, and whether the team has anyone else.
  - Move it to `project_agents … is_lead AND left_at IS NULL`. Design A proposes splitting it into `is_lead(instance, scope)` and `private_delegation_targets`.
- `instances.rs:259-270`, `lock_instance_count`: advisory lock `instances/{user}` held until the transaction ends, then counts non-deleted instances. Adoption depends on it.
- `instances.rs:384-411`, `delete_instance`: a soft delete that does not touch `team_members`. The gateway delete handler (`gateway/src/routes/instances.rs:372-393`) runs `retire_instance_plans`, cancels runs, revokes grants, then deletes.
  - With projects, the same tenant transaction must also set `project_agents.left_at` and clear `is_lead`.
- `users.rs:211-212`, `erase_account`: `DELETE FROM teams WHERE user_id`, `DELETE FROM team_templates WHERE user_id`; members cascade.
  - Add projects where `creator_id` = the user, `project_templates`, and later the user's rows in other users' projects (8.15 / 16.6).
- `lib.rs:33`: `mod teams;` (no `pub use`).
- `lib.rs:123-137`: `Db::tenant` sets `role=thinktin_app` and `app.user_id`.
- `lib.rs:140-149`: `Db::worker` sets `role=thinktin_worker` (BYPASSRLS).
- `error.rs:37-53` maps database errors:
  - 23505 → Conflict (409); 23503 → Invalid "reference …" (422); 23514 → Invalid; 42501 → Forbidden (500).
  - Design A wants 42501 to become 404 on project paths.

## 2. Gateway

- `routes/mod.rs:18` and `158-169` register the routes:
  - `GET/POST /v1/teams`
  - `GET/PATCH/DELETE /v1/teams/{id}`
  - `GET/POST /v1/team-templates`
  - `DELETE /v1/team-templates/{id}`
  - `POST /v1/team-templates/{id}/adopt`
  - There is no `/v1/projects*` route yet.
- `routes/teams.rs`. Every handler uses `s.db.tenant(who.user)`:
  - Line 16: `MAX_MEMBERS = 12`. Lines 18-25: `check_members` requires 1-12 members, otherwise 422.
  - 27-32 `list` returns `{"teams":[Team]}`.
  - 40-51 `create`: name trimmed, 1-64 characters → 201.
  - 53-63 `get`.
  - 71-94 `update`: optional name and members.
  - 96-106 `delete` → 204.
  - 108-113 `templates` returns `{"templates":[TeamTemplate]}`.
  - 115-162 `create_template`: exactly one of `spec` or `team_id`, otherwise 422. With `team_id` it snapshots each member's `agent_id`, `harness`, `name` and `role` from `t.instance()`. It then checks 1-12 members, member names 1-64, and that `s.templates.current(agent_id)` exists.
  - 164-174 `delete_template`.
  - 181-226 `adopt_template` (section 6).
- `routes/mod.rs:196-201`, `default_scope`: `GrantScope { platform_tools: cfg.default_platform_tools }`.
- `routes/mod.rs:204-206`, `parse_id`: a malformed id gives 404.
- **What changes:** paths, status codes and JSON shapes stay the same; the handlers read and write projects. Optionally add new `/v1/projects*` routes and `/v1/project-templates*` (design A: both template paths share one table).

## 3. Proto types and wire format

- `crates/proto/src/domain.rs:64-65`: `TeamId` and `TeamTemplateId` come from `id_type!` (lines 11-49): serde-transparent UUIDs, `new()` is UUIDv7.
- Lines 298-305: `TeamRole { Lead="lead", Member="member" }`.
- Lines 922-964:
  - `Team{id, name, members: Vec<TeamMember>, created_at}`
  - `TeamMember{instance_id, role, position: u32}`
  - `TeamTemplate{id, name, spec: TeamTemplateSpec, created_at}`
  - `TeamTemplateSpec{members: Vec<TemplateMember>}`
  - `TemplateMember{agent_id, harness: Option (serde default), name, role (default "member", from member_role at 962-964)}`
- No `deny_unknown_fields` anywhere in proto, client-core or the team routes. The server can add fields such as `project_id`, `goal` or `my_role` without breaking current clients. Removing or renaming fields would break them.
- **What changes:** nothing is required. Add `Project*` types alongside.

## 4. client-core

- `src/api.rs:1722-1818`, HTTP calls:
  - `teams`, `create_team`, `team`, `update_team` (PATCH body only includes fields that were given), `delete_team`
  - `team_templates`, `create_team_template(name, spec?, team?)` (sends `{"name","spec","team_id"}`), `delete_team_template`, `adopt_team_template(id, name?)` (sends `{"name"}`)
- `src/ffi.rs:816-918`, UniFFI records `TeamMember`, `Team`, `TemplateMember`, `TeamTemplate`. Roles are plain strings checked by `from_enum_str(…,"team role")`, so `"boss"` gives `InvalidArgument`. Ids are strings.
- `src/ffi.rs:2592-2708`, the 10 FFI methods: `teams`, `create_team`, `team`, `update_team`, `delete_team`, `team_templates`, `create_team_template`, `create_team_template_from_team`, `delete_team_template`, `adopt_team_template`.
- Teams are not in `cache.rs` or `events.rs`, so there is no offline team cache.
- **What changes:** nothing, if `/v1/teams*` keeps its shape. New `Project*` records and methods would be additions. Only the Android binding is committed (`apps/android/core/src/main/kotlin/cn/thinktin/core/client_core.kt`, 127 "team" hits); regenerate it with `tools/client-core/gen-bindings.sh`. iOS generates its binding at build time.

## 5. Apps

- **Android**
  - `apps/android/data/.../core/CoreThinktinService.kt:390-413` wraps all 10 methods.
  - Team screens and view models: `app/.../ui/teams/TeamsViewModels.kt` (line 279 enforces `NoLead`), `TeamsScreens.kt`, `InstanceSettingsViewModel.kt`, plus models, mappers and mocks.
- **iOS**
  - `apps/apple/ThinktinKit/Sources/ThinktinCoreAdapter/CoreClient.swift:491-545` wraps the 10 methods.
  - `ViewModels/Teams/TeamsModels.swift:204` enforces `noLead`.
  - `InstanceDeletionImpact.swift:16,91-110` works out team impact from the team list.
  - Also `AppRoute`, `Screens/Teams/*`, `Core.swift`, `Conversions.swift`.
- Both apps require a lead; the server does not. According to the survey, the apps also pre-fill pipelines from a team on the client side.
- **What changes:** nothing in 8.13. The UI renames are 12.25 and 13.18.

## 6. Adoption flow and its transaction (`gateway/src/routes/teams.rs:181-226`)

All steps run in one `Tx<Tenant>`:
1. `team_template(id)`. Another user's template gives 404.
2. Resolve the name (`req.name` or the template name), trim, check 1-64 characters. This happens before any lock; a bad name gives 422 and creates no instances.
3. If `instances_per_user > 0` and `lock_instance_count() + n > max`, return 409 `instance_limit`. The advisory lock is held to commit, so concurrent adoptions queue up.
4. For each member:
   - `control::adopt_in` resolves the agent and harness and validates the name (unknown agent → 404, bad harness → 422). It inserts the instance, appends an `instance.state` event and writes an `instance.adopt` audit row (`control/src/lib.rs:216-293`).
   - Then `t.create_run_grant(instance, None, &default_scope(&s), s.cfg.grant_ttl)` creates a private top-level grant.
   - Role becomes Lead or Member; position is the index.
5. `t.create_team(name, &members)`, then commit, then 201 with the `Team`.

Any error drops the transaction, so nothing is half-created. There is no audit row for the team itself.

For comparison, a single `POST /v1/instances` uses two transactions: `adopt_capped` commits, then the grant is created (`routes/instances.rs:38-52`).

**What changes:** the single-user project rows must be written inside this same tenant transaction (fact 5). Design A also states that adopted teams keep the old behaviour: private grants with the full default scope, and their runs carry no `project_id`.

## 7. Template storage format

- Column `team_templates.spec jsonb`, written with `to_json(&TeamTemplateSpec)` and read with `from_json(…, "team template")`; a bad row gives `Error::Corrupt`.
- Shape: `{"members":[{"agent_id":"claude","harness":null|"cli","name":"主编","role":"lead"|"member"}]}`.
- No version field and no database validation. Validation only happens in the gateway when the template is created; the harness is only checked at adoption.
- It already describes members by agent kind and creates instances on adoption, which is what projects.md asks of project templates.
- Design A keeps it as is: `project_templates.spec` holds `TeamTemplateSpec` unchanged, and it is only visible to its owner (design-A.md lines 172-180).

## 8. The leader concept and orchestrator code scoped by team or user

**Who gets delegate tools**
- `server/src/config.rs:155`: every grant's default platform tools include `DELEGATE_TOOLS`.
- `orchestrator/src/executor.rs:770-776`: a run gets them only if the scope has them and `w.is_team_lead(instance)`. Line 850 filters them out otherwise.
- `executor.rs:1914-1918`: calls to tools outside `allowed_tools` are refused at call time.

**`orchestrator/src/delegate.rs`**
- 44-49: targets come from `tenant(ctx.user).delegation_targets(ctx.instance)`.
- 81-86: no targets gives the error "only the lead of a team can delegate…". This also fires for a lead whose team has only itself.
- 101: `lock_run_waits(ctx.user)`, a per-user advisory lock (`store/src/runs.rs:428-435`).
- 103-133: depth limit `MAX_DEPTH = 3`, chain and wait-cycle checks, at most 10 children.
- 137-143: `create_child_grant(ctx.grant, target, same scope)`. The child grant belongs to the parent grant's user (`grants.rs:246-275`).
- 144-148: the lead is named by its `agent_id` in `texts::delegated_task` ("团队负责人（{lead}）", `texts.rs:480-490`).
- 169-173: `create_run(ctx.user, …)`, so the child run is private and has the same owner.
- 174-181: a `delegate.started` event on the lead's instance.

**Resuming the lead**
- `executor.rs:809-818` names finished children through `tenant(rec.user_id).instance(child)`. A cross-user child would get an empty name; that is for later work packages.

**Not scoped by team, only by user** (all through tenant RLS)
- Peers: `peers.rs:46-51` and `92` use `tenant.peers()`; `store/src/instances.rs:535-560` has no user condition and relies on RLS.
- Ask: `ask.rs:65-68` (tenant peers), `84` (`lock_run_waits(ctx.user)`), `86` (`accepts_questions`).
- Board: `board.rs:59` and `90` use tenant transactions. The "team or project" tags (`board.rs:186,207`) are free text and not linked to the `teams` table.
- Pipelines:
  - `pipeline.rs:209-273`: `start_step` uses `create_run(root.user_id)` and a child grant from the root's grant.
  - `pipeline.rs:438-479`: `HandoffCopier` reads artifacts through a worker transaction.
  - `gateway/src/routes/plans.rs:101-120` checks step shape; `store/src/plans.rs:252-279` (`set_plan_steps`) checks ownership through RLS.

**Behaviour the tests depend on**
- One instance can lead several teams and be a member of others, including two teams with the same pair in opposite roles (`orchestrator/tests/executor.rs:2117-2133`, `2240-2252`).
- `project_agents` keyed on `(project_id, instance_id)` allows this. The non-dedicated case must not add a uniqueness rule per instance.

**What changes in 8.13:** only `delegation_targets` and `is_team_lead` move to `project_agents`, keeping private behaviour. Peers, ask, board, pipelines and the per-user lock stay as they are until 8.17 / 8.18 (design A: global `run_waits` lock, project-scoped transactions).

## 9. Tests

**Should pass unchanged if the compatibility layer is right**
- `gateway/tests/api.rs:1266` `teams_pipelines_and_artifacts`
  - Covers: empty members → 422; another user's instance → 404 (1298-1307); another user's GET → 404; PATCH rename.
  - Template from a team, a bad agent → 422, adopt gives two new instances with `members[0].role=="lead"`, then 2 teams.
  - Deleting the team keeps its instances (1549-1558).
- `api.rs:1682` `other_users_objects_are_invisible`: team and template set up at 1732-1748; 404 cases at 1890-1902; empty lists at 1941-1942.
- `api.rs:2581` `instance_limit_over_http`: "no half team" at 2625.
- `api.rs:2657` `team_adoption_is_all_or_nothing`: a bad name gives 422 with 0 instances; of two concurrent adoptions one gets 201 and one 409, leaving exactly 3 instances and 1 team.
- `client-core/tests/client.rs:1640` `ffi_teams_and_templates`: through UniFFI, including role "boss" → `InvalidArgument` and deleting a team keeping 4 instances.
- `orchestrator/tests/executor.rs`: `delegation_env_with` 2005-2038, `the_lead_delegates…` 2048, `delegating_back_up_the_chain_is_refused` 2111, `the_run_tree_shares_one_token_budget` 2156, helper `team()` 2215-2236, `delegation_stops_at_three_levels` 2240.
  - These call `Tx<Tenant>::create_team` directly, so the store method should keep its signature as a compatibility wrapper.

**Will break and need updating**
- `store/src/tests.rs:820` `erasing_an_account_deletes_its_content`.
  - It creates a team and a template for both users (952-976). For each of `teams`, `team_members` and `team_templates` (1084-1086) it asserts Alice has 0 rows and Bob has more than 0.
  - If `create_team` stops writing the old tables, Bob's check fails. The new tables also need adding. `projects` has `creator_id` rather than `user_id`, so the `count(table,user)` helper will not work on it.
- `store/src/tests.rs:764` `every_tenant_table_the_app_can_touch_has_rls`.
  - It only scans tables with a `user_id` column, so `projects(creator_id)` would not be covered.
  - It also requires `"teams"` among the app-reachable tables (812); that fails if the table is dropped or the app's privileges are revoked.
- `tenants_are_isolated` (`tests.rs:93`) does not cover teams at all.

**Missing coverage that projects-impl.md requires before reads switch over:** migrating as a non-superuser owner with FORCE RLS; parallel role creation; old API/FFI clients atomically adopting and reading/writing on the new schema; adoption rollback.

## 10. Rollout and sync risks the plan names

- **One source of truth.** projects-impl.md requires old and new clients to see the same project id during the transition, with no double adoption, double editing or orphan instances.
  - That means `TeamId == ProjectId` and `TeamTemplateId == ProjectTemplateId`, with a single table behind each.
  - Design A leaves the old tables in place but unused until after the app switch (design-A.md line 533). During a rolling deploy, an older server would still write `teams`. With no production data that is acceptable, but it should be written down.
- **Data copy.** Design A copies data with the same ids: teams → projects plus a creator member row; team_members → project_agents with `left_at = now()` for deleted instances; templates copied as is.
  - The copy temporarily turns FORCE off on teams, team_members, team_templates and instances inside the migration transaction. There is no production data, but dev and staging databases may have rows.
- **Request limits stay.** Teams and templates still accept 1-12 members per request. The 10-user / 30-agent project limits are enforced in the database (design A) or under a per-project lock (projects-impl.md).

## Map: rls

# Database security model and how to add `thinktin_member` and `ProjectTx` (WP 8.13)

Facts below were read from branch `claude/determined-lovelace-vn0j5h` at commit `be8afae`. Items marked **[verified]** were run on the local PostgreSQL 16.15 in a scratch database, using a non-superuser owner that applied every migration. The scratch database and roles were dropped afterwards. No repo files were changed.

**The main problem: the documented production migration path is broken.**
- A table owner with no CREATEROLE fails migration 0001 at line 16. With CREATEROLE but no BYPASSRLS it fails at line 17 instead.
- Postgres checks permission before it checks whether the role already exists. The `duplicate_object OR unique_violation` handler never sees the error. **[verified]**
- `deploy-checklist.md:59-60` says pre-created roles are skipped. That is wrong.
- CI and every test run migrations as superuser, so nothing catches this.

## 1. Roles

| Role | Created at | Attributes | Purpose |
|---|---|---|---|
| `thinktin_app` | `0001_init.sql:16` | NOLOGIN NOBYPASSRLS | Tenant API, under RLS |
| `thinktin_worker` | `0001:17` | NOLOGIN BYPASSRLS | Background jobs |
| `thinktin_llmgw` | `0001:18` | NOLOGIN BYPASSRLS | Model gateway, narrow grants |
| `thinktin_relay` | `0014_device_relay.sql:15` | NOLOGIN BYPASSRLS | Device relay, narrow column grants (`0014:84-92`) |

- **Creation idiom:** `DO $$ BEGIN CREATE ROLE … ; EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $$;`. The reason is in `0001:8`: concurrent test-database creation races on cluster-level roles. **[verified]** A concurrent `CREATE ROLE` fails with 23505 on `pg_authid_rolname_index`. A concurrent identical `GRANT r TO u` only raises a NOTICE.
- **Production logins** (`docs/deploy-checklist.md:54-71`, `docs/release.md:59-72`, `crates/server/src/secrets.rs:27-33`):
  - `thinktin_owner` is LOGIN, owns the tables, and runs migrations. It has no CREATEROLE and no BYPASSRLS.
  - `thinktin_server_login` gets `thinktin_app` and `thinktin_worker`.
  - `thinktin_llmgw_login` and `thinktin_relay_login` get their own roles.
  - The checklist pre-creates the four NOLOGIN roles.
- **Dev and CI:** `thinktin_dev` is LOGIN SUPERUSER (`tools/dev/setup-db.sh:14-19`; CI's `POSTGRES_USER` in `.github/workflows/ci.yml:17-33`, with `THINKTIN_REQUIRE_DB=1`).
- No non-superuser migration role exists anywhere in the code. The only role switch in tests is `SET LOCAL ROLE` for worker, llmgw and relay reading `_sqlx_migrations` (`crates/store/src/tests.rs:2803-2815`).

## 2. How transactions set the role and settings (`crates/store/src/lib.rs`)

- `Db::tenant` (lines 122-137) runs one statement: `SELECT set_config('role','thinktin_app',true), set_config('app.user_id',$1,true), set_config('statement_timeout',$2,true)`. Timeout is 15s (line 87).
- `Db::worker` (139-149) sets only role and a 60s timeout (line 89).
- `Db::llmgw` (151-161) and `Db::relay` (163-174) set only role and the 15s timeout.
- Every setting is transaction-local (`true`), equivalent to `SET LOCAL`.
- `app_user_id()` (`0001:20-23`) is plain `LANGUAGE sql STABLE`, not SECURITY DEFINER: `nullif(current_setting('app.user_id', true), '')::uuid`. If unset it returns NULL, so no row matches. EXECUTE is granted to app, worker and llmgw (`0001:464`) and never revoked from PUBLIC.
- `Tx<R> { tx, role: R }` is at lines 177-181. Role markers `Tenant{user}`, `Worker`, `Llmgw`, `Relay` are at 183-199. Capability traits `Internal` and `SessionCheck` are at 201-209.
- `Tx::conn()` is private to the crate (line 229). The gateway and orchestrator cannot run raw SQL; only store methods can.
- Many methods sit on generic `impl<R> Tx<R>` blocks, so any new `Tx<Member>` would inherit them:
  - `runs.rs:265` (`run`, `run_tree` at 317-337), `:364`, `:424` (`lock_run_waits`, `accepts_questions`)
  - `events.rs:37` (`append_event` 40-73, `events_after` 76-93, `event_range` 96-110) and `:113` (`recent_run_events`)
  - `artifacts.rs:160`, `:266`
  - `grants.rs:177` (`revoke_*`)
  - `plans.rs:422`
  - `inbox.rs:91` (`insert_inbox`, `settle_*`)
  - `im_channels.rs:281`, `device_relay.rs:107`, `users.rs:265`
- **Error mapping:**
  - Store (`crates/store/src/error.rs:37-55`): 42501 becomes `Forbidden` (line 51), 23503 becomes `Invalid("reference …")`, 23505 becomes `Conflict`, and `RowNotFound` becomes `NotFound`.
  - Gateway (`crates/gateway/src/error.rs:67-80`): `Forbidden` falls into `other => internal`, so it returns 500. `NotFound` returns 404.

## 3. How RLS policies are written

- **Standard tenant policy:** `CREATE POLICY tenant ON <t> TO thinktin_app USING (user_id = app_user_id()) WITH CHECK (user_id = app_user_id())`. It is generated in loops at `0001:427-437`, `0002:96-105` and `0009:48-57`, and written per table elsewhere (`0008:20`, `0012:15`, `0017:37`, `0018:45`, `0019:34`, `0025:35`, `0030:22`).
- **Read-only variants** have USING only: `0014:73` (`FOR SELECT`), `0032:45` and `0032:48`, `0034:42`, `0036:16`.
- **Special cases:**
  - `users` self policy (`0001:440-442`).
  - `audit_log` and `outbox` `FOR INSERT … WITH CHECK` (`0001:445-457`).
  - `outbox` `read_own_keys FOR SELECT`, plus a column grant of only `(user_id, dedupe_key)` (`0001:459,474`). Tested at `tests.rs:625-638`.
- **No-policy tables** are deny-by-default: `login_codes`, `user_keys` (`0001:449-454`), `session_refresh_history` (`0007:12-13`), `device_calls` (`0014:77-78`).
- **FORCE RLS** is set on every RLS table except two. `blob_purge` has ENABLE only (`0007:36`) so owner-owned definer triggers can write it. `im_bot_slots` (`0017:47-51`) has no RLS at all and is granted to the worker only.
- **Why FORCE:** `0001:426` says it is so that "the owner is also bound". Policies are only `TO thinktin_app`, so under FORCE the owner sees zero rows. **[verified]**
  - Owner `SELECT` returns 0 rows. `UPDATE` silently changes 0 rows. `INSERT … SELECT` copies 0 rows. A literal `INSERT` fails with 42501.
  - `ALTER TABLE … NO FORCE` → copy → `FORCE` inside one transaction works.
  - Consequence: the existing backfills already no-op under the production owner: `0015:7`, `0024:13`, `0025:43`, `0026:16`, `0034:6`, `0036:22`, `0038:20`. This is harmless only because there is no production data.
- **Events partitions:** `events` is `PARTITION BY RANGE` (`0001:271-282`). Partitions are created by `ensure_event_partitions` with no RLS of their own. The policy lives on the parent only, so a role must never be granted privileges on a partition.
- **Composite foreign keys `(x_id, user_id)` everywhere** (`0001:13-14`). Foreign-key checks ignore RLS. Example: `teams`/`team_members` at `0002:5-27`.

## 4. Grant conventions

- `thinktin_app` gets explicit per-table grants, increasingly column-limited:
  - `0017:39-41` (UPDATE column list)
  - `0018:47-51`
  - `0023:24-27`: `REVOKE INSERT, UPDATE ON instances`, then column-limited INSERT/UPDATE
  - `0024:9`, `0025:38-39`, `0034:45`
- `thinktin_worker`: `0001:477` `ON ALL TABLES` only covered tables that existed then. Every later table gets an explicit grant (`0002:110`, `0008:24`, `0009:61`, …). Newer tables give the worker less than full access (`0032:54`, `0034:47`).
- `thinktin_llmgw` is narrow, including column grants: `0001:483-484`, `0009:63`, `0034:46,49` (`runs (id, user_id, instance_id, kind, state)`).
- `0016:3` grants `_sqlx_migrations` SELECT to worker, llmgw and relay for the startup check.
- There are no `ALTER DEFAULT PRIVILEGES` anywhere.

## 5. Existing SECURITY DEFINER functions (all owned by the migration account)

| Function | Location | Settings |
|---|---|---|
| `ensure_event_partitions(date,int)` | `0001:286-298` | `SET search_path = public`; REVOKE PUBLIC and GRANT worker at `0001:478-480` |
| `drop_event_partitions_before(date)` | `0001:302-319` | same |
| `queue_artifact_blob_purge()` trigger | `0007:40-48` | `search_path = public`; `REVOKE ALL … FROM PUBLIC` |
| `queue_workspace_archive_purge()` trigger | `0023:33-61` | same; key-prefix check |

None reads a FORCE table. All use `search_path = public`, which leaves `pg_temp` searched first for relation names. **[verified]** A `thinktin_app` session that creates a temp table named `blob_purge` makes `queue_artifact_blob_purge` resolve to it. Here that only made the user's own artifact delete fail. The plan's "fixed search path" rule is not met by these four. New functions should use `SET search_path = pg_catalog, public, pg_temp` and schema-qualified names. The old ones can be fixed with `ALTER FUNCTION … SET search_path`, which the lint allows.

## 6. Migration conventions

- **Name and numbering:** `NNNN_lowercase.sql`, contiguous from 0001 (`tools/ci/check_migrations.py:29`, `:318`). The latest is `0038_browser.sql`, so **8.13 starts at 0039**.
  - Design A's numbers 0031-0036 are stale: 0031 is now `0031_windows_devices.sql`.
- **Release rules** (`docs/release.md:33-52`): expand then contract; additive changes only.
  - Breaking statements (DROP, RENAME, type change, SET NOT NULL, REVOKE, DELETE without WHERE) need a preceding `-- deploy-safe: <reason>` comment (`check_migrations.py:30,179-190,212-215,228-256`).
  - Adding a constraint or index to an existing table, or a full-table UPDATE, only warns (`:251-269`).
  - `CREATE INDEX CONCURRENTLY` goes in its own file whose first line is `-- no-transaction` (`release.md:47-50`). No such file exists yet.
- **No tags yet.** There are no `v*` tags, so `check_migrations.py` only checks file names; there are no checksum or deploy-safe checks yet (CI `ci.yml:42-45`).
- **Runner:**
  - `Db::migrate` (`crates/store/src/schema.rs:96-103`) uses `sqlx::migrate!("./migrations")` with `set_ignore_missing(true)` and sqlx's advisory lock. Each file is one transaction.
  - Production runs it as the owner through `thinktin-server migrate` (`schema.rs:3-8`).
  - Services refuse to start on pending, modified or failed migrations (`schema.rs:20-60,107+`).
  - sqlx 0.9 has `Migrator::run_to(target, conn)` (`sqlx-core-0.9.0/src/migrate/migrator.rs:185`). This makes a backfill test possible: migrate to 38, seed rows, migrate to 39 as the owner.

## 7. How tests create databases, roles and migrations

- `store::testing::TestDb::new` (`crates/store/src/testing.rs:17-44`):
  - connects as `DATABASE_URL` (superuser) and creates `thinktin_test_<uuidv7>`;
  - opens a 16-connection pool as that same superuser and calls `db.migrate()` (line 42);
  - drops the database `WITH (FORCE)` in `Drop` (47-71).
- Every database-backed test in every crate uses it (`store = { features = ["testing"] }` in ten Cargo.toml files).
- Roles are created by the 0001 and 0014 DO blocks running as superuser.
- **Consequences:**
  - Tables and definer functions are owned by a superuser, so FORCE RLS and definer functions reading FORCE tables are never exercised.
  - About 130 tests rely on raw superuser `db.pool()` queries (44 in store `tests.rs`, 26 in gateway `api.rs`, …). The test pool must stay superuser (or BYPASSRLS); only the migration connection should change.

**[verified]** With 0001 and 0014 changed to also catch `insufficient_privilege` (scratch copy only), all 38 migrations apply cleanly as a NOSUPERUSER NOBYPASSRLS NOCREATEROLE database owner. A stub `_sqlx_migrations` table is needed for 0016.

## 8. Existing tests that assert isolation

- **`tenants_are_isolated`** (`crates/store/src/tests.rs:92-210`):
  - another tenant gets `NotFound` on instances, routes, runs, rename and events;
  - a composite foreign key blocks referencing someone else's key and maps to `Invalid` (140-178);
  - an impersonating raw INSERT gets `Forbidden` (180-188);
  - `login_codes` gets `Forbidden` (189-196);
  - `users` shows only yourself (197-203);
  - the worker sees everything (205-209).
- **`outbox_delivers_once_and_retries`** (602-645): column-privilege `Forbidden`.
- **`every_tenant_table_the_app_can_touch_has_rls`** (761-816). Weak points:
  - only tables with a `user_id` column, so `projects.creator_id` would escape;
  - checks `relrowsecurity` but not `relforcerowsecurity`;
  - counts policies for any role, and does not reject quals that are just `true`.
- **`erasing_an_account_deletes_its_content`** (818+): the table list at 1070-1093 includes teams, team_members and team_templates. The erase SQL is at `users.rs:183-231` (`DELETE FROM teams` / `team_templates` at 211-212).
- **Gateway** (`crates/gateway/tests/api.rs`):
  - `teams_pipelines_and_artifacts` (1266): a team with a foreign instance returns 404 (1298-1308);
  - `other_users_objects_are_invisible` (1682): team and template routes return 404 (1890-1902), lists come back empty (1939-1960);
  - `instance_limit_over_http` (2581);
  - `team_adoption_is_all_or_nothing` (2657): two concurrent adopts give 201 plus 409, and nothing half-adopted remains.
- **Client FFI:** `ffi_teams_and_templates` (`crates/client-core/tests/client.rs:1641`).

## 9. The 8.13 code these changes touch

- **Store team methods:** all `Tx<Tenant>` (`crates/store/src/teams.rs:11-190`): `create_team`, `team`, `teams`, `update_team` (DELETE + reinsert), `delete_team`, and the template methods.
- **Atomic adoption** (`crates/gateway/src/routes/teams.rs:183-226`) happens in one `Tx<Tenant>`:
  - `lock_instance_count` (`instances.rs:259-270`, advisory lock `instances/<user>`);
  - `control::adopt_in` (`crates/control/src/lib.rs:214-224`, no commit);
  - `create_run_grant` per instance;
  - then `create_team` and commit.
  - So the single-user project rows must be writable by `thinktin_app` inside that same transaction. This contradicts design A's "no app writes; worker only". The plan (`projects-impl.md:10`) explicitly requires a restricted tenant write entry.
- **Other team readers:**
  - `delegation_targets` (`instances.rs:563-578`, tenant), used by `orchestrator/src/delegate.rs:46`;
  - `is_team_lead` (`instances.rs:581-589`, worker), used by `orchestrator/src/executor.rs:776`.
- **Routes:** `crates/gateway/src/routes/mod.rs:159-169`. **FFI:** `client-core/src/ffi.rs:818-915`, `:2594-2710`. **IDs:** `proto/src/domain.rs:44-68` has `TeamId` and `TeamTemplateId`; there is no `ProjectId` yet.

## 10. How to add `thinktin_member` and `ProjectTx` in this codebase's style

### Migration `0039_projects.sql`

1. **Roles.** Use the house DO-block idiom, but also catch `insufficient_privilege`; otherwise the non-superuser owner fails as shown above:
   ```sql
   DO $$ BEGIN CREATE ROLE thinktin_member NOLOGIN NOBYPASSRLS; EXCEPTION WHEN duplicate_object OR unique_violation OR insufficient_privilege THEN NULL; END $$;
   DO $$ BEGIN CREATE ROLE thinktin_definer NOLOGIN NOBYPASSRLS; EXCEPTION WHEN duplicate_object OR unique_violation OR insufficient_privilege THEN NULL; END $$;
   GRANT USAGE ON SCHEMA public TO thinktin_member, thinktin_definer;
   ```
   0001:16-18 and 0014:15 have the same defect. Editing them is acceptable only because no `v*` tag or deployed database exists. If a staging database exists, sqlx will report them as `modified`.

2. **Tables.** `projects`, `project_members`, `project_agents`, `project_invites`, `project_templates`, and the project key index. Each gets `ENABLE` + `FORCE ROW LEVEL SECURITY` and an explicit `GRANT … TO thinktin_worker`. Never use `ON ALL TABLES` for `thinktin_member`.

3. **Membership functions.**
   - SECURITY DEFINER, `LANGUAGE sql STABLE`, `SET search_path = pg_catalog, public, pg_temp`, fully qualified names (`public.project_members`).
   - No user-supplied parameters: they read `app.user_id` and `app.project_id` only.
   - They check live membership and project status. **[verified]** that this rejects a forged project setting and a deleted project:
   ```sql
   CREATE FUNCTION app_project_id() RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER
       SET search_path = pg_catalog, public, pg_temp
       AS $$ SELECT m.project_id FROM public.project_members m
               JOIN public.projects p ON p.id = m.project_id AND p.status IN ('active','archived')
              WHERE m.project_id = nullif(current_setting('app.project_id', true), '')::uuid
                AND m.user_id = public.app_user_id() AND m.left_at IS NULL $$;
   -- app_project_role() similarly
   GRANT CREATE ON SCHEMA public TO thinktin_definer;           -- ALTER … OWNER needs it [verified]
   ALTER FUNCTION app_project_id() OWNER TO thinktin_definer;   -- needs SET ROLE right on definer [verified]
   -- deploy-safe: only granted inside this migration for the owner change
   REVOKE CREATE ON SCHEMA public FROM thinktin_definer;
   REVOKE ALL ON FUNCTION app_project_id(), app_project_role() FROM PUBLIC;
   GRANT EXECUTE ON FUNCTION app_project_id(), app_project_role() TO thinktin_member;
   GRANT SELECT (project_id, user_id, role, left_at) ON project_members TO thinktin_definer;
   GRANT SELECT (id, status) ON projects TO thinktin_definer;
   CREATE POLICY definer_read ON project_members FOR SELECT TO thinktin_definer USING (true);
   CREATE POLICY definer_read ON projects FOR SELECT TO thinktin_definer USING (true);
   ```
   - **[verified]** A member policy on `project_members` that calls `app_project_id()` does not recurse into itself (no 42P17), because the function runs as `thinktin_definer` and hits `definer_read`.
   - The migration cannot grant itself membership in the definer role: without ADMIN it gets 42501 "Only roles with the ADMIN option…". **[verified]** So the deploy step below is required.

4. **Member policies and column grants.** Read-only. Wrap the function as `(SELECT …)` so it becomes an InitPlan evaluated once per statement:
   ```sql
   CREATE POLICY member_read ON projects FOR SELECT TO thinktin_member USING (id = (SELECT app_project_id()));
   CREATE POLICY member_read ON project_members FOR SELECT TO thinktin_member USING (project_id = (SELECT app_project_id()));
   GRANT SELECT (id, creator_id, name, goal, status, created_at) ON projects TO thinktin_member;
   GRANT SELECT (project_id, user_id, role, joined_at, left_at) ON project_members TO thinktin_member;  -- no budgets
   ```
   - Grant on the `events` parent only, never on partitions.
   - With no policy or grant on `runs`, the member gets `permission denied for table runs`. **[verified]**

5. **Tenant writes for single-user projects.** INSERT-only policies `TO thinktin_app`, in the style of design B's `create_solo` (`projects-design-B.md:255-280`):
   - `creator_id = app_user_id()`, `role = 'creator'`, the project is solo, and the instance's `user_id = app_user_id()`;
   - a SELECT policy for your own rows so `INSERT … RETURNING` works;
   - column-limited `GRANT INSERT`.
   - This keeps `adopt_template` atomic in its existing `Tx<Tenant>`.

6. **Backfill teams to projects.** Use the same ids so `TeamId == ProjectId`:
   - `ALTER TABLE <teams, team_members, team_templates, projects, project_members, project_agents> NO FORCE ROW LEVEL SECURITY;`
   - `INSERT … SELECT`;
   - a `DO` block that compares row counts and member/instance foreign keys and `RAISE EXCEPTION`s on mismatch;
   - `FORCE` again, all in the same file and transaction.
   - Without `NO FORCE` the copy silently moves 0 rows. **[verified]**

7. **Large-table indexes** (`runs(project_id …)` and similar) go in separate `-- no-transaction` files, one `CREATE INDEX CONCURRENTLY` per file.

### Deploy additions (`docs/deploy-checklist.md:59-71`, `docs/release.md:65-72`)

```sql
CREATE ROLE thinktin_member NOLOGIN NOBYPASSRLS;
CREATE ROLE thinktin_definer NOLOGIN NOBYPASSRLS;
GRANT thinktin_member TO thinktin_server_login;
GRANT thinktin_definer TO thinktin_owner WITH INHERIT FALSE, SET TRUE;
```

The `INHERIT FALSE` matters. **[verified]** With a plain `GRANT thinktin_definer TO thinktin_owner`, the `TO thinktin_definer` policies also apply to the owner. An owner-owned definer function then reads membership rows (the trap stays hidden), and the owner can read membership tables directly. With `INHERIT FALSE, SET TRUE`, `ALTER … OWNER` still works, the owner reads 0 rows, and an owner-owned copy of the function returns NULL.

Design A's `GRANT thinktin_definer TO CURRENT_USER` (in the migration) and plain checklist grant should be replaced with this.

### Rust: `ProjectTx` as its own type, not `Tx<Member>`

A separate struct means none of the generic `impl<R> Tx<R>` write and read helpers listed in section 2 compile against it. That is the plan's choice, taken from design B's section 2.2.

```rust
// lib.rs, next to Tx
/// 项目事务（8.15）：thinktin_member，只读；不是现任成员或项目不可读时返回 NotFound。
pub struct ProjectTx { tx: Transaction<'static, Postgres>, user: UserId, project: ProjectId, role: ProjectRole }

impl Db {
    pub async fn project(&self, user: UserId, project: ProjectId) -> Result<ProjectTx> {
        let mut tx = self.pool.begin().await?;
        sqlx::query("SELECT set_config('role', 'thinktin_member', true), set_config('app.user_id', $1, true), \
                     set_config('app.project_id', $2, true), set_config('statement_timeout', $3, true), \
                     set_config('transaction_read_only', 'on', true)")
            .bind(user.to_string()).bind(project.to_string()).bind(TENANT_STATEMENT_TIMEOUT)
            .execute(&mut *tx).await?;
        let role: Option<String> = sqlx::query_scalar("SELECT app_project_role()").fetch_one(&mut *tx).await?;
        let role = parse(&role.ok_or(Error::NotFound)?)?;   // dropping tx rolls back
        Ok(ProjectTx { tx, user, project, role })
    }
}
impl ProjectTx {
    fn conn(&mut self) -> &mut PgConnection { &mut self.tx }  // private, like Tx::conn
    pub fn role(&self) -> ProjectRole { self.role }
    pub async fn finish(self) -> Result<()> { self.tx.rollback().await?; Ok(()) }  // no commit
    // narrow reads only, each with an explicit `WHERE project_id = app_project_id()` and a
    // member_columns!() list: project_view, members, agents, … (no run()/events_after() reuse)
}
```

- **[verified]** `transaction_read_only = on` can be set inside that first `set_config` statement. Trying to turn it off later fails ("read-write mode must be set before any query"), and it also blocks `CREATE TEMP TABLE`.
- Add `ProjectId` and `ProjectTemplateId` to `id_type!` (`proto/src/domain.rs:44-68`), with `From<TeamId>`.
- In the gateway, map member-path `Forbidden` to 404 with a warn log. Today it returns 500.

### Tests

**Test-database setup.** Add a production-like owner to `TestDb::new`:
- On the admin connection, take `pg_advisory_lock` and then idempotently create the six service roles plus `thinktin_test_owner LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE`.
- Run `GRANT thinktin_definer TO thinktin_test_owner WITH INHERIT FALSE, SET TRUE`, then unlock.
- `CREATE DATABASE … OWNER thinktin_test_owner`.
- Run `migrate` over an owner-connected pool, but keep `TestDb.db` on the superuser pool so the ~130 raw `db.pool()` call sites keep working.

**Extend the RLS coverage test** (`tests.rs:761-816`):
- assert `relforcerowsecurity`;
- cover tables without `user_id`;
- require at least one policy per role (`TO thinktin_app` or `TO thinktin_member`) with no `'true'` quals;
- the member has no privileges on any `pg_inherits` child of `events`;
- every `prosecdef` function created from 0039 on is owned by `thinktin_definer`, has a `search_path` in `proconfig`, and has no PUBLIC EXECUTE in `proacl`;
- definer and member have `rolsuper` and `rolbypassrls` false;
- `pg_auth_members` for the definer role has no `inherit_option = true`.

**New tests:**
- A three-user matrix (creator, member, outsider, departed member) using the `tenants_are_isolated` style: raw SQL through `x.conn()` and `matches!(err, Error::Forbidden(_))`. Include a forged `app.project_id`.
- A `run_to(38)` → seed teams → `run()` backfill test as the owner, checking counts.
- Keep `team_adoption_is_all_or_nothing` (`api.rs:2657`) and `ffi_teams_and_templates` (`client.rs:1641`) green against project-backed teams.

## Map: scope

Read-only mapping done. I changed no files. All line references are to branch `claude/determined-lovelace-vn0j5h` at commit `be8afae`.

# Current keying, constraints, readers and writers, and where projects-impl.md "数据、身份与现有接口" items 1–4 land

## 0. Where the approved plan departs from design A (this decides 8.13's shape)
- **Migration numbering.** Design A plans `0031_projects.sql`/`0032_teams_to_projects.sql` (projects-design-A.md:67-68). Those numbers are taken: the branch has migrations up to `0038_browser.sql`. The next number is **0039**, as projects-impl.md:28 requires. The rules from release.md:37-55 apply: nullable column first, then backfill, then `SET NOT NULL` with a `-- deploy-safe:` comment; any `REVOKE` also needs `deploy-safe`; `CREATE INDEX CONCURRENTLY` goes in its own file starting with `-- no-transaction`. `tools/ci/check_migrations.py` enforces this (it looks for `deploy-safe:`, line 30). There are no `v*` tags yet.
- **The scope must be typed.** Item 1 (projects-impl.md:18) says ID collisions must not cross the private/project type. Design A's untyped `scope_id = coalesce(project_id, user_id)` (A:192, A:260) does not satisfy this on its own. Store a kind column too, e.g. `scope_kind IN ('private','project')`, with a CHECK tying `(scope_kind, scope_id)` to `(user_id, project_id)`, and put `(id, scope_kind, scope_id)` in the UNIQUE/FK keys.
- **Approvals and events keep their old FK.** Item 1 keeps `(run_id,user_id)` and adds a scope-consistency constraint. Design A replaces it with `(run_id, scope_id)` (A:199-200).
- **Solo-project creation runs inside the tenant transaction.** projects-impl.md:11 says the restricted write entry for single-user projects must reuse the existing tenant transaction. Design A instead routes `POST /v1/teams` through `Tx<Worker>::create_project` and gives `thinktin_app` no write access to project tables (A:103, A:141). Today adoption is a single `Tx<Tenant>`: gateway/src/routes/teams.rs:191 opens it, then 195 `lock_instance_count`, 200-210 `control::adopt_in` (control/src/lib.rs:216-223, no commit), 211 `create_run_grant`, 223 `create_team`, 224 commit. The test `team_adoption_is_all_or_nothing` (gateway/tests/api.rs:2657) depends on this. So solo-project creation needs a narrow tenant-callable entry, such as a SECURITY DEFINER function or creator-only INSERT policies.
- **The name `scope` is already used.** It is a column, `run_grants.scope jsonb` (0001_init.sql:164, holding `GrantScope` from proto domain.rs:407-433), and a type, `store::ArtifactScope` (artifacts.rs:87-96, the ask-based artifact visibility). The new typed columns need different names.

## 1. Roles and transactions today
- `Db::tenant` sets the role and `app.user_id` with `set_config('role','thinktin_app',true)` (store/src/lib.rs:123-137). `Db::worker` is `thinktin_worker`, which bypasses RLS (140-149). `Db::llmgw` is at 152-161, `Db::relay` at 165-174. There is no member role and no scope GUC.
- Every tenant table has a policy `tenant ... USING (user_id = app_user_id()) WITH CHECK (same)` plus FORCE. For runs, events, approvals, inbox_items, run_grants, plans and usage_records the loop is at 0001:427-438; for artifacts, teams, team_members, team_templates and plan_steps it is at 0002:95-105.
- Tenant table grants are table-wide, so a new column becomes tenant-writable automatically:
  - `SELECT, INSERT, UPDATE ON ... plans, triggers, runs, approvals, inbox_items` (0001:466)
  - full DML on `run_grants` (0001:468)
  - `DELETE` on `inbox_items` (0001:469)
  - `SELECT, INSERT ON events` (0001:470)
  - `SELECT ON usage_records` (0001:471)
  - `SELECT, DELETE ON artifacts` (0002:109)
  - Precedent for narrowing to column grants: `instances` (0023:24-27, which also grants `UPDATE(event_seq, token_epoch)`).
- The worker's `ON ALL TABLES` grant (0001:477) covers only tables that existed then; new tables need explicit grants, as in 0002:110.
- Store error mapping (store/src/error.rs:46-52): 23505 → `Conflict`, 23503 → `Invalid`, 23514 → `Invalid`, 42501 → `Forbidden`. The gateway turns `Forbidden` into a 500 (gateway/src/error.rs:66-79, via the `other` arm).
- Existing SECURITY DEFINER functions use `SET search_path = public`, not the `pg_catalog, public, pg_temp` that item 2 wants:
  - `ensure_event_partitions` and `drop_event_partitions_before` (0001:286-319; PUBLIC execute revoked at 478)
  - `queue_artifact_blob_purge` (0007:40-46)
  - `queue_workspace_archive_purge` (0023:32-58)
- Tests migrate as the `DATABASE_URL` user (store/src/testing.rs:26-42), which is a SUPERUSER (tools/dev/setup-db.sh:17). Production's owner is a plain LOGIN role (deploy-checklist.md:57) and FORCE applies to it (0001:426). No test runs as a non-superuser owner today.
- Roles are created race-tolerantly with `DO $$ BEGIN CREATE ROLE … EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $$` (0001:16-18, 0014:15).
- The RLS coverage test `every_tenant_table_the_app_can_touch_has_rls` (store/src/tests.rs:763-817) only considers tables with a `user_id` column (line 773). Project tables keyed by `project_id` would escape it.

## 2. Table by table

### runs (0001:217-267, plus later columns)
- **Keys.**
  - `PRIMARY KEY id`; `UNIQUE (id,user_id)` (248). Every run-referencing table points at this.
  - FKs:
    - `(instance_id,user_id)→instances` CASCADE (249)
    - `(plan_id,user_id)→plans` SET NULL(plan_id) (250)
    - `(trigger_id,user_id)→triggers` SET NULL (251)
    - **`(parent_run_id,user_id)→runs(id,user_id)` ON DELETE CASCADE** (252)
    - `(run_grant_id,user_id)→run_grants` SET NULL(run_grant_id) (253)
  - No FK on `root_run_id` (225), `interrupts_run_id` (0027:6), `hook_id` (0030:28) or `step_key`.
- **Uniques.** `runs_plan_fire (plan_id,fire_time)` (0001:256); `runs_step (parent_run_id,step_key)` (0002:45); `runs_one_active_per_instance (instance_id) WHERE kind='agent' AND busy states` (0002:48-51). That last one is the basis of `instance_usage_since`.
- **Indexes.** `runs_claim` (0010:5-7); `runs_tree(root_run_id)` (0001:263); `runs_parent` (0011:3); `runs_user_active`, `runs_plan`, `runs_user_recent` (0020:13-15; `list_runs` must match these predicates exactly); `runs_answer_due` (0026:12); `runs_interrupts` (0027:7); `runs_urgent_queued` (0029:8); `runs_hook` (0030:29).
- **Other roles.** relay has column SELECT and `UPDATE(not_before, updated_at)` (0014:92); llmgw has `SELECT(id,user_id,instance_id,kind,state)` (0034:49).
- **Insert.** `insert_run` (runs.rs:267-315) takes `user` from the caller and copies `root_run_id` from the parent with a plain `SELECT root_run_id FROM runs WHERE id=$1` (269-280; under tenant RLS this only sees the caller's own runs). The `INSERT` column list is at 282-286.
  - Tenant entry points: `Tx<Tenant>::create_run` (451-457), `queue_urgent_run` (602-704).
  - Worker entry point: `Tx<Worker>::create_run(user,…)` (853-855).
  - `NewRun.parent_run_id` is public (32). The tenant path does not stop a tenant passing a parent; only the composite FK keeps it to the same user.
- **Who creates runs.**
  - gateway/routes/runs.rs:46 and :48 (tenant)
  - gateway/routes/vault.rs:431 (tenant)
  - gateway/routes/hooks.rs:323 (worker, `target.user_id`)
  - orchestrator/scheduler.rs:184 (worker, `d.user_id`)
  - delegate.rs:169-173, ask.rs:157, pipeline.rs:262 (worker; child `user_id` = parent's user)
- **Tenant reads that rely only on RLS**, with no `user_id` predicate: `run` (317-323), `run_tree` (326-336), `runs(instance)` (460-478), `instance_holder` (730-741), `last_finished_run` (744-755), `run_budget` (758-764), `run_event_count` (767-775).
  - Only `list_runs` filters `user_id = app_user_id()` explicitly (493). `wake_waiting_runs` uses `user_id=$1` (818).
- **Tenant writes.** `cancel_run` (522-552); `cancel_run_tree` by `root_run_id` (557-580); `cancel_asks_to` (584-597) → `cancel_asks` (386-421); urgent-message cancel and `mark_interrupt` (669-694, 708-727); `cancel_instance_runs` (779-810). The epoch bump is a macro `bump_epochs_where!` (341-351) that updates `instances.token_epoch`.
- **Worker tree/claim functions** (none of them check scope):
  - claiming and leases: `claim_next_run` (872-947), `take_over_expired` (987-1009), `claim_expired_waits` (1284-1307), `due_pipelines` (1423-1436). These filter only by `source = ANY(known_sources())` (203-205), the existing mechanism that lets old replicas skip rows they cannot handle.
  - cancellation: `cancel_user_runs` (831-850), `cancel_descendants` (1013-1045), `cancel_children` (1503-1522), `cancel_stale_asks` (1254-1281)
  - tree and child queries: `tree_tokens_except` (1048-1057), `delegated_runs`, `ask_runs`, `unreported_children` (1060-1120), `run_chain` (1156-1171), `instance_waits_for` (1227-1249), `child_runs` (1453-1463)
- **Locks.** `lock_run_waits` takes an advisory lock on `run_waits/{user}` (428-434). `queue_urgent_run` locks `interrupts/{instance}` (605-608). Both are per user or per instance; nothing is per project.

### run_grants (0001:158-174)
- **Keys.** `UNIQUE (id,user_id)` (170); `(instance_id,user_id)→instances` CASCADE (171); `(parent_id,user_id)→run_grants` CASCADE (172). `plan_id` has no FK (grants.rs:76 says so). Index `run_grants_instance` (174).
- **Scope JSON.** `GrantScope{aliases, platform_tools, max_tokens}` (domain.rs:407-415). `contains` (418-433) is checked only when a child grant is created. `max_tokens` is not enforced at runtime anywhere.
- **Tenant functions.**
  - `create_run_grant` (grants.rs:67-83). Callers: gateway/teams.rs:211, instances.rs:52, runs.rs:80, plans.rs:182/426, auth/grants.rs:75.
  - `create_plan_child_grant` (87-120, checks `ancestors_usable!`); caller orchestrator/tools.rs:251.
  - `plan_grant` (123-133); `run_grants(instance)` (136-147, RLS only).
- **Generic functions.** `revoke_run_grant`, `revoke_plan_grants`, `revoke_instance_grants` (179-229). They recurse via `parent_id` only.
- **Worker functions.**
  - `run_grant` (233-243)
  - **`create_child_grant` (246-275) checks only the direct parent's `is_active`** (254-258, domain.rs:501-503), not its ancestors.
  - `touch_run_grant` (279-300, uses `ancestors_usable!`)
  - **`active_grant_for_instance`** (303-315: `parent_id IS NULL AND plan_id IS NULL`)
  - `revoke_user_grants` (318-328)
- **`ancestors_usable!`** (47-55) walks `parent_id` only. It is shared with llmgw `usable_grant_aliases` (store/llmgw.rs:116-132).
- **Lookups that would wrongly pick up a future top-level project grant** (item 3: private grant lookups must explicitly exclude project grants):
  - `active_grant_for_instance` (grants.rs:303-315), used at executor.rs:745-752 when `run_grant_id` is NULL (ask children always are, ask.rs:151) and at ask.rs:131-141
  - `ensure_instance_grant` (gateway runs.rs:67-91), predicate `plan_id.is_none() && parent_id.is_none()` (77)
  - the platform-tool backfill migrations, all `WHERE parent_id IS NULL AND revoked_at IS NULL`: 0024:13-18, 0025:43-48, 0026:16-21, 0036:22-27, 0038:20-25
- **Sandbox token.** `GrantService::sandbox_token` (auth/grants.rs:107-169) requires `g.instance_id == instance && user == rt.user_id` (123-127). It puts `ep` (token_epoch), `uid` and `grant` in the token (150-157). llm-gw caches grant validity in a TtlMap (llm-gw/src/pg.rs:68, 161-170, 218-230) and reads the epoch from `gateway_instance` (store/llmgw.rs:51, pg.rs:96).

### approvals (0001:323-345)
- **Keys.** PK `id`; **`UNIQUE (run_id, request_id)`** (340); `(instance_id,user_id)` CASCADE (341); **`(run_id,user_id)→runs` CASCADE** (342). There is no `UNIQUE(id,user_id)`. `request_id` is `approval_key(attempt, shim_id)` (approvals.rs:38-40). Index `approvals_pending (user_id,created_at)` (344).
- **Worker writes.** `create_approval` (approvals.rs:101-119), called only at executor.rs:2128-2162 with `user: rec.user_id` (the owner) and followed by `notify(rec.user_id)`. Also `approval_for_request` (121-136), `settle_approval` (140-169, which also marks inbox read), `approval_pending` (172-180), `cancel_run_approvals` (183-201; called at executor.rs:1053, 1171).
- **Tenant side.** `pending_approvals` (206-217) and `approval` (220-230) rely on RLS only. `decide_approval` (233-285) updates and settles inbox; it is called from gateway/routes/approvals.rs:45, which then does a tenant `append_event` (46).
- **Leak surface.** `runs.state_reason` is set to the approval title on `WaitingApproval` (executor.rs:2176). The `agent.permission_requested` event stores the raw request (2171-2172).

### artifacts (0002:73-91)
- **Keys.** `UNIQUE (root_run_id,name,version)` (86); `(instance_id,user_id)` CASCADE (87); `(run_id,user_id)→runs` CASCADE (88). `root_run_id` has no FK. It is not necessarily the tree root: it is `ArtifactScope.own`, which is the nearest ask run or the tree root (artifacts.rs:174-200; set at orchestrator/tools.rs:493-501).
- **Triggers and indexes.** Blob purge trigger `artifacts_blob_purge` (0007:40-48); index `artifacts_run` (0007:26).
- **Worker insert.** `insert_artifact` (artifacts.rs:119-156): advisory lock `artifact:{root}:{name}`, cap `MAX_TREE_ARTIFACTS=1000`. Only caller: orchestrator/artifacts.rs:306.
- **Generic reads**, by role: `artifact` (161-171), `artifact_scope` (174-200), `tree_artifacts` (204-226), `named_artifact` (229-250), `scoped_artifact` (253-263), `run_artifacts` (269-280).
  - worker callers: tools.rs:492-493, 563-564, 593-594, 609-611; pipeline.rs:247, 461
  - tenant callers: peers.rs:116; gateway artifacts.rs:53, 71, 102
- **Tenant only.** `instance_artifacts` (285-302), `delete_artifact` (305-312).
- **Encryption.** Content is sealed with the owner's DEK (orchestrator/artifacts.rs:342-345).

### events and the event stream (0001:271-319)
- **Table.** Partitioned by month; `PRIMARY KEY (instance_id, seq, created_at)` (279); `(instance_id,user_id)` CASCADE (280); **`(run_id,user_id)→runs` CASCADE** (281); index `events_run(run_id,seq)` (283). Partitions are created by a SECURITY DEFINER function (286-299) and have no RLS of their own.
- **Sequencing.** `append_event` (events.rs:40-73), generic over role: `UPDATE instances SET event_seq=event_seq+1 ... RETURNING event_seq,user_id` (47-52) locks the instance row until commit. The event's `user_id` is the instance owner. After the INSERT (53-65) it calls `pg_notify('thinktin_events', instance_id)` (67-71). The gateway hub parses the payload as an `InstanceId` (hub.rs:82).
- **Reads.** `events_after` (76-92), `event_range` (96-110; `oldest = min(seq)` under RLS, `latest` from the instance row) and `recent_run_events` (116-134) all rely on RLS only. Gateway: routes/events.rs:49-51, 64-68, 95-97, 139-142. `content_reports.event_seq` refers to `(instance, seq)` and has no FK (0019:7-11).
- **Tenant inserts.** gateway runs.rs:51, :201, :212 and approvals.rs:46. Everything else inserts as worker.
- **Outbox.** It carries only notifications (0001:350-366): `user_id NOT NULL` with no FK, `UNIQUE (user_id,dedupe_key)` partial (365), and tenant may only append its own rows (457-459, 473-474). Store functions: `insert` (store/outbox.rs:47-61), `Tx<Tenant>::enqueue_outbox` (86-89), worker `enqueue_outbox` (105-107), `claim_outbox_of` with a kinds filter so old versions skip unknown kinds (143-180). There is no event outbox and no sequencer. `project_seq` and the project feed belong to item 6 / 8.19, not items 1–4.

### inbox_items (0001:368-382, 0003, 0005, 0021, 0035)
- **Keys.** `(instance_id,user_id)` CASCADE; **`(run_id,user_id)→runs` SET NULL(run_id)** (378-379); `(plan_id,user_id)→plans` SET NULL (0003:8); `UNIQUE (user_id,dedupe_key)` partial (0003:10). `approval_id`, `vault_request_id` and `egress_request_id` have no FKs.
- **Writes.** `insert_inbox` (inbox.rs:94-129) is generic; it is reached via `orchestrator::outbox::notify` (worker, orchestrator/outbox.rs:200-217) and `notify_tenant` (220-238).
- **Tenant reads**, all RLS only: `inbox` (182-201), `inbox_item` (203-213), `inbox_unread` (215-221). Tenant also has `mark_inbox_read` and `mark_inbox_unread` (225-262) and `delete_inbox_item` (264-273).
- **Consequence.** The FK forces the recipient to be the run's owner. A future "project task done → notify creator" item for another owner's run would be rejected.

### usage and budgets
- **`usage_records`** (0001:386-410; 0037:3) has **no FKs**: `user_id`, `instance_id`, `run_grant_id`, `credential_id`. It has no `run_id` and no `project_id`. Indexes: user/time, instance/time, credential/time (408-410). It is inserted only by Internal roles via `insert_usage` (usage.rs:35-66; llm-gw pg.rs:333-338, 365). Tenant reads it via `usage_summary` (usage.rs:110-160).
- **Per-run budget.** `runs.budget` holds `RunBudget{max_tokens, max_duration_secs, max_steps}` (domain.rs:355-369). Executor `on_renew` (executor.rs:2380-2425) compares `instance_usage_since` (runs.rs:1393-1407; correct only because of the one-active-run index) plus **`tree_tokens_except(root)`** (runs.rs:1048-1057, which sums the whole tree regardless of owner) against `rec.budget.max_tokens`.
- **Children copy the parent budget.** delegate.rs:168, ask.rs:153, pipeline.rs:261.
- **Per-key daily budget** in llm-gw: `PgLedger` (llm-gw/src/pg.rs:411+) with `credential_tokens_since` (store/llmgw.rs:135-149). The plan's `daily_token_limit` is enforced only for webhooks (gateway hooks.rs:300-307).
- **Retry idempotency.** `tool_calls` (0012:3-16) has a **single-column** FK `run_id→runs(id)` and `PK (run_id,key)`; it is worker-only (tool_calls.rs:10-41). Approval keys include the attempt number.

### Other private tables that reference runs through `(run_id,user_id)`
- `board_posts` SET NULL (0025:22; insert at store/board.rs:142)
- `vault_requests` SET NULL (0009:38; vault.rs:296)
- `device_calls` SET NULL (0014:46; device_relay.rs:446)
- `egress_requests` SET NULL (0034:26; egress.rs:425)
- `live_activities` CASCADE (0018:37; live_activities.rs:198, 298)
- `content_reports.run_id` has no FK (0019:9)

### teams (0002:5-37)
- **Tables.** `teams UNIQUE(id,user_id)`. `team_members` has `PK(team_id,instance_id)`, FKs `(team_id,user_id)` and `(instance_id,user_id)` CASCADE, and **`team_one_lead (team_id) WHERE role='lead'`** (27). That index also counts soft-deleted instances; `team()` filters them out at teams.rs:52. `team_templates UNIQUE(id,user_id)`.
- **Store.** Tenant only, all in store/teams.rs: `create_team` (13-22, uses `app_user_id()`), `insert_members` (24-42), `team` (44-74), `teams` (76-85), `update_team` (88-112, delete-all then reinsert), `delete_team` (114-123), templates (125-189).
- **Delegation scope reads `team_members`.** `delegation_targets` (instances.rs:564-577, tenant) and `is_team_lead` (582-589, worker), called from delegate.rs:44-49 and executor.rs:771-776.
- **Routes.** gateway routes/mod.rs:159-169 and routes/teams.rs. Client side: client-core api.rs:1729-1816, FFI ffi.rs:818-923 (records) and 2594-2706 (10 methods).
- **Tests to keep passing.** gateway api.rs:1266 (`teams_pipelines_and_artifacts`), 1682 (`other_users_objects_are_invisible`), 2657 (atomic adoption); client-core tests/client.rs:1641; orchestrator tests/executor.rs:2001-2330 (delegation, team helper at 2215).

## 3. Parent/child (delegation) paths
- **delegate** (orchestrator/delegate.rs:75-189), as worker:
  - checks: `lock_run_waits(ctx.user)` (101), `run_chain` (103), `instance_waits_for` (120)
  - **grant:** `create_child_grant(ctx.grant, target.id, parent scope)` (137-143)
  - **run fields:** `plan_id` copied from the parent (164), `parent_run_id` (165), the child grant (166), the budget (168)
  - `create_run(ctx.user)` (169-173), then `append_event` on the lead's instance (174-181)
- **ask** (ask.rs:54-174):
  - tenant `peers` (65-69)
  - worker lock (84) and acceptance check (86)
  - `active_grant_for_instance` (131-141)
  - **run fields:** `plan_id = None` (150), `run_grant_id = None` (151), budget copied (153)
  - `create_run(ctx.user)` (157)
- **pipeline** (`start_step`, pipeline.rs:209-272):
  - child grant from `root.run_grant_id` (227-245)
  - `run_artifacts(deps)` (247)
  - plan, parent and budget copied (257-261)
  - `create_run(root.user_id)` (262)
  - Handoff copy reads sibling artifacts as worker (438-479).
- **Executor uses of the parent link:**
  - interrupt preface reads the interrupted run (executor.rs:787-800)
  - tenant lookup of child instance names (809-819)
  - failure propagation via `cancel_descendants` (1164-1166)
  - `ToolContext{user,instance,run,plan,grant}` (shim.rs:68-75, built at executor.rs:958-964) has **no scope field**.
- **Account erase** (users.rs:182-230): `DELETE FROM runs WHERE user_id=$1` (200) cascades children through the 0001:252 FK. Stop-all (orchestrator/account.rs:90-112) calls `cancel_user_runs` and `revoke_user_grants`.

## 4. Where `project_id` and the typed scope go, and which constraints change (items 1–4)

**Item 1: schema**
- **New tables:** projects, members, agents, invites, plus the project key index.
  - The agents table needs `UNIQUE(project_id,instance_id,user_id)` and `FK (instance_id,user_id)→instances`.
  - Keep ids so that `TeamId == ProjectId`.
  - Add a solo-project backfill from teams, team_members and team_templates. This must temporarily lift FORCE on teams, team_members, team_templates and instances, verify row counts, and restore FORCE.
- **runs** keep `user_id` as the owner. Add:
  - `project_id NULL`, `scope_kind`, `scope_id`
  - a CHECK linking kind, `scope_id`, `user_id` and `project_id`
  - `UNIQUE(id, scope_kind, scope_id)` (keep `UNIQUE(id,user_id)`, since everything references it)
  - **replace the 0001:252 parent FK** with `(parent_run_id, scope_kind, scope_id)→runs`
  - `FK (project_id,instance_id,user_id)→project_agents`
  - **add** `(run_grant_id, scope_kind, scope_id)→run_grants`, so a private run cannot use a project grant
  - Derive `project_id` from the parent; make `project_id`, `user_id` and `instance_id` immutable on UPDATE.
- **Parent FK delete action.** The plan's account-erase rule (item 7) says cross-owner children are detached, so the scope-based parent FK needs a deliberate action, e.g. `SET NULL (parent_run_id)`. The current one is CASCADE.
- **run_grants:** same new columns plus `UNIQUE(id,kind,scope)`. Keep `(parent_id,user_id)` and add `(parent_id,kind,scope)`. Add the project-agent FK.
- **plans:** their FK `(run_grant_id,user_id)` (0001:193) should also force private plans to private grants.
- **approvals and events:** keep 0001:340-342 and 0001:281. Add project/scope columns filled by trigger from `runs`, plus an FK `(run_id, scope_kind, scope_id)→runs`. A partitioned `events` can carry this; runs needs the matching unique. Events with `run_id` NULL are private only.
  - The derive trigger must not depend on tenant RLS visibility. If the trigger cannot see the run, the FK will reject the row, which is the safe failure.
- **artifacts:** keep `(run_id,user_id)` and require a private scope, or move project artifacts to a separate table keyed by `project_id` with an FK to `runs(id,'project',project_id)`.
  - `board_posts` and `vault_requests` should also be restricted to private runs.
  - `device_calls`, `egress_requests` and `live_activities` stay owner-keyed.
- **inbox_items** stay private per recipient. The `(run_id,user_id)` FK (0001:379) must change before cross-owner project notifications are possible.

**Item 2: tenant reads**
- The tenant policies at 0001:427-438 and 0002:95-105 must be narrowed for rows with `project_id`: allow them only to a live member of an active project, and never in a private-tool transaction.
- Every RLS-only tenant read listed in §2 inherits this narrowing.
- These private-tool tenant transactions need a private-scope variant:
  - ask.rs:65
  - board.rs:59, 90
  - delegate.rs:45
  - peers.rs:47, 92
  - tools.rs:199, 225, 278, 313
  - vault.rs:46, 111
  - executor.rs:809
- Worker reads that feed agents need explicit scope parameters: tools.rs:492-611, pipeline.rs:247, 448-461, delegate.rs:58-60, executor.rs:930-932.

**Item 3: who may write project rows**
- Today a tenant can INSERT or UPDATE any column of runs, run_grants, approvals and inbox_items (0001:466-469). It can also set `parent_run_id` through `Tx<Tenant>::create_run` (runs.rs:451-457).
- This needs a guard that rejects `project_id IS NOT NULL` when `current_user = thinktin_app`. It has to be a SECURITY INVOKER trigger, because the role is set with `set_config('role')`. Alternatively, revoke and re-grant column privileges as 0023 did for instances.
- `ancestors_usable!` (grants.rs:47-55) and `create_child_grant` (246-275) must also check the project and ancestor chain.
- The per-user locks (runs.rs:428-434) need project → member → instance ordering.

**Item 4: budgets and spend**
- `usage_records` needs a project attribution: either `project_id`, or derive it from `run_grant_id` (which has no FK).
- Add a reservation per (project, owner), following `PgLedger` (pg.rs:411+).
- `tree_tokens_except` (runs.rs:1048-1057) must sum per owner.
- Cross-owner children must not copy the parent's `RunBudget` (delegate.rs:168, ask.rs:153, pipeline.rs:261).
- llm-gw must re-check the grant and the epoch: `usable_grant_aliases` (store/llmgw.rs:116-132), whose TtlMap cache keeps a revoked grant usable for up to `cache_secs`, and `token_epoch` (llmgw.rs:51).
- Approvals already go only to `rec.user_id` (executor.rs:2128-2162).

**8.13 compatibility**
- Runs can stay private (`project_id` NULL) through 8.13; projects-impl.md:29 gates executable project tasks.
- `delegation_targets` and `is_team_lead` switch to `project_agents` only after the old-client and rollback tests pass (projects-impl.md:28).
- `every_tenant_table_the_app_can_touch_has_rls` needs widening to tables that have no `user_id`.

## Map: workspace

# Instance sessions and workspaces today, what 8.16 needs, and what 8.13 must prepare

**Summary:** today every instance has one sandbox, one agent HOME, one working directory and one saved agent session. Every run on an instance continues that same conversation: user chat, plan runs, delegated children, ask answers and pipeline steps. 8.16 can split this per (instance, project) using shim flags that every template already has, plus a new archive table. 8.13 only has to put four things in the database: `project_agents` (with `dedicated`), `runs.project_id`, `run_grants.project_id`, and a guard on run claiming.

## 1. How it works today

### Sandbox layout
- Default root is `/sandbox` (envd.rs:351-375, cube.rs:7-8). The working directory defaults to `<root>/workspace` (envd.rs:364) and the process HOME to `<root>/home` (envd.rs:370).
- Local backend: `sandboxes/<id>/workspace` is a symlink to `volumes/<workspace_id>` (local.rs:3-6, 189-199); HOME is `sandboxes/<id>/home` (local.rs:289).
- Template image: one Unix user, uid 1001 `user`, with HOME `/sandbox/home` and workspace `/sandbox/workspace` (deploy/templates/Dockerfile:34-38, 126-130).
- The **agent-shim binary is baked into each template image** (Dockerfile:39). Instances pin `agent_version`, so old instances keep running old shims.
- `ExecSpec` has only argv, env and cwd (sandbox lib.rs:115-121). `check_relative_path` (lib.rs:233-244) is the only path guard.
- `instances.workspace_id` (0001_init.sql:126) is set to `ws-<uuidv7>` at adoption (control lib.rs:274). It becomes `CreateSpec.workspace` (control lib.rs:1006-1008): a Cube volume, a local volume, or a component of the ACS archive key.

### Launch path and session choice
- `Executor::start` (executor.rs:723-990) wakes the sandbox (729-740) and picks the grant from `run_grant_id`, else from `active_grant_for_instance` (744-752).
- It builds `ShimLaunch` (863-872). `ShimLaunch` (shim.rs:16-30) has no scope, session or cwd field. Nor does `ToolContext` (shim.rs:68-75), nor `RunRecord` (runs.rs:126-144, `columns!()` runs.rs:192-199).
- `ExecConnector::start` starts a **new `agent-shim serve` for every attempt** (exec.rs:163-283):
  - process cwd is `workdir = "workspace"` (exec.rs:89, 206);
  - argv is `--home .thinktin/home --cwd .` (exec.rs:115-119);
  - the tool list is written to `workspace/.thinktin/platform-tools.json` (exec.rs:170-184).
- The executor sends `Shutdown` at the end of each run (executor.rs:1676-1686).
- The shim canonicalizes and creates both directories (main.rs:158-173). The agent HOME is therefore `/sandbox/workspace/.thinktin/home`, inside the cwd and on the workspace volume. `/sandbox/home` is not used, because `config::render` sets HOME itself (config.rs:142).
- Per-agent state directories, all under that HOME:

  | Agent | Setting | Location |
  |---|---|---|
  | Claude | `CLAUDE_CONFIG_DIR` | config.rs:181-182 |
  | Codex | `CODEX_HOME` | config.rs:214-215 |
  | Pi | `.pi/agent` | config.rs:270 |
  | OpenClaw | `OPENCLAW_STATE_DIR`, and `agents.defaults.workspace = cwd` | config.rs:307-311, 346 |
  | Hermes | `HERMES_HOME` | config.rs:383-384 |

  The manifests declare `runtime.state_dirs` (manifest.rs:76), but nothing in the code uses it.
- Saved session:
  - one file, `HOME/.thinktin/shim-session.json`, holding `{agent_id, harness, cwd, session_id}` (state.rs:9-18);
  - `previous_session` uses it only if agent id, harness and canonical cwd all match (shim.rs:268-272);
  - it is overwritten after every handshake (shim.rs:237, 274-284).
- How each harness resumes:
  - ACP uses `session/load` or resume, else falls back to `session/new` and emits `SessionLost` (acp.rs:95-139, shim.rs:231-236).
  - Claude CLI uses `--resume` or `--session-id` (claude_cli.rs:43-60, 101-110).
  - OpenClaw has `restore = false` and a hard-coded key `--session agent:main:thinktin`, with history kept in the state directory (openclaw.toml:24-27).
- **No agent session id is stored in the database.** The executor only sees `session_restored` (executor.rs:904-910). It uses that for the resume brief (928-951) and the announced/interrupted preface (1689-1726).
- Per-HOME helpers:
  - bridge socket `HOME/.thinktin/platform-tools.sock` (main.rs:474-479, bridge.rs:104-134), falling back to a temp directory at 100 bytes or more (bridge.rs:519-520);
  - `thinktin-vault` binary in `HOME/.thinktin/bin` (main.rs:500-509);
  - browser output in `cwd/.thinktin/browser`, profile in the shared temp directory (browser/launch.rs:54-55);
  - `TMPDIR` is inherited, so `/tmp` is shared (process.rs:28).
- Concurrency: one active agent run per instance (`runs_one_active_per_instance`, 0002_collaboration.sql:48-51; claim_next_run runs.rs:878-896). The index includes `waiting_children`, `waiting_approval`, `waiting_quota`, `waiting_device` and `backoff`, so waiting runs also block other runs on the instance.

### Platform file I/O (one fixed workdir)
- `ArtifactTools::workspace_path` is `workspace/<rel>` (tools.rs:508-511). It is used by publish reads (tools.rs:519-533) and by fetch, whose default is `handoff/<name>` (tools.rs:639-660).
- `HandoffCopier` writes `workspace/handoff/<name>` (pipeline.rs:469).
- Both are wired from `exec_cfg.workdir` (server/src/workers.rs:137-154, 206-210).

### Workspace archives (backends without volumes, i.e. ACS)
- Packing: `tar --create --gzip --file=- .` over the whole workspace, which includes `.thinktin/home` (control workspace.rs:80-87, export at lib.rs:1749-1805).
- Unpacking: the archive is uploaded to `workspace/.thinktin/restore.tgz` and extracted into the workspace root (workspace.rs:77, 90-98; restore_into lib.rs:1808-1838; run_in_sandbox lib.rs:1841-1870).
- Object key: `workspaces/<user>/<workspace_id>/<archive_id>` (workspace.rs:40-42), with an owner check (orchestrator workspaces.rs:186-193).
- Encryption: sealed in chunks with the **instance owner's user DEK** (workspaces.rs:224-294). The AAD domain is `thinktin/workspace/v1/` plus user id and archive id (keyvault lib.rs:625-640, 777-784).
- Metadata is one set of columns on `instances` (0023_workspace_archives.sql:3-21). The purge trigger only queues keys under `workspaces/<user>/` (0023:31-61).
- Cube and local volumes and snapshots copy the whole workspace, without per-project encryption (local.rs:341-370).
- "Restore the last archive" also happens when a sandbox disappears unexpectedly (docs/sandbox-acs.md:98). Only the workspace is saved (sandbox-acs.md:111).

## 2. What 8.16 would need

**Scope.** Add `Scope::{Private, Project(id)}`, taken from `runs.project_id` (never from the agent), to `RunRecord`, `ShimLaunch` and `ToolContext`. Delegated, ask and pipeline children inherit the parent's scope.

**Layout.** Project directories go beside the private ones, not inside them:

| Scope | cwd | HOME |
|---|---|---|
| Private | `private/` (moved out of `.`) | `.thinktin/home` (unchanged) |
| Project | `projects/<k>` | `.thinktin/h/<k>` |

- `k` is `p` + 32 hex characters.
- Pass these through the **existing** `--home`/`--cwd` flags (exec.rs:115-119). Those flags and the per-HOME `shim-session.json` have existed since the first shim (eaebe65, 2026-10-13) and the first in-sandbox launch (2f2c344), so every template's baked shim accepts them.
- A separate HOME per scope automatically separates the session file, every agent's state directory, the vault binary and the socket. The socket path is 94 bytes, under the 100-byte limit.
- One correction to design A §6.2: the new `--session-key` flag and the OpenClaw `{session_key}` placeholder are **unnecessary** when each scope has its own HOME, because `OPENCLAW_STATE_DIR` sits under HOME (config.rs:307). Avoiding a new flag also avoids crashing old shims. exec.rs:193 already routes new options through environment variables for this reason.
- The one-time move of private files into `private/` should be done orchestrator-side through `provider.exec`, not inside the shim, because old template shims won't have the code. There is no production data, so losing a dev session once is acceptable.
- Why the private cwd must move: Claude reads `CLAUDE.md` from parent directories, so a project cwd nested under the private cwd would pick up private instructions.

**Paths.** `ArtifactTools::workspace_path`, the fetch default and `HandoffCopier` must prefix the scope cwd (tools.rs:508-511, 639-646; pipeline.rs:469).

**Cross-scope leaks in today's code that must be fixed:**
- The piggyback of new messages is not scoped: `unannounced_messages(instance)` (runs.rs:1194-1210) feeds `Executor::new_messages` (executor.rs:1504-1535). A private user message would land in a project session, and vice versa. Filter it by `project_id`.
- The "already announced" preface (executor.rs:800, 1696) only holds within the same scope.
- The interrupted preface quotes the other run's title (executor.rs:787-797). Suppress it across scopes.
- `active_grant_for_instance` (grants.rs:303-315) picks the newest top-level grant of any scope. It needs `AND project_id IS NULL`, plus a project variant. The grant drives the tool list and model aliases (executor.rs:752-759, 834-845).
- `is_team_lead` and `delegation_targets` are global, not per scope (instances.rs:563-590).

**Archives.**
- The private archive must exclude `./projects` and `./.thinktin/h` (EXPORT_ARGV).
- Each live project scope gets its own archive, sealed with the project key (from 8.15) under a new AAD domain that includes the instance id. This satisfies impl.md:22: "私人工作区归档不得夹带可被个人 DEK 解出的项目明文".
- Metadata goes in a **new** table, keyed `(instance_id, project_id)`, with its own purge trigger.
- `archive_to_store` (control lib.rs:1435-1515) must commit all scope archives before the sandbox is destroyed. `restore_into` must restore only scopes that are still live.

**Cleanup.** Before every shim start or restore, delete every `projects/*` and `.thinktin/h/*` directory that is not a live scope (an allow-list). Design A's deletion queue `scope_cleanups` (A §6.4) can be undone when an older archive or snapshot is restored (sandbox-acs.md:98).

**Dedicated instances.**
- A trigger rejects private runs on them.
- No private grants; existing private grants and plans are revoked or paused when an instance is marked dedicated, and marking returns 409 while it has unfinished private runs.
- They are hidden from the private `agents_list`.
- Same user id means marking an existing instance dedicated does not hide its old private HOME. The impl plan's pilot rule ("试点跨用户项目只接入可以做到进程和文件隔离的实例", impl.md:12, 22) therefore means: only freshly adopted dedicated instances in cross-user projects, or wipe the private scope first.

**Non-dedicated warning.** For cross-user projects only (projects.md:69), the API takes `ack_shared_memory`, and the app shows the warning.

**Concurrency.** Keep one active run per instance. The fixed OpenClaw port 18789 (config.rs:298) and the single `platform-tools.json` path (exec.rs:178) depend on it. The cost: on a non-dedicated instance, a project run that is waiting (including waiting for quota when the project budget runs out) blocks the owner's private runs.

**Not needed:** a per-scope token epoch. Bumping `instances.token_epoch` is enough, because only one run is active per instance.

## 3. What 8.13 must prepare so 8.16 needs no migration of the same tables

**Must have:**
1. **`project_agents`** with:
   - primary key `(project_id, instance_id)`;
   - `UNIQUE (project_id, instance_id, user_id)`;
   - foreign key `(instance_id, user_id) → instances`;
   - `left_at`;
   - **`dedicated boolean NOT NULL DEFAULT false`** (projects.md:32 already lists it in the model);
   - a partial unique index on `instance_id WHERE dedicated AND left_at IS NULL` (design A lines 132-158).

   The scope key can be derived from the project UUID, and migrated teams keep their ids, so 8.16's archive table can reference this primary key without changing `project_agents`.
2. **`runs.project_id`**: nullable, references `projects`, cannot change on update, and children inherit it from the parent (via trigger). Put the "no private run on a dedicated instance" check in the same 8.13 trigger function (design A lines 390-393), so 8.16 doesn't have to replace it.
3. **`run_grants.project_id`**, needed for the top-level grant per (instance, project) that drives tools and models. Nothing per scope is needed on `instances`: the existing `workspace_archive_*` columns stay as the private scope's archive.
4. **Team compatibility:** team-template adoption (gateway teams.rs:183-226, which already creates instances, private grants and the team in one tenant transaction) and `POST /v1/teams` must write `dedicated = false` and leave team runs at `project_id = NULL`. They then stay in the private session (design A line 1158), and **8.13 changes nothing inside the sandbox**.
5. **Claim guard (code):** the 8.13 build must add `project_id IS NULL` to `claim_next_run` (runs.rs:878-896), `take_over_expired` (993-1005) and `claim_expired_waits` (1291-1303), next to the existing `known_sources()` filter (runs.rs:201-205). It stays until the build that can isolate scopes. This is impl.md:29. Workers older than 8.13 can't see the column, so no executable project runs may be written until they are gone.

**Optional, but decide in 8.13:**
- `project_agents.ack_shared_memory_at` (or record the ack in the audit log only).
- An "adopted for this project vs existing instance" marker, for the pilot rule above. Otherwise derive it from whether the instance has any private runs.
- Changing `runs_one_active_per_instance` so that waiting project runs don't block private runs. This is a `runs` migration, so it belongs with 8.13's change to `runs`. Default: leave it as is.

**Note on migration numbers:** the last migration is 0038_browser.sql. Design A's 0031–0036 collide with the existing 0031_windows_devices … 0036_search, so 8.13 starts at **0039**.