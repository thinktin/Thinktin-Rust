-- 受控出网通道（WBS 2.7，docs/egress.md）：实例能上哪些网站、每天用了多少流量、访问日志。
-- 用户 2026-11-04 定的：默认只连模型；“全部公网”要用户自己打开；每实例同时 4 条、每天 100 MiB；日志 6 个月。

-- 档位和用户加的网站（接口按 proto::egress::normalize_host 整理后存）。已有的实例按默认只连模型。
ALTER TABLE instances
    ADD COLUMN egress_mode text NOT NULL DEFAULT 'model' CHECK (egress_mode IN ('model', 'dev', 'custom', 'all')),
    ADD COLUMN egress_hosts text[] NOT NULL DEFAULT '{}' CHECK (cardinality(egress_hosts) <= 50);
-- 0023 起业务角色按列授权：App 的实例设置改这两列。
GRANT UPDATE (egress_mode, egress_hosts) ON instances TO thinktin_app;

-- 每个实例每天（北京时间自然日）用掉的双向流量。出口代理开隧道、转发途中先从这里预留一段再转发，结束时退回
-- 没用完的，多副本也不会超。
CREATE TABLE egress_usage (
    instance_id uuid NOT NULL,
    user_id     uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    day         date NOT NULL,
    bytes       bigint NOT NULL DEFAULT 0 CHECK (bytes >= 0),
    PRIMARY KEY (instance_id, day),
    FOREIGN KEY (instance_id, user_id) REFERENCES instances (id, user_id) ON DELETE CASCADE
);
CREATE INDEX egress_usage_day ON egress_usage (day);

-- 访问日志：每条隧道（放行的和拒绝的）一行，只记元数据（实例、目标网站和端口、连上的地址、结果和原因、字节数、
-- 时长），不记路径、令牌和内容。网络安全法要求网络日志至少留 6 个月，所以不跟着实例删除、也不跟着注销账号删除
-- （没有外键），由后台到期删掉（6 个月）。
CREATE TABLE egress_log (
    id          uuid PRIMARY KEY,
    user_id     uuid NOT NULL,
    instance_id uuid NOT NULL,
    at          timestamptz NOT NULL DEFAULT now(),
    host        text NOT NULL,
    port        integer NOT NULL,
    address     text,
    allowed     boolean NOT NULL,
    reason      text NOT NULL,
    bytes_up    bigint NOT NULL DEFAULT 0,
    bytes_down  bigint NOT NULL DEFAULT 0,
    duration_ms bigint NOT NULL DEFAULT 0
);
CREATE INDEX egress_log_at ON egress_log (at);
CREATE INDEX egress_log_instance ON egress_log (instance_id, at DESC);

ALTER TABLE egress_usage ENABLE ROW LEVEL SECURITY;
ALTER TABLE egress_usage FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant ON egress_usage TO thinktin_app USING (user_id = app_user_id());
ALTER TABLE egress_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE egress_log FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant ON egress_log TO thinktin_app USING (user_id = app_user_id());

-- App 只读自己的用量和日志；模型网关（出口代理在它里面）记用量和日志；后台到期删除。
GRANT SELECT ON egress_usage, egress_log TO thinktin_app;
GRANT SELECT, INSERT, UPDATE ON egress_usage TO thinktin_llmgw;
GRANT INSERT ON egress_log TO thinktin_llmgw;
GRANT SELECT, DELETE ON egress_usage, egress_log TO thinktin_worker;
