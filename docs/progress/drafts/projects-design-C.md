<!-- 未评审的草稿（2026-10-29 设计评审的 design:C），见 docs/progress/claude-determined-lovelace-vn0j5h.md 的紧急交接 -->

# 项目与跨用户协作：实现方案（从“项目拥有内容、删密钥即销毁”出发）

> 状态：实现设计，2026-10-29，还没开工。产品设计见 [projects.md](projects.md)。第 1 节是用户定的；第 11 节按默认处理：预算内自动执行并通知主人，每个项目最多 10 个用户、30 个 agent，项目不能转让，项目模板不分享。同一用户之间的交流（8.9–8.12）见[架构方案](architecture-v3.md) 4.11。
> 角度：项目是共享内容的属主。项目建好就生成**项目密钥**（KMS 包裹的 DEK）。项目看板、项目产出物、项目工作区的归档都用它加密。运行的提示词、摘要、事件按“已拍板”的问题 9（[progress.md](progress.md):162）照旧明文存，但生命周期跟项目走：成员退出、注销时留下，项目删除时删掉。行号以分支 `claude/determined-lovelace-vn0j5h` 为准。

## 0. 结论

1. **新表**：`projects`、`project_members`、`project_agents`（成员都看得到的部分）、`project_agent_auth`（只有主人看得到的授权）、`project_keys`（只有 worker 能读写）、`project_templates`、`project_board_posts`（正文是密文）、`project_events`（项目动态）、`project_invites`、`user_blocks`、`scope_cleanups`、`project_workspace_archives`。
2. **团队变成单人项目**：迁移把 `teams` 复制成 `projects`，**沿用原来的 id**。`/v1/teams*`、`/v1/team-templates*` 和现有的 FFI 改成项目之上的兼容视图，字节级兼容，等两个 App 换成项目页（12.25/13.18）以后再删。
3. **读走 RLS，跨用户写走 worker**：
   - 成员关系用 `app_project_ids()` 判断。它是 `SECURITY DEFINER` 函数，读的 `project_members` 只 ENABLE 不 FORCE（照 0007 里 `blob_purge` 的先例），在生产环境的非超级用户属主下也成立。
   - `runs`、`events`、`artifacts` 上的 `tenant` 策略改成“自己的私人行，或自己还在的项目里的行”，另加一条只读的 `project_read`。
   - 跨用户的写（加入、移出、删除、替别人的 agent 建运行、看板、动态、通知）一律在 `Tx<Worker>` 里做，并且显式核对角色。
4. **按作用域收窄数据库可见范围**：新增 `Db::tenant_in(user, DataScope)`，设置 `app.project_scope`。
   - 私人运行里的平台工具看不到任何项目内容。
   - 项目 P 的运行里看不到主人的私人内容，也看不到别的项目。
   - 这一条在数据库层把第 6 节的“私人↔项目”两个方向都挡住。
5. **运行归 agent 的主人**：`runs.user_id` 是主人，花他的 key、记他的用量，审批推给他。`runs.project_id` 跟着父运行走，由触发器保证。运行树可以跨用户：`(parent_run_id, user_id)` 外键换成单列外键加触发器。
6. **项目授权**：每个（实例，项目）一个顶层授权，由主人签。范围 = 项目范围 ∩ 主人授权。委派、提问、流水线步骤的子授权都从**目标 agent 主人的项目授权**收窄而来，所以子授权的属主天然是主人，`run_grants` 的复合外键不用改。主人撤回 agent、全部停止时，现有的 `ancestors_usable!` 链就能把它们一起吊销。
7. **加密销毁**：
   - 项目密钥在建项目的同一个请求里生成。迁移来的团队由后台补发。补发和以后的任何生成都在项目行锁下核对状态，项目删了就不会再生成。
   - 删除分两步。第一个事务里：删密钥、成员一律标记退出、运行全部取消、授权全部吊销，这时内容已经立刻读不出、也看不到了。之后后台分批删掉明文行。
8. **贡献保留**：
   - 项目运行不跟着作者的账号走，成员注销时 `erase_account` 跳过他在别人项目里的运行。
   - 项目产出物和看板用项目密钥加密，作者的 DEK 销毁了照样读得出，满足第 4.5、10 节。
9. **会话和工作区**：
   - 每个（实例，项目）有自己的 HOME 和工作目录：`projects/<p>/home`、`projects/<p>/work`。私人工作目录挪到同级的 `private/`。
   - 撤回、退出、删除时进清理队列，跑运行之前或巡检时执行。
   - 分作用域归档以后（阶段 9），对象存储里的项目工作区也由项目密钥加密。
10. **等待环检测**：跨用户以后，按用户加锁已经挡不住环，改成全局一把咨询锁。
11. **项目动态有自己的序号**：写的时候不编号，读之前由“编号器”在一把锁下按提交顺序编号。热路径上不加锁，也不和实例行锁死锁。

## 1. 数据模型和迁移

### 1.1 `0031_projects.sql`：新表

```sql
-- 项目与跨用户协作（WBS 8.13、8.15）。设计见 docs/projects.md 和 docs/projects-impl.md。

CREATE TABLE projects (
    id          uuid PRIMARY KEY,                    -- 从团队迁来的沿用团队 id
    creator_id  uuid NOT NULL REFERENCES users (id), -- 用户行只标记删除、不真删（users.rs:183-231）
    name        text NOT NULL,
    goal        text NOT NULL DEFAULT '' CHECK (length(goal) <= 2000),
    status      text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived', 'deleted')),
    -- 项目给成员 agent 的范围（GrantScope）；NULL 是平台默认的项目范围（第 3.2 节）。
    scope       jsonb,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    archived_at timestamptz,
    deleted_at  timestamptz,
    purged_at   timestamptz,                          -- 后台把明文内容删完的时间
    CHECK ((status = 'deleted') = (deleted_at IS NOT NULL)),
    CHECK (status = 'deleted' OR length(name) BETWEEN 1 AND 64)
);
CREATE INDEX projects_creator ON projects (creator_id) WHERE status <> 'deleted';
CREATE INDEX projects_purge ON projects (deleted_at) WHERE status = 'deleted' AND purged_at IS NULL;

CREATE TABLE project_members (
    project_id   uuid NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
    user_id      uuid NOT NULL REFERENCES users (id),
    role         text NOT NULL CHECK (role IN ('creator', 'member')),
    display_name text NOT NULL DEFAULT '' CHECK (length(display_name) <= 64), -- 快照：成员读不到 users
    daily_tokens bigint CHECK (daily_tokens > 0),     -- 这个用户给自己的 agent 定的项目预算，NULL 不限
    total_tokens bigint CHECK (total_tokens > 0),
    consented_at timestamptz,                         -- 确认“项目内容会发给我的 agent 用的模型厂商”
    joined_at    timestamptz NOT NULL DEFAULT now(),
    left_at      timestamptz,
    left_reason  text CHECK (left_reason IN ('left', 'removed', 'erased', 'project_deleted')),
    PRIMARY KEY (project_id, user_id),
    CHECK ((left_at IS NULL) = (left_reason IS NULL))
);
CREATE UNIQUE INDEX project_one_creator ON project_members (project_id) WHERE role = 'creator';
CREATE INDEX project_members_user ON project_members (user_id) WHERE left_at IS NULL;

-- 成员都看得到的部分。名字、种类、用途是快照（成员读不到别人的 instances）。
CREATE TABLE project_agents (
    project_id       uuid NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
    instance_id      uuid NOT NULL,
    user_id          uuid NOT NULL,                   -- 主人
    is_lead          boolean NOT NULL DEFAULT false,
    dedicated        boolean NOT NULL DEFAULT false,
    position         integer NOT NULL DEFAULT 0,
    name             text NOT NULL DEFAULT '',
    agent_id         text NOT NULL,
    purpose          text NOT NULL DEFAULT '',
    computer_enabled boolean NOT NULL DEFAULT false,  -- 只给成员看开没开，具体授权在 project_agent_auth
    vault_enabled    boolean NOT NULL DEFAULT false,
    added_at         timestamptz NOT NULL DEFAULT now(),
    left_at          timestamptz,
    PRIMARY KEY (project_id, instance_id),
    -- 代替 team_members 的同一用户复合外键（0002:23-24）：主人是成员，实例是主人的。
    FOREIGN KEY (project_id, user_id) REFERENCES project_members (project_id, user_id),
    FOREIGN KEY (instance_id, user_id) REFERENCES instances (id, user_id)
);
CREATE UNIQUE INDEX project_one_lead ON project_agents (project_id) WHERE is_lead AND left_at IS NULL;
CREATE UNIQUE INDEX project_agents_dedicated ON project_agents (instance_id) WHERE dedicated AND left_at IS NULL;
CREATE INDEX project_agents_instance ON project_agents (instance_id) WHERE left_at IS NULL;

-- 只有主人看得到：保险箱条目名、预授权工具、审批超时、主人签的项目授权。
CREATE TABLE project_agent_auth (
    project_id            uuid NOT NULL,
    instance_id           uuid NOT NULL,
    user_id               uuid NOT NULL,
    allow_computer        boolean NOT NULL DEFAULT false,
    vault_items           text[] NOT NULL DEFAULT '{}',
    preauthorized_tools   text[] NOT NULL DEFAULT '{}',
    approval_timeout_secs integer NOT NULL DEFAULT 86400 CHECK (approval_timeout_secs BETWEEN 60 AND 604800),
    grant_id              uuid,
    PRIMARY KEY (project_id, instance_id),
    FOREIGN KEY (project_id, instance_id) REFERENCES project_agents (project_id, instance_id) ON DELETE CASCADE,
    FOREIGN KEY (grant_id, user_id) REFERENCES run_grants (id, user_id) ON DELETE SET NULL (grant_id)
);

-- 包裹后的项目 DEK。只有 worker 能读写；删掉这一行就是“删密钥即销毁”。
CREATE TABLE project_keys (
    project_id  uuid PRIMARY KEY REFERENCES projects (id) ON DELETE CASCADE,
    kms_key_id  text NOT NULL,
    wrapped_dek bytea NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- 团队模板改名：spec 还是 TeamTemplateSpec（按 agent 种类描述成员，领养时建实例），多一个 goal。
CREATE TABLE project_templates (
    id         uuid PRIMARY KEY,
    user_id    uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name       text NOT NULL,
    goal       text NOT NULL DEFAULT '' CHECK (length(goal) <= 2000),
    spec       jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, user_id)
);
```

### 1.2 现有表的改动（同一个迁移）

```sql
-- 都可空，上一版程序照常工作（docs/release.md 第 3 节）。
ALTER TABLE runs ADD COLUMN project_id uuid REFERENCES projects (id), ADD COLUMN initiated_by uuid;
ALTER TABLE events ADD COLUMN project_id uuid;            -- 分区表：自动加到各分区；随运行删，不加外键
ALTER TABLE artifacts ADD COLUMN project_id uuid REFERENCES projects (id);
ALTER TABLE approvals ADD COLUMN project_id uuid;
ALTER TABLE inbox_items ADD COLUMN project_id uuid, ADD COLUMN project_run_id uuid;  -- 给非主人的通知用，不加外键
ALTER TABLE outbox ADD COLUMN project_id uuid;
ALTER TABLE run_grants ADD COLUMN project_id uuid REFERENCES projects (id);
ALTER TABLE usage_records ADD COLUMN project_id uuid;
ALTER TABLE plans ADD COLUMN project_id uuid REFERENCES projects (id);

-- 运行树可以跨用户（只限项目里）：复合外键（0001:252）换成单列外键加触发器。
ALTER TABLE runs DROP CONSTRAINT runs_parent_run_id_user_id_fkey,
    ADD CONSTRAINT runs_parent_run_id_fkey FOREIGN KEY (parent_run_id) REFERENCES runs (id)
        ON DELETE CASCADE NOT VALID;
ALTER TABLE runs VALIDATE CONSTRAINT runs_parent_run_id_fkey;

CREATE FUNCTION check_run_project() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    p record;
BEGIN
    -- 项目运行只能跑在这个项目里、主人还没撤回的 agent 上，运行属于 agent 的主人。
    IF NEW.project_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM project_agents a
        WHERE a.project_id = NEW.project_id AND a.instance_id = NEW.instance_id
          AND a.user_id = NEW.user_id AND a.left_at IS NULL) THEN
        RAISE EXCEPTION 'instance % is not an agent of project %', NEW.instance_id, NEW.project_id
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.parent_run_id IS NULL THEN
        RETURN NEW;
    END IF;
    -- 按调用方的权限读：业务角色看不到的父运行当不存在。
    SELECT user_id, project_id INTO p FROM runs WHERE id = NEW.parent_run_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'parent run % not found', NEW.parent_run_id USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF p.project_id IS DISTINCT FROM NEW.project_id THEN
        RAISE EXCEPTION 'a child run belongs to its parent''s project' USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.project_id IS NULL AND p.user_id <> NEW.user_id THEN
        RAISE EXCEPTION 'a private child run belongs to its parent''s user' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER runs_project_check BEFORE INSERT OR UPDATE OF parent_run_id, project_id, user_id, instance_id
    ON runs FOR EACH ROW EXECUTE FUNCTION check_run_project();
```

