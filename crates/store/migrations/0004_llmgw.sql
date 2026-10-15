-- 模型网关按 key 的每日预算从用量表汇总（多副本共享），需要读用量表。
GRANT SELECT ON usage_records TO thinktin_llmgw;
