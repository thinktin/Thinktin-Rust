package cn.thinktin.app.navigation

import android.content.Context
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.ComposeNavigator
import androidx.navigation.compose.DialogNavigator
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.navArgument
import androidx.navigation.navDeepLink
import cn.thinktin.app.push.RequestNotificationPermissionOnce
import cn.thinktin.app.ui.account.DeleteAccountScreen
import cn.thinktin.app.ui.account.EditNameScreen
import cn.thinktin.app.ui.agent.AgentDetailScreen
import cn.thinktin.app.ui.approval.ApprovalCenterScreen
import cn.thinktin.app.ui.approval.ApprovalDetailScreen
import cn.thinktin.app.ui.catalog.CatalogScreen
import cn.thinktin.app.ui.chat.ChatNavigation
import cn.thinktin.app.ui.chat.ChatScreen
import cn.thinktin.app.ui.common.LocalAppContainer
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.computer.ComputerGrantScreen
import cn.thinktin.app.ui.computer.ComputerPairScreen
import cn.thinktin.app.ui.computer.ComputersScreen
import cn.thinktin.app.ui.devices.DevicesAction
import cn.thinktin.app.ui.devices.DevicesScreen
import cn.thinktin.app.ui.drawer.AppDrawer
import cn.thinktin.app.ui.drawer.DrawerDestination
import cn.thinktin.app.ui.drawer.DrawerViewModel
import cn.thinktin.app.ui.home.HomeScreen
import cn.thinktin.app.ui.inbox.InboxScreen
import cn.thinktin.app.ui.instance.InstanceNameScreen
import cn.thinktin.app.ui.instance.InstanceSettingsScreen
import cn.thinktin.app.ui.keys.AddKeyScreen
import cn.thinktin.app.ui.keys.KeyEditScreen
import cn.thinktin.app.ui.keys.KeySecretScreen
import cn.thinktin.app.ui.keys.KeysScreen
import cn.thinktin.app.ui.placeholder.ComingSoonScreen
import cn.thinktin.app.ui.placeholder.Page
import cn.thinktin.app.ui.plans.PlanDetailNavigation
import cn.thinktin.app.ui.plans.PlanDetailScreen
import cn.thinktin.app.ui.plans.PlanEditMode
import cn.thinktin.app.ui.plans.PlanEditScreen
import cn.thinktin.app.ui.plans.PlansScreen
import cn.thinktin.app.ui.routes.ModelRoutesScreen
import cn.thinktin.app.ui.run.RunScreen
import cn.thinktin.app.ui.settings.SettingsScreen
import cn.thinktin.app.ui.privacy.PrivacyInfoScreen
import cn.thinktin.app.update.UpdateScreen
import cn.thinktin.app.ui.imchannels.ImChannelEditorScreen
import cn.thinktin.app.ui.imchannels.ImChannelsScreen
import cn.thinktin.app.ui.vault.VaultEditorScreen
import cn.thinktin.app.ui.vault.VaultItemScreen
import cn.thinktin.app.ui.vault.VaultRequestScreen
import cn.thinktin.app.ui.vault.VaultScreen
import cn.thinktin.app.ui.settings.licenses.LicenseTextScreen
import cn.thinktin.app.ui.settings.licenses.LicensesScreen
import cn.thinktin.app.ui.teams.TeamDetailScreen
import cn.thinktin.app.ui.teams.TeamEditScreen
import cn.thinktin.app.ui.teams.TeamsScreen
import cn.thinktin.app.ui.usage.UsageScreen
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/** 当前的深链收件箱（MainActivity 提供；预览和测试里没有就是空的）。 */
val LocalDeepLinks = staticCompositionLocalOf { DeepLinkInbox() }

/**
 * 主界面的 NavController。和 rememberNavController 一样，只是用 Application 的 Context 构造：NavController 拿不到
 * Activity，就不会在建图时自己处理 Activity intent 里的深链（否则每次主界面重建——退出再登录、切换演示模式——
 * 都会把冷启动时的那条深链再跳一遍）。深链统一由 [DeepLinkInbox] 交给 [NavHostController.handleDeepLink]。
 */
