import SwiftUI
import ThinktinKit

/// 登录设备页（WBS 12.2，`.devices`）。改版照参考 66（规范 4.9.9）：insetGrouped `List`，一组设备（本机在前），每行状态点、
/// 设备图标、名字、“类别 · 状态”，点进设备详情（本地压栈，参考 67、69）；别的设备左滑“下线”。有别的设备时下面单独一组红字
/// “下线其他设备”（sheet，可以勾选同时全部停止），做完弹出下线了几台、停了什么。签名密钥出问题（新录了面容、签不了）时
/// 再多一组电脑的说明（12.9）。
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
                } footer: {
                    Text(
                        zh
                            ? "电脑连着时显示“在线”，Botin 可以借它在本机执行。iOS 16 起设备名可能都叫 iPhone，点进去看登录时间分辨。"
                            : "Computers show Online while connected, so Botins can run tasks on them. Device names may all read "
                                + "“iPhone” on iOS 16 and later; open one to see when it signed in.")
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
                // 电脑（12.9）：签名密钥失效、签不了名、出错时的说明和“生成新密钥”（每台电脑的配对在它的详情里）。
                ComputerLinkStatusSection()
            } else if let error = model.loadError, !error.isOffline {
                Section {
                    ErrorBanner(error, onRetry: { Task { await model.load() } })
                }
                .clearListRow()
            }
        }
        .insetGroupedList()
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

/// 设备的一行（参考 66）：状态点（本机、在线的电脑亮）、平台图标、名字、“类别 · 状态”。系统 `NavigationLink` 画箭头。
struct DeviceRow: View {
    let device: DeviceInfo
    var isRevoking = false

    @Environment(\.displayLanguage) private var language

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: Metrics.Spacing.s) {
                DeviceStatusDot(isActive: device.isActive)
                Image(systemName: DeviceInfo.symbol(for: device))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: Metrics.Spacing.l)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    Text(device.displayName(language))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(device.listSubtitle(now: context.date, language: language))
                        .font(.subheadline)
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
    /// SF Symbol：iPad、iPhone、安卓手机、电脑。
    static func symbol(for device: DeviceInfo) -> String {
        switch device.platform {
        case .ios: device.name.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone"
        case .android: "smartphone"
        case .macos, .windows: "desktopcomputer"
        case .unknown: "desktopcomputer"
        }
    }
}

/// 设备详情（登录设备页里本地压栈，参考 67 手机、69 电脑）：名称、状态、登录时间一组；电脑多“在这台电脑上执行”的配对和
/// 授权（12.9，`ComputerDeviceSections`）；最后红字“下线”（本机是“下线本机”，就是退出登录）。改名要后端（规范 6.20），名称行
/// 不能点。
struct DeviceDetailScreen: View {
    let model: DevicesModel
    let deviceID: DeviceID

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRevoke: DeviceInfo?

    var body: some View {
        let zh = language == .chinese
        let device = model.devices.first { $0.id == deviceID }
        List {
            if let device {
                Section {
                    LabeledContent(zh ? "名称" : "Name", value: device.displayName(language))
                    TimelineView(.everyMinute) { context in
                        HStack(spacing: Metrics.Spacing.s) {
                            DeviceStatusDot(isActive: device.isActive)
                            Text(device.activityText(now: context.date, language: language))
                                .foregroundStyle(Theme.inkSecondary)
                        }
                    }
                    LabeledContent(zh ? "类别" : "Type", value: device.platform.localizedName(language))
                    TimelineView(.everyMinute) { context in
                        LabeledContent(
                            zh ? "登录" : "Signed in", value: device.signedInText(now: context.date, language: language))
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
                } footer: {
                    Text(DeviceRevokeConfirmation.message(device, language: language))
                }
                .themedRow()
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .overlay {
            if device == nil {
                ContentUnavailableView(
                    zh ? "这台设备已经下线" : "This device is signed out", systemImage: "iphone.slash")
            }
        }
        .settingsNavigationTitle(device?.displayName(language) ?? AppRoute.devices.title(language))
        .modifier(
            DeviceRevokeConfirmation(model: model, pending: $pendingRevoke, onRevoked: { dismiss() }))
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
                    .textCase(nil)
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