另外两个触发器写法相同：

- **`run_grants` 的项目授权**：`run_grants_project_check`，带 `project_id` 的授权必须指向这个项目里主人还没撤回的 agent，`user_id` 必须是主人。
- **流水线步骤**：`plan_steps` 的 `(instance_id, user_id)` 外键（0002:67）换成 `instance_id → instances (id)`，再加 `plan_steps_check`。私人计划的步骤实例必须是计划属主的；项目计划的步骤实例必须是 `plans.project_id` 里没撤回的 agent。

其余复合外键都不用改，理由见第 3.1 节：`run_grants` 的父授权、`events`、`approvals`、`artifacts`、`live_activities`、`device_calls`。

迁移旧数据（只复制，旧表留到阶段 10，按“扩展—收缩”的规则，[release.md](release.md) 第 3 节）：

```sql
INSERT INTO projects (id, creator_id, name, created_at, updated_at)
    SELECT id, user_id, name, created_at, updated_at FROM teams;
INSERT INTO project_members (project_id, user_id, role, display_name, joined_at, consented_at)
    SELECT t.id, t.user_id, 'creator', coalesce(u.display_name, ''), t.created_at, t.created_at
    FROM teams t JOIN users u ON u.id = t.user_id;
INSERT INTO project_agents (project_id, instance_id, user_id, is_lead, position, name, agent_id, purpose,
                            added_at, left_at)
    SELECT m.team_id, m.instance_id, m.user_id, m.role = 'lead', m.position, i.name, i.agent_id, i.purpose,
           t.created_at, CASE WHEN i.state = 'deleted' THEN coalesce(i.deleted_at, now()) END
    FROM team_members m JOIN teams t ON t.id = m.team_id JOIN instances i ON i.id = m.instance_id;
INSERT INTO project_agent_auth (project_id, instance_id, user_id)
    SELECT project_id, instance_id, user_id FROM project_agents;
INSERT INTO project_templates (id, user_id, name, spec, created_at)
    SELECT id, user_id, name, spec, created_at FROM team_templates;
```

迁移来的项目这时还没有密钥，由第 4.1 节的补发任务生成。删了的实例迁成已撤回（`left_at`），所以 `project_one_lead` 不会出现“看不见的负责人占着位置”（调查提到的陷阱）。

`0032_project_indexes.sql`（第一行写 `-- no-transaction`，在已有的表上用 `CREATE INDEX CONCURRENTLY`）：

```sql
CREATE INDEX CONCURRENTLY runs_project ON runs (project_id, id DESC) WHERE project_id IS NOT NULL;
CREATE INDEX CONCURRENTLY artifacts_project ON artifacts (project_id, created_at DESC) WHERE project_id IS NOT NULL;
CREATE INDEX CONCURRENTLY run_grants_project ON run_grants (project_id, instance_id) WHERE project_id IS NOT NULL;
CREATE INDEX CONCURRENTLY inbox_project ON inbox_items (project_id, user_id) WHERE project_id IS NOT NULL;
CREATE INDEX CONCURRENTLY outbox_project ON outbox (project_id) WHERE project_id IS NOT NULL;
CREATE INDEX CONCURRENTLY usage_project ON usage_records (project_id, user_id, created_at) WHERE project_id IS NOT NULL;
CREATE INDEX CONCURRENTLY plans_project ON plans (project_id) WHERE project_id IS NOT NULL;
```

`events` 不建 `project_id` 索引：成员按运行读（已经有 `events_run (run_id, seq)`）；按项目删的时候随运行级联删。

### 1.3 团队、团队模板怎么映射，接口和 FFI 怎么保持兼容

| 老概念 | 新的存法 | `/v1/teams*` 兼容视图（`gateway/src/routes/teams.rs` 重写） |
|---|---|---|
| `Team{id,name,members,created_at}` | `projects` 里我建的、`active` 的；成员只列**我自己的**、没撤回的 agent | `list`：`creator_id = me`；我加入的别人的项目不出现，老 App 处理不了别人的 agent |
| `TeamMember{instance_id, role, position}` | `project_agents.is_lead` 对应 `lead`，`position` 照搬 | `role` 还是 `"lead"`/`"member"`（`TeamRole`），FFI 不变 |
| 新建团队 | 建单人项目（租户事务）→ 补项目密钥（worker） | 成员 1–12 个照旧（routes/teams.rs:16）。12 是老 App 的上限，项目本身的上限是 30 |
| 改团队（成员整体替换，teams.rs:88-112） | `Tx<Worker>::replace_own_project_agents(actor, project, members)`：只增删**调用者自己的** agent，别人的不动 | 按调用者的 agent 算差集：新增的签项目授权，去掉的走撤回（第 4.8 节） |
| 删团队 | 删项目（第 4.6 节，会销毁密钥） | 项目里还有别的成员时返回 409 `has_members`，免得老 App 一键删掉别人的贡献 |
| 团队模板 | `project_templates` | `/v1/team-templates*` 读写 `project_templates`。从团队生成模板（routes/teams.rs:133-142）只取**我自己的** agent |
| 按模板领养 | 一个租户事务里：领养实例（`control::adopt_in`），签实例授权，建项目和项目 agent | 和现在一样全成或全不成（routes/teams.rs:183-226）；密钥在提交后马上补，见第 4.1 节 |

为什么“建项目”允许走租户事务：`adopt_in` 只接受 `Tx<Tenant>`（control/src/lib.rs:216）。为了让按模板领养保持原子，建项目、建创建者成员行、加**自己的** agent 这三步开租户的 INSERT 策略（第 2.3 节）。其余的项目写操作都走 worker。

- **服务端**：`proto::domain::Team*` 保留，由 `store::teams` 从项目表拼出来。兼容路由和 `client-core` 的 `api.rs:1600-1696`、`ffi.rs:722-823/2418-2534` 不用改。`crates/client-core/tests/client.rs` 的 `ffi_teams_and_templates`、`gateway/tests/api.rs` 的 `teams_pipelines_and_artifacts` 原样通过，这是阶段 1 的验收条件之一。
- **委派**：私人运行里的委派保留现在的语义，等于老的团队。目标 = 这个实例当负责人的项目里、**和它同一个主人**、不是别的项目专属的 agent，子运行还是私人的（`project_id` 为 NULL）。`delegation_targets`（instances.rs:529-543）和 `is_team_lead`（instances.rs:546-556）改成读 `project_agents`，见第 6.2 节。
- **新的项目接口和 FFI** 和老的并排加（第 7.6、7.7 节）。两个 App 换成项目页以后，阶段 10 删老表、老路由。

### 1.4 后面几个阶段的迁移

| 编号 | 阶段 | 内容 |
|---|---|---|
| 0031 | 1 | 上面的表、列、触发器、策略、成员关系函数、数据迁移 |
| 0032 | 1 | 索引（不在事务里建） |
| 0033 | 3 | `project_board_posts` |
| 0034 | 4 | `scope_cleanups`、`instances.workspace_layout` |
| 0035 | 7 | `project_events`、`project_feed_heads` |
| 0036 | 8 | `project_invites`、`user_blocks` |
| 0037 | 9 | `project_workspace_archives` 和清理触发器 |
| 0038 | 10 | `-- deploy-safe` 删 `teams`、`team_members`、`team_templates` |

阶段 2、5、6 不需要新的表结构（列在 0031 里已经加好）。新的 `wait_code` 取值 `project_budget` 符合 0020 的格式约束，不用迁移。

## 2. 成员读路径和数据边界

### 2.1 原则

- **读**：一律经租户事务和 RLS。成员关系只用一个 `SECURITY DEFINER` 函数判断，策略里不直接子查询 `project_members`（避免递归和逐行开销）。
- **写**：
  - 业务角色只能写自己的行，而且只在建项目时写项目表。
  - 跨用户的写一律走 `Tx<Worker>` 上的 `store::projects` 函数。每个函数第一个参数是 `actor: UserId`，在同一个事务里锁住项目行，核对角色和状态。
  - worker 绕过 RLS，所以这里的 SQL 必须自己写上 `project_id = $1` 和成员关系条件（调查里 keys 一节的陷阱：worker 能解开任何 DEK）。
- **`instances` 和 `users` 不加成员可读的策略**：这两张表的整行都能读到，里面有 `phone`、`sandbox_address`、归档键之类的列（0001:466），一放开就是私人数据泄露。成员看到的名字、种类、用途都来自 `project_members` 和 `project_agents` 里的快照。

### 2.2 成员关系函数

```sql
-- 当前用户在哪些项目里（没退出；项目删除时成员一律标记退出，所以不用再连 projects）。
-- app.project_scope：空 = 全部（App 和接口用）；'private' = 一个都不算；项目 id = 只算这一个。
-- 属主不受 project_members 的 RLS 约束（只 ENABLE 不 FORCE，照 0007 的 blob_purge），生产环境的
-- thinktin_owner 不是超级用户也成立。不接受 user 参数，免得被拿来探测别人的成员关系。
CREATE FUNCTION app_project_ids() RETURNS uuid[]
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    AS $$
    SELECT coalesce(array_agg(m.project_id), '{}'::uuid[])
    FROM public.project_members m
    WHERE m.user_id = public.app_user_id()
      AND m.left_at IS NULL
      AND CASE coalesce(current_setting('app.project_scope', true), '')
            WHEN '' THEN true
            WHEN 'private' THEN false
            ELSE m.project_id::text = current_setting('app.project_scope', true)
          END
$$;
ALTER FUNCTION app_project_ids() COST 1000;
REVOKE ALL ON FUNCTION app_project_ids() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app_project_ids() TO thinktin_app;

-- 私人内容在这个事务里看不看得到：项目作用域里看不到（普通 SQL 函数，规划器能内联）。
CREATE FUNCTION app_private_visible() RETURNS boolean
    LANGUAGE sql STABLE
    AS $$ SELECT coalesce(current_setting('app.project_scope', true), '') IN ('', 'private') $$;
GRANT EXECUTE ON FUNCTION app_private_visible() TO thinktin_app;
```

- 策略里一律写成 `= ANY ((SELECT app_project_ids()))`。外面包一层标量子查询，它就成了每条语句只算一次的 InitPlan。`SECURITY DEFINER` 函数不会被内联，要是逐行调用，事件、运行树这些查询会撞上 15 秒的租户超时。
- 必须是 `STABLE`，不能是 `IMMUTABLE`：sqlx 按连接缓存语句，而 `app.user_id` 每个事务都会变。

### 2.3 策略（风险最大的部分）

```sql
-- 运行、事件、产出物：同一套。
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['runs', 'events', 'artifacts'] LOOP
        EXECUTE format('DROP POLICY tenant ON %I', t);
        -- 自己的行：私人的只在私人可见时；项目的只在自己还在这个项目里时（退出即不可见，包括自己 agent 的项目运行）。
        EXECUTE format($p$CREATE POLICY tenant ON %I TO thinktin_app
            USING (user_id = app_user_id()
                   AND ((project_id IS NULL AND app_private_visible())
                        OR project_id = ANY ((SELECT app_project_ids()))))
            WITH CHECK (user_id = app_user_id()
                   AND ((project_id IS NULL AND app_private_visible())
                        OR project_id = ANY ((SELECT app_project_ids())))) $p$, t);
        -- 成员读别人在项目里的运行、事件、产出物：只读（宽松策略是“或”的关系，写照旧只能写自己的）。
        EXECUTE format($p$CREATE POLICY project_read ON %I FOR SELECT TO thinktin_app
            USING (project_id = ANY ((SELECT app_project_ids()))) $p$, t);
    END LOOP;
END $$;

-- 项目：成员、创建者看得到；只有创建者能建，能改名字和目标。
ALTER TABLE projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE projects FORCE ROW LEVEL SECURITY;
CREATE POLICY member_read ON projects FOR SELECT TO thinktin_app
    USING ((creator_id = app_user_id() AND app_private_visible()) OR id = ANY ((SELECT app_project_ids())));
CREATE POLICY creator_insert ON projects FOR INSERT TO thinktin_app
    WITH CHECK (creator_id = app_user_id() AND status = 'active');
CREATE POLICY creator_update ON projects FOR UPDATE TO thinktin_app
    USING (creator_id = app_user_id() AND status = 'active')
    WITH CHECK (creator_id = app_user_id() AND status = 'active');

-- 成员：只 ENABLE 不 FORCE（成员关系函数的属主要能读它）。业务角色只能插“自己是创建者”的那一行。
ALTER TABLE project_members ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON project_members FOR SELECT TO thinktin_app
    USING (project_id = ANY ((SELECT app_project_ids())));
CREATE POLICY creator_insert ON project_members FOR INSERT TO thinktin_app
    WITH CHECK (user_id = app_user_id() AND role = 'creator' AND left_at IS NULL
                AND EXISTS (SELECT 1 FROM projects p WHERE p.id = project_id AND p.creator_id = app_user_id()));
CREATE POLICY own_budget ON project_members FOR UPDATE TO thinktin_app
    USING (user_id = app_user_id() AND project_id = ANY ((SELECT app_project_ids())))
    WITH CHECK (user_id = app_user_id() AND left_at IS NULL);

-- 项目 agent：成员看得到；业务角色只能在自己建的、进行中的项目里加自己的实例（复合外键保证实例是自己的）。
ALTER TABLE project_agents ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_agents FORCE ROW LEVEL SECURITY;
CREATE POLICY member_read ON project_agents FOR SELECT TO thinktin_app
    USING (project_id = ANY ((SELECT app_project_ids())));
CREATE POLICY creator_insert ON project_agents FOR INSERT TO thinktin_app
    WITH CHECK (user_id = app_user_id() AND left_at IS NULL
                AND EXISTS (SELECT 1 FROM projects p WHERE p.id = project_id
                              AND p.creator_id = app_user_id() AND p.status = 'active'));

-- 主人自己的授权：别的成员（包括创建者）看不到保险箱条目名。
ALTER TABLE project_agent_auth ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_agent_auth FORCE ROW LEVEL SECURITY;
CREATE POLICY own ON project_agent_auth TO thinktin_app
    USING (user_id = app_user_id() AND project_id = ANY ((SELECT app_project_ids())))
    WITH CHECK (user_id = app_user_id() AND project_id = ANY ((SELECT app_project_ids())));

-- 只有后台能碰：没有业务角色的策略，也不授权（双保险，同 0001:449-454 的 user_keys）。
ALTER TABLE project_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_keys FORCE ROW LEVEL SECURITY;

-- project_templates：和 team_templates 一样按 user_id（照搬 0002:95-105）。

GRANT SELECT, INSERT ON projects, project_members, project_agents, project_agent_auth TO thinktin_app;
GRANT UPDATE (name, goal, updated_at) ON projects TO thinktin_app;
GRANT UPDATE (daily_tokens, total_tokens) ON project_members TO thinktin_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON project_templates TO thinktin_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON projects, project_members, project_agents, project_agent_auth,
    project_keys, project_templates TO thinktin_worker;
GRANT SELECT (project_id, user_id, daily_tokens, total_tokens, left_at) ON project_members TO thinktin_llmgw;
```

