import SwiftUI
import ThinktinKit

// 手机控制电脑（WBS 12.9）：登录设备页里的“电脑”一组（配对、授权、解除配对），审批中心里电脑发来的高危操作。
// 签名密钥和 client-core 的编码由 App 注入（`\.deviceSigner`、`\.pairingCodec`）；没注入时（预览、macOS）不显示。

private struct DeviceSignerKey: EnvironmentKey {
    static let defaultValue: (any DeviceSigner)? = nil
}

private struct PairingCodecKey: EnvironmentKey {
    static let defaultValue: (any PairingCodec)? = nil
}

/// 扫配对二维码的视图（App 用 VisionKit 实现）：扫到内容时回调。没有时只能粘贴配对码。
public struct PairingScanner: Sendable {
    public let make: @MainActor @Sendable (_ onCode: @escaping @MainActor (String) -> Void) -> AnyView

    public init(make: @escaping @MainActor @Sendable (_ onCode: @escaping @MainActor (String) -> Void) -> AnyView) {
        self.make = make
    }
}

private struct PairingScannerKey: EnvironmentKey {
    static let defaultValue: PairingScanner? = nil
}

extension EnvironmentValues {
    /// 安全芯片里的签名密钥（12.9）；nil 是这台设备不支持（预览、macOS），电脑相关的界面不显示。
    public var deviceSigner: (any DeviceSigner)? {
        get { self[DeviceSignerKey.self] }
        set { self[DeviceSignerKey.self] = newValue }
    }

    /// client-core 的配对与验签（12.9）。
    public var pairingCodec: (any PairingCodec)? {
        get { self[PairingCodecKey.self] }
        set { self[PairingCodecKey.self] = newValue }
    }

    /// 扫配对二维码（12.9）；nil 时只能粘贴配对码。
    public var pairingScanner: PairingScanner? {
        get { self[PairingScannerKey.self] }
        set { self[PairingScannerKey.self] = newValue }
    }
}

/// 建 `ComputerLinkModel` 要的东西都在环境里时才显示内容。
struct ComputerLinkGate<Content: View>: View {
    @ViewBuilder let content: (ComputerLinkModel) -> Content

    @Environment(\.client) private var client
    @Environment(\.deviceSigner) private var signer
    @Environment(\.pairingCodec) private var codec
    @Environment(AppModel.self) private var app

    var body: some View {
        if let signer, let codec, let user = app.user {
            ComputerLinkHolder(
                model: ComputerLinkModel(client: client, codec: codec, signer: signer, userID: user.id),
                content: content)
        }
    }
}

private struct ComputerLinkHolder<Content: View>: View {
    @State private var model: ComputerLinkModel
    let content: (ComputerLinkModel) -> Content

    init(model: ComputerLinkModel, content: @escaping (ComputerLinkModel) -> Content) {
        _model = State(initialValue: model)
        self.content = content
    }

    var body: some View {
        content(model)
            .task { await model.load() }
    }
}

/// 登录设备页里的“电脑”一组：每台电脑的配对状态、在线状态；配对、授权（能力令牌）、吊销、解除配对。
struct ComputerLinkSection: View {
    var body: some View {
        ComputerLinkGate { model in
            ComputerLinkSectionContent(model: model)
        }
    }
}

private struct ComputerLinkSectionContent: View {
    let model: ComputerLinkModel

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language
    @State private var pairing: DeviceInfo?
    @State private var granting: DeviceInfo?
    @State private var confirmsUnpair: DeviceInfo?
    @State private var confirmsReset = false

