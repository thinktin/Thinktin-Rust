package cn.thinktin.data

import cn.thinktin.data.model.Run
import cn.thinktin.data.model.RunKind
import cn.thinktin.data.model.RunSource
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.RunTrees
import cn.thinktin.data.model.WaitCode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 运行树（13.5 运行页）：缩进顺序、等待冒泡到根、父运行不在列表里、坏数据里的环。 */
class RunTreesTest {
    private fun run(
        id: String,
        parent: String? = null,
        state: RunState = RunState.Succeeded,
        createdAt: Long = 0,
        waitCode: WaitCode? = null,
    ) = Run(
        id = id, kind = RunKind.Agent, instanceId = "i-$id", planId = null, parentRunId = parent, rootRunId = "root",
        stepKey = null, source = if (parent == null) RunSource.User else RunSource.Pipeline, prompt = id, state = state,
        stateReason = null, attempt = 1, tokensUsed = 0, summary = null, error = null, createdAtMs = createdAt,
        startedAtMs = createdAt, finishedAtMs = null, waitCode = waitCode,
    )

    @Test
    fun depthFirstWithSiblingsByTime() {
        val nodes = RunTrees.build(
            listOf(
                run("b", parent = "root", createdAt = 20),
                run("root", state = RunState.WaitingChildren),
                run("a", parent = "root", createdAt = 10),
                run("a1", parent = "a", createdAt = 15),
            ),
        )
        assertEquals(listOf("root", "a", "a1", "b"), nodes.map { it.run.id })
        assertEquals(listOf(0, 1, 2, 1), nodes.map { it.depth })
        assertEquals(2, nodes[0].childCount)
        assertTrue(RunTrees.hasActive(nodes))
    }

    @Test
    fun waitingStepBubblesToRoot() {
        val nodes = RunTrees.build(
            listOf(
                run("root", state = RunState.WaitingChildren),
                run("a", parent = "root", state = RunState.WaitingApproval, createdAt = 1),
                run("b", parent = "root", state = RunState.Running, createdAt = 2),
                run("b1", parent = "b", state = RunState.WaitingQuota, createdAt = 3, waitCode = WaitCode.Invalid),
            ),
        )
        val root = nodes.first()
        // 等 key 比等审批更要用户动手：排在前面。
        assertEquals("b1", root.attention?.run?.id)
        assertEquals(WaitCode.Invalid, root.attention?.waitCode)
        assertEquals("a", nodes.first { it.run.id == "a" }.attention?.run?.id)
        assertNull(nodes.first { it.run.id == "b" }.attention?.run?.takeIf { it.id == "b" })
    }

    @Test
    fun orphansAreRootsAndCyclesDoNotLoop() {
        val nodes = RunTrees.build(
            listOf(
                run("x", parent = "missing"),
                run("c1", parent = "c2"),
                run("c2", parent = "c1"),
            ),
        )
        assertEquals(setOf("x", "c1", "c2"), nodes.map { it.run.id }.toSet())
        assertEquals(3, nodes.size)
        assertEquals(0, nodes.first { it.run.id == "x" }.depth)
        assertFalse(RunTrees.hasActive(nodes))
    }
}
