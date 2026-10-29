<!-- 未评审的草稿（2026-10-29 设计评审的 design:A），见 docs/progress/claude-determined-lovelace-vn0j5h.md 的紧急交接 -->

# 项目与跨用户协作：实现方案（项目边界放在数据库里）

> 状态：实现设计，2026-10-29 写，还没开工。产品设计见[项目与跨用户协作](projects.md)，第 1 节是用户的决定，第 11 节的默认值按已接受处理：在预算内自动执行并通知主人；每个项目最多 10 个用户、30 个 agent；不支持转让；不分享模板。工作包是 [WBS](wbs.md) 8.13–8.19。
> 角度：**项目边界由数据库强制**。读权限靠行级安全，而且行级安全按“这个事务替谁、在哪个作用域里读”来放行。写入的完整性靠外键、CHECK 和触发器，这些约束对任何角色都生效，`thinktin_worker` 也绕不过。业务角色 `thinktin_app` 只收窄、不放宽。
> 下文引用的行号以 `claude/determined-lovelace-vn0j5h` 分支为准，可能有几行偏差。

## 0. 结论

1. **新增两个数据库角色，三种作用域事务。**
   - `thinktin_member`：项目事务用，`Db::project` / `Db::project_scope` 设置 `app.project_id`。它只有“当前项目”的策略，没有策略的表一行也看不到，包括保险箱、私人运行、私人看板和 key。私人数据因此默认关闭（fail-closed）。
   - `thinktin_definer`：成员关系函数和触发器的属主。它不能登录，也不能绕过 RLS，只靠 `TO thinktin_definer` 的只读策略读成员关系表。生产环境的迁移账号不是超级用户，而且受 FORCE 约束（deploy-checklist.md:55-71）。这个角色在测试里同样是普通角色，所以测试走的就是生产路径。
   - 私人运行里的平台工具用 `Db::private_scope`。它仍是 `thinktin_app`，但设置 `app.scope = private`，带 `project_id` 的行一概不可见。
2. **`scope_id = coalesce(project_id, user_id)`：所有挂在运行上的行用同一种作用域外键。**
   - 现在的同用户复合外键 `(x_id, user_id)`（0001_init.sql:13-14、249-253）改成 `(x_id, scope_id)`。
   - 私人行只能挂在同一用户的私人行上；项目行只能挂在同一项目的项目行上。
   - 一棵运行树要么全是某一个用户的私人运行，要么全属于同一个项目，库里保证。
3. **运行仍归 agent 的主人**（`runs.user_id`），花谁的 key、记谁的用量、审批找谁都不变。项目运行多一个 `project_id`，外键 `(project_id, instance_id, user_id) → project_agents` 保证“这个实例确实是这个项目里这个主人的 agent”。
4. **项目自己的内容放项目自己的表**：`project_board_posts`、`project_artifacts`，用项目密钥加密。成员退出或注销后内容还在；删项目就是删掉 `projects` 这一行，级联删光，项目密钥随之销毁。
5. **现有团队 API 和 FFI 不变。** 0032 把团队搬成“只有创建者一个人的项目”，`/v1/teams*` 和 `/v1/team-templates*` 变成项目上的兼容视图：只列我建的项目和其中我的 agent，`TeamId` 就是 `ProjectId`。旧表留到 12.25/13.18 之后再删。
6. **分 8 期**，最危险的边界放在第 1 期，配三用户矩阵测试和“生产属主”测试。跨用户执行由服务端开关 `projects.cross_user` 挡着，等费用和审批（第 7 期）和安全评审 15.7 做完再打开。

## 1. 边界模型

### 1.1 事务、角色和设置

| 事务 | 角色 | 事务内设置 | 谁用 | 看得到 |
|---|---|---|---|---|
| `Db::tenant(user)`（不变） | thinktin_app | `app.user_id` | App 的私人页面，`/v1/runs`、`/v1/instances/...` | 自己的私人行，加上自己的 agent 在**现任成员**项目里的行（主人看得到自己 agent 的项目运行，projects.md 第 7 节） |
| `Db::private_scope(user, instance)` | thinktin_app | 再加 `app.scope=private`、`app.instance_id` | 私人运行里的平台工具 | 只有 `project_id IS NULL` 的行 |
| `Db::project(user, project)` | thinktin_member | `app.user_id`、`app.project_id` | App 的项目页 | 只有这个项目的行（列也收窄，见 2.6）；不是现任成员时什么都看不到 |
| `Db::project_scope(user, project, instance)` | thinktin_member | 再加 `app.instance_id` | 项目运行里的平台工具 | 同上，再加上主人为这个 agent 在这个项目里打开的保险箱条目（只有名字） |
| `Db::worker()`（不变） | thinktin_worker | 无 | 后台、跨用户写 | 全部；**读必须写明项目条件，写由约束和触发器兜底** |

`app.project_id` 只是一个“想看哪个项目”的请求，真正放行的是 `app_project_id()`：只有 `app.user_id` 是这个项目的现任成员时它才返回这个项目，否则返回 NULL，所有策略都不匹配。

### 1.2 为什么另开一个成员角色，而不是给 `thinktin_app` 加成员策略

- **租户角色不放宽。** 现在大多数租户读不带 `user_id` 条件，完全靠 RLS：`run`、`run_tree`（runs.rs:317-336）、`instance`、`peers`（instances.rs:284-528）、`events_after`、产出物的几个函数。给 `thinktin_app` 加成员可读策略，会立刻把别人的运行带进 `/v1/runs`、`agent_status` 和“先读再改”的流程。比如 `runs.rs` 的 `cancel?tree=true`（gateway runs.rs:185-221）。新角色的策略只对它自己生效，这些已有的代码一行都不用审。
- **列权限按角色给。** 成员能看 `runs` 的哪些列、`instances` 的哪些列、`users` 只能看 `display_name`、`events` 不给 `seq`（按实例的序号会暴露别人私人事件的数量），这些只能靠单独的角色来授权。
- **默认关闭。** 没给成员角色写策略的表，它一行也看不到。新加一张私人表，就算忘了写项目相关的东西，也不会漏进项目。

### 1.3 为什么要 `thinktin_definer`

调研里 rls 那张图的第一条陷阱：所有表都是 FORCE RLS，策略都写 `TO thinktin_app`，生产环境的属主 `thinktin_owner` 是普通角色。属主拥有的 SECURITY DEFINER 函数在生产里读成员关系表，一行都读不到，于是成员判断永远为假。测试用超级用户连接（tools/dev/setup-db.sh:16-18、store testing.rs），超级用户绕过 RLS，测试照样通过。

我的做法是：函数和触发器的属主改成 `thinktin_definer`（NOLOGIN NOBYPASSRLS）。成员关系表上加 `FOR SELECT TO thinktin_definer USING (true)` 的策略，FORCE 照常保留。这样做的好处有三条：

- 不需要新建 BYPASSRLS 角色。这类角色要 RDS 的高权限账号才建得出来。
- 不需要让迁移账号成为 worker 的成员，否则迁移账号就能绕过 RLS。现在 0001:432-436 有意让属主也受 FORCE 约束。
- 测试库虽然是超级用户，函数却以普通角色 `thinktin_definer` 执行，所以 FORCE 加策略的组合在 CI 里就会被测到。

调研 rls 图提的是“非 FORCE 的成员表”或“BYPASSRLS 的函数属主”。这两种方案在测试里都测不出生产属主的问题，所以没采用。

### 1.4 两条原则

- **读走作用域事务，RLS 兜底。** 平台工具里现在直接用 `Db::worker` 读的地方都要改：产出物工具（tools.rs:477-594）、交接（pipeline.rs:438-479）、委派列表。能改成作用域事务的改成作用域事务；必须留在 worker 的，改用带 `Scope` 参数、SQL 里写死项目条件的 store 函数。
- **写由约束兜底。** 跨用户的写入要做的事比较多：建子运行、取消别人的运行、吊销授权、发通知。这些照旧走 worker，然后由外键、`scope_id` CHECK 和触发器保证不会写出越界的行。BYPASSRLS 只绕过策略，不绕过约束和触发器。

## 2. 数据模型与迁移

### 2.1 迁移编号

| 迁移 | 分期 | 内容 |
|---|---|---|
| 0031_projects.sql | P1 | 角色、项目、成员、项目 agent、模板、事件计数器；成员关系函数；`scope_id` 和外键替换；触发器；策略和授权 |
| 0032_teams_to_projects.sql | P2 | 团队、团队模板的数据搬进项目（保留 id）；旧表留着不用 |
| 0033_project_content.sql | P4 | 项目密钥、项目看板、项目产出物、沙箱清理队列 |
| 0034_project_invites.sql | P6 | 邀请、拉黑 |
| 0035_project_runs.sql | P7 | 授权的 `via_grant_id`、用量的 `project_id`、预算索引 |
| 0036_project_pipelines.sql | P8 | 流水线步骤跨主人；项目事件的 `pg_notify` |

### 2.2 新表（0031）

```sql
-- 项目与跨用户协作（WBS 8.13、8.15）：项目、成员、项目 agent，以及库里的项目边界。设计见 docs/projects.md
-- 和本文。这一版只建结构和边界，程序还不写跨用户的行；团队的数据在 0032 搬过来。

-- ---------- 角色 ----------
-- thinktin_member：项目事务（Db::project）用，只有按“当前项目”放行的策略，没写策略的表一行也看不到。
-- thinktin_definer：成员关系函数和触发器的属主。不能登录、不绕过 RLS，只靠下面 TO thinktin_definer 的
-- 只读策略读成员关系表。生产环境的迁移账号不是超级用户、也受 FORCE 约束，测试里这些函数照样以这个普通角色
-- 执行，和生产一样。
DO $$ BEGIN CREATE ROLE thinktin_member NOLOGIN NOBYPASSRLS; EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE thinktin_definer NOLOGIN NOBYPASSRLS; EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $$;
-- 改函数属主要求迁移账号能 SET ROLE 成它（部署清单里由高权限账号先授予；这里授不了就跳过，后面改属主时会明确报错）。
DO $$ BEGIN GRANT thinktin_definer TO CURRENT_USER; EXCEPTION WHEN insufficient_privilege OR invalid_grant_operation THEN NULL; END $$;
GRANT USAGE ON SCHEMA public TO thinktin_member, thinktin_definer;
-- ALTER FUNCTION ... OWNER TO 要求新属主对 schema 有 CREATE；改完马上收回（见文件末尾）。
GRANT CREATE ON SCHEMA public TO thinktin_definer;

-- ---------- 项目 ----------
-- 状态只有进行中和已归档（只读）。删除不留行：删掉这一行，项目的成员、agent、看板、产出物、密钥、运行一起级联删掉。
CREATE TABLE projects (
    id          uuid PRIMARY KEY,
    creator_id  uuid NOT NULL REFERENCES users (id),          -- 用户行注销后也保留（erase_account 只去标识化）
    name        text NOT NULL CHECK (length(name) BETWEEN 1 AND 64),
    goal        text NOT NULL DEFAULT '' CHECK (length(goal) <= 4000),
    status      text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
    -- 项目给的范围（ProjectPolicy）：平台工具、预授权的工具种类。项目运行的范围是它和主人给的取交集（4.2）。
    policy      jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    archived_at timestamptz,
    CHECK ((status = 'archived') = (archived_at IS NOT NULL))
);
CREATE INDEX projects_creator ON projects (creator_id);

-- 成员（用户）。退出、被移出、注销都只标记（看板条目、产出物的作者还要显示“已退出的成员”“已注销的用户”）。
CREATE TABLE project_members (
    project_id        uuid NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
    user_id           uuid NOT NULL REFERENCES users (id),
    role              text NOT NULL CHECK (role IN ('creator', 'member')),
    -- 这个用户给自己派进来的 agent 定的项目预算（token，每天 / 总计），模型网关按它硬性拦截（4.3）。
    daily_token_limit bigint CHECK (daily_token_limit > 0),
    total_token_limit bigint CHECK (total_token_limit > 0),
    -- 确认“项目内容会发给你的 agent 用的模型厂商”（projects.md 第 10 节）。创建者在发第一个邀请时确认。
    consented_at      timestamptz,
    joined_at         timestamptz NOT NULL DEFAULT now(),
    left_at           timestamptz,
    left_reason       text CHECK (left_reason IN ('left', 'removed', 'erased')),
    PRIMARY KEY (project_id, user_id),
    CHECK ((left_at IS NULL) = (left_reason IS NULL)),
    CHECK (role = 'member' OR left_at IS NULL),               -- 创建者不能退出（不支持转让），只能删项目
    CHECK (role = 'creator' OR consented_at IS NOT NULL)
);
CREATE UNIQUE INDEX project_one_creator ON project_members (project_id) WHERE role = 'creator';
CREATE INDEX project_members_user ON project_members (user_id) WHERE left_at IS NULL;

-- 项目里的 agent。撤回、主人退出时只标记，实例删了也标记（retire_instance_from_projects）。
CREATE TABLE project_agents (
    project_id         uuid NOT NULL,
    instance_id        uuid NOT NULL,
    user_id            uuid NOT NULL,                          -- 主人
    is_lead            boolean NOT NULL DEFAULT false,
    dedicated          boolean NOT NULL DEFAULT false,         -- 专属：不接私人任务（触发器强制）
    position           integer NOT NULL DEFAULT 0,
    -- 主人写给项目成员看的用途（不用实例的 purpose：那是主人私人的说明）。
    purpose            text NOT NULL DEFAULT '' CHECK (length(purpose) <= 200),
    -- 主人给的范围（默认都关，projects.md 第 7 节）。
    allow_computer     boolean NOT NULL DEFAULT false,
    preauthorized_tools text[] NOT NULL DEFAULT '{}',
    approval_timeout_secs integer NOT NULL DEFAULT 86400 CHECK (approval_timeout_secs BETWEEN 60 AND 604800),
    added_at           timestamptz NOT NULL DEFAULT now(),
    left_at            timestamptz,
    PRIMARY KEY (project_id, instance_id),
    UNIQUE (project_id, instance_id, user_id),
    FOREIGN KEY (project_id, user_id) REFERENCES project_members (project_id, user_id) ON DELETE CASCADE,
    -- 实例确实是这个主人的（外键不受 RLS 约束，worker 写的也逃不掉）。
    FOREIGN KEY (instance_id, user_id) REFERENCES instances (id, user_id) ON DELETE CASCADE,
    CHECK (NOT (is_lead AND left_at IS NOT NULL))
);
-- 一个项目最多一个负责人；撤回的不占（调研 teams 图的陷阱：team_one_lead 会把删掉的实例也算进去）。
CREATE UNIQUE INDEX project_one_lead ON project_agents (project_id) WHERE is_lead AND left_at IS NULL;
-- 专属实例只专属一个项目。
CREATE UNIQUE INDEX project_agent_dedicated ON project_agents (instance_id) WHERE dedicated AND left_at IS NULL;
CREATE INDEX project_agents_instance ON project_agents (instance_id) WHERE left_at IS NULL;

-- 主人允许这个 agent 在这个项目里用的保险箱条目（默认没有）。复合外键保证条目属于主人自己。
CREATE TABLE project_agent_vault_items (
    project_id  uuid NOT NULL,
    instance_id uuid NOT NULL,
    user_id     uuid NOT NULL,
    item_id     uuid NOT NULL,
    PRIMARY KEY (project_id, instance_id, item_id),
    FOREIGN KEY (project_id, instance_id, user_id)
        REFERENCES project_agents (project_id, instance_id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (item_id, user_id) REFERENCES vault_items (id, user_id) ON DELETE CASCADE
);

-- 项目模板（原来的团队模板，按 agent 种类描述成员）。只有自己看得到（首版不分享）。
CREATE TABLE project_templates (
    id         uuid PRIMARY KEY,
    user_id    uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name       text NOT NULL,
    spec       jsonb NOT NULL,                 -- TeamTemplateSpec，格式不变
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, user_id)
);

-- 项目事件流的序号（8.19）。单独一行：追加事件时锁它，提交顺序就是序号顺序（和 instances.event_seq 同一个道理），
-- 又不和改项目名、外键检查抢 projects 那一行。
CREATE TABLE project_feeds (
    project_id uuid PRIMARY KEY REFERENCES projects (id) ON DELETE CASCADE,
    event_seq  bigint NOT NULL DEFAULT 0
);
```

