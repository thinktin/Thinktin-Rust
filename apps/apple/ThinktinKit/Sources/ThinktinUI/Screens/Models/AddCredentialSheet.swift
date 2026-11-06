import SwiftUI
import ThinktinKit

/// 添加模型 key（`.addCredential`，应用框架的 sheet，自带导航栈）：
///
/// 1. 选厂商（厂商表里的，或“自定义地址”），看它支持的协议、推荐模型和说明；
/// 2. 自定义地址填 https 的 Anthropic Messages / OpenAI Chat Completions / OpenAI Responses 地址（至少一个，本地先校验）；
/// 3. 填 key（打码输入）、备注、每日上限；
/// 4. 勾选第三方 AI 数据共享的同意（App Store 5.1.2(i)）才能保存；
/// 5. 服务端拒收（订阅类 key、套餐地址）时显示本地化的原因，认得出是哪个字段的显示在那个字段下面；加好后说明能用哪些协议、
///    等 key 的任务会接着跑。
///
/// 从某个实例的模型路由页弹出来时（sheet 底下的页面是 `.modelRoutes(id)`，`Router.routeBelowSheet`），提示这把 key
/// 能不能给那个实例的 agent 用；
/// 加好关掉 sheet，路由页会刷新 key 列表、把新 key 选进还没配的 main。
///
/// 改版（规范 2.5、2.6，参考 59 的字段写法）：`Form`，左上 `CloseButton`、右上 `ConfirmButton("保存")`；厂商一组（一行一个，
/// 选中的右边系统勾），厂商说明一组，接口地址、key 各一组（标签在上的输入框），数据去向一组（说明和系统 `Toggle`）；
/// 加好了是一页分组列表（居中的对勾头部、新 key 的一行、下一步的按钮）。
struct AddCredentialSheet: View {
    @Environment(\.client) private var client
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        let target: Instance? = {
            guard case .modelRoutes(let id) = router.routeBelowSheet else { return nil }
            return app.instances.first { $0.id == id }
        }()
        AddCredentialContent(client: client, targetInstance: target)
    }
}

