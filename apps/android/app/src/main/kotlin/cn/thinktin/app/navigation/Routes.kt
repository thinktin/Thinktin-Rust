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
    /** 对话；runId 可选：首页“最近运行”点进来时定位到那个运行。 */
    const val CHAT = "chat/{instanceId}?runId={runId}"
    const val RUN = "run/{runId}"
    const val CATALOG = "catalog"
    const val AGENT = "agent/{agentId}"
    const val INSTANCE = "instance/{instanceId}"

    /** 改实例名（实例设置页进入；有输入框，单独成页）。 */
    const val INSTANCE_NAME = "instance/{instanceId}/name"

    /** 实例的模型别名与降级链（13.4）。 */
    const val INSTANCE_ROUTES = "instance/{instanceId}/routes"
    const val PLANS = "plans"
    const val PLAN = "plan/{planId}"
    const val TEAMS = "teams"
    const val TEAM = "team/{teamId}"

    /** 收件箱；itemId 可选（推送点进某一条）。 */
    const val INBOX = "inbox?itemId={itemId}"
    /** 审批中心（13.16）：跨实例的待处理审批。 */
    const val APPROVALS = "approvals"

    /** 审批详情（什么状态都能看）；推送深链 thinktin://approval/{id}。 */
    const val APPROVAL = "approval/{approvalId}"
    /** 模型 key 列表（13.4）。 */
    const val KEYS = "keys"

    /** 添加 key（两步，有输入框，单独成页）。 */
    const val KEYS_NEW = "keys/new"

    /** 编辑 key（标签、启用 / 停用）。 */
    const val KEY_EDIT = "keys/{credentialId}/edit"

    /** 换 key（密码输入）。 */
    const val KEY_SECRET = "keys/{credentialId}/secret"

    /** 用量看板（13.4）。 */
    const val USAGE = "usage"

    /** 密码保险箱；requestId 可选（填写请求）。 */
    const val VAULT = "vault?requestId={requestId}"
    /** 设备与账号；action 可选：从设置页直接打开某个操作（见 DevicesAction）。 */
    const val DEVICES = "devices?action={action}"
    const val SETTINGS = "settings"

    /** 改昵称、注销账号（设置页和设备与账号页进入）。 */
    const val ACCOUNT_NAME = "account/name"
    const val DELETE_ACCOUNT = "account/delete"

    const val ARG_INSTANCE_ID = "instanceId"
    const val ARG_RUN_ID = "runId"
    const val ARG_AGENT_ID = "agentId"
    const val ARG_PLAN_ID = "planId"
    const val ARG_TEAM_ID = "teamId"
    const val ARG_ITEM_ID = "itemId"
    const val ARG_APPROVAL_ID = "approvalId"
    const val ARG_REQUEST_ID = "requestId"
    const val ARG_ACTION = "action"
    const val ARG_CREDENTIAL_ID = "credentialId"

    fun chat(instanceId: String, runId: String? = null) =
        if (runId == null) "chat/${Uri.encode(instanceId)}" else "chat/${Uri.encode(instanceId)}?runId=${Uri.encode(runId)}"
    fun run(runId: String) = "run/${Uri.encode(runId)}"
    fun agent(agentId: String) = "agent/${Uri.encode(agentId)}"
    fun instance(instanceId: String) = "instance/${Uri.encode(instanceId)}"
    fun instanceName(instanceId: String) = "instance/${Uri.encode(instanceId)}/name"
    fun instanceRoutes(instanceId: String) = "instance/${Uri.encode(instanceId)}/routes"
    fun keyEdit(credentialId: String) = "keys/${Uri.encode(credentialId)}/edit"
    fun keySecret(credentialId: String) = "keys/${Uri.encode(credentialId)}/secret"
    fun plan(planId: String) = "plan/${Uri.encode(planId)}"
    fun team(teamId: String) = "team/${Uri.encode(teamId)}"
    fun approval(approvalId: String) = "approval/${Uri.encode(approvalId)}"
    fun inbox(itemId: String? = null) = if (itemId == null) "inbox" else "inbox?itemId=${Uri.encode(itemId)}"
    fun devices(action: String? = null) = if (action == null) "devices" else "devices?action=${Uri.encode(action)}"
    fun vault(requestId: String? = null) = if (requestId == null) "vault" else "vault?requestId=${Uri.encode(requestId)}"

    /** 抽屉直达的顶级目的地（返回栈弹到 home）。 */
    val TOP_LEVEL: Set<String> = setOf(HOME, INBOX, APPROVALS, PLANS, TEAMS, SETTINGS, CATALOG)
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
