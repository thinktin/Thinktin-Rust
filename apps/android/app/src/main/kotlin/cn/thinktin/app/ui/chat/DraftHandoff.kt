package cn.thinktin.app.ui.chat

/**
 * 首页拦下密码时，把消息转交给对话页（对话页有保险箱表单）：首页 [put] 后打开对话页，对话页的 ViewModel 建好时 [take]。
 * 每个实例只留最后一条，取一次就没了。
 */
class DraftHandoff {
    private val drafts = mutableMapOf<String, String>()

    @Synchronized
    fun put(instanceId: String, text: String) {
        drafts[instanceId] = text
    }

    @Synchronized
    fun take(instanceId: String): String? = drafts.remove(instanceId)
}