private struct AddCredentialContent: View {
    @State private var model: AddCredentialModel
    /// 从哪个实例的路由页弹出来的（没有为 nil）。
    let targetInstance: Instance?

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol, targetInstance: Instance?) {
        self.targetInstance = targetInstance
        _model = State(initialValue: AddCredentialModel(client: client, targetAgentID: targetInstance?.agentID))
    }

    var body: some View {
        let zh = language == .chinese
        Group {
            if let created = model.created {
                AddCredentialDoneView(
                    model: model, credential: created, targetInstance: targetInstance,
                    onClose: { router.dismissSheet() })
            } else {
                Form { form }
                    .formStyle(.grouped)
                    .themedGroupedBackground()
                    .scrollDismissesKeyboard(.interactively)
            }
        }
        .inlineNavigationTitle(
            model.created == nil ? AppRoute.addCredential.title(language) : (zh ? "加好了" : "Key added")
        )
        .toolbar {
            if model.created == nil {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton { router.dismissSheet() }
                        .disabled(model.isSubmitting)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.created != nil {
                    ConfirmButton { router.dismissSheet() }
                } else {
                    ConfirmButton(zh ? "保存" : "Save", isWorking: model.isSubmitting) { submit() }
                        .disabled(app.isOffline)
                }
            }
        }
        .interactiveDismissDisabled(model.isSubmitting)
        .task { await model.load() }
    }

    private func submit() {
        let model = self.model
        let app = self.app
        Task {
            // 加好 key 后服务端唤醒等 key 的任务：工作台里的等待状态跟着变。
            if await model.submit() != nil { await app.refreshBadges() }
        }
    }

    // MARK: 表单

    @ViewBuilder
    private var form: some View {
        let zh = language == .chinese
        let model = self.model
        vendorSection
        if let vendor = model.selectedVendor {
            VendorInfoCard(vendor: vendor, notes: model.vendorNotes, compatibility: model.compatibility)
        } else if let compatibility = model.compatibility {
            Section {
                NoticeRow(
                    systemImage: compatibility.isCompatible ? "checkmark.circle" : "exclamationmark.triangle",
                    tone: compatibility.isCompatible ? .success : .waiting, text: compatibility.message(language))
            }
            .themedRow()
        }
        if model.isCustom {
            endpointSection
        }
        if model.choice != nil {
            Section {
                ModelsField(
                    title: "API key",
                    text: Binding(get: { model.apiKey }, set: { model.apiKey = $0 }),
                    prompt: zh ? "粘贴厂商控制台里的 API key" : "Paste the API key from the vendor's console",
                    kind: .secret,
                    problem: keyProblem,
                    hint: zh ? "加密保存，之后只显示后 4 位。" : "Stored encrypted; only the last 4 characters are shown later.")
                ModelsField(
                    title: zh ? "备注（可选）" : "Note (optional)",
                    text: Binding(get: { model.label }, set: { model.label = $0 }),
                    prompt: model.vendorName(language),
                    problem: fieldProblem(.label),
                    hint: zh
                        ? "有几把 key 时方便区分，最多 \(Credential.maxLabelLength) 个字。"
                        : "Helps tell keys apart (up to \(Credential.maxLabelLength) characters).")
                ModelsField(
                    title: zh ? "每日上限（可选，token 数）" : "Daily limit (optional, tokens)",
                    text: Binding(get: { model.dailyLimit }, set: { model.dailyLimit = $0 }),
                    prompt: zh ? "不限" : "No limit",
                    kind: .number,
                    problem: fieldProblem(.dailyLimit),
                    hint: zh
                        ? "当天用满这么多 token 后不再用这把 key（有备用的改用备用）。之后可以在 key 详情里改。"
                        : "Once a day's tokens reach this, the key is skipped (fallbacks take over). You can change it "
                            + "later in the key's details."
                )
            } header: {
                Text(zh ? "key" : "Key").groupHeader()
            }
            .themedRow()
            consentSection
        }
        if model.formRejection != nil || model.error != nil {
            Section {
                if let rejection = model.formRejection {
                    NoticeRow(
                        systemImage: "exclamationmark.octagon", tone: .failure,
                        text: rejection.message(vendorName: model.vendorName(language), language: language))
                }
                if let error = model.error {
                    ErrorBanner(error) { submit() }
                        .clearListRow()
                }
            }
            .themedRow()
        }
        if app.isOffline {
            Section {
            } footer: {
                Text(zh ? "离线时不能修改，联网后再试。" : "You can't make changes while offline.")
            }
        }
    }

    /// key 输入框下面的问题：本地查出来的，或者服务端说是订阅类 key、格式不对。
    private var keyProblem: String? { fieldProblem(.apiKey) }

    /// 一个字段下面的问题：本地查出来的优先，再是服务端拒收的原因里属于这个字段的。
    private func fieldProblem(_ field: AddCredentialModel.Field) -> String? {
        if let problem = model.problem(for: field) { return problem.message(language) }
        return model.rejection(for: field)?.message(vendorName: model.vendorName(language), language: language)
    }

    private var vendorSection: some View {
        let zh = language == .chinese
        let model = self.model
        return Section {
            if let error = visibleError(model.vendorsError) {
                ErrorBanner(error) { Task { await model.load() } }
                    .clearListRow()
            }
            if !model.hasLoadedVendors && model.vendors.isEmpty && model.vendorsError == nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(model.vendors) { vendor in
                    vendorRow(
                        title: vendor.name, detail: ModelsText.protocolList(vendor.modelProtocols, language: language),
                        isSelected: model.choice == .preset(vendor.id)
                    ) {
                        model.choice = .preset(vendor.id)
                    }
                }
                vendorRow(
                    title: ModelsText.customVendorName(language),
                    detail: zh
                        ? "自己的网关或兼容接口：填 https 的接口地址"
                        : "Your own gateway or a compatible API: enter its https addresses",
                    isSelected: model.isCustom
                ) {
                    model.choice = .custom
                }
            }
        } header: {
            Text(zh ? "厂商" : "Vendor").groupHeader()
        } footer: {
            if model.problem(for: .vendor) != nil {
                FieldMessage(text: zh ? "先选一个厂商。" : "Choose a vendor first.")
            } else if let rejection = model.rejection(for: .vendor) {
                FieldMessage(text: rejection.message(vendorName: model.vendorName(language), language: language))
            }
        }
        .themedRow()
    }

    /// 厂商的一行：名字、支持的协议，选中的右边系统勾（参考 11 的单选行）。
    private func vendorRow(
        title: String, detail: String?, isSelected: Bool, action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Metrics.Spacing.s) {
                PlansOptionLabel(title: title, detail: detail)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var endpointSection: some View {
        let zh = language == .chinese
        return Section {
            ForEach(CredentialEndpointField.allCases, id: \.self) { field in
                ModelsField(
                    title: field.title(language),
                    text: endpointBinding(field),
                    prompt: field.placeholder,
                    kind: .url,
                    problem: endpointProblem(field),
                    hint: ModelsText.protocolName(field.modelProtocol))
            }
        } header: {
            Text(zh ? "接口地址" : "Endpoints").groupHeader()
        } footer: {
            Text(
                zh
                    ? "至少填一个，只支持 https。填了哪个地址，这把 key 就能用对应的协议；地址本身之后不再显示。"
                    : "Fill in at least one; only https is supported. Each address enables its protocol for this key. "
                        + "Addresses aren't shown again after saving.")
        }
        .themedRow()
    }

    private func endpointBinding(_ field: CredentialEndpointField) -> Binding<String> {
        let model = self.model
        switch field {
        case .anthropic: return Binding(get: { model.anthropicBase }, set: { model.anthropicBase = $0 })
        case .openai: return Binding(get: { model.openaiBase }, set: { model.openaiBase = $0 })
        case .responses: return Binding(get: { model.responsesBase }, set: { model.responsesBase = $0 })
        }
    }

    private func endpointProblem(_ field: CredentialEndpointField) -> String? {
        let zh = language == .chinese
        if model.problem(for: .endpoint(field)) == .required { return zh ? "至少填一个地址。" : "Enter at least one address." }
        return fieldProblem(.endpoint(field))
    }

    private var consentSection: some View {
        let zh = language == .chinese
        let model = self.model
        let vendor = model.vendorName(language)
        return Section {
            NoticeRow(
                systemImage: "arrow.up.right.circle", tone: .neutral,
                text: ModelsText.dataSharingNotice(vendorNames: [vendor], language: language))
            Toggle(
                ModelsText.dataSharingConsent(vendorName: vendor, language: language),
                isOn: Binding(get: { model.hasConsented }, set: { model.hasConsented = $0 }))
        } header: {
            Text(zh ? "数据去向" : "Where your data goes").groupHeader()
        } footer: {
            if model.problem(for: .consent) != nil {
                FieldMessage(text: zh ? "要先同意，才能保存这把 key。" : "Agree first to save this key.")
            }
        }
        .themedRow()
    }
}