要注意的几点：

- **建项目时的写法**：建创建者那一行的 `INSERT` **不能带 `RETURNING`**。成员关系函数用的是这条语句开始时的快照，`RETURNING` 要求新行通过 SELECT 策略，会报错。后面加 agent 的 `INSERT … RETURNING` 没问题：前一条语句写的行，下一条语句的快照里看得到。
- **授权和审批**：`run_grants`、`approvals` 的 `tenant` 策略不改，只有主人看得到。成员退出时，他的项目审批在退出流程里删掉（第 4.8 节）。
- **收件箱、出箱**：`inbox_items`、`outbox` 只属于收件人，不加成员可读的策略。
- **关于 FORCE**：`project_members` 是 ENABLE 不 FORCE，所以表的属主（迁移账号）不受 RLS 约束。这和 FORCE 的本意（防止迁移账号误用）有冲突，代价是迁移账号能读到成员关系。这和 `blob_purge` 是同一类取舍。覆盖测试把这两张表列成白名单（第 2.6 节）。

### 2.4 作用域：`Db::tenant_in`

```rust
/// 租户事务看得到哪些内容（8.15）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DataScope {
    /// App 和接口：自己的私人内容，加上自己还在的全部项目。
    All,
    /// 私人运行里的平台工具：只有私人内容，项目的一概看不到（项目内容不带回私人会话）。
    Private,
    /// 项目运行里的平台工具：只有这个项目的内容，主人的私人内容也看不到（私人内容不带进项目）。
    Project(ProjectId),
}

impl Db {
    pub async fn tenant(&self, user: UserId) -> Result<Tx<Tenant>> { self.tenant_in(user, DataScope::All).await }
    /// 多设一个事务级的 app.project_scope（和 app.user_id 一样提交或回滚时清掉）。
    pub async fn tenant_in(&self, user: UserId, scope: DataScope) -> Result<Tx<Tenant>>;
}
```

`ToolContext`（shim.rs:66-72）加 `project: Option<ProjectId>`，在 executor.rs:924 由 `rec.run.project_id` 填。再加 `fn data_scope(&self) -> DataScope`。这些平台工具把 `db.tenant(ctx.user)` 换成 `db.tenant_in(ctx.user, ctx.data_scope())`：

- board.rs:59/90
- ask.rs:65
- peers.rs:47/92
- delegate.rs:45
- vault.rs:46/111
- tools.rs 的计划工具

这一步也修掉调查里提到的陷阱：B 进了项目以后，他私人运行里的 `agent_status`、`recent_run_events` 会读到项目运行。`Tx<Tenant>` 的 `Tenant` 结构多记一个 `scope` 字段，供调试和断言用。

### 2.5 成员能读到别人的运行以后，现有接口的行为

| 接口 | 成员 B 读 A 的项目运行时会怎样 | 处理 |
|---|---|---|
| `GET /v1/runs/{id}`、`/tree`、`/artifacts`、`/v1/artifacts/{id}`、`/content` | 经 `project_read` 能读 | 就是要这样。`content` 按 `project_id` 用项目密钥解密（第 4.2 节） |
| `POST /v1/runs/{id}/cancel`（routes/runs.rs:185-221） | `cancel_run` 的 `SELECT … FOR NO KEY UPDATE` 要过 UPDATE 策略。B 锁不到 A 的行，得到 RowNotFound，也就是 404，不会变成 500 | 先读 `run.project_id`：项目运行而且不是自己的，走 `Tx<Worker>::cancel_project_run(actor, run, tree)`，显式核对权限（第 3.6 节） |
| `cancel?tree=true`（runs.rs:557-580 的 `cancel_run_tree`） | 混合属主的树只会取消调用者自己的行 | 项目树一律走上面那个 worker 函数 |
| `/v1/instances/{id}/events*`、`/runs`、`/artifacts` | `t.instance(id)` 这道门挡住了别人的实例 | 不放开。成员走项目路由（第 7.6 节） |
| `/v1/runs`（`list_runs`，runs.rs:482） | 写死了 `user_id = app_user_id()` | 照旧：主人的列表里有自己 agent 的项目运行，退出后看不到 |
| `POST /v1/reports` | `reports.rs` 经 RLS 读运行、事件、产出物 | 成员能举报项目内容，快照记在举报人名下 |
| `ensure_instance_grant`（runs.rs:77） | 项目授权也是顶层授权，会被当成实例授权 | 过滤条件加 `project_id.is_none()`。`active_grant_for_instance`（grants.rs:303-315）也加 `AND project_id IS NULL`，不然私人运行会拿到项目授权，反过来也一样 |
| `peers()`（instances.rs:500-527）的“忙不忙” | `Private` 作用域下看不到项目运行，会把“正在做项目”误报成空闲 | “忙不忙”改由 worker 的 `instance_holder_states(&ids)` 返回，只给状态、不给任务 |
| 以后像 0024–0026 那样往授权里补工具的迁移 | 会把保险箱、电脑工具补进项目授权 | 约定写上 `AND project_id IS NULL`，记进 release.md |

### 2.6 测试（阶段 1 就做）

`crates/store/src/tests.rs`：

- `projects_are_isolated`：三个用户。B 用 worker 的 `add_project_member` 直接造成成员，C 是外人。
  - B 读得到 A 的项目运行、事件、产出物，读不到 A 的私人运行、实例、用户行。
  - C 一行都读不到。
  - B 伪造 `project_id` 去写运行、项目 agent，被 WITH CHECK 拒绝。
  - B 退出后立刻什么都读不到，包括他自己 agent 的项目运行。
- `data_scope_limits_what_tools_see`：`Private` 作用域下看不到自己的项目运行；`Project(P)` 下看不到私人运行，也看不到项目 Q。
- `membership_works_under_production_ownership`：建一个 `NOSUPERUSER NOBYPASSRLS` 的临时角色，把这次测试库里所有表和函数的属主换给它，再以 `thinktin_app` 验证成员关系照样生效。结束时 `REASSIGN OWNED` 并删掉这个角色。TestDb 是超级用户，平时测不到这种情况（testing.rs:18-44、setup-db.sh:16-18）。
- 扩展 `every_tenant_table_the_app_can_touch_has_rls`（tests.rs:764-816）：
  - 检查范围从“有 `user_id` 列的表”改成“业务角色能碰的所有表”。
  - 要求 `relforcerowsecurity`，白名单只有 `project_members`、`blob_purge`。
  - 每个 `SECURITY DEFINER` 函数必须带 `search_path`，并且 `PUBLIC` 不能执行。
  - 不能有 `USING (true)` 的策略。
- `run_tree_rules`：触发器拒绝跨项目的父子运行、跨用户的私人子运行、不在项目里的实例。

`gateway/tests/api.rs`：`other_users_objects_are_invisible`（1680 行起）加上项目路由，外人访问一律 404。

## 3. 跨用户的运行

### 3.1 运行树

| 运行 | `user_id`（谁付钱、审批找谁） | `project_id` | `run_grant_id` | `plan_id` |
|---|---|---|---|---|
| 创建者在 App 里给项目下的任务（`POST /v1/projects/{id}/tasks`，默认交给负责人） | 目标 agent 的主人；`initiated_by` 记创建者 | P | 目标的项目授权 | NULL |
| 负责人委派 | 目标 agent 的主人 | 跟父运行（触发器保证） | 从目标的项目授权收窄（第 3.2 节） | NULL（不再沿用父运行的，delegate.rs:164） |
| 项目里提问 | 回答方的主人 | 跟父运行 | 从回答方的项目授权收窄（不再是 NULL，ask.rs:149） | NULL |
| 流水线的根（kind=pipeline） | 创建者，挂在创建者自己的一个项目 agent 上 | P | 计划的授权 | 项目计划 |
| 流水线的步骤 | 这一步 agent 的主人 | P | 从这一步 agent 的项目授权收窄 | NULL（用到计划时去根运行上找，HandoffCopier 也一样） |

- **不用改的复合外键**：子授权的属主是目标主人，所以 `run_grants (parent_id, user_id)`（0001:172）照样成立。运行的属主就是实例和授权的属主，所以 `(instance_id, user_id)`、`(run_grant_id, user_id)` 也照样成立。事件、审批、产出物都写在运行自己的实例上，和运行同一个属主。真正跨用户的只有“父运行”这一条，第 1.2 节的触发器管它。
- **删除级联**：
  - 运行只会在两种情况下被删：注销时 `erase_account` 删**私人**运行，删项目后后台清理。所以跨用户的级联只会发生在同一个项目里。
  - 成员注销时，他的项目运行**留着**，不会连带删掉别人的子运行。
- **语言**：委派、提问发给 agent 的平台说明，用目标主人的语言（delegate.rs:155、ask.rs:103 现在用的是 `ctx.user` 的）。负责人的标签改成快照名加主人的显示名，例如“小周的 Claude”，不再只写 `agent_id`（delegate.rs:144-148、texts.rs:426-438）。
- **执行器交还子运行结果**：给子运行起名用 worker 读 `project_agents` 的快照，不再用 `tenant(rec.user_id).instance(child)`（executor.rs:799-818，别人的实例会是空名字）。结果正文按不可信输入包装（第 9 节）。

### 3.2 项目授权：范围取交集，主人能吊销

```rust
impl GrantScope {
    /// 两个范围的交集（项目给的 ∩ 主人给的）。别名为空表示“实例配置的全部”：一边为空取另一边；
    /// token 上限取小的。
    pub fn intersect(&self, other: &GrantScope) -> GrantScope;
}

/// 平台默认的项目范围：默认平台工具里去掉计划工具（SCHEDULE_TOOLS）和 vault_request；
/// vault_list 和电脑工具留在项目范围里，但只有主人打开了才进主人的范围。
pub fn project_scope(default_platform_tools: &[String]) -> GrantScope;

impl Tx<Worker> {
    /// 主人签（或重签）他的 agent 在这个项目里的授权：顶层、带 project_id，
    /// 范围 = projects.scope（或 project_scope）∩ 主人的授权（project_agent_auth），旧的吊销。
    pub async fn issue_project_grant(&mut self, owner: UserId, project: ProjectId, instance: InstanceId,
                                     project_scope: &GrantScope, ttl: Duration) -> Result<RunGrant>;
    /// 项目子运行的授权：父授权是目标 agent 的项目授权，范围 = 它的范围 ∩ 发起方运行的授权范围
    /// （权限不放大），有效期不超过它。属主就是目标主人。
    pub async fn create_project_child_grant(&mut self, target_grant: GrantId, caller_grant: GrantId,
                                            ttl: Duration) -> Result<RunGrant>;
}
```

