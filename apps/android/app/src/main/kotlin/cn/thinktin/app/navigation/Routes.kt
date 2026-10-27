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

    /** 新建计划（13.6）；instanceId 可选：从实例进来时预选它。有输入框，单独成页。 */
    const val PLAN_NEW = "plans/new?instanceId={instanceId}&teamId={teamId}"

    /** 编辑计划（13.6）。 */
    const val PLAN_EDIT = "plan/{planId}/edit"
    const val TEAMS = "teams"
    const val TEAM = "team/{teamId}"

    /** 新建、编辑团队（13.7，单独的页面）。 */
    const val TEAM_NEW = "teams/new"
    const val TEAM_EDIT = "team/{teamId}/edit"

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

    /** 密码保险箱；requestId 可选（填写请求：推送、收件箱、深链进来直接显示请求页）。 */
    const val VAULT = "vault?requestId={requestId}"

    /** 保险箱条目、新建、修改（13.14）。 */
    const val VAULT_ITEM = "vault/item/{itemId}"
    const val VAULT_NEW = "vault/new"
    const val VAULT_EDIT = "vault/item/{itemId}/edit"

    /** IM 渠道（13.15）：列表、绑定、修改。 */
    const val IM_CHANNELS = "im-channels"
    const val IM_CHANNEL_NEW = "im-channels/new"
    const val IM_CHANNEL_EDIT = "im-channels/{channelId}/edit"
    /** 设备与账号；action 可选：从设置页直接打开某个操作（见 DevicesAction）。 */
    const val DEVICES = "devices?action={action}"

    /** 电脑（13.9）：列表；配对（computerId 为空是从二维码进来的，code 是 `thinktin-pair:` 深链带进来的配对码）；授权。 */
    const val COMPUTERS = "computers"
    const val COMPUTER_PAIR = "computers/pair?computerId={computerId}&code={code}"
    const val COMPUTER_GRANT = "computers/{computerId}/grant"
    const val SETTINGS = "settings"

    /** 个人信息与权限（13.11）。 */
    const val PRIVACY_INFO = "privacy"

    /** 检查更新（13.12，只有官网安装包有）。 */
    const val UPDATE = "update"

    /** 开源许可（13.13）与一份原文。 */
    const val LICENSES = "licenses"
    const val LICENSE_TEXT = "licenses/text?path={path}&title={title}"

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
    const val ARG_CHANNEL_ID = "channelId"
    const val ARG_PATH = "path"
    const val ARG_TITLE = "title"
    const val ARG_CODE = "code"
    const val ARG_COMPUTER_ID = "computerId"

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
    fun planEdit(planId: String) = "plan/${Uri.encode(planId)}/edit"
    fun planNew(instanceId: String? = null, teamId: String? = null): String {
        val query = listOfNotNull(
            instanceId?.let { "instanceId=${Uri.encode(it)}" },
            teamId?.let { "teamId=${Uri.encode(it)}" },
        )
        return if (query.isEmpty()) "plans/new" else "plans/new?" + query.joinToString("&")
    }
    fun team(teamId: String) = "team/${Uri.encode(teamId)}"
    fun teamEdit(teamId: String) = "team/${Uri.encode(teamId)}/edit"
    fun approval(approvalId: String) = "approval/${Uri.encode(approvalId)}"
    fun inbox(itemId: String? = null) = if (itemId == null) "inbox" else "inbox?itemId=${Uri.encode(itemId)}"
    fun devices(action: String? = null) = if (action == null) "devices" else "devices?action=${Uri.encode(action)}"
    fun computerPair(computerId: String? = null, code: String? = null): String {
        val query = listOfNotNull(
            computerId?.let { "computerId=${Uri.encode(it)}" },
            code?.let { "code=${Uri.encode(it)}" },
        )
        return if (query.isEmpty()) "computers/pair" else "computers/pair?" + query.joinToString("&")
    }
    fun computerGrant(computerId: String) = "computers/${Uri.encode(computerId)}/grant"
    fun vaultItem(itemId: String) = "vault/item/${Uri.encode(itemId)}"

    fun vaultEdit(itemId: String) = "vault/item/${Uri.encode(itemId)}/edit"

    fun imChannelEdit(channelId: String) = "im-channels/${Uri.encode(channelId)}/edit"

    fun vault(requestId: String? = null) = if (requestId == null) "vault" else "vault?requestId=${Uri.encode(requestId)}"
    fun licenseText(path: String, title: String) = "licenses/text?path=${Uri.encode(path)}&title=${Uri.encode(title)}"

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

    /** 审批中心（iOS 的小组件用，12.20；两端都认）。 */
    const val APPROVALS = "$SCHEME://approvals"

    /**
     * 电脑上的配对二维码（13.9，docs/pairing.md）：`thinktin-pair:v1?d=…&k=…&n=…&e=…`。用系统相机扫到后打开 App，
     * 整条交给“电脑”页当配对码（不经 NavController 的深链匹配：它不认这种不带 // 的地址）。
     */
    const val PAIR_SCHEME = "thinktin-pair"
}
