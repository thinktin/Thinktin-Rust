import SwiftUI
import ThinktinKit

/// 资料页、编辑页、头像页的头像大小：参考 09、12、18 量出来都是 80pt 左右（规范 2.4 写的 120 / 100 偏大）。
/// 最大跟到 xxxLarge 的动态字体，再大不跟（`InstanceAvatar` 跟着缩放，辅助字号下会比屏幕还宽）。
enum ProfileAvatarMetrics {
    static let size: CGFloat = 80
    static let maxDynamicType: DynamicTypeSize = .xxxLarge
}

/// 资料页头部、编辑页顶上的大头像上面留的空：这两行贴边（列表会切掉行外面的），有任务在跑时会跳、资料页上点一下也跳，
/// 头顶最多冒出方框上沿 `BotinFaceLife.Limits.lift` 倍边长（80pt 时 8pt），上面就留这么多。和 `InstanceAvatar` 一样按
/// `.body` 跟着动态字体缩放；加在头像的 `.dynamicTypeSize(...ProfileAvatarMetrics.maxDynamicType)` 里面，和头像一起封顶。
struct ProfileAvatarHeadroom: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var side = ProfileAvatarMetrics.size

    func body(content: Content) -> some View {
        content.padding(.top, side * BotinFaceLife.Limits.lift)
    }
}

/// 编辑 Botin（规范 4.4.3，参考 12）：资料页“编辑”压进来的页面（本地的 `navigationDestination`，不加路由），标题“编辑 Botin”，
/// 右上“完成”。
///
/// - 居中的头像，右下角一个玻璃小铅笔，点了进头像页（和“外观”组的“头像”行一样）；
/// - “名称”组一个输入框，平时没有脚注（参考 12），名字有问题、快到上限、离线不能改时才写（`AdoptionModel.nameNote`）；
///   离线时不能改名字（头像只存在这台设备上，照样能改）；
/// - “外观”组“头像 >”；
/// - “语音通话”组（参考 12、13–17、85–88）：语音、速度、语言三行系统的 `Picker(.menu)`（行尾是值和上下箭头，菜单里选中的
///   打勾，长列表系统菜单自己能滚）。ThinkTin 还没有语音通话（6.23），选项是演示数据（`BotinVoiceDemoData`），选了只记在
///   这台设备上（`BotinVoiceStore`），脚注说“即将推出”。
///
/// 点“完成”记下语音通话的选择、保存名字并返回（名字没变直接返回；改名失败时语音的选择已经记下了，它只在本机）；点返回放弃
/// 改动（规范 4.4.3）。
struct InstanceEditScreen: View {
    let model: InstanceDetailModel