- **主人吊销**：撤回 agent、退出、全部停止都会吊销项目授权。所有子授权经 `ancestors_usable!`（grants.rs:46-55）一起失效，模型网关和 `touch_run_grant` 都按它判断。还要把这个实例的 `token_epoch` 加一，让已经发出去的沙箱令牌马上作废（调查 money 一节的陷阱：网关缓存的授权状态最多要等 `cache_secs` 才更新）。
- **负责人一侧失效**：父运行结束或被取消时停掉子孙（`cancel_descendants`）。不需要把负责人的授权当成第二个祖先。
- **沙箱令牌**：`auth::GrantService::sandbox_token`（auth/src/grants.rs:105-163）在授权带 `project_id` 时多核对三件事：项目是 `active`，agent 没撤回，主人没退出。否则签不出令牌，运行按失败结束。
- **执行器的回退**：项目运行没有 `run_grant_id` 时，用 `project_agent_auth.grant_id`，**绝不**回退到 `active_grant_for_instance`（executor.rs:739-746）。

### 3.3 预算按主人分开记

| 在哪里查 | 查什么 | 改动 |
|---|---|---|
| **模型网关，请求发出去之前**（准，靠这里保证“不会花超”） | 主人在这个项目里当天、累计用了多少 token | `PgDirectory::load_grant`（pg.rs:159-167）和 `usable_grant_aliases`（llmgw.rs:98-114）一并取出授权的 `project_id`、`user_id`，以及 `project_members` 里的预算。`attempt`（proxy.rs:936 起）在按 key 查每日预算（958-965）之后，再用 `BudgetLedger` 查键 `project/<p>/<user>` 的当天用量，累计用量按 `usage_records(project_id, user_id)` 求和（缓存，和 `PgLedger` 一样）。超了就返回新的结果类型 `project_budget`。用量记录写上 `project_id` |
| **执行器续租时**（兜底） | 运行树里同一个主人的用量 | `on_renew`（executor.rs:2325）把 `tree_tokens_except`（runs.rs:1048）换成 `tree_tokens_except_for_owner(root, except, owner)`。跨主人的子运行不继承根运行的 `max_tokens`（只继承时长和步数，delegate.rs:168、pipeline.rs:261 改）。`waits.rs` 认出 `project_budget`，转入等额度，`wait_code = "project_budget"`，并通知主人。主人调高预算以后 `wake_waiting_runs` |

按天切分用模型网关的 `budget_utc_offset_secs`，和按 key 的每日预算一致。

### 3.4 审批和执行策略

- **审批找谁**：审批推给 `rec.user_id`，也就是主人（executor.rs:2052-2128），不用改。审批和通知上带 `project_id`，App 用来标注和过滤。
- **策略从哪来**：项目运行的执行策略不从 `plan_id` 读（executor.rs:759；子运行读到的会是根运行的计划，也就是创建者的计划）。改成 `Tx<Worker>::project_run_policy(project, instance)`：
  - 预授权工具 = 主人在 `project_agent_auth.preauthorized_tools` 里设的（默认为空）。创建者的 `"*"` 不会变成别人 agent 的 `allow_tools`。
  - 审批超时 = 主人设的。超时动作只有“拒绝”和“失败”，**没有** `PausePlan`（executor.rs:2187），不会去暂停别人的计划。
- 项目运行不推“成功”通知，结果在项目通知里，见第 7.4 节。

### 3.5 电脑和保险箱

| 能力 | 私人运行（不变） | 项目运行 |
|---|---|---|
| 电脑工具 | `has_computer(rec.user_id)` 并且在授权范围里（executor.rs:796-797、833-845） | 还要 `project_agent_auth.allow_computer`。这个开关决定主人的范围里有没有电脑工具 |
| `vault_list` 和取用保险箱条目 | 条目的 `instance_ids` 为空表示全部实例都能用（store/vault.rs:391-411） | 只能用 `vault_items` 里列出的名字；“为空表示全部”这条在项目里**不适用** |
| `vault_request` | 有 | 没有：不在项目范围里。别的用户的内容不能借它给主人推送表单 |
| 计划工具 | 有 | 没有：项目里建出来的私人计划会比成员关系活得久（调查 money 一节的陷阱） |

主人改开关时重签项目授权，正在跑的运行在下次换令牌时生效。“随时可以关”时，重签的同时把令牌代数加一，马上生效。

### 3.6 打断、全部停止、冻结

- **谁能打断项目运行**：`Tx<Worker>::cancel_project_run(actor, run, tree: bool)` 放行三种人：
  - 创建者：项目里的任何项目运行。
  - 运行的主人：自己的运行和它的子孙，子孙可以是别人的 agent，因为是他的运行要的。
  - 其他人：404。

  这个函数先锁运行树、令牌代数加一、再取消（照 runs.rs:557-580 的顺序），事件写在各自的实例上。
- **负责人打断成员**（4.11 里还没做的那一条）：负责人在项目运行里多一个 `delegate_cancel(run_id)` 工具，只能取消自己委派出去的子运行和它的子孙。
- **主人自己的紧急消息**：照 8.12 处理，可以打断自己 agent 正在跑的项目运行，第 7 节允许。新消息开头的说明在私人和项目作用域之间**不引用对方的任务标题**（executor.rs:780-794 加一个条件：两边的 `project_id` 不一样时用通用说法）。
- **全部停止**（account.rs:91-112）：
  - 成员：现有的 `cancel_user_runs`、`revoke_user_grants` 已经把他的项目运行和项目授权都停掉、吊销了。agent 在项目里显示“已停止”，主人下次在项目里重新打开时重签授权。
  - 创建者：另外取消他建的项目里**所有**还没结束的项目运行，包括别人 agent 正在替项目干的活。别人的授权不吊销。这一条需要用户确认，见第 9 节。
- **冻结**：`claim_next_run` 按 `users.status` 跳过被冻结的用户（runs.rs:872），只影响他自己 agent 的运行。

## 4. 项目密钥、项目内容、删除和注销

### 4.1 项目密钥

- **KMS 的上下文**：
  - 现有的 `Kms` 接口（keyvault/lib.rs:64-70）照旧用字符串上下文，项目的写成 `project:<uuid>`。用户的上下文是裸 UUID，永远不会以 `project:` 开头，所以不会撞上。
  - `AliyunKms::context()`（aliyun/src/kms.rs:39-41）按前缀分：项目的生成 `{"purpose":"thinktin-project-dek","project":"<uuid>"}`。用户的格式**一个字节都不改**，不然存着的用户 DEK 全都解不开。
- **`KeyVault`**：加一组按“域”区分的通用接口。新增三个域：`thinktin/project-blob/v1/`、`thinktin/project-board/v1/`、`thinktin/project-workspace/v1/`，AAD 里的属主就是 `project:<uuid>`。用户密文和项目密文换不了位置，要挪动只能重新加密。

  ```rust
  pub enum Domain { Blob, ProjectBlob, ProjectBoard, Workspace, ProjectWorkspace }
  pub async fn seal_in(&self, domain: Domain, owner: &str, object_id: &str, plain: &[u8]) -> Result<Vec<u8>>;
  pub async fn open_in(&self, domain: Domain, owner: &str, object_id: &str, sealed: &[u8]) -> Result<Vec<u8>>;
  ```

  再加一个 `Error::NoProjectKey(String)`。不复用 `NoUserKey`：outbox.rs:671-676 会把 `NoUserKey` 当成“账号已注销”。

- **`orchestrator::artifacts`** 加：

  ```rust
  pub enum KeyUse { Read, Write }
  /// 项目的 DEK，包成只含这个项目的密钥库。Write：没有就生成，但只在项目行锁下、项目没删时插入
  /// （先找 KMS 包好，再开 worker 事务 SELECT … FOR UPDATE，核对状态、没有密钥才插）；Read：没有就是 NoProjectKey。
  pub async fn project_vault(db: &Db, kms: Arc<dyn Kms>, project: ProjectId, use_: KeyUse)
      -> Result<KeyVault<Arc<dyn Kms>, MemoryKeyStore>, ArtifactError>;
  ```

- **什么时候生成**：
  - 建项目的请求在租户事务提交后马上调 `project_vault(.., Write)`。
  - 维护循环里的 `ensure_project_keys` 给迁移来的项目和上一步失败的项目补发。
  - 所有写密文的地方（发布产出物、写看板、归档工作区）都用 `Write`，所以就算补发还没轮到也照样能写。
  - 因为生成一定在行锁下核对 `status <> 'deleted'`，删除以后不会再生成新密钥（调查 keys 一节的陷阱：`insert_user_key` 不查用户状态，users.rs:163-176）。
- **存储层**：`Tx<Worker>::insert_project_key`、`impl<R: Internal> Tx<R>::project_key`，对照 users.rs:163-176、276-285。
- **加密不是权限边界**：worker 能解开任何密钥。谁能读什么只由第 2 节决定。

### 4.2 项目产出物

- **存在哪**：还是 `artifacts` 表，多一列 `project_id`。运行树里的名字空间、版本号和上限不变（store/artifacts.rs:104-141），提问一方看得到回答方的范围这套规则也不变。原因是项目运行跟着项目活，不会因为作者注销被级联删掉（第 4.9 节），所以没必要另建一张表。
- **发布**（orchestrator/artifacts.rs:280-338）：
  - `Origin` 加 `project: Option<ProjectId>`，由 `ArtifactTools::origin`（tools.rs:477-499）从 `ToolContext.project` 填。
  - 项目运行用 `project_vault(p, Write)` 加密，属主写 `project:<p>`，对象键是 `projects/<p32>/artifacts/<a32>`（现在是 `<user32>/<a32>`，第 300 行）。
  - 登记索引的事务里，`SELECT status FROM projects WHERE id = $p FOR SHARE` 必须是 `active`。`insert_artifact` 用 `(SELECT project_id FROM runs WHERE id = $run)` 核对，必须和 `Origin.project` 一致，不一致就失败，内容照 330-337 行删掉，不留孤儿。
  - 文本类内容加密前先用发布方主人的保险箱抹一遍（看板已经这样做，board.rs:85-89；产出物现在没有）。
- **读取**（341-347）：按 `a.project_id` 分支，项目的产出物**绝不**退回去用用户 DEK。读到时项目已经删了，得到 `NoProjectKey`，接口返回 404，平台工具说“这个产出物已经不在了”。
- **删除**：作者的主人（还在项目里时，经租户策略）或者创建者（worker 路径）。应用角色从来写不了 `blob_key`，所以 `queue_artifact_blob_purge`（0007:40-48）照旧安全。
- **列出**：`Tenant::project_artifacts(project, before, limit)`，每棵树里每个名字只取最新版本。平台工具 `artifact_list` 在项目运行里多一个参数 `scope: "project"`，可以列整个项目空间。

### 4.3 项目看板（`0033_project_board.sql`）

```sql
CREATE TABLE project_board_posts (
    id                 uuid PRIMARY KEY,                 -- UUIDv7
    project_id         uuid NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
    author_user_id     uuid,                             -- 作者的主人或用户本人；用户行不真删
    author_instance_id uuid,
    author_label       text NOT NULL DEFAULT '',         -- 快照（实例名或显示名），注销时清空
    run_id             uuid REFERENCES runs (id) ON DELETE SET NULL,
    by_agent           boolean NOT NULL,
    sealed             bytea NOT NULL,                   -- 正文用项目密钥加密（AAD = 项目 + 条目 id）
    tags               text[] NOT NULL DEFAULT '{}' CHECK (cardinality(tags) <= 8),  -- 明文：按标签读
    mentions           uuid[] NOT NULL DEFAULT '{}' CHECK (cardinality(mentions) <= 10),
    created_at         timestamptz NOT NULL DEFAULT now(),
    archived_at        timestamptz,
    revived_at         timestamptz
);
CREATE INDEX project_board_live ON project_board_posts (project_id, id DESC) WHERE archived_at IS NULL;
CREATE INDEX project_board_archived ON project_board_posts (project_id, id DESC) WHERE archived_at IS NOT NULL;
ALTER TABLE project_board_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_board_posts FORCE ROW LEVEL SECURITY;
CREATE POLICY member_read ON project_board_posts FOR SELECT TO thinktin_app
    USING (project_id = ANY ((SELECT app_project_ids())));
GRANT SELECT ON project_board_posts TO thinktin_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON project_board_posts TO thinktin_worker;
```

- **为什么另建一张表，不给 `board_posts` 加列**：
  - `board_posts.body` 是长度 1–2000 的明文（0025:6-25），而这里要存密文。
  - `board_posts` 按 `user_id` 隔离，注销时整块删掉（users.rs:222）。
  - 它有 `(instance_id, user_id)`、`(run_id, user_id)` 的复合外键，跨用户写不了。

  私人看板保持原样。
- **写**：`Tx<Worker>::post_to_project_board`，平台工具和 App 都走它。
  - 加咨询锁 `board/project/<id>`，条数上限照 `MAX_BOARD_LIVE_POSTS`，满了自动归档。
  - 在同一个事务里 `FOR SHARE` 核对项目是 `active`，并且作者是成员。
  - 写之前用作者主人的保险箱抹一遍。
- **读**：一次取一把 DEK，最多解 50 条。
- **在 agent 眼里**：在项目运行里，`board_read`、`board_post` **就是项目看板**。私人看板在项目运行里看不到，项目看板在私人运行里也看不到。
- **作者显示**：
  - 作者的主人退出了：“已退出的成员”。
  - 注销了：“已注销的用户”。
  - 实例撤回了：快照名后面加“（已撤回）”。

  这些都由 `project_members.left_reason` 和 `project_agents.left_at` 推出来。
