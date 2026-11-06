# 8.16 对抗评审（workflow `review-8-16`，2026-11-06）

四个方面（数据库规则、领取和执行、工作区和加入、接口和测试）各一个审查员，每个方面一个反驳者。共 17 条，反驳后成立 15 条。

原文是英文，下面照录（`verified` 是反驳者的结论）。修复记录见文末。

## 0. A paused plan's in-flight pipeline can reach a newly dedicated instance, and the trigger error then blocks the pipeline driver for every user（db-invariants，high → verified=True high）

- **id**: `pipeline-step-on-dedicated-wedges-driver`，`crates/orchestrator/src/pipeline.rs:262`
- **scenario**:

  1) User A has pipeline plan P. Its own instance is X, and step b runs on instance Y and depends on step a. P fires, so pipeline root run R (kind='pipeline', instance X) is waiting_children with step a running on X.
  2) A pauses P (POST /v1/plans/{id}/pause), or an agent edit pauses it through request_plan_confirmation. This only sets plans.status='paused'. R keeps running, because due_pipelines and advance() never look at the plan's status.
  3) A dedicates Y to a project (PATCH /v1/projects/{p}/agents/{Y}, or join/add with dedicate:true). free_instance_check and the 0055 trigger instances_dedicated_alone both pass: Y has no unfinished run (R is on X) and no *active* plan uses Y.
  4) Step a succeeds. The pipeline tick calls start_step(b on Y). create_child_grant inserts a private run_grants row on Y; with no plan grant, create_run inserts a private run. The run_grants_instance_space / runs_instance_space trigger raises 23514 constraint instance_dedicated. error.rs maps that to Error::InstanceDedicated, not Invalid, so the grant branch `Err(store::Error::Invalid(m)) => return Ok(Err(m))` no longer catches it. `Err(e) => return Err(e)` / `create_run(..).await?` propagates it, and advance()? and tick()? abort the whole batch transaction, including requeue_pipelines.
  5) The next tick (every 2s) picks the same front-of-queue batch (ORDER BY not_before, id LIMIT 20) and fails again. R and up to 19 other users' pipelines in that batch never advance, and later pipelines are never reached. This lasts until someone cancels R.
  I reproduced the DB half on a scratch database: the dedicating UPDATE succeeded with paused plan P holding a step on Y, and the later step-run INSERT on Y failed with 'instance … works only for its project' (instance_dedicated).

- **evidence**:

  0055_dedicated_instances.sql:126 and instances.rs:1098 count only `plans p WHERE p.status = 'active'`. They ignore unfinished pipeline runs whose plan has a remaining step on the instance (the 0055 comment says '暂停的可以留着，恢复时再查', but a running pipeline never re-checks). pipeline.rs:236-241: `match w.create_child_grant(...) { Ok(g) => ..., Err(store::Error::Invalid(m)) => return Ok(Err(m)), Err(e) => return Err(e) }`. pipeline.rs:262: `let child = w.create_run(root.user_id, &new).await?;`. pipeline.rs:69: `self.advance(&mut w, root, ...).await?;` inside one transaction for the whole batch. error.rs now returns InstanceDedicated for constraint instance_dedicated before the generic 23514 → Invalid arm.

- **fix**:

  Smallest fix: in PipelineDriver::start_step, map store::Error::InstanceDedicated from both create_child_grant and create_run to `Ok(Err(format!("the agent for step {} now works only for a project", step.key)))`, so this one pipeline fails cleanly. Also, as an invariant: in free_instance_check and instances_dedicated_alone, treat `EXISTS (SELECT 1 FROM runs r JOIN plan_steps s ON s.plan_id = r.plan_id WHERE r.kind = 'pipeline' AND r.state NOT IN ('succeeded','failed','cancelled') AND s.instance_id = <instance>)` as other work (instance_not_free).

- **verifier**:

  I could not refute any step of the scenario.
  (1) Plan steps can sit on a different instance from the plan's own instance (orchestrator/tests/pipeline.rs:364-365 runs steps on e.a and e.b).
  (2) Pausing does not touch the in-flight pipeline. gateway routes/plans.rs:324-336 only calls set_plan_paused (plans.rs:490-496 changes status only), and request_plan_confirmation (plans.rs:179-189) does the same. due_pipelines (runs.rs:1723-1736) and advance() never read plans.status.
  (3) Dedicating Y then passes every check. free_instance_check (instances.rs:1096-1100) and the 0055 trigger instances_dedicated_alone (0055:126-128) count only plans with status = 'active' and unfinished runs whose instance_id is Y. Root R is on X and step b has no run yet. The 0055 comment ('暂停的可以留着，恢复时再查') covers resume (plans_instance_space fires on status -> active), but nothing re-checks a pipeline that is already running. Both place_agents (project_members.rs:218) and dedicate_project_agent (:385) rely only on free_instance_check. Dedication revokes private grants on Y only, so the plan's root grant on X stays active.
  (4) When step a succeeds, start_step(b on Y) runs. instance_runtime passes, because Y is 'provisioning', not deleted. create_child_grant then calls grants.rs insert with project_id NULL. The BEFORE INSERT trigger run_grants_instance_space (space_matches_instance, 0055:57-69) raises 23514 with CONSTRAINT 'instance_dedicated'. error.rs:73-76 maps that constraint name to Error::InstanceDedicated before the generic 23514 -> Invalid arm. So pipeline.rs:238 (`Err(store::Error::Invalid(m)) => return Ok(Err(m))`) does not catch it, and :239 (`Err(e) => return Err(e)`) propagates it. If the root has no grant, create_run at :262 propagates it the same way, through runs_instance_space.
  (5) tick() (pipeline.rs:63-83) uses `?` on advance, so the whole batch transaction is dropped and rolled back, including requeue_pipelines. The run loop only logs the error ('pipeline tick failed') and ticks again. due_pipelines orders by (not_before, id) and nothing was requeued, so the next tick picks the same front batch and fails again. Nothing times a waiting pipeline out: the only pipeline-kind queries are due_pipelines and requeue_pipelines.
  On a single replica the batch never moves, so every user's pipelines in it stall and later ones are never reached, until someone cancels R. Before 8.16 this trigger did not exist, so 8.16 opened the hole.
  I keep it high: one user's ordinary actions (pause, then dedicate) cause a persistent, cross-user outage of a shared worker, which behaves like a deadlock.

- **verified_fix**:

  In PipelineDriver::start_step, map store::Error::InstanceDedicated from both create_child_grant and create_run to Ok(Err(format!("the agent for step {} now works only for a project", step.key))). The pipeline then fails cleanly through cancel_children and finish. Defensively, run each advance() inside a SAVEPOINT so that one bad pipeline cannot roll back the batch.
  Also close the invariant hole. In free_instance_check and in the instances_dedicated_alone trigger, treat this as other work (instance_not_free): EXISTS (SELECT 1 FROM runs r JOIN plan_steps s ON s.plan_id = r.plan_id WHERE r.kind = 'pipeline' AND r.state NOT IN ('succeeded','failed','cancelled') AND s.instance_id = <instance>).


## 1. The egress→instance lock order in release and join/add-with-dedicate deadlocks against the tenant's instance delete (instance→egress)（db-invariants，medium → verified=True low）

