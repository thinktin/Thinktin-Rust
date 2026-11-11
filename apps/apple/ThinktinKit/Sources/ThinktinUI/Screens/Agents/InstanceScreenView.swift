import SwiftUI
import ThinktinKit

/// 观看与接管（`.instanceScreen(id)`，规范 4.6.2，参考 27、29、30、31、89）：Botin 云端桌面的画面，全屏黑底，从 Botin 资料的
/// “工作区”行压进来（参考 09 的“电脑”行进 27）。画面接口还没有（docs/browser.md 只有设计），这一页是演示（`InstanceScreenModel`）：
///
/// - 导航栏中间是小头像 + 名字（参考 27），右上玻璃“?”弹使用说明（参考 28，`InstanceScreenHelpSheet`）；控制时“?”旁边再加
///   一个分开的“…”（参考 31）：“触控板模式”开关、“交还给 Botin”。
/// - 中间：连接中是居中转圈“正在连接…”（参考 27）；连上后是按屏宽铺满、上下留黑边的画面（参考 29），现在是写着“即将推出”的
///   占位画面（`InstanceScreenDemoData.aspectRatio`），触控板模式时中间多一个光标。
/// - 底部（iOS 的底部工具栏，iOS 26 系统画成玻璃）：只看时右边胶囊“接管控制”（参考 27、29，连接中灰着）；控制时左边剪贴板菜单
///   （从本机粘贴、复制到本机，参考 89）、右边键盘（参考 30）。剪贴板、键盘要后端，点了弹“即将推出”；接管、交还、触控板模式
///   只在本机切换版式。macOS 没有底部工具栏，这几个按钮放在右上。
/// - 黑底上按深色画：这一页的 `colorScheme` 环境和 iOS 导航栏、底部工具栏的配色都是深色。导航栏的底画成黑色（和页面一样，
///   看不出来）：iOS 17 / 18 上底藏着时 `toolbarColorScheme` 不管用，浅色外观下状态栏是黑字，在黑底上看不见（2026-11-05
///   截图）；iOS 26 的导航栏没有底，这样也换不了状态栏，所以 iOS 上这一页在最上面时再要一个深色的 `preferredColorScheme`
///   （要根视图配合，见 `body` 里的说明）。“?”“…”和“接管控制”是白字（参考 27、29），不用强调色。离线时不能接管。
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
            // 画面按整块屏幕的高居中（参考 29：画面的中线在屏幕正中），不按导航栏和底部工具栏之间的安全区（那样低 15pt）；
            // 左右照旧留安全区（横屏时不伸到刘海下面）。
            screen
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .vertical)
        }
        .inlineNavigationTitle(title) {
            if let instance {
                InstanceScreenTitle(
                    name: instance.name, appearance: app.appearances.resolved(for: instance.id),
                    mood: app.faceMood(for: instance.id))
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
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
            // 状态栏要白字（参考 27、29）：iOS 26 的导航栏没有底，上面几行换不了状态栏的颜色，浅色外观下时间、信号是黑字，
            // 在黑底上看不见（2026-11-11 截图）。这一页在最上面时让它所在的那一层（窗口或 sheet）按深色画，退出去就还原；
            // 页面本来就是整屏黑底。App 的根视图自己也设 `preferredColorScheme`（设置里选的外观，`SettingsPreferencesScope`），
            // 外层的会盖住这里的，所以根视图要先读页面要的（`PreferredColorSchemeKey`）再设，不然这一行在主导航栈里不起作用。
            .preferredColorScheme(.dark)
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
        .tint(Color.white)
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
        .tint(Color.white)
    }

    /// 只看时右下的“接管控制”（参考 27、29）：白字、`.footnote` 中等粗细（参考约 13.5pt 的字，胶囊 86 × 39pt；底部工具栏
    /// 里的胶囊多高由系统定，iOS 26 约 47pt），连接中、离线时灰着。
    private var takeControlButton: some View {
        let model = self.model
        return Button {
            model.takeControl()
        } label: {
            Text(InstanceScreenText.takeControl(language))
                .font(Typography.footnote.font.weight(.medium))
        }
        .tint(Color.white)
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
        .tint(Color.white)
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
        .tint(Color.white)
    }
}

/// 导航栏中间（参考 27）：24pt 头像 + 名字。不能点（对话页的标题胶囊才进资料页），读屏当标题念。
private struct InstanceScreenTitle: View {
    let name: String
    let appearance: InstanceAppearance
    /// 头像的脸此刻的状态（有任务在跑时是活的）。
    let mood: BotinFaceMood

    var body: some View {
        HStack(spacing: Metrics.Spacing.xs) {
            InstanceAvatar(name, appearance: appearance, size: Metrics.Avatar.title, mood: mood)
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