@Composable
fun rememberAppNavController(): NavHostController {
    val context = LocalContext.current.applicationContext
    return rememberSaveable(
        saver = Saver(
            save = { it.saveState() },
            restore = { state -> createNavController(context).apply { restoreState(state) } },
        ),
    ) { createNavController(context) }
}

private fun createNavController(context: Context): NavHostController = NavHostController(context).apply {
    navigatorProvider.addNavigator(ComposeNavigator())
    navigatorProvider.addNavigator(DialogNavigator())
}

/** 已登录（或演示模式）时的主界面：抽屉 + NavHost（第 3 节）。 */
@Composable
fun MainNavigation(navController: NavHostController = rememberAppNavController()) {
    val service = LocalThinktinService.current
    val container = LocalAppContainer.current
    val deepLinks = LocalDeepLinks.current
    val pendingDeepLink by deepLinks.current.collectAsStateWithLifecycle()
    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    val drawerViewModel: DrawerViewModel = viewModel(
        key = "drawer-${System.identityHashCode(service)}",
        factory = viewModelFactory { initializer { DrawerViewModel(service, container.computerLinks) } },
    )
    val drawerUi by drawerViewModel.uiState.collectAsStateWithLifecycle()
    val backStack by navController.currentBackStackEntryAsState()
    val currentRoute = backStack?.destination?.route

    // 深链（冷启动、App 已在运行时的推送点击）：等导航图建好再交给 NavController，处理完清掉。
    LaunchedEffect(pendingDeepLink) {
        val uri = pendingDeepLink ?: return@LaunchedEffect
        navController.currentBackStackEntryFlow.first()
        drawerState.close()
        if (uri.scheme == DeepLinks.PAIR_SCHEME) {
            navController.navigate(Routes.computerPair(code = uri.toString()))
        } else {
            navController.handleDeepLink(DeepLinkInbox.navigationIntent(uri))
        }
        deepLinks.consume(uri)
    }

    // 通知权限（13.8）：真实服务登录进来后问一次。
    RequestNotificationPermissionOnce(enabled = !service.isDemo)

    // 打开抽屉时刷新实例和未读数。
    LaunchedEffect(drawerState.isOpen) {
        if (drawerState.isOpen) drawerViewModel.refresh()
    }

    fun closeDrawerThen(action: () -> Unit) {
        scope.launch { drawerState.close() }
        action()
    }

    ModalNavigationDrawer(
        drawerState = drawerState,
        gesturesEnabled = drawerState.isOpen || currentRoute == Routes.HOME,
        drawerContent = {
            AppDrawer(
                state = drawerUi,
                currentRoute = currentRoute,
                onQueryChange = drawerViewModel::onQueryChange,
                onNavigate = { destination ->
                    closeDrawerThen {
                        val route = when (destination) {
                            DrawerDestination.NewChat -> Routes.HOME
                            DrawerDestination.Catalog -> Routes.CATALOG
                            DrawerDestination.Inbox -> Routes.inbox()
                            DrawerDestination.Approvals -> Routes.APPROVALS
                            DrawerDestination.Plans -> Routes.PLANS
                            DrawerDestination.Teams -> Routes.TEAMS
                            DrawerDestination.Settings -> Routes.SETTINGS
                        }
                        navController.navigateTopLevel(route)
                    }
                },
                onOpenInstance = { instance -> closeDrawerThen { navController.navigate(Routes.chat(instance.id)) } },
                onOpenInstanceSettings = { instance ->
                    closeDrawerThen { navController.navigate(Routes.instance(instance.id)) }
                },
            )
        },
    ) {
        MainNavHost(
            navController = navController,
            onOpenDrawer = { scope.launch { drawerState.open() } },
            onInstancesChanged = drawerViewModel::refresh,
        )
    }
}