### 2.3 `scope_id`：挂在运行上的行共用一种作用域外键

规则只有一条：`scope_id = coalesce(project_id, user_id)`。它是普通列，由触发器填写，再加一个 CHECK。它不能做成 `GENERATED` 列，因为 PostgreSQL 不允许外键的引用列里有生成列，同时动作又是 `SET NULL`。而 `runs` 的 plan、grant 外键都是 `ON DELETE SET NULL (列)`（0001:250-253）。

| 表 | 新列 | 外键变化 | 保证了什么 |
|---|---|---|---|
| runs | `project_id`、`scope_id`、`requested_by` | `(parent_run_id, user_id)` 换成 `(parent_run_id, scope_id) → runs(id, scope_id)`；`(plan_id, user_id)` 换成 `(plan_id, scope_id) → plans`；新增 `(run_grant_id, scope_id) → run_grants`；新增 `(project_id, instance_id, user_id) → project_agents` | 私人运行树只属于一个用户，项目运行树只属于一个项目；项目运行在这个项目的 agent 上、归它的主人；私人运行不能用项目授权，项目运行也不能用私人授权 |
| plans | `project_id`、`scope_id` | 新增 `(project_id, instance_id, user_id) → project_agents` | 项目计划托管在创建者自己的项目 agent 上 |
| run_grants | `project_id`、`scope_id`（P7 再加 `via_grant_id`） | 保留 `(parent_id, user_id)`，新增 `(parent_id, scope_id)`，新增 `(project_id, instance_id, user_id) → project_agents` | 项目授权只发给项目里的 agent、只归它的主人 |
| events | `project_id`、`project_seq`、`scope_id` | `(run_id, user_id)` 换成 `(run_id, scope_id)` | 项目运行的事件一定带着项目，不会混进私人事件流 |
| approvals | `project_id`、`scope_id` | `(run_id, user_id)` 换成 `(run_id, scope_id)` | 审批的项目标记和它的运行一致 |
| inbox_items | `project_id`（外键到 projects，`ON DELETE CASCADE`）、`scope_id` | `(run_id, user_id)` 换成 `(run_id, scope_id) ON DELETE SET NULL (run_id)` | 创建者的收件箱可以指向别的主人的项目运行；删项目时这些条目一起删掉 |
| artifacts（私人） | 无 | `(run_id, user_id) → runs(id, user_id)` 改为引用 `runs(id, scope_id)` | 私人产出物只能来自私人运行 |
| board_posts、vault_requests（私人） | 无 | 同上，改为引用 `runs(id, scope_id)` | 只能挂在私人运行上 |
| live_activities、device_calls、tool_calls | 无 | 不变 | 都是运行主人自己的行 |

运行和计划的部分写出来是这样（其余表照同一个写法）：

```sql
-- ---------- 作用域外键（scope_id = coalesce(project_id, user_id)） ----------
CREATE FUNCTION fill_scope() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    NEW.scope_id := coalesce(NEW.project_id, NEW.user_id);
    RETURN NEW;
END $$;

ALTER TABLE plans
    ADD COLUMN project_id uuid REFERENCES projects (id) ON DELETE CASCADE,
    ADD COLUMN scope_id uuid;
ALTER TABLE runs
    ADD COLUMN project_id uuid REFERENCES projects (id) ON DELETE CASCADE,
    ADD COLUMN scope_id uuid,
    -- 项目任务是谁派的（创建者）。运行归 agent 的主人，派任务的人另记。
    ADD COLUMN requested_by uuid REFERENCES users (id);
-- 已有的行都是私人的。生产环境里迁移账号受 FORCE 约束，看不到任何行（docs/deploy-checklist.md），所以回填时
-- 临时去掉 FORCE，同一个事务里加回来。
ALTER TABLE plans NO FORCE ROW LEVEL SECURITY;
ALTER TABLE runs NO FORCE ROW LEVEL SECURITY;
UPDATE plans SET scope_id = user_id;
UPDATE runs SET scope_id = user_id;
ALTER TABLE plans FORCE ROW LEVEL SECURITY;
ALTER TABLE runs FORCE ROW LEVEL SECURITY;
CREATE TRIGGER plans_fill_scope BEFORE INSERT ON plans FOR EACH ROW EXECUTE FUNCTION fill_scope();
-- deploy-safe: 上一版插入时不填 scope_id，由 plans_fill_scope 触发器补上
ALTER TABLE plans ALTER COLUMN scope_id SET NOT NULL,
    ADD CONSTRAINT plans_scope CHECK (scope_id = coalesce(project_id, user_id)),
    ADD CONSTRAINT plans_id_scope UNIQUE (id, scope_id),
    ADD CONSTRAINT plans_project_host FOREIGN KEY (project_id, instance_id, user_id)
        REFERENCES project_agents (project_id, instance_id, user_id);
-- deploy-safe: runs 的 scope_id 由 runs_fill 触发器补上（见 2.5），上一版不用填
ALTER TABLE runs ALTER COLUMN scope_id SET NOT NULL,
    ADD CONSTRAINT runs_scope CHECK (scope_id = coalesce(project_id, user_id)),
    ADD CONSTRAINT runs_id_scope UNIQUE (id, scope_id),
    ADD CONSTRAINT runs_project_agent FOREIGN KEY (project_id, instance_id, user_id)
        REFERENCES project_agents (project_id, instance_id, user_id),
    DROP CONSTRAINT runs_parent_run_id_user_id_fkey,
    ADD CONSTRAINT runs_parent_scope FOREIGN KEY (parent_run_id, scope_id)
        REFERENCES runs (id, scope_id) ON DELETE CASCADE,
    DROP CONSTRAINT runs_plan_id_user_id_fkey,
    ADD CONSTRAINT runs_plan_scope FOREIGN KEY (plan_id, scope_id)
        REFERENCES plans (id, scope_id) ON DELETE SET NULL (plan_id);
CREATE INDEX runs_project ON runs (project_id, id DESC) WHERE project_id IS NOT NULL;
CREATE INDEX runs_project_active ON runs (project_id, id DESC)
    WHERE project_id IS NOT NULL AND state NOT IN ('succeeded', 'failed', 'cancelled');
-- （run_grants、events、approvals、inbox_items 同样：加列、去 FORCE 回填、加回 FORCE、补触发器、换外键。
--   私人表 artifacts、board_posts、vault_requests 只把外键改成引用 runs (id, scope_id)。）
```

外键的名字是 PostgreSQL 的默认名（`<表>_<列>_<列>_fkey`）。P1 的测试会断言每个旧的同用户外键都已经换掉、新的都在。

项目运行是 UUIDv7，项目 id 和用户 id 都由服务端生成，`coalesce` 之后两者不会撞。即使真撞上，`runs_project_agent` 外键和 2.5 节的触发器也会把“项目运行挂在私人行下面”挡住。

### 2.4 成员关系函数（0031，属主是 `thinktin_definer`）

```sql
-- 不是 SECURITY DEFINER、可以内联的：当前事务是不是“私人运行的工具”，以及调用工具的是哪个实例。
CREATE FUNCTION app_private_scope() RETURNS boolean LANGUAGE sql STABLE
    AS $$ SELECT coalesce(current_setting('app.scope', true), '') = 'private' $$;
CREATE FUNCTION app_instance_id() RETURNS uuid LANGUAGE sql STABLE
    AS $$ SELECT nullif(current_setting('app.instance_id', true), '')::uuid $$;

-- 下面都是 SECURITY DEFINER，以 thinktin_definer 执行：
-- 不接受用户参数（只认 app.user_id，免得被拿来探测别人的成员关系）；STABLE 不是 IMMUTABLE（连接池里的连接会
-- 换用户）；search_path 先 pg_catalog、最后 pg_temp，表名都带 schema。
-- 策略里一律写成 (SELECT f())：成为 InitPlan，一条语句只算一次，还能走索引；直接写 f(project_id) 会每行跑一次
-- （带 SET 子句的函数不会内联）。

-- 我现在是成员的项目（进行中、已归档的都算；删了的连行都没了）。
CREATE FUNCTION app_project_ids() RETURNS uuid[]
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
    AS $$ SELECT coalesce(array_agg(m.project_id), '{}') FROM public.project_members m
           WHERE m.user_id = public.app_user_id() AND m.left_at IS NULL $$;

-- 当前事务的项目：Db::project 设的 app.project_id，只有我是它的现任成员时才返回。
CREATE FUNCTION app_project_id() RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
    AS $$ SELECT m.project_id FROM public.project_members m
           WHERE m.project_id = nullif(current_setting('app.project_id', true), '')::uuid
             AND m.user_id = public.app_user_id() AND m.left_at IS NULL $$;

-- 我在当前项目里的角色（creator / member），不是成员时为 NULL。
CREATE FUNCTION app_project_role() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
    AS $$ SELECT m.role FROM public.project_members m
           WHERE m.project_id = public.app_project_id() AND m.user_id = public.app_user_id() $$;

-- 当前项目能不能写（进行中，不是归档）。
CREATE FUNCTION app_project_writable() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
    AS $$ SELECT EXISTS (SELECT 1 FROM public.projects p
                          WHERE p.id = public.app_project_id() AND p.status = 'active') $$;

-- 当前项目里出现过的实例、用户（含已撤回、已退出的：老的运行和看板条目还要显示名字）。
CREATE FUNCTION app_project_instance_ids() RETURNS uuid[] ...
    AS $$ SELECT coalesce(array_agg(a.instance_id), '{}') FROM public.project_agents a
           WHERE a.project_id = public.app_project_id() $$;
CREATE FUNCTION app_project_user_ids() RETURNS uuid[] ...
    AS $$ SELECT coalesce(array_agg(m.user_id), '{}') FROM public.project_members m
           WHERE m.project_id = public.app_project_id() $$;

-- 主人给调用工具的这个 agent 在当前项目里打开的保险箱条目。
CREATE FUNCTION app_agent_vault_item_ids() RETURNS uuid[] ...
    AS $$ SELECT coalesce(array_agg(v.item_id), '{}') FROM public.project_agent_vault_items v
           JOIN public.project_agents a USING (project_id, instance_id, user_id)
           WHERE v.project_id = public.app_project_id() AND v.instance_id = public.app_instance_id()
             AND v.user_id = public.app_user_id() AND a.left_at IS NULL $$;

-- 项目里一个 agent 忙不忙：只回答当前项目的 agent，只给“忙 / 不忙”，不说忙的是私人事还是别的项目（7.1）。
CREATE FUNCTION app_project_agent_busy(instance uuid) RETURNS boolean ...
    AS $$ SELECT instance = ANY (public.app_project_instance_ids()) AND EXISTS (
             SELECT 1 FROM public.runs r WHERE r.instance_id = instance AND r.kind = 'agent'
               AND r.state IN ('starting', 'running', 'waiting_approval', 'waiting_device', 'waiting_quota',
                               'waiting_children', 'backoff')) $$;
-- 私人那一层用的：自己的实例忙不忙（私人作用域里看不到它在做的项目运行，只能知道它忙）。
CREATE FUNCTION app_own_instance_busy(instance uuid) RETURNS boolean ...   -- 条件换成 instances.user_id = app_user_id()

-- 成员能看的事件种类：白名单（新加的种类默认不给成员看）。保险箱、审批、权限请求、思考过程、用量都不在里面。
CREATE FUNCTION app_member_event_kind(kind text) RETURNS boolean LANGUAGE sql IMMUTABLE
    AS $$ SELECT kind = ANY ('{run.state,agent.message,agent.plan,agent.tool_call,agent.tool_call_update,
                               agent.turn_started,agent.turn_ended,agent.error,artifact.published,
                               delegate.started,ask.sent,board.posted,pipeline.step_started,
                               run.log_truncated}'::text[]) $$;

-- 改属主、收回执行权限：只给需要的角色。
ALTER FUNCTION app_project_ids() OWNER TO thinktin_definer;   -- ……每个 DEFINER 函数一条
REVOKE ALL ON FUNCTION app_project_ids(), app_project_id(), app_project_role(), app_project_writable(),
    app_project_instance_ids(), app_project_user_ids(), app_agent_vault_item_ids(),
    app_project_agent_busy(uuid), app_own_instance_busy(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app_project_ids(), app_own_instance_busy(uuid) TO thinktin_app;
GRANT EXECUTE ON FUNCTION app_project_id(), app_project_role(), app_project_writable(), app_project_instance_ids(),
    app_project_user_ids(), app_agent_vault_item_ids(), app_project_agent_busy(uuid) TO thinktin_member;
GRANT EXECUTE ON FUNCTION app_user_id(), app_private_scope(), app_instance_id(), app_member_event_kind(text)
    TO thinktin_member;

-- worker 用的权限判断：接受用户参数，所以只给 worker（它本来就绕过 RLS），不是 DEFINER。
CREATE FUNCTION project_role_of(p uuid, u uuid) RETURNS text LANGUAGE sql STABLE
    SET search_path = pg_catalog, public, pg_temp
    AS $$ SELECT m.role FROM public.project_members m
           JOIN public.projects pr ON pr.id = m.project_id
           WHERE m.project_id = p AND m.user_id = u AND m.left_at IS NULL $$;
REVOKE ALL ON FUNCTION project_role_of(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION project_role_of(uuid, uuid) TO thinktin_worker;
```

