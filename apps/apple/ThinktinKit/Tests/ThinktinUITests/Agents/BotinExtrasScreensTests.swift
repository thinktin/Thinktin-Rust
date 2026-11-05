import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// Botin 的附加页（第 2 轮 r2/botin）：编辑页的“语音通话”组（参考 12、13–17、85–88）。视图模型的逻辑在 ThinktinKitTests 的
/// `BotinVoiceTests` 里测。
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
}
