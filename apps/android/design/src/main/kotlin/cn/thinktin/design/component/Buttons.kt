package cn.thinktin.design.component

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import cn.thinktin.design.R
import cn.thinktin.design.theme.ThinktinShapes
import cn.thinktin.design.theme.ThinktinTheme

/** 所有按钮共用的内边距（设计稿：左右 24dp、上下 12dp）。 */
private val ButtonContentPadding = PaddingValues(horizontal = 24.dp, vertical = 12.dp)

/** 主按钮：主色、20dp 圆角。[loading] 时显示转圈并不可点。 */
@Composable
fun PrimaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    loading: Boolean = false,
) {
    Button(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled && !loading,
        shape = ThinktinShapes.Button,
        contentPadding = ButtonContentPadding,
    ) {
        ButtonContent(text, loading)
    }
}

/** 危险操作的主按钮（注销、删除）：错误色底，形状和 [PrimaryButton] 一样。 */
@Composable
fun DangerButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    loading: Boolean = false,
) {
    Button(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled && !loading,
        shape = ThinktinShapes.Button,
        contentPadding = ButtonContentPadding,
        colors = ButtonDefaults.buttonColors(
            containerColor = MaterialTheme.colorScheme.error,
            contentColor = MaterialTheme.colorScheme.onError,
        ),
    ) {
        ButtonContent(text, loading)
    }
}

/** 次按钮：描边、20dp 圆角（取消、上一步这类）。[trailingIcon] 用于下拉选择（地区码）。 */
@Composable
fun SecondaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    loading: Boolean = false,
    trailingIcon: ImageVector? = null,
) {
    OutlinedButton(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled && !loading,
        shape = ThinktinShapes.Button,
        contentPadding = ButtonContentPadding,
    ) {
        ButtonContent(text, loading, trailingIcon)
    }
}

@Composable
private fun ButtonContent(text: String, loading: Boolean, trailingIcon: ImageVector? = null) {
    if (loading) {
        val label = stringResource(R.string.design_loading)
        CircularProgressIndicator(
            modifier = Modifier
                .size(18.dp)
                .semantics { contentDescription = label },
            strokeWidth = 2.dp,
            color = LocalContentColor.current,
        )
    } else {
        Text(text)
        if (trailingIcon != null) Icon(trailingIcon, contentDescription = null)
    }
}

@Preview(showBackground = true)
@Composable
internal fun PrimaryButtonPreview() {
    ThinktinTheme {
        PrimaryButton(text = "领养一个 agent", onClick = {})
    }
}

@Preview(showBackground = true)
@Composable
internal fun DangerButtonPreview() {
    ThinktinTheme {
        Column {
            DangerButton(text = "永久注销", onClick = {})
            DangerButton(text = "永久注销", onClick = {}, loading = true)
        }
    }
}

@Preview(showBackground = true)
@Composable
internal fun SecondaryButtonPreview() {
    ThinktinTheme {
        SecondaryButton(text = "取消", onClick = {})
    }
}
