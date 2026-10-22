package cn.thinktin.app.navigation

import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import androidx.navigation.navDeepLink
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.drawer.AppDrawer
import cn.thinktin.app.ui.drawer.DrawerDestination
import cn.thinktin.app.ui.drawer.DrawerViewModel
import cn.thinktin.app.ui.home.HomeScreen
import cn.thinktin.app.ui.placeholder.ComingSoonScreen
import cn.thinktin.app.ui.placeholder.Page
import cn.thinktin.app.ui.settings.SettingsScreen
import kotlinx.coroutines.launch

/** 已登录（或演示模式）时的主界面：抽屉 + NavHost（第 3 节）。 */
@Composable
fun MainNavigation(navController: NavHostController = rememberNavController()) {
    val service = LocalThinktinService.current
    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    val drawerViewModel: DrawerViewModel = viewModel(
        key = "drawer-${System.identityHashCode(service)}",
        factory = viewModelFactory { initializer { DrawerViewModel(service) } },
    )
    val drawerUi by drawerViewModel.uiState.collectAsStateWithLifecycle()
    val backStack by navController.currentBackStackEntryAsState()
    val currentRoute = backStack?.destination?.route

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
                            DrawerDestination.Inbox -> Routes.inbox()
                            DrawerDestination.Plans -> Routes.PLANS
                            DrawerDestination.Teams -> Routes.TEAMS
                            DrawerDestination.Settings -> Routes.SETTINGS
                        }
                        navController.navigateTopLevel(route)
                    }
                },
                onOpenInstance = { instance -> closeDrawerThen { navController.navigate(Routes.chat(instance.id)) } },
            )
        },
    ) {
        MainNavHost(navController = navController, onOpenDrawer = { scope.launch { drawerState.open() } })
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

@Composable
private fun MainNavHost(navController: NavHostController, onOpenDrawer: () -> Unit) {
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
                onOpenInstanceSettings = { navController.navigate(Routes.instance(it)) },
            )
        }
        composable(Routes.CHAT, arguments = listOf(stringArg(Routes.ARG_INSTANCE_ID))) {
            Placeholder(Page.Chat, it, Routes.ARG_INSTANCE_ID)
        }
        composable(
            Routes.RUN,
            arguments = listOf(stringArg(Routes.ARG_RUN_ID)),
            deepLinks = listOf(navDeepLink { uriPattern = DeepLinks.RUN }),
        ) { Placeholder(Page.Run, it, Routes.ARG_RUN_ID) }
        composable(Routes.CATALOG) { Placeholder(Page.Catalog, it) }
        composable(Routes.AGENT, arguments = listOf(stringArg(Routes.ARG_AGENT_ID))) {
            Placeholder(Page.Agent, it, Routes.ARG_AGENT_ID)
        }
        composable(
            Routes.INSTANCE,
            arguments = listOf(stringArg(Routes.ARG_INSTANCE_ID)),
            deepLinks = listOf(navDeepLink { uriPattern = DeepLinks.INSTANCE }),
        ) { Placeholder(Page.Instance, it, Routes.ARG_INSTANCE_ID) }
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
        composable(Routes.KEYS) { Placeholder(Page.Keys, it) }
        composable(
            Routes.VAULT,
            arguments = listOf(optionalStringArg(Routes.ARG_REQUEST_ID)),
            deepLinks = listOf(navDeepLink { uriPattern = DeepLinks.VAULT_REQUEST }),
        ) { Placeholder(Page.Vault, it, Routes.ARG_REQUEST_ID) }
        composable(Routes.DEVICES) { Placeholder(Page.Devices, it) }
        composable(Routes.SETTINGS) { SettingsScreen(onBack = back) }
    }
}

private fun stringArg(name: String) = navArgument(name) { type = NavType.StringType }

private fun optionalStringArg(name: String) = navArgument(name) {
    type = NavType.StringType
    nullable = true
    defaultValue = null
}