    var body: some View {
        let zh = language == .chinese
        AccountSection(ComputerLinkText.sectionTitle(language), footer: ComputerLinkText.sectionFooter(language)) {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                if let error = model.error {
                    Text(ComputerLinkText.error(error, language: language))
                        .typography(.footnote)
                        .foregroundStyle(StatusTone.failure.color)
                }
                if !model.canSign {
                    Text(ComputerLinkText.cannotSign(language))
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                }
                if model.needsRepair {
                    Text(ComputerLinkText.needsRepair(language))
                        .typography(.footnote)
                        .foregroundStyle(StatusTone.waiting.color)
                    PillButton(zh ? "生成新密钥" : "Create a new key", kind: .secondary, size: .compact) {
                        confirmsReset = true
                    }
                }
                if model.hasLoaded && model.computers.isEmpty {
                    Text(ComputerLinkText.noComputers(language))
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                }
                ForEach(model.computers) { computer in
                    computerRow(computer)
                }
            }
            .padding(Metrics.Spacing.m)
        }
        .sheet(item: $pairing) { computer in
            NavigationStack {
                PairComputerSheet(model: model, computer: computer) { pairing = nil }
            }
        }
        .sheet(item: $granting) { computer in
            NavigationStack {
                GrantEditorSheet(model: model, computer: computer) { granting = nil }
            }
        }
        .confirmationDialog(
            zh ? "解除配对？" : "Unpair this computer?",
            isPresented: Binding(get: { confirmsUnpair != nil }, set: { if !$0 { confirmsUnpair = nil } }),
            titleVisibility: .visible, presenting: confirmsUnpair
        ) { computer in
            Button(zh ? "解除配对" : "Unpair", role: .destructive) { Task { await model.unpair(computer.id) } }
            Button(zh ? "取消" : "Cancel", role: .cancel) {}
        } message: { _ in
            Text(
                zh
                    ? "发给这台电脑的授权会一起吊销。电脑上也要解除配对。"
                    : "Access granted to this computer is revoked too. Unpair on the computer as well.")
        }
        .confirmationDialog(
            zh ? "生成新密钥？" : "Create a new key?", isPresented: $confirmsReset, titleVisibility: .visible
        ) {
            Button(zh ? "生成并忘掉所有配对" : "Create and forget pairings", role: .destructive) {
                Task { await model.resetKey() }
            }
            Button(zh ? "取消" : "Cancel", role: .cancel) {}
        }
    }

    private func computerRow(_ computer: DeviceInfo) -> some View {
        let zh = language == .chinese
        let paired = model.paired(computer.id)
        let now = Date()
        return VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            HStack(spacing: Metrics.Spacing.s) {
                Image(systemName: "desktopcomputer")
                    .typography(.title3)
                    .foregroundStyle(Theme.inkSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    Text(computer.name)
                        .typography(.body)
                        .foregroundStyle(Theme.ink)
                    Text(
                        [
                            ComputerLinkText.online(computer.isOnline, language: language),
                            paired.map { ComputerLinkText.paired($0.pairedAt, now: now, language: language) }
                                ?? ComputerLinkText.notPaired(language),
                        ].joined(separator: " · ")
                    )
                    .typography(.caption)
                    .foregroundStyle(Theme.inkSecondary)
                }
                Spacer(minLength: 0)
                if paired == nil {
                    PillButton(zh ? "配对" : "Pair", kind: .primary, size: .compact) { pairing = computer }
                        .disabled(!model.canSign || app.isOffline)
                } else {
                    Menu {
                        Button(zh ? "授权目录和应用" : "Grant access") { granting = computer }
                        Button(zh ? "重新配对" : "Pair again") { pairing = computer }
                        Button(zh ? "解除配对" : "Unpair", role: .destructive) { confirmsUnpair = computer }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .typography(.title3)
                            .foregroundStyle(Theme.accent)
                    }
                    .accessibilityLabel(Text(zh ? "更多操作" : "More actions"))
                }
            }
            if paired != nil {
                ForEach(model.activeGrants(for: computer.id)) { issued in
                    HStack(alignment: .top, spacing: Metrics.Spacing.s) {
                        VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                            Text(ComputerLinkText.grantSummary(issued.grant, language: language))
                                .typography(.footnote)
                                .foregroundStyle(Theme.ink)
                            Text(ComputerLinkText.expires(issued.grant.expiresAt, now: now, language: language))
                                .typography(.caption)
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        Spacer(minLength: 0)
                        Button(zh ? "吊销" : "Revoke") { Task { await model.revoke(issued) } }
                            .typography(.footnote)
                            .foregroundStyle(StatusTone.failure.color)
                            .buttonStyle(.plain)
                            .disabled(app.isOffline)
                    }
                    .padding(.leading, Metrics.Spacing.xl)
                }
            }
        }
    }
}

