package cn.thinktin.app

import android.app.Application

/**
 * Application：持有 [AppContainer]。容器本身很轻（真实服务第一次用到时才在后台创建，见 [AppContainer.coreService]）。
 * 测试可以覆盖 [createContainer]，或在启动 Activity 之前换掉 [container]。
 */
open class ThinktinApp : Application() {
    lateinit var container: AppContainer
        internal set

    override fun onCreate() {
        super.onCreate()
        container = createContainer()
    }

    protected open fun createContainer(): AppContainer = AppContainer.create(this)
}
