import SwiftUI
import ThinktinKit

/// 账号页（WBS 12.2，`.account`；设置根页第一行进来）。改版照参考 54（规范 4.9.2）：insetGrouped `List`，第一组头像、昵称、
/// 打码的手机号；“个人资料”一组昵称（进改昵称页）、手机号（只读）；红字“退出登录”单独一组；红色垃圾桶“注销账号”单独一组
/// （行尾没有箭头），脚注写后果。分组标题、脚注的颜色照参考 54 比行里的灰字暗一档（`Theme.groupCaption`）。参考的“切换账户 /
/// 添加账户”不做（client-core 只存一个会话，规范 6.20）。登录设备、全部停止在设置根页。
struct AccountScreen: View {
    @Environment(\.client) private var client
    @Environment(AppModel.self) private var app

    var body: some View {
        AccountContent(model: AccountModel(client: client, user: app.user), client: client)
    }
}

private struct AccountContent: View {
    @State private var model: AccountModel
    let client: any ClientProtocol

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language
    @State private var confirmsSignOut = false
    @State private var isSigningOut = false
    @State private var signOutError: ClientError?
    /// 点了“注销账号”：压进注销页。
    @State private var showsDeleteAccount = false

    init(model: AccountModel, client: any ClientProtocol) {
        _model = State(initialValue: model)
        self.client = client
    }

    var body: some View {
        let zh = language == .chinese
        List {
            if let user = model.user {
                Section {
                    SettingsProfileRow(
                        title: user.nameForDisplay, subtitle: model.maskedPhone.isEmpty ? nil : model.maskedPhone)
                }
                .themedRow()
                profileSection(user)
                signOutSection
                Section {
                    // 参考 54：这一行只有垃圾桶和字，行尾没有箭头（`NavigationLink` 会画一个），所以是按钮，点了压进注销页
                    // （下面的 `navigationDestination(isPresented:)`）。垃圾桶和正文一样大，字紧跟在后面（约 8pt）；列表行里的
                    // `Label` 会把图标放进一列宽的图标栏、字离图标约 39pt，所以自己排。
                    Button(role: .destructive) {
                        showsDeleteAccount = true
                    } label: {
                        HStack(spacing: Metrics.Spacing.xs) {
                            Image(systemName: "trash")
                                .imageScale(.medium)
                                .accessibilityHidden(true)
                            Text(zh ? "注销账号" : "Delete account")
                        }
                        .foregroundStyle(Theme.danger)
                    }
                    .disabled(app.isOffline)
                } footer: {
                    Text(
                        zh
                            ? "永久删除你的 ThinkTin 账号和里面的全部内容，不能恢复。"
                            : "Permanently deletes your ThinkTin account and everything in it. This can't be undone."
                    )
                    .settingsGroupFooter()
                }
                .themedRow()
            } else if let error = model.loadError, !error.isOffline {
                Section {
                    ErrorBanner(error, onRetry: { Task { await model.load() } })
                }
                .clearListRow()
            }
        }
        .insetGroupedList()
        .settingsGroupedList()
        .themedGroupedBackground()
        .overlay { placeholder }
        .settingsNavigationTitle(AppRoute.account.title(language))
        .navigationDestination(isPresented: $showsDeleteAccount) {
            DeleteAccountView(client: client, maskedPhone: model.maskedPhone)
        }
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

    /// 还没拉到用户：转圈；离线又没有：离线说明（账号不缓存，docs/ios.md 6.2）。
    @ViewBuilder
    private var placeholder: some View {
        if model.user == nil {
            if let error = model.loadError {
                if error.isOffline {
                    AccountOfflineState()
                }
            } else {
                ProgressView()
            }
        }
    }

    private func profileSection(_ user: User) -> some View {
        let zh = language == .chinese
        let name = user.displayName.flatMap { $0.isEmpty ? nil : $0 }
        return Section {
            NavigationLink {
                DisplayNameEditor(client: client, user: user) { model.apply($0) }
            } label: {
                LabeledContent(zh ? "昵称" : "Name", value: name ?? (zh ? "未设置" : "Not set"))
            }
            .disabled(app.isOffline)
            LabeledContent {
                Text(verbatim: model.maskedPhone)
                    .monospacedDigit()
            } label: {
                Text(zh ? "手机号" : "Phone number")
            }
        } header: {
            Text(zh ? "个人资料" : "Profile").settingsGroupHeader()
        } footer: {
            Text(zh ? "手机号是登录方式，暂时不能更换。" : "Your phone number is how you sign in and can't be changed yet.")
                .settingsGroupFooter()
        }
        .themedRow()
    }

    private var signOutSection: some View {
        let zh = language == .chinese
        return Section {
            if let signOutError {
                ErrorBanner(signOutError, onDismiss: { self.signOutError = nil })
            }
            Button(role: .destructive) {
                confirmsSignOut = true
            } label: {
                HStack {
                    Text(zh ? "退出登录" : "Sign out")
                        .foregroundStyle(Theme.danger)
                    if isSigningOut {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isSigningOut)
        } footer: {
            Text(
                zh
                    ? "退出登录只影响这台设备，Botin 照常运行。"
                    : "Signing out only affects this device; Botins keep running."
            )
            .settingsGroupFooter()
        }
        .themedRow()
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
    @FocusState private var isFocused: Bool

    init(client: any ClientProtocol, user: User?, onSaved: @escaping @MainActor (User) -> Void) {
        _model = State(initialValue: DisplayNameModel(client: client, user: user))
        self.onSaved = onSaved
    }

    var body: some View {
        let zh = language == .chinese
        Form {
            Section {
                TextField(zh ? "昵称" : "Name", text: $model.draft)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit { save() }
                    .accessibilityLabel(Text(zh ? "昵称" : "Name"))
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    if let message = model.validationMessage(language) {
                        Text(message)
                            .foregroundStyle(Theme.danger)
                    } else {
                        Text(
                            zh
                                ? "显示在首页左上角的头像和这台设备上。不填就显示打码的手机号。"
                                : "Shown on the home screen's account button and on this device. Leave it empty to show your masked number."
                        )
                    }
                    Spacer(minLength: Metrics.Spacing.xs)
                    Text(verbatim: model.counterText)
                        .monospacedDigit()
                        .foregroundStyle(model.isTooLong ? Theme.danger : Theme.inkTertiary)
                        .accessibilityLabel(
                            Text(
                                zh
                                    ? "已输入 \(model.characterCount) 个字，最多 \(User.maxDisplayNameLength) 个"
                                    : "\(model.characterCount) of \(User.maxDisplayNameLength) characters"))
                }
            }
            .themedRow()
            if let error = model.error {
                Section {
                    ErrorBanner(error, onRetry: { save() })
                }
                .clearListRow()
            }
        }
        .formStyle(.grouped)
        .settingsGroupedList()
        .themedGroupedBackground()
        .settingsNavigationTitle(zh ? "昵称" : "Name")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                ConfirmButton(zh ? "保存" : "Save", isWorking: model.isSaving) { save() }
                    .disabled(!model.canSave || app.isOffline)
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