`thinktin_definer` 只读这些：projects、project_members、project_agents、project_agent_vault_items 的全部行；runs 的 `(id, project_id, instance_id, kind, state)`；instances 的 `(id, user_id, state)`。另外它要写 `project_feeds.event_seq`，供 2.5 节的触发器用。每一项都对应一条 `TO thinktin_definer` 的策略，并且只授予用到的列。

### 2.5 触发器（0031；属主是 `thinktin_definer`，对所有角色生效）

```sql
-- 运行：派生并校验作用域。子运行的项目由父运行决定（程序给的不一致就报错）；根运行的项目由程序给，这里校验它
-- 是这个项目里这个主人的现任 agent、项目进行中、实例没删；私人运行不能建在专属实例上。
CREATE FUNCTION runs_fill() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE parent_project uuid;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.project_id IS DISTINCT FROM OLD.project_id OR NEW.user_id IS DISTINCT FROM OLD.user_id
           OR NEW.instance_id IS DISTINCT FROM OLD.instance_id THEN
            RAISE EXCEPTION 'a run cannot move between users, instances or projects' USING ERRCODE = 'check_violation';
        END IF;
        NEW.scope_id := OLD.scope_id;
        RETURN NEW;
    END IF;
    IF NEW.parent_run_id IS NOT NULL THEN
        SELECT r.project_id INTO parent_project FROM public.runs r WHERE r.id = NEW.parent_run_id;
        IF NEW.project_id IS DISTINCT FROM parent_project THEN
            RAISE EXCEPTION 'child run must stay in its parent''s scope' USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    IF NEW.project_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.project_agents a
              JOIN public.project_members m ON m.project_id = a.project_id AND m.user_id = a.user_id
              JOIN public.projects p ON p.id = a.project_id
              JOIN public.instances i ON i.id = a.instance_id
             WHERE a.project_id = NEW.project_id AND a.instance_id = NEW.instance_id AND a.user_id = NEW.user_id
               AND a.left_at IS NULL AND m.left_at IS NULL AND p.status = 'active' AND i.state <> 'deleted') THEN
            RAISE EXCEPTION 'instance % is not an active agent of project %', NEW.instance_id, NEW.project_id
                USING ERRCODE = 'check_violation';
        END IF;
    ELSIF EXISTS (SELECT 1 FROM public.project_agents a
                   WHERE a.instance_id = NEW.instance_id AND a.dedicated AND a.left_at IS NULL) THEN
        RAISE EXCEPTION 'instance % is dedicated to a project', NEW.instance_id USING ERRCODE = 'check_violation';
    END IF;
    NEW.scope_id := coalesce(NEW.project_id, NEW.user_id);
    RETURN NEW;
END $$;
CREATE TRIGGER runs_fill BEFORE INSERT OR UPDATE OF project_id, user_id, instance_id, scope_id ON runs
    FOR EACH ROW EXECUTE FUNCTION runs_fill();

-- 事件：项目、项目序号、作用域都按它的运行算，不信程序给的值（上一版程序写的事件也自动带上项目）。
-- 锁的顺序：append_event 先锁实例行（UPDATE instances SET event_seq），这里再锁项目计数器，各处都是这个顺序。
CREATE FUNCTION events_fill() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    NEW.project_id := NULL;
    NEW.project_seq := NULL;
    IF NEW.run_id IS NOT NULL THEN
        SELECT r.project_id INTO NEW.project_id FROM public.runs r WHERE r.id = NEW.run_id;
    END IF;
    IF NEW.project_id IS NOT NULL THEN
        UPDATE public.project_feeds SET event_seq = event_seq + 1 WHERE project_id = NEW.project_id
            RETURNING event_seq INTO NEW.project_seq;
    END IF;
    NEW.scope_id := coalesce(NEW.project_id, NEW.user_id);
    RETURN NEW;
END $$;
CREATE TRIGGER events_fill BEFORE INSERT ON events FOR EACH ROW EXECUTE FUNCTION events_fill();
```

另外几个触发器的写法相同：

- `approvals_fill`、`inbox_fill`：有 `run_id` 时，`project_id` 取运行的值。没有运行的收件箱条目（邀请、加入）用程序给的 `project_id`。
- `run_grants_fill`：校验 `(project_id, instance_id, user_id)` 是项目里的现任 agent。
- `project_members_guard`：现任成员不超过 10 个；新加入时项目要在进行中。
- `project_agents_guard`：
  - 主人是现任成员、项目进行中、实例没删；
  - 现任 agent 不超过 30 个；
  - 设负责人或专属时，这个 agent 自己也得是现任的。
- 数上限之前先拿咨询锁 `pg_advisory_xact_lock(hashtextextended('project/' || project_id, 0))`。它不要求 UPDATE 权限，不像 `SELECT ... FOR UPDATE`。
- 抛出的 SQLSTATE 用 `check_violation`（23514），store 会映射成 `Error::Invalid`（store error.rs:44-49）。

### 2.6 策略和授权（0031）

**租户策略只收窄。** 下面几张主人表的 `tenant` 策略整体重写：runs、events、plans、approvals、inbox_items、run_grants，以及 P8 的 plan_steps。私人行照旧放行；带 `project_id` 的行，只在“不是私人工具事务、而且自己还是这个项目的现任成员”时放行。成员一退出，自己 agent 留在项目里的运行、事件、收件箱，自己马上也看不到了（projects.md 第 9 节“退出即不可见”）：

```sql
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['runs', 'events', 'plans', 'approvals', 'inbox_items', 'run_grants'] LOOP
        EXECUTE format('DROP POLICY tenant ON %I', t);
        EXECUTE format($p$CREATE POLICY tenant ON %I TO thinktin_app
            USING (user_id = app_user_id() AND (project_id IS NULL
                   OR (NOT app_private_scope() AND project_id = ANY ((SELECT app_project_ids())))))
            WITH CHECK (user_id = app_user_id() AND (project_id IS NULL
                   OR (NOT app_private_scope() AND project_id = ANY ((SELECT app_project_ids())))))$p$, t);
    END LOOP;
END $$;
```

`list_runs` 的语句（runs.rs:482-508）和部分索引（0020）的条件要一字不差才用得上索引。RLS 的条件是后加上去的安全限定，不改语句本身，所以部分索引照样能用。P1 的测试会用 `EXPLAIN` 确认。

**成员策略只给 `thinktin_member`，基本都是只读：**

```sql
CREATE POLICY member_read ON runs FOR SELECT TO thinktin_member
    USING (project_id IS NOT NULL AND project_id = (SELECT app_project_id()));
-- 不给：run_grant_id、budget、租约、tokens_used（主人花了多少是主人的事）、state_reason（审批标题）、hook_id……
GRANT SELECT (id, kind, instance_id, user_id, project_id, plan_id, parent_run_id, root_run_id, step_key, source,
              prompt, state, wait_code, attempt, summary, error, requested_by, created_at, started_at, finished_at)
    ON runs TO thinktin_member;

CREATE POLICY member_read ON events FOR SELECT TO thinktin_member
    USING (project_id IS NOT NULL AND project_id = (SELECT app_project_id()) AND app_member_event_kind(kind));
-- 不给 seq：按实例的序号会暴露别人 agent 私人事件的数量和时间（调研 visibility 图）。成员按 project_seq 翻页。
GRANT SELECT (instance_id, run_id, project_id, project_seq, kind, payload, created_at) ON events TO thinktin_member;

CREATE POLICY member_read ON plans FOR SELECT TO thinktin_member USING (project_id = (SELECT app_project_id()));
-- 项目里的 agent：不暴露沙箱地址、工作区、限额、私人用途、事件序号。
CREATE POLICY member_read ON instances FOR SELECT TO thinktin_member
    USING (id = ANY ((SELECT app_project_instance_ids())));
GRANT SELECT (id, user_id, agent_id, name, state) ON instances TO thinktin_member;
-- 成员的显示名（不给手机号）。
CREATE POLICY member_read ON users FOR SELECT TO thinktin_member USING (id = ANY ((SELECT app_project_user_ids())));
GRANT SELECT (id, display_name) ON users TO thinktin_member;
-- 主人给这个 agent 在这个项目里打开的保险箱条目：只有名字和用途，没有密文。
CREATE POLICY member_read ON vault_items FOR SELECT TO thinktin_member
    USING (user_id = app_user_id() AND id = ANY ((SELECT app_agent_vault_item_ids())));
GRANT SELECT (id, user_id, name, purpose, has_username, last_used_at) ON vault_items TO thinktin_member;

-- 项目自己的表
CREATE POLICY member_read ON projects FOR SELECT TO thinktin_member USING (id = (SELECT app_project_id()));
CREATE POLICY creator_edit ON projects FOR UPDATE TO thinktin_member
    USING (id = (SELECT app_project_id()) AND (SELECT app_project_role()) = 'creator')
    WITH CHECK (id = (SELECT app_project_id()) AND (SELECT app_project_role()) = 'creator'
                AND (SELECT app_project_writable()));
GRANT SELECT (id, creator_id, name, goal, status, created_at, updated_at, archived_at) ON projects TO thinktin_member;
GRANT UPDATE (name, goal, updated_at) ON projects TO thinktin_member;
CREATE POLICY member_read ON project_members FOR SELECT TO thinktin_member USING (project_id = (SELECT app_project_id()));
GRANT SELECT (project_id, user_id, role, joined_at, left_at, left_reason) ON project_members TO thinktin_member;  -- 预算不给
CREATE POLICY member_read ON project_agents FOR SELECT TO thinktin_member USING (project_id = (SELECT app_project_id()));
GRANT SELECT (project_id, instance_id, user_id, is_lead, dedicated, position, purpose, added_at, left_at)
    ON project_agents TO thinktin_member;  -- 电脑、保险箱、预授权只给主人自己看
```

**`thinktin_app`（租户）只看自己那份：**

- `projects`：`id = ANY((SELECT app_project_ids())) AND NOT app_private_scope()`。项目名和目标是项目内容，私人工具事务看不到。
- `project_members`、`project_agents`、`project_agent_vault_items`：`user_id = app_user_id()`，全部列，用于自己的预算和授权设置。私人作用域里也看得到，它们只是“我的哪些 agent 在哪些项目里”这类元数据，委派兼容（7.6 节）要用。
- `project_templates`：照 `team_templates` 的租户策略写。
- `project_feeds`：`SELECT` 和 `UPDATE (event_seq)`，条件是 `project_id = ANY((SELECT app_project_ids()))`。网关的租户事务也会给项目运行追加事件，比如取消、审批。
- 业务角色对这些表**没有写权限**。项目的增删改都走 worker，由约束和 SQL 里的权限判断把关（第 3.4 节）。

**`thinktin_definer`**：在 2.4 节列出的表上，各有一条 `FOR SELECT ... USING (true)`，`project_feeds` 再加一条 `FOR UPDATE ... USING (true)`。

**worker、模型网关：**

- `GRANT SELECT, INSERT, UPDATE, DELETE ON <新表> TO thinktin_worker`。0001:477 的那条 `ON ALL TABLES` 只覆盖当时已有的表。
- 模型网关要判断授权能不能用、按项目算预算（4.3 节），所以 `thinktin_llmgw` 要拿到：project_agents `(project_id, instance_id, user_id, left_at)`、project_members `(project_id, user_id, left_at, daily_token_limit, total_token_limit)`、projects `(id, status)` 的 SELECT。

