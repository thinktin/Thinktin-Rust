import SwiftUI
import ThinktinKit

/// 登录设备页（WBS 12.2，`.devices`）。改版照参考 66（规范 4.9.9）：insetGrouped `List`，一组设备（本机在前），每行状态点、
/// 设备图标、名字、“类别 · 状态”，点进设备详情（本地压栈，参考 67、69）；别的设备左滑“下线”。设备那一组下面没有脚注
/// （参考 66）。有别的设备时下面单独一组红字“下线其他设备”（sheet，可以勾选同时全部停止），做完弹出下线了几台、停了什么。
/// 签名密钥出问题（新录了面容、签不了）时再多一组电脑的说明（12.9）。上下的节奏和设置别的页一样（`settingsGroupedList()`）。
///
/// 设备不缓存：离线时没有数据，页面显示空状态，顶部的离线横幅由 `AppShell` 放；写操作离线时禁用。
struct DevicesScreen: View {
    @Environment(\.client) private var client

    var body: some View {
        DevicesContent(model: DevicesModel(client: client))
    }
}

private struct DevicesContent: View {
    @State private var model: DevicesModel

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language
    @State private var pendingRevoke: DeviceInfo?
    @State private var showsSignOutOthers = false
    /// 设备详情：行是 `NavigationLink`，这个只给 `onSubpageRequest`（这台设备、第一台电脑）用。
    @State private var openedDevice: DeviceID?