- **id**: `egress-prelock-vs-instance-delete-deadlock`，`crates/store/src/instances.rs:1233`
- **scenario**:

  The owner deletes an agent (DELETE /v1/instances/{id}) while, at the same moment, releasing it (POST /v1/instances/{id}/release) or joining or adding it to a project with dedicate:true (for example from a second device). The instance has a pending egress request.
  - The release/join transaction runs prelock_egress first (`SELECT id FROM egress_requests WHERE instance_id=$1 ORDER BY id FOR UPDATE`), then lock_instance (FOR UPDATE).
  - The tenant delete runs delete_instance: `UPDATE instances SET state='deleted'` takes a row lock on the instance, then `UPDATE egress_requests SET status='expired' WHERE instance_id=$1 AND status='pending'`.
  Each transaction waits for the other, and PostgreSQL aborts one with 40P01. That surfaces as store::Error::Db and a 500 from the gateway.
  The delete route's lock_instance_projects only takes advisory locks on projects where the instance has a *live* agent row. For release (no live rows allowed) and for joining a project the instance is not in yet, nothing serializes the two requests. dedicate_project_agent is protected only because its instance has a live row in that project.
  I reproduced it on a scratch database with exactly these statements: 'ERROR: deadlock detected … while locking tuple in relation "instances"'. The existing test dedicate_races_instance_delete creates no egress requests and covers only the PATCH dedicate path, so it does not catch this.

- **evidence**:

  instances.rs:1232-1234 (release_instance): `self.lock_project(project)...; self.prelock_egress(instance).await?; let rt = self.lock_instance(instance).await?;`. project_members.rs:179-197 (place_agents): prelock_egress for each dedicated instance, then `SELECT ... FROM instances ... FOR UPDATE`. instances.rs:392-421 (Tx<Tenant>::delete_instance): `UPDATE instances SET state = 'deleted' ...` and later `WITH gone AS (UPDATE egress_requests SET status = 'expired' WHERE instance_id = $1 AND status = 'pending' ...)`. projects.rs:414-426: lock_instance_projects locks only `project_agents ... WHERE instance_id = $1 AND left_at IS NULL` projects.

