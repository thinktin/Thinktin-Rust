import SwiftUI
import ThinktinKit

/// 保险箱（`.vault`，WBS 12.13）。改版照参考 57、58（规范 4.9.5）：标题“密码保险箱”，右上玻璃“+”弹系统菜单（参考 58：
/// 登录信息、卡、联系信息；只有登录信息能存，卡和联系信息的表单照参考做好了、保存弹“即将推出”，规范 4.9.7）；第一行是筛选胶囊
/// （全部 / 登录信息 / 支付 / 联系信息 / 等你填写 / 处理过的，带数；参考 57 的画法：没选中的是灰字、选中的垫一块卡片色，
/// `FilterChipBar(style: .tabs)`），紧贴导航栏（`compactGroupedList`）；一条都没有时一行灰字
/// “保险箱里还是空的。”+ 脚注（Botin 看得到什么、看不到什么）；有的时候 insetGrouped 的几组：等你填写的请求、条目（名字、
/// 用途和能用的 Botin，左滑删除）、处理过的请求。离线时显示已经拉到的，写操作禁用。
struct VaultScreen: View {
    @Environment(\.client) private var client

    var body: some View {
        VaultContent(model: VaultModel(client: client))
    }
}

private struct VaultContent: View {
    @State private var model: VaultModel
    @State private var creating: VaultItemKind?
    @State private var pendingDeletion: VaultItem?

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(model: VaultModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let zh = language == .chinese
        @Bindable var bindable = self.model
        List {
            Section {
                FilterChipBar(chipOptions, selection: $bindable.filter, horizontalInset: 0, style: .tabs)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(Text(zh ? "筛选" : "Filter"))
            }
            .clearListRow()
            if let error = visibleError(model.error) {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                .clearListRow()
            }
            if let error = model.actionError {
                Section {
                    ErrorBanner(error, onDismiss: { model.clearActionError() })
                }
                .clearListRow()
            }
            if model.hasLoaded {
                if model.isEmptyForFilter {
                    Section {
                        Text(VaultText.empty(model.filter, language: language))
                            .foregroundStyle(Theme.inkSecondary)
                    } footer: {
                        Text(
                            model.filter == .cards || model.filter == .contacts
                                ? VaultExtraText.kindsFooter(language) : VaultText.footer(language))
                    }
                    .themedRow()
                } else {
                    sections
                }
            }
        }
        .insetGroupedList()
        // 参考 57：胶囊离导航栏约 76pt（中心到中心），系统默认的顶边距多出十几 pt。
        .compactGroupedList()
        .themedGroupedBackground()
        .overlay {
            if !model.hasLoaded && model.error == nil { ProgressView() }
        }
        .inlineNavigationTitle(AppRoute.vault.title(language))
        .toolbar {
            ToolbarItem(placement: ToolbarSlot.trailing) {
                Menu {
                    ForEach(VaultItemKind.allCases) { kind in
                        Button {
                            creating = kind
                        } label: {
                            Label(kind.title(language), systemImage: kind.systemImage)
                        }
                        // 只有登录信息真的存进保险箱：离线、没拉到、满了时不能新建；卡和联系信息是本地的表单。
                        .disabled(kind.isSupported && (app.isOffline || !model.hasLoaded || model.isFull))
                    }
                } label: {
                    Label(VaultExtraText.addMenu(language), systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: router.visibleRoute) {
            // 从条目、请求页回来（主栈里或设置的 sheet 里）：可能改了、删了、填了。
            if router.visibleRoute == .vault && model.hasLoaded { Task { await model.load() } }
        }
        .onSubpageRequest(when: model.hasLoaded, { $0.newVaultItemKind }) { creating = $0 }
        .navigationDestination(item: $creating) { kind in
            switch kind {
            case .login:
                VaultItemEditorView(itemID: nil) { item in
                    creating = nil
                    if let item { model.upsert(item) }
                }
            case .card: VaultCardFormView()
            case .contact: VaultContactFormView()
            }
        }
        .confirmationDialog(
            zh ? "删除“\(pendingDeletion?.name ?? "")”？" : "Delete “\(pendingDeletion?.name ?? "")”?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible, presenting: pendingDeletion
        ) { item in
            Button(zh ? "删除" : "Delete", role: .destructive) {
                Task { await model.delete(item) }
            }
            Button(zh ? "取消" : "Cancel", role: .cancel) {}
        } message: { item in
            Text(VaultText.deleteMessage(item.name, language: language))
        }
    }

    private var chipOptions: [FilterChipBar<VaultFilter?>.Option] {
        [.init(value: nil, title: VaultFilter.allTitle(language), count: model.count(of: nil))]
            + VaultFilter.allCases.map { .init(value: $0, title: $0.title(language), count: model.count(of: $0)) }
    }

    @ViewBuilder
    private var sections: some View {
        let zh = language == .chinese
        if model.shows(.pending) && !model.pendingRequests.isEmpty {
            Section {
                ForEach(model.pendingRequests) { request in
                    requestRow(request)
                }
            } header: {
                Text(zh ? "等你填写" : "Waiting for you").groupHeader()
            }
            .themedRow()
        }
        if model.shows(.items) && !model.items.isEmpty {
            Section {
                ForEach(model.items) { item in
                    NavigationLink(value: AppRoute.vaultItem(item.id)) {
                        SettingsRowLabel(title: item.name, subtitle: itemSubtitle(item))
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        // 只弹确认：不用 `.destructive`，不然系统先把行收走。
                        Button(zh ? "删除" : "Delete") {
                            pendingDeletion = item
                        }
                        .tint(StatusTone.failure.color)
                        .disabled(app.isOffline || model.deleting.contains(item.id))
                    }
                }
            } header: {
                Text(VaultText.count(model.items.count, language: language)).groupHeader()
            } footer: {
                Text(model.isFull ? VaultText.full(language) : VaultText.footer(language))
            }
            .themedRow()
        }
        if model.shows(.past) && !model.pastRequests.isEmpty {
            Section {
                ForEach(model.pastRequests) { request in
                    requestRow(request)
                }
            } header: {
                Text(zh ? "处理过的请求" : "Past requests").groupHeader()
            }
            .themedRow()
        }
    }

    private func itemSubtitle(_ item: VaultItem) -> String {
        [
            item.purpose.isEmpty ? nil : item.purpose,
            VaultText.instances(item, names: model.instanceNames, language: language),
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private func requestRow(_ request: VaultRequest) -> some View {
        let status = model.status(of: request)
        let detail = [
            model.instanceNames[request.instanceID],
            status == .pending
                ? VaultText.requestExpires(request.expiresAt, now: Date(), language: language)
                : ConversationText.vaultStatus(status, name: request.name, language: language),
        ].compactMap { $0 }.joined(separator: " · ")
        return NavigationLink(value: AppRoute.vaultRequest(request.id)) {
            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                Text(request.name)
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(status == .pending ? StatusTone.waiting.color : Theme.inkSecondary)
            }
        }
    }
}

/// 一个条目（`.vaultItem(id)`）：insetGrouped `List`：引用（点了复制）、用途、账号（只显示账号，密码永远看不到）、能用的 Botin；
/// 时间一组；最后红字“删除条目”。右上“编辑”压进修改表单（和新建同一个页面，规范 4.9.6）。
struct VaultItemScreen: View {
    let itemID: VaultItemID

    @Environment(\.client) private var client

    var body: some View {
        VaultItemContent(model: VaultItemModel(client: client, itemID: itemID))
    }
}

private struct VaultItemContent: View {
    @State private var model: VaultItemModel
    @State private var isEditing = false
    @State private var isConfirmingDeletion = false
    @State private var copies = 0

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(model: VaultItemModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        List {
            if let detail = model.detail, !model.isMissing {
                if let error = model.actionError {
                    Section {
                        ErrorBanner(error, onDismiss: { model.clearActionError() })
                    }
                    .clearListRow()
                }
                content(detail)
            } else if !model.isMissing, let error = visibleError(model.error) {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                .clearListRow()
            }
        }
        .insetGroupedList()
        .settingsGroupedList()
        .themedGroupedBackground()
        .overlay {
            if model.isMissing {
                ContentUnavailableView(
                    zh ? "找不到这个条目" : "Item not found", systemImage: "key.slash",
                    description: Text(zh ? "可能已经删掉了。" : "It may have been deleted."))
            } else if model.detail == nil && model.error == nil {
                ProgressView()
            }
        }
        .inlineNavigationTitle(model.detail?.item.name ?? AppRoute.vaultItem(model.itemID).title(language))
        .toolbar {
            ToolbarItem(placement: ToolbarSlot.trailing) {
                if model.detail != nil && !model.isMissing {
                    Button(zh ? "编辑" : "Edit") { isEditing = true }
                        .disabled(app.isOffline)
                }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: model.isDeleted) {
            if model.isDeleted { router.pop() }
        }
        .navigationDestination(isPresented: $isEditing) {
            VaultItemEditorView(itemID: model.itemID) { item in
                isEditing = false
                if item != nil { Task { await model.didSave() } }
            }
        }
        .appFeedback(.success, trigger: copies)
        .confirmationDialog(
            zh ? "删除“\(model.detail?.item.name ?? "")”？" : "Delete “\(model.detail?.item.name ?? "")”?",
            isPresented: $isConfirmingDeletion, titleVisibility: .visible
        ) {
            Button(zh ? "删除" : "Delete", role: .destructive) {
                Task { await model.delete() }
            }
            Button(zh ? "取消" : "Cancel", role: .cancel) {}
        } message: {
            Text(VaultText.deleteMessage(model.detail?.item.name ?? "", language: language))
        }
    }

    @ViewBuilder
    private func content(_ detail: VaultItemDetail) -> some View {
        let zh = language == .chinese
        let item = detail.item
        Section {
            Button {
                Pasteboard.copy(item.reference)
                copies += 1
            } label: {
                SettingsRowLabel(
                    title: item.reference,
                    subtitle: copies > 0
                        ? (zh ? "已复制" : "Copied")
                        : (zh ? "在消息里这样写，Botin 就能用它" : "Write this in a message to use it"))
            }
            .fontDesign(.monospaced)
            .accessibilityHint(Text(zh ? "复制引用" : "Copies the reference"))
            if !item.purpose.isEmpty {
                LabeledContent(zh ? "用途" : "Purpose", value: item.purpose)
            }
            LabeledContent(
                zh ? "账号" : "Username", value: detail.username.isEmpty ? (zh ? "没有账号" : "None") : detail.username)
            LabeledContent(zh ? "密码" : "Password", value: "••••••••")
            LabeledContent(
                zh ? "能用它的 Botin" : "Botins",
                value: VaultText.instances(item, names: model.instanceNames, language: language))
        } footer: {
            Text(zh ? "密码已加密保存，谁都看不到明文（包括你）。" : "The password is stored encrypted. Nobody can see it, including you.")
                .vaultGroupFooter()
        }
        .themedRow()
        Section {
            LabeledContent(zh ? "创建" : "Created", value: Formatting.relativeTime(item.createdAt, language: language))
            LabeledContent(zh ? "修改" : "Updated", value: Formatting.relativeTime(item.updatedAt, language: language))
            LabeledContent(
                zh ? "上次使用" : "Last used",
                value: item.lastUsedAt.map { Formatting.relativeTime($0, language: language) }
                    ?? (zh ? "还没用过" : "Never"))
        } header: {
            Text(zh ? "时间" : "Dates").vaultGroupHeader()
        }
        .themedRow()
        Section {
            Button(zh ? "删除条目" : "Delete item", role: .destructive) {
                isConfirmingDeletion = true
            }
            .foregroundStyle(Theme.danger)
            .disabled(app.isOffline || model.isDeleting)
        }
        .themedRow()
    }
}

/// 新建 / 修改条目（参考 59 的“新登录信息”，规范 4.9.6）：在保险箱的导航栈里压栈（不再 sheet 叠 sheet），右上“保存”
/// （`ConfirmButton`，名字、密码没填时灰，`hasRequiredFields`）。`Form` 里几组，字段是“标签在上、输入在下”，输入框是空的
/// （参考 59 没有占位字，只有网站有个例子）：名称（新建时，建好不能改）；账号 + 密码（密码行尾一个眼睛，只显示正在输入的）；
/// 提示（= 用途，多行；常驻的脚注只有这一处，[vault:名字] 的写法也并在这里，`VaultText.purposeFooter`）；能用它的 Botin
/// （`Toggle` 所有 Botin，关掉后勾选）。参考的“网站”（59、99）照做在名称下面（`VaultWebsitesSection`，能加、能移除），
/// 但要后端（6.16），填了不保存、脚注写着。保存成功调 `onFinish` 退回上一页。
struct VaultItemEditorView: View {
    let itemID: VaultItemID?
    /// 保存了带上条目（调用方退回上一页）。
    let onFinish: @MainActor (VaultItem?) -> Void

    @Environment(\.client) private var client

    var body: some View {
        VaultItemEditorContent(model: VaultItemEditorModel(client: client, itemID: itemID), onFinish: onFinish)
    }
}

private struct VaultItemEditorContent: View {
    @State private var model: VaultItemEditorModel
    @State private var showsPassword = false
    /// 网站（参考 99）：接口还没有这个字段，只在这一页里。
    @State private var websites = VaultFieldList()
    let onFinish: @MainActor (VaultItem?) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    init(model: VaultItemEditorModel, onFinish: @escaping @MainActor (VaultItem?) -> Void) {
        _model = State(initialValue: model)
        self.onFinish = onFinish
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        Form {
            if let error = model.saveError {
                Section {
                    ErrorBanner(error, onDismiss: { model.clearSaveError() })
                }
                .clearListRow()
            }
            if model.hasLoaded {
                fields
            } else if let error = model.error {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                .clearListRow()
            }
        }
        .formStyle(.grouped)
        .settingsGroupedList()
        .themedGroupedBackground()
        .overlay {
            if !model.hasLoaded && model.error == nil { ProgressView() }
        }
        .scrollDismissesKeyboard(.interactively)
        .settingsNavigationTitle(model.isEditing ? (zh ? "修改条目" : "Edit item") : VaultItemKind.login.newTitle(language))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                ConfirmButton(zh ? "保存" : "Save", isWorking: model.isSaving) {
                    Task {
                        if let item = await model.save() { onFinish(item) }
                    }
                }
                .disabled(
                    !model.hasLoaded || app.isOffline || !model.hasRequiredFields
                        || (model.isEditing && !model.hasChanges))
            }
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private var fields: some View {
        let zh = language == .chinese
        @Bindable var bindable = self.model
        let problems = model.visibleProblems
        if problems.contains(.full) {
            Section {
                Label(VaultText.full(language), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(StatusTone.waiting.color)
            }
            .themedRow()
        }
        Section {
            VaultLabeledField(title: zh ? "名称" : "Name") {
                if model.isEditing {
                    Text(verbatim: model.name)
                        .fontDesign(.monospaced)
                        .foregroundStyle(Theme.inkSecondary)
                } else {
                    TextField(
                        "", text: Binding(get: { model.name }, set: { model.setName($0) })
                    )
                    .fontDesign(.monospaced)
                    .modelsIdentifierInput()
                }
            }
        } footer: {
            if model.isEditing {
                Text(zh ? "名字建好后不能改。" : "The name can't be changed.").vaultGroupFooter()
            } else if let problem = problemText(problems, where: { if case .name = $0 { true } else { false } }) {
                Text(problem).foregroundStyle(Theme.danger).vaultGroupFooter()
            } else if let renamed = model.renamedTo {
                Text(VaultText.renamed(renamed, language: language)).vaultGroupFooter()
            }
        }
        .themedRow()
        VaultWebsitesSection(websites: $websites)
        Section {
            VaultLabeledField(title: zh ? "账号" : "Username") {
                TextField("", text: $bindable.username)
                    .modelsIdentifierInput()
                    .usernameContentType()
            }
            VaultLabeledField(title: zh ? "密码" : "Password") {
                HStack {
                    Group {
                        if showsPassword {
                            TextField("", text: $bindable.password)
                                .modelsIdentifierInput()
                        } else {
                            SecureField("", text: $bindable.password)
                        }
                    }
                    .passwordContentType()
                    Button {
                        showsPassword.toggle()
                    } label: {
                        Label(
                            showsPassword ? (zh ? "隐藏密码" : "Hide password") : (zh ? "显示密码" : "Show password"),
                            systemImage: showsPassword ? "eye.slash" : "eye"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.inkSecondary)
                }
            }
        } footer: {
            if let problem = problemText(problems, where: { if case .password = $0 { true } else { false } })
                ?? message(problems, .usernameTooLong)
            {
                Text(problem).foregroundStyle(Theme.danger).vaultGroupFooter()
            } else if model.isEditing {
                Text(VaultText.passwordKept(language)).vaultGroupFooter()
            }
        }
        .themedRow()
        Section {
            VaultLabeledField(title: zh ? "提示" : "Notes") {
                TextField("", text: $bindable.purpose, axis: .vertical)
                    .lineLimit(4...8)
            }
        } footer: {
            HStack(alignment: .firstTextBaseline) {
                if let problem = message(problems, .purposeTooLong) ?? message(problems, .controlCharacters) {
                    Text(problem).foregroundStyle(Theme.danger)
                } else {
                    Text(VaultText.purposeFooter(language))
                }
                Spacer(minLength: Metrics.Spacing.xs)
                Text(verbatim: "\(purposeCount)/\(VaultRules.maxPurpose)")
                    .monospacedDigit()
                    .foregroundStyle(purposeCount > VaultRules.maxPurpose ? Theme.danger : Theme.inkTertiary)
            }
            .vaultGroupFooter()
        }
        .themedRow()
        instancesSection(problems)
    }

    private var purposeCount: Int {
        model.purpose.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
    }

    private func message(_ problems: [VaultFormProblem], _ problem: VaultFormProblem) -> String? {
        problems.contains(problem) ? VaultText.formProblem(problem, language: language) : nil
    }

    private func problemText(_ problems: [VaultFormProblem], where match: (VaultFormProblem) -> Bool) -> String? {
        problems.first(where: match).map { VaultText.formProblem($0, language: language) }
    }

    @ViewBuilder
    private func instancesSection(_ problems: [VaultFormProblem]) -> some View {
        let zh = language == .chinese
        @Bindable var bindable = self.model
        Section {
            Toggle(zh ? "所有 Botin" : "All Botins", isOn: $bindable.allInstances)
            if !model.allInstances {
                ForEach(model.instances) { instance in
                    let isOn = model.selected.contains(instance.id)
                    Button {
                        model.toggle(instance.id)
                    } label: {
                        HStack {
                            Text(verbatim: instance.name)
                                .foregroundStyle(Theme.ink)
                            Spacer(minLength: 0)
                            if isOn {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Theme.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                }
            }
        } header: {
            Text(zh ? "能用它的 Botin" : "Botins that can use it").vaultGroupHeader()
        } footer: {
            if !model.allInstances,
                let problem = message(problems, .noInstances) ?? message(problems, .tooManyInstances)
            {
                Text(problem).foregroundStyle(Theme.danger)
            }
        }
        .themedRow()
    }
}

/// 表单里“标签在上、输入在下”的一格（参考 59）。
struct VaultLabeledField<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityHidden(true)
            content
                .accessibilityLabel(Text(title))
        }
        .padding(.vertical, Metrics.Spacing.xxs)
    }
}

/// 填写请求（`.vaultRequest(id)`）：Botin 要的账号密码，填好只进保险箱；已有同名条目的先提示会换掉它。处理过、过期了的显示结果。
/// 改版成 `Form`（规范 2.5、4.9.6 的字段写法）：请求一组（名字、哪个 Botin、它写的用途带 AI 标识、来自哪次运行），
/// 账号 + 密码一组（标签在上、输入框空着，密码行尾一个眼睛，和条目表单一样）；“存进保险箱”是右上的确认按钮（参考 59 的
/// “保存”，没填密码时灰），“拒绝”是单独一组的红字行（参考 64 的“删除规则”）。表单里不再放按钮（2026-11-06 截图：
/// 两个大按钮叠在一起，中间拖着一块玻璃的灰影）。
struct VaultRequestScreen: View {
    let requestID: VaultRequestID

    @Environment(\.client) private var client

    var body: some View {
        VaultRequestContent(model: VaultRequestModel(client: client, requestID: requestID))
    }
}

private struct VaultRequestContent: View {
    @State private var model: VaultRequestModel
    @State private var showsPassword = false

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    init(model: VaultRequestModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        Form {
            if let request = model.request, !model.isMissing {
                if let error = model.actionError {
                    Section {
                        ErrorBanner(error, onDismiss: { model.clearActionError() })
                    }
                    .clearListRow()
                }
                content(request)
            } else if !model.isMissing, let error = visibleError(model.error) {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                .clearListRow()
            }
        }
        .formStyle(.grouped)
        .settingsGroupedList()
        .themedGroupedBackground()
        .overlay {
            if model.isMissing {
                ContentUnavailableView(
                    zh ? "找不到这个请求" : "Request not found", systemImage: "key.slash",
                    description: Text(zh ? "可能已经过期清理掉了。" : "It may have expired and been cleaned up."))
            } else if model.request == nil && model.error == nil {
                ProgressView()
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .inlineNavigationTitle(AppRoute.vaultRequest(model.requestID).title(language))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if let request = model.request, !model.isMissing, (model.status ?? request.status) == .pending {
                    ConfirmButton(ConversationText.vaultFulfill(language), isWorking: model.isWorking) {
                        Task { _ = await model.fulfill() }
                    }
                    .disabled(model.password.isEmpty || app.isOffline)
                }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
    }

    @ViewBuilder
    private func content(_ request: VaultRequest) -> some View {
        let zh = language == .chinese
        @Bindable var bindable = self.model
        let status = model.status ?? request.status
        let problems = model.visibleProblems
        Section {
            SettingsRowLabel(
                title: ConversationText.vaultItemName(request.name, language: language),
                subtitle: model.instanceNames[request.instanceID].map { zh ? "Botin：\($0)" : "Botin: \($0)" })
            if !request.purpose.isEmpty {
                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                    Text(verbatim: request.purpose)
                        .foregroundStyle(Theme.ink)
                    AIGeneratedLabel()
                }
            }
            if let runID = request.runID {
                NavigationLink(value: AppRoute.run(runID)) {
                    Text(zh ? "来自这次运行" : "From this run")
                }
            }
        } footer: {
            if status == .pending {
                Text(VaultText.requestExpires(request.expiresAt, now: Date(), language: language))
                    .foregroundStyle(StatusTone.waiting.color)
                    .vaultGroupFooter()
            } else {
                Text(ConversationText.vaultStatus(status, name: request.name, language: language))
                    .foregroundStyle(status == .fulfilled ? StatusTone.success.color : Theme.inkSecondary)
                    .vaultGroupFooter()
            }
        }
        .themedRow()
        if status == .pending {
            if let existing = model.existingItem {
                Section {
                    Label(
                        VaultText.requestReplaces(existing.name, language: language),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .foregroundStyle(StatusTone.waiting.color)
                }
                .themedRow()
            }
            Section {
                if request.needsUsername {
                    VaultLabeledField(title: ConversationText.vaultField(.username, language: language)) {
                        TextField("", text: $bindable.username)
                            .modelsIdentifierInput()
                            .usernameContentType()
                    }
                }
                VaultLabeledField(title: ConversationText.vaultField(.password, language: language)) {
                    HStack {
                        Group {
                            if showsPassword {
                                TextField("", text: $bindable.password)
                                    .modelsIdentifierInput()
                            } else {
                                SecureField("", text: $bindable.password)
                            }
                        }
                        .passwordContentType()
                        Button {
                            showsPassword.toggle()
                        } label: {
                            Label(
                                showsPassword ? (zh ? "隐藏密码" : "Hide password") : (zh ? "显示密码" : "Show password"),
                                systemImage: showsPassword ? "eye.slash" : "eye"
                            )
                            .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.inkSecondary)
                    }
                }
            } footer: {
                if let problem = problems.compactMap({ problem -> String? in
                    if case .password = problem { return VaultText.formProblem(problem, language: language) }
                    if problem == .usernameTooLong { return VaultText.formProblem(problem, language: language) }
                    return nil
                }).first {
                    Text(problem).foregroundStyle(Theme.danger).vaultGroupFooter()
                } else {
                    Text(ConversationText.vaultRequestNote(language)).vaultGroupFooter()
                }
            }
            .themedRow()
            Section {
                Button(role: .destructive) {
                    Task { _ = await model.decline() }
                } label: {
                    Text(ConversationText.vaultDecline(language))
                }
                .foregroundStyle(Theme.danger)
                .disabled(model.isWorking || app.isOffline)
            }
            .themedRow()
        } else if status == .fulfilled, let itemID = request.itemID {
            Section {
                NavigationLink(value: AppRoute.vaultItem(itemID)) {
                    Text(zh ? "查看条目" : "View item")
                }
            }
            .themedRow()
        }
    }
}
