import SwiftUI
import ThinktinKit

/// 账号页（WBS 12.2，`.account`）：头像、昵称、打码的手机号；登录设备、全部停止；退出登录；注销账号。
/// 版式参考 Claude iOS App 的设置页（一组组圆角卡片）。设置中心（12.12）的“账号”一栏进这里。
struct AccountScreen: View {
    @Environment(\.client) private var client
    @Environment(AppModel.self) private var app

    var body: some View {
        AccountContent(model: AccountModel(client: client, user: app.user), client: client)
    }
}

private struct AccountContent: View {
    @State private var model: AccountModel
    @State private var stopAll: StopAllModel
    let client: any ClientProtocol

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language
    @State private var confirmsSignOut = false
    @State private var isSigningOut = false
    @State private var signOutError: ClientError?

    init(model: AccountModel, client: any ClientProtocol) {
        _model = State(initialValue: model)
        _stopAll = State(initialValue: StopAllModel(client: client))
        self.client = client
    }

    var body: some View {
        let zh = language == .chinese
        AccountScrollPage {
            if let user = model.user {
                header(user)
                profileSection(user)
                securitySection
                signOutSection
                AccountSection(
                    footer: zh
                        ? "注销会永久删除账号和全部内容。" : "Deleting your account permanently removes it and everything in it."
                ) {
                    NavigationLink {
                        DeleteAccountView(client: client, maskedPhone: model.maskedPhone)
                    } label: {
                        AccountRow(
                            systemImage: "person.crop.circle.badge.xmark", title: zh ? "注销账号" : "Delete account",
                            tone: .destructive, showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(app.isOffline)
                }
            } else if let error = model.loadError {
                if error.isOffline {
                    AccountOfflineState()
                } else {
                    ErrorBanner(error, onRetry: { Task { await model.load() } })
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Metrics.Spacing.xxl)
            }
        }
        .navigationTitle(AppRoute.account.title(language))
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await model.load() }
        .task { await model.load() }
        .confirmationDialog(
            zh ? "退出登录？" : "Sign out?", isPresented: $confirmsSignOut, titleVisibility: .visible
        ) {
            Button(zh ? "退出登录" : "Sign out", role: .destructive) { signOut() }
            Button(zh ? "取消" : "Cancel", role: .cancel) {}
        } message: {
            Text(AccountModel.signOutMessage(language))
        }
    }

    private func header(_ user: User) -> some View {
        HStack(spacing: Metrics.Spacing.m) {
            AccountAvatar(name: user.nameForDisplay)
            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                Text(user.nameForDisplay)
                    .typography(.title2)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                if !model.maskedPhone.isEmpty {
                    Text(verbatim: model.maskedPhone)
                        .font(Typography.subheadline.font.monospacedDigit())
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func profileSection(_ user: User) -> some View {
        let zh = language == .chinese
        let name = user.displayName.flatMap { $0.isEmpty ? nil : $0 }
        return AccountSection(
            zh ? "个人资料" : "Profile",
            footer: zh ? "手机号是登录方式，暂时不能更换。" : "Your phone number is how you sign in and can't be changed yet."
        ) {
            NavigationLink {
                DisplayNameEditor(client: client, user: user) { model.apply($0) }
            } label: {
                AccountRow(
                    systemImage: "person", title: zh ? "昵称" : "Name", value: name ?? (zh ? "未设置" : "Not set"),
                    showsChevron: true)
            }
            .buttonStyle(.plain)
            .disabled(app.isOffline)
            AccountRowDivider()
            AccountRow(systemImage: "phone", title: zh ? "手机号" : "Phone number", value: model.maskedPhone)
        }
    }

    private var securitySection: some View {
        let zh = language == .chinese
        return AccountSection(
            zh ? "安全" : "Security",
            footer: zh
                ? "退出登录只影响这台设备，agent 照常运行。要让所有 agent 立刻停下来，用“全部停止”。"
                : "Signing out only affects this device; agents keep running. Use Stop everything to halt them all at once."
        ) {
            NavigationLink(value: AppRoute.devices) {
                AccountRow(
                    systemImage: "laptopcomputer.and.iphone", title: AppRoute.devices.title(language),
                    showsChevron: true)
            }
            .buttonStyle(.plain)
            AccountRowDivider()
            StopAllRow(model: stopAll)
        }
    }

    private var signOutSection: some View {
        let zh = language == .chinese
        return VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            if let signOutError {
                ErrorBanner(signOutError, onDismiss: { self.signOutError = nil })
            }
            AccountSection {
                Button {
                    confirmsSignOut = true
                } label: {
                    HStack {
                        AccountRow(
                            systemImage: "rectangle.portrait.and.arrow.right", title: zh ? "退出登录" : "Sign out")
                        if isSigningOut {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, Metrics.Spacing.m)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isSigningOut)
            }
        }
    }

    /// 退出登录用 `AppModel.signOut()`：网络不通时本地照样清掉，之后应用框架回到登录页。
    private func signOut() {
        isSigningOut = true
        signOutError = nil
        Task {
            defer { isSigningOut = false }
            do {
                try await app.signOut()
            } catch {
                signOutError = (error as? ClientError) ?? .internal(message: String(describing: error))
            }
        }
    }
}

/// 改昵称（账号页里压进来的子页面，不用 `AppRoute`）。
struct DisplayNameEditor: View {
    @State private var model: DisplayNameModel
    let onSaved: @MainActor (User) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @FocusState private var isFocused: Bool

    init(client: any ClientProtocol, user: User?, onSaved: @escaping @MainActor (User) -> Void) {
        _model = State(initialValue: DisplayNameModel(client: client, user: user))
        self.onSaved = onSaved
    }

    var body: some View {
        let zh = language == .chinese
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
        AccountScrollPage {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                TextField(zh ? "昵称" : "Name", text: $model.draft)
                    .typography(.body)
                    .foregroundStyle(Theme.ink)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit { save() }
                    .padding(.horizontal, Metrics.Spacing.m)
                    .frame(minHeight: Metrics.minTapTarget + Metrics.Spacing.s)
                    .background(Theme.paperElevated, in: shape)
                    .overlay {
                        shape.strokeBorder(
                            model.isTooLong ? Theme.danger : (isFocused ? Theme.accent : Theme.hairline),
                            lineWidth: isFocused ? 1 : Metrics.hairline(scale: displayScale))
                    }
                    .accessibilityLabel(Text(zh ? "昵称" : "Name"))
                HStack(alignment: .firstTextBaseline) {
                    if let message = model.validationMessage(language) {
                        FieldMessage(text: message)
                    } else {
                        Text(
                            zh
                                ? "显示在侧边栏和这台设备上。不填就显示打码的手机号。"
                                : "Shown in the sidebar and on this device. Leave it empty to show your masked number."
                        )
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Metrics.Spacing.xs)
                    Text(verbatim: model.counterText)
                        .font(Typography.footnote.font.monospacedDigit())
                        .foregroundStyle(model.isTooLong ? Theme.danger : Theme.inkTertiary)
                        .accessibilityLabel(
                            Text(
                                zh
                                    ? "已输入 \(model.characterCount) 个字，最多 \(User.maxDisplayNameLength) 个"
                                    : "\(model.characterCount) of \(User.maxDisplayNameLength) characters"))
                }
            }
            if let error = model.error {
                ErrorBanner(error, onRetry: { save() })
            }
        }
        .navigationTitle(zh ? "昵称" : "Name")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if model.isSaving {
                    ProgressView()
                } else {
                    Button(zh ? "保存" : "Save") { save() }
                        .disabled(!model.canSave || app.isOffline)
                }
            }
        }
        .onAppear { isFocused = true }
    }

    private func save() {
        guard model.canSave, !app.isOffline else { return }
        Task {
            if let user = await model.save() {
                onSaved(user)
                dismiss()
            }
        }
    }
}

#Preview("账号 · 浅色中文") {
    AccountDestination(route: .account).previewShell(client: AccountPreviewClients.signedIn())
}

#Preview("账号 · 深色英文") {
    AccountDestination(route: .account).previewShell(.english, scheme: .dark, client: AccountPreviewClients.signedIn())
}

#Preview("昵称 · 浅色中文") {
    DisplayNameEditor(client: AccountPreviewClients.signedIn(), user: DemoData.state().user) { _ in }
        .previewShell()
}

#Preview("昵称 · 深色英文、太长") {
    let user = User(
        id: DemoData.userID, phone: "+8613800138000", displayName: String(repeating: "Long name ", count: 7),
        createdAt: Date())
    DisplayNameEditor(client: AccountPreviewClients.signedIn(), user: user) { _ in }
        .previewShell(.english, scheme: .dark)
}