- **删除和归档**：作者的主人（还在项目里时）和创建者可以。

### 4.4 运行的提示词、摘要、事件为什么不加密

| 方案 | 结论 |
|---|---|
| 用项目密钥加密 `runs.prompt/summary/error/state_reason`、`events.payload` | **不做**。问题 9 已经定了对话、提示词、摘要不整体加密。读这些字段的地方很多：`open_ask` 在 SQL 里按 prompt 相等比较（runs.rs:1074-1094），续跑简报，查进度（peers.rs），交还子运行结果，接口的列表和事件流，举报快照。全都要改成在 Rust 里解密，换来的效果和“删行”在活库里一样 |
| 复制一份到项目表 | 只复制**元数据**到项目动态（`project_events`），给项目页用游标。正文不复制，复制只会多一份要删的东西 |
| **删除** | **采用**：项目删除时，第一个事务就让它们不可见（成员一律标记退出），后台再分批 DELETE。和注销“删 DEK + 删明文行”是同一个做法（users.rs:183-231） |

剩下的风险写进合规文档（compliance.md 第 5 节）：数据库备份和时间点恢复里的明文要等保留期过了才消失。这和注销现在的情况完全一样。项目密钥那一行也在备份里，所以“删密钥即销毁”对备份同样要等保留期。

### 4.5 内容去向总表

| 内容 | 存在哪 | 怎么加密 | 成员退出或被移出 | 成员注销 | 项目删除 |
|---|---|---|---|---|---|
| 项目名、目标 | `projects` | 明文 | 留 | 留 | 清空，只留墓碑 |
| 项目看板 | `project_board_posts.sealed` | **项目密钥** | 留，作者显示“已退出的成员” | 留，作者快照清空 | **删密钥**，后台删行 |
| 产出物内容 | 对象存储 `projects/<p>/artifacts/` | **项目密钥** | 留 | 留，不受作者的 DEK 影响 | **删密钥**，行删掉后排进 `blob_purge` |
| 产出物索引 | `artifacts`（带 `project_id`） | 元数据明文 | 留，作者自己看不到了 | 留 | 删行 |
| 运行的提示词、摘要、错误 | `runs` | 明文（问题 9） | 留在项目里，主人看不到了 | 留 | 马上不可见，后台删 |
| 运行事件 | `events`（带 `project_id`，保留 30 天） | 明文 | 同上 | 同上 | 随运行级联删 |
| 审批 | `approvals` | 明文，只有主人看得到 | 取消后删 | 删 | 随运行级联删 |
| 平台工具的副作用缓存 | `tool_calls` | 明文，只有 worker 读 | 留 | 删 | 随运行级联删 |
| 电脑工具的参数和结果 | `device_calls` | 明文，只有 worker 读 | 留 | 删（现在就删，users.rs） | 删（在删运行之前，按 `run_id` 找） |
| 收件箱、出箱 | `inbox_items`、`outbox`（带 `project_id`） | 明文 | 删掉退出者的 | 删 | 删 |
| 项目动态 | `project_events` | 只有元数据 | 留 | 留 | 删 |
| 沙箱里的项目工作区和 agent 记忆 | `workspace/projects/<p>/` | — | 进清理队列 | 实例删除时回收 | 进清理队列 |
| 工作区归档 | 对象存储 | 阶段 9 以前：主人的 DEK，整个工作区一份；以后：项目部分用**项目密钥** | 清理后下一次归档换掉旧的 | 随用户 DEK | 阶段 9 以后：**删密钥**；以前：清理加重新归档 |
| 举报快照 | `content_reports` | 明文 | 留（举报人的） | 举报人注销时删 | 留到处理完（第 9 节） |
| 用量 | `usage_records` | 没有内容 | 留 | 留 | 留 |
| App 本地缓存 | client-core 的 SQLite | — | 收到退出通知后清掉 | — | 收到删除通知后清掉 |

### 4.6 删除项目

`Tx<Worker>::delete_project(actor: Option<UserId>, project)`。`actor` 为 `None` 表示注销或后台调用。分两步。

**第一步（一个事务，即时生效）**：

1. `SELECT … FROM projects WHERE id = $1 FOR UPDATE`。必须是创建者，状态不是 `deleted`。
2. 取消所有还没结束的项目运行：按 id 顺序锁运行，令牌代数加一，改成取消（照 runs.rs:557-580）。再取消这些运行的审批（`cancel_run_approvals`）。
3. `UPDATE run_grants SET revoked_at = now(), revoke_reason = 'project_deleted' WHERE project_id = $1 AND revoked_at IS NULL`。
4. **`DELETE FROM project_keys WHERE project_id = $1`**。从这一刻起，看板、产出物、（阶段 9 以后的）工作区归档都解不开了。
5. 所有成员 `left_at = now(), left_reason = 'project_deleted'`。成员关系函数马上不再返回这个项目，所有成员（包括主人自己的项目运行）都看不到了。
6. `projects`：`status = 'deleted'`，`name = ''`，`goal = ''`，`deleted_at = now()`。
7. 给每个当过项目 agent 的实例写一条 `scope_cleanups`（第 5.4 节）。
8. 通知成员“项目已删除”。只带项目 id 和删除前的名字，App 据此清缓存。写审计日志。

**第二步（后台分批）**：`purge_deleted_projects` 放进维护循环，挑 `projects_purge` 里的项目，每批一个事务，按下面的顺序删：

1. `device_calls WHERE run_id IN (项目运行)`
2. `inbox_items` 和 `outbox` 里 `WHERE project_id = $1` 的
3. `runs WHERE project_id = $1 LIMIT n`：事件、审批、`tool_calls`、`live_activities`、产出物都随之级联删掉，产出物的密文排进 `blob_purge`
4. 剩下的 `artifacts`
5. `project_board_posts`、`project_events`、`project_feed_heads`、`project_invites`
6. `plans WHERE project_id = $1`：触发器、步骤、webhook 随之级联删掉
7. `run_grants WHERE project_id = $1`
8. `project_agent_auth`、`project_agents`、`project_members`
9. 最后写 `purged_at`

对象存储里的密文由现有的 `purge_blobs`（server/src/workers.rs:380-397）删掉。

**加密销毁的测试**（阶段 5）：

- 发布一个产出物、写一条看板。
- 删项目以后：`ArtifactStore::read` 得到 `NoProjectKey`；`project_keys` 里没有这一行；`blob_purge` 里有这个对象的键；成员读运行得到 404。
- 清理跑完以后，逐张表查 `project_id = P` 的行，都是 0 条。

### 4.7 归档

- **归档**（创建者）：`status = 'archived'`，取消项目运行，吊销项目授权。密钥保留，成员照样能读。
- **只读怎么保证**：所有写都在 worker 里用 `FOR SHARE` 核对项目是 `active`，归档后一律拒绝。
- **恢复**：主人下一次在项目里有动作时重签项目授权。为了省事，恢复时由 worker 替所有还在的 agent 重签：主人的授权设置已经存在 `project_agent_auth` 里，等于主人之前已经同意过。

### 4.8 撤回 agent、退出、被移出

**撤回 agent**：`Tx<Worker>::withdraw_project_agent(actor, project, instance, reason)`，只有主人或创建者能做。

1. 这个实例在项目里还没结束的运行和它们的子孙一起取消，子孙可以是别人的 agent。
2. 别人问它的、还没答完的问题也取消（复用 `cancel_asks`）。
3. 吊销它在项目里的所有授权，令牌代数加一。
4. 如果它是负责人，`is_lead = false`，通知创建者重新指定。
5. 写 `left_at`。
6. 暂停在这个实例上有步骤的项目计划（`retire_project_agent_plans`），通知创建者。
7. 写清理队列和项目动态。

**退出或被移出**：`leave_project(actor, project, member, reason)`。创建者不能退出，只能删除，首版不支持转让。

1. 他的每个 agent 走一遍撤回。
2. 成员行写 `left_at` 和 `left_reason`。
3. 删掉这个人在这个项目里的收件箱、还没送出的出箱、审批：`WHERE user_id = $member AND project_id = $p`。
4. 给他发一条退出通知，App 收到后清掉本地缓存里 `project_id = P` 的事件和项目数据。client-core 缓存表里的事件要多存一列 `project_id`。
5. 写项目动态，通知创建者。

**结果**：

- 留下的贡献（看板、产出物、运行）在项目里照旧，作者显示“已退出的成员”或“已移出的成员”。
- 退出的人在服务器上马上看不到项目内容，包括他自己 agent 的项目运行，靠的是第 2.3 节的 `tenant` 策略。
- 他沙箱里的项目目录在下一次运行之前清掉（第 5.4 节）。

### 4.9 注销（改 `erase_account`，users.rs:183-231）

在现有的语句之前加：

1. 他建的、没删的项目，每个调一次 `delete_project(None, p)` 的第一步，明文由后台清理。
2. 他在别人项目里的成员身份，每个调一次 `leave_project(.., reason = 'erased')`。再把他的快照清空：`project_members.display_name = ''`，`project_agents.name = ''`、`purpose = ''`，`project_board_posts.author_label = ''`。

现有语句的改动：

| 现在 | 改成 | 为什么 |
|---|---|---|
| `DELETE FROM runs WHERE user_id = $1`（第 200 行） | `… AND project_id IS NULL` | 他在别人项目里的运行是贡献，保留。他自己项目的运行由项目清理删 |
| `DELETE FROM events WHERE instance_id IN (…)` | `… AND project_id IS NULL` | 同上 |
| 无 | `DELETE FROM approvals WHERE user_id = $1`、`DELETE FROM tool_calls WHERE user_id = $1` | 留下的项目运行上挂着的审批和缓存只属于主人 |
| `DELETE FROM teams / team_templates` | `DELETE FROM project_templates WHERE user_id = $1`；老表在阶段 10 删掉之前照删 | |
| 无 | `DELETE FROM project_invites WHERE inviter_id = $1 OR invitee_id = $1`、`DELETE FROM user_blocks WHERE blocker_id = $1 OR blocked_id = $1` | |

他的 `user_keys` 销毁了，但项目产出物和看板用的是项目密钥，照样读得出，这就是“贡献保留”能成立的原因。内容里如果有个人信息，16.6 再定怎么处理。`erasing_an_account_deletes_its_content`（tests.rs:820 起）的逐表清单加上新表，另外加一个“别人项目里的贡献还在、作者名清空了”的检查。

## 5. 会话和工作区（每个（实例，项目）一套）

### 5.1 目录布局

所有内容都要放在 `/sandbox/workspace` 下面，因为只有它在工作区卷上、会被归档（cube.rs:456-460、control/workspace.rs:80-87）。

```
/sandbox/workspace/
  .thinktin/platform-tools.json   每次启动重写（exec.rs:172-180）
  .thinktin/home/                 私人 HOME（不变：私人记忆、会话文件 shim-session.json）
  private/                        私人工作目录（从工作区根目录挪过来，见 5.3）
  projects/<p32>/home/            项目的 HOME：这个项目里 agent 自己的状态、记忆、技能、会话文件、桥接套接字
  projects/<p32>/work/            项目的工作目录；交接文件在 work/handoff/
```

- **为什么每个作用域一个 HOME**（调查 sessions 一节的方案 B），不共用 HOME：
  1. 删除和退出就是 `rm -rf projects/<p32>`，阶段 9 也能把它单独归档、用项目密钥加密。
  2. 各家 agent 的跨会话记忆都放在 HOME 里，换个工作目录挡不住：
     - Hermes 的 `MEMORY.md`、`USER.md` 和 `session_search`
     - Claude 的 `~/.claude/CLAUDE.md`
     - Codex 的 memories

     共用 HOME 的话，私人记忆会被带进别人的项目，项目内容也会被带回私人对话，正好违反第 6 节。
  3. 会话文件本来就按 HOME 存（state.rs:16-18），**agent-shim 不用改**。`previous_session` 对工作目录的核对（shim.rs:270-274）照样起保护作用。
  4. OpenClaw 的状态目录在 HOME 下面（config.rs:277-283），每个作用域自然分开，固定的网关会话键（openclaw.toml:26）不会串。这一点要在 2026.10.3 上实测。
- **代价**：agent 在项目里用不上主人私人积累的记忆和技能，这是产品上的取舍，见第 9 节。
- **套接字路径长度**：`/sandbox/workspace/projects/<32 位十六进制>/home/.thinktin/platform-tools.sock` 是 95 字节，没超过 bridge.rs:416 的 100 字节上限。本地后端的根目录更长，会退回 `TMPDIR`，也能用。

### 5.2 作用域怎么传

```rust
/// 运行在哪个作用域里执行（8.16）。目录只从服务端的 id 推出来，从不用项目名或 agent 给的路径。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionScope { Private, Project(ProjectId) }

impl SessionScope {
    pub fn of(run: &Run) -> Self;
    /// 相对 ExecConfig.workdir："．thinktin/home" 或 "projects/<p32>/home"。
    pub fn home(&self) -> String;
    /// 相对 ExecConfig.workdir："private" 或 "projects/<p32>/work"。
    pub fn cwd(&self) -> String;
}
```

