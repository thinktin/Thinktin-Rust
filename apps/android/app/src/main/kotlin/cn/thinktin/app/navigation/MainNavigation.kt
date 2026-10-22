package cn.thinktin.app.navigation

import android.content.Context
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.res.stringResource
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
import cn.thinktin.app.R
import cn.thinktin.app.ui.account.DeleteAccountScreen
import cn.thinktin.app.ui.account.EditNameScreen
import cn.thinktin.app.ui.agent.AgentDetailScreen
import cn.thinktin.app.ui.catalog.CatalogScreen
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.devices.DevicesAction
import cn.thinktin.app.ui.devices.DevicesScreen
import cn.thinktin.app.ui.drawer.AppDrawer
import cn.thinktin.app.ui.drawer.DrawerDestination
import cn.thinktin.app.ui.drawer.DrawerViewModel
import cn.thinktin.app.ui.home.HomeScreen
import cn.thinktin.app.ui.instance.InstanceNameScreen
import cn.thinktin.app.ui.instance.InstanceSettingsScreen
import cn.thinktin.app.ui.keys.AddKeyScreen
import cn.thinktin.app.ui.keys.KeyEditScreen
import cn.thinktin.app.ui.keys.KeySecretScreen
import cn.thinktin.app.ui.keys.KeysScreen
import cn.thinktin.app.ui.placeholder.ComingSoonScreen
import cn.thinktin.app.ui.placeholder.Page
import cn.thinktin.app.ui.routes.ModelRoutesScreen
import cn.thinktin.app.ui.settings.SettingsScreen
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
    val deepLinks = LocalDeepLinks.current
    val pendingDeepLink by deepLinks.current.collectAsStateWithLifecycle()
    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    val drawerViewModel: DrawerViewModel = viewModel(
        key = "drawer-${System.identityHashCode(service)}",
        factory = viewModelFactory { initializer { DrawerViewModel(service) } },
    )
    val drawerUi by drawerViewModel.uiState.collectAsStateWithLifecycle()
    val backStack by navController.currentBackStackEntryAsState()
    val currentRoute = backStack?.destination?.route

    // 深链（冷启动、App 已在运行时的推送点击）：等导航图建好再交给 NavController，处理完清掉。
    LaunchedEffect(pendingDeepLink) {
        val uri = pendingDeepLink ?: return@LaunchedEffect
        navController.currentBackStackEntryFlow.first()
        drawerState.close()
        navController.handleDeepLink(DeepLinkInbox.navigationIntent(uri))
        deepLinks.consume(uri)
    }

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

    @Composable
    fun Placeholder(page: Page, entry: NavBackStackEntry, arg: String? = null) {
        ComingSoonScreen(page = page, argument = arg?.let { entry.arguments?.getString(it) }, onBack = back)
    }

    NavHost(navController = navController, startDestination = Routes.HOME) {
        composable(Routes.HOME) {
            HomeScreen(
                onOpenDrawer = onOpenDrawer,
                onOpenChat = { navController.navigate(Routes.chat(it)) },
                onOpenRun = { navController.navigate(Routes.run(it)) },
                onOpenCatalog = { navController.navigate(Routes.CATALOG) },
                onOpenAgent = { navController.navigate(Routes.agent(it)) },
                onOpenInstanceSettings = { navController.navigate(Routes.instance(it)) },
            )
        }
        composable(Routes.CHAT, arguments = listOf(stringArg(Routes.ARG_INSTANCE_ID))) { entry ->
            // 对话页在 13.5 做；顶栏先放“实例设置”入口。
            val instanceId = entry.arguments?.getString(Routes.ARG_INSTANCE_ID).orEmpty()
            ComingSoonScreen(
                page = Page.Chat,
                argument = instanceId,
                onBack = back,
                actions = {
                    IconButton(onClick = { navController.navigate(Routes.instance(instanceId)) }) {
                        Icon(Icons.Outlined.Tune, contentDescription = stringResource(R.string.home_instance_settings))
                    }
                },
            )
        }
        composable(
            Routes.RUN,
            arguments = listOf(stringArg(Routes.ARG_RUN_ID)),
            deepLinks = listOf(navDeepLink { uriPattern = DeepLinks.RUN }),
        ) { Placeholder(Page.Run, it, Routes.ARG_RUN_ID) }
        composable(Routes.CATALOG) {
            CatalogScreen(onBack = back, onOpenAgent = { navController.navigate(Routes.agent(it)) })
        }
        composable(Routes.AGENT, arguments = listOf(stringArg(Routes.ARG_AGENT_ID))) { entry ->
            AgentDetailScreen(
                agentId = entry.arguments?.getString(Routes.ARG_AGENT_ID).orEmpty(),
                onBack = back,
                onAdopted = { instance ->
                    onInstancesChanged()
                    // 目录和详情不留在返回栈里：从对话页返回回到首页。
                    navController.navigate(Routes.chat(instance.id)) {
                        popUpTo(Routes.HOME)
                    }
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
                    onInstancesChanged()
                    back()
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
        composable(Routes.PLANS) { Placeholder(Page.Plans, it) }
        composable(
            Routes.PLAN,
            arguments = listOf(stringArg(Routes.ARG_PLAN_ID)),
            deepLinks = listOf(navDeepLink { uriPattern = DeepLinks.PLAN }),
        ) { Placeholder(Page.Plan, it, Routes.ARG_PLAN_ID) }
        composable(Routes.TEAMS) { Placeholder(Page.Teams, it) }
        composable(Routes.TEAM, arguments = listOf(stringArg(Routes.ARG_TEAM_ID))) {
            Placeholder(Page.Team, it, Routes.ARG_TEAM_ID)
        }
        composable(
            Routes.INBOX,
            arguments = listOf(optionalStringArg(Routes.ARG_ITEM_ID)),
            deepLinks = listOf(
                navDeepLink { uriPattern = DeepLinks.INBOX },
                navDeepLink { uriPattern = DeepLinks.INBOX_ITEM },
            ),
        ) { Placeholder(Page.Inbox, it, Routes.ARG_ITEM_ID) }
        composable(Routes.APPROVALS) { Placeholder(Page.Approvals, it) }
        composable(
            Routes.APPROVAL,
            arguments = listOf(stringArg(Routes.ARG_APPROVAL_ID)),
            deepLinks = listOf(navDeepLink { uriPattern = DeepLinks.APPROVAL }),
        ) { Placeholder(Page.Approval, it, Routes.ARG_APPROVAL_ID) }
        composable(Routes.KEYS) {
            KeysScreen(
                onBack = back,
                onAdd = { navController.navigate(Routes.KEYS_NEW) },
                onEdit = { navController.navigate(Routes.keyEdit(it)) },
                onReplaceSecret = { navController.navigate(Routes.keySecret(it)) },
                onOpenUsage = { navController.navigate(Routes.USAGE) { launchSingleTop = true } },
            )
        }
        composable(Routes.KEYS_NEW) { AddKeyScreen(onBack = back, onAdded = back) }
        composable(Routes.KEY_EDIT, arguments = listOf(stringArg(Routes.ARG_CREDENTIAL_ID))) { entry ->
            val credentialId = entry.arguments?.getString(Routes.ARG_CREDENTIAL_ID).orEmpty()
            KeyEditScreen(
                credentialId = credentialId,
                onBack = back,
                onSaved = back,
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
                onSaved = back,
            )
        }
        composable(Routes.USAGE) { UsageScreen(onBack = back) }
        composable(
            Routes.VAULT,
            arguments = listOf(optionalStringArg(Routes.ARG_REQUEST_ID)),
            deepLinks = listOf(navDeepLink { uriPattern = DeepLinks.VAULT_REQUEST }),
        ) { Placeholder(Page.Vault, it, Routes.ARG_REQUEST_ID) }
        composable(Routes.DEVICES, arguments = listOf(optionalStringArg(Routes.ARG_ACTION))) { entry ->
            DevicesScreen(
                action = DevicesAction.fromWire(entry.arguments?.getString(Routes.ARG_ACTION)),
                onBack = back,
                onEditName = { navController.navigate(Routes.ACCOUNT_NAME) },
                onDeleteAccount = { navController.navigate(Routes.DELETE_ACCOUNT) },
            )
        }
        composable(Routes.SETTINGS) {
            SettingsScreen(
                onBack = back,
                onOpenDevices = { action -> navController.navigate(Routes.devices(action?.wire)) },
                onEditName = { navController.navigate(Routes.ACCOUNT_NAME) },
                onDeleteAccount = { navController.navigate(Routes.DELETE_ACCOUNT) },
                onOpenKeys = { navController.navigate(Routes.KEYS) },
                onOpenUsage = { navController.navigate(Routes.USAGE) },
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