/// 配对一台电脑：扫码（或粘贴配对码）→ 面容 ID 签名 → 等电脑确认。
struct PairComputerSheet: View {
    let model: ComputerLinkModel
    let computer: DeviceInfo
    let onClose: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language
    @Environment(\.pairingScanner) private var scanner
    @State private var code = ""
    @State private var finished = false

    var body: some View {
        let zh = language == .chinese
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.m) {
                Text(ComputerLinkText.pairInstructions(language))
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                if finished, model.paired(computer.id) != nil, !model.isPairing {
                    Label(zh ? "配对好了" : "Paired", systemImage: "checkmark.circle.fill")
                        .typography(.headline)
                        .foregroundStyle(StatusTone.success.color)
                } else if model.isPairing {
                    HStack(spacing: Metrics.Spacing.s) {
                        ProgressView()
                        Text(ComputerLinkText.waitingForConfirmation(language))
                            .typography(.subheadline)
                            .foregroundStyle(Theme.ink)
                    }
                    PillButton(zh ? "不等了" : "Stop waiting", kind: .secondary, size: .compact) {
                        model.cancelPairing()
                    }
                } else {
                    if let scanner {
                        scanner.make { scanned in
                            code = scanned
                            submit()
                        }
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
                    }
                    PlansTextField(
                        title: zh ? "配对码" : "Pairing code", text: $code, prompt: "thinktin-pair:v1?…", monospaced: true)
                    if let error = model.error {
                        Text(ComputerLinkText.error(error, language: language))
                            .typography(.footnote)
                            .foregroundStyle(StatusTone.failure.color)
                    }
                    PillButton(zh ? "配对" : "Pair", systemImage: "link") { submit() }
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
                }
            }
            .padding(Metrics.Spacing.m)
        }
        .background(Theme.paper)
        .navigationTitle(zh ? "配对“\(computer.name)”" : "Pair “\(computer.name)”")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(zh ? "完成" : "Done") { onClose() }
            }
        }
    }

    private func submit() {
        let reason = ComputerLinkText.signReason(.pair, computer: computer.name, language: language)
        Task {
            guard await model.pair(code: code, reason: reason) else { return }
            await model.awaitConfirmation()
            finished = true
        }
    }
}

/// 给配好的电脑授权：能碰的目录、应用（一行一个）和有效期，签名发过去。
struct GrantEditorSheet: View {
    let model: ComputerLinkModel
    let computer: DeviceInfo
    let onClose: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language
    @State private var dirs = ""
    @State private var apps = ""
    @State private var duration = CapabilityRules.durations[1]