迁移最后：

```sql
ALTER TABLE projects ENABLE ROW LEVEL SECURITY;  ALTER TABLE projects FORCE ROW LEVEL SECURITY;   -- 每张新表都是
-- deploy-safe: 只在这次迁移里临时给过 thinktin_definer，属主改完就收回；上一版程序不用这个角色
REVOKE CREATE ON SCHEMA public FROM thinktin_definer;
```

`thinktin_member` 绝不能用 `GRANT ... ON ALL TABLES` 授权。`events` 的月分区没有开 RLS（0001:271-319），只能把权限授在父表上。

### 2.7 团队和团队模板怎么映射；兼容视图

**0032 搬数据，保留 id**：

| 原表 | 新表 | 规则 |
|---|---|---|
| teams | projects | 同一个 id，`creator_id = user_id`，`goal = ''`，`status = 'active'` |
| （无） | project_members | 每个团队一行：创建者，`role = 'creator'` |
| team_members | project_agents | `role = 'lead'` 变成 `is_lead`；实例已删的 `left_at = now()`，这样 `project_one_lead` 不会被不存在的负责人占住 |
| team_templates | project_templates | 原样复制（spec 格式不变） |
| （无） | project_feeds | 每个项目一行 |

旧表在生产环境同样受 FORCE 约束，所以这次复制也用 2.3 节的做法：teams、team_members、team_templates、instances 临时 `NO FORCE`，读完加回来，都在同一个迁移事务里。旧表这次不删：滚动发布期间上一版程序还在读它们，删除放到 App 切换之后的那一次迁移。迁移的 SQL 里不能生成项目密钥，搬过来的项目第一次需要密钥时再按 5.1 节的规则补建，这样做是安全的。

**兼容视图**（`gateway/src/routes/teams.rs` 改写，路径和 JSON 不变；`client-core` 的 `Team*` 记录和 10 个方法不变，见 ffi.rs:722-823、2418-2534）：

| 旧接口 | 新实现 |
|---|---|
| `GET /v1/teams` | 我建的、进行中的项目，`members` 只列**我自己的**现任 agent（实例没删），角色是 `lead`（`is_lead`）或 `member` |
| `POST /v1/teams` | `Tx<Worker>::create_project`（单人项目；成员必须是我自己的没删的实例，否则 404，和现在 api.rs 约 1298-1308 行的断言一样） |
| `GET /v1/teams/{id}` | 同上，只看我建的；别人的 404 |
| `PATCH /v1/teams/{id}` | 改名；成员的“整体替换”只在**我的** agent 范围里算差集（加的加、撤的撤），别人的 agent 不动；负责人只能设成我的 agent |
| `DELETE /v1/teams/{id}` | 项目里只有我一个成员时等于删项目；有别的成员时 409（让 App 改用项目接口），免得旧版 App 一下删掉别人的内容 |
| `/v1/team-templates*` | 读写 `project_templates`；`adopt` 像现在一样领养实例并签私人授权（teams.rs:183-226），再建单人项目 |

请求上的 1-12 个成员校验照旧保留。项目的 10 个用户、30 个 agent 上限由库里的触发器管。服务端不要求一定有负责人，两个 App 现在要求有一个，这个规则由 App 自己维持。

## 3. 成员的读路径和数据边界

### 3.1 store 接口

```rust
/// 项目事务（thinktin_member）：以成员身份看一个项目。
#[derive(Debug, Clone, Copy)]
pub struct Member { user: UserId, project: ProjectId, instance: Option<InstanceId> }

/// 一次运行的作用域（proto）：私人，或者某个项目。由运行的 project_id 决定，从不取 agent 给的值。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Scope { Private, Project(ProjectId) }

impl Db {
    /// App 的项目页。不是现任成员时 app_project_id() 是 NULL，什么都看不到。
    pub async fn project(&self, user: UserId, project: ProjectId) -> Result<Tx<Member>>;
    /// 项目运行里的平台工具：同上，再设 app.instance_id。
    pub async fn project_scope(&self, user: UserId, project: ProjectId, instance: InstanceId) -> Result<Tx<Member>>;
    /// 私人运行里的平台工具：thinktin_app，app.scope = private（带 project_id 的行一概看不到）。
    pub async fn private_scope(&self, user: UserId, instance: InstanceId) -> Result<Tx<Tenant>>;
}

impl Tx<Member> {
    /// 我在这个项目里的角色；不是成员返回 NotFound（接口回 404，不区分“没这个项目”和“看不到”）。
    pub async fn role(&mut self) -> Result<ProjectRole>;
    pub async fn project_detail(&mut self) -> Result<ProjectDetail>;          // 项目 + 成员（显示名）+ agent（实例名、种类、状态）
    pub async fn project_runs(&mut self, f: ProjectRunFilter, before: Option<RunId>, limit: i64) -> Result<Vec<ProjectRun>>;
    pub async fn project_run(&mut self, id: RunId) -> Result<ProjectRun>;
    pub async fn project_run_tree(&mut self, root: RunId) -> Result<Vec<ProjectRun>>;
    pub async fn project_run_events(&mut self, run: RunId, kinds: &[&str], limit: i64) -> Result<Vec<ProjectEvent>>;
    pub async fn project_events_after(&mut self, after: u64, limit: i64) -> Result<Vec<ProjectEvent>>;
    pub async fn project_event_range(&mut self) -> Result<(u64, u64)>;
    pub async fn project_peers(&mut self, me: Option<InstanceId>) -> Result<Vec<ProjectPeer>>;   // 含 app_project_agent_busy
    pub async fn project_board(&mut self, f: &BoardFilter) -> Result<Vec<SealedProjectPost>>;   // P4
    pub async fn project_artifacts(&mut self, root: Option<RunId>, limit: i64) -> Result<Vec<StoredArtifact>>; // P4
    pub async fn enabled_vault_items(&mut self) -> Result<Vec<VaultItem>>;   // project_scope 下
}
```

成员角色的列权限比 `columns!()` 宏（runs.rs:192）里的列少，所以 `Tx<Member>` 的查询另用一套 `member_columns!()`。泛型的 `impl<R> Tx<R>`（`run`、`run_tree`、`recent_run_events`、`artifact`）在成员角色下会报“没有列权限”，这正好挡住误用，相当于在运行时把关。

### 3.2 私人运行里的工具看不到项目数据

| 途径 | 机制 |
|---|---|
| 读运行、事件、计划、收件箱、审批 | `Db::private_scope` 下的 `tenant` 策略只放行 `project_id IS NULL` 的行 |
| 查自己的另一个 agent（`agent_status`），它正在做项目运行 | `instance_holder` 看不到那个运行，状态只说“忙”（`app_own_instance_busy`），不给细节 |
| 项目名、目标 | `projects` 的租户策略在私人作用域里不放行 |
| 项目看板、项目产出物 | `thinktin_app` 对这两张表没有任何权限 |
| 私人产出物 | 外键 `artifacts (run_id, user_id) → runs (id, scope_id)` 保证私人产出物只来自私人运行 |
| 产出物工具（今天走 worker，tools.rs:477-594） | 改成按 `Scope` 分两套 store 函数：私人只查 `artifacts`，项目只查 `project_artifacts WHERE project_id = $1`；`artifact_scope` 走的运行树本身已经同质（2.3） |
| 打断时的开头说明引用了被打断运行的标题（executor.rs:780-794） | 两个运行作用域不同时，不引用标题 |
| 交还子任务结果时给子任务起名（executor.rs:799-818） | 子任务和父运行同作用域（库里保证），名字改用 worker 查询 `instance_labels(ids, scope)` |

### 3.3 项目运行里的工具看不到私人数据

`Db::project_scope` 是 `thinktin_member`，它能看的只有 2.6 节列出的那些表和列，其余一律看不到：

- 私人运行、私人看板、私人产出物、计划（项目计划除外）、收件箱、审批、key、IM 渠道、设备；
- 保险箱里没为这个项目打开的条目，以及任何条目的密文；
- 主人别的实例，包括它们的用途说明。

保险箱的值只在 executor 里用 worker 解开，规则见 4.5 节。

**编译期把关**：新增 `crates/orchestrator/clippy.toml`：

```toml
disallowed-methods = [
  { path = "store::Db::tenant", reason = "平台工具按运行的作用域开事务：ToolContext::private_tx / project_tx（projects 实现方案 3.2、3.3）" },
]
```

现在 orchestrator 里用 `tenant` 的地方有 ask.rs:65、board.rs:59/90、delegate.rs:45、peers.rs:47/92、tools.rs:199-313、vault.rs:46/111、executor.rs:802。这些全部改成 `ctx.private_tx(&db)` 或 `ctx.project_tx(&db)`。确实要用租户事务的地方，比如 `notify_tenant`，单独写 `#[allow(clippy::disallowed_methods)]` 并注明原因。CI 本来就跑 clippy。

```rust
pub struct ToolContext {
    pub user: UserId, pub instance: InstanceId, pub run: RunId, pub plan: Option<PlanId>, pub grant: GrantId,
    /// 运行的作用域：执行器从 runs.project_id 取（shim.rs:66-72 现在没有）。
    pub scope: Scope,
}
impl ToolContext {
    pub async fn private_tx(&self, db: &Db) -> store::Result<Tx<Tenant>>;   // scope 是项目时返回 Forbidden
    pub async fn project_tx(&self, db: &Db) -> store::Result<Tx<Member>>;   // scope 是私人时返回 Forbidden
}
```

### 3.4 worker 路径的规矩

- 跨用户的写入有这些：创建者派任务、委派、提问、流水线步骤、取消别人的运行、吊销授权、发通知、加入、退出、移出、删项目。它们一律在 worker 事务里做，权限判断写进同一条 SQL：`... WHERE project_role_of($project, $actor) = 'creator'`，或者 `user_id = $actor`。
- worker 的读，凡是给 agent 或别的用户看的，都要用带 `Scope` 或 `ProjectId` 参数的函数，SQL 里写死 `project_id = $n`。函数名带上 `project_`，评审时一眼能看出来。
- `ancestors_usable!`（grants.rs:47-55）只在内部角色下才可信，在租户 RLS 下，看不到的祖先会被当成不存在。项目授权的祖先链只在 worker 和模型网关里判断（4.2 节）。

### 3.5 错误映射

RLS 的 `WITH CHECK` 失败会报 42501，store 映射成 `Forbidden`，网关现在把它当内部错误返回 500（gateway error.rs:66-79）。改成 404，并打一条 warn 日志，和“看不到就是不存在”的口径一致。邀请、加入这些路径上的唯一键冲突（23505 映射成 409），也要先确认调用方有权看到那一行再返回，不然会变成探测别人数据是否存在的手段。

### 3.6 边界测试（P1 就写）

1. **三用户矩阵**（store tests）：A 是创建者，B 是成员，C 是外人，D 是已退出的成员。数据直接用 worker 插：A 的私人运行、A 在项目里的运行和事件、B 的私人看板。断言 tenant、private_scope、project 三种事务各自看得到什么、看不到什么；断言 D 什么都看不到，包括他自己 agent 在项目里的运行。
2. **伪造写入**：
   - C 在自己的运行上填项目的 `project_id`：触发器报 23514，或外键报 23503；
   - B 把 A 的实例写进 `project_agents`，`user_id` 填 A：触发器拒绝，因为 A 不是这个人；
   - B 设 `app.project_id` 为 C 的项目再发看板：`app_project_id()` 是 NULL，`WITH CHECK` 拒绝；
   - 私人运行下建项目子运行、项目运行下建私人子运行：触发器和 `runs_parent_scope` 都拒绝；
   - 私人运行引用项目授权：`(run_grant_id, scope_id)` 外键拒绝。
3. **生产属主**：断言 0031 起所有 SECURITY DEFINER 函数的属主都是 `thinktin_definer`，并且 `rolsuper` 和 `rolbypassrls` 都为假。再以 `thinktin_member` 调用 `app_project_id()`，返回值应当正确。因为执行者是普通角色，这一步在 CI 里就验证了“FORCE 加只读策略”在生产上能用。
4. **覆盖面**：改写 `every_tenant_table_the_app_can_touch_has_rls`（store tests.rs:764-816）：
   - 对 `thinktin_app` 或 `thinktin_member` 有任何权限的每张表（不再要求有 `user_id` 列），断言 `relrowsecurity` 和 `relforcerowsecurity` 都打开，并且这个角色至少有一条策略；
   - `pg_policies` 里 `TO thinktin_app` 或 `TO thinktin_member` 的策略，`qual` 和 `with_check` 不能是 `true`；
   - `thinktin_member` 对 `events` 的任何分区都没有权限。
5. **网关**（P6 起）：在 `other_users_objects_are_invisible`（api.rs:1680-1993）旁边加一组三用户测试：成员读别人 agent 的项目运行、事件、产出物；外人对所有项目路由都得到 404；退出之后立刻 404，事件 WS 被关掉。

## 4. 跨用户的运行（8.18）

### 4.1 运行归属和运行树

| 运行 | `user_id`（主人） | `project_id` | `requested_by` | 授权 |
|---|---|---|---|---|
| 创建者派给某个 agent 的项目任务 | 这个 agent 的主人 | P | 创建者 | 主人这个 agent 在 P 里的项目授权 |
| 负责人委派的子任务 | 目标 agent 的主人 | P（从父运行继承，库里保证） | — | 项目子授权（4.2） |
| 提问 | 回答方 agent 的主人 | P | — | 回答方在 P 里的项目授权（明确写在运行上，不再走 executor.rs:739-746 的兜底） |
| 项目流水线的根（kind = pipeline） | 创建者 | P | — | 计划授权（创建者，项目） |
| 流水线的步骤 | 步骤 agent 的主人 | P | — | 项目子授权 |

