-- 降级链（WBS 9.9）：别名的主 key 失效、欠费或被限流时，网关按顺序换备用的 key 和上游模型重发。
-- 备用项跟着主路由走：替换或删掉别名时一起删掉。
CREATE TABLE model_route_fallbacks (
    instance_id    uuid NOT NULL,
    alias          text NOT NULL,
    position       smallint NOT NULL CHECK (position BETWEEN 1 AND 3),
    user_id        uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    credential_id  uuid NOT NULL,
    upstream_model text NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (instance_id, alias, position),
    FOREIGN KEY (instance_id, alias) REFERENCES model_routes (instance_id, alias) ON DELETE CASCADE,
    FOREIGN KEY (instance_id, user_id) REFERENCES instances (id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (credential_id, user_id) REFERENCES credentials (id, user_id)
);
CREATE INDEX model_route_fallbacks_credential ON model_route_fallbacks (credential_id);

ALTER TABLE model_route_fallbacks ENABLE ROW LEVEL SECURITY;
ALTER TABLE model_route_fallbacks FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant ON model_route_fallbacks TO thinktin_app
    USING (user_id = app_user_id()) WITH CHECK (user_id = app_user_id());

GRANT SELECT, INSERT, DELETE ON model_route_fallbacks TO thinktin_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON model_route_fallbacks TO thinktin_worker;
GRANT SELECT ON model_route_fallbacks TO thinktin_llmgw;
