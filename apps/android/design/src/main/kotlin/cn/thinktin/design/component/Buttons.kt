package cn.thinktin.design.component

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import cn.thinktin.design.R
import cn.thinktin.design.theme.ThinktinShapes
import cn.thinktin.design.theme.ThinktinTheme

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
        contentPadding = PaddingValues(horizontal = 24.dp, vertical = 12.dp),
    ) {
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
        }
    }
}

@Preview(showBackground = true)
@Composable
internal fun PrimaryButtonPreview() {
    ThinktinTheme {
        PrimaryButton(text = "领养一个 agent", onClick = {})
    }
}
