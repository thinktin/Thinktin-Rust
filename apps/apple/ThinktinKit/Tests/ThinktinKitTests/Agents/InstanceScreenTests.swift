import Foundation
import Testing

@testable import ThinktinKit

// 观看与接管（规范 4.6.2、4.6.3，参考 27–31、89）：页面的阶段（连接中 → 只看 → 控制中）、触控板模式、“即将推出”的操作、
// 使用说明、路由。画面接口还没有，这些是界面的状态机和演示。

@MainActor
@Suite("观看与接管")
struct InstanceScreenTests {
    @Test("连接中 → 只看 → 接管 → 交还：只在对的阶段响应")
    func phases() async {
        let model = InstanceScreenModel(instanceID: DemoData.writerID, connectDelay: .zero)
        #expect(model.phase == .connecting)
        // 连接中不能接管。
        model.takeControl()
        #expect(model.phase == .connecting)
        await model.connect()
        #expect(model.phase == .viewing)
        // 只看时剪贴板、键盘不响应，交还也不响应。
        model.perform(.keyboard)
        #expect(model.comingSoon == nil)
        model.handBack()
        #expect(model.phase == .viewing)

        model.takeControl()
        #expect(model.phase == .controlling)
        model.isTrackpadMode = true
        model.perform(.pasteFromDevice)
        #expect(model.comingSoon == .pasteFromDevice)
        model.comingSoon = nil

        model.handBack()
        #expect(model.phase == .viewing)
        #expect(!model.isTrackpadMode)
        // 再连一次不会回到连接中。
        await model.connect()
        #expect(model.phase == .viewing)
    }

    @Test("页面没等到就关了：停在连接中")
    func cancelledConnect() async {
        let model = InstanceScreenModel(instanceID: DemoData.writerID, connectDelay: .seconds(30))
        let task = Task { await model.connect() }
        task.cancel()
        await task.value
        #expect(model.phase == .connecting)
    }

    @Test("剪贴板和键盘：标题、图标、“即将推出”的说明")
    func actions() {
        #expect(
            InstanceScreenAction.allCases.map { $0.title(.chinese) } == ["从本机粘贴", "复制到本机", "键盘"])
        #expect(InstanceScreenAction.allCases.map(\.systemImage) == ["doc.on.clipboard", "doc.on.doc", "keyboard"])
        for action in InstanceScreenAction.allCases {
            #expect(!action.comingSoonMessage(.chinese).isEmpty)
            #expect(!action.comingSoonMessage(.english).isEmpty)
        }
        #expect(InstanceScreenText.comingSoon(.chinese) == "即将推出")
        #expect(InstanceScreenText.placeholderTitle(.chinese).contains("即将推出"))
        #expect(InstanceScreenText.phase(.controlling, language: .chinese) == "你在控制")
        #expect(InstanceScreenDemoData.aspectRatio == 1.6)
    }

    @Test("使用说明：手势、输入与剪贴板两组，每行都有图标、标题、说明；剪贴板那行用菜单里的字")
    func help() {
        for language in [DisplayLanguage.chinese, .english] {
            let sections = InstanceScreenHelp.sections(language)
            #expect(sections.count == 2)
            #expect(sections.map(\.items.count) == [5, 2])
            for item in sections.flatMap(\.items) {
                #expect(!item.systemImage.isEmpty && !item.title.isEmpty && !item.detail.isEmpty)
            }
            #expect(Set(sections.flatMap(\.items).map(\.id)).count == 7)
            let clipboard = sections[1].items[1].detail
            #expect(clipboard.contains(InstanceScreenAction.copyToDevice.title(language)))
            #expect(clipboard.contains(InstanceScreenAction.pasteFromDevice.title(language)))
        }
        #expect(InstanceScreenHelp.footer(.chinese).contains("即将推出"))
    }

    @Test("路由：归 Botin 那一组、压栈、离线不可用；从外面打开时经过对话；没有深链")
    func route() {
        let route = AppRoute.instanceScreen(DemoData.writerID)
        #expect(route.feature == .agents)
        #expect(route.presentation == .push)
        #expect(route.offlinePolicy == .unavailable)
        #expect(route.instanceID == DemoData.writerID)
        #expect(route.title(.chinese) == "观看与接管")
        #expect(DeepLink.backStack(to: route) == [.conversation(DemoData.writerID), route])
        #expect(DeepLink.url(for: route) == nil)
    }
}
