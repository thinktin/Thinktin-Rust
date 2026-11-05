import Foundation

// 改头像页顶上的分段“形状 / 生成 / 上传”（规范 4.4.4，参考 18、19、20）。只有形状能用（存本机，6.9 A）：生成要图片生成服务和
// 用哪把 key、费用怎么算（6.9），上传要存储接口和 Botin 上的头像字段（6.9 B），都还没有，用户要先照参考把页面排出来
// （2026-11-05），所以两页的版式都做了，点了弹“即将推出”。

/// 改头像页的分段。
public enum AvatarSourceTab: String, CaseIterable, Hashable, Sendable, Identifiable {
    /// 形状网格 + 色板（参考 18），现在唯一能用的。
    case shape
    /// 写一句描述生成（参考 19）。
    case generate
    /// 从相册选、拍照（参考 20）。
    case upload

    public var id: String { rawValue }

    public func title(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .shape: return zh ? "形状" : "Shape"
        case .generate: return zh ? "生成" : "Generate"
        case .upload: return zh ? "上传" : "Upload"
        }
    }

    /// 这一页的操作现在能不能真的做（生成、上传要后端，点了弹“即将推出”）。
    public var isAvailable: Bool { self == .shape }
}

/// “上传”页的一行（参考 20：从相册选择、拍照）。
public enum AvatarUploadSource: String, CaseIterable, Hashable, Sendable, Identifiable {
    case photoLibrary
    case camera

    public var id: String { rawValue }

    public func title(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .photoLibrary: return zh ? "从相册选择" : "Choose from library"
        case .camera: return zh ? "拍照" : "Take photo"
        }
    }

    /// SF Symbols 的图标名。
    public var systemImage: String {
        switch self {
        case .photoLibrary: "photo"
        case .camera: "camera"
        }
    }
}

/// “生成”页的描述：多行输入，最多 `maxLength` 个字。
public enum AvatarGenerationPrompt {
    public static let maxLength = 300

    /// 去掉首尾空白之后的描述。
    public static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// “生成”能不能点：写了描述、不超长（点了弹“即将推出”）。
    public static func canSubmit(_ text: String) -> Bool {
        let prompt = normalized(text)
        return !prompt.isEmpty && prompt.count <= maxLength
    }

    /// 超长时输入框下面的提示；没超长为 nil。
    public static func problem(_ text: String, language: DisplayLanguage = .current) -> String? {
        let count = normalized(text).count
        guard count > maxLength else { return nil }
        return language == .chinese
            ? "最多 \(maxLength) 个字，现在 \(count) 个。" : "Up to \(maxLength) characters (now \(count))."
    }
}

/// 改头像页三个分段的字。
public enum AvatarSourceText {
    /// “生成”页输入框的占位字。
    public static func generatePlaceholder(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "描述想要的头像，比如“一只橙色的纸船”…" : "Describe the avatar, e.g. “an orange paper boat”…"
    }

    /// “生成”页的按钮。
    public static func generate(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "生成" : "Generate"
    }

    /// “生成”页按钮下面的一句。
    public static func generateFooter(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "按描述画一个头像，满意了再用。生成头像即将推出。"
            : "Draws an avatar from your description for you to keep or discard. Coming soon."
    }

    /// “上传”页那一组的脚注（参考 20 的“图片最大 25 MB”）。
    public static func uploadFooter(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "图片不超过 25 MB，选好之后可以裁剪。上传头像即将推出。"
            : "Images up to 25 MB. You can crop it after choosing. Uploading is coming soon."
    }

    /// “即将推出”提示的标题。
    public static func comingSoon(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "即将推出" : "Coming soon"
    }

    /// “即将推出”提示的说明。
    public static func comingSoonMessage(_ tab: AvatarSourceTab, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch tab {
        case .generate:
            return zh
                ? "生成头像还没有接上。现在可以在“形状”里挑形状和颜色。"
                : "Generating avatars isn't available yet. You can pick a shape and colour under Shape for now."
        case .upload:
            return zh
                ? "上传头像还没有接上。现在可以在“形状”里挑形状和颜色。"
                : "Uploading avatars isn't available yet. You can pick a shape and colour under Shape for now."
        case .shape:
            return ""
        }
    }

    /// “好”（关掉提示）。
    public static func ok(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "好" : "OK"
    }
}
