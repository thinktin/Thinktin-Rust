package cn.thinktin.data.model

/*
 * 运行树（13.5 运行页，第 4.7、8.6 节）：runTree() 的平铺列表 → 缩进树。
 * 卡在等待（等 key、等电脑、等审批）的子步骤要冒泡到根节点显示（团队模板领养出来的实例没有模型路由，一跑就等 key）。
 */

/** 树上的一行。[depth] 是缩进层级（根是 0）；[attention] 是它自己或子孙里最该处理的等待。 */
data class RunTreeNode(
    val run: Run,
    val depth: Int,
    val childCount: Int,
    val attention: RunAttention?,
)

/** 子孙里在等用户处理的那个运行：[run] 的状态和 [Run.waitCode] 决定横幅文案和操作。 */
data class RunAttention(val run: Run) {
    val state: RunState get() = run.state
    val waitCode: WaitCode? get() = run.waitCode
}

object RunTrees {
    /**
     * 平铺的运行 → 深度优先的行（父在子前，兄弟按创建时间）。父运行不在列表里的当作根（深度 0）；
     * 有环（坏数据）时每个运行只出现一次。
     */
    fun build(runs: List<Run>): List<RunTreeNode> {
        val byId = runs.associateBy { it.id }
        val children = runs.groupBy { run -> run.parentRunId?.takeIf { it in byId && it != run.id } }
            .mapValues { (_, list) -> list.sortedWith(compareBy({ it.createdAtMs }, { it.id })) }
        val out = mutableListOf<RunTreeNode>()
        val seen = mutableSetOf<String>()
        val attentionCache = mutableMapOf<String, RunAttention?>()

        fun attentionOf(run: Run, path: Set<String>): RunAttention? = attentionCache.getOrPut(run.id) {
            val own = if (run.state.needsAttention) RunAttention(run) else null
            val below = children[run.id].orEmpty()
                .filter { it.id !in path }
                .mapNotNull { attentionOf(it, path + run.id) }
            // 等 key / 等电脑比等审批更要用户动手（审批有自己的推送和审批中心），排在前面；同类取最早的。
            (listOfNotNull(own) + below).minWithOrNull(
                compareBy<RunAttention>({ priority(it.state) }, { it.run.createdAtMs }),
            )
        }

        fun visit(run: Run, depth: Int) {
            if (!seen.add(run.id)) return
            val kids = children[run.id].orEmpty()
            out += RunTreeNode(run, depth, kids.size, attentionOf(run, emptySet()))
            kids.forEach { visit(it, depth + 1) }
        }

        children[null].orEmpty().forEach { visit(it, 0) }
        // 环里的运行（没有根能走到）也列出来，不丢。
        runs.sortedBy { it.createdAtMs }.forEach { visit(it, 0) }
        return out
    }

    private fun priority(state: RunState): Int = when (state) {
        RunState.WaitingQuota -> 0
        RunState.WaitingDevice -> 1
        RunState.WaitingApproval -> 2
        else -> 3
    }

    /** 整棵树还有没结束的运行（顶部“停止整棵树”）。 */
    fun hasActive(nodes: List<RunTreeNode>): Boolean = nodes.any { it.run.state.isActive }
}