运行归主人，所以 `rec.user_id` 的下游都自动对上：审批（executor.rs:2052-2128）、通知、`has_computer`、扫描器（scrubber）、语言、沙箱令牌里的 `uid`（auth grants.rs:105-163 要求授权的用户就是实例的主人）、模型网关选 key（proxy.rs:946-957）。

### 4.2 授权：项目授权、子授权、两边都能吊销

- **项目授权**：每个 `(实例, 项目)` 一个顶层授权，`user_id` 是主人，`project_id` 是 P，`parent_id` 为空。主人加入项目或增派 agent 时签发（主人的同意），撤回、退出、项目删除、主人“全部停止”时吊销。范围是 `ProjectPolicy.platform_tools` 和主人的设置取交集，保险箱和电脑默认关。
- **项目子授权**（委派、步骤）：`Tx<Worker>::create_project_child_grant(owner_grant, via, target, ttl)`：
  - `user_id` 是目标的主人，`parent_id` 是**目标主人的项目授权**（同一个用户、同一个项目，库里的两条外键保证）；
  - `via_grant_id` 是发起方那次运行的授权，比如负责人的授权（0035 加这一列，`REFERENCES run_grants (id) ON DELETE CASCADE`，并且 `CHECK (via_grant_id IS NULL OR project_id IS NOT NULL)`）；
  - 范围是 `parent.scope.intersect(project.policy.scope)`，所以既不会比主人给的宽，也不会比项目给的宽。
- **`GrantScope::intersect`**（proto domain.rs:398-424 旁边）返回 `Option<GrantScope>`。别名列表为空表示“全部”，两边都不空而交集为空时返回 None，拒绝签发，否则空集会被当成“全部”。
- **两边都能吊销**：`ancestors_usable!` 改成同时沿 `parent_id` 和 `via_grant_id` 往上走，再加上项目还活着的判断。主人撤回时项目授权失效，创建者或负责人那边的授权失效时 `via` 失效，两种情况都会让子授权跟着失效：

```sql
NOT EXISTS (WITH RECURSIVE up(id) AS (
      SELECT e.next FROM run_grants g
      CROSS JOIN LATERAL (VALUES (g.parent_id), (g.via_grant_id)) e(next)
      WHERE g.id = $1 AND e.next IS NOT NULL
    UNION
      SELECT e.next FROM up JOIN run_grants g ON g.id = up.id
      CROSS JOIN LATERAL (VALUES (g.parent_id), (g.via_grant_id)) e(next)
      WHERE e.next IS NOT NULL)
  SELECT 1 FROM run_grants a JOIN up ON a.id = up.id
  WHERE a.revoked_at IS NOT NULL OR a.expires_at <= now())
AND NOT EXISTS (SELECT 1 FROM run_grants g WHERE g.id = $1 AND g.project_id IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM project_agents a
    JOIN project_members m ON m.project_id = a.project_id AND m.user_id = a.user_id
    JOIN projects p ON p.id = a.project_id
  WHERE a.project_id = g.project_id AND a.instance_id = g.instance_id AND a.user_id = g.user_id
    AND a.left_at IS NULL AND m.left_at IS NULL AND p.status = 'active'))
```

这个判断被 `touch_run_grant`（换沙箱令牌时）和模型网关的 `usable_grant_aliases`（store llmgw.rs:98-114）共用。所以哪怕某个授权漏吊销了，成员退出后它在模型网关最多再活 `cache_secs`。退出、撤回时还会给相关实例的 `token_epoch` 加一，签出去的令牌马上作废（runs.rs `bump_epochs_where!`）。

- **授权兜底**：`active_grant_for_instance` 改成 `active_grant_for(instance, scope)`，条件加上 `project_id IS NOT DISTINCT FROM $2`（现在是 grants.rs:303-315）。否则一个项目里的提问会拿到主人的私人顶层授权，那个授权带着保险箱和电脑。
- **沙箱令牌**：`GrantService::sandbox_token` 多收一个 `scope` 参数，核对授权的项目和运行的项目一致。

### 4.3 预算：各扣各的

- **模型网关硬拦截**（“不会花超”）：
  - `usable_grant_aliases` 多返回授权的 `project_id`；
  - `attempt` 在发请求之前，按 `(user_id, project_id, 当天)` 和 `(user_id, project_id, 总计)` 对照 `project_members` 的两个上限，做法照 credential 的 `PgLedger`（llm-gw pg.rs:410-485；proxy.rs:958-965）；
  - 超了返回新的 outcome `project_budget`；
  - `usage_records` 加 `project_id`（0035），索引是 `(user_id, project_id, created_at)`；
  - 一天的边界用和 key 每日上限相同的 `budget_utc_offset_secs`；
  - 并发请求会有少量超出（limits.rs 文件头已经写明），这一点保留。
- **执行器**：
  - `waits.rs` 认识 `project_budget`，运行转入“等额度”，`wait_code = "project_budget"`（字符串，老客户端照样能解析，proto domain.rs:778-802），并通知主人；
  - 主人在项目页提高预算时唤醒这些运行，否则每小时自己试一次；
  - `on_renew`（executor.rs:2325-2398）的“全树共用”改成 `tree_tokens_for_owner(root, rec.user_id, except)`：只把同一个主人的运行加起来，再对照 `rec.budget.max_tokens`；
  - 跨主人的子运行不沿用父运行的 `RunBudget`（delegate.rs:168、pipeline.rs:261、ask.rs:153），而是用目标主人的默认值（6 小时，没有 token 上限），token 由项目预算管。
- **并发假设不变**：`instance_usage_since` 能把用量算对，靠的是“一个实例同时只有一个运行”（0002:48-51），这一条保留。

### 4.4 审批和预授权

- 审批照旧推给 `rec.user_id`，也就是主人（executor.rs:2072-2107）。`approvals.project_id` 由触发器填，通知里带上项目，主人的审批列表能标出“项目 P”。
- 预授权（`allow_tools`，executor.rs:850）的规则：
  - 项目运行取“项目给的”和“主人给的”交集。项目给的是项目计划的 `preauthorized_tools`，没有计划时用 `projects.policy`；主人给的是 `project_agents.preauthorized_tools`；
  - 现在 executor.rs:758-761 从 `run.plan_id` 读策略，对子运行来说读到的是创建者的计划，会把创建者的预授权直接交给别人的 agent。改了以后不会了；
  - 创建者自己的 agent 加进项目时，主人那一份默认复制项目的；别人的 agent 默认为空。
- 审批超时用主人的 `approval_timeout_secs`。项目运行的计划不属于运行主人时，“暂停计划”这个策略按“失败”处理（executor.rs:2180-2207），不会因为一个成员没批就停掉创建者的计划。

### 4.5 电脑和保险箱

- **电脑**：项目运行要同时满足 `has_computer(owner)`（executor.rs:796-797）、`project_agents.allow_computer` 和授权范围。主人随时可以关掉。关掉时吊销并重签这个 agent 的项目授权、`token_epoch` 加一，正在跑的那一轮在下次续租时停下。
- **保险箱**：项目运行只能用 `project_agent_vault_items` 里列出的条目。
  - 列条目（`vault_list`）走 `Tx<Member>::enabled_vault_items`（成员策略）；
  - 真正解开（executor.rs:1954-2048）改用 `vault_items_for_run(user, instance, scope)`：项目作用域下 SQL 里多一个 `id IN (项目条目)`，“`instance_ids` 为空表示全部实例”的规则（store vault.rs:391-411）不适用；
  - `vault_request`（请用户填密码）不进项目范围：别的用户写的内容可能诱导 agent 不停地弹表单。
- **计划工具**（`SCHEDULE_TOOLS`）不进项目范围，不然 agent 在项目运行里建出的私人计划会比成员关系活得久。成员角色对 `plans` 也没有写权限，就算放进来也写不进去。

### 4.6 打断、全部停止、冻结

| 谁 | 能停什么 | 怎么做 |
|---|---|---|
| 创建者 | 项目里任何运行、任何运行树 | `POST /v1/projects/{id}/runs/{run}/cancel?tree=`：worker，先在 SQL 里核对 `project_role_of = 'creator'` 并且运行属于这个项目，再锁树（runs.rs `lock_run_tree`）、给 epoch 加一、更新状态，最后在 worker 里给事件 |
| 主人 | 自己 agent 的运行，以及挂在自己运行下面的子孙（不管子孙是谁的） | 不带 `tree` 时走现在的 `/v1/runs/{id}/cancel`（租户，只动自己的行）；带 `tree` 而且运行属于某个项目时，转到 worker 路径，只取消以自己的运行为根的子树 |
| 创建者的紧急消息 | 只能打断项目运行 | 占着实例的是主人的私人运行时只排队，不打断（8.12 的 `queue_urgent_run` 加一个作用域判断） |
| 主人“全部停止”或冻结 | 自己的全部运行和授权（项目授权也在内），**另外**取消它们在项目树里的子孙 | `cancel_user_runs` 之后跟一句 `cancel_descendants`。子孙替一个已经停下的父运行干活，没有意义了。项目授权被吊销后，负责人也签不出新的子授权，要等主人在项目页点“继续” |

负责人 agent 打断替它干活的成员（4.11 里写着，同一用户的也还没做），这一期仍不做。

## 5. 项目密钥、看板、产出物、删除和注销（0033）

### 5.1 项目密钥

```sql
-- 项目的 DEK（KMS 包裹）。只有 worker 能读写；删项目时级联删掉即“删密钥即销毁”。
CREATE TABLE project_keys (
    project_id  uuid PRIMARY KEY REFERENCES projects (id) ON DELETE CASCADE,
    kms_key_id  text NOT NULL,
    wrapped_dek bytea NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE project_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_keys FORCE ROW LEVEL SECURITY;          -- 不给业务角色、成员角色、模型网关建策略和授权
GRANT SELECT, INSERT, DELETE ON project_keys TO thinktin_worker;
```

- **什么时候建**：
  - 新项目在建项目的同一个 worker 事务里写入。KMS 先在事务外包好 DEK，`create_project` 再一起写进去；
  - 0032 搬过来的项目用 `ensure_project_key` 补建。
- **不会在删除后复活**：补建是 `INSERT`，外键检查会对 `projects` 那一行加 KEY SHARE 锁，和删项目的 `DELETE` 互斥；项目已经没了的话，外键直接失败。调研 keys 图担心的“删除以后又悄悄生成一把新密钥”在这里由外键挡住。
- **keyvault**：沿用现在以字符串作所有者的接口，所有者写成 `project:<uuid>`。这个前缀永远不会和用户 id 混淆。
  - 新的 AAD 域：`thinktin/project-blob/v1/`、`thinktin/project-board/v1/`（lib.rs:768-795 旁边）；
  - 新的错误 `Error::NoProjectKey`。outbox.rs:671-676 会把 `NoUserKey` 当成“账号已注销”，不能和它混用；
  - `AliyunKms::context()`（aliyun/kms.rs:39-41）：所有者以 `project:` 开头时输出 `{"purpose":"thinktin-project-dek","project":"<uuid>"}`，用户的格式一个字节都不改，否则已经包好的用户 DEK 就解不开了。
- **orchestrator**：在 `user_vault`（artifacts.rs:159-211）旁边加 `project_vault(db, kms, project)`。

### 5.2 项目看板

```sql
CREATE TABLE project_board_posts (
    id                 uuid PRIMARY KEY,
    project_id         uuid NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
    author_user_id     uuid NOT NULL,
    author_instance_id uuid,                          -- agent 写的；NULL 是成员在 App 里写的
    run_id             uuid,
    by_agent           boolean NOT NULL,
    sealed             bytea NOT NULL,                -- 正文用项目 DEK 加密（AAD：项目 + 条目 id）
    body_chars         integer NOT NULL CHECK (body_chars BETWEEN 1 AND 2000),
    tags               text[] NOT NULL DEFAULT '{}' CHECK (cardinality(tags) <= 8),
    mentions           uuid[] NOT NULL DEFAULT '{}' CHECK (cardinality(mentions) <= 10),
    created_at         timestamptz NOT NULL DEFAULT now(),
    archived_at        timestamptz,
    revived_at         timestamptz,
    FOREIGN KEY (project_id, author_user_id) REFERENCES project_members (project_id, user_id),
    FOREIGN KEY (project_id, author_instance_id, author_user_id)
        REFERENCES project_agents (project_id, instance_id, user_id),
    -- 只能挂在同一个项目的运行上；运行删了（作者注销）条目还在。
    FOREIGN KEY (run_id, project_id) REFERENCES runs (id, scope_id) ON DELETE SET NULL (run_id),
    CHECK (by_agent = (author_instance_id IS NOT NULL))
);
CREATE INDEX project_board_live ON project_board_posts (project_id, id DESC) WHERE archived_at IS NULL;
```

- **作者还在不在**：触发器 `project_board_guard` 在插入时检查作者是现任成员、作者 agent 是现任 agent、`mentions` 里都是现任成员、项目进行中。条目的外键指向的成员行、agent 行退出时只是标记，不会删，所以退出或注销后条目还在。作者显示为“已退出的成员”还是“已注销的用户”，看 `project_members.left_reason`。
- **成员角色在 App 里的写权限**：
  - 发条目：`WITH CHECK (project_id = (SELECT app_project_id()) AND author_user_id = app_user_id() AND NOT by_agent AND author_instance_id IS NULL AND (SELECT app_project_writable()))`，列权限只给插入要用的那些列；
  - 归档、取消归档：作者本人或创建者，列权限只有 `UPDATE (archived_at, revived_at)`；
  - 删除：只有创建者。
