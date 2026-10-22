package cn.thinktin.app

import android.app.Application

/** Application：持有 [AppContainer]。测试可以覆盖 [createContainer]。 */
open class ThinktinApp : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = createContainer()
    }

    protected open fun createContainer(): AppContainer = AppContainer.create(this)
}