/// 选的厂商一组：支持的协议、推荐模型（`LabeledContent`），能不能给目标 Botin 用的提示，说明写在组脚注。
private struct VendorInfoCard: View {
    let vendor: VendorInfo
    let notes: String?
    let compatibility: CredentialCompatibility?

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        Section {
            if let protocols = ModelsText.protocolList(vendor.modelProtocols, language: language) {
                LabeledContent(zh ? "支持的协议" : "Protocols", value: protocols)
            }
            if !vendor.models.isEmpty {
                LabeledContent(
                    zh ? "推荐模型" : "Recommended models", value: AgentsText.list(vendor.models, language: language))
            }
            if let compatibility {
                NoticeRow(
                    systemImage: compatibility.isCompatible ? "checkmark.circle" : "exclamationmark.triangle",
                    tone: compatibility.isCompatible ? .success : .waiting, text: compatibility.message(language))
            }
        } header: {
            Text(vendor.name).groupHeader()
        } footer: {
            if let notes { Text(notes) }
        }
        .themedRow()
    }
}

/// 加好了：显示新 key、能用哪些协议、能不能给目标实例用、等 key 的任务会接着跑。
private struct AddCredentialDoneView: View {
    let model: AddCredentialModel
    let credential: Credential
    let targetInstance: Instance?
    let onClose: @MainActor () -> Void

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        List {
            Section {
                VStack(spacing: Metrics.Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(StatusTone.success.color)
                        .accessibilityHidden(true)
                    Text(zh ? "key 加好了" : "Key added")
                        .font(.title2.bold())
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(model.createdMessage(language))
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Metrics.Spacing.s)
                .clearListRow()
            }
            Section {
                ModelsCredentialRow(
                    summary: CredentialSummary(credential: credential, vendors: model.vendors, language: language))
                if let compatibility = model.compatibility {
                    NoticeRow(
                        systemImage: compatibility.isCompatible ? "checkmark.circle" : "exclamationmark.triangle",
                        tone: compatibility.isCompatible ? .success : .waiting, text: compatibility.message(language))
                }
            }
            .themedRow()
            Section {
                if let targetInstance {
                    Button(action: onClose) {
                        Label(
                            zh ? "回到“\(targetInstance.name)”的模型路由" : "Back to “\(targetInstance.name)” routes",
                            systemImage: "slider.horizontal.3")
                    }
                } else if let current = app.currentInstance {
                    // 不是从路由页来的（设置、引导）：顺手去配当前 Botin 的路由。先关掉这层 sheet，路由页压在底下那层
                    // （主栈或设置的栈）上；压进这层 sheet 的话，路由页的“添加 key”再弹添加 key 是原地不动。
                    Button {
                        router.dismissSheet()
                        router.open(.modelRoutes(current.id))
                    } label: {
                        Label(
                            zh ? "给“\(current.name)”配模型路由" : "Set up routes for “\(current.name)”",
                            systemImage: "slider.horizontal.3")
                    }
                }
            }
            .themedRow()
        }
        .insetGroupedList()
        .themedGroupedBackground()
    }
}

#Preview("添加 key · 浅色中文") {
    AddCredentialSheet().previewShell()
}

#Preview("添加 key · 深色英文") {
    AddCredentialSheet().previewShell(.english, scheme: .dark)
}
