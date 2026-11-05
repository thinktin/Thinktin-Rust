import Foundation
import Observation

// 观看与接管（规范 4.6.2、4.6.3，参考 27、28、29、30、31、89）：Botin 云端桌面的实时画面，只看，需要时接管控制（剪贴板、键盘、
// 触控板模式）。后端还没有（docs/browser.md 的只读票据和控制票据、限帧画面通道、控制租约都只是设计，剪贴板和键盘还没写，
// `ClientProtocol` 没有画面接口），用户要先照参考把页面排出来（2026-11-05），所以这里是界面的状态机和演示：打开先“正在连接…”，
// 一会儿换成占位画面（`InstanceScreenDemoData`，写着“即将推出”）；“接管控制”在本机切到控制的版式（底部剪贴板、键盘，右上“…”），
// 剪贴板、键盘要后端，点了弹“即将推出”；“交还给 Botin”回到只看。

/// 画面页的阶段。
public enum InstanceScreenPhase: Hashable, Sendable {
    /// 正在连接（参考 27：居中转圈“正在连接…”）。
    case connecting
    /// 只看（参考 29）：右下玻璃胶囊“接管控制”。
    case viewing
    /// 控制中（参考 30）：底部左边剪贴板、右边键盘，右上“?”旁边多一个“…”。
    case controlling
}

/// 控制时要服务端的操作（现在都弹“即将推出”）。
public enum InstanceScreenAction: String, CaseIterable, Hashable, Sendable, Identifiable {
    /// 把本机剪贴板的内容粘贴到画面里（参考 89 的第一项）。
    case pasteFromDevice
    /// 把画面里复制的内容放进本机剪贴板（参考 89 的第二项）。
    case copyToDevice
    /// 调出键盘往画面里打字（参考 30 右下的键盘按钮）。
    case keyboard

    public var id: String { rawValue }

    public func title(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .pasteFromDevice: return zh ? "从本机粘贴" : "Paste from this device"
        case .copyToDevice: return zh ? "复制到本机" : "Copy to this device"
        case .keyboard: return zh ? "键盘" : "Keyboard"
        }
    }

    /// SF Symbols 的图标名。
    public var systemImage: String {
        switch self {
        case .pasteFromDevice: "doc.on.clipboard"
        case .copyToDevice: "doc.on.doc"
        case .keyboard: "keyboard"
        }
    }

    /// “即将推出”的说明。
    public func comingSoonMessage(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .pasteFromDevice, .copyToDevice:
            return zh
                ? "在本机和 Botin 的云端桌面之间复制、粘贴还没有接上。"
                : "Copying and pasting between this device and the Botin's cloud desktop isn't available yet."
        case .keyboard:
            return zh
                ? "往 Botin 的云端桌面里打字还没有接上。"
                : "Typing into the Botin's cloud desktop isn't available yet."
        }
    }
}

/// 演示用的值（没有画面接口）。
public enum InstanceScreenDemoData {
    /// 占位画面的宽高比：云端桌面按 16:10 画（参考 29 的画面差不多这个比例），按屏宽铺满、上下留黑边。
    public static let aspectRatio: Double = 16.0 / 10.0
    /// “正在连接…”停多久再换成占位画面（参考 27 的样子要能看到）。
    public static let connectDelay: Duration = .milliseconds(800)
}

/// 观看与接管页的状态（演示）。
@Observable @MainActor
public final class InstanceScreenModel {
    public let instanceID: InstanceID
    public private(set) var phase: InstanceScreenPhase = .connecting
    /// 触控板模式（参考 31 的“…”菜单）：手指在画面上拖动移动光标、点按单击，不是直接点在手指下面。
    public var isTrackpadMode = false
    /// 正在弹“即将推出”的操作。
    public var comingSoon: InstanceScreenAction?

    @ObservationIgnored private let connectDelay: Duration

    /// - Parameter connectDelay: “正在连接…”停多久（测试传 `.zero`）。
    public init(instanceID: InstanceID, connectDelay: Duration = InstanceScreenDemoData.connectDelay) {
        self.instanceID = instanceID
        self.connectDelay = connectDelay
    }

    /// 连接（页面出现时调）：演示里等一会儿就换成占位画面。页面没等到就关了（任务取消）时停在连接中。
    public func connect() async {
        guard phase == .connecting else { return }
        if connectDelay > .zero {
            do {
                try await Task.sleep(for: connectDelay)
            } catch {
                return
            }
        }
        guard phase == .connecting else { return }
        phase = .viewing
    }

    /// “接管控制”（只看时才能点）。
    public func takeControl() {
        guard phase == .viewing else { return }
        phase = .controlling
    }

    /// “交还给 Botin”：回到只看，触控板模式关掉（下次接管从直接点按开始）。
    public func handBack() {
        guard phase == .controlling else { return }
        phase = .viewing
        isTrackpadMode = false
    }

    /// 控制时的剪贴板、键盘：现在都弹“即将推出”。只看时不响应。
    public func perform(_ action: InstanceScreenAction) {
        guard phase == .controlling else { return }
        comingSoon = action
    }
}

