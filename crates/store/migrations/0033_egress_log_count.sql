-- 出网日志（2.7）合并行：一个实例一分钟里的日志超过上限时，同一个网站、同一种结果合并成一行，记下次数
-- （评审 2026-11-04：只给拒绝的设上限时，放行的隧道每条一行，几台实例一起刷就能把库撑满、清理也追不上）。
ALTER TABLE egress_log ADD COLUMN count integer NOT NULL DEFAULT 1 CHECK (count > 0);
-- App 看“最近被拒绝的访问”只扫拒绝的行。
CREATE INDEX egress_log_denied ON egress_log (instance_id, at DESC) WHERE NOT allowed;
