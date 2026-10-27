package cn.thinktin.app.ui.privacy

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import cn.thinktin.app.R
import cn.thinktin.app.push.FlavorPush
import cn.thinktin.app.push.hasNotificationPermission
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.design.theme.ThinktinSpacing

/** 收集的一项个人信息：是什么、用来做什么、什么时候收集。 */
data class CollectedInfo(@StringRes val name: Int, @StringRes val purpose: Int, @StringRes val scenario: Int)

/** 共享给的一个第三方：是谁、共享什么、用来做什么。 */
data class SharedParty(@StringRes val name: Int, @StringRes val data: Int, @StringRes val purpose: Int)

/** App 里一个收集个人信息的第三方 SDK（推送 SDK 接上后由各渠道的 [FlavorPush] 给出）。 */
data class ThirdPartySdk(val name: String, val vendor: String, @StringRes val data: Int, @StringRes val purpose: Int)

/** 一种系统权限的说明；[runtime] 的要用户允许，其余安装时就有。 */
data class PermissionInfo(
    val permission: String,
    @StringRes val name: Int,
    @StringRes val purpose: Int,
    val runtime: Boolean = false,
)

/**
 * 个人信息收集清单、第三方共享清单、第三方 SDK 清单、权限说明（13.11，工信部和各应用商店要求 App 里能查到）。
 * 和隐私政策（[cn.thinktin.app.ui.settings.PRIVACY_POLICY_URL]）、商店后台填的一致：改了这里要同步改那两处
 * （docs/android-release.md 第 2 节）。
 */
object PrivacyInfo {
    val collected = listOf(
        CollectedInfo(R.string.privacy_collect_phone, R.string.privacy_collect_phone_purpose, R.string.privacy_when_sign_in),
        CollectedInfo(R.string.privacy_collect_name, R.string.privacy_collect_name_purpose, R.string.privacy_collect_name_when),
        CollectedInfo(R.string.privacy_collect_device, R.string.privacy_collect_device_purpose, R.string.privacy_when_sign_in),
        CollectedInfo(R.string.privacy_collect_push, R.string.privacy_collect_push_purpose, R.string.privacy_when_signed_in),
        CollectedInfo(R.string.privacy_collect_content, R.string.privacy_collect_content_purpose, R.string.privacy_when_using),
        CollectedInfo(R.string.privacy_collect_keys, R.string.privacy_collect_keys_purpose, R.string.privacy_when_adding),
        CollectedInfo(R.string.privacy_collect_vault, R.string.privacy_collect_vault_purpose, R.string.privacy_when_adding),
        CollectedInfo(R.string.privacy_collect_logs, R.string.privacy_collect_logs_purpose, R.string.privacy_when_using),
        CollectedInfo(R.string.privacy_collect_usage, R.string.privacy_collect_usage_purpose, R.string.privacy_when_using),
    )

    val shared = listOf(
        SharedParty(R.string.privacy_share_sms, R.string.privacy_share_sms_data, R.string.privacy_share_sms_purpose),
        SharedParty(R.string.privacy_share_models, R.string.privacy_share_models_data, R.string.privacy_share_models_purpose),
        SharedParty(R.string.privacy_share_im, R.string.privacy_share_im_data, R.string.privacy_share_im_purpose),
    )

    /** App 里收集个人信息的第三方 SDK（推送 SDK 还没接，现在是空的）。 */
    val sdks: List<ThirdPartySdk> get() = listOfNotNull(FlavorPush.disclosure)

    /** 认得的权限（几个权限是同一件事的只列一次：指纹是旧系统的生物识别）。 */
    private val known = listOf(
        PermissionInfo(Manifest.permission.INTERNET, R.string.privacy_perm_internet, R.string.privacy_perm_internet_purpose),
        PermissionInfo(
            "android.permission.POST_NOTIFICATIONS",
            R.string.privacy_perm_notifications,
            R.string.privacy_perm_notifications_purpose,
            runtime = true,
        ),
        PermissionInfo("android.permission.USE_BIOMETRIC", R.string.privacy_perm_biometric, R.string.privacy_perm_biometric_purpose),
        PermissionInfo("android.permission.USE_FINGERPRINT", R.string.privacy_perm_biometric, R.string.privacy_perm_biometric_purpose),
        PermissionInfo(
            "android.permission.REQUEST_INSTALL_PACKAGES",
            R.string.privacy_perm_install,
            R.string.privacy_perm_install_purpose,
            runtime = true,
        ),
    )

