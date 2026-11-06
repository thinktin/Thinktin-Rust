import Foundation
import Testing

@testable import ThinktinKit

@MainActor
@Suite("输入框的“+”附件菜单")
struct ConversationAttachmentTests {
    @Test("三项照参考 08 的顺序；没有相机的设备不放拍照；都还不能用（等服务端收附件）")
    func menu() {
        #expect(ComposerAttachmentSource.menu(hasCamera: true) == [.photoLibrary, .camera, .files])
        #expect(ComposerAttachmentSource.menu(hasCamera: false) == [.photoLibrary, .files])
        #expect(ComposerAttachmentSource.allCases.allSatisfy { !$0.isAvailable })
        #expect(ComposerAttachmentSource.photoLibrary.title(.chinese) == "照片或视频")
        #expect(ComposerAttachmentSource.files.title(.english) == "Choose File")
        #expect(Set(ComposerAttachmentSource.allCases.map(\.systemImage)).count == 3)
        #expect(ConversationText.comingSoon(.chinese) == "即将推出")
        #expect(ConversationText.comingSoon(.english) == "Coming Soon")
        for source in ComposerAttachmentSource.allCases {
            #expect(!ConversationText.attachmentComingSoon(source, language: .chinese).isEmpty)
            #expect(!ConversationText.attachmentComingSoon(source, language: .chinese).contains("实例"))
        }
    }

    @Test("Botin 还在、不是只看本次过程时才有“+”")
    func availability() async {
        let mock = ConversationFixture.mock()
        let live = ConversationModel(client: mock, instanceID: ConversationFixture.writer)
        await live.start()
        #expect(live.canAttach)
        let focus = ConversationModel(
            client: mock, instanceID: ConversationFixture.writer, focusRunID: DemoData.weeklyRunID)
        #expect(!focus.canAttach)
        let gone = ConversationModel(client: mock, instanceID: "gone")
        await gone.start()
        #expect(!gone.canAttach)
    }
}