/// 画面页的字。
public enum InstanceScreenText {
    /// 工作区页那一行、路由的标题。
    public static func title(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "观看与接管" : "Watch and take over"
    }

    /// 工作区页那一行下面的灰字。
    public static func entryDetail(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "看 Botin 在云端桌面上做什么，需要时接管控制。"
            : "See what the Botin is doing on its cloud desktop, and take control when needed."
    }

    public static func connecting(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "正在连接…" : "Connecting…"
    }

    public static func takeControl(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "接管控制" : "Take control"
    }

    public static func handBack(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "交还给 Botin" : "Hand back to Botin"
    }

    public static func trackpadMode(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "触控板模式" : "Trackpad mode"
    }

    /// 底部左边的剪贴板菜单（读屏）。
    public static func clipboard(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "剪贴板" : "Clipboard"
    }

    /// 右上“…”（读屏）。
    public static func more(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "更多" : "More"
    }

    /// 右上“?”和使用说明的标题（参考 28）。
    public static func helpTitle(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "使用说明" : "How to use"
    }

    /// 占位画面上的两行。
    public static func placeholderTitle(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "画面即将推出" : "Live screen coming soon"
    }

    public static func placeholderDetail(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "接上以后，Botin 的云端桌面会实时显示在这里。"
            : "Once connected, the Botin's cloud desktop shows here live."
    }

    /// 读屏念的现在在哪一步。
    public static func phase(_ phase: InstanceScreenPhase, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch phase {
        case .connecting: return connecting(language)
        case .viewing: return zh ? "只看" : "Watching"
        case .controlling: return zh ? "你在控制" : "You're in control"
        }
    }

    public static func comingSoon(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "即将推出" : "Coming soon"
    }

    public static func ok(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "好" : "OK"
    }
}

/// 使用说明（右上“?”，参考 28 的版式：两组，每行图标 + 标题 + 多行灰字）。文案是自己写的。
public enum InstanceScreenHelp {
    public static func sections(_ language: DisplayLanguage = .current) -> [WorkspaceHelpSection] {
        let zh = language == .chinese
        let gestures = [
            WorkspaceHelpItem(
                systemImage: "eye", title: InstanceScreenText.takeControl(language),
                detail: zh
                    ? "打开时只看。点右下角的“接管控制”之后才能点按和输入；Botin 请你帮忙时，一进来就由你控制。"
                    : "You start by watching. Tap Take control at the bottom right to tap and type. When the Botin "
                        + "asks for help, you're in control from the start."),
            WorkspaceHelpItem(
                systemImage: "arrow.up.and.down", title: zh ? "滚动" : "Scroll",
                detail: zh ? "两根手指上下拖。" : "Drag with two fingers."),
            WorkspaceHelpItem(
                systemImage: "hand.tap", title: zh ? "点按与拖动" : "Tap and drag",
                detail: zh
                    ? "点一下就是在那里单击，一根手指拖动。打开触控板模式后，拖动是移动光标。"
                    : "Tap to click where you tap; drag with one finger. In trackpad mode, dragging moves the pointer."),
            WorkspaceHelpItem(
                systemImage: "contextualmenu.and.cursorarrow", title: zh ? "右键" : "Right-click",
                detail: zh ? "两根手指点按，或者长按。" : "Tap with two fingers, or touch and hold."),
            WorkspaceHelpItem(
                systemImage: "plus.magnifyingglass", title: zh ? "放大" : "Zoom",
                detail: zh
                    ? "两根手指捏合缩放；放大以后，两根手指拖动是平移画面。"
                    : "Pinch to zoom. When zoomed in, dragging with two fingers pans the screen."),
        ]
        let input = [
            WorkspaceHelpItem(
                systemImage: "keyboard", title: zh ? "输入" : "Type",
                detail: zh ? "点右下角的键盘按钮。" : "Tap the keyboard button at the bottom right."),
            WorkspaceHelpItem(
                systemImage: "doc.on.clipboard", title: zh ? "复制与粘贴" : "Copy and paste",
                detail: zh
                    ? "点左下角的剪贴板按钮，选“\(InstanceScreenAction.copyToDevice.title(language))”或"
                        + "“\(InstanceScreenAction.pasteFromDevice.title(language))”。"
                    : "Tap the clipboard button at the bottom left, then choose "
                        + "\(InstanceScreenAction.copyToDevice.title(language)) or "
                        + "\(InstanceScreenAction.pasteFromDevice.title(language))."),
        ]
        return [
            WorkspaceHelpSection(title: zh ? "手势" : "Gestures", items: gestures),
            WorkspaceHelpSection(title: zh ? "输入与剪贴板" : "Typing and clipboard", items: input),
        ]
    }

    /// 说明最下面的一句：画面和控制还没有接上。
    public static func footer(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "画面和控制即将推出，这里先说明以后怎么用。"
            : "The live screen and controls are coming soon. This explains how they'll work."
    }
}