    var body: some View {
        let zh = language == .chinese
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.m) {
                Text(
                    zh
                        ? "agent 在这台电脑上看文件、写文件、打开应用这类普通操作，只能碰你在这里给的目录和应用，到期自动失效。删除、执行命令这类高危操作每次都要你批准。"
                        : "Routine actions on this computer (reading or writing files, opening apps) can only touch the folders and apps you grant here, until it expires. Risky actions like deleting or running commands always need your approval."
                )
                .typography(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
                PlansTextField(
                    title: zh ? "目录（一行一个，完整路径）" : "Folders (one per line, full path)", text: $dirs,
                    prompt: "/Users/me/Documents", multiline: true, monospaced: true)
                PlansTextField(
                    title: zh ? "应用（一行一个 bundle id）" : "Apps (one bundle ID per line)", text: $apps,
                    prompt: "com.apple.Safari", multiline: true, monospaced: true)
                Text(zh ? "有效期" : "Expires after")
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                HStack(spacing: Metrics.Spacing.xs) {
                    ForEach(CapabilityRules.durations, id: \.self) { option in
                        Button(ComputerLinkText.duration(option, language: language)) { duration = option }
                            .buttonStyle(.pill(option == duration ? .primary : .secondary, size: .compact))
                    }
                }
                if let error = model.error {
                    Text(ComputerLinkText.error(error, language: language))
                        .typography(.footnote)
                        .foregroundStyle(StatusTone.failure.color)
                }
            }
            .padding(Metrics.Spacing.m)
        }
        .background(Theme.paper)
        .navigationTitle(zh ? "给“\(computer.name)”授权" : "Grant access to “\(computer.name)”")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(zh ? "取消" : "Cancel") { onClose() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(zh ? "签名授权" : "Sign") {
                    let reason = ComputerLinkText.signReason(.grant, computer: computer.name, language: language)
                    Task {
                        let lines = { (text: String) in text.split(whereSeparator: \.isNewline).map(String.init) }
                        if await model.issueGrant(
                            to: computer.id, dirs: lines(dirs), apps: lines(apps), duration: duration, reason: reason)
                            != nil
                        {
                            onClose()
                        }
                    }
                }
                .disabled(model.isWorking)
            }
        }
    }
}

/// 审批中心里电脑发来的高危操作：说明（AI 生成）、工具、参数，批准 / 拒绝（都要面容 ID 签名）。
struct ComputerApprovalsSection: View {
    var body: some View {
        ComputerLinkGate { model in
            ComputerApprovalsContent(model: model)
        }
    }
}

private struct ComputerApprovalsContent: View {
    let model: ComputerLinkModel

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        if !model.pendingRequests.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                SectionHeader(title: zh ? "电脑上的操作" : "On your computer")
                if let error = model.error {
                    Text(ComputerLinkText.error(error, language: language))
                        .typography(.footnote)
                        .foregroundStyle(StatusTone.failure.color)
                }
                ForEach(model.pendingRequests) { request in
                    requestCard(request)
                }
            }
        }
    }

    private func requestCard(_ request: ComputerApprovalRequest) -> some View {
        let zh = language == .chinese
        let computer = model.name(of: request.desktopID) ?? (zh ? "电脑" : "Computer")
        return Card {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                HStack(spacing: Metrics.Spacing.xs) {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(Theme.inkSecondary)
                        .accessibilityHidden(true)
                    Text(computer)
                        .typography(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                    Spacer(minLength: 0)
                    Text(ComputerLinkText.expires(request.expiresAt, now: Date(), language: language))
                        .typography(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
                Text(request.summary)
                    .typography(.body)
                    .foregroundStyle(Theme.ink)
                AIGeneratedLabel()
                Text(request.tool)
                    .font(Typography.footnote.monospacedFont)
                    .foregroundStyle(Theme.inkSecondary)
                Text(JSONValue.parse(request.argumentsJSON)?.prettyPrinted() ?? request.argumentsJSON)
                    .font(Typography.caption.monospacedFont)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(8)
                HStack(spacing: Metrics.Spacing.s) {
                    PillButton(zh ? "拒绝" : "Reject", kind: .secondary, size: .compact) {
                        decide(request, approve: false, computer: computer)
                    }
                    PillButton(zh ? "批准" : "Approve", kind: .primary, size: .compact) {
                        decide(request, approve: true, computer: computer)
                    }
                }
                .disabled(model.isWorking || app.isOffline)
            }
        }
    }

    private func decide(_ request: ComputerApprovalRequest, approve: Bool, computer: String) {
        let reason = ComputerLinkText.signReason(approve ? .approve : .reject, computer: computer, language: language)
        Task { await model.decide(request, approve: approve, reason: reason) }
    }
}