- **fix**:

  Use one order everywhere: in the gateway delete route (before cancel_instance_runs, which can already bump the instance's epoch) or at the top of delete_instance, pre-lock the instance's egress rows with `SELECT id FROM egress_requests WHERE instance_id = $1 ORDER BY id FOR UPDATE` before touching the instances row. That matches the egress→instance order of decide_egress_request and the 8.16 prelock.

- **verifier**:

  The lock cycle is real.
  The worker side takes egress rows before the instance:
  - release_instance (instances.rs:1232-1234): lock_project, then prelock_egress (`SELECT id FROM egress_requests WHERE instance_id=$1 ORDER BY id FOR UPDATE`), then lock_instance FOR UPDATE.
  - place_agents (project_members.rs:179-197): prelock_egress for each dedicate:true instance, then `SELECT … FROM instances … FOR UPDATE`.
  The tenant delete route (gateway routes/instances.rs:389-404) takes the instance first, then the egress rows:
  - cancel_instance_runs runs bump_epochs_where! (`UPDATE instances SET token_epoch…`) when the instance has an active run. In any case delete_instance (instances.rs:390-397) runs `UPDATE instances SET state='deleted'`, a NO KEY UPDATE lock.
  - Only then does it run `UPDATE egress_requests SET status='expired' WHERE instance_id=$1 AND status='pending'` (:414-423).
  FOR UPDATE conflicts with NO KEY UPDATE on both rows. So if the worker's prelock lands while the tenant sits between its instance lock and its egress update (several statements wide), each waits on the other and PostgreSQL aborts one with 40P01. That becomes Error::Db and a 500, and nothing retries 40P01.
  Nothing earlier serializes the two:
  - lock_instance_projects (projects.rs:414-426) locks only projects where the instance has a live row. Release requires no live rows, and a join/add with dedicate puts the instance into a project it is not yet in.
  - lock_users takes FOR KEY SHARE, which does not conflict.
  - retire_instance_plans' advisory key and plan locks are not taken by the worker side.
  - In place_agents the deadlock happens at lock_instance, before free_instance_check. So a busy private instance with a pending egress request (the most likely state) still triggers it.
  This contradicts the plan's D3/D13 order (requests -> instances) and the stated intent of dedicate_races_instance_delete ('不会互相等死'). That test uses no egress rows and calls t.delete_instance directly.
  I lower the severity to low. Only the same owner can race against themselves (delete vs release/add-dedicate on one instance from two devices at the same moment). PostgreSQL detects the deadlock and rolls back one transaction whole, so there is no hang, corruption or leak. The user sees one retryable 500.

- **verified_fix**:

  Make the tenant delete route follow egress -> instance too. In gateway routes/instances.rs delete, right after lock_instance_projects and before retire_instance_plans and cancel_instance_runs, pre-lock the instance's egress rows with `SELECT id FROM egress_requests WHERE instance_id = $1 ORDER BY id FOR UPDATE`. For example, make the store's prelock_egress available on Tx<R> and call it there, or do it at the start of a combined store helper. This matches decide_egress_request (egress row, then instances) and the 8.16 prelock. Extend dedicate_races_instance_delete with a pending egress request, run it through the full route sequence, and add release and add-with-dedicate variants.


## 2. web_search in project runs still checks queries against the owner's whole vault and reports matches（claim-execution，high → verified=True medium）

- **id**: `web-search-vault-oracle`，`crates/orchestrator/src/search.rs:185`
- **scenario**:

  Bob's agent D is dedicated to a shared project P. Since 8.16, project runs on D can be claimed, and executor start gives them PROJECT_RUN_TOOLS, which includes web_search. Bob's vault holds a PIN 4821. Alice, another member, asks D to web_search 4820, 4821, 4822 and so on, and to say which searches were refused. The 4821 search returns the tool error 'the query contains one of the user's saved secrets; never put passwords or keys into a search'. The agent repeats this in agent.message, which members can read, so Alice learns Bob's PIN. This is the guessing oracle that D14/S1 closed in the executor scrubber (empty for project runs) and in llm-gw (skipped for dedicated instances). It stays open through the one non-artifact tool project runs are given. It becomes reachable as soon as anything writes a project run (8.17), but 8.16 claims and tests this guarantee.

- **evidence**:

  search.rs:184-190 runs `let scrubber = crate::vault::user_scrubber(&self.db, self.kms.clone(), ctx.user).await; if scrubber.scrub(&query).is_some() { return Err("the query contains one of the user's saved secrets...") }`. Here ctx.user is the run owner, and user_scrubber (vault.rs:255-290) loads every item in the owner's vault. tools.rs:454 PROJECT_RUN_TOOLS includes "web_search". executor.rs:995-999 uses Scrubber::new() for project runs and proxy.rs:749 skips scrubbing for dedicated instances, but search.rs ignores ctx.project.

- **fix**:

  In SearchTools::search, skip the owner-vault check when ctx.project.is_some(), as the executor and llm-gw already do. In 8.18, check only the vault items granted to the project.

- **verifier**:

  The code matches the finding. SearchTools::search (crates/orchestrator/src/search.rs:184-190) builds crate::vault::user_scrubber(&self.db, self.kms, ctx.user). That function (vault.rs:255-290) opens every item in the run owner's vault. The search returns a distinct error when the query contains any item's value. ToolContext carries `project` (shim.rs:69-77) and executor start fills it (executor.rs:978), but search.rs never reads it. PROJECT_RUN_TOOLS includes web_search (tools.rs:454-460), allowed_in_space lets it through (executor.rs:864), and project runs get no scrubbing (executor.rs:995-999). So the agent can repeat the refusal verbatim in agent.message, which members can read. Plan D14 says the scrubber is empty for project runs and llm-gw skips owner-vault scrubbing. Its stated purpose is to stop a member from guessing the owner's PIN through scrubbing differences. The plan lists only executor.rs:979, vault.rs and proxy.rs and misses this third use of the owner's vault, so the 8.16 code breaks D14's guarantee. Why medium and not high: it cannot be reached today. Nothing writes project runs (plan D1), and executor start fails any project run without run_grant_id ('a project run needs its project grant', executor.rs:757-762). Project grants only come with 8.17's dispatcher. Once 8.17 lands, this is a high-severity cross-user vault oracle with no further change to search.rs, and nothing in the 8.17 list would touch it.

- **verified_fix**:

  In SearchTools::search, skip the owner-vault check when ctx.project.is_some(), as the executor and llm-gw already do: `if ctx.project.is_none() { let scrubber = user_scrubber(...); if scrubber.scrub(&query).is_some() { return Err(...) } }`. In 8.18, check only the vault items granted to the project. Add a test: a project run's web_search with a query that equals an owner-vault value is not refused, so the refusal reveals nothing.


## 3. An in-flight pipeline of a paused plan whose step agent was dedicated aborts every pipeline tick, stalling all users' pipelines（claim-execution，high → verified=True high）

- **id**: `pipeline-stall-dedicated-step`，`crates/orchestrator/src/pipeline.rs:241`
- **scenario**:

  Alice has a plan with steps: step1 on agent B, step2 on agent A (after step1). The plan's own instance is L. A trigger fires and creates pipeline root R on L. Alice pauses the plan (POST /v1/plans/{id}/pause; set_plan_paused only changes status, so R keeps running). A is a mixed agent in her solo project P, and she marks it dedicated (PATCH /v1/projects/P/agents/A with reset_workspace, which is not behind cross_user). free_instance_check passes: A has no unfinished runs, because R is on L and step2 has not started, and the plan is not 'active'. When step1 succeeds, due_pipelines (which ignores plan status) returns R. start_step calls create_child_grant on A (or create_run when there is no grant). The run_grants_instance_space / runs_instance_space trigger raises instance_dedicated, which maps to Error::InstanceDedicated. That error is not Invalid, so it propagates out of advance and tick. The whole batch transaction rolls back, including requeue_pipelines. R keeps its old not_before and is picked again every 2 s, so with batch 20 the oldest due pipelines of every user never advance again. I confirmed on a scratch DB that a worker run_grants insert on a dedicated instance fails with CONSTRAINT instance_dedicated.

- **evidence**:

  pipeline.rs:229-242 `match w.create_child_grant(parent, step.instance_id, ...) { Ok(g) => ..., Err(store::Error::Invalid(m)) => return Ok(Err(m)), Err(e) => return Err(e) }` and pipeline.rs:262 `let child = w.create_run(root.user_id, &new).await?;`. tick (pipeline.rs:68-81) uses one transaction and `?` on every advance. instances.rs:1098 free_instance_check and the 0055 instances_dedicated_alone trigger (line 126) count only plans with status 'active'. due_pipelines (runs.rs ~1727) has no plan-status filter.

- **fix**:

  In start_step, map store::Error::InstanceDedicated from both create_child_grant and create_run to Ok(Err(format!("the agent for step {} now works only for a project", step.key))), so the pipeline fails on its own. Also make free_instance_check and instances_dedicated_alone refuse while an unfinished pipeline run belongs to a plan, in any status, that has a step on the instance.

- **verifier**:

  This is reachable today with a solo project, with no cross_user switch. (1) The plan has an active trigger that starts pipeline root R on L, with step1 on B and step2 on A. (2) POST /v1/plans/{id}/pause calls set_plan_paused, which only flips plans.status (plans.rs:490-508) and does not stop R. (3) A is an agent in her solo project P. PATCH /v1/projects/P/agents/A {dedicated, reset_workspace} (routes/projects.rs:327, no cross_user gate) reaches dedicate_project_agent, and its free_instance_check (instances.rs:1091-1117) passes. A has no unfinished runs, because step2 has no child yet and R is on L. The plan check counts only status='active', and the 0055 instances_dedicated_alone trigger does the same; the 0055 comment says paused plans may stay. (4) Step1 succeeds. due_pipelines (runs.rs:1723-1736) has no plan-status filter and returns R. advance calls start_step(step2). instance_runtime(A) shows 'provisioning', not deleted, so it goes on to create_child_grant or create_run. That INSERT fires run_grants_instance_space or runs_instance_space (space_matches_instance), which raises 23514 CONSTRAINT instance_dedicated. error.rs:76 maps that to Error::InstanceDedicated, not Invalid. start_step's match only turns Invalid into Ok(Err) (pipeline.rs:238-240), and create_run is propagated with `?` (pipeline.rs:262). The error leaves advance and tick (pipeline.rs:68-71). The tx rolls back, so requeue_pipelines never commits and R keeps its old not_before. The next tick, every 2 s, picks R first again (ORDER BY not_before, id) and fails again. On a single replica no pipeline of any user advances. With several replicas, SKIP LOCKED only lets them take turns around R, and a few such roots fill the batch. Nothing else refutes it: no pre-check exists in create_run or create_child_grant (runs.rs:1127, grants.rs:306-335), and pause does not cancel. Correction to the proposed fix: by the time InstanceDedicated surfaces, PostgreSQL has already aborted the transaction. Mapping the error to Ok(Err(..)) would make the following cancel_children and finish fail with 'current transaction is aborted', so the tick would still fail. The check has to happen before the INSERT, or inside a savepoint.

- **verified_fix**:

  In start_step, check before any INSERT. Read the step instance's workspace_project_id with `SELECT workspace_project_id FROM instances WHERE id=$1 FOR KEY SHARE`, so a concurrent dedicate, which uses FOR UPDATE, has to wait for this tx. If it is Some, return Ok(Err(format!("the agent for step {} now works only for a project", step.key))) so the pipeline fails on its own. Alternatively, wrap the grant and run inserts in a savepoint and map InstanceDedicated to Ok(Err). Also make free_instance_check and instances_dedicated_alone refuse while an unfinished pipeline run belongs to a plan, in any status, with a step on the instance. Hardening: make tick isolate per-root failures with a savepoint per advance, so one bad root cannot stall every user's pipelines.


## 4. Tenant instance delete locks the instance before its pending egress requests, the opposite of the 8.16 egress-then-instance pre-lock (40P01)（claim-execution，medium → verified=True low）

- **id**: `delete-instance-egress-deadlock`，`crates/store/src/instances.rs:416`
- **scenario**:

  Bob's instance A has a pending egress request. On one device he calls POST /v1/instances/A/release, or adds or joins A as dedicated to a project it is not yet in. On another device he deletes A at the same time. release_instance/place_agents run prelock_egress (FOR UPDATE on A's egress rows) and then wait for the instance lock. The tenant delete route runs delete_instance: UPDATE instances (row lock on A), then UPDATE egress_requests ... status='pending', which waits on the worker's egress lock. lock_instance_projects does not serialize the two, because A has no live agent row in the target project. PostgreSQL reports a deadlock and one request fails with 500. I reproduced this on a scratch DB with all migrations applied: 'ERROR: deadlock detected ... while locking tuple (0,1) in relation "egress_requests"'. The same reverse order already conflicts with decide_egress_request(Always). Plan test 18 claims there is no 40P01 here.

- **evidence**:

  delete_instance (instances.rs:390-425) runs `UPDATE instances SET state = 'deleted' ...`, then `WITH gone AS (UPDATE egress_requests SET status = 'expired' WHERE instance_id = $1 AND status = 'pending' ...)`, i.e. instance before requests. 8.16's prelock_egress (instances.rs:1080) is called before lock_instance in release_instance (instances.rs:1209-1235) and in place_agents for dedicate=true, i.e. requests before instance (plan D6/A3).

- **fix**:

  Before UPDATE instances in the delete route or delete_instance, pre-lock the instance's egress rows (`SELECT id FROM egress_requests WHERE instance_id = $1 ORDER BY id FOR UPDATE`). Alternatively, expire the pending requests before updating the instance row, matching decide_egress_request and retire_workspace.

