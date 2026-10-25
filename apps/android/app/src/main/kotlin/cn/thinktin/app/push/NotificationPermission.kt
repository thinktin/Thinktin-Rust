package cn.thinktin.app.push

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat

/**
 * 通知权限（Android 13 起要用户允许，13.8）：登录进了主界面（演示模式不问）、还没允许、这次安装没问过时问一次。
 * 拒绝了不再弹（系统也只让问两次），设置页的“通知”能跳系统设置（13.13）。
 */
@Composable
fun RequestNotificationPermissionOnce(enabled: Boolean) {
    val context = LocalContext.current
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    LaunchedEffect(enabled) {
        if (!enabled || !shouldAsk(context)) return@LaunchedEffect
        markAsked(context)
        launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
    }
}

/** 能发通知了（Android 13 以下装上就有）。 */
fun hasNotificationPermission(context: Context): Boolean =
    Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
        PackageManager.PERMISSION_GRANTED

private fun shouldAsk(context: Context): Boolean =
    Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
        !hasNotificationPermission(context) &&
        !prefs(context).getBoolean(KEY_ASKED, false)

private fun markAsked(context: Context) {
    prefs(context).edit().putBoolean(KEY_ASKED, true).apply()
}

private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

private const val PREFS = "push"
private const val KEY_ASKED = "notification_permission_asked"
