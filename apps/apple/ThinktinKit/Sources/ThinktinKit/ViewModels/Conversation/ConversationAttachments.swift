import Foundation

// 输入框的“+”附件菜单（规范 4.3.6、6.13，参考 08）：照参考放三项——照片或视频、拍照、选择文件。ThinkTin 的运行附件（WBS 12.22）
// 要服务端先能收文件（后端 5.6），`ClientProtocol` 还没有上传接口，所以现在每一项点了都只弹“即将推出”的系统提示，不打开选择器。
// 接口有了以后：照片用 `.photosPicker`，拍照用 `UIImagePickerController`（`sourceType = .camera`），文件用 `.fileImporter`，
// 选好的放在输入框上面一排缩略图（输入框长成卡片，和引用回复一样）。

/// “+”菜单的一项。
public enum ComposerAttachmentSource: String, CaseIterable, Hashable, Sendable {
    /// 照片或视频（系统相册）。
    case photoLibrary
    /// 拍照（只有 iPhone / iPad 有）。
    case camera
    /// 选择文件（“文件”App）。
    case files

    public func title(_ language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch self {
        case .photoLibrary: return zh ? "照片或视频" : "Photos or Videos"
        case .camera: return zh ? "拍照" : "Take Photo"
        case .files: return zh ? "选择文件" : "Choose File"
        }
    }

    public var systemImage: String {
        switch self {
        case .photoLibrary: "photo.on.rectangle"
        case .camera: "camera"
        case .files: "folder"
        }
    }

    /// 现在能不能真的发出去：上传要服务端（12.22），都还不能。界面点了弹“即将推出”。
    public var isAvailable: Bool { false }

    /// 菜单里的几项（从上到下，和参考 08 一样）；没有相机的设备（Mac）不放“拍照”。
    public static func menu(hasCamera: Bool) -> [Self] {
        allCases.filter { hasCamera || $0 != .camera }
    }
}

extension ConversationModel {
    /// 输入框上放不放“+”：Botin 还在、不是“只看本次过程”。
    public var canAttach: Bool { focusRunID == nil && !isMissing }
}

extension ConversationText {
    /// “+”的读屏标签。
    public static func attach(_ language: DisplayLanguage) -> String {
        language == .chinese ? "添加照片或文件" : "Add Photos or Files"
    }

    /// 还没做好的功能点了以后的系统提示标题。
    public static func comingSoon(_ language: DisplayLanguage) -> String {
        language == .chinese ? "即将推出" : "Coming Soon"
    }

    /// 附件“即将推出”的说明。
    public static func attachmentComingSoon(_ source: ComposerAttachmentSource, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        let what: String
        switch source {
        case .photoLibrary: what = zh ? "发照片和视频" : "Sending photos and videos"
        case .camera: what = zh ? "拍照发给 Botin" : "Taking a photo for your Botin"
        case .files: what = zh ? "发文件" : "Sending files"
        }
        return zh
            ? "\(what)还在做，等服务端能收附件以后就能用。现在可以先把内容贴进输入框。"
            : "\(what) is on the way and will work once the server accepts attachments. For now, paste the content into the message."
    }

    /// 系统提示的确认按钮。
    public static func ok(_ language: DisplayLanguage) -> String {
        language == .chinese ? "好" : "OK"
    }
}
