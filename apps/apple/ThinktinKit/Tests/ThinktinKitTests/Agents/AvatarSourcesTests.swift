import Foundation
import Testing

@testable import ThinktinKit

// 改头像页的“形状 / 生成 / 上传”（规范 4.4.4，参考 18、19、20）：分段、上传的两行、生成的描述规则、“即将推出”的字。

@Suite("改头像的三个分段")
struct AvatarSourcesTests {
    @Test("分段：形状、生成、上传，只有形状现在能用")
    func tabs() {
        #expect(AvatarSourceTab.allCases.map { $0.title(.chinese) } == ["形状", "生成", "上传"])
        #expect(AvatarSourceTab.allCases.map { $0.title(.english) } == ["Shape", "Generate", "Upload"])
        #expect(AvatarSourceTab.allCases.filter(\.isAvailable) == [.shape])
        #expect(AvatarUploadSource.allCases.map { $0.title(.chinese) } == ["从相册选择", "拍照"])
        #expect(AvatarUploadSource.allCases.map(\.systemImage) == ["photo", "camera"])
    }

    @Test("生成的描述：写了才能点，去掉首尾空白算字数，超长有提示")
    func prompt() {
        #expect(!AvatarGenerationPrompt.canSubmit(""))
        #expect(!AvatarGenerationPrompt.canSubmit("  \n "))
        #expect(AvatarGenerationPrompt.canSubmit(" 一只橙色的纸船 "))
        #expect(AvatarGenerationPrompt.problem("纸船", language: .chinese) == nil)
        let max = String(repeating: "船", count: AvatarGenerationPrompt.maxLength)
        #expect(AvatarGenerationPrompt.canSubmit(max + "  "))
        let long = max + "船"
        #expect(!AvatarGenerationPrompt.canSubmit(long))
        #expect(AvatarGenerationPrompt.problem(long, language: .chinese) == "最多 300 个字，现在 301 个。")
        #expect(AvatarGenerationPrompt.problem(long, language: .english)?.hasPrefix("Up to 300") == true)
    }

    @Test("“即将推出”：生成、上传各有说明，脚注写明还不能用")
    func comingSoon() {
        #expect(AvatarSourceText.comingSoon(.chinese) == "即将推出")
        #expect(AvatarSourceText.comingSoon(.english) == "Coming soon")
        for tab in [AvatarSourceTab.generate, .upload] {
            #expect(!AvatarSourceText.comingSoonMessage(tab, language: .chinese).isEmpty)
            #expect(!AvatarSourceText.comingSoonMessage(tab, language: .english).isEmpty)
        }
        #expect(AvatarSourceText.uploadFooter(.chinese).contains("25 MB"))
        #expect(AvatarSourceText.uploadFooter(.chinese).contains("即将推出"))
        #expect(AvatarSourceText.generateFooter(.chinese).contains("即将推出"))
    }
}