- **agent 写**：项目运行里的 `board_post` 用 worker 写，完整性由外键和触发器兜底：
  - 写之前用作者主人的保险箱抹值，沿用 board.rs:85-89；
  - 用项目 DEK 加密；
  - `board.posted` 事件在同一个 worker 事务里写；
  - 上限照私人看板：每个项目 200 条没归档的，咨询锁是 `board/project/<id>`。
- **标签**：标签是明文，格式受限，读的时候按标签过滤要用。正文加密。

### 5.3 项目产出物

```sql
CREATE TABLE project_artifacts (
    id             uuid PRIMARY KEY,
    project_id     uuid NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
    author_user_id uuid NOT NULL,
    instance_id    uuid NOT NULL,
    run_id         uuid,
    root_run_id    uuid NOT NULL,                 -- 名字空间：和私人产出物一样按运行树（ArtifactScope.own）
    name           text NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
    version        integer NOT NULL CHECK (version > 0),
    content_type   text NOT NULL,
    size           bigint NOT NULL CHECK (size >= 0),
    sha256         bytea NOT NULL,
    blob_key       text NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (root_run_id, name, version),
    FOREIGN KEY (project_id, instance_id, author_user_id) REFERENCES project_agents (project_id, instance_id, user_id),
    FOREIGN KEY (run_id, project_id) REFERENCES runs (id, scope_id) ON DELETE SET NULL (run_id),
    -- 清理触发器信得过这个键：只能在这个项目自己的前缀下。
    CHECK (starts_with(blob_key, 'projects/' || replace(project_id::text, '-', '') || '/'))
);
CREATE INDEX project_artifacts_tree ON project_artifacts (root_run_id, name, version DESC);
CREATE INDEX project_artifacts_project ON project_artifacts (project_id, created_at DESC);
```

- **清理**：删除时由触发器把 `blob_key` 排进 `blob_purge`。触发器的属主是迁移账号，因为 `blob_purge` 不是 FORCE 的；先例是 0007:40-48、0023:31-61。这里也加上 0023 那样的前缀检查。
- **发布**：`ArtifactStore::publish` 按 `Origin.space` 分两路：
  - 私人：照旧；
  - 项目：文本类的先用发布者主人的保险箱抹值；
  - 项目：用项目 DEK 加密，所有者是 `project:<uuid>`，键是 `projects/<p32>/<a32>`；
  - 项目：写索引的 worker 事务里核对项目还在（外键），失败就删掉 blob，沿用 artifacts.rs:330-337。
- **读**：`read` 按 `StoredArtifact.space` 选密钥，永远不会退回用用户 DEK。
- **成员角色的权限**：可以读。可以删除，条件是 `author_user_id = app_user_id() OR (SELECT app_project_role()) = 'creator'`，也就是作者主人（还在项目里时）或创建者。`blob_key` 成员写不了。

### 5.4 删项目

`Tx<Worker>::delete_project(project, actor)`，一个事务完成：

1. 锁 `projects` 那一行，核对 `creator_id = actor`。
2. 锁住项目里所有没结束的运行，按 id 排序，沿用 `lock_runs_where!`；相关实例 `token_epoch` 加一；状态改成已取消，原因是 `project deleted`。
3. 吊销 `project_id = P` 的授权。
4. 每个出现过的 `(实例, 项目)` 排一条沙箱清理（6.4 节）。
5. 给现任成员写一条收件箱通知。这条不带 `project_id`，免得被级联删掉；正文里写项目名。
6. `DELETE FROM projects WHERE id = $1`，级联删掉：
   - 密钥（销毁）、成员、agent、邀请、计数器；
   - 看板、产出物（blob 排进清理队列）；
   - 项目计划，以及计划带着的步骤、触发器、webhook；
   - 项目运行，以及运行带着的事件、审批、实时活动；
   - 指向这个项目的收件箱条目。

运行的提示词、摘要、事件都是明文（progress.md 第 9 条决定），只销毁密钥并不能让它们读不出来，所以这里直接删掉。这和 projects.md 4.6“项目运行的内容都读不出来了”的效果一致。`usage_records` 只有 id 和计数，保留。`content_reports` 是审核留底，保留。

### 5.5 注销（16.4、16.6）

`erase_account`（users.rs:183-231）在现在的步骤之前加两步：

1. 自己建的每个项目都调 `delete_project`。
2. 自己参加的别人的项目：调 `detach_member(project, user, Erased)`。这一步取消自己的项目运行和它们的子孙，吊销项目授权，agent 和成员行标记退出（`left_reason = 'erased'`），删掉自己发出的和收到的邀请，并通知创建者。

然后照旧执行 `DELETE FROM runs WHERE user_id = $1`。这一步会经 `runs_parent_scope` 把挂在他运行下面的别的成员的子运行一起删掉。这些是那棵运行树的执行记录，用量记录还在。项目看板条目和项目产出物属于项目，作者外键指向的是标记过的行，所以保留，作者显示“已注销的用户”；内容里如果有个人信息，按 16.6 处理。还要补 `DELETE FROM user_blocks WHERE blocker_id = $1 OR blocked_id = $1`，以及 `project_templates` 的删除。注销测试的表清单（tests.rs:1063-1086）补上所有新表。

## 6. 会话和工作区（8.16）

### 6.1 作用域怎么落到沙箱里

| | 私人 | 项目 P |
|---|---|---|
| 会话键 | `private` | `p<32hex>` |
| cwd（相对 `/sandbox/workspace`） | `private`（**从 `.` 挪出来**） | `projects/<32hex>` |
| HOME | `.thinktin/home`（不变，私人记忆保留） | `.thinktin/h/p<32hex>`（每个项目一个，方案 B） |
| 交接目录 | `private/handoff` | `projects/<32hex>/handoff` |

- **为什么每个项目一个 HOME（方案 B）**：只分开 cwd（方案 A）挡不住几样东西：Hermes 会把 `MEMORY.md`、`USER.md` 注入每个会话，它的 `session_search` 还能搜到私人对话；Claude 的 `~/.claude/CLAUDE.md`、技能、`~/.git-credentials` 也会被带进项目。每个项目一个 HOME 能把所有 agent 的状态目录都分开，删项目时 `rm -rf` 就干净了。代价是 agent 在项目里用不上主人攒下的记忆和技能，而 projects.md 第 6 节要的正是这种隔离。HOME 由 `config::render` 每次启动重新生成（config.rs:97-150），模型路由不受影响。
- **为什么私人 cwd 要挪**：项目目录如果嵌在私人 cwd 里，私人运行会看到 `projects/`；项目会话往上找父目录时，又会读到私人目录里的 `CLAUDE.md` 和 `AGENTS.md`。所以两边改成平级目录。
  - 新的 shim 第一次带 `--cwd private` 启动、`private/` 还不存在时，把工作区顶层除 `.thinktin`、`projects` 以外的东西都挪进 `private/`；
  - 私人会话会因为 cwd 变了接不回来一次，这时有 7.12 的续跑简报兜底；
  - 现在只有开发数据。
- **socket 路径**：`/sandbox/workspace/.thinktin/h/p<32hex>/.thinktin/platform-tools.sock` 一共 94 字节，在 bridge.rs:416 的上限以内。
- **这不是安全边界**：一个沙箱里只有一个 Unix 用户（Dockerfile:36），`ExecSpec` 也只有 argv、env、cwd（sandbox lib.rs:115-121）。被诱导的 agent 照样能读 `../private`。所以：
  - 跨用户项目里派非专属实例时，接口要求带 `ack_shared_memory: true`，App 弹 projects.md 第 6 节那条提示；
  - 推荐用专属实例。

### 6.2 改动清单

- `orchestrator/src/shim.rs:16-28`：`ShimLaunch` 加 `scope: Scope`。`SessionScope { key, cwd, home }` 由 `Scope` 在服务端算出，用的是项目 UUID 的简写形式，绝不用项目名或 agent 给的路径。
- `exec.rs:103-140`：`--home <home> --cwd <cwd> --session-key <key>`。`ExecSpec.cwd` 仍然是 `workdir`，这样 `.thinktin/platform-tools.json`（exec.rs:172-180）的相对路径不变。
- `agent-shim`：
  - `main.rs` 加 `--session-key`（`[a-z0-9-]{1,64}`，默认 `private`）；
  - `state.rs:16-37` 改成 `HOME/.thinktin/sessions/<key>.json`，`private` 这个键先回头读老的 `shim-session.json`；
  - `previous_session` 的 cwd 检查（shim.rs:270-274）保留，作为保险；
  - 一次性的目录迁移，见 6.1。
- `catalog`：`Harness.command` 支持 `{session_key}` 占位，openclaw.toml:26 改成 `--session agent:main:thinktin-{session_key}`。`private` 映射回老的 `agent:main:thinktin`，保留开发数据里的历史。
- `ArtifactTools::workspace_path`（tools.rs:504-507）、`fetch` 的默认路径（641）、`HandoffCopier`（pipeline.rs:469）：前面加上 `ctx.scope` 对应的 cwd，不再用固定的 `workdir`。
- `executor.rs:780-794`：打断的开头说明跨作用域时不引用标题（3.2 节）。

### 6.3 并发

“一个实例同时只有一个运行”（0002:48-51）保留。HOME、bridge 的 socket、OpenClaw 的端口 18789、每次启动重写配置文件，都依赖这条规则才安全。代价是：别人的项目运行占着一个非专属实例时，主人的私事得排队。App 在实例页显示“正在项目 P 里忙”。主人随时可以撤回这个 agent，或者用紧急消息打断它，主人有打断自己 agent 的权利。

### 6.4 退出和删除时的清理

```sql
-- 要从沙箱里删掉的作用域（撤回、退出、移出、删项目）。不引用 projects：项目删了它还在。
CREATE TABLE scope_cleanups (
    instance_id uuid NOT NULL,
    scope_key   text NOT NULL CHECK (scope_key ~ '^p[0-9a-f]{32}$'),
    queued_at   timestamptz NOT NULL DEFAULT now(),
    done_at     timestamptz,
    PRIMARY KEY (instance_id, scope_key)
);   -- 只有 worker 能读写；FORCE RLS，没有业务策略
```

- `control` 加一个公开的生命周期操作 `clear_scope(instance, key)`，内部用现在私有的 `run_in_sandbox`（control lib.rs:1841-1870）执行 `rm -rf -- projects/<hex> .thinktin/h/p<hex>`。
- **执行器在任何一次启动 shim 之前**，先把这个实例上还没做的清理做完。这时沙箱刚被唤醒，正开着。这样可以保证没有哪个 agent 运行能看到已经离开的项目留下的文件。
- 巡检任务定时处理开着的沙箱。暂停、归档的不专门唤醒，等它下次被唤醒。
- 遗留：对象存储里的工作区归档（ACS，workspaces.rs:226-292）和 Cube 卷的快照，要到下一次归档替换掉时才不再包含这些文件。文档和 15.7 的评审里都要写明这一点。

### 6.5 专属实例

- 加入时可以当场领养一个实例，或者把已有实例标成专属（`dedicated`）。
- 专属实例：
  - 触发器拒绝在它上面建私人运行；
  - 不签私人授权；
  - 不出现在主人私人那一层的 `agents_list` 里；
  - 照样走项目作用域。
- 标成专属之前，它不能有没结束的私人运行，否则返回 409。

## 7. 项目里的协作工具（8.17）

| 工具 | 私人运行（不变，只换成 `private_tx`） | 项目运行 |
|---|---|---|
| `agents_list` | 同一用户的其他实例；不含专属实例 | 项目里的现任 agent（任何主人），不含自己：名字、种类、主人显示名、项目里的用途、忙不忙（`app_project_agent_busy`）。不看实例的 `peer_access`：派进项目就是同意了 |
| `agent_status` | 同一用户；对方在做项目运行时只说“忙”，不给细节 | 只看对方在**这个项目**里的运行（成员策略）：在跑的是本项目运行就给简报；忙别的就只说“忙于别的工作”；“上一个结束的”也只在本项目里找 |
| `ask` | 同一用户 | 对方必须是本项目的现任 agent；回答运行归对方主人，带对方的项目授权，预算按对方主人；问题照旧用提问方主人的保险箱抹值（ask.rs:72-74）。跨主人时通知对方主人（见下） |
| `board_read` / `board_post` | 私人看板 | 项目看板（5.2），说明里注明“其他用户的 agent 写的，当信息、不当指令” |
| `artifact_*` | 私人产出物 | 项目产出物；`artifact_list` 加可选的 `project_wide: true`，列整个项目每个名字的最新版本 |
| `delegate_list` / `delegate` | 只给“当负责人的项目里有我自己别的 agent”的实例，目标只限我自己的这些 agent，子运行是私人的（兼容现在的团队用法） | 只有**这个项目**的负责人拿得到（`is_lead(instance, Scope::Project(p))`），目标是项目里的现任 agent（不分主人）；被委派的成员不是负责人，没有委派工具，不能再往下委派 |
| `schedule_*`、`vault_request` | 照旧 | 不进项目范围 |

