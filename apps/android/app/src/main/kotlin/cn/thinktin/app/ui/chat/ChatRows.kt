package cn.thinktin.app.ui.chat

import cn.thinktin.data.model.ConversationSection
import cn.thinktin.data.model.HistoryGap
import cn.thinktin.data.model.RunBlock
import cn.thinktin.data.model.TimelineItem
import cn.thinktin.data.model.Conversation

/** 时间线上的一行（LazyColumn 的一项）：区块头、一条内容、缺过程记录的说明、运行的摘要 / 失败原因。 */
sealed interface ChatRow {
    val key: String

    data class Header(val block: RunBlock) : ChatRow {
        override val key: String get() = "run/${block.runId}/header"
    }

    data class Item(val item: TimelineItem, val runId: String?) : ChatRow {
        override val key: String get() = item.key
    }

    data class Gap(val runId: String, val gap: HistoryGap) : ChatRow {
        override val key: String get() = "run/$runId/gap"
    }

    /** 运行结束后的摘要（agent 写的，标 AI 生成）和失败原因（平台诊断，不标）。 */
    data class Outcome(val block: RunBlock) : ChatRow {
        override val key: String get() = "run/${block.runId}/outcome"
    }
}

object ChatRows {
    /** 归并结果 → 行（旧的在前；界面倒过来放进 reverseLayout 的列表）。 */
    fun of(conversation: Conversation): List<ChatRow> = buildList {
        for (section in conversation.sections) {
            when (section) {
                is ConversationSection.Loose -> add(ChatRow.Item(section.item, null))
                is ConversationSection.RunSection -> {
                    val block = section.block
                    add(ChatRow.Header(block))
                    val items = block.items
                    // 用户那句话在区块头下面，然后是过程。
                    items.forEach { add(ChatRow.Item(it, block.runId)) }
                    if (block.history != HistoryGap.None) add(ChatRow.Gap(block.runId, block.history))
                    val run = block.run
                    if (run != null && block.state.isTerminal && (run.summary != null || run.error != null)) {
                        add(ChatRow.Outcome(block))
                    }
                }
            }
        }
    }
}