/** 抽屉入口是顶级目的地：返回栈弹到 home，不重复压栈。 */
fun NavHostController.navigateTopLevel(route: String) {
    navigate(route) {
        popUpTo(graph.findStartDestination().id) { saveState = route != Routes.HOME }
        launchSingleTop = true
        restoreState = route != Routes.HOME
    }
}

/**
 * [onInstancesChanged]：领养、改名、换版本、删除之后刷新抽屉里的实例列表（首页回到前台时自己刷新）。
 */
@Composable
private fun MainNavHost(navController: NavHostController, onOpenDrawer: () -> Unit, onInstancesChanged: () -> Unit) {
    val back: () -> Unit = {
        if (!navController.popBackStack()) navController.navigateTopLevel(Routes.HOME)
    }

    /**
     * 表单页保存成功后返回：只在 [entry] 还在栈顶时弹。页面退出动画期间仍可点击、LaunchedEffect 仍在收集，
     * 重复的回调不能再多弹一层（把列表页也弹掉，栈空时跳回首页）。
     */
    fun backFrom(entry: NavBackStackEntry): () -> Unit = {
        if (navController.currentBackStackEntry?.id == entry.id) back()
    }

    @Composable
    fun Placeholder(page: Page, entry: NavBackStackEntry, arg: String? = null) {
        ComingSoonScreen(page = page, argument = arg?.let { entry.arguments?.getString(it) }, onBack = back)
    }

    NavHost(navController = navController, startDestination = Routes.HOME) {
        composable(Routes.HOME) {
            HomeScreen(
                onOpenDrawer = onOpenDrawer,
                onOpenChat = { navController.navigate(Routes.chat(it)) },
                // 最近运行：进对话页并定位到那个运行（13.5）。
                onOpenRun = { instanceId, runId -> navController.navigate(Routes.chat(instanceId, runId)) },
                onOpenCatalog = { navController.navigate(Routes.CATALOG) },
                onOpenAgent = { navController.navigate(Routes.agent(it)) },
                onOpenInstanceSettings = { navController.navigate(Routes.instance(it)) },
            )
        }
        composable(
            Routes.CHAT,
            arguments = listOf(stringArg(Routes.ARG_INSTANCE_ID), optionalStringArg(Routes.ARG_RUN_ID)),
        ) { entry ->
            val instanceId = entry.arguments?.getString(Routes.ARG_INSTANCE_ID).orEmpty()
            ChatScreen(
                instanceId = instanceId,
                focusRunId = entry.arguments?.getString(Routes.ARG_RUN_ID),
                navigation = ChatNavigation(
                    onBack = back,
                    onOpenInstanceSettings = { navController.navigate(Routes.instance(it)) },
                    onOpenRun = { navController.navigate(Routes.run(it)) },
                    onOpenPlan = { navController.navigate(Routes.plan(it)) },
                    onOpenApprovals = { navController.navigate(Routes.APPROVALS) },
                    onOpenApproval = { navController.navigate(Routes.approval(it)) },
                    onOpenKeys = { navController.navigate(Routes.KEYS) },
                    onOpenModelRoutes = { navController.navigate(Routes.instanceRoutes(it)) },
                    onOpenDevices = { navController.navigate(Routes.devices()) },
                    onInstanceGone = {
                        onInstancesChanged()
                        navController.navigate(Routes.HOME) { popUpTo(Routes.HOME) { inclusive = true } }
                    },
                ),
            )
        }
        composable(
            Routes.RUN,
            arguments = listOf(stringArg(Routes.ARG_RUN_ID)),
            deepLinks = listOf(navDeepLink { uriPattern = DeepLinks.RUN }),
        ) { entry ->
            RunScreen(
                runId = entry.arguments?.getString(Routes.ARG_RUN_ID).orEmpty(),
                onBack = back,
                onOpenChat = { instanceId, runId -> navController.navigate(Routes.chat(instanceId, runId)) },
                onOpenModelRoutes = { navController.navigate(Routes.instanceRoutes(it)) },
            )
        }
        composable(Routes.CATALOG) {
            CatalogScreen(onBack = back, onOpenAgent = { navController.navigate(Routes.agent(it)) })
        }
        composable(Routes.AGENT, arguments = listOf(stringArg(Routes.ARG_AGENT_ID))) { entry ->
            AgentDetailScreen(
                agentId = entry.arguments?.getString(Routes.ARG_AGENT_ID).orEmpty(),
                onBack = back,
                onAdopted = { instance, routesConfigured ->
                    onInstancesChanged()
                    // 目录和详情不留在返回栈里：从对话页返回回到首页。
                    navController.navigate(Routes.chat(instance.id)) {
                        popUpTo(Routes.HOME)
                    }
                    // 没配好默认模型（跳过、没有能用的 key、配 main 失败）：先打开模型别名页，配完返回到对话页。
                    if (!routesConfigured) navController.navigate(Routes.instanceRoutes(instance.id))
                },
            )
        }
        composable(
            Routes.INSTANCE,
            arguments = listOf(stringArg(Routes.ARG_INSTANCE_ID)),
            deepLinks = listOf(navDeepLink { uriPattern = DeepLinks.INSTANCE }),
        ) { entry ->
            val instanceId = entry.arguments?.getString(Routes.ARG_INSTANCE_ID).orEmpty()
            InstanceSettingsScreen(
                instanceId = instanceId,
                onBack = back,
                onRename = { navController.navigate(Routes.instanceName(instanceId)) },
                onOpenAgent = { navController.navigate(Routes.agent(it)) },
                onOpenModelRoutes = { navController.navigate(Routes.instanceRoutes(instanceId)) },
                onOpenKeys = { navController.navigate(Routes.KEYS) },
                onChanged = onInstancesChanged,
                onDeleted = {
                    onInstancesChanged()
                    // 回首页，并清掉返回栈里指向这个实例的页面（对话页等）；首页重新加载。
                    navController.navigate(Routes.HOME) {
                        popUpTo(Routes.HOME) { inclusive = true }
                    }
                },
            )
        }
        composable(Routes.INSTANCE_NAME, arguments = listOf(stringArg(Routes.ARG_INSTANCE_ID))) { entry ->
            InstanceNameScreen(
                instanceId = entry.arguments?.getString(Routes.ARG_INSTANCE_ID).orEmpty(),
                onBack = back,
                onSaved = {
                    if (navController.currentBackStackEntry?.id == entry.id) {
                        onInstancesChanged()
                        back()
                    }
                },
            )
        }
        composable(Routes.INSTANCE_ROUTES, arguments = listOf(stringArg(Routes.ARG_INSTANCE_ID))) { entry ->
            ModelRoutesScreen(
                instanceId = entry.arguments?.getString(Routes.ARG_INSTANCE_ID).orEmpty(),
                onBack = back,
                onOpenKeys = { navController.navigate(Routes.KEYS) },
                onAddKey = { navController.navigate(Routes.KEYS_NEW) },
            )
        }
        composable(Routes.PLANS) {
            PlansScreen(
                onBack = back,
                onOpenPlan = { navController.navigate(Routes.plan(it)) },
                onNewPlan = { navController.navigate(Routes.planNew()) },
                onOpenCatalog = { navController.navigate(Routes.CATALOG) },
            )
        }
        composable(
            Routes.PLAN,
            arguments = listOf(stringArg(Routes.ARG_PLAN_ID)),
            deepLinks = listOf(navDeepLink { uriPattern = DeepLinks.PLAN }),
        ) { entry ->
            PlanDetailScreen(
                planId = entry.arguments?.getString(Routes.ARG_PLAN_ID).orEmpty(),
                navigation = PlanDetailNavigation(
                    onBack = back,
                    onEdit = { navController.navigate(Routes.planEdit(it)) },
                    onOpenRun = { navController.navigate(Routes.run(it)) },
                    onDeleted = backFrom(entry),
                ),
            )
        }
        composable(
            Routes.PLAN_NEW,
            arguments = listOf(optionalStringArg(Routes.ARG_INSTANCE_ID), optionalStringArg(Routes.ARG_TEAM_ID)),
        ) { entry ->
            PlanEditScreen(
                mode = PlanEditMode.Create(
                    entry.arguments?.getString(Routes.ARG_INSTANCE_ID),
                    entry.arguments?.getString(Routes.ARG_TEAM_ID),
                ),
                onClose = backFrom(entry),
                onSaved = { plan, _ ->
                    // 新建的换成它的详情页（返回回到列表）。
                    if (navController.currentBackStackEntry?.id == entry.id) {
                        navController.navigate(Routes.plan(plan.id)) { popUpTo(Routes.PLAN_NEW) { inclusive = true } }
                    }
                },
            )
        }
        composable(Routes.PLAN_EDIT, arguments = listOf(stringArg(Routes.ARG_PLAN_ID))) { entry ->
            PlanEditScreen(
                mode = PlanEditMode.Edit(entry.arguments?.getString(Routes.ARG_PLAN_ID).orEmpty()),
                onClose = backFrom(entry),
                onSaved = { _, _ -> backFrom(entry)() },
            )
        }
        composable(Routes.TEAMS) {
            TeamsScreen(
                onBack = back,
                onOpenTeam = { navController.navigate(Routes.team(it)) },
                onNewTeam = { navController.navigate(Routes.TEAM_NEW) },
            )
        }
        composable(Routes.TEAM, arguments = listOf(stringArg(Routes.ARG_TEAM_ID))) { entry ->
            val teamId = entry.arguments?.getString(Routes.ARG_TEAM_ID).orEmpty()
            TeamDetailScreen(
                teamId = teamId,
                onBack = backFrom(entry),
                onEdit = { navController.navigate(Routes.teamEdit(teamId)) },
                onOpenInstance = { navController.navigate(Routes.instance(it)) },
                onOpenRoutes = { navController.navigate(Routes.instanceRoutes(it)) },
                onNewPipeline = { team -> navController.navigate(Routes.planNew(teamId = team.id)) },
            )
        }
        composable(Routes.TEAM_NEW) { entry ->
            TeamEditScreen(
                teamId = null,
                onClose = backFrom(entry),
                onSaved = { id ->
                    if (navController.currentBackStackEntry?.id == entry.id) {
                        navController.navigate(Routes.team(id)) { popUpTo(Routes.TEAM_NEW) { inclusive = true } }
                    }
                },
            )
        }
        composable(Routes.TEAM_EDIT, arguments = listOf(stringArg(Routes.ARG_TEAM_ID))) { entry ->
            TeamEditScreen(
                teamId = entry.arguments?.getString(Routes.ARG_TEAM_ID).orEmpty(),
                onClose = backFrom(entry),
                onSaved = { backFrom(entry)() },
            )
        }
        composable(
            Routes.INBOX,
            arguments = listOf(optionalStringArg(Routes.ARG_ITEM_ID)),
            deepLinks = listOf(
                navDeepLink { uriPattern = DeepLinks.INBOX },
                navDeepLink { uriPattern = DeepLinks.INBOX_ITEM },
            ),
        ) { entry ->
            InboxScreen(
                itemId = entry.arguments?.getString(Routes.ARG_ITEM_ID),
                onBack = back,
                onNavigate = { navController.navigate(it) },
            )
        }
        composable(Routes.APPROVALS, deepLinks = listOf(navDeepLink { uriPattern = DeepLinks.APPROVALS })) {
            ApprovalCenterScreen(onBack = back, onOpenApproval = { navController.navigate(Routes.approval(it)) })
        }
        composable(
            Routes.APPROVAL,
            arguments = listOf(stringArg(Routes.ARG_APPROVAL_ID)),
            deepLinks = listOf(navDeepLink { uriPattern = DeepLinks.APPROVAL }),
        ) { entry ->
            ApprovalDetailScreen(
                approvalId = entry.arguments?.getString(Routes.ARG_APPROVAL_ID).orEmpty(),
                onBack = back,
                onOpenRun = { navController.navigate(Routes.run(it)) },
                onOpenChat = { navController.navigate(Routes.chat(it)) },
            )
        }
        composable(Routes.KEYS) {
            KeysScreen(
                onBack = back,
                onAdd = { navController.navigate(Routes.KEYS_NEW) },
                onEdit = { navController.navigate(Routes.keyEdit(it)) },
                onReplaceSecret = { navController.navigate(Routes.keySecret(it)) },
                onOpenUsage = { navController.navigate(Routes.USAGE) { launchSingleTop = true } },
            )
        }
        composable(Routes.KEYS_NEW) { entry -> AddKeyScreen(onBack = back, onAdded = backFrom(entry)) }
        composable(Routes.KEY_EDIT, arguments = listOf(stringArg(Routes.ARG_CREDENTIAL_ID))) { entry ->
            val credentialId = entry.arguments?.getString(Routes.ARG_CREDENTIAL_ID).orEmpty()
            KeyEditScreen(
                credentialId = credentialId,
                onBack = back,
                onSaved = backFrom(entry),
                onReplaceSecret = {
                    // 换 key 页替换编辑页：换完回到列表。
                    navController.navigate(Routes.keySecret(credentialId)) {
                        popUpTo(Routes.KEY_EDIT) { inclusive = true }
                    }
                },
            )
        }
        composable(Routes.KEY_SECRET, arguments = listOf(stringArg(Routes.ARG_CREDENTIAL_ID))) { entry ->
            KeySecretScreen(
                credentialId = entry.arguments?.getString(Routes.ARG_CREDENTIAL_ID).orEmpty(),
                onBack = back,
                onSaved = backFrom(entry),
            )
        }
        composable(Routes.USAGE) { UsageScreen(onBack = back) }
        composable(
            Routes.VAULT,
            arguments = listOf(optionalStringArg(Routes.ARG_REQUEST_ID)),
            deepLinks = listOf(navDeepLink { uriPattern = DeepLinks.VAULT_REQUEST }),
        ) { entry ->
            val requestId = entry.arguments?.getString(Routes.ARG_REQUEST_ID)
            if (requestId.isNullOrEmpty()) {
                VaultScreen(
                    onBack = back,
                    onOpenItem = { navController.navigate(Routes.vaultItem(it)) },
                    onOpenRequest = { navController.navigate(Routes.vault(it)) },
                    onNewItem = { navController.navigate(Routes.VAULT_NEW) },
                )
            } else {
                VaultRequestScreen(
                    requestId = requestId,
                    onBack = back,
                    onOpenItem = { navController.navigate(Routes.vaultItem(it)) },
                    onOpenRun = { navController.navigate(Routes.run(it)) },
                )
            }
        }
        composable(Routes.VAULT_ITEM, arguments = listOf(stringArg(Routes.ARG_ITEM_ID))) { entry ->
            VaultItemScreen(
                itemId = entry.arguments?.getString(Routes.ARG_ITEM_ID).orEmpty(),
                onBack = back,
                onEdit = { navController.navigate(Routes.vaultEdit(it)) },
            )
        }
        composable(Routes.IM_CHANNELS) {
            ImChannelsScreen(
                onBack = back,
                onNew = { navController.navigate(Routes.IM_CHANNEL_NEW) },
                onEdit = { navController.navigate(Routes.imChannelEdit(it)) },
            )
        }
        composable(Routes.IM_CHANNEL_NEW) { ImChannelEditorScreen(channelId = null, onBack = back, onSaved = { back() }) }
        composable(Routes.IM_CHANNEL_EDIT, arguments = listOf(stringArg(Routes.ARG_CHANNEL_ID))) { entry ->
            ImChannelEditorScreen(
                channelId = entry.arguments?.getString(Routes.ARG_CHANNEL_ID).orEmpty(), onBack = back, onSaved = { back() },
            )
        }
        composable(Routes.VAULT_NEW) { VaultEditorScreen(itemId = null, onBack = back, onSaved = { back() }) }
        composable(Routes.VAULT_EDIT, arguments = listOf(stringArg(Routes.ARG_ITEM_ID))) { entry ->
            VaultEditorScreen(itemId = entry.arguments?.getString(Routes.ARG_ITEM_ID).orEmpty(), onBack = back, onSaved = { back() })
        }
        composable(Routes.DEVICES, arguments = listOf(optionalStringArg(Routes.ARG_ACTION))) { entry ->
            DevicesScreen(
                action = DevicesAction.fromWire(entry.arguments?.getString(Routes.ARG_ACTION)),
                onBack = back,
                onEditName = { navController.navigate(Routes.ACCOUNT_NAME) },
                onDeleteAccount = { navController.navigate(Routes.DELETE_ACCOUNT) },
                onOpenComputers = { navController.navigate(Routes.COMPUTERS) },
            )
        }
        composable(Routes.COMPUTERS) {
            ComputersScreen(
                onBack = back,
                onPair = { navController.navigate(Routes.computerPair(computerId = it)) },
                onGrant = { navController.navigate(Routes.computerGrant(it)) },
            )
        }
        composable(
            Routes.COMPUTER_PAIR,
            arguments = listOf(optionalStringArg(Routes.ARG_COMPUTER_ID), optionalStringArg(Routes.ARG_CODE)),
        ) { entry ->
            ComputerPairScreen(
                computerId = entry.arguments?.getString(Routes.ARG_COMPUTER_ID),
                pairingCode = entry.arguments?.getString(Routes.ARG_CODE),
                onBack = back,
            )
        }
        composable(Routes.COMPUTER_GRANT, arguments = listOf(stringArg(Routes.ARG_COMPUTER_ID))) { entry ->
            ComputerGrantScreen(computerId = entry.arguments?.getString(Routes.ARG_COMPUTER_ID).orEmpty(), onBack = back)
        }
        composable(Routes.SETTINGS) {
            SettingsScreen(
                onBack = back,
                onOpenDevices = { action -> navController.navigate(Routes.devices(action?.wire)) },
                onEditName = { navController.navigate(Routes.ACCOUNT_NAME) },
                onDeleteAccount = { navController.navigate(Routes.DELETE_ACCOUNT) },
                onOpenKeys = { navController.navigate(Routes.KEYS) },
                onOpenUsage = { navController.navigate(Routes.USAGE) },
                onOpenLicenses = { navController.navigate(Routes.LICENSES) },
                onOpenPrivacyInfo = { navController.navigate(Routes.PRIVACY_INFO) },
                onOpenUpdate = { navController.navigate(Routes.UPDATE) },
                onOpenVault = { navController.navigate(Routes.vault()) },
                onOpenImChannels = { navController.navigate(Routes.IM_CHANNELS) },
            )
        }
        composable(Routes.PRIVACY_INFO) { PrivacyInfoScreen(onBack = back) }
        composable(Routes.UPDATE) {
            val updater = LocalAppContainer.current.updater
            if (updater != null) UpdateScreen(updater, onBack = back) else LaunchedEffect(Unit) { back() }
        }
        composable(Routes.LICENSES) {
            LicensesScreen(onBack = back, onOpenText = { path, title -> navController.navigate(Routes.licenseText(path, title)) })
        }
        composable(
            Routes.LICENSE_TEXT,
            arguments = listOf(optionalStringArg(Routes.ARG_PATH), optionalStringArg(Routes.ARG_TITLE)),
        ) { entry ->
            LicenseTextScreen(
                path = entry.arguments?.getString(Routes.ARG_PATH).orEmpty(),
                title = entry.arguments?.getString(Routes.ARG_TITLE).orEmpty(),
                onBack = back,
            )
        }
        composable(Routes.ACCOUNT_NAME) { EditNameScreen(onBack = back) }
        composable(Routes.DELETE_ACCOUNT) { DeleteAccountScreen(onBack = back) }
    }
}

private fun stringArg(name: String) = navArgument(name) { type = NavType.StringType }

private fun optionalStringArg(name: String) = navArgument(name) {
    type = NavType.StringType
    nullable = true
    defaultValue = null
}