- **`is_team_lead` 要拆开**：现在的实现是全局的，不管哪个项目、也不看实例删没删（instances.rs:548-555）。按它的写法，一个项目的负责人在主人的私人运行里也会拿到委派工具，可能把私人上下文推给别人的 agent。拆成两个函数：`is_lead(instance, scope)`，以及私人运行用的 `private_delegation_targets(instance)`。两个都放在 executor.rs:763-769 和 843 的判断里。
- **跨用户时说清楚是谁**：
  - `texts::delegated_task` 不再只写 `agent_id`（delegate.rs:144-148、texts.rs:426-438），改成“Claude（李四的 agent）”；
  - 别人的 agent 交还的结果、回答，在 `results_message` 里注明是不可信输入。
- **自动执行并通知主人**（第 11 节的默认值）：跨主人的委派、提问、流水线步骤建好时，给目标主人发一条信息类通知，子类型 `project_task_assigned`，按（项目，实例，小时）去重。主人随时可以停下或撤回。
- **防互相干等的锁改成全局**：`lock_run_waits(user)`（runs.rs:428-435）换成全局咨询锁 `run_waits`。只按两个用户加锁不够：四个用户的环 1→2→3→4→1 里，1→2 和 3→4 这两条边不共享任何一把用户锁，同时检查时谁都看不到对方，环就漏过去了。一个环可能同时经过私人边和项目边，所以按项目加锁也不够。
  - `instance_waits_for`（runs.rs:1227-1252）在 worker 下本来就跨用户沿图查找，查询本身不用改，改的只是串行化范围；
  - 建委派、提问只是几条语句，持锁的时间是毫秒级；
  - 关掉实例交流开关时（`accepts_questions`），也拿这把锁。
- **项目流水线**（P8）：
  - 计划带上 `project_id`，归创建者，托管在创建者自己的一个项目 agent 上（外键 `plans_project_host`）。创建者在项目里没有 agent 时，建流水线返回 409，提示“先派一个自己的 agent”；
  - 步骤可以落在任何现任项目 agent 上。`plan_steps` 加 `project_id`、`scope_id`、`agent_owner_id`；外键 `(instance_id, user_id)` 换成 `(instance_id, agent_owner_id) → instances`；再加 `(project_id, instance_id, agent_owner_id) → project_agents` 和 `CHECK (project_id IS NOT NULL OR agent_owner_id = user_id)`；
  - `start_step`（pipeline.rs:208-273）：步骤运行归步骤 agent 的主人，授权是项目子授权（`via` 是计划授权），预算按步骤主人；
  - `HandoffCopier` 读项目产出物，用项目密钥解开；
  - 撤回或退出时，`retire_instance_plans` 的 worker 版本暂停那些有步骤落在这个 agent 上的项目流水线（现在是租户的，plans.rs:314-345）。

## 8. 邀请、加入、通知、事件流和接口（8.14、8.19）

### 8.1 邀请和拉黑（0034）

```sql
CREATE TABLE project_invites (
    id          uuid PRIMARY KEY,
    project_id  uuid NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
    inviter_id  uuid NOT NULL REFERENCES users (id),
    kind        text NOT NULL CHECK (kind IN ('phone', 'link')),
    invitee_id  uuid REFERENCES users (id),     -- 手机号邀请找到的用户；还没注册的，注册时按 phone_hash 认领
    phone_hash  bytea,                          -- HMAC(手机号)，不存明文（和验证码同一把密钥）
    token_hash  bytea UNIQUE,                   -- 链接邀请：地址里令牌的 SHA-256（同 plan_hooks）
    max_uses    integer CHECK (max_uses BETWEEN 1 AND 10),
    uses        integer NOT NULL DEFAULT 0,
    status      text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined', 'revoked', 'expired')),
    expires_at  timestamptz NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    decided_at  timestamptz,
    CHECK ((kind = 'phone') = (phone_hash IS NOT NULL)),
    CHECK ((kind = 'link') = (token_hash IS NOT NULL AND max_uses IS NOT NULL))
);
CREATE INDEX project_invites_invitee ON project_invites (invitee_id) WHERE status = 'pending';
CREATE INDEX project_invites_inviter ON project_invites (inviter_id, created_at DESC);
CREATE TABLE user_blocks (
    blocker_id uuid NOT NULL REFERENCES users (id),
    blocked_id uuid NOT NULL REFERENCES users (id),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (blocker_id, blocked_id),
    CHECK (blocker_id <> blocked_id)
);
```

- **策略**：
  - 租户能看发给自己的待处理邀请：`invitee_id = app_user_id() AND status = 'pending'`，并且邀请人没有被自己拉黑；
  - 成员角色：只有创建者看得到这个项目的邀请；
  - `user_blocks` 只能看到自己发起的拉黑。
- **限流**：
  - 每个邀请人每 24 小时 20 个邀请，按邀请人加咨询锁再数；
  - 每个项目同时最多 20 个待处理的邀请；
  - 链接默认 7 天有效，最多用 10 次。
- **拉黑**：拉黑以后，对方之前发来、还没处理的邀请改成 `declined`。对方再发，接口照样返回成功，但不送达，也不通知，免得变成探测“我有没有被拉黑”的手段。
- **加入**（`POST /v1/project-invites/{id}/accept` 或 `/v1/invite-links/{token}/accept`）：
  1. 要当场领养专属实例的话，先在租户事务里领养（`control::adopt_in`，不签私人授权）并提交；
  2. 再开一个 worker 事务，做下面这些事：
     - 核对邀请有效，并锁住邀请行；
     - 写入成员行，或者把退出过的行重新激活；`consented_at` 必填，由 CHECK 保证；
     - 写入 agent 行；非专属实例在多人项目里必须带 `ack_shared_memory`；
     - 签发项目授权；
     - `uses` 加一；
     - 通知本人和创建者。
  3. 第 2 步失败时，补偿删除第 1 步领养的实例。
  - 跨用户开关 `projects.cross_user` 关着的时候，接受别人的邀请返回 403。
- **调整**：
  - 增派、撤回自己的 agent；
  - 改自己的预算：唤醒停在“等额度”的运行；
  - 改授权（电脑、保险箱、预授权）：重签项目授权，`token_epoch` 加一；
  - 退出：`detach_member(..., Left)`；
  - 创建者移出成员：`detach_member(..., Removed)`；
  - 创建者更换负责人。
  - 这些都走 worker，权限判断写在 SQL 里，副作用（取消运行、吊销授权、清理排队、通知）和状态修改在同一个事务里。

### 8.2 通知

| 事件 | 推给 |
|---|---|
| 邀请 | 被邀请人（已注册的） |
| 加入、退出、被移出 | 当事人、创建者 |
| 项目任务完成、失败 | 创建者，加上这棵运行树里出过力的主人（不重复） |
| 子任务、回答进入等待（等审批、等额度、等电脑） | 这个运行的主人（现在 executor.rs:1155-1164 的规则不变） |
| 审批 | 只推给主人（不变） |
| 被派了任务（跨主人，自动执行） | 目标 agent 的主人 |
| 项目看板上被 @ | 被 @ 的现任成员 |
| 项目删除 | 现任成员 |

- **新增的通知子类型**（`notice_subtype`）：`project_invited`、`project_joined`、`project_left`、`project_removed`、`project_deleted`、`project_task_assigned`、`project_mention`。等待原因新增 `project_budget`。
- **按收件人生成**：`notify` 照旧一次只发给一个用户（outbox.rs:195-212），文案按收件人的语言生成。
- **收件箱条目**：带 `project_id`；不是运行主人的收件人，`instance_id` 填 NULL（库里的外键要求实例属于收件人）。
- **IM**：项目相关的通知首版**不发 IM**。IM 群在项目成员关系之外，会把别人 agent 写的摘要带到第三方群里。

### 8.3 项目事件流

- **序号**：用 2.5 节触发器分配的 `project_seq`，所以项目运行的事件同时出现在主人的实例事件流里（租户，按 `seq`）和项目事件流里（成员，按 `project_seq`）。
- **通知频道**：触发器另发 `pg_notify('thinktin_project_events', project_id)`（0036）。新开一个频道，因为老副本会把 `thinktin_events` 的内容当成 `InstanceId` 来解析（hub.rs:82）。
- **订阅**：`EventHub` 加一张按 `ProjectId` 订阅的表。
- **接口**：
  - `GET /v1/projects/{id}/events?after=&limit=`：分页，返回里带 `oldest` 和 `latest`，取自 `project_event_range`，不读 `instances` 那一行；
  - `GET /v1/projects/{id}/events/ws?after=`：每次被唤醒都开一个新的 `Db::project` 事务来取，退出以后自然什么都取不到；心跳时再核对一次 `role()`，不再是成员就用专门的关闭码关掉连接（现在心跳只核对令牌，events.rs:194-205）；
  - 一个项目页只占一个流的名额（`open_stream`），不用把每个成员实例的流都订阅一遍。
- **实例级事件**（`run_id` 为空）只给主人看，成员通过 `app_project_agent_busy` 知道忙不忙就够了。
- **client-core**：项目事件的游标单独存一张表，按项目分。收到 `project_left`、`project_removed`、`project_deleted` 通知，或者请求返回 404 时，清掉这个项目的缓存（cache.rs:30-33 现在只按实例）。

### 8.4 REST

```
GET    /v1/projects                                   我参加的项目（含角色、我的 agent）
POST   /v1/projects                                   {name, goal, agents:[{instance_id, dedicated?, purpose?}], lead_instance_id?}
GET    /v1/projects/{id}                              ProjectDetail（项目、成员、agent、我自己的预算和授权）
PATCH  /v1/projects/{id}                              {name?, goal?, lead_instance_id?}            创建者
POST   /v1/projects/{id}/archive | /unarchive                                                     创建者
DELETE /v1/projects/{id}                                                                          创建者
POST   /v1/projects/{id}/agents                       {agents:[…], adopt?:{agent_id, harness?, name}, ack_shared_memory?}
PATCH  /v1/projects/{id}/agents/{instance}            {purpose?, dedicated?, allow_computer?, vault_item_ids?, preauthorized_tools?, approval_timeout_secs?}  主人
DELETE /v1/projects/{id}/agents/{instance}                                                        主人或创建者
PATCH  /v1/projects/{id}/members/me                   {daily_token_limit?, total_token_limit?}
DELETE /v1/projects/{id}/members/me                   退出
DELETE /v1/projects/{id}/members/{user}               移出（创建者）
POST   /v1/projects/{id}/invites                      {phone} | {link:{max_uses?, ttl_hours?}} → {invite, url?}   创建者
GET    /v1/projects/{id}/invites | DELETE …/{invite}                                              创建者
GET    /v1/project-invites                            发给我的
GET    /v1/project-invites/{id} | POST …/accept | POST …/decline
GET    /v1/invite-links/{token} | POST …/accept
GET    /v1/blocks | POST /v1/blocks {user_id} | DELETE /v1/blocks/{user}
GET    /v1/projects/{id}/runs?active=&roots=&before=&limit=
GET    /v1/projects/{id}/runs/{run} | …/tree | …/artifacts
POST   /v1/projects/{id}/runs                         {instance_id, prompt, delivery?}             创建者
POST   /v1/projects/{id}/runs/{run}/cancel?tree=      创建者、主人（4.6）
GET    /v1/projects/{id}/board | POST …               {body, tags?, mentions?}
POST   /v1/projects/{id}/board/{post}/archive | /unarchive | DELETE …/{post}
GET    /v1/projects/{id}/artifacts | GET …/{a} | GET …/{a}/content | DELETE …/{a}
GET    /v1/projects/{id}/events | GET …/events/ws
GET    /v1/projects/{id}/plans | POST …               项目流水线（P8，创建者）
GET    /v1/project-templates | POST … | DELETE …/{id} | POST …/{id}/adopt
```

- 所有项目路由都先开 `s.db.project(who.user, id)`，再调 `role()`。不是成员一律返回 404。
- 有副作用的路由在核对完以后转到 `Db::worker`。
- `/v1/team-templates*` 和 `/v1/project-templates*` 读写的是同一张表。

### 8.5 FFI（client-core）

- **新增记录**：
  - `Project { id, name, goal, status, creator_id, my_role, created_at_ms, archived_at_ms }`
  - `ProjectMember { user_id, display_name, role, joined_at_ms, left_at_ms, left_reason }`
  - `ProjectAgent { instance_id, owner_id, owner_name, name, agent_id, purpose, is_lead, dedicated, status }`
  - `MyProjectAgentSettings { allow_computer, vault_item_ids, preauthorized_tools, approval_timeout_secs }`
  - `ProjectDetail { project, members, agents, my_budget, my_settings }`
  - `ProjectInvite { id, project_id, project_name, inviter_name, invitee_phone_masked, url, expires_at_ms, status }`
  - `InvitePreview { project_name, goal, creator_name, members, agents }`
  - `ProjectBoardPost`、`ProjectEvent { project_seq, instance_id, run_id, kind, payload_json, created_at_ms }`
  - `ProjectTemplate`：和 `TeamTemplate` 同构
- **已有记录只加字段**，都标 `#[uniffi(default = None)]`，老的绑定照常能用：
  - `Run`：`project_id`、`owner_id`、`requested_by`
  - `Artifact`、`InboxItem`、`Approval`：`project_id`
