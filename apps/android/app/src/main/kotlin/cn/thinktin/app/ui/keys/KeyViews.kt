package cn.thinktin.app.ui.keys

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import cn.thinktin.app.R
import cn.thinktin.data.model.Credential
import cn.thinktin.data.model.VendorInfo

/** 厂商的显示名：自定义接口用本地文案，厂商表里没有的显示 id。 */
@Composable
fun vendorName(vendorId: String, vendors: Map<String, VendorInfo>): String =
    if (vendorId == KeyRules.CUSTOM_VENDOR) {
        stringResource(R.string.key_vendor_custom)
    } else {
        vendors[vendorId]?.name ?: vendorId
    }

/** key 的标题：标签，没有标签时用厂商名。 */
@Composable
fun credentialTitle(credential: Credential, vendors: Map<String, VendorInfo>): String =
    credential.label.ifBlank { vendorName(credential.vendor, vendors) }

/** 选 key 时的一行：“工作 key（Anthropic · …a1b2）”。 */
@Composable
fun credentialOption(credential: Credential, vendors: Map<String, VendorInfo>): String = stringResource(
    R.string.key_option,
    credentialTitle(credential, vendors),
    vendorName(credential.vendor, vendors),
    credential.last4,
)

/**
 * 厂商标记：圆形底上的首字母（不用各家的图标和商标，设计规范开头）。读屏不读它（厂商名在文字里）。
 */
@Composable
fun VendorBadge(name: String, modifier: Modifier = Modifier) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surfaceVariant,
        contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier
            .size(40.dp)
            .clearAndSetSemantics { },
    ) {
        Box(contentAlignment = Alignment.Center) {
            Text(
                text = name.trim().take(1).uppercase(),
                style = MaterialTheme.typography.titleMedium,
            )
        }
    }
}
