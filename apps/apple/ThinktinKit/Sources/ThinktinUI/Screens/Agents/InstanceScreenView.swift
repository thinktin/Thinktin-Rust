import SwiftUI
import ThinktinKit

/// 观看与接管（`.instanceScreen(id)`，规范 4.6.2，参考 27、29、30、31、89）：Botin 云端桌面的画面，全屏黑底，从工作区页的
/// “观看与接管”压进来。画面接口还没有（docs/browser.md 只有设计），这一页是演示（`InstanceScreenModel`）：
///
/// - 导航栏中间是小头像 + 名字（参考 27），右上玻璃“?”弹使用说明（参考 28，`InstanceScreenHelpSheet`）；控制时“?”旁边再加
///   一个分开的“…”（参考 31）：“触控板模式”开关、“交还给 Botin”。
/// - 中间：连接中是居中转圈“正在连接…”（参考 27）；连上后是按屏宽铺满、上下留黑边的画面（参考 29），现在是写着“即将推出”的
///   占位画面（`InstanceScreenDemoData.aspectRatio`），触控板模式时中间多一个光标。
/// - 底部（iOS 的底部工具栏，iOS 26 系统画成玻璃）：只看时右边胶囊“接管控制”（参考 27、29，连接中灰着）；控制时左边剪贴板菜单
///   （从本机粘贴、复制到本机，参考 89）、右边键盘（参考 30）。剪贴板、键盘要后端，点了弹“即将推出”；接管、交还、触控板模式
///   只在本机切换版式。macOS 没有底部工具栏，这几个按钮放在右上。
/// - 黑底上按深色画：只改这一页的 `colorScheme` 环境和 iOS 导航栏、底部工具栏的配色，不改整个 App 的外观。离线时不能接管。
struct InstanceScreenView: View {
    let instanceID: InstanceID
    /// “正在连接…”停多久（测试、预览传 `.zero` 直接看画面）。
    var connectDelay: Duration = InstanceScreenDemoData.connectDelay

    var body: some View {
        InstanceScreenContent(
            model: InstanceScreenModel(instanceID: instanceID, connectDelay: connectDelay))
    }
}

/// 页面本身（测试、预览可以传一个已经走到某一步的 `InstanceScreenModel`）。
struct InstanceScreenContent: View {
    @State private var model: InstanceScreenModel
    @State private var isShowingHelp = false

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    init(model: InstanceScreenModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let model = self.model
        let language = self.language
        let instance = app.instances.first { $0.id == model.instanceID }
        let title = instance?.name ?? AppRoute.instanceScreen(model.instanceID).title(language)
        ZStack {
            Color.black.ignoresSafeArea()
            screen
        }
        .inlineNavigationTitle(title) {
            if let instance {
                InstanceScreenTitle(name: instance.name, appearance: app.appearances.resolved(for: instance.id))
            } else {
                InlineTitleText(title: title)
            }
        }
        .toolbar { toolbarItems }
        .task { await model.connect() }
        .sheet(isPresented: $isShowingHelp) {
            InstanceScreenHelpSheet()
                .environment(\.displayLanguage, language)
                .tint(Theme.accent)
        }
        .alert(
            InstanceScreenText.comingSoon(language),
            isPresented: Binding(get: { model.comingSoon != nil }, set: { if !$0 { model.comingSoon = nil } }),
            presenting: model.comingSoon
        ) { _ in
            Button(InstanceScreenText.ok(language)) { model.comingSoon = nil }
        } message: { action in
            Text(action.comingSoonMessage(language))
        }
        #if os(iOS)
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
        #endif
        .environment(\.colorScheme, .dark)
    }