- **方法**：
  - 项目：`projects`、`project`、`create_project`、`update_project`、`set_project_lead`、`archive_project`、`unarchive_project`、`delete_project`
  - agent：`add_project_agents`、`adopt_project_agent`、`update_my_project_agent`、`withdraw_project_agent`
  - 成员：`set_project_budget`、`leave_project`、`remove_project_member`
  - 邀请：`invite_by_phone`、`create_invite_link`、`revoke_invite`、`project_invites`、`my_project_invites`、`invite_preview`、`accept_invite`、`accept_invite_link`、`decline_invite`
  - 拉黑：`blocks`、`block_user`、`unblock_user`
  - 运行：`project_runs`、`project_run_tree`、`create_project_task`、`cancel_project_run`
  - 看板：`project_board`、`post_project_board`、`archive_project_post`、`delete_project_post`
  - 产出物：`project_artifacts`、`project_artifact_content`、`delete_project_artifact`
  - 事件：`project_events`，以及订阅接口 `subscribe_project_events(project_id, after, listener)`，形状照实例事件的订阅
  - 模板：`project_templates`、`create_project_template`、`adopt_project_template`、`delete_project_template`
- **团队的 10 个方法和 `Team*` 记录原样保留。**
- **这个容器里能做的**：重新生成 Android 的 `client_core.kt`，iOS 的绑定在构建时生成。界面放在 12.25 和 13.18。

## 9. 分期

每一期都要编译通过，跑通 `cargo test --workspace`（集成测试连 Postgres）和 `cargo clippy --workspace --all-targets`，而且系统照常能用。

| 期 | 范围 | 主要文件 | 测试 | 风险 |
|---|---|---|---|---|
| **P1 边界底座**（0031） | 两个角色；项目、成员、agent、模板、事件计数器；成员关系函数；`scope_id` 和外键替换；触发器；租户策略收窄；成员策略；`Db::project`、`Db::private_scope`、`Db::project_scope`、`Tx<Member>` 的读接口；42501 映射成 404。程序还不写任何项目行，App 不受影响 | store/migrations/0031、store/src/lib.rs、新的 store/src/projects.rs、store/src/{runs,events}.rs（只改列和宏）、gateway/src/error.rs、docs/deploy-checklist.md（预建 `thinktin_member`、`thinktin_definer`，`GRANT thinktin_member TO thinktin_server_login`，`GRANT thinktin_definer TO thinktin_owner`） | 3.6 节第 1-4 项全部；现有的 `tenants_are_isolated`、`erasing_an_account_deletes_its_content`、全部 gateway、orchestrator 测试不改也能通过；`EXPLAIN` 确认 `list_runs` 还用部分索引 | **高**：外键替换、策略重写、每次插入事件多一次查找。所以放在最前面，而且这一期没有新功能 |
| **P2 团队搬进项目**（0032） | 复制数据（临时去掉 FORCE）；团队路由改成兼容视图；`delegation_targets` 和 `is_team_lead` 改成基于 `project_agents`（私人语义不变）；注销清单 | store/src/teams.rs 改成 projects.rs、gateway/src/routes/teams.rs、store/src/instances.rs:529-555、orchestrator/src/executor.rs:763-769 | 现有 `teams_pipelines_and_artifacts`（api.rs:1266+）、`ffi_teams_and_templates`（client-core tests:1491+）、委派测试（orchestrator tests/executor.rs:1917-2224）原样通过；新增“删实例以后可以重新设负责人” | 中 |
| **P3 工具按作用域开事务** | `ToolContext.scope`；所有工具改用 `private_tx` / `project_tx`；产出物工具的读按 `Scope` 分开；`clippy.toml` 禁用 `Db::tenant`；全局 `run_waits` 锁 | orchestrator/src/{shim,peers,board,ask,delegate,tools,vault,executor}.rs、crates/orchestrator/clippy.toml、store/src/runs.rs:428 | 私人运行下的工具看不到用 worker 直接插进去的项目行；全局锁下的环检测（四用户的环用库里构造的数据测） | 中 |
| **P4 项目密钥和项目内容**（0033） | `project_keys`、`project_board_posts`、`project_artifacts`、`scope_cleanups`；keyvault 新的 AAD 域和错误；Aliyun 的项目上下文；`project_vault`；`delete_project`；注销；网关的项目读接口和看板、产出物接口（这时只有单人项目）；FFI 第一批，重新生成 Android 绑定 | keyvault/src/lib.rs、aliyun/src/kms.rs、orchestrator/src/{artifacts,board}.rs、store/src/{projects,users,artifacts,board}.rs、gateway/src/routes/projects.rs、client-core/src/{api,ffi}.rs、apps/android/core/.../client_core.kt | 删项目以后密文解不开、索引全没了、blob 进了清理队列；删除和补建密钥并发时不会复活；注销之后别人项目里的看板和产出物还在，作者显示“已注销” | 中高 |
| **P5 会话和工作区** | shim 的 `--session-key`、每个作用域一个 HOME、私人 cwd 挪到 `private/`；exec 的参数；工具和交接的路径；OpenClaw 的会话键模板；清理队列和 `clear_scope`；**第一批项目运行**：创建者给自己的 agent 派任务（单人项目，项目授权签给自己） | agent-shim/src/{main,state,shim}.rs、catalog（manifest、openclaw.toml）、orchestrator/src/{exec,tools,pipeline,executor}.rs、control/src/lib.rs | e2e_shim：私人和项目两个会话交替跑，各自都能接回（e2e_shim.rs:289-317 的变体）；清理在下一次启动之前做完；交接文件写进作用域目录 | 中 |
| **P6 成员和邀请**（0034） | 邀请、拉黑、加入、退出、移出、上限、加入时的确认；签发别人 agent 的项目授权；成员相关的通知；跨用户开关（默认关）；FFI | store/src/projects.rs、gateway/src/routes/{projects,invites}.rs、orchestrator/src/outbox.rs、client-core | 网关三用户测试（3.6 第 5 项）；退出之后立刻 404；限流和拉黑不暴露信息；开关关着时接受返回 403 | 中 |
| **P7 跨用户执行和费用**（0035） | 创建者给别人的 agent 派任务；项目作用域下的委派、提问、状态、列表、看板、产出物；`via_grant_id` 和新的祖先判断；`GrantScope::intersect`；预授权取交集；电脑和保险箱按项目打开；模型网关硬预算和 `usage_records.project_id`；执行器按主人算预算；按主人路由审批；打断和全部停止；通知分发。15.7 安全评审做完以后打开跨用户开关 | orchestrator/src/{delegate,ask,peers,executor,waits,account,texts}.rs、store/src/{grants,runs,usage,llmgw,vault}.rs、llm-gw/src/{proxy,pg}.rs、auth/src/grants.rs、proto/src/domain.rs | 两个用户端到端（17.8 的子集）：各扣各的预算，项目预算用完停在等额度；审批推给主人；主人撤回或全部停止后，负责人签不出子授权；创建者的预授权不会落到成员的 agent 上；关掉电脑以后工具立刻没了 | **高** |
| **P8 事件流、项目流水线、模板**（0036） | 项目事件的 `pg_notify` 和 WS；`plan_steps` 跨主人；`start_step` 和交接按主人；项目模板的接口和 FFI；更新文档（architecture-v3 第 4.11 节、projects.md 写成“已做”、security-audit、threat-model） | gateway/src/{hub.rs,routes/events.rs}、orchestrator/src/pipeline.rs、store/src/plans.rs、client-core/src/events.rs、docs | WS：退出时连接被关掉；流水线跨主人交接成功，读的是项目产出物；撤回一个 agent 时，带它步骤的项目流水线被暂停 | 中 |

## 10. 对调研里待定问题的决定

**teams 图**
- 保留 `/v1/teams*`：保留，作为单人项目上的兼容视图（2.7），App 切换之后再删。
- 项目流水线放在哪：`plans.project_id`，归创建者，托管在创建者的项目 agent 上；根运行归创建者；每个步骤归它的 agent 的主人，用对方主人的项目授权（7）。
- `delegate_list` 能看到谁：项目运行里只看到这个运行所在项目的 agent；私人运行只看到自己的、并且在它当负责人的项目里的 agent。
- 不是负责人的成员能不能再委派：不能。
- 上限：项目 10 个用户、30 个 agent（库里管）；团队和模板的请求照旧校验 1-12。
- 负责人是布尔值还是枚举：`project_agents.is_lead` 布尔值，每个项目最多一个，不强制有。
- 搬过来的团队运行用哪个会话：不带 `project_id` 的运行（现在的团队用法）照旧用私人会话；只有项目运行用项目会话。
- 跨用户子运行的语言：平台写给 agent 的说明用目标主人的语言；通知按收件人的语言。
- 模板：保留 `TemplateMember`（agent 种类、接入方式、名字、角色），保留负责人这个角色。

**rls 图**
- 函数的属主：`thinktin_definer`，普通角色，加只读策略（1.3）。
- 数据库要不要把 agent 限定在当前项目：要。用 `app.project_id` 加成员角色；私人运行用 `app.scope=private`。
- 一棵运行树能不能跨用户：能。用 `scope_id` 外键保证树内只有同一个项目（2.3）。
- 成员看完整的运行行吗：不看，用列权限只给一部分（2.6）。
- 事件：项目运行的事件同时进实例流（主人）和项目流（成员，按 `project_seq`）；实例级事件只给主人。
- 项目状态在策略里怎么体现：已归档的照样能读，写入要求 `app_project_writable()`，触发器也查；删除不留行。
- 看板和产出物：单独建项目表（5.2、5.3）。
- 团队的数据：0031 只建结构，0032 搬数据，旧表留着。

**visibility 图**
- 事件流的形状：每个项目一个序号（`project_feeds`），锁的顺序是先实例、后计数器。
- 主人的实例页、`/v1/runs` 里要不要有项目运行：要，只要主人还是现任成员。
- 实例级事件：只给主人。
- 流水线根运行的主人：创建者。
- 实时活动：首版只给运行的主人，沿用 live.rs:35-42。
- 审批原因、权限请求：不给非主人看（`state_reason` 不授列权限，事件按白名单）。
- 谁能删项目产出物：创建者，或者作者的主人（还在项目里时）。
- 退出以后的收件箱：行留着但看不到（RLS），删项目时删掉。
- IM：不发。
- 删项目：直接删掉运行、事件、收件箱，看板和产出物靠销毁密钥。

**keys 图**
- 运行内容：删项目时删掉，不另外加密。
- 看板：正文加密，标签明文；单人项目也有项目密钥（补建）。
- 产出物：单独一张表，名字空间仍按运行树，另外能列整个项目的。
- 项目工作区目录：删掉（清理队列），不单独归档。
- 注销：贡献保留（5.5）。
- KMS 的所有者：字符串前缀 `project:`，Aliyun 输出单独的 purpose。
- 谁能删看板条目和产出物：创建者，或者作者的主人（还在项目里时）。
- 项目里发布的文本产出物要不要抹保险箱的值：要。

**sessions 图**
- 方案 A 还是 B：B。
- 私人 cwd 挪不挪：挪到 `private/`。
- 每种项目都分作用域吗：是，凡是项目运行都分，包括单人项目。
- 清理：执行器启动 shim 之前做，加上巡检；不强行唤醒沙箱。
- 专属实例：也走项目作用域。
- 记忆类功能要不要单独关：方案 B 之后不需要单独关。
- 项目工作区的磁盘配额：首版不单独设。
- 还要实测的：OpenClaw 2026.10.3 认不认任意会话键、多个键共用一个状态目录会不会互相串，放进 P5 的镜像集成测试。

**money 图**
- 根运行的主人：项目任务归 agent 的主人（`requested_by` 记创建者），流水线根归创建者。
- 预算在哪里拦：模型网关硬拦，执行器按主人算树里的用量；一天的边界用 `budget_utc_offset_secs`。
- `usage_records`：加 `project_id`，不加 `run_id`。
- 项目授权的形状：每个（实例，项目）一个顶层授权；子授权的 `parent_id` 是主人的项目授权，`via_grant_id` 是发起方的授权。
- 全部停止：取消自己的运行和它们在项目树里的子孙；项目授权吊销以后，要主人在项目页点“继续”。
- 审批超时：用主人的设置；项目运行的计划不是运行主人的时，“暂停计划”按失败处理。
- 跨用户委派要不要主人确认：在预算内自动执行，并通知主人。
- 项目运行和私人运行能不能并发：不能，一个实例同时只有一个运行。
- 搬过来的团队用什么默认值：老的用法不变（私人授权，完整的默认范围）；新的项目运行用项目的默认值（电脑和保险箱关）。

**我在这个角度上采用的别处的做法和理由**
- 项目内容放项目自己的表（调研 keys 图的建议）：只有这样，注销、退出时贡献能留下，删项目时销毁密钥才真正有效。
- 每个项目一个事件序号（visibility 图）：不暴露成员的私人事件数量，还能把事件按序续传。
- 跨用户的写入走 worker，在 SQL 里写明权限判断（visibility 图）：这些写入有副作用，要和状态修改在一个事务里；数据库强制的部分由约束和触发器承担。
- 每个项目一个 HOME（sessions 图的方案 B）：效果见 6.1。

## 11. 需要用户定的

1. **手机号邀请没注册的号码时，要不要发短信？** 发短信有成本，也有骚扰和合规风险。默认不发：等对方用这个号码注册时，邀请自动出现；急的话由创建者自己转发邀请链接。
2. **邀请的默认上限**：每人每天 20 个；链接 7 天有效、最多用 10 次。可以调。
3. **要不要让成员看到别人的 agent “忙 / 不忙”？** 这会让人知道对方的 agent 在忙别的（可能是私事）。默认显示，只有这一位信息。
4. **成员注销以后，他的 agent 在项目里的运行记录**（不是看板条目和产出物）**删不删？** 默认跟着他的账号一起删，挂在下面的别人的子运行记录也一起删，只留用量。
5. **要不要让别人看到自己 agent 在项目里花了多少 token？** 默认只有主人自己看得到。
6. **项目通知要不要发到成员绑定的 IM 群？** 默认不发。