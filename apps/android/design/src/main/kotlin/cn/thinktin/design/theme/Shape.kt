package cn.thinktin.design.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Shapes
import androidx.compose.ui.unit.dp

/** 第 2.3 节的圆角。 */
object ThinktinShapes {
    val Card = RoundedCornerShape(16.dp)
    val Composer = RoundedCornerShape(28.dp)
    val Bubble = RoundedCornerShape(18.dp)

    /** 用户消息：右下角 4dp。 */
    val UserBubble = RoundedCornerShape(topStart = 18.dp, topEnd = 18.dp, bottomEnd = 4.dp, bottomStart = 18.dp)
    val Button = RoundedCornerShape(20.dp)

    /** 底部面板（领养表单等）：只有上面两个角是圆的。 */
    val Sheet = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)
}

/** 第 2.3 节的间距。 */
object ThinktinSpacing {
    val Page = 16.dp
    val ListItemMinHeight = 56.dp
    val Paragraph = 12.dp
    val Message = 20.dp
}

internal val ThinktinMaterialShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(12.dp),
    medium = ThinktinShapes.Card,
    large = ThinktinShapes.Button,
    extraLarge = ThinktinShapes.Composer,
)