    /**
     * 安装包实际申请的权限（读清单合并后的结果，新加的依赖带进来的权限也会列出来）：认得的给说明，认不得的原样列出；
     * App 自己定义的（`<包名>.*`，AndroidX 给动态广播加的）不算。
     */
    fun permissions(requested: List<String>, packageName: String): List<Pair<String, PermissionInfo?>> {
        val seen = mutableSetOf<Int>()
        return requested.distinct()
            .filterNot { it.startsWith("$packageName.") }
            .mapNotNull { permission ->
                val info = known.firstOrNull { it.permission == permission }
                when {
                    info == null -> permission to null
                    seen.add(info.name) -> permission to info
                    else -> null
                }
            }
    }

    /** 这个安装包申请的权限。 */
    fun requestedPermissions(context: Context): List<String> = try {
        context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
            .requestedPermissions?.toList().orEmpty()
    } catch (_: PackageManager.NameNotFoundException) {
        emptyList()
    }

    /** 要用户允许的权限现在允许了没有；安装时就有的为 null。 */
    fun isGranted(context: Context, permission: String): Boolean? = when (permission) {
        "android.permission.POST_NOTIFICATIONS" -> hasNotificationPermission(context) &&
            androidx.core.app.NotificationManagerCompat.from(context).areNotificationsEnabled()
        "android.permission.REQUEST_INSTALL_PACKAGES" ->
            Build.VERSION.SDK_INT < Build.VERSION_CODES.O || context.packageManager.canRequestPackageInstalls()
        else -> null
    }
}

/**
 * 收集清单、共享清单、SDK 清单三段（个人信息与权限页、首次启动的隐私政策页“查看清单”共用）。权限一段各自画
 * （隐私政策页上还没有权限可看）。
 */
@Composable
fun PrivacyListsContent(modifier: Modifier = Modifier) {
    Column(modifier = modifier) {
        PrivacySection(R.string.privacy_section_collected)
        PrivacyInfo.collected.forEach { item ->
            PrivacyItem(
                title = stringResource(item.name),
                lines = listOf(
                    stringResource(R.string.privacy_item_purpose, stringResource(item.purpose)),
                    stringResource(R.string.privacy_item_when, stringResource(item.scenario)),
                ),
            )
        }
        PrivacySection(R.string.privacy_section_shared)
        PrivacyInfo.shared.forEach { item ->
            PrivacyItem(
                title = stringResource(item.name),
                lines = listOf(
                    stringResource(R.string.privacy_item_data, stringResource(item.data)),
                    stringResource(R.string.privacy_item_purpose, stringResource(item.purpose)),
                ),
            )
        }
        PrivacySection(R.string.privacy_section_sdks)
        val sdks = PrivacyInfo.sdks
        if (sdks.isEmpty()) {
            Text(
                text = stringResource(R.string.privacy_no_sdks),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = ThinktinSpacing.Page, vertical = 8.dp),
            )
        } else {
            sdks.forEach { sdk ->
                PrivacyItem(
                    title = stringResource(R.string.privacy_sdk_title, sdk.name, sdk.vendor),
                    lines = listOf(
                        stringResource(R.string.privacy_item_data, stringResource(sdk.data)),
                        stringResource(R.string.privacy_item_purpose, stringResource(sdk.purpose)),
                    ),
                )
            }
        }
    }
}

@Composable
internal fun PrivacySection(@StringRes title: Int) {
    SectionHeader(
        title = stringResource(title),
        modifier = Modifier.padding(horizontal = ThinktinSpacing.Page).padding(top = 8.dp),
    )
}

@Composable
internal fun PrivacyItem(title: String, lines: List<String>, trailing: (@Composable () -> Unit)? = null) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                lines.forEach { Text(it) }
            }
        },
        trailingContent = trailing,
        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.background),
    )
}

/** 打开系统设置里这个 App 的详情页（关权限、通知）。 */
@Composable
internal fun SystemSettingsButton(onClick: () -> Unit) {
    TextButton(onClick = onClick) { Text(stringResource(R.string.privacy_open_system_settings)) }
}