    init(model: DevicesModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let zh = language == .chinese
        List {
            if let error = model.actionError {
                Section {
                    ErrorBanner(error, onDismiss: { model.dismissActionError() })
                }
                .clearListRow()
            }
            if model.hasLoaded {
                Section {
                    ForEach(sortedDevices) { device in
                        NavigationLink {
                            DeviceDetailScreen(model: model, deviceID: device.id)
                        } label: {
                            DeviceRow(device: device, isRevoking: model.revoking.contains(device.id))
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !device.isCurrent {
                                // 只弹确认：不用 `.destructive`，不然系统先把行收走。
                                Button(zh ? "下线" : "Sign out") {
                                    pendingRevoke = device
                                }
                                .tint(StatusTone.failure.color)
                                .disabled(app.isOffline)
                            }
                        }
                    }
                }
                .themedRow()
                if !model.otherDevices.isEmpty {
                    Section {
                        Button(zh ? "下线其他设备" : "Sign out other devices", role: .destructive) {
                            showsSignOutOthers = true
                        }
                        .foregroundStyle(Theme.danger)
                        .disabled(app.isOffline || model.isSigningOutOthers)
                    }
                    .themedRow()
                }
                // 电脑（12.9）：签名密钥失效、签不了名、出错时的说明和“生成新密钥”；还没有电脑登录时说怎么让它出现
                // （每台电脑的配对在它的详情里）。
                ComputerLinkStatusSection(hasComputer: model.devices.contains(where: \.isComputer))
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
        .overlay {
            if !model.hasLoaded {
                if model.loadError?.isOffline == true {
                    AccountOfflineState()
                } else if model.loadError == nil {
                    ProgressView()
                }
            }
        }
        .settingsNavigationTitle(AppRoute.devices.title(language))
        .refreshable { await model.load() }
        .task { await model.loadIfNeeded() }
        .navigationDestination(item: $openedDevice) { id in
            DeviceDetailScreen(model: model, deviceID: id)
        }
        .onSubpageRequest(.currentDevice, when: model.hasLoaded) { openedDevice = model.currentDevice?.id }
        .onSubpageRequest(.computerDevice, when: model.hasLoaded) {
            openedDevice = model.devices.first(where: \.isComputer)?.id
        }
        .deviceRevokeConfirmation(model: model, pending: $pendingRevoke)
        .sheet(isPresented: $showsSignOutOthers) {
            SignOutOthersSheet(model: model)
                .environment(app)
        }
        .alert(
            zh ? "已下线其他设备" : "Other devices signed out",
            isPresented: Binding(
                get: { model.signOutOthersResult != nil && !showsSignOutOthers },
                set: { if !$0 { model.signOutOthersResult = nil } })
        ) {
            Button(zh ? "好" : "OK", role: .cancel) {}
        } message: {
            Text(model.signOutOthersResult?.summary(language) ?? "")
        }
    }

    /// 本机在前，其余照服务端的顺序。
    private var sortedDevices: [DeviceInfo] {
        (model.currentDevice.map { [$0] } ?? []) + model.otherDevices
    }
}

extension View {
    /// 下线一台设备前的确认（列表左滑、详情页的红字都用它）。
    fileprivate func deviceRevokeConfirmation(model: DevicesModel, pending: Binding<DeviceInfo?>) -> some View {
        modifier(DeviceRevokeConfirmation(model: model, pending: pending))
    }
}

private struct DeviceRevokeConfirmation: ViewModifier {
    let model: DevicesModel
    @Binding var pending: DeviceInfo?
    var onRevoked: (@MainActor () -> Void)?

    @Environment(\.displayLanguage) private var language

    func body(content: Content) -> some View {
        let zh = language == .chinese
        content.confirmationDialog(
            title, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible, presenting: pending
        ) { device in
            Button(
                device.isCurrent ? (zh ? "下线并退出登录" : "Sign out") : (zh ? "下线" : "Sign out device"), role: .destructive
            ) {
                Task {
                    if await model.revoke(device) { onRevoked?() }
                }
            }
            Button(zh ? "取消" : "Cancel", role: .cancel) {}
        } message: { device in
            Text(Self.message(device, language: language))
        }
    }

    private var title: String {
        let zh = language == .chinese
        guard let device = pending else { return "" }
        if device.isCurrent { return zh ? "下线本机？" : "Sign out this device?" }
        let name = device.displayName(language)
        return zh ? "下线“\(name)”？" : "Sign out “\(name)”?"
    }

    static func message(_ device: DeviceInfo, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        if device.isCurrent {
            return zh
                ? "下线本机就是退出登录：回到登录页，这台设备不再收到通知。Botin 照常运行。"
                : "Signing out this device takes you back to the sign-in screen and stops notifications here. "
                    + "Botins keep running."
        }
        return zh
            ? "它会立即退出登录，要重新登录才能再用。"
            : "It will be signed out right away and needs to sign in again to be used."
    }
}

/// 设备的一行（参考 66）：状态点（本机、在线的电脑亮）、只有轮廓的平台图标、名字、一行 `.footnote` 的“类别 · 状态”
/// （名字和它隔 6pt，和设置别的带副标题的行一样）。系统 `NavigationLink` 画箭头。
struct DeviceRow: View {
    let device: DeviceInfo
    var isRevoking = false

    @Environment(\.displayLanguage) private var language

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: Metrics.Spacing.s) {
                DeviceStatusDot(isActive: device.isActive)
                // 参考 66 的图标只有轮廓。设备这类符号系统默认分层画（屏幕那一块垫一层浅灰，看上去是实心的，
                // 2026-11-11 截图），指定单色才只剩线。
                Image(systemName: DeviceInfo.symbol(for: device))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: Metrics.Spacing.l)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SettingsMetrics.subtitleSpacing) {
                    Text(device.displayName(language))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(device.listSubtitle(now: context.date, language: language))
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }
                if isRevoking {
                    Spacer(minLength: Metrics.Spacing.xs)
                    ProgressView()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(device.accessibilityText(now: context.date, language: language)))
        }
    }
}

/// 设备的状态点（参考 66、67）：亮的是成功色，别的灰。
struct DeviceStatusDot: View {
    let isActive: Bool

    var body: some View {
        Circle()
            .fill(isActive ? StatusTone.success.color : Theme.inkTertiary)
            .frame(width: Metrics.Spacing.xs, height: Metrics.Spacing.xs)
            .accessibilityHidden(true)
    }
}

extension DeviceInfo {
    /// SF Symbol：iPad、iPhone、安卓手机、电脑。电脑用 `display`（参考 66 是只有轮廓的显示器）。这几个符号都要用单色画
    /// （`DeviceRow`），不然屏幕那一块是实心的灰。
    static func symbol(for device: DeviceInfo) -> String {
        switch device.platform {
        case .ios: device.name.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone"
        case .android: "smartphone"
        case .macos, .windows, .unknown: "display"
        }
    }
}

/// 设备详情（登录设备页里本地压栈，参考 67 手机、69 电脑）：第一组只有名称、状态两行（参考 67、69；类别在列表的副标题里，
/// 登录时间接在状态后面：“正在使用 · 10月2日登录”）；电脑多“在这台电脑上执行”的配对和授权（12.9，
/// `ComputerDeviceSections`）；最后红字“下线”（本机是“下线本机”，就是退出登录），下面没有脚注（参考 69 的“移除电脑”；
/// 那句说明在点了以后的确认里）。名称行带箭头，点了弹系统的改名弹窗（参考 68：标题“重命名 …”、输入框、取消 / 保存）；
/// 改名要后端（规范 6.20），保存弹“即将推出”。
struct DeviceDetailScreen: View {
    let model: DevicesModel
    let deviceID: DeviceID

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRevoke: DeviceInfo?
    @State private var isRenaming = false
    @State private var newName = ""
    @State private var comingSoon: SettingsComingSoon?

    var body: some View {
        let zh = language == .chinese
        let device = model.devices.first { $0.id == deviceID }
        List {
            if let device {
                Section {
                    nameRow(device)
                    TimelineView(.everyMinute) { context in
                        HStack(spacing: Metrics.Spacing.s) {
                            DeviceStatusDot(isActive: device.isActive)
                            Text(device.detailStatusText(now: context.date, language: language))
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        // 分隔线从行首画起（系统默认从第一个文字开始，落在状态点后面，和别的行不齐）。
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    }
                }
                .themedRow()
                if device.isComputer {
                    ComputerDeviceSections(computer: device)
                }
                Section {
                    Button(
                        device.isCurrent
                            ? (zh ? "下线本机" : "Sign out this device") : (zh ? "下线这台设备" : "Sign out this device"),
                        role: .destructive
                    ) {
                        pendingRevoke = device
                    }
                    .foregroundStyle(Theme.danger)
                    .disabled(app.isOffline || model.revoking.contains(device.id))
                }
                .themedRow()
            }
        }
        .insetGroupedList()
        .settingsGroupedList()
        .themedGroupedBackground()
        .overlay {
            if device == nil {
                ContentUnavailableView(
                    zh ? "这台设备已经下线" : "This device is signed out", systemImage: "iphone.slash")
            }
        }
        .settingsNavigationTitle(device?.displayName(language) ?? AppRoute.devices.title(language))
        .modifier(
            DeviceRevokeConfirmation(model: model, pending: $pendingRevoke, onRevoked: { dismiss() })
        )
        .alert(renameTitle(device), isPresented: $isRenaming) {
            TextField(zh ? "名称" : "Name", text: $newName)
            Button(zh ? "取消" : "Cancel", role: .cancel) {}
            Button(zh ? "保存" : "Save") { comingSoon = .renameDevice }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .settingsComingSoon($comingSoon)
    }

    /// 名称一行（参考 67）：右边灰色的名字和箭头，点了改名。
    private func nameRow(_ device: DeviceInfo) -> some View {
        let zh = language == .chinese
        return Button {
            newName = device.displayName(language)
            isRenaming = true
        } label: {
            LabeledContent {
                HStack(spacing: Metrics.Spacing.xs) {
                    Text(device.displayName(language))
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.inkTertiary)
                        .accessibilityHidden(true)
                }
            } label: {
                Text(zh ? "名称" : "Name")
                    .foregroundStyle(Theme.ink)
            }
        }
        .accessibilityHint(Text(zh ? "给这台设备改名" : "Renames this device"))
    }

    /// 改名弹窗的标题（参考 68：“重命名 iPhone”）。
    private func renameTitle(_ device: DeviceInfo?) -> String {
        let name = device?.displayName(language) ?? ""
        return language == .chinese ? "重命名 \(name)" : "Rename \(name)"
    }
}

/// “下线其他设备”（sheet）：说明会发生什么，可以勾选“同时全部停止”（怀疑账号被盗时），确认后执行。
/// 结果由设备页弹出（关掉 sheet 之后）。
struct SignOutOthersSheet: View {
    let model: DevicesModel

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @State private var stopAgents = false

