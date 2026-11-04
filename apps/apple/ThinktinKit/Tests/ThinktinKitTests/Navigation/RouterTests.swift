import Foundation
import Testing

@testable import ThinktinKit

// Router：首页为根的主导航栈、当前实例、两层 sheet 和它们自己的导航栈、深链与推送的返回栈、没登录时先记下
// （docs/ios-ui-redesign.md 第 3.3、3.4 节）。

@MainActor
@Suite("导航")
struct RouterTests {
    @Test("根永远是首页，当前实例不改根")
    func root() {
        let router = Router()
        #expect(router.rootRoute == .home)
        #expect(router.topRoute == .home)
        #expect(router.visibleRoute == .home)
        #expect(router.isAtRoot)
        router.currentInstanceID = "i1"
        #expect(router.rootRoute == .home)
        #expect(router.path.isEmpty)
        router.open(.run("r1"))
        #expect(router.topRoute == .run("r1"))
        #expect(router.visibleRoute == .run("r1"))
        #expect(!router.isAtRoot)
    }

    @Test("open：压栈、不重复压、返回")
    func openPush() {
        let router = Router()
        router.open(.run("r1"))
        router.open(.run("r1"))
        router.open(.runTree("r1"))
        #expect(router.path == [.run("r1"), .runTree("r1")])
        router.pop()
        #expect(router.path == [.run("r1")])
        router.pop()
        router.pop()
        #expect(router.path.isEmpty)
        #expect(router.sheet == nil)
    }

    @Test("open：对话压栈并记成当前实例；栈里已有这个对话就退回到它")
    func openConversation() {
        let router = Router(path: [.inbox])
        router.open(.conversation("i1"))
        #expect(router.path == [.inbox, .conversation("i1")])
        #expect(router.currentInstanceID == "i1")
        router.open(.instance("i1"))
        router.open(.modelRoutes("i1"))
        router.open(.conversation("i1"))
        #expect(router.path == [.inbox, .conversation("i1")])
        // 另一个实例的对话照常压上去。
        router.open(.run("r2"))
        router.open(.conversation("i2"))
        #expect(router.path == [.inbox, .conversation("i1"), .run("r2"), .conversation("i2")])
        #expect(router.currentInstanceID == "i2")
    }

    @Test("open：对话总是先关掉 sheet 再压进主栈（领养成功、新任务选实例）")
    func conversationFromSheet() {
        let router = Router(path: [.inbox])
        router.open(.adopt(agentID: nil))
        router.open(.agent("claude"))
        router.open(.addCredential)
        #expect(router.nestedSheet == .addCredential)
        router.open(.conversation("i3"))
        #expect(router.sheet == nil)
        #expect(router.nestedSheet == nil)
        #expect(router.sheetPath.isEmpty)
        #expect(router.path == [.inbox, .conversation("i3")])
        #expect(router.currentInstanceID == "i3")
    }

    @Test("open：首页、搜索回到根并关掉 sheet；搜索通知首页激活搜索栏；整页状态忽略")
    func openRootAndGlobal() {
        let router = Router(path: [.inbox, .inboxItem("x")], currentInstanceID: "i1")
        router.open(.settings)
        router.open(.home)
        #expect(router.path.isEmpty)
        #expect(router.sheet == nil)
        #expect(router.currentInstanceID == "i1")
        #expect(router.searchRequest == 0)

        router.open(.plans(instanceID: nil))
        router.open(.settings)
        router.open(.search)
        #expect(router.path.isEmpty)
        #expect(router.sheet == nil)
        #expect(router.searchRequest == 1)
        router.open(.search)
        #expect(router.searchRequest == 2)

        router.open(.frozen)
        router.open(.signIn)
        #expect(router.path.isEmpty && router.sheet == nil)
    }

    @Test("sheet 里压栈压进 sheet 自己的导航栈，不关 sheet（设置里点保险箱条目）")
    func sheetPath() {
        let router = Router(path: [.conversation("i1")], currentInstanceID: "i1")
        router.open(.settings)
        #expect(router.sheet == .settings)
        #expect(router.frontSheet == .settings)
        #expect(router.visibleRoute == .settings)
        #expect(router.routeBelowSheet == .conversation("i1"))
        router.open(.vault)
        router.open(.vaultItem("v1"))
        router.open(.vaultItem("v1"))
        #expect(router.sheetPath == [.vault, .vaultItem("v1")])
        #expect(router.path == [.conversation("i1")])
        #expect(router.visibleRoute == .vaultItem("v1"))
        #expect(router.topRoute == .conversation("i1"))
        // 返回先退 sheet 的栈，退到根再返回就关掉 sheet；主栈不动。
        router.pop()
        #expect(router.sheetPath == [.vault])
        #expect(router.visibleRoute == .vault)
        router.pop()
        #expect(router.sheet == .settings)
        router.pop()
        #expect(router.sheet == nil)
        #expect(router.path == [.conversation("i1")])
    }

    @Test("sheet 里再开 sheet 页叠第二层，第二层有自己的栈；关掉只关最前面那层")
    func nestedSheet() {
        let router = Router()
        router.open(.settings)
        router.open(.credentials)
        router.open(.addCredential)
        #expect(router.sheet == .settings)
        #expect(router.sheetPath == [.credentials])
        #expect(router.nestedSheet == .addCredential)
        #expect(router.frontSheet == .addCredential)
        #expect(router.routeBelowSheet == .credentials)
        #expect(router.visibleRoute == .addCredential)

        router.open(.modelRoutes("i1"))
        #expect(router.nestedSheetPath == [.modelRoutes("i1")])
        #expect(router.sheetPath == [.credentials])
        #expect(router.visibleRoute == .modelRoutes("i1"))

        // 已经开着的不重复弹；第三个 sheet 页换掉第二层（最多两层），它的栈清掉。
        router.present(.addCredential)
        #expect(router.nestedSheetPath == [.modelRoutes("i1")])
        router.open(.onboarding)
        #expect(router.sheet == .settings)
        #expect(router.nestedSheet == .onboarding)
        #expect(router.nestedSheetPath.isEmpty)
        // 再弹第一层的那个页面：回到它（关掉上面那层）。
        router.present(.settings)
        #expect(router.sheet == .settings)
        #expect(router.nestedSheet == nil)
        #expect(router.sheetPath == [.credentials])

        router.open(.addCredential)
        router.dismissSheet()
        #expect(router.nestedSheet == nil)
        #expect(router.sheet == .settings)
        #expect(router.sheetPath == [.credentials])
        #expect(router.visibleRoute == .credentials)
        router.dismissSheet()
        #expect(router.sheet == nil)
        #expect(router.sheetPath.isEmpty)
        #expect(router.routeBelowSheet == nil)
        router.dismissSheet()
        #expect(router.sheet == nil)
    }

    @Test("sheet 换了或被系统下滑关掉：它的栈和上面那层一起清掉")
    func sheetResets() {
        let router = Router()
        router.open(.settings)
        router.open(.credentials)
        router.open(.addCredential)
        router.open(.usage)
        // 系统下滑关掉第二层（`.sheet(item:)` 的绑定写 nil）。
        router.nestedSheet = nil
        #expect(router.nestedSheetPath.isEmpty)
        #expect(router.sheetPath == [.credentials])
        router.open(.addCredential)
        // 下滑关掉第一层。
        router.sheet = nil
        #expect(router.sheetPath.isEmpty)
        #expect(router.nestedSheet == nil)

        router.open(.settings)
        router.open(.vault)
        router.sheet = .newTask
        #expect(router.sheetPath.isEmpty)
        // 第二层里返回：退到它的根再返回就关掉它。
        router.open(.agentCatalog)
        router.open(.newPlan(instanceID: nil))
        router.pop()
        #expect(router.nestedSheet == nil)
        #expect(router.sheet == .newTask)
        #expect(router.sheetPath == [.agentCatalog])
        router.dismissAllSheets()
        #expect(router.sheet == nil && router.nestedSheet == nil)
    }

    @Test("工作台菜单的入口：先关掉 sheet、回到首页再压")
    func topLevelEntries() {
        let router = Router(path: [.conversation("i1"), .run("r1"), .runTree("r1")], currentInstanceID: "i1")
        router.open(.settings)
        router.open(.vault)
        router.openTopLevel(.inbox)
        #expect(router.path == [.inbox])
        #expect(router.sheet == nil)
        #expect(router.sheetPath.isEmpty)
        router.openTopLevel(.plans(instanceID: nil))
        #expect(router.path == [.plans(instanceID: nil)])
        router.openTopLevel(.newTask)
        #expect(router.sheet == .newTask)
        #expect(router.path == [.plans(instanceID: nil)])
        router.openTopLevel(.settings)
        #expect(router.sheet == .newTask)
        #expect(router.nestedSheet == .settings)
        router.openTopLevel(.conversation("i2"))
        #expect(router.path == [.conversation("i2")])
        #expect(router.currentInstanceID == "i2")
        #expect(router.sheet == nil)
        router.openTopLevel(.search)
        #expect(router.path.isEmpty)
        #expect(router.searchRequest == 1)
    }

