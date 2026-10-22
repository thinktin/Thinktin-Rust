package cn.thinktin.app.navigation

import android.net.Uri

/**
 * 路由（第 3 节）。登录流（login → login/code、login/frozen）是独立的导航图，未登录时替换整个主区。
 */
object Routes {
    const val LOGIN = "login"
    const val LOGIN_CODE = "login/code"

    /** 登录时服务端说账号被冻结（还没有登录态）。 */
    const val LOGIN_FROZEN = "login/frozen"

    const val HOME = "home"
    const val CHAT = "chat/{instanceId}"
    const val RUN = "run/{runId}"
    const val CATALOG = "catalog"
    const val AGENT = "agent/{agentId}"
    const val INSTANCE = "instance/{instanceId}"
    const val PLANS = "plans"
    const val PLAN = "plan/{planId}"
    const val TEAMS = "teams"
    const val TEAM = "team/{teamId}"

    /** 收件箱；itemId 可选（推送点进某一条）。 */
    const val INBOX = "inbox?itemId={itemId}"
    const val APPROVALS = "approvals"
    const val APPROVAL = "approval/{approvalId}"
    const val KEYS = "keys"

    /** 密码保险箱；requestId 可选（填写请求）。 */
    const val VAULT = "vault?requestId={requestId}"
    /** 设备与账号；action 可选：从设置页直接打开某个操作（见 DevicesAction）。 */
    const val DEVICES = "devices?action={action}"
    const val SETTINGS = "settings"

    const val ARG_INSTANCE_ID = "instanceId"
    const val ARG_RUN_ID = "runId"
    const val ARG_AGENT_ID = "agentId"
    const val ARG_PLAN_ID = "planId"
    const val ARG_TEAM_ID = "teamId"
    const val ARG_ITEM_ID = "itemId"
    const val ARG_APPROVAL_ID = "approvalId"
    const val ARG_REQUEST_ID = "requestId"
    const val ARG_ACTION = "action"

    fun chat(instanceId: String) = "chat/${Uri.encode(instanceId)}"
    fun run(runId: String) = "run/${Uri.encode(runId)}"
    fun agent(agentId: String) = "agent/${Uri.encode(agentId)}"
    fun instance(instanceId: String) = "instance/${Uri.encode(instanceId)}"
    fun plan(planId: String) = "plan/${Uri.encode(planId)}"
    fun team(teamId: String) = "team/${Uri.encode(teamId)}"
    fun approval(approvalId: String) = "approval/${Uri.encode(approvalId)}"
    fun inbox(itemId: String? = null) = if (itemId == null) "inbox" else "inbox?itemId=${Uri.encode(itemId)}"
    fun devices(action: String? = null) = if (action == null) "devices" else "devices?action=${Uri.encode(action)}"
    fun vault(requestId: String? = null) = if (requestId == null) "vault" else "vault?requestId=${Uri.encode(requestId)}"

    /** 抽屉直达的顶级目的地（返回栈弹到 home）。 */
    val TOP_LEVEL: Set<String> = setOf(HOME, INBOX, PLANS, TEAMS, SETTINGS, CATALOG)
}

/** 深链（两端一致，推送点击用）：thinktin://… */
object DeepLinks {
    const val SCHEME = "thinktin"
    const val RUN = "$SCHEME://run/{runId}"
    const val APPROVAL = "$SCHEME://approval/{approvalId}"
    const val PLAN = "$SCHEME://plan/{planId}"
    const val INSTANCE = "$SCHEME://instance/{instanceId}"
    const val VAULT_REQUEST = "$SCHEME://vault/request/{requestId}"
    const val INBOX = "$SCHEME://inbox"
    const val INBOX_ITEM = "$SCHEME://inbox/{itemId}"
}