    /// 中间：连接中转圈，连上后是画面（现在是占位的）。
    @ViewBuilder
    private var screen: some View {
        let model = self.model
        switch model.phase {
        case .connecting:
            VStack(spacing: Metrics.Spacing.s) {
                ProgressView()
                Text(InstanceScreenText.connecting(language))
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
            }
            .accessibilityElement(children: .combine)
        case .viewing, .controlling:
            InstanceScreenPlaceholder(showsPointer: model.phase == .controlling && model.isTrackpadMode)
                .accessibilityValue(Text(InstanceScreenText.phase(model.phase, language: language)))
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: ToolbarSlot.trailing) {
            helpButton
        }
        if model.phase == .controlling {
            GlassToolbarSpacer(.fixed, placement: ToolbarSlot.trailing)
            ToolbarItem(placement: ToolbarSlot.trailing) {
                moreMenu
            }
        }
        #if os(iOS)
            if model.phase == .controlling {
                ToolbarItem(placement: .bottomBar) {
                    clipboardMenu
                }
                GlassToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    keyboardButton
                }
            } else {
                GlassToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    takeControlButton
                }
            }
        #else
            if model.phase == .controlling {
                ToolbarItem(placement: .primaryAction) {
                    clipboardMenu
                }
                ToolbarItem(placement: .primaryAction) {
                    keyboardButton
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    takeControlButton
                }
            }
        #endif
    }

    /// 右上“?”：使用说明（参考 28）。
    private var helpButton: some View {
        Button {
            isShowingHelp = true
        } label: {
            Label(InstanceScreenText.helpTitle(language), systemImage: "questionmark")
                .labelStyle(.iconOnly)
        }
    }

    /// 控制时右上的“…”（参考 31）：触控板模式开关；交还给 Botin。
    private var moreMenu: some View {
        let model = self.model
        return Menu {
            Toggle(isOn: Binding(get: { model.isTrackpadMode }, set: { model.isTrackpadMode = $0 })) {
                Label(InstanceScreenText.trackpadMode(language), systemImage: "cursorarrow")
            }
            Section {
                Button {
                    model.handBack()
                } label: {
                    Label(InstanceScreenText.handBack(language), systemImage: "arrow.uturn.backward")
                }
            }
        } label: {
            Label(InstanceScreenText.more(language), systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
    }

    /// 只看时右下的“接管控制”（参考 27、29）：连接中、离线时灰着。
    private var takeControlButton: some View {
        let model = self.model
        return Button(InstanceScreenText.takeControl(language)) {
            model.takeControl()
        }
        .disabled(model.phase != .viewing || app.isOffline)
    }

    /// 控制时左下的剪贴板（参考 89）：从本机粘贴、复制到本机。
    private var clipboardMenu: some View {
        let model = self.model
        return Menu {
            ForEach([InstanceScreenAction.pasteFromDevice, .copyToDevice]) { action in
                Button {
                    model.perform(action)
                } label: {
                    Label(action.title(language), systemImage: action.systemImage)
                }
            }
        } label: {
            Label(InstanceScreenText.clipboard(language), systemImage: "clipboard")
                .labelStyle(.iconOnly)
        }
    }

    /// 控制时右下的键盘（参考 30）。
    private var keyboardButton: some View {
        let model = self.model
        return Button {
            model.perform(.keyboard)
        } label: {
            Label(InstanceScreenAction.keyboard.title(language), systemImage: InstanceScreenAction.keyboard.systemImage)
                .labelStyle(.iconOnly)
        }
    }
}

/// 导航栏中间（参考 27）：24pt 头像 + 名字。不能点（对话页的标题胶囊才进资料页），读屏当标题念。
private struct InstanceScreenTitle: View {
    let name: String
    let appearance: InstanceAppearance

    var body: some View {
        HStack(spacing: Metrics.Spacing.xs) {
            InstanceAvatar(name, appearance: appearance, size: Metrics.Avatar.title)
                .accessibilityHidden(true)
            Text(verbatim: name)
                .typography(.headline)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 占位画面（参考 29 的画面位置）：按屏宽铺满、16:10，深灰渐变上写“画面即将推出”和一句说明；触控板模式时中间一个光标。
struct InstanceScreenPlaceholder: View {
    let showsPointer: Bool

    @Environment(\.displayLanguage) private var language

    var body: some View {
        LinearGradient(
            stops: [
                Gradient.Stop(color: Color.white.opacity(0.08), location: 0),
                Gradient.Stop(color: Color.white.opacity(0.22), location: 1),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .aspectRatio(InstanceScreenDemoData.aspectRatio, contentMode: .fit)
        .overlay {
            VStack(spacing: Metrics.Spacing.xs) {
                Image(systemName: "display")
                    .font(.title2)
                    .accessibilityHidden(true)
                Text(InstanceScreenText.placeholderTitle(language))
                    .typography(.headline)
                Text(InstanceScreenText.placeholderDetail(language))
                    .typography(.footnote)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Theme.inkSecondary)
            .minimumScaleFactor(0.6)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(Metrics.Spacing.m)
        }
        .overlay {
            if showsPointer {
                Image(systemName: "cursorarrow")
                    .font(.title2)
                    .foregroundStyle(Color.white)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// 使用说明（右上“?”，参考 28）：large sheet、左上 ×，“手势”“输入与剪贴板”两组，最下面一句“即将推出”。
struct InstanceScreenHelpSheet: View {
    @Environment(\.displayLanguage) private var language

    var body: some View {
        GroupedHelpSheet(
            title: InstanceScreenText.helpTitle(language), sections: InstanceScreenHelp.sections(language),
            footer: InstanceScreenHelp.footer(language))
    }
}

#Preview("观看与接管 · 只看") {
    NavigationStack {
        InstanceScreenView(instanceID: DemoData.writerID, connectDelay: .zero)
    }
    .previewShell()
}

#Preview("观看与接管 · 正在连接（英文）") {
    NavigationStack {
        InstanceScreenView(instanceID: DemoData.reviewerID, connectDelay: .seconds(3600))
    }
    .previewShell(.english, scheme: .dark)
}

#Preview("使用说明") {
    InstanceScreenHelpSheet()
        .previewShell(scheme: .dark)
}
