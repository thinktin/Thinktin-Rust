import SwiftUI
import ThinktinKit

/// 登录设备页（WBS 12.2，`.devices`）：本机（下线本机就是退出登录）、其他设备（电脑是否在线、最近活跃、登录时间，
/// 单台下线），底部“下线其他设备”（可以勾选同时全部停止），做完显示下线了几台、停了什么。
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
        AccountScrollPage {
            if let error = model.actionError {
                ErrorBanner(error, onDismiss: { model.dismissActionError() })
            }
            if model.hasLoaded {
                if let current = model.currentDevice {
                    AccountSection(zh ? "本机" : "This device") {
                        DeviceRow(device: current, isRevoking: model.revoking.contains(current.id)) {
                            pendingRevoke = current
                        }
                    }
                }
                AccountSection(
                    zh ? "其他设备" : "Other devices",
                    footer: zh
                        ? "电脑连着时显示“在线”，agent 可以借它在本机执行。iOS 16 起设备名可能都叫 iPhone，可以按登录时间分辨。"
                        : "Computers show Online while connected, so agents can run tasks on them. Device names may all read "
                            + "“iPhone” on iOS 16 and later; use the sign-in date to tell them apart."
                ) {
                    if model.otherDevices.isEmpty {
                        Text(zh ? "没有其他登录着的设备。" : "No other devices are signed in.")
                            .typography(.subheadline)
                            .foregroundStyle(Theme.inkSecondary)
                            .padding(Metrics.Spacing.m)
                    }
                    ForEach(Array(model.otherDevices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { AccountRowDivider() }
                        DeviceRow(device: device, isRevoking: model.revoking.contains(device.id)) {
                            pendingRevoke = device
                        }
                    }
                }
                if !model.otherDevices.isEmpty {
                    PillButton(
                        zh ? "下线其他设备" : "Sign out other devices", systemImage: "rectangle.portrait.and.arrow.right",
                        kind: .secondary
                    ) {
                        showsSignOutOthers = true
                    }
                    .disabled(app.isOffline || model.isSigningOutOthers)
                    .frame(maxWidth: .infinity)
                }
                // 电脑：配对、授权、解除配对（12.9，只在能签名的设备上有）。
                ComputerLinkSection()
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
        .navigationTitle(AppRoute.devices.title(language))
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await model.load() }
        .task { await model.loadIfNeeded() }
        .confirmationDialog(
            revokeTitle, isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
            titleVisibility: .visible, presenting: pendingRevoke
        ) { device in
            Button(
                device.isCurrent ? (zh ? "下线并退出登录" : "Sign out") : (zh ? "下线" : "Sign out device"), role: .destructive
            ) {
                Task { await model.revoke(device) }
            }
            Button(zh ? "取消" : "Cancel", role: .cancel) {}
        } message: { device in
            Text(revokeMessage(device))
        }
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

    private var revokeTitle: String {
        let zh = language == .chinese
        guard let device = pendingRevoke else { return "" }
        if device.isCurrent { return zh ? "下线本机？" : "Sign out this device?" }
        let name = device.displayName(language)
        return zh ? "下线“\(name)”？" : "Sign out “\(name)”?"
    }

    private func revokeMessage(_ device: DeviceInfo) -> String {
        let zh = language == .chinese
        if device.isCurrent {
            return zh
                ? "下线本机就是退出登录：回到登录页，这台设备不再收到通知。agent 照常运行。"
                : "Signing out this device takes you back to the sign-in screen and stops notifications here. "
                    + "Agents keep running."
        }
        return zh
            ? "它会立即退出登录，要重新登录才能再用。"
            : "It will be signed out right away and needs to sign in again to be used."
    }
}

/// 设备的一行：平台图标、名字（本机带“本机”标记）、状态（电脑在线 / 离线、最近活跃）、登录时间，右边“下线”。
struct DeviceRow: View {
    let device: DeviceInfo
    var isRevoking = false
    let onRevoke: @MainActor () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        TimelineView(.everyMinute) { context in
            HStack(alignment: .center, spacing: Metrics.Spacing.s) {
                Image(systemName: icon)
                    .typography(.title3)
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: Metrics.Spacing.xl)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    HStack(spacing: Metrics.Spacing.xs) {
                        Text(device.displayName(language))
                            .typography(.body)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(2)
                        if device.isCurrent {
                            Text(zh ? "本机" : "This device")
                                .typography(.caption2)
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, Metrics.Spacing.xs)
                                .padding(.vertical, Metrics.Spacing.unit / 2)
                                .overlay { Capsule().strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1) }
                                .fixedSize()
                        }
                    }
                    HStack(spacing: Metrics.Spacing.xxs) {
                        if device.isComputer {
                            StatusDot(
                                StatusAppearance(tone: device.isOnline ? .success : .muted),
                                accessibilityLabel: device.isOnline ? (zh ? "在线" : "Online") : (zh ? "离线" : "Offline"))
                        }
                        Text(device.activityText(now: context.date, language: language))
                            .typography(.caption)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    Text(device.signedInText(now: context.date, language: language))
                        .typography(.caption)
                        .foregroundStyle(Theme.inkTertiary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(device.accessibilityText(now: context.date, language: language)))
                Spacer(minLength: Metrics.Spacing.xs)
                if isRevoking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: onRevoke) {
                        Text(zh ? "下线" : "Sign out")
                    }
                    .buttonStyle(.pill(.secondary, size: .compact))
                    .disabled(app.isOffline)
                    .accessibilityLabel(
                        Text(
                            device.isCurrent
                                ? (zh ? "下线本机" : "Sign out this device")
                                : (zh
                                    ? "下线 \(device.displayName(language))" : "Sign out \(device.displayName(language))")
                        ))
                }
            }
            .padding(.horizontal, Metrics.Spacing.m)
            .padding(.vertical, Metrics.Spacing.s)
            .frame(minHeight: Metrics.minTapTarget)
        }
    }

    /// SF Symbol：iPad、iPhone、安卓手机、Mac。
    private var icon: String {
        switch device.platform {
        case .ios: device.name.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone"
        case .android: "smartphone"
        case .macos: "laptopcomputer"
        case .unknown: "desktopcomputer"
        }
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
            AccountScrollPage {
                AccountPageHeader(
                    title: zh ? "下线其他设备" : "Sign out other devices",
                    message: zh
                        ? "除了这台，其他 \(model.otherDevices.count) 台设备会立即退出登录，要重新登录才能再用。"
                        : "Every device except this one (\(model.otherDevices.count) in total) is signed out right away "
                            + "and has to sign in again.")
                AccountSection(
                    footer: zh
                        ? "怀疑账号被盗时勾选：同时取消所有运行、吊销 agent 的运行授权、暂停所有计划。"
                        : "Turn this on if you think someone else has access: it also cancels all runs, revokes the "
                            + "agents' run grants and pauses every plan."
                ) {
                    Toggle(isOn: $stopAgents) {
                        Text(zh ? "同时停止全部 agent" : "Also stop all agents")
                            .typography(.body)
                            .foregroundStyle(Theme.ink)
                    }
                    .tint(Theme.danger)
                    .padding(.horizontal, Metrics.Spacing.m)
                    .frame(minHeight: Metrics.minTapTarget + Metrics.Spacing.s)
                }
                if let error = model.actionError {
                    ErrorBanner(error, onDismiss: { model.dismissActionError() })
                }
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
                                .controlSize(.small)
                                .tint(Theme.onAccent)
                        }
                        Text(
                            stopAgents
                                ? (zh ? "下线并全部停止" : "Sign out and stop everything")
                                : (zh ? "下线其他设备" : "Sign out other devices"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.pill(.destructive))
                .disabled(model.isSigningOutOthers || app.isOffline)
            }
            .navigationTitle(zh ? "下线其他设备" : "Sign out others")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(zh ? "取消" : "Cancel") { dismiss() }
                }
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
