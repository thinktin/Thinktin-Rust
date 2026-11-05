import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// Botin 的附加页（第 2 轮 r2/botin）：编辑页的“语音通话”组（参考 12、13–17、85–88）、改头像的三个分段（18–20）。
/// 视图模型的逻辑在 ThinktinKitTests 的 `BotinVoiceTests`、`AvatarSourcesTests` 里测。
@MainActor
@Suite("Botin 附加页的界面")
struct BotinExtrasScreensTests {
    @Test("编辑页的语音通话组：没选过、选过（音色、1.5x、日语），浅色中文、深色英文、大字号")
    func editVoiceSection() {
        let mock = MockClient(autoReply: false)
        let voices = BotinVoiceStore(defaults: nil)
        let fresh = InstanceDetailModel(
            client: mock, instanceID: DemoData.writerID, instance: mock.state.instances[0], voices: voices)
        hostAndLayout(NavigationStack { InstanceEditScreen(model: fresh) }.previewShell())

        voices.set(
            BotinVoiceSettings(voiceID: "cedar", speed: .oneAndHalf, languageCode: "ja"), for: DemoData.reviewerID)
        let chosen = InstanceDetailModel(
            client: mock, instanceID: DemoData.reviewerID, instance: mock.state.instances[1], voices: voices)
        hostAndLayout(NavigationStack { InstanceEditScreen(model: chosen) }.previewShell(.english, scheme: .dark))
        hostAndLayout(
            NavigationStack { InstanceEditScreen(model: chosen) }.previewShell().dynamicTypeSize(.accessibility3))
    }

    @Test("改头像的三个分段：形状、生成、上传，浅色中文、深色英文、大字号")
    func avatarTabs() {
        let store = InstanceAppearanceStore(defaults: nil)
        store.set(InstanceAppearance(shape: .cloud, color: .teal), for: DemoData.writerID)
        for tab in AvatarSourceTab.allCases {
            let editor = InstanceAppearanceEditor(instanceID: DemoData.writerID, name: "写作助手", store: store)
            hostAndLayout(NavigationStack { InstanceAvatarScreen(editor: editor, tab: tab) }.previewShell())
            hostAndLayout(
                NavigationStack { InstanceAvatarScreen(editor: editor, tab: tab) }.previewShell(
                    .english, scheme: .dark))
            hostAndLayout(
                NavigationStack { InstanceAvatarScreen(editor: editor, tab: tab) }.previewShell()
                    .dynamicTypeSize(.accessibility3))
        }
    }
}