- **verifier**:

  The lock-order inversion is real. The tenant delete route (routes/instances.rs:389-410) runs lock_instance_projects, retire_instance_plans and cancel_instance_runs, then delete_instance. delete_instance first runs UPDATE instances, which takes a row lock on A (instances.rs:390-397), and then UPDATE egress_requests ... status='pending' (instances.rs:414-423). That is instance before requests. The 8.16 worker paths take requests before instance: place_agents with dedicate=true runs prelock_egress (project_members.rs:179-184) before SELECT ... FOR UPDATE on the instance, and release_instance and dedicate_project_agent do the same. The interleaving that deadlocks: W pre-locks A's egress rows, T updates A, W waits for A, T waits for an egress row, giving 40P01. Nothing serializes the two for the add-agents or join path into a project A is not yet in. lock_instance_projects only takes advisory locks for projects where A has live rows, and the tenant takes no users lock. add_agents is not behind cross_user, so the race is reachable today: the same user deletes A and adds it as dedicated at the same moment while A has a pending egress request. Today's release path is effectively unreachable, because a dedicated instance cannot have pending egress requests until project runs execute. I lowered the severity to low. PostgreSQL detects the deadlock and aborts one of the two transactions, both of which belong to the same user and are racing each other. Nothing is corrupted or leaked, and the user only sees a transient 500 on one request. It does contradict the plan's lock order (D5/D6) and test 18's claim that there is no 40P01.

- **verified_fix**:

  In delete_instance, take A's egress rows before touching the instance row: run `SELECT id FROM egress_requests WHERE instance_id = $1 ORDER BY id FOR UPDATE`, or do the pending-expire UPDATE, before the UPDATE instances. Note that cancel_instance_runs, which runs earlier in the route, bumps token_epoch on instances via bump_epochs_where!, so the pre-lock belongs at the start of the delete route, before cancel_instance_runs. Add a concurrency test that runs delete alongside add-agents with dedicate.


## 5. ArtifactTools::origin uses the instance's current sandbox, so a cancelled run that is still dispatching tools can read or write a re-spaced workspace（claim-execution，low → verified=True low）

- **id**: `artifact-tools-current-sandbox`，`crates/orchestrator/src/tools.rs:509`
- **scenario**:

  (Needs project runs, so 8.17 or later.) Project run R runs on dedicated agent D. The owner withdraws D, which cancels R in the DB, but R's executor only notices at its next renew, up to 15 s later. Meanwhile the shim keeps sending PlatformToolCall events and they are still dispatched. The owner immediately releases D: the busy check passes because R is terminal, and D gets a fresh private workspace. A private message starts private run R2, and ensure_running binds a new private sandbox S2 to D. R's agent then calls artifact_publish path=notes.txt. origin() reads instance_runtime(D).sandbox_id, which is S2, so the file is read from the owner's private workspace and published as an artifact of R, stamped with project P and visible to all members. artifact_fetch in the same window writes project content into the private workspace. The plan says the DB invariants keep the space fixed for the whole run, so origin needs no check, but those invariants only hold while the run is unfinished.

- **evidence**:

  tools.rs:507-520 `let rt = w.instance_runtime(ctx.instance).await?; ... rt.sandbox_id` is used by publish (read_file) and fetch (write_file). It is not compared with the sandbox the run was launched in or with ctx.project. release_instance (instances.rs:1209+) and free_instance_check only reject unfinished runs. The executor learns of cancellation only in on_renew (executor.rs:2409-2419, renew_every 15 s).

- **fix**:

  Carry the launch sandbox id, or the start-time rt, in ToolContext and use it in origin. At minimum, refuse when rt.workspace_project_id != ctx.project or rt.sandbox_id differs from the sandbox the run started in.

- **verifier**:

  The cited code is as described. ArtifactTools::origin reads the instance's current runtime (tools.rs:507-520), and publish and fetch use rt.sandbox_id for read_file and write_file. It never compares workspace_project_id with ctx.project, and never compares the sandbox with the one the run started in. The plan (§3, line 797) says no check is needed because the D4 invariants keep the space fixed for the whole run. Those invariants only hold while the run is unfinished in the DB. The cancel helpers set the run terminal and clear lease_owner, and the executor only notices on its next renew (renew_every 15 s, executor.rs:77, on_renew at 2409). Until then, PlatformToolCall events are still dispatched with no liveness check (executor.rs:1921-1949, call_tool 1427). Meanwhile release_instance and free_instance_check accept the instance, because the run is terminal, and retire_workspace swaps the space. If another run then gets a new sandbox bound, a late tool call from the old run reads or writes the wrong space's workspace. The exposure is small: it needs executable project runs (8.17), a tight sequence within about 15 s (withdraw, release, a new run claimed, a sandbox created), and a tool call the old agent already had queued. The token_epoch bump stops it from making new model calls, and the fresh workspace holds very little. Still, the plan's claim that origin needs no check is wrong, and the fix is cheap.

