import Foundation
import Testing

@testable import ThinktinKit

// Router：导航栈、当前实例、抽屉、sheet、深链与推送、没登录时先记下。

@MainActor
@Suite("导航")
struct RouterTests {
    @Test("根是当前实例的对话，没有实例时是首页")
    func root() {
        let router = Router()
        #expect(router.rootRoute == .home)
        #expect(router.topRoute == .home)
        #expect(router.isAtRoot)
        router.currentInstanceID = "i1"
        #expect(router.rootRoute == .conversation("i1"))
        router.open(.run("r1"))
        #expect(router.topRoute == .run("r1"))
        #expect(!router.isAtRoot)
    }

    @Test("open：压栈、不重复压、关掉抽屉和 sheet")
    func openPush() {
        let router = Router(isDrawerOpen: true)
        router.sheet = .newTask
        router.open(.run("r1"))
        router.open(.run("r1"))
        router.open(.runTree("r1"))
        #expect(router.path == [.run("r1"), .runTree("r1")])
        #expect(!router.isDrawerOpen)
        #expect(router.sheet == nil)
        router.pop()
        #expect(router.path == [.run("r1")])
        router.pop()
        router.pop()
        #expect(router.path.isEmpty)
    }

    @Test("open：对话切换实例回到根，sheet 弹出，整页状态忽略")
    func openOthers() {
        let router = Router(path: [.inbox, .inboxItem("x")])
        router.open(.conversation("i2"))
        #expect(router.currentInstanceID == "i2")
        #expect(router.path.isEmpty)

        router.open(.addCredential)
        #expect(router.sheet == .addCredential)
        #expect(router.path.isEmpty)
        router.dismissSheet()
        #expect(router.sheet == nil)

        router.open(.frozen)
        router.open(.signIn)
        #expect(router.path.isEmpty && router.sheet == nil)

        router.open(.plans)
        router.open(.home)
        #expect(router.path.isEmpty)
        #expect(router.currentInstanceID == "i2")
    }

    @Test("抽屉入口：先回到根再压")
    func drawerEntries() {
        let router = Router(path: [.run("r1"), .runTree("r1")], isDrawerOpen: true)
        router.openFromDrawer(.inbox)
        #expect(router.path == [.inbox])
        #expect(!router.isDrawerOpen)
        router.openFromDrawer(.newTask)
        #expect(router.sheet == .newTask)
        router.openFromDrawer(.settings)
        #expect(router.path == [.settings])
        #expect(router.sheet == nil)
        router.toggleDrawer()
        #expect(router.isDrawerOpen)
        router.closeDrawer()
        #expect(!router.isDrawerOpen)
        router.openDrawer()
        router.selectInstance("i3")
        #expect(router.currentInstanceID == "i3")
        #expect(router.path.isEmpty)
        #expect(!router.isDrawerOpen)
    }

    @Test("新任务：回到根，通知对话页聚焦输入框")
    func newTask() {
        let router = Router(path: [.plans], currentInstanceID: "i1")
        router.requestNewTask()
        #expect(router.path.isEmpty)
        #expect(router.newTaskRequest == 1)
        router.requestNewTask(in: "i2")
        #expect(router.currentInstanceID == "i2")
        #expect(router.newTaskRequest == 2)
    }

    @Test("深链：返回栈重建成“根 → 目标页”，带实例的顺带切实例")
    func deepLinks() throws {
        let router = Router(path: [.plans, .plan("p0")], currentInstanceID: "i1", isDrawerOpen: true)
        router.sheet = .newTask
        #expect(router.handle(url: try #require(URL(string: "thinktin://run/r9"))))
        #expect(router.path == [.run("r9")])
        #expect(router.sheet == nil)
        #expect(!router.isDrawerOpen)
        #expect(router.currentInstanceID == "i1")

        #expect(router.handle(url: try #require(URL(string: "thinktin://instance/i5"))))
        #expect(router.currentInstanceID == "i5")
        #expect(router.path == [.instance("i5")])

        #expect(!router.handle(url: try #require(URL(string: "thinktin://nope/1"))))
        #expect(!router.handle(url: try #require(URL(string: "https://example.com"))))
        #expect(router.path == [.instance("i5")])

        // 系统相机扫了电脑上的配对二维码：弹出配对。
        let pair = "thinktin-pair:v1?d=mac&k=key&n=nonce&e=1"
        #expect(router.handle(url: try #require(URL(string: pair))))
        #expect(router.sheet == .pairComputer(code: pair))
        router.dismissSheet()

        router.show(.conversation("i7"))
        #expect(router.currentInstanceID == "i7")
        #expect(router.path.isEmpty)
        router.show(.newPlan(instanceID: nil))
        #expect(router.sheet == .newPlan(instanceID: nil))
        #expect(router.path.isEmpty)
    }

    @Test("推送：跳到目标页，切到推送里的实例")
    func push() {
        let router = Router(currentInstanceID: "i1")
        router.handle(push: PushPayload(kind: .runFinished, instanceID: "i2", runID: "r2"))
        #expect(router.currentInstanceID == "i2")
        #expect(router.path == [.run("r2")])
        router.handle(push: PushPayload(kind: .approval, approvalID: "a1"))
        #expect(router.currentInstanceID == "i2")
        #expect(router.path == [.approval("a1")])
    }

    @Test("没登录时先记下，恢复后再跳，只跳一次")
    func holding() throws {
        let router = Router()
        router.isHoldingRoutes = true
        router.handle(push: PushPayload(kind: .runFailed, instanceID: "i2", runID: "r2"))
        #expect(router.path.isEmpty)
        #expect(router.pendingRoute == Router.PendingRoute(route: .run("r2"), instanceID: "i2"))
        // 新来的替换旧的。
        #expect(router.handle(url: try #require(URL(string: "thinktin://plan/p3"))))
        #expect(router.pendingRoute?.route == .plan("p3"))
        router.isHoldingRoutes = false
        #expect(router.path == [.plan("p3")])
        #expect(router.pendingRoute == nil)
        router.isHoldingRoutes = true
        router.isHoldingRoutes = false
        #expect(router.path == [.plan("p3")])

        router.isHoldingRoutes = true
        router.show(.inbox)
        router.discardPendingRoute()
        router.isHoldingRoutes = false
        #expect(router.path == [.plan("p3")])
    }

    @Test("退出登录：全部清空")
    func reset() {
        let router = Router(path: [.inbox], currentInstanceID: "i1", isDrawerOpen: true)
        router.sheet = .newTask
        router.isHoldingRoutes = true
        router.show(.run("r1"))
        router.reset()
        #expect(router.path.isEmpty)
        #expect(router.sheet == nil)
        #expect(!router.isDrawerOpen)
        #expect(router.currentInstanceID == nil)
        #expect(router.pendingRoute == nil)
    }

    @Test("当前实例变了才通知")
    func selectionHook() {
        let router = Router()
        var seen: [InstanceID?] = []
        router.instanceSelectionDidChange = { seen.append($0) }
        router.selectInstance("i1")
        router.selectInstance("i1")
        router.open(.conversation("i2"))
        router.reset()
        #expect(seen == ["i1", "i2", nil])
    }
}
