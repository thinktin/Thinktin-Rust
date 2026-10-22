-- 发布流程（2.9）：控制面、模型网关、设备中继启动时核对它们要的迁移都已经执行过，读迁移工具记的
-- `_sqlx_migrations`。服务的登录账号不是表的属主，经各自的服务角色授权（只读）。
GRANT SELECT ON _sqlx_migrations TO thinktin_worker, thinktin_llmgw, thinktin_relay;