    @Test("切换实例：从首页进它的对话；传 nil 回到首页")
    func selectInstance() {
        let router = Router(path: [.inbox, .conversation("i1"), .instance("i1")], currentInstanceID: "i1")
        router.open(.settings)
        router.selectInstance("i3")
        #expect(router.currentInstanceID == "i3")
        #expect(router.path == [.conversation("i3")])
        #expect(router.sheet == nil)
        router.selectInstance(nil)
        #expect(router.currentInstanceID == nil)
        #expect(router.path.isEmpty)
    }

    @Test("新任务：从首页进实例的对话，通知对话页聚焦输入框；没有实例时只回到首页")
    func newTask() {
        let router = Router(path: [.plans(instanceID: nil)], currentInstanceID: "i1")
        router.open(.newTask)
        router.requestNewTask()
        #expect(router.path == [.conversation("i1")])
        #expect(router.sheet == nil)
        #expect(router.newTaskRequest == 1)
        router.requestNewTask(in: "i2")
        #expect(router.currentInstanceID == "i2")
        #expect(router.path == [.conversation("i2")])
        #expect(router.newTaskRequest == 2)

        let empty = Router(path: [.inbox])
        empty.requestNewTask()
        #expect(empty.path.isEmpty)
        #expect(empty.newTaskRequest == 0)
    }

    @Test("实例删了：各层栈里从它的第一个页面起拿掉，根是它的 sheet 关掉")
    func removeRoutes() {
        let router = Router(path: [.inbox, .conversation("i1"), .run("r1"), .instance("i1")])
        router.removeRoutes(of: "i2")
        #expect(router.path == [.inbox, .conversation("i1"), .run("r1"), .instance("i1")])
        router.removeRoutes(of: "i1")
        #expect(router.path == [.inbox])

        router.open(.adopt(agentID: nil))
        router.open(.agent("claude"))
        router.open(.instance("i2"))
        router.open(.modelRoutes("i2"))
        router.open(.newPlan(instanceID: "i2"))
        router.open(.plan("p1"))
        router.removeRoutes(of: "i2")
        #expect(router.nestedSheet == nil)
        #expect(router.sheet == .adopt(agentID: nil))
        #expect(router.sheetPath == [.agent("claude")])
        #expect(router.path == [.inbox])

        router.dismissAllSheets()
        router.present(.newPlan(instanceID: "i4"))
        router.open(.plan("p2"))
        router.removeRoutes(of: "i4")
        #expect(router.sheet == nil)
        #expect(router.sheetPath.isEmpty)
    }

    @Test("深链：关掉 sheet，返回栈“首页 → 目标页”，实例的页面经过它的对话")
    func deepLinks() throws {
        let router = Router(path: [.plans(instanceID: nil), .plan("p0")], currentInstanceID: "i1")
        router.open(.settings)
        router.open(.vault)
        #expect(router.handle(url: try #require(URL(string: "thinktin://run/r9"))))
        #expect(router.path == [.run("r9")])
        #expect(router.sheet == nil)
        #expect(router.sheetPath.isEmpty)
        #expect(router.currentInstanceID == "i1")

        #expect(router.handle(url: try #require(URL(string: "thinktin://instance/i5"))))
        #expect(router.currentInstanceID == "i5")
        #expect(router.path == [.conversation("i5"), .instance("i5")])

        #expect(router.handle(url: try #require(URL(string: "thinktin://vault/request/q1"))))
        #expect(router.path == [.vaultRequest("q1")])
        #expect(router.currentInstanceID == "i5")

        #expect(!router.handle(url: try #require(URL(string: "thinktin://nope/1"))))
        #expect(!router.handle(url: try #require(URL(string: "https://example.com"))))
        #expect(router.path == [.vaultRequest("q1")])

        // 系统相机扫了电脑上的配对二维码：弹出配对。
        let pair = "thinktin-pair:v1?d=mac&k=key&n=nonce&e=1"
        #expect(router.handle(url: try #require(URL(string: pair))))
        #expect(router.sheet == .pairComputer(code: pair))
        #expect(router.path.isEmpty)
        router.dismissSheet()

        router.show(.conversation("i7"))
        #expect(router.currentInstanceID == "i7")
        #expect(router.path == [.conversation("i7")])
        router.show(.modelRoutes("i8"))
        #expect(router.path == [.conversation("i8"), .modelRoutes("i8")])
        router.show(.newPlan(instanceID: nil))
        #expect(router.sheet == .newPlan(instanceID: nil))
        #expect(router.path.isEmpty)
        router.show(.search)
        #expect(router.sheet == nil)
        #expect(router.path.isEmpty)
        #expect(router.searchRequest == 1)
        router.show(.home)
        #expect(router.path.isEmpty)
        #expect(router.searchRequest == 1)
    }

