package cn.thinktin.app.ui.plans

import cn.thinktin.data.model.PlanStep
import cn.thinktin.data.model.Team
import cn.thinktin.data.model.TeamRole

/** 流水线最多几步（服务端 `routes/plans.rs` 的 MAX_STEPS）。 */
const val MAX_PIPELINE_STEPS = 20

/** 每步的提示词最多几个字（服务端 1–8000，去掉首尾空白后按码点数）。 */
const val MAX_STEP_PROMPT = 8000

/** 编辑中的一步：[id] 只在本地用（改键名时认得出是哪一步）。 */
data class StepDraft(
    val id: Long,
    val key: String,
    val instanceId: String?,
    val prompt: String,
    val dependsOn: List<String> = emptyList(),
) {
    fun toStep(): PlanStep = PlanStep(key.trim(), instanceId.orEmpty(), prompt.trim(), dependsOn)

    companion object {
        fun from(step: PlanStep, id: Long) = StepDraft(id, step.key, step.instanceId, step.prompt, step.dependsOn)
    }
}

/** 一步的问题（保存前在本地拦下，和服务端 `check_steps` / `order_steps` 一样）。 */
sealed interface StepProblem {
    val stepId: Long?

    /** 键名要 1–32 个 a-z 0-9 _ -，以字母或数字开头。 */
    data class BadKey(override val stepId: Long) : StepProblem

    data class DuplicateKey(override val stepId: Long) : StepProblem

    data class NoInstance(override val stepId: Long) : StepProblem

    /** 选的实例删掉了（服务端会拒绝：先改步骤）。 */
    data class DeletedInstance(override val stepId: Long) : StepProblem

    data class EmptyPrompt(override val stepId: Long) : StepProblem

    data class PromptTooLong(override val stepId: Long) : StepProblem

    /** 依赖的步骤不在了（改了键名、删了的会自动跟着改，剩下的是手写错的）。 */
    data class UnknownDependency(override val stepId: Long, val key: String) : StepProblem

    data class SelfDependency(override val stepId: Long) : StepProblem

    /** 依赖成环了。 */
    data object Cycle : StepProblem {
        override val stepId: Long? = null
    }

    data object TooMany : StepProblem {
        override val stepId: Long? = null
    }
}

/**
 * 流水线步骤的本地规则（13.7）：键名格式、唯一、依赖存在、不依赖自己、没有环（Kahn 拓扑排序，同一层按声明顺序），
 * 最多 20 步，提示词 1–8000 字。和服务端 `crates/proto/src/domain.rs` 的 `order_steps`、`routes/plans.rs` 的 `check_steps` 一致。
 */
object Pipeline {
    private val KEY = Regex("^[a-z0-9][a-z0-9_-]{0,31}$")

    fun isValidKey(key: String): Boolean = KEY.matches(key)

    /** [instances] 是还在的实例。 */
    fun problems(steps: List<StepDraft>, instances: Set<String>): List<StepProblem> = buildList {
        if (steps.size > MAX_PIPELINE_STEPS) add(StepProblem.TooMany)
        val counts = steps.groupingBy { it.key.trim() }.eachCount()
        val keys = counts.keys
        for (step in steps) {
            val key = step.key.trim()
            if (!isValidKey(key)) add(StepProblem.BadKey(step.id))
            if ((counts[key] ?: 0) > 1) add(StepProblem.DuplicateKey(step.id))
            when {
                step.instanceId.isNullOrEmpty() -> add(StepProblem.NoInstance(step.id))
                step.instanceId !in instances -> add(StepProblem.DeletedInstance(step.id))
            }
            val prompt = step.prompt.trim()
            if (prompt.isEmpty()) add(StepProblem.EmptyPrompt(step.id))
            if (prompt.codePointCount(0, prompt.length) > MAX_STEP_PROMPT) add(StepProblem.PromptTooLong(step.id))
            for (dep in step.dependsOn) {
                if (dep == key) add(StepProblem.SelfDependency(step.id)) else if (dep !in keys) add(StepProblem.UnknownDependency(step.id, dep))
            }
        }
        if (order(steps) == null) add(StepProblem.Cycle)
    }

    /** 拓扑序（键名）；有环时为 null。认不出的依赖不算（另报）。 */
    fun order(steps: List<StepDraft>): List<String>? {
        val keys = steps.map { it.key.trim() }.toSet()
        val done = LinkedHashSet<String>()
        val pending = steps.map { it.key.trim() to it.dependsOn.filter { d -> d in keys && d != it.key.trim() } }.toMutableList()
        while (pending.isNotEmpty()) {
            val ready = pending.filter { (_, deps) -> deps.all { it in done } }
            if (ready.isEmpty()) return null
            ready.forEach { done += it.first }
            pending.removeAll(ready)
        }
        return done.toList()
    }

    /** 新加一步的键名：`step1`、`step2`……没用过的第一个。 */
    fun nextKey(steps: List<StepDraft>): String {
        val used = steps.map { it.key.trim() }.toSet()
        return generateSequence(1) { it + 1 }.map { "step$it" }.first { it !in used }
    }

    /** 改一步的键名：别的步骤依赖它的跟着改。 */
    fun rename(steps: List<StepDraft>, id: Long, key: String): List<StepDraft> {
        val old = steps.firstOrNull { it.id == id }?.key ?: return steps
        val unique = steps.count { it.key == old } == 1
        return steps.map { s ->
            when {
                s.id == id -> s.copy(key = key)
                unique && old in s.dependsOn -> s.copy(dependsOn = s.dependsOn.map { if (it == old) key else it })
                else -> s
            }
        }
    }

    /** 删一步：别的步骤对它的依赖一起去掉。 */
    fun remove(steps: List<StepDraft>, id: Long): List<StepDraft> {
        val key = steps.firstOrNull { it.id == id }?.key ?: return steps
        val remaining = steps.filterNot { it.id == id }
        if (remaining.any { it.key == key }) return remaining
        return remaining.map { s -> if (key in s.dependsOn) s.copy(dependsOn = s.dependsOn - key) else s }
    }

    /** 上下挪一步（[delta] 是 -1 或 1）。 */
    fun move(steps: List<StepDraft>, id: Long, delta: Int): List<StepDraft> {
        val i = steps.indexOfFirst { it.id == id }
        val j = i + delta
        if (i < 0 || j !in steps.indices) return steps
        return steps.toMutableList().also { it[i] = steps[j]; it[j] = steps[i] }
    }

    /**
     * 用团队建流水线：每个成员一步（按顺序），负责人最后一步、依赖前面所有步骤（汇总）。提示词留空等用户写。
     * 计划挂在负责人的实例上。
     */
    fun fromTeam(team: Team, firstId: Long = 1): List<StepDraft> {
        val ordered = team.members.sortedBy { it.position }
        val members = ordered.filter { it.role != TeamRole.Lead }
        val lead = ordered.firstOrNull { it.role == TeamRole.Lead }
        val drafts = members.mapIndexed { i, m -> StepDraft(firstId + i, "step${i + 1}", m.instanceId, "") }
        return if (lead == null) {
            drafts
        } else {
            drafts + StepDraft(firstId + drafts.size, "summary", lead.instanceId, "", drafts.map { it.key })
        }
    }
}