    @State private var draft: String
    @State private var voice: BotinVoiceEditor
    @State private var isEditingAvatar = false
    @FocusState private var isNameFocused: Bool

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayLanguage) private var language

    init(model: InstanceDetailModel) {
        self.model = model
        _draft = State(initialValue: model.instance?.name ?? "")
        _voice = State(
            initialValue: BotinVoiceEditor(instanceID: model.instanceID, store: model.voices ?? BotinVoiceStore.shared))
    }

    var body: some View {
        let model = self.model
        let problem = InstanceNameRule.problem(draft)
        let name = model.instance?.name ?? draft
        Form {
            Section {
                Button {
                    isEditingAvatar = true
                } label: {
                    AvatarWithPencil(
                        name: name, appearance: app.appearances.resolved(for: model.instanceID),
                        mood: app.faceMood(for: model.instanceID))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text(InstanceProfileText.avatar(language)))
                .accessibilityHint(Text(language == .chinese ? "换形状和颜色" : "Change the shape and colour"))
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                TextField(InstanceProfileText.nameSection(language), text: $draft)
                    .focused($isNameFocused)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .autocorrectionDisabled()
                    .disabled(model.isRenaming || app.isOffline)
            } header: {
                Text(InstanceProfileText.nameSection(language))
                    .groupHeader()
            } footer: {
                nameFooter
            }
            .themedRow()
            if let error = model.renameError {
                Section {
                    ErrorBanner(error) { save() }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }
            Section {
                Button {
                    isEditingAvatar = true
                } label: {
                    HStack {
                        Text(InstanceProfileText.avatar(language))
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: Metrics.Spacing.s)
                        // 只有“头像 >”（参考 12）：大头像已经在页面最上面了。
                        Image(systemName: "chevron.right")
                            .font(Typography.footnote.font.weight(.semibold))
                            .foregroundStyle(Theme.inkTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text(InstanceProfileText.appearanceSection(language))
                    .groupHeader()
            }
            .themedRow()
            BotinVoiceSection(editor: voice)
        }
        .formStyle(.grouped)
        .compactGroupedList()
        .themedGroupedBackground()
        .inlineNavigationTitle(InstanceProfileText.editTitle(language))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                ConfirmButton(isWorking: model.isRenaming, action: save)
                    .disabled(!canSave(problem: problem))
            }
        }
        .navigationDestination(isPresented: $isEditingAvatar) {
            InstanceAvatarScreen(
                editor: InstanceAppearanceEditor(
                    instanceID: model.instanceID, name: name, store: app.appearances))
        }
        .onSubpageRequest(.botinAvatar) { isEditingAvatar = true }
        .onDisappear { model.clearRenameError() }
    }

    /// 名字下面的脚注：平时没有（参考 12）；离线说不能改，名字有问题（删空了、太长）或快到上限时说（和新建表单同一条规则）。
    @ViewBuilder
    private var nameFooter: some View {
        if app.isOffline {
            Text(language == .chinese ? "离线时不能改名字。" : "You can't rename while offline.")
        } else if let note = AdoptionModel.nameNote(for: draft, hidesUntouchedEmpty: false, language: language) {
            Text(verbatim: note.text)
                .foregroundStyle(note.isProblem ? StatusTone.failure.color : Theme.inkSecondary)
        }
    }

    /// 名字对、不在保存中；离线时名字没改也能点（只是返回）。
    private func canSave(problem: InstanceNameProblem?) -> Bool {
        guard problem == nil, !model.isRenaming else { return false }
        return !app.isOffline || InstanceNameRule.normalized(draft) == model.instance?.name
    }

    private func save() {
        guard canSave(problem: InstanceNameRule.problem(draft)) else { return }
        isNameFocused = false
        voice.save()
        let model = self.model
        let name = draft
        Task {
            if await model.rename(to: name) { dismiss() }
        }
    }
}

/// 编辑页的“语音通话”组（参考 12 的三行，13–17、85–88 是它们的菜单）：系统的 `Picker(.menu)`，菜单里选中的打勾；行尾的值和
/// 上下箭头是灰的（`menuPickerTint`，参考 12），不用强调色。
private struct BotinVoiceSection: View {
    let editor: BotinVoiceEditor

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let editor = self.editor
        let language = self.language
        Section {
            Picker(
                BotinVoiceText.voice(language),
                selection: Binding(get: { editor.voiceID }, set: { editor.voiceID = $0 })
            ) {
                Text(BotinVoiceText.notSet(language)).tag(String?.none)
                ForEach(BotinVoiceDemoData.voices) { voice in
                    Text(verbatim: voice.name).tag(String?.some(voice.id))
                }
            }
            .pickerStyle(.menu)
            .menuPickerTint()
            Picker(
                BotinVoiceText.speed(language), selection: Binding(get: { editor.speed }, set: { editor.speed = $0 })
            ) {
                ForEach(BotinVoiceSpeed.allCases, id: \.self) { speed in
                    Text(verbatim: speed.label)
                        .accessibilityLabel(Text(speed.accessibilityLabel(language)))
                        .tag(speed)
                }
            }
            .pickerStyle(.menu)
            .menuPickerTint()
            Picker(
                BotinVoiceText.language(language),
                selection: Binding(get: { editor.languageCode }, set: { editor.languageCode = $0 })
            ) {
                Text(BotinVoiceText.automatic(language)).tag(String?.none)
                ForEach(BotinVoiceDemoData.languages) { option in
                    Text(option.name(language)).tag(String?.some(option.code))
                }
            }
            .pickerStyle(.menu)
            .menuPickerTint()
        } header: {
            Text(BotinVoiceText.section(language))
                .groupHeader()
        } footer: {
            Text(BotinVoiceText.footer(language))
        }
        .themedRow()
    }
}

/// 编辑页顶上的头像：右下角一个玻璃小铅笔（参考 12）。这一行贴边（`listRowInsets(EdgeInsets())`），下面留 16pt，
/// 铅笔的玻璃阴影才不会被行的下边切掉；上面留跳起来冒出的那一截（`ProfileAvatarHeadroom`，默认字号 8pt）。有任务在跑时
/// 脸是活的（`mood`）。
private struct AvatarWithPencil: View {
    let name: String
    let appearance: InstanceAppearance
    let mood: BotinFaceMood

    var body: some View {
        InstanceAvatar(name, appearance: appearance, size: ProfileAvatarMetrics.size, mood: mood)
            .modifier(ProfileAvatarHeadroom())
            .dynamicTypeSize(...ProfileAvatarMetrics.maxDynamicType)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "pencil")
                    .font(Typography.footnote.font.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 30, height: 30)
                    .glassBackground(in: Circle())
                    .offset(x: Metrics.Spacing.xs, y: Metrics.Spacing.xxs)
            }
            .padding(.bottom, Metrics.Spacing.m)
            .accessibilityHidden(true)
    }
}

/// 改头像（规范 4.4.4，参考 18、19、20）：编辑页压进来，标题“头像”，右上“完成”记进这台设备（`InstanceAppearanceStore`）。
/// 顶上是系统的分段“形状 / 生成 / 上传”（`AvatarSourceTab`），下面 80pt 大预览（`AvatarPickerPreview`：活的脸，换形状时
/// 变形过去，挑了形状、颜色笑一下，点一下跳一下），再下面跟着分段换：
///
/// - 形状（参考 18）：和新建表单同一张卡片（形状网格 3 × 5、色板 2 × 6），卡片最下面分隔线和“重置为默认”，下面一句
///   “只保存在这台设备上”；
/// - 生成（参考 19）：多行描述 + 整宽的“生成”胶囊（写了描述才能点），下面一句说明；点了弹“即将推出”（要图片生成服务，6.9）；
/// - 上传（参考 20）：“从相册选择”“拍照”两行 + 脚注（25 MB、可以裁剪）；点了弹“即将推出”（要存储接口和 Botin 上的头像
///   字段，6.9 B；只存在本机的照片得改首页、搜索、对话标题里所有画头像的地方，这次不做）。
///
/// 点返回放弃改动。
struct InstanceAvatarScreen: View {
    @State private var editor: InstanceAppearanceEditor
    @State private var tab: AvatarSourceTab
    /// “生成”页的描述。
    @State private var prompt = ""
    /// 正在弹“即将推出”的分段（生成、上传）。
    @State private var comingSoon: AvatarSourceTab?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayLanguage) private var language

    /// - Parameter tab: 一打开在哪个分段（预览、测试用；App 里总是“形状”）。
    init(editor: InstanceAppearanceEditor, tab: AvatarSourceTab = .shape) {
        _editor = State(initialValue: editor)
        _tab = State(initialValue: tab)
    }

    var body: some View {
        let editor = self.editor
        let language = self.language
        List {
            Section {
                // 分段和大预览之间约 40pt（参考 18）。
                VStack(spacing: Metrics.Spacing.xxl + Metrics.Spacing.xs) {
                    Picker(selection: $tab) {
                        ForEach(AvatarSourceTab.allCases) { option in
                            Text(option.title(language)).tag(option)
                        }
                    } label: {
                        Text(InstanceProfileText.avatar(language))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    // 固定大小（不跟动态字体缩放），只是装饰，读屏不念（网格自己会念）。一直是活的；变形、渐变、反应都是
                    // `AvatarPickerPreview` 自己做（减弱动态效果时不做）。
                    AvatarPickerPreview(
                        name: editor.name, appearance: editor.appearance, size: ProfileAvatarMetrics.size)
                }
                .frame(maxWidth: .infinity)
                .clearListRow()
            }
            switch tab {
            case .shape: shapeSection
            case .generate: generateSections
            case .upload: uploadSection
            }
        }
        .insetGroupedList()
        .compactGroupedList()
        .themedGroupedBackground()
        .inlineNavigationTitle(InstanceProfileText.avatar(language))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                ConfirmButton {
                    editor.save()
                    dismiss()
                }
            }
        }
        .alert(
            AvatarSourceText.comingSoon(language),
            isPresented: Binding(get: { comingSoon != nil }, set: { if !$0 { comingSoon = nil } }),
            presenting: comingSoon
        ) { _ in
            Button(AvatarSourceText.ok(language)) { comingSoon = nil }
        } message: { tab in
            Text(AvatarSourceText.comingSoonMessage(tab, language: language))
        }
    }

    /// 形状（参考 18）：形状网格和色板的卡片，最下面“重置为默认”。
    private var shapeSection: some View {
        let editor = self.editor
        return Section {
            AvatarPicker(
                name: editor.name, shape: Binding(get: { editor.shape }, set: { editor.shape = $0 }),
                color: Binding(get: { editor.color }, set: { editor.color = $0 }),
                resolvedColor: editor.resolvedColor
            ) {
                // 从字的起点一直画到卡片的右边（参考 18），抵掉卡片右边的内边距。
                Divider()
                    .padding(.trailing, -Metrics.Spacing.m)
                Button(InstanceProfileText.resetAvatar(language)) { editor.reset() }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(editor.isDefault)
            }
            .clearListRow()
        } footer: {
            Text(InstanceProfileText.avatarFooter(language))
        }
    }

    /// 生成（参考 19）：多行描述、整宽的“生成”胶囊。
    @ViewBuilder
    private var generateSections: some View {
        let language = self.language
        Section {
            TextField(AvatarSourceText.generatePlaceholder(language), text: $prompt, axis: .vertical)
                .lineLimit(4...8)
        } footer: {
            if let problem = AvatarGenerationPrompt.problem(prompt, language: language) {
                Text(problem)
                    .foregroundStyle(StatusTone.failure.color)
            }
        }
        .themedRow()
        Section {
            Button {
                comingSoon = .generate
            } label: {
                Text(AvatarSourceText.generate(language))
                    .frame(maxWidth: .infinity)
            }
            .glassButtonStyle()
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(!AvatarGenerationPrompt.canSubmit(prompt))
            .clearListRow()
        } footer: {
            Text(AvatarSourceText.generateFooter(language))
        }
    }

    /// 上传（参考 20）：从相册选择、拍照两行和脚注。
    private var uploadSection: some View {
        let language = self.language
        return Section {
            ForEach(AvatarUploadSource.allCases) { source in
                Button {
                    comingSoon = .upload
                } label: {
                    HStack {
                        Label {
                            Text(source.title(language))
                                .foregroundStyle(Theme.ink)
                        } icon: {
                            Image(systemName: source.systemImage)
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        Spacer(minLength: Metrics.Spacing.s)
                        Image(systemName: "chevron.right")
                            .font(Typography.footnote.font.weight(.semibold))
                            .foregroundStyle(Theme.inkTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } footer: {
            Text(AvatarSourceText.uploadFooter(language))
        }
        .themedRow()
    }
}

#Preview("编辑 Botin · 浅色中文") {
    NavigationStack {
        InstanceEditScreen(
            model: InstanceDetailModel(
                client: MockClient(autoReply: false), instanceID: DemoData.writerID,
                instance: DemoData.state().instances[0]))
    }
    .previewShell()
}

#Preview("头像 · 深色英文") {
    NavigationStack {
        InstanceAvatarScreen(
            editor: InstanceAppearanceEditor(
                instanceID: DemoData.reviewerID, name: "Code reviewer", store: InstanceAppearanceStore(defaults: nil)))
    }
    .previewShell(.english, scheme: .dark)
}

#Preview("头像 · 生成") {
    NavigationStack {
        InstanceAvatarScreen(
            editor: InstanceAppearanceEditor(
                instanceID: DemoData.writerID, name: "写作助手", store: InstanceAppearanceStore(defaults: nil)),
            tab: .generate)
    }
    .previewShell(scheme: .dark)
}

#Preview("头像 · 上传") {
    NavigationStack {
        InstanceAvatarScreen(
            editor: InstanceAppearanceEditor(
                instanceID: DemoData.writerID, name: "写作助手", store: InstanceAppearanceStore(defaults: nil)),
            tab: .upload)
    }
    .previewShell()
}