    var body: some View {
        let zh = language == .chinese
        NavigationStack {
            Form {
                Section {
                    Toggle(zh ? "同时停止全部 Botin" : "Also stop all Botins", isOn: $stopAgents)
                        .tint(Theme.danger)
                } header: {
                    Text(
                        zh
                            ? "除了这台，其他 \(model.otherDevices.count) 台设备会立即退出登录，要重新登录才能再用。"
                            : "Every device except this one (\(model.otherDevices.count) in total) is signed out right away "
                                + "and has to sign in again."
                    )
                    .groupHeader()
                } footer: {
                    Text(
                        zh
                            ? "怀疑账号被盗时打开：同时取消所有运行、吊销 Botin 的运行授权、暂停所有计划。"
                            : "Turn this on if you think someone else has access: it also cancels all runs, revokes the "
                                + "Botins' run grants and pauses every plan.")
                }
                .themedRow()
                if let error = model.actionError {
                    Section {
                        ErrorBanner(error, onDismiss: { model.dismissActionError() })
                    }
                    .clearListRow()
                }
            }
            .formStyle(.grouped)
            .themedGroupedBackground()
            .settingsNavigationTitle(zh ? "下线其他设备" : "Sign out others")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton { dismiss() }
                }
            }
            .floatingBar(edge: .bottom) {
                Button(role: .destructive) {
                    Task {
                        if await model.signOutOthers(stopAgents: stopAgents) != nil {
                            if stopAgents { await app.refreshBadges() }
                            dismiss()
                        }
                    }
                } label: {
                    HStack(spacing: Metrics.Spacing.xs) {
                        if model.isSigningOutOthers {
                            ProgressView()
                        }
                        Text(
                            stopAgents
                                ? (zh ? "下线并全部停止" : "Sign out and stop everything")
                                : (zh ? "下线其他设备" : "Sign out other devices"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .glassButtonStyle(.prominent)
                .tint(Theme.danger)
                .controlSize(.large)
                .disabled(model.isSigningOutOthers || app.isOffline)
                .padding(.horizontal, Metrics.Spacing.m)
                .padding(.bottom, Metrics.Spacing.s)
            }
        }
        .tint(Theme.accent)
        .presentationDetents([.medium, .large])
    }
}

#Preview("登录设备 · 浅色中文") {
    AccountDestination(route: .devices).previewShell(client: AccountPreviewClients.signedIn())
}

#Preview("登录设备 · 深色英文、只有本机") {
    AccountDestination(route: .devices).previewShell(
        .english, scheme: .dark, client: AccountPreviewClients.singleDevice())
}

#Preview("下线其他设备 · 浅色中文") {
    let model = DevicesModel(client: AccountPreviewClients.signedIn())
    SignOutOthersSheet(model: model)
        .task { await model.load() }
        .previewShell()
}

#Preview("下线其他设备 · 深色英文") {
    let model = DevicesModel(client: AccountPreviewClients.signedIn())
    SignOutOthersSheet(model: model)
        .task { await model.load() }
        .previewShell(.english, scheme: .dark)
}
