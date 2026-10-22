package cn.thinktin.app

import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import cn.thinktin.app.ui.AppRoot
import cn.thinktin.design.theme.Appearance
import cn.thinktin.design.theme.ThinktinTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        val container = (application as ThinktinApp).container
        setContent {
            val settings by container.settings.collectAsStateWithLifecycle(initialValue = null)
            val appearance = settings?.appearance ?: Appearance.System
            ThinktinTheme(appearance = appearance) {
                SystemBarsFor(appearance)
                AppRoot(container = container, settings = settings)
            }
        }
    }

    /** 状态栏、导航栏图标的深浅跟着 App 的外观设置走（不只是系统的）。 */
    @Composable
    private fun SystemBarsFor(appearance: Appearance) {
        val dark = when (appearance) {
            Appearance.System -> isSystemInDarkTheme()
            Appearance.Light -> false
            Appearance.Dark -> true
        }
        DisposableEffect(dark) {
            val style = if (dark) {
                SystemBarStyle.dark(Color.TRANSPARENT)
            } else {
                SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT)
            }
            enableEdgeToEdge(statusBarStyle = style, navigationBarStyle = style)
            onDispose {}
        }
    }
}