| 地方 | 改动 |
|---|---|
| `ShimLaunch`（shim.rs:16-28） | 加 `scope: SessionScope`，executor.rs:846-854 填。两个测试替身连接器跟着改（orchestrator/tests/executor.rs:71、tests/pipeline.rs:61） |
| `ExecConnector::argv`（exec.rs:103-140） | `--home` 和 `--cwd` 用 `scope.home()`、`scope.cwd()`。进程的工作目录还是 `workdir`（189 行），`.thinktin/platform-tools.json` 的相对路径照样成立 |
| `ArtifactTools::workspace_path` 和 `fetch` 的默认路径（tools.rs:504-507、641） | `<workdir>/<scope.cwd()>/<rel>`，作用域从 `ToolContext.project` 来 |
| `HandoffCopier`（pipeline.rs:469） | `<workdir>/<scope.cwd()>/handoff/<name>`；项目步骤要找计划时去根运行上找 |
| 专属实例 | 只跑项目作用域。私人运行、私人计划在这样的实例上返回 409 `dedicated_instance`，私人委派的目标里也排除它们 |

### 5.3 私人工作目录的一次性迁移（`0034`）

- `instances` 加一列 `workspace_layout smallint NOT NULL DEFAULT 1`，加完再 `ALTER … SET DEFAULT 2`：已有的实例是 1，新实例是 2。业务角色不授权这一列。
- 执行器在 `ensure_running` 之后、启动 shim 之前，如果 `workspace_layout < 2`，就调 `Lifecycle::prepare_layout(instance)`：
  - 在沙箱里依次执行 `mkdir -p private` 和 `find . -mindepth 1 -maxdepth 1 ! -name .thinktin ! -name private ! -name projects -exec mv -t private -- {} +`。不经 shell，复用 `run_in_sandbox`（control/lib.rs:1841-1870），把它改成公开的。
  - 然后写 `workspace_layout = 2`。可以重复执行。
- **代价**：私人会话因为工作目录变了，会丢一次（`session_lost`）。要更新 `e2e_shim.rs:289-317` 和 agent-integration.md 第 7 节。
- 滚动更新期间，老副本启动的 shim 还用 `--cwd .`，会看到 `private/` 子目录，可以接受。

### 5.4 清理

```sql
CREATE TABLE scope_cleanups (
    instance_id uuid NOT NULL REFERENCES instances (id) ON DELETE CASCADE,
    project_id  uuid NOT NULL,              -- 不加外键：项目删了也要清
    reason      text NOT NULL CHECK (reason IN ('withdrawn', 'left', 'removed', 'project_deleted', 'erased')),
    queued_at   timestamptz NOT NULL DEFAULT now(),
    attempts    integer NOT NULL DEFAULT 0,
    last_error  text CHECK (length(last_error) <= 500),
    done_at     timestamptz,
    PRIMARY KEY (instance_id, project_id)
);
-- 只给 worker：ENABLE + FORCE，没有业务角色的策略。
```

- `Lifecycle::clear_project_scope(instance, project) -> Result<bool>`：在沙箱里执行 `rm -rf -- projects/<p32>`。没有沙箱时返回 `false`。
- **执行器**：每次开始运行之前，先把这个实例排着的清理做完。做不成就重试这次运行。所以撤回或退出以后，主人的私人对话不可能再让 agent 去读 `../projects/<p32>`。
- **巡检**（`ScopeJanitor`，放进维护循环，每 10 分钟一次）：
  - 排了超过 1 小时还没做的，实例在跑就直接清。
  - 实例已暂停或已归档（阶段 9 以前），就叫醒它（`ensure_running`）再清。之后空闲归档时，新的归档会换掉旧的，旧的由 0023 的触发器排进清理队列。
- 同一个 agent 撤回后又加回来：重新登记之前先把还没做的清理做完，新的作用域从空目录开始。

### 5.5 分作用域的工作区归档（阶段 9，`0037`）

```sql
CREATE TABLE project_workspace_archives (
    project_id  uuid NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
    instance_id uuid NOT NULL,
    user_id     uuid NOT NULL,
    key         text NOT NULL,              -- projects/<p32>/workspaces/<i32>/<archive32>
    archive_id  uuid NOT NULL,
    bytes       bigint NOT NULL,
    sha256      bytea NOT NULL,
    archived_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (project_id, instance_id),
    FOREIGN KEY (instance_id, user_id) REFERENCES instances (id, user_id) ON DELETE CASCADE
);
-- 换掉、删掉的归档排进 blob_purge：只收这个项目、这个实例前缀下的键（照 0023:31-60 的写法，不信任输入）。
CREATE FUNCTION queue_project_workspace_purge() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
    own text := 'projects/' || replace(OLD.project_id::text, '-', '') || '/workspaces/'
                || replace(OLD.instance_id::text, '-', '') || '/';
BEGIN
    IF starts_with(OLD.key, own) AND (TG_OP = 'DELETE' OR OLD.key IS DISTINCT FROM NEW.key) THEN
        INSERT INTO public.blob_purge (blob_key) VALUES (OLD.key) ON CONFLICT DO NOTHING;
    END IF;
    RETURN coalesce(NEW, OLD);
END $$;
REVOKE ALL ON FUNCTION queue_project_workspace_purge() FROM PUBLIC;
CREATE TRIGGER project_workspace_archive_purge AFTER UPDATE OF key OR DELETE ON project_workspace_archives
    FOR EACH ROW EXECUTE FUNCTION queue_project_workspace_purge();
```

- **导出**：私人归档的 `EXPORT_ARGV`（control/workspace.rs:80-87）加 `--exclude=./projects`。每个还在的（实例，项目）另打一个包：`tar --create --gzip --file=- -C projects/<p32> .`。
- **存储接口**：`WorkspaceStore::put` 和 `restore` 加一个属主参数 `KeyOwner::{User, Project}`。`ObjectWorkspaceStore` 的属主核对（workspaces.rs:186-193）按前缀分，项目的用 `project_vault` 和 `Domain::ProjectWorkspace`。
- **放回**：先放私人的，再放每个还在的项目包（解压时加 `-C`）。项目已经删了或 agent 已经撤回的，跳过并删掉那一行。所有包加起来不超过 `max_archive_bytes`（control/lib.rs:150）。
- **清理**：对象存储里的项目工作区从此由项目密钥加密。删项目时删密钥，就把所有成员归档里的项目部分一起销毁了。归档着的实例清理时只要删 `project_workspace_archives` 那一行，**不用再叫醒沙箱**。

### 5.6 这不是安全边界

一个沙箱只有一个 Unix 用户，`ExecSpec` 只有 `argv/env/cwd` 三样（sandbox/lib.rs:115-121）。项目里的运行（可能被别人的看板内容诱导）照样能读 `../../private` 和私人 HOME。所以：

- **非专属实例的提示**：跨用户项目里派非专属实例时，接口要求带 `ack_private_access: true`，否则返回 409 `ack_required`，App 据此弹出第 6 节的提示。同一用户自己的项目不要求。单人项目第一次来了别的成员时，通知创建者：哪些 agent 不是专属的。
- **专属实例**：推荐用在跨用户项目里。它的私人目录是空的，私人 HOME 也没有内容。
- docs/sandbox-cube.md:32 说 agent 的状态不在工作区卷上，这句已经过时，顺手改掉。

## 6. 项目里的协作工具

### 6.1 谁看得到谁

| 在哪儿调 | `agents_list` / `agent_status` | `ask` | `board_*` | `delegate*` | 产出物 |
|---|---|---|---|---|---|
| A 的 agent X 的**私人运行** | A 的其他实例（开着交流开关的，8.9）；只汇总**私人**运行，正在做项目的显示“忙”、不带任务 | A 的实例，子运行是私人的 | A 的私人看板 | X 当负责人的项目里、A 自己的、不是专属的 agent，子运行是私人的（兼容老团队） | 私人树 |
| X 在**项目 P 的运行** | P 里还在的 agent（不分主人），带主人名的快照；`agent_status` 只汇总对方在 **P 里**的运行；对方在忙别的事只显示“忙” | P 里的 agent，子运行在 P 里、归对方主人、进对方的 P 会话 | P 的看板 | 只有 X 是 **P 的负责人**才有，目标是 P 里的 agent；成员不能再往下委派 | P 的树，加上 `scope: "project"` |

- `is_team_lead`（instances.rs:546-556）换成 `is_project_lead(instance, run.project_id)`。私人运行用上面那条兼容规则。这样负责人的私人运行永远拿不到跨用户的目标（调查 teams 一节的陷阱）。
- **项目里的提问不看 `peer_access`**：那个开关管的是同一用户之间的交流；进了项目就等于同意在项目里被查、被问。
- 别人写的看板内容、回答、产出物、子运行结果，都照“不可信输入”的格式交给 agent。现有的 `UNTRUSTED` 提示改成写明“来自另一个用户的 agent”。

### 6.2 各工具的改动

- **`delegate`**（delegate.rs:75-189）：
  - 目标从 `project_agents` 里找（worker 查询，SQL 里写死 `project_id = ctx.project AND left_at IS NULL`），不再用 `tenant.delegation_targets`。
  - 子授权用 `create_project_child_grant(目标的项目授权, ctx.grant)`，子运行用 `create_run(目标主人)`。
  - 目标是别的主人的 agent 时，按 `project-delegated:<p>:<owner>:<小时>` 去重，通知主人（第 7.4 节）。
- **`ask`**（ask.rs）：项目里的目标是 P 里的 agent。要求对方有还能用的**项目授权**，不再看 `active_grant_for_instance`（ask.rs:131-140）。
- **`agents_list` / `agent_status`**（peers.rs）：项目作用域下，`instance_holder` 和 `last_finished_run` 都加上 `project_id = $p`。私人作用域下加 `project_id IS NULL`（RLS 本身也会挡住）。
- **流水线**：
  - 项目计划：`plans.project_id = P`，属主是创建者，挂在创建者自己的一个项目 agent 上。
  - `check_steps` 和 `set_plan_steps`（plans.rs:252-279）对项目计划改成核对 P 里的 agent，用 worker 和显式条件。
  - `retire_instance_plans`（plans.rs:314-345）加上项目版本。
  - `PipelineDriver::start_step` 按第 3.1 节建步骤运行。

### 6.3 等待环：全局一把锁

`lock_run_waits(user)`（runs.rs:428-434）换成 `lock_run_waits()`，锁的键是 `"run_waits"`，全局一把。

**为什么不按用户或按项目锁**：一个实例同时为私人和多个项目排队，“排队等实例”这条边会跨作用域。举个例子：

1. 私人运行 X 在等 Y 的回答，回答排在 Y 的项目运行后面；
2. Y 的项目运行在等它派给 X 的子任务，子任务排在 X 的私人运行后面。

这两条边分别在私人和项目两个作用域里建立。检查“谁在等谁”时如果各拿各的锁，两边会同时通过，结果互相等死。

全局锁里只有 `run_chain`、`instance_waits_for`（runs.rs:1227）和建子运行这几条语句，耗时在毫秒级。委派和提问都是 agent 一轮里的决定，频率低。关交流开关的路径（`accepts_questions`）也拿同一把锁。以后量大了，可以改成按“通过项目连在一起的一组主人”排好序加锁，留到那时再做。

## 7. 邀请、加入、通知、动态、接口

### 7.1 邀请（`0036`）

```sql
CREATE TABLE project_invites (
    id          uuid PRIMARY KEY,
    project_id  uuid NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
    inviter_id  uuid NOT NULL REFERENCES users (id),
    kind        text NOT NULL CHECK (kind IN ('phone', 'link')),
    phone_hmac  bytea,                       -- 用服务端密钥对手机号做 HMAC：没注册的人的手机号不明文存
    invitee_id  uuid REFERENCES users (id),  -- 手机号已经注册的，建邀请时就记下
    token_hash  bytea UNIQUE,                -- 链接里令牌的 SHA-256；令牌只在建的时候给一次
    max_uses    integer NOT NULL DEFAULT 1 CHECK (max_uses BETWEEN 1 AND 10),
    uses        integer NOT NULL DEFAULT 0,
    state       text NOT NULL DEFAULT 'pending'
                CHECK (state IN ('pending', 'accepted', 'declined', 'revoked', 'expired', 'hidden')),
    expires_at  timestamptz NOT NULL,        -- 最长 7 天
    created_at  timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz,
    CHECK ((kind = 'phone') = (phone_hmac IS NOT NULL)),
    CHECK ((kind = 'link') = (token_hash IS NOT NULL))
);
CREATE INDEX project_invites_inviter ON project_invites (inviter_id, created_at);
CREATE INDEX project_invites_invitee ON project_invites (invitee_id) WHERE state = 'pending';
CREATE INDEX project_invites_phone ON project_invites (phone_hmac) WHERE state = 'pending' AND invitee_id IS NULL;
-- 只给 worker：读邀请都在 worker 里按“我是邀请人或被邀请人”显式过滤。

CREATE TABLE user_blocks (
    blocker_id    uuid NOT NULL REFERENCES users (id),
    blocked_id    uuid NOT NULL REFERENCES users (id),
    blocked_label text NOT NULL DEFAULT '',  -- 拉黑时对方的显示名快照
    created_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (blocker_id, blocked_id)
);
-- 租户策略：blocker_id = app_user_id()；业务角色可以 SELECT、INSERT、DELETE 自己的。
```