    @Test("推送：运行详情经过推送里实例的对话；审批这类“首页 → 目标页”，照样记下实例")
    func push() {
        let router = Router(currentInstanceID: "i1")
        router.handle(push: PushPayload(kind: .runFinished, instanceID: "i2", runID: "r2"))
        #expect(router.currentInstanceID == "i2")
        #expect(router.path == [.conversation("i2"), .run("r2")])
        router.handle(push: PushPayload(kind: .approval, instanceID: "i3", approvalID: "a1"))
        #expect(router.currentInstanceID == "i3")
        #expect(router.path == [.approval("a1")])
        // 只有实例 id：首页 → 实例的对话。
        router.handle(push: PushPayload(kind: .runFailed, instanceID: "i4"))
        #expect(router.path == [.conversation("i4")])
        // 没有实例 id 的运行：首页 → 运行详情。
        router.handle(push: PushPayload(kind: .runFinished, runID: "r5"))
        #expect(router.path == [.run("r5")])
        #expect(router.currentInstanceID == "i4")
        router.handle(push: PushPayload(kind: .planConfirm))
        #expect(router.path == [.plans(instanceID: nil)])
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

        // 记下的推送带实例：恢复后返回栈经过它的对话。
        router.isHoldingRoutes = true
        router.handle(push: PushPayload(kind: .runFinished, instanceID: "i6", runID: "r6"))
        router.isHoldingRoutes = false
        #expect(router.path == [.conversation("i6"), .run("r6")])
    }

    @Test("退出登录：全部清空")
    func reset() {
        let router = Router(path: [.inbox], currentInstanceID: "i1")
        router.open(.settings)
        router.open(.vault)
        router.open(.addCredential)
        router.open(.usage)
        router.isHoldingRoutes = true
        router.show(.run("r1"))
        router.reset()
        #expect(router.path.isEmpty)
        #expect(router.sheet == nil)
        #expect(router.sheetPath.isEmpty)
        #expect(router.nestedSheet == nil)
        #expect(router.nestedSheetPath.isEmpty)
        #expect(router.currentInstanceID == nil)
        #expect(router.pendingRoute == nil)
    }

    @Test("首页的行直接改主栈压对话（NavigationLink）：最上面的对话记成当前实例；退回首页、进别的页面不清")
    func pathTracksCurrentInstance() {
        let router = Router(currentInstanceID: "i1")
        var seen: [InstanceID?] = []
        router.instanceSelectionDidChange = { seen.append($0) }
        router.path.append(.conversation("i2"))
        #expect(router.currentInstanceID == "i2")
        router.path.append(.instance("i2"))
        #expect(router.currentInstanceID == "i2")
        // 系统的返回手势改的也是这个绑定。
        router.path = []
        #expect(router.currentInstanceID == "i2")
        router.path = [.inbox, .inboxItem("x")]
        #expect(router.currentInstanceID == "i2")
        // 深链的返回栈“首页 → 对话 → 运行”：栈里最上面的对话。
        router.path = [.conversation("i3"), .run("r1")]
        #expect(router.currentInstanceID == "i3")
        router.path = [.conversation("i3"), .conversation("i4")]
        #expect(router.currentInstanceID == "i4")
        #expect(seen == ["i2", "i3", "i4"])
    }

    @Test("搜索请求：首页晚出现时照样补上，处理过的不再激活；退出登录时丢掉没处理的")
    func searchRequests() {
        let router = Router()
        #expect(!router.hasPendingSearchRequest)
        // 冷启动的深链：首页还没出现，请求先记着。
        router.show(.search)
        router.open(.search)
        #expect(router.searchRequest == 2)
        #expect(router.hasPendingSearchRequest)
        // 首页出现、激活了搜索栏：两次一起算处理了，首页重建时不再激活。
        router.searchRequestHandled()
        #expect(!router.hasPendingSearchRequest)
        #expect(router.handledSearchRequest == 2)
        router.open(.search)
        #expect(router.hasPendingSearchRequest)
        // 换账号后不能自己弹出搜索栏。
        router.reset()
        #expect(!router.hasPendingSearchRequest)
        #expect(router.searchRequest == 3)
    }

    @Test("当前实例变了才通知")
    func selectionHook() {
        let router = Router()
        var seen: [InstanceID?] = []
        router.instanceSelectionDidChange = { seen.append($0) }
        router.selectInstance("i1")
        router.selectInstance("i1")
        router.open(.conversation("i2"))
        router.open(.conversation("i2"))
        router.reset()
        #expect(seen == ["i1", "i2", nil])
    }
}