- **verified_fix**:

  At executor start, carry the launch-time sandbox id and space in ToolContext, or keep the start-time rt. In ArtifactTools::origin, refuse when rt.workspace_project_id != ctx.project or rt.sandbox_id differs from the launch sandbox ('the agent's workspace changed; this run is over'). Optionally, check that the run is still non-terminal before dispatching side-effecting platform tools.


## 6. Release and dedicate-on-join lock egress requests before the instance, but deleting an instance locks them the other way round（workspace-lifecycle，medium → verified=True medium）

- **id**: `egress-prelock-vs-instance-delete-deadlock`，`crates/store/src/instances.rs:1233`
- **scenario**:

  A user's botin I has a pending egress request R (the agent asked for a site and nobody answered yet). Case 1: I is dedicated, already withdrawn from its project, and the owner calls POST /v1/instances/{I}/release. Case 2: I is private and the owner joins or adds agents with {instance_id: I, dedicated: true, reset_workspace: true}. At the same moment the owner deletes I (DELETE /v1/instances/{I}, from a second device or a retry). The release or place_agents transaction runs prelock_egress and locks R. The delete transaction then locks I: cancel_instance_runs bumps token_epoch, then delete_instance does `UPDATE instances SET state='deleted'`. The delete then runs `UPDATE egress_requests SET status='expired' WHERE instance_id=I AND status='pending'` and waits on R. The release or place_agents transaction runs lock_instance(I) FOR UPDATE and waits on the delete. PostgreSQL reports 40P01 and aborts one of the two requests, which reaches the user as a server error. The delete's lock_instance_projects takes no lock that would serialize the two: in case 1 I is live in no project, and in case 2 it is not yet in the target project. I reproduced this lock pattern on a scratch database (two tables, same statements): it gives 'deadlock detected ... while updating tuple in relation egress_requests'. The 8.16 test dedicate_races_instance_delete asserts there is no 40P01, but its fixture has no egress requests, so prelock locks nothing. dedicate_project_agent is safe only because the instance is live in that project, so the delete takes the same project lock first.

- **evidence**:

  instances.rs:1080-1086 prelock_egress: `SELECT id FROM egress_requests WHERE instance_id = $1 ORDER BY id FOR UPDATE`, then release_instance (1233-1234) and place_agents (project_members.rs:180-201) lock the instance row (`lock_instance` / `... FOR UPDATE`). The tenant delete path (gateway routes/instances.rs:398-402, then store instances.rs:390-423 delete_instance) first locks the instance (`bump_epochs_where!` in cancel_instance_runs, then `UPDATE instances SET state = 'deleted'`) and only afterwards runs `WITH gone AS (UPDATE egress_requests SET status = 'expired' WHERE instance_id = $1 AND status = 'pending' ...)`. That is instance -> egress, the reverse of the D6/D13 order (egress requests -> instances) that 8.16 relies on.

- **fix**:

  Make the tenant delete take the egress locks in the same order: at the start of the delete transaction (before retire_instance_plans and cancel_instance_runs touch the instance), lock or expire the instance's pending egress requests, for example `SELECT id FROM egress_requests WHERE instance_id=$1 ORDER BY id FOR UPDATE`. Alternatively, move the egress expiry in delete_instance ahead of the instance UPDATE. Add a pending egress request to dedicate_races_instance_delete, and add a release-vs-delete case.

- **verifier**:

  I checked the lock order on both sides. Release (store instances.rs:1209-1235, called from orchestrator projects.rs:471 by POST /v1/instances/{id}/release) takes the user rows FOR KEY SHARE, then the project advisory lock, then prelock_egress (instances.rs:1080, SELECT id FROM egress_requests WHERE instance_id=$1 ORDER BY id FOR UPDATE), then lock_instance (FOR UPDATE, instances.rs:676). place_agents (project_members.rs:180-200) does the same: prelock, then SELECT ... FOR UPDATE on the instance. The tenant delete (gateway routes/instances.rs:389-402) runs: t.instance (plain read); lock_instance_projects, which only locks projects where the instance is live, so none for a withdrawn dedicated instance (case 1) and not the target project for a private one (case 2); retire_instance_plans (instance_plans advisory lock, which release and place_agents never take); cancel_instance_runs (runs FOR NO KEY UPDATE, and an instance UPDATE only if agent runs are active); revoke_instance_grants; then delete_instance, which does UPDATE instances SET state='deleted' first and the egress UPDATE ... status='expired' fourth (instances.rs:390-423). Nothing taken earlier in the delete path conflicts with what release or place_agents hold before their prelock. The tenant delete doesn't lock the users row, and the FK KEY SHARE locks are compatible. So the cycle forms if the release or place_agents prelock and instance lock both land while the delete holds the instance row and hasn't yet reached its egress UPDATE. That window is three statements long, or longer when the instance has active runs and cancel_instance_runs bumps the epoch. RLS doesn't stop the delete's egress UPDATE from waiting. The tenant policy (0056:91-92) shows rows with project_id NULL, or stamped with a project the owner is still a member of. In case 2 that is the usual private request. In case 1 it is a project request where the owner withdrew the agent but stayed in the project. Withdraw doesn't expire pending egress requests (project_members.rs has no egress handling besides prelock). The test dedicate_races_instance_delete (tests/isolation.rs:713) has no egress rows, and it calls t.delete_instance directly, not the gateway sequence, so it can't catch this. Plan D5/D6 set egress requests before instances as the order. The tenant delete takes them the other way round. The same inversion already existed between decide_egress_request and delete. PostgreSQL detects the deadlock and aborts one request (a 500). No data is corrupted, so medium rather than high.

- **verified_fix**:

  In the gateway delete handler, lock the instance's egress requests before anything touches the instance row: right after t.lock_instance_projects(id) and before retire_instance_plans and cancel_instance_runs, run SELECT id FROM egress_requests WHERE instance_id=$1 ORDER BY id FOR UPDATE. As a Tenant method this only covers rows visible to the tenant, but invisible rows (projects the owner left) are also skipped by the delete's own expiry UPDATE, so that is enough. Moving the expiry inside delete_instance ahead of its instance UPDATE is NOT enough, because cancel_instance_runs may already have locked the instance through bump_epochs_where! when agent runs are active. Add a pending egress request to dedicate_races_instance_delete, drive the delete through the gateway's statement order, and add release-vs-delete and join(dedicate)-vs-delete cases. This also fixes the older decide_egress_request-vs-delete inversion.


## 7. Deleting a project can leave a host the owner chose to always allow during the project on the botin's fresh private workspace（workspace-lifecycle，low → verified=True low）

- **id**: `retire-vs-egress-always-allow`，`crates/store/src/instances.rs:1159`
- **scenario**:

  A dedicated botin I in project p has a pending egress request R with project_id NULL. Such a request arises when the ask arrives while no run is active (llm-gw passes run=None from ledger.decision), so the stamp trigger leaves project_id NULL. The owner taps 'always allow': decide_egress_request locks R FOR UPDATE and checks the instance is live. The project creator then deletes p (or the creator is erased, or the purge backstop retires I). retire_project_workspaces locks I (SKIP LOCKED; the decide has not reached its UPDATE yet) and calls retire_workspace. That sets egress_hosts='{}' and a new workspace_id, and its `DELETE FROM egress_requests ... FOR UPDATE SKIP LOCKED` skips R. The delete commits. The decide's `UPDATE instances SET egress_hosts = egress_hosts || host WHERE id=$1 AND state <> 'deleted'` then runs against the reset private row and succeeds. R is NULL-stamped, so its UPDATE is still visible under RLS and the decide commits. The fresh private workspace therefore starts with a host approved in the project context, and R survives with status 'always'. This contradicts D6, which says a fresh workspace has egress_hosts '{}' and the instance's egress requests are deleted. The race is closed for requests stamped with p: after the delete, member_projects() hides them, the final UPDATE returns no row, and the decide rolls back. Only this race is open. dedicate and release avoid it by pre-locking egress requests; the project-delete callers (delete_project, erase_account, purge_deleted_projects) cannot wait and do not pre-lock.

- **evidence**:

  instances.rs:1159-1167 deletes egress requests with `FOR UPDATE SKIP LOCKED` after the instance is reset (1133-1150 sets `egress_hosts = '{}'`, new workspace_id). retire_project_workspaces (1192-1205) is called with no prelock from project_lifecycle.rs:168 (delete_project), users.rs:232 (erase) and project_lifecycle.rs:375 (purge). egress.rs:552-596 decide_egress_request locks the request first, then does `UPDATE instances ... WHERE id = $1 AND state <> 'deleted'` with no check that the workspace is still the one the request was asked in.

- **fix**:

  In decide_egress_request, read the instance's workspace_id together with the liveness check. Add `AND workspace_id = $ws` to the `UPDATE instances` (retire always assigns a new workspace_id), and return NotFound or Conflict when no row is updated. Alternatively, store the workspace_id on egress_requests when the request is created and compare it in the decide.

- **verifier**:

  retire_project_workspaces (instances.rs:1192-1205) locks instances with SKIP LOCKED and calls retire_workspace without any egress prelock. retire_workspace resets egress_hosts to '{}', gives the instance a new workspace_id, and then deletes egress requests with FOR UPDATE SKIP LOCKED (1159-1167). So a request that decide_egress_request (egress.rs:552-607) has already locked FOR UPDATE survives. The decide's later UPDATE instances ... WHERE id=$1 AND state <> 'deleted' (580-590) then re-reads under READ COMMITTED, or re-checks the new row version if it had to wait. It sees the reset, non-deleted private row and appends the host. The final UPDATE egress_requests succeeds when R.project_id is NULL, because the tenant policy USING (project_id IS NULL OR project_id IN member_projects()) still passes. A p-stamped request is filtered out once member_projects() drops the deleted project (0049:45-51), so fetch_one fails and the decide rolls back, as the reviewer said. A NULL-stamped pending request on a dedicated instance can exist. The stamp trigger (0056:30-41) only stamps when run_id is set. llm-gw passes run=None when egress_current_run (egress.rs:266) finds no active agent run. A token can still pass after its run ends because proxy.rs:405-415 accepts a cached directory entry whose epoch matches for up to the cache TTL. Requests left over from the private period don't survive: dedicate prelocks them and deletes them. So reaching this needs two narrow windows: a request made inside the cache TTL after a run ends, and the owner answering it at the same moment the project is deleted, the creator erased, or the purge backstop runs. The result contradicts D6 (a fresh workspace has egress_hosts '{}' and its egress requests deleted) and plan test 19 (the request is gone or expired, or the decision committed first). Test 19 isn't implemented: no retire_races_egress_always test exists. The impact is small. The host was approved by the same owner for the same botin, and no data crosses spaces. So the severity is low.

- **verified_fix**:

  In decide_egress_request, read the instance's workspace_id when doing the liveness check (or FOR SHARE). For Always, add AND workspace_id = $ws to the UPDATE instances. Because retire_workspace always assigns a new workspace_id, return NotFound when no row matches instead of the current 'too many always-allowed sites' Invalid. A sturdier option is to record workspace_id on egress_requests when the request is created and compare it in decide. Then add plan test 19 (retire_project_workspaces racing decide Always with a NULL-stamped request).


## 8. The claim-to-execute isolation path opened in 8.16 has no end-to-end test, and the docs say only test 19 is missing（api-contract-tests，medium → verified=True low）

- **id**: `missing-executor-isolation-tests`，`crates/orchestrator/src/executor.rs:741`
- **scenario**:

  8.16 opens claiming of project runs on dedicated instances (C8, D1: "the claim → execute path, with isolation, is tested in 8.16"). Suppose a later change drops `.filter(|t| allowed_in_space(..))` (executor.rs:864), the empty-scrubber branch (:996), the start-time space check (:741-746) or the no-private-grant rule (:760-763). A project run claimed on a dedicated botin would then launch with the owner's vault, board, delegate or computer tools, or with the owner-vault scrubber, which lets members probe for PINs. No test fails. The only coverage is the unit test `tools::space_tests`, which calls `allowed_in_space` directly and never exercises the executor.

- **evidence**:

  Plan §6.3 requires orchestrator `isolation.rs` with project_run_gets_only_project_tools, project_run_scrubber_is_empty, project_run_without_grant_fails, space_mismatch_is_refused, piggyback_stays_in_space, dedicating_gives_a_fresh_workspace, released_instance_forgets_project_files, left_members_instances_stop and resume_brief_reads_only_its_run. None of them exist. `grep -rl 'workspace_project_id|isolation|dedicate' crates/orchestrator/tests` returns nothing. Also missing: §6.2 retire_during_archive_deletes_the_upload and retire_during_restore_removes_the_new_sandbox (control/tests has only dedicated_archive_is_owned_by_the_project and sweep_destroys_retired_workspaces), and §6.1 test 5 dedicate_races_private_message. Even so, docs/projects-impl.md:192 and the progress file say "没写的测试：换工作区和出网“一直允许”同时进行" (only test 19).

- **fix**:

  Add orchestrator/tests/isolation.rs with at least project_run_gets_only_project_tools, project_run_scrubber_is_empty, project_run_without_grant_fails and space_mismatch_is_refused, using FakeConnector and a worker-written project run on a dedicated instance. Otherwise, list every unwritten test in projects-impl.md and the progress file.

- **verifier**:

  Confirmed. crates/orchestrator/tests has no isolation.rs, and no orchestrator test drives a project run through Executor::start. The only project-related orchestrator tests are projects.rs (artifacts and receipts), im.rs::project_notices_skip_im and workspaces.rs::project_archives_use_the_project_key_and_die_with_it. The only check of the tool filter is the unit test tools::space_tests, which calls allowed_in_space directly. Several other planned tests are also missing: control's retire_during_archive_deletes_the_upload and retire_during_restore_removes_the_new_sandbox (control/tests has only dedicated_archive_is_owned_by_the_project and sweep_destroys_retired_workspaces), and store test 5 dedicate_races_private_message. Plan D1 and C8 make the claim -> execute end-to-end tests part of opening the claim. Yet docs/projects-impl.md:192 and docs/progress/claude-determined-lovelace-vn0j5h.md:143 both say only test 19 is missing, which is inaccurate. I lowered the severity to low. The executor code at executor.rs:741-763, :864 and :996 reads correctly (rt.workspace_project_id is filled from runtime_columns), and in 8.16 no production path writes project runs, so a user cannot reach this today. It is a regression-safety and documentation gap, not a runtime defect.

- **verified_fix**:

  Add crates/orchestrator/tests/isolation.rs with at least project_run_gets_only_project_tools, project_run_scrubber_is_empty, project_run_without_grant_fails and space_mismatch_is_refused. Seed a worker-written project run on a dedicated instance and drive it through FakeConnector. Add the two control retire tests and store test 5, or list every unwritten test (not only 19) in projects-impl.md and the progress file.


## 9. orphan_sweeper_frees_the_instance asserts that takeover and expired waits skip the orphan, but they could never select it（api-contract-tests，low → verified=True low）

- **id**: `orphan-test-vacuous-takeover`，`crates/store/src/tests/boundary.rs:2466`
- **scenario**:

  Remove `live_space!` from `take_over_expired` or `claim_expired_waits` (runs.rs:1288-1290, 1593-1595). An ex-member's run with an expired lease would be taken over again and could produce a RunFailed notice for them, which D9 exists to prevent. The test still passes, and no other test covers that negative case.

- **evidence**:

  The fixture's b1 comes from `join_raw`, which inserts the project_agents row without dedicating it, so b1 is a mixed instance and `isolated!` already excludes its run. The test also sets `state = 'backoff', lease_owner = NULL`. `take_over_expired` only selects `lease_owner IS NOT NULL AND lease_expires_at < now()`, and `claim_expired_waits` only selects `state IN ('waiting_quota','waiting_device') AND wait_deadline <= now()`, so neither query can return the row whether or not the agent is live. The two `is_empty()` assertions at :2465-2476 prove nothing about the live rule.

- **fix**:

  Use a dedicated instance (UPDATE instances SET workspace_project_id) and put the orphan in the states those queries select: `running` with an expired lease for take_over_expired, `waiting_quota` with a past wait_deadline for claim_expired_waits. Assert it is skipped after the agent row is marked left, and returned while the row is live.

- **verifier**:

  Confirmed. project_run_fixture (boundary.rs:671) uses join_raw, which only inserts a project_agents row, so b1 stays a mixed instance (workspace_project_id NULL). The isolated! clause already excludes its project run. The test also sets state='backoff', lease_owner=NULL. take_over_expired (runs.rs:1277) requires lease_owner IS NOT NULL AND lease_expires_at < now(), and claim_expired_waits (runs.rs:1581) requires state IN ('waiting_quota','waiting_device') AND wait_deadline <= now(). Neither query can select the row, with or without live_space!, so the two is_empty() assertions at boundary.rs:2465-2476 prove nothing about the liveness rule. No other test covers it either. claim_takes_dedicated_project_runs_only checks liveness only through claim_next_run. old_claim_sql_never_returns_project_runs checks claim_expired_waits only in the positive, live case. tests.rs:1225-1270 uses a mixed instance at level 2, where isolated! is again what excludes the run. Removing live_space! from either query would leave every test green.

- **verified_fix**:

  Dedicate b1 (UPDATE instances SET workspace_project_id = p, peer_access = false) and seed the orphan once as 'running' with an expired lease and once as 'waiting_quota' with a past wait_deadline, setting thinktin.isolation = 1 in that transaction. Assert that take_over_expired and claim_expired_waits return it while the agent row is live and skip it after left_at is set.


## 10. private_queries_ignore_project_rows does not test the same-space filter of unannounced_messages（api-contract-tests，low → verified=False low）

- **id**: `piggyback-test-vacuous`，`crates/store/src/tests/isolation.rs:461`
- **scenario**:

  Drop `AND project_id IS NOT DISTINCT FROM $3` from `unannounced_messages` (runs.rs:1498). A project run would then piggyback the owner's private queued messages, and the test still passes.

- **evidence**:

  The only project run on c is `rc`, which the test leases into `running`. `unannounced_messages` only returns `state = 'queued' AND source = 'user'`, so rc is never a candidate either way. `private_only == vec![queued_private]` holds even without the space filter. `project_only.iter().all(|r| r.project_id == Some(f.p))` runs on an empty Vec, so it is vacuously true. The comment says "私人的和项目里的各一条" (one queued message of each), but no queued project message is ever created.

- **fix**:

  Create a queued, non-urgent `source='user'` project run on c (worker insert). Assert `unannounced_messages(c, None)` excludes it and `unannounced_messages(c, Some(p))` equals exactly that run.

- **verifier**:

  Refuted as stated. queued_private is a queued, source='user', non-urgent private run on c (queue_run uses RunSource::User). If `AND project_id IS NOT DISTINCT FROM $3` were dropped, unannounced_messages(c, Some(p)) would return [queued_private], whose project_id is None. The assertion `project_only.iter().all(|r| r.project_id == Some(f.p))` would then fail, so the test does catch a project run piggybacking the owner's private messages, which is the direction D15 cares about most. One gap remains, but it is not the reviewer's scenario: no queued project message is ever created. A mutation like `($3 IS NULL OR project_id = $3)` would let a private run piggyback project messages and still pass. The comment's 'one of each' is also inaccurate. That is a minor coverage nit.

- **verified_fix**:

  Optional hardening: insert a queued, non-urgent source='user' project run on c (worker insert, no lease). Assert unannounced_messages(c, None) == [queued_private] and unannounced_messages(c, Some(p)) == [that run].


## 11. accept_with_adopt_is_atomic's "a later failure rolls the adoption back" fails before any adoption runs（api-contract-tests，low → verified=True low）

- **id**: `adopt-atomic-test-vacuous`，`crates/store/src/tests/projects.rs:2525`
- **scenario**:

  Plan test 7 requires that "a later failure leaves no instance". Suppose the adopt INSERT moved before validation or into its own transaction. The `instances(bob) == 1` assertion would still pass, because nothing was ever inserted.

- **evidence**:

  The failing entry is `JoinAgent::mixed(a1.id)` (alice's instance). In `place_agents` (project_members.rs:173-204) the ownership loop over `all` runs first and returns `Invalid("choose your own agents…")` before `retire_workspace`, before the adopt `INSERT INTO instances` and before `put_agents`. The rollback assertion therefore never sees an adopted row to roll back.

- **fix**:

  Make the failure happen after the adopt insert. For example, pre-insert a live project_agents row so `put_agents` returns Conflict, or exceed MAX_PROJECT_AGENTS on the adopt. Then assert no new instance and no retired_workspaces row remain.

- **verifier**:

  Confirmed. In the 'bad' case max_instances = 0, so reserve_adopts passes. In place_agents (project_members.rs:139-204) the ownership loop over `all` runs SELECT ... WHERE id = $1 AND user_id = $2 for every listed id. It returns Invalid('choose your own agents…') for a1 (alice's) before free_instance_check/retire_workspace for b1, before the adopt INSERT INTO instances and before put_agents. Nothing is ever written, so `instances(bob) == 1` cannot detect a non-atomic adopt. The earlier InstanceLimit case also fails in reserve_adopts before any insert. Plan test 7's 'a later failure leaves no instance' is therefore not exercised.

- **verified_fix**:

  Make the failure happen after the adopt INSERT and the dedicate step. Two ways: first insert a live project_agents row for b1 by raw SQL so put_agents returns Conflict, or fill the project to MAX_PROJECT_AGENTS minus 1 so the adopt pushes it over. Then assert bob's instance count, the retired_workspaces rows for b1 and b1's workspace_id are all unchanged.


## 12. Joining with a botin dedicated to another project returns agent_not_isolated, not instance_dedicated（api-contract-tests，low → verified=True low）

- **id**: `join-dedicated-elsewhere-wrong-code`，`crates/store/src/project_members.rs:229`
- **scenario**:

  Bob's botin B is dedicated to project P1. Bob accepts an invite to P2 and lists B without `dedicated`. The server (mixed_project_agents=false) answers 409 `agent_not_isolated`, "only agents dedicated to this project can join it". The App's guidance for that code is to dedicate or reset the agent. The real problem is that B belongs to another project: §4/§5.2 list 409 `instance_dedicated` for this case, and the client-core error docs say instance_dedicated means "不能放进别的项目" (cannot be put into another project). If B was only withdrawn from P1, following the guidance silently wipes P1's memory on B.

- **evidence**:

  In the `sorted` loop, `space = Some(P1)` is not `Some(project)` and `dedicate` is false, so `else if shared { if !mixed_allowed { return Err(Error::AgentNotIsolated) } }` runs before the `project_agents_dedicated` trigger, which would raise `instance_dedicated` in put_agents. The gateway test only checks instance_dedicated for `POST /v1/projects/{p2}/agents` into an unshared project, where the mixed check is skipped.

- **fix**:

  In place_agents, when `space.is_some() && space != Some(project)` and `!dedicate`, return `Error::InstanceDedicated` before the mixed check. Add a join test for that case.

- **verifier**:

  Confirmed in code. accept always calls place_agents with shared=true (project_invites.rs:690-692), and the server forces mixed_allowed=false (config.rs:1064). For an Existing{dedicate:false} entry whose instance has workspace_project_id = P1 != P2, the sorted loop takes the `else if shared { if !mixed_allowed { return Err(AgentNotIsolated) } }` branch (project_members.rs:226-235) before the project_agents_dedicated trigger can raise instance_dedicated. The same request on an unshared project, the case the gateway test covers via POST /v1/projects/{p2}/agents, gets instance_dedicated. The client-core docs (error.rs:22-24) say instance_dedicated means the botin '不能放进别的项目' (cannot be put into another project), so the error codes are inconsistent. The reviewer's harm is overstated, though. Following the agent_not_isolated guidance on a botin still live in P1 gets 409 conflict (instance_not_free). On one already withdrawn from P1, it needs an explicit reset_workspace:true with the 'dedicated_existing_agent_is_reset' consent, so the wipe is not silent. It is a misleading error code and nothing more.

- **verified_fix**:

  In place_agents, before the mixed check, return Error::InstanceDedicated when `space.is_some() && space != Some(project.0) && !dedicate`. Add a join test (and a shared-project add test) for a botin dedicated to another project, asserting 409 instance_dedicated.


## 13. POST /v1/projects/{id}/agents with dedicated:true for an agent already in the project silently does nothing（api-contract-tests，low → verified=True low）

- **id**: `add-agents-dedicate-ignored`，`crates/store/src/project_members.rs:173`
- **scenario**:

  A member sends `{"agents":[{"instance_id":X,"dedicated":true,"reset_workspace":true}],"consent":true,"consent_version":2}` for an agent X that is already live in the project as a mixed agent, for example the creator's original solo agent. The response is 200 with the ProjectDetail. X is not reset or dedicated and keeps taking private tasks, and no error says that PATCH is the way to dedicate it.

- **evidence**:

  `new` filters out ids in `already`. `all` derives each `dedicate` flag from `new.iter().any(|(n, d, _)| n == id && *d)`, so it is false for X, which only gets FOR SHARE. Then `if new.is_empty() && adopts.is_empty() { return Ok(vec![]) }` at :205. The gateway's AgentReq::join accepted the destructive request after checking reset_workspace.

- **fix**:

  For a listed agent that is already live and has `dedicate: true` but is not yet dedicated to this project, either run the same dedicate path (free check, retire, revoke) or return 422/409 pointing to PATCH /v1/projects/{id}/agents/{instance}.

- **verifier**:

  Confirmed. In place_agents, `new` drops ids in `already` (live in this project). The dedicate flag in `all` comes only from `new`, so an already-live agent gets FOR SHARE and dedicate=false, and `if new.is_empty() && adopts.is_empty() { return Ok(vec![]) }` (project_members.rs:205) returns success. The gateway add_agents handler then answers 200 with ProjectDetail. AgentReq::join accepted the request because reset_workspace was true. Reachable today: a solo project creator's original agents are mixed (create_solo_project refuses dedicated), so POST /v1/projects/{p}/agents with {instance_id: a1, dedicated: true, reset_workspace: true} is a silent no-op, and a1 keeps taking private work. Impact is low. No data is lost (nothing is wiped), the response shows dedicated=false, and PATCH /v1/projects/{id}/agents/{instance} is the intended path.

- **verified_fix**:

  In place_agents, for a listed id that is in `already` with dedicate=true and whose space != Some(project), either run the dedicate path (free check, retire_workspace, revoke private grants) or return 409/422 pointing to PATCH /v1/projects/{id}/agents/{instance}. Leave the idempotent skip for agents already dedicated to this project.


## 14. GET /v1/project-invites previews always report mixed_agents_allowed=false（api-contract-tests，low → verified=False low）

- **id**: `invite-list-mixed-flag`，`crates/gateway/src/routes/project_invites.rs:40`
- **scenario**:

  With `mixed_project_agents = true` (reachable today through GatewayConfig in tests, and in any build that declares level 2), `GET /v1/project-invites/{id}` and `/resolve` report `mixed_agents_allowed: true`, but the invite list (`mine`, FFI `project_invites()`) reports false for the same invites. An App that drives the join UI from the list hides the mixed option.

- **evidence**:

  `get` and `resolve` wrap the preview in `with_config(&s, p)`. `mine` returns `projects::invites_for(...)` unchanged, and store `preview()` hard-codes `mixed_agents_allowed: false` (project_invites.rs:781).

- **fix**:

  Apply `with_config` to each item in `mine`, or pass the flag into the store preview.

- **verifier**:

  Not reachable today. server/src/config.rs:1064 refuses to start when api.mixed_project_agents is true while store::ISOLATION_LEVEL < 2, and ISOLATION_LEVEL is 1. In every deployable build, GatewayConfig.mixed_project_agents is false, so the hard-coded false from store preview (project_invites.rs:781) used by `mine` matches what `get` and `resolve` report. The mismatch can only appear in tests that set the gateway field directly, or in a future level-2 build. The plan defers the mixed path to level 2, and 8.16 leaves no hole reachable today.

- **verified_fix**:

  When level 2 lands, apply with_config to each item in `mine` (or pass the flag into the store preview) so all three endpoints agree.


## 15. application_name_is_versioned tests the TestDb connection options, not Db::connect（api-contract-tests，low → verified=True low）

- **id**: `appname-test-checks-harness`，`crates/store/src/tests/isolation.rs:360`
- **scenario**:

  If `.application_name(APPLICATION_NAME)` were removed from `Db::connect` (store/src/lib.rs:129), production connections would revert to `thinktin`. Operators would lose the advisory old-replica count that D11 plans for 8.17, and the test would still pass.

- **evidence**:

  TestDb builds its own pool with `.application_name(crate::APPLICATION_NAME)` (testing.rs:131) and never goes through `Db::connect`. The test reads `pg_stat_activity` on that pool, so it only confirms the harness setting it applied itself.

- **fix**:

  Build the test's Db with `Db::connect` against the test database URL (or a shared options helper used by both paths) and assert the name on that connection.

- **verifier**:

  Confirmed. TestDb::new builds its own pool with `.application_name(crate::APPLICATION_NAME)` (testing.rs:126-133) and wraps it with Db::from_pool, never calling Db::connect. application_name_is_versioned (isolation.rs:358-370) reads pg_stat_activity on that harness pool. Removing `.application_name(APPLICATION_NAME)` from Db::connect (lib.rs:124-131) would still pass. The second assertion only checks that the constant equals thinktin/i{ISOLATION_LEVEL}. Impact is minimal: D11 makes the name advisory only (the real fence is thinktin.isolation in Db::worker), and the old-replica count is 8.17 work.

- **verified_fix**:

  Have the test open a Db with Db::connect on the test database URL (or move the connect options into a shared helper used by both Db::connect and TestDb) and assert application_name on that connection.


## 16. Gateway tests skip several plan §6.5 negative cases (legacy body, PATCH 409, plan resume, join with a botin dedicated elsewhere)（api-contract-tests，low → verified=True low）

- **id**: `gateway-tests-missing-negatives`，`crates/gateway/tests/api.rs:5991`
- **scenario**:

  Regressions in these paths would go unnoticed: a legacy body handled leniently, PATCH on a busy botin returning something other than 409 conflict, `POST /v1/plans/{id}/resume` of a paused plan on a dedicated botin succeeding (it relies only on the plans_instance_space trigger), or join returning the wrong code for a botin dedicated elsewhere (see the finding above).

- **evidence**:

  `dedicated_botins_over_http` covers a missing or version-1 consent_version, the exactly-one rule, reset, 403/404/422 on PATCH, release, plan create and peer_access. There is no request with a legacy `instance_ids` body (plan: "a legacy instance_ids body gives 422"), no PATCH or join on a botin with an unfinished run (plan: "PATCH … 200 / 403 / 409 / 422"), and no plan resume or confirm on a dedicated botin (plan: "private message, plan create, plan resume … give 409"). Store test 4 (`dedicated_instances_refuse_private_work`) also omits queue_urgent_run, plan resume, step insert and replace_my_project_agents, which the plan lists.

- **fix**:

  Add these cases: pause a plan on X, dedicate X, then resume gives 409 instance_dedicated; queue a private run on X, then PATCH gives 409 conflict; a body with only instance_ids gives 422; join with a botin dedicated to another project gives 409 instance_dedicated.

- **verifier**:

  Confirmed as a coverage gap against plan §6.5 and §6.1 test 4. dedicated_botins_over_http (api.rs:5991-6275) has no accept with a legacy instance_ids-only body, no PATCH /v1/projects/{id}/agents/{instance} on a busy botin (409 conflict), no plan resume or PATCH on a dedicated botin, and no join with a botin dedicated to another project. The only 'dedicated elsewhere' case is POST /v1/projects/{p2}/agents into an unshared project. Store test dedicated_instances_refuse_private_work (isolation.rs:215-320) omits queue_urgent_run, plan resume, plan step insert and replace_my_project_agents. Reading the code, these paths behave correctly today. A missing 'agents' field fails JSON extraction with 422, and plan resume is refused by the plans_instance_space trigger (UPDATE OF status WHEN NEW.status='active'), which maps to InstanceDedicated. The exception is the join-elsewhere code, which returns agent_not_isolated (see the separate finding). So this is missing regression coverage, not a live defect.

- **verified_fix**:

  Add: pause a plan on X, dedicate X, then POST /v1/plans/{id}/resume gives 409 instance_dedicated; queue a private run on a project agent, then PATCH .../agents/{instance} gives 409 conflict; an accept body with only instance_ids gives 422; join with a botin dedicated to another project gives 409 (instance_dedicated once that finding is fixed). Extend store test 4 with queue_urgent_run, plan resume, step insert and replace_my_project_agents.


## 修复记录

- 0、3（流水线卡死）：`585d3f1` 标专属要等没走完的流水线（`free_instance_check`、迁移 0059 的触发器）；改坏检查发现 driver 里
  按 `InstanceDedicated` 映射没用（库里拒绝后事务已经作废，25P02），`a768085` 改成保存点里建授权和运行、只靠触发器判断。
- 2（搜索按主人保险箱查）：`585d3f1`，项目运行不查。
- 1、4、6（删实例和换工作区的锁顺序）：`585d3f1` 先锁出网请求；之后收成 `Tx<Tenant>::remove_instance`，加了锁的探测测试。
- 5（产出物工具用现在的沙箱）：`585d3f1`，运行结束或空间变了就拒绝。
- 7（换工作区和“一直允许”）：迁移 0059 给出网请求记工作区，`decide_egress_request` 核对；测试 19。
- 8、9、11、15、16、10（测试）：store `161a140`、编排 `1c67463`、控制面 `4cba131`、接口 `c7b6d2a`，之后逐个改坏规则核对。
- 12、13（加入时的错误码）：`585d3f1`。
- 14（邀请列表的混用标记）：2 级之前不可达，没改。