- **按手机号邀请**：不管对方注册没有、有没有拉黑邀请人，**回答都一样**（“邀请已发出”），这样问不出一个手机号注册了没有。
  - 被邀请人拉黑了邀请人：状态直接记成 `hidden`，对方永远看不到。
  - 还没注册的：注册或登录以后，“我的邀请”按 HMAC 匹配出来。
- **链接邀请**：令牌 32 字节随机数，库里只存哈希，有过期时间和使用次数上限。
- **预览**：项目名、目标、创建者的显示名、现有成员和 agent（都是快照）。只有被邀请人或者拿着令牌的人看得到。在 worker 里读，显式核对。

### 7.2 加入、增派、非专属提示

`POST /v1/project-invites/{id}/accept`，或者用链接的 `POST /v1/project-invites/redeem {token, …}`：

```json
{ "agents": ["<instance id>", …], "adopt": {"agent_id": "hermes", "name": "项目助手", "harness": null} | null,
  "dedicated": ["<instance id>"], "daily_tokens": 200000 | null, "total_tokens": 5000000 | null,
  "consent_vendor": true, "ack_private_access": true }
```

1. 要当场领养新实例的，先在租户事务里调 `adopt_capped`，受实例数上限约束，然后提交。
2. 再开一个 worker 事务：
   1. 锁项目行，必须是 `active`。
   2. 核对邀请。
   3. 人数上限：成员不超过 10，agent 不超过 30。
   4. 派来的实例必须是自己的、没删除的，标成专属的不能已经专属于别的项目。
   5. 写成员行（或者把退出过的重新激活），连同快照、预算、`consented_at`。
   6. 写项目 agent 和授权行，默认都关。
   7. 签项目授权。
   8. 邀请次数加一或标记已接受。
   9. 写项目动态、通知创建者和邀请人、写审计日志。
3. `consent_vendor` 必须是 `true`。

**增派**：`POST /v1/projects/{id}/agents`（worker，必须是成员，实例必须是自己的）。

**撤回、退出、移出**：见第 4.8 节。

### 7.3 限流和拉黑

| 限制 | 默认 | 实现 |
|---|---|---|
| 每个邀请人每天的手机号邀请 | 20 | 咨询锁 `invites/<user>`，数最近 24 小时的 |
| 每个邀请人每天建的链接 | 5 | 同上 |
| 每个项目同时待处理的邀请 | 20 | 锁项目行时数 |
| 链接的次数和有效期 | 最多 10 次，最长 7 天 | 列上的约束 |
| 每个项目的成员、agent | 10 个、30 个 | 加入、增派时在项目行锁下数 |
| 拉黑 | 被邀请人拉黑邀请人 | `POST /v1/project-invites/{id}/block`：按邀请找到邀请人再写入。之后他发来的邀请记成 `hidden` |

### 7.4 通知（按收件人，不是群发）

- **只发给相关的人**：`orchestrator::outbox::Notice` 加 `project: Option<ProjectId>` 和 `project_run: Option<RunId>`。`project_notify(w, project, kind, recipients)` 对每个收件人调一次 `notify(w, user, …)`（outbox.rs:195-212），用各自的语言。
- **收件人不是运行的主人时**：收件箱条目里 `run_id`、`instance_id` 留空，满足复合外键（0001:378-379），改用 `project_run_id` 跳转。
- **IM 群机器人**：项目通知**不转发**到 IM（outbox.rs:202-209 加一个条件），不让别人的 agent 写的摘要流到项目之外的第三方群里。

| 事件 | 发给谁 |
|---|---|
| 收到邀请 | 被邀请人 |
| 加入、退出、被移出 | 当事人和创建者 |
| 项目任务（根运行）完成或失败 | 创建者，加上这棵树里出过力的 agent 的主人（去重） |
| 跨用户委派开始 | 被委派 agent 的主人，每个项目每小时最多一条 |
| 审批 | 只有 agent 的主人（不变） |
| 项目预算用完 | 主人 |
| 看板上 @ 了某人 | 被 @ 的成员 |
| 项目删除或归档 | 所有成员 |

委派、提问、步骤的子运行照旧不单独发通知（executor.rs:1155-1164）。项目任务结束时，执行器把现在只发给 `rec.user_id`（1166-1189）的那一条换成调 `project_notify`。

### 7.5 项目动态和游标（`0035`）

```sql
CREATE TABLE project_events (
    id            uuid PRIMARY KEY,           -- UUIDv7，写入时生成
    project_id    uuid NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
    seq           bigint,                     -- 读之前由编号器分配：同一项目里连续，按提交顺序
    kind          text NOT NULL CHECK (kind ~ '^[a-z][a-z_.]{0,47}$'),
    actor_user_id uuid,
    instance_id   uuid,
    run_id        uuid,
    ref_id        uuid,                       -- 看板条目、产出物
    payload       jsonb NOT NULL DEFAULT '{}'::jsonb, -- 只放元数据：状态、名字快照、≤60 字的任务标题；不放正文
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (project_id, seq)
);
CREATE INDEX project_events_unsequenced ON project_events (project_id, id) WHERE seq IS NULL;
CREATE TABLE project_feed_heads (
    project_id uuid PRIMARY KEY REFERENCES projects (id) ON DELETE CASCADE,
    seq        bigint NOT NULL DEFAULT 0
);
-- project_events：成员只读编好号的（project_id = ANY(app_project_ids()) AND seq IS NOT NULL）；
-- project_feed_heads 只给 worker。
```

- **写**：在触发它的那个事务里插一行，`seq` 留空，然后 `pg_notify('thinktin_project_events', <项目 id>)`。新开一个频道，老副本照样把 `thinktin_events` 的载荷当实例 id 解析（hub.rs:82）。
- **编号**：`Tx<Worker>::sequence_project_events(project)`，在 REST 翻页和 WS 每次被唤醒去读之前执行：

  ```sql
  SELECT seq FROM project_feed_heads WHERE project_id = $1 FOR UPDATE;           -- 得到 h
  WITH todo AS (SELECT id, row_number() OVER (ORDER BY id) AS n FROM project_events
                WHERE project_id = $1 AND seq IS NULL ORDER BY id LIMIT 500)
  UPDATE project_events e SET seq = $h + todo.n FROM todo WHERE e.id = todo.id;  -- 改了 k 行
  UPDATE project_feed_heads SET seq = $h + $k WHERE project_id = $1;
  ```

- **为什么这样编号**：
  - 编号器只能看到已经提交的行，编号只增不减，所以读的一方按 `seq > 游标` 读永远不会漏行。
  - 写的一方不拿计数锁。执行器的写法是先锁实例行再写动态，删项目的写法是先锁项目行再动实例行，两种顺序撞在一起也不会死锁。
  - 好几个副本同时编号时，靠 `FOR UPDATE` 排队。
- **事件流**：`/v1/projects/{id}/feed/ws` 每个项目一条，占一个连接名额（events.rs:99）。每次心跳重新核对成员关系，退出了就以 4004 关闭（新的关闭码）。`EventHub` 加一张按项目 id 索引的表。
- **保留期**：维护任务删掉 90 天以前的动态。
- **看单个运行的细节**：`/v1/projects/{id}/runs/{run}/events?after=` 和对应的 `/ws`。按 `events_run (run_id, seq)` 读，靠 `project_read` 放行，唤醒用的是那个运行所在实例的现有频道。

  成员看得到这个运行的事件序号，序号之间的空档说明这个实例上同时还记过别的事件，但看不到内容。运行占着实例的时候别的事件很少，可以接受。

### 7.6 HTTP 接口（新增，`gateway/src/routes/projects.rs`）

| 方法和路径 | 谁能调 | 存储层 |
|---|---|---|
| `GET/POST /v1/projects` | 成员 / 任何人（建单人项目，带上自己的 agent 和负责人） | 租户读；建项目是租户写，提交后补密钥 |
| `GET/PATCH/DELETE /v1/projects/{id}` | 成员 / 创建者改名字、目标 / 创建者删除 | 删除：`delete_project` |
| `POST /v1/projects/{id}/archive`、`/unarchive` | 创建者 | worker |
| `GET /v1/projects/{id}/members`、`PATCH …/members/me`（预算） | 成员 | 租户 |
| `POST /v1/projects/{id}/leave`、`DELETE …/members/{user}` | 成员自己 / 创建者 | `leave_project` |
| `GET/POST /v1/projects/{id}/agents`、`PATCH/DELETE …/agents/{instance}` | 成员 / 主人增派、改授权、撤回；创建者撤回或换负责人（`is_lead`） | worker |
| `POST /v1/projects/{id}/tasks` | 创建者 | worker 建运行（第 3.1 节） |
| `GET /v1/projects/{id}/runs?active&roots&before&limit` | 成员 | `Tenant::project_runs`，SQL 里显式写 `project_id = $1` |
| `GET /v1/projects/{id}/runs/{run}/events`、`/ws` | 成员 | 第 7.5 节 |
| `GET /v1/projects/{id}/feed`、`/feed/ws` | 成员 | 第 7.5 节 |
| `GET/POST /v1/projects/{id}/board`，`…/board/{post}/archive|unarchive`，`DELETE …/board/{post}` | 成员 / 作者的主人或创建者 | worker 加解密 |
| `GET /v1/projects/{id}/artifacts` | 成员 | 内容还是走 `/v1/artifacts/{id}/content` |
| `POST /v1/projects/{id}/invites`（`{phone}` 或 `{link: {max_uses, ttl_hours}}`）、`GET`、`DELETE …/invites/{invite}` | 创建者 | worker |
| `GET /v1/project-invites`、`GET …/{id}`（预览）、`POST …/{id}/accept|decline|block`、`POST /v1/project-invites/redeem`、`POST /v1/project-invites/preview`（`{token}`） | 被邀请人 / 拿着令牌的人 | worker |
| `GET/DELETE /v1/blocks[/{user}]` | 自己 | 租户 |
| `GET/POST/DELETE /v1/project-templates[/{id}]`、`POST …/{id}/adopt` | 自己 | 租户（和团队模板一样） |
| `POST /v1/runs/{id}/cancel` | 第 3.6 节 | 项目运行走 worker |

错误码：

- 看不到的项目一律 404（`parse_id` 解析不了的也是）。
- 人数上限、要求确认、专属冲突、还有别的成员：409，带上 `project_full`、`ack_required`、`dedicated_instance`、`has_members`。
- RLS 的 WITH CHECK 失败现在是 42501 → `Forbidden`，在接口层会变成 500（gateway/error.rs:66-79）。项目路由在调用存储层之前先核对权限，正常情况下走不到这一步。

### 7.7 FFI（client-core，新增的记录和方法；Team* 一概不动）

- **新记录**：`Project`、`ProjectMember`、`ProjectAgent`、`ProjectAgentSettings`（只有主人看得到）、`ProjectInvite`、`ProjectInvitePreview`、`ProjectFeedEntry`、`ProjectBoardPost`、`ProjectTemplate`。
- **已有记录加字段**（都加 `#[uniffi(default)]`）：`Run.project_id`、`Run.initiated_by`、`Artifact.project_id`、`InstanceEvent.project_id`、`InboxItem.project_id`、`InboxItem.project_run_id`、`Approval.project_id`。
- **新方法**：
  - 项目：`projects`、`project`、`create_project`、`update_project`、`archive_project`、`unarchive_project`、`delete_project`、`leave_project`、`remove_project_member`
  - 成员和 agent：`project_members`、`set_my_project_budget`、`project_agents`、`add_project_agents`、`update_project_agent`、`withdraw_project_agent`、`set_project_lead`
  - 邀请和拉黑：`invite_to_project_by_phone`、`create_project_invite_link`、`project_invites`、`revoke_project_invite`、`my_project_invites`、`preview_project_invite`、`preview_project_invite_link`、`accept_project_invite`、`redeem_project_invite_link`、`decline_project_invite`、`block_inviter`、`blocked_users`、`unblock_user`
  - 任务和动态：`create_project_task`、`project_runs`、`project_run_events`、`project_feed`、`subscribe_project_feed`（和现有的事件监听同一种回调）
  - 看板和产出物：`project_board`、`post_to_project_board`、`archive_project_board_post`、`delete_project_board_post`、`project_artifacts`
  - 模板：`project_templates`、`create_project_template`、`adopt_project_template`
- **本地缓存**：client-core 的 SQLite 事件缓存（cache.rs:30-33）加一列 `project_id`。收到“退出、移出、删除”的通知或者 404 时，`purge_project(project_id)` 把相关数据清掉。
- 每次 FFI 有变化都在这个容器里重新生成 `apps/android/core/.../client_core.kt`。iOS 的绑定在构建时生成。字段都带默认值，Swift 那边不用改源码。

## 8. 分阶段

每个阶段都要满足：`cargo build --workspace`、`cargo test --workspace`（连 Postgres）、`cargo clippy --workspace --all-targets` 通过，老 App 的团队功能照常可用。跨用户的逻辑在阶段 1、2 就用 store 函数直接造出来的成员测好，到阶段 8 才对用户开放邀请。

| 阶段 | 范围 | 主要文件 | 测试 | 风险 |
|---|---|---|---|---|
| **1 地基**（8.13、8.15 的 RLS） | 0031、0032；成员关系函数、策略、触发器；`DataScope` 和 `tenant_in`；`store::projects`（租户读，worker 写的骨架：`add_project_member` 等）；团队、团队模板改成项目之上的兼容视图；`delegation_targets` 和 `is_team_lead` 改读 `project_agents`；项目密钥：keyvault 的域和 `NoProjectKey`、Aliyun 的上下文、`project_vault`、建项目时生成和后台补发；`active_grant_for_instance` 和 `ensure_instance_grant` 排除项目授权；proto 的 `Project*` 和各 DTO 的 `project_id`；只读的项目路由和 FFI | store/{lib,projects,teams,instances,grants,runs,events,artifacts,tests}.rs，keyvault/lib.rs，aliyun/src/kms.rs，orchestrator/src/artifacts.rs，gateway/src/routes/{teams,projects,runs,mod}.rs，proto/src/domain.rs，client-core/src/{ffi,api}.rs，server/src/workers.rs | 第 2.6 节的全部测试；`ffi_teams_and_templates`、`teams_pipelines_and_artifacts` 原样通过；项目密钥的生成、补发，以及“删了以后不再生成” | **高**（RLS、策略重写）。这时没有跨用户的数据流，问题会在测试里暴露 |
| **2 项目运行**（8.17、8.18 的核心） | 项目任务接口；`project_id` 跟着父运行走（委派、提问、步骤）；项目授权（`issue_project_grant`、`create_project_child_grant`、`GrantScope::intersect`、`project_scope`）；沙箱令牌的项目核对；执行器的策略、授权回退、按项目判断负责人；平台工具改用 `tenant_in`；全局等待锁；跨主人的子运行按主人建；交还结果时用快照名；项目计划和步骤触发器；这时项目运行里先不给产出物、看板工具 | orchestrator/src/{executor,delegate,ask,peers,pipeline,tools,vault,shim,texts}.rs，store/src/{runs,grants,plans,projects}.rs，auth/src/grants.rs，proto，gateway/src/routes/projects.rs | orchestrator/tests/executor.rs：A 的负责人委派给 B 的 agent，子运行 `user_id = B`，授权的属主是 B、范围是交集，审批找 B，B 吊销以后子运行停下；私人运行拿不到跨用户的目标；负责人的私人运行里没有项目委派；提问进的是 P 的作用域；全局锁下的交叉等待测试；`ask`、`delegate` 现有的测试改用新的锁 | **高**（跨用户运行）。还没有对外开放的入口 |
| **3 项目内容** | 0033；产出物用项目密钥加密（发布、读取、对象键前缀、`FOR SHARE` 核对、抹保险箱）；项目看板表、平台工具、App 接口、FFI；项目运行里打开产出物和看板工具 | orchestrator/src/{artifacts,tools,board,pipeline}.rs，store/src/{artifacts,board}.rs，gateway/src/routes/{artifacts,projects}.rs，keyvault | 产出物和看板的加解密往返；用户 DEK 加密的产出物冒充项目产出物会被拒（AAD 的域不同）；退出的作者自己读不到 | 中 |
| **4 会话和工作区**（8.16） | 0034；`SessionScope`；每个作用域一个 HOME 和工作目录；`private/` 迁移；`ArtifactTools` 和 `HandoffCopier` 的路径；`scope_cleanups`、执行器开跑前清理、巡检；专属实例；打断说明不跨作用域；非专属确认 | orchestrator/src/{shim,exec,executor,tools,pipeline}.rs，control/src/lib.rs，store，gateway | e2e_shim：私人和项目两个作用域交替跑，各自接回会话，`session_lost` 只出现一次（迁移那次）；撤回后私人运行开跑前目录已经没了；交接文件写进作用域目录 | 中（真实沙箱只能用本地后端测） |
| **5 删除、归档、退出、注销**（8.15） | `delete_project` 的两步和后台清理；归档；撤回、退出、移出；`erase_account` 的改动；退出时的收件箱、出箱、审批清理 | store/src/{projects,users,tests}.rs，orchestrator（清理任务），gateway | 第 4.6 节的加密销毁测试；注销测试的逐表清单；“贡献保留，名字清空”；退出后 RLS 立刻挡住 | 中高 |
| **6 费用与控制**（8.18） | 模型网关的项目预算和 `project_budget`；用量记录写 `project_id`；按主人分开记的树用量；等额度的 `wait_code`；创建者和主人的打断、`delegate_cancel`；全部停止的扩展；电脑、保险箱按项目授权 | llm-gw/src/{proxy,pg,store}.rs，store/src/{llmgw,usage,runs}.rs，orchestrator/src/{executor,waits,account,delegate,vault}.rs | llm-gw 测试：B 的项目预算用完时，B 的 agent 拿到 429 加 `project_budget`，A 的不受影响；创建者能打断别人的项目运行，成员不能（404）；保险箱只能用允许的条目 | 中 |
| **7 通知与动态**（8.19） | 0035；`project_events`、编号器、WS、事件中心的新频道；`project_notify`；收件箱的 `project_run_id`；不转发到 IM；动态的 FFI 和监听 | orchestrator/src/{outbox,executor,pipeline}.rs，store/src/{inbox,projects}.rs，gateway/src/{hub,routes/projects}.rs，client-core | 编号器：并发写、乱序提交时游标不漏行；退出后 WS 以 4004 关闭；收件人按第 7.4 节的表 | 中 |
| **8 邀请与加入**（8.14），跨用户正式开放 | 0036；邀请（手机号的 HMAC、链接）、预览、接受（含当场领养）、拒绝、拉黑、限流；增派；FFI；Android 绑定重新生成 | gateway/src/routes/projects.rs，store/src/projects.rs，auth（登录时匹配手机号邀请），client-core | gateway：三个用户的完整矩阵（邀请、派多个 agent、只看得到项目内容、各扣各的预算、审批推给主人、退出后看不到、删除后读不出），对应 17.8；限流；按手机号问不出是否注册 | 高（第一次真的跨用户），前面几个阶段已经兜住 |
| **9 分作用域归档** | 0037；导出、放回按作用域分开；`KeyOwner`；清理不用再叫醒沙箱 | control/src/{lib,workspace}.rs，orchestrator/src/workspaces.rs | ACS 和本地的归档、放回往返；删项目后项目包解不开、键排进清理队列 | 中（归档代码比较绕） |
| **10 收缩** | 12.25/13.18 上线以后：0038 删老团队表，删兼容路由和团队 FFI；更新文档（projects.md 链接到本文、architecture-v3 4.11、threat-model、security-audit 第 43-44 行、compliance 第 5 节） | — | 回归测试 | 低 |

## 9. 未决问题的决定，以及要用户定的

**团队（teams）**

| 问题 | 决定 |
|---|---|
| 留不留 `/v1/teams*` | 留，作为单人项目之上的兼容视图，阶段 10 删 |
| 项目流水线的计划放哪、根运行归谁 | 计划带 `project_id`，属于创建者，挂在他自己的项目 agent 上；根运行归创建者；步骤归各 agent 的主人 |
| `delegate_list` 在项目里看到什么 | 只看当前运行所在项目的 agent。私人运行只看自己的（兼容老团队） |
| 普通成员能不能再往下委派 | 不能，只有项目负责人能 |
| 人数上限 | 项目最多 10 个用户、30 个 agent；兼容接口和模板最多 12 个 |
| 负责人怎么存，是不是必须有 | `is_lead` 布尔，最多一个；服务端不强制必须有 |
| 迁来的团队的运行换不换会话 | 只有带 `project_id` 的运行换；私人委派还用私人会话 |
| 跨用户子运行用谁的语言、推给谁 | 平台说明用目标主人的语言；通知按收件人各自的语言 |
| 模板存什么 | 还是 agent 种类、接入方式、名字、角色，加一个 `goal` |

**RLS**

| 问题 | 决定 |
|---|---|
| 成员关系函数归谁 | `project_members` 只 ENABLE 不 FORCE，函数归迁移账号；不建新角色；用测试模拟生产环境的属主 |
| 数据库层要不要按项目收窄 | 要：`app.project_scope` |
| 运行树跨不跨用户 | 跨用户：单列外键加触发器 |
| 成员看完整的运行行吗 | 项目运行看完整的行 |
| 项目运行的事件放哪 | 留在实例的事件流里（主人在项目里时看得到）；成员按运行读；项目页用单独的动态 |
| `status` 怎么体现在策略里 | 删除靠成员一律标记退出；归档靠 worker 的 `FOR SHARE` 核对 |
| 看板、产出物用新表还是加列 | 看板另建表，产出物加列 |
| 团队要不要同一个迁移里迁 | 同一个迁移里只复制，老表以后删 |

**可见性（visibility）**

| 问题 | 决定 |
|---|---|
| 项目动态的形状 | 写时不编号，读前由编号器编号 |
| 主人的实例页显不显示项目运行 | 显示（主人在项目里时） |
| 没有运行的实例事件给不给成员看 | 永远只给主人 |
| 流水线根运行归谁 | 创建者 |
| 实时活动 | 首版只给主人自己的设备 |
| 审批原因、权限请求的内容要不要对成员隐藏 | 不隐藏（这些属于项目内容；保险箱名只出现允许的那些） |
| 谁能删项目产出物 | 作者的主人和创建者 |
| 退出时删不删他的收件箱 | 删 |
| 项目通知走不走 IM | 不走 |
| 删除时运行内容是删还是加密 | 删 |

**密钥（keys）**

| 问题 | 决定 |
|---|---|
| 运行内容要不要加密 | 不加密（问题 9），删除时删 |
| 看板加密到什么程度，单人项目要不要也有密钥 | 正文加密，标签明文；单人项目也有密钥 |
| 产出物的名字空间 | 还是按运行树，另外能按项目列出 |
| 项目工作区怎么处理 | 先做清理队列，阶段 9 用项目密钥分开归档 |
| 注销以后贡献留不留 | 留 |
| `Kms` 要不要带类型化的属主 | 不改接口，用 `project:` 前缀 |
| 谁能删看板条目 | 作者的主人和创建者 |
| 项目里发布的文本产出物要不要抹保险箱 | 要 |

**会话（sessions）**

| 问题 | 决定 |
|---|---|
| 共用 HOME 还是每个作用域一个 | 每个作用域一个 HOME（方案 B） |
| 私人工作目录挪不挪 | 挪到 `private/` |
| 每种项目都分开吗 | 是，单人项目也分开 |
| 清理要不要叫醒沙箱 | 跑运行前清；巡检 1 小时内叫醒清；阶段 9 以后不用叫醒 |
| OpenClaw 的会话键 | HOME 分开以后自然分开，要实测 |
| 要不要用配置关掉 agent 的跨会话记忆 | 方案 B 下不需要 |
| 专属实例还走作用域吗 | 走项目作用域 |
| 项目工作区要不要单独的配额 | 首版和实例共用上限，阶段 9 合计在归档上限之内 |

**费用（money）**

| 问题 | 决定 |
|---|---|
| 项目运行树的根归谁 | 创建者下的任务：根运行归被派的 agent 的主人；流水线：根运行归创建者 |
| 预算在哪里查 | 模型网关查准的，执行器兜底；按天切分用网关的偏移 |
| `usage_records` 加什么 | 加 `project_id` |
| 项目授权怎么签 | 每个（实例，项目）一个顶层授权，由主人签 |
| 全部停止的范围 | 第 3.6 节 |
| 审批超时听谁的 | 主人的设置，不暂停计划 |
| 跨用户委派要不要主人逐个确认 | 预算内自动执行，通知主人 |
| 同一实例能不能并发跑私人和项目运行 | 不能，保留一个实例同时只跑一个运行 |
| 迁来的团队用哪套默认 | 私人运行照旧；项目运行用项目的默认值 |

**要用户定的产品问题**（括号里是开工前没回复时的默认）：

1. agent 在项目里有一套**独立的记忆和技能**，用不上主人私人积累的，项目里学到的也带不回私人对话。同一用户自己的项目要不要例外，共用私人记忆？（默认：不例外，所有项目都分开。）
2. 成员注销以后，他的 agent 在别人项目里留下的**运行记录**（任务、回答、过程）也保留，名字清空，不只是看板和产出物。这样可以吗？（默认：保留。）
3. 创建者点“全部停止”时，也停掉他建的项目里别人的 agent 正在替项目干的活？（默认：停，但不吊销别人的授权。）
4. 跨用户委派时给主人的通知频率。（默认：每个项目每小时最多一条汇总。）
5. 项目删除以后，用户对项目内容的举报快照保留到运营处理完再删？这一条和 16.6 一起定。（默认：保留到处理完。）