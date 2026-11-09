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

/// 登录设备页里电脑的整体状态（改版规范 4.9.9）：出错、这台设备签不了名、签名密钥失效（新录了面容）时一组说明，失效时可以
/// “生成新密钥”。每台电脑的配对和授权在它的设备详情里（`ComputerDeviceSections`）。都正常、也有电脑登录时不显示；
/// 还没有电脑登录这个账号时是一组“电脑”：怎么让电脑出现（`ComputerLinkText.noComputers`）+ 配对说明的脚注，不然没电脑的人
/// 在这页上找不到 12.9 的功能从哪儿开始。
struct ComputerLinkStatusSection: View {
    /// 设备列表里有没有电脑（`DeviceInfo.isComputer`）。
    let hasComputer: Bool

    var body: some View {
        ComputerLinkGate { model in
            ComputerLinkStatusContent(model: model, hasComputer: hasComputer)
        }
    }
}

private struct ComputerLinkStatusContent: View {
    let model: ComputerLinkModel
    let hasComputer: Bool

    @Environment(\.displayLanguage) private var language
    @State private var confirmsReset = false

    var body: some View {
        let zh = language == .chinese
        if model.error != nil || !model.canSign || model.needsRepair {
            Section {
                if let error = model.error {
                    Text(ComputerLinkText.error(error, language: language))
                        .foregroundStyle(StatusTone.failure.color)
                }
                if !model.canSign {
                    Text(ComputerLinkText.cannotSign(language))
                        .foregroundStyle(Theme.inkSecondary)
                }
                if model.needsRepair {
                    Text(ComputerLinkText.needsRepair(language))
                        .foregroundStyle(StatusTone.waiting.color)
                    Button(zh ? "生成新密钥" : "Create a new key") { confirmsReset = true }
                }
            } header: {
                Text(ComputerLinkText.sectionTitle(language)).groupHeader()
            }
            .themedRow()
            .confirmationDialog(
                zh ? "生成新密钥？" : "Create a new key?", isPresented: $confirmsReset, titleVisibility: .visible
            ) {
                Button(zh ? "生成并忘掉所有配对" : "Create and forget pairings", role: .destructive) {
                    Task { await model.resetKey() }
                }
                Button(zh ? "取消" : "Cancel", role: .cancel) {}
            }
        } else if !hasComputer {
            Section {
                Text(ComputerLinkText.noComputers(language))
                    .foregroundStyle(Theme.inkSecondary)
            } header: {
                Text(ComputerLinkText.sectionTitle(language)).groupHeader()
            } footer: {
                Text(ComputerLinkText.sectionFooter(language))
            }
            .themedRow()
        }
    }
}

/// 电脑的设备详情里“在这台电脑上执行”一组（参考 69 的位置；ThinkTin 是配对和授权，12.9）：配对状态；没配对时“配对”，配对了
/// 有“授权目录和应用”、现有的授权（左滑吊销）、“重新配对”和红字“解除配对”。参考的“始终允许 / 每次询问 / 从不允许”三档不做
/// （规范 6.20：高危操作不能预授权）。只在能签名的设备上有（`ComputerLinkGate`）。
struct ComputerDeviceSections: View {
    let computer: DeviceInfo

    var body: some View {
        ComputerLinkGate { model in
            ComputerDeviceContent(model: model, computer: computer)
        }
    }
}

private struct ComputerDeviceContent: View {
    let model: ComputerLinkModel
    let computer: DeviceInfo

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language
    @State private var pairing: DeviceInfo?
    @State private var granting: DeviceInfo?
    @State private var confirmsUnpair = false

    var body: some View {
        let zh = language == .chinese
        let paired = model.paired(computer.id)
        let now = Date()
        Section {
            LabeledContent(
                zh ? "配对" : "Pairing",
                value: paired.map { ComputerLinkText.paired($0.pairedAt, now: now, language: language) }
                    ?? ComputerLinkText.notPaired(language))
            if paired == nil {
                Button(zh ? "配对这台电脑" : "Pair this computer") { pairing = computer }
                    .disabled(!model.canSign || app.isOffline)
            } else {
                ForEach(model.activeGrants(for: computer.id)) { issued in
                    VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                        Text(ComputerLinkText.grantSummary(issued.grant, language: language))
                            .foregroundStyle(Theme.ink)
                        Text(ComputerLinkText.expires(issued.grant.expiresAt, now: now, language: language))
                            .font(.subheadline)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(zh ? "吊销" : "Revoke", role: .destructive) {
                            Task { await model.revoke(issued) }
                        }
                        .disabled(app.isOffline)
                    }
                    .contextMenu {
                        Button(zh ? "吊销" : "Revoke", systemImage: "xmark.circle", role: .destructive) {
                            Task { await model.revoke(issued) }
                        }
                        .disabled(app.isOffline)
                    }
                }
                Button(zh ? "授权目录和应用" : "Grant access") { granting = computer }
                    .disabled(app.isOffline)
                Button(zh ? "重新配对" : "Pair again") { pairing = computer }
                    .disabled(!model.canSign || app.isOffline)
                Button(zh ? "解除配对" : "Unpair", role: .destructive) { confirmsUnpair = true }
                    .foregroundStyle(Theme.danger)
            }
        } header: {
            Text(zh ? "在这台电脑上执行" : "Running on this computer").groupHeader()
        } footer: {
            Text(ComputerLinkText.sectionFooter(language))
        }
        .themedRow()
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
            zh ? "解除配对？" : "Unpair this computer?", isPresented: $confirmsUnpair, titleVisibility: .visible
        ) {
            Button(zh ? "解除配对" : "Unpair", role: .destructive) { Task { await model.unpair(computer.id) } }
            Button(zh ? "取消" : "Cancel", role: .cancel) {}
        } message: {
            Text(
                zh
                    ? "发给这台电脑的授权会一起吊销。电脑上也要解除配对。"
                    : "Access granted to this computer is revoked too. Unpair on the computer as well.")
        }
    }
}

/// 系统相机扫了电脑上的二维码（`thinktin-pair:` 深链，`.pairComputer`）：还不知道是哪台电脑，配对码已经填好。
struct PairComputerRoute: View {
    let code: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ComputerLinkGate { model in
            PairComputerSheet(model: model, computer: nil, initialCode: code) { dismiss() }
        }
    }
}

/// 配对一台电脑：扫码（或粘贴配对码）→ 面容 ID 签名 → 等电脑确认。`computer` 为 nil 是从深链来的。
struct PairComputerSheet: View {
    let model: ComputerLinkModel
    let computer: DeviceInfo?
    let onClose: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language
    @Environment(\.pairingScanner) private var scanner
    @State private var code: String
    @State private var finished = false
    /// 发出配对回复的那台电脑（配码里的）：等到它的确认才算配好。
    @State private var pairingID: DeviceID?

    init(
        model: ComputerLinkModel, computer: DeviceInfo?, initialCode: String = "",
        onClose: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.computer = computer
        self.onClose = onClose
        _code = State(initialValue: initialCode)
    }

    /// 标题、签名说明里的电脑名字。
    private var computerName: String {
        computer?.name ?? pairingID.flatMap { model.name(of: $0) } ?? (language == .chinese ? "电脑" : "computer")
    }

    var body: some View {
        let zh = language == .chinese
        Form {
            if finished, let id = pairingID ?? computer?.id, model.paired(id) != nil, !model.isPairing {
                Section {
                    Label(zh ? "配对好了" : "Paired", systemImage: "checkmark.circle.fill")
                        .typography(.headline)
                        .foregroundStyle(StatusTone.success.color)
                } footer: {
                    Text(ComputerLinkText.pairInstructions(language))
                }
                .themedRow()
            } else if model.isPairing {
                Section {
                    HStack(spacing: Metrics.Spacing.s) {
                        ProgressView()
                        Text(ComputerLinkText.waitingForConfirmation(language))
                            .typography(.body)
                            .foregroundStyle(Theme.ink)
                    }
                    Button(zh ? "不等了" : "Stop waiting", role: .destructive) {
                        model.cancelPairing()
                    }
                }
                .themedRow()
            } else {
                if let scanner {
                    Section {
                        scanner.make { scanned in
                            code = scanned
                            submit()
                        }
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
                        .clearListRow()
                    }
                }
                Section {
                    FormTextField(
                        title: zh ? "配对码" : "Pairing code", text: $code, prompt: "thinktin-pair:v1?…",
                        monospaced: true)
                } footer: {
                    if let error = model.error {
                        Text(ComputerLinkText.error(error, language: language))
                            .foregroundStyle(StatusTone.failure.color)
                    } else {
                        Text(ComputerLinkText.pairInstructions(language))
                    }
                }
                .themedRow()
            }
        }
        .formStyle(.grouped)
        .themedGroupedBackground()
        .floatingBar(edge: .bottom) {
            if !model.isPairing, !finished {
                Button {
                    submit()
                } label: {
                    Label(zh ? "配对" : "Pair", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .glassButtonStyle(.prominent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .padding(.horizontal, Metrics.Spacing.m)
                .padding(.bottom, Metrics.Spacing.xs)
                .disabled(
                    code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking
                        || !model.hasLoaded)
            }
        }
        .navigationTitle(
            computer.map { zh ? "配对“\($0.name)”" : "Pair “\($0.name)”" } ?? (zh ? "配对电脑" : "Pair a computer")
        )
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                CloseButton { onClose() }
            }
        }
    }

    private func submit() {
        let reason = ComputerLinkText.signReason(.pair, computer: computerName, language: language)
        Task {
            guard await model.pair(code: code, reason: reason) else { return }
            pairingID = model.state.pending?.offer.desktopID
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
        Form {
            Section {
                FormTextField(
                    title: zh ? "目录（一行一个，完整路径）" : "Folders (one per line, full path)", text: $dirs,
                    prompt: "/Users/me/Documents", multiline: true, monospaced: true)
                FormTextField(
                    title: zh ? "应用（一行一个 bundle id）" : "Apps (one bundle ID per line)", text: $apps,
                    prompt: "com.apple.Safari", multiline: true, monospaced: true)
            } footer: {
                Text(
                    zh
                        ? "Botin 在这台电脑上看文件、写文件、打开应用这类普通操作，只能碰你在这里给的目录和应用，到期自动失效。删除、执行命令这类高危操作每次都要你批准。"
                        : "Routine actions on this computer (reading or writing files, opening apps) can only touch the folders and apps you grant here, until it expires. Risky actions like deleting or running commands always need your approval."
                )
            }
            .themedRow()
            Section {
                Picker(zh ? "有效期" : "Expires after", selection: $duration) {
                    ForEach(CapabilityRules.durations, id: \.self) { option in
                        Text(ComputerLinkText.duration(option, language: language)).tag(option)
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                if let error = model.error {
                    Text(ComputerLinkText.error(error, language: language))
                        .foregroundStyle(StatusTone.failure.color)
                }
            }
            .themedRow()
        }
        .formStyle(.grouped)
        .themedGroupedBackground()
        .navigationTitle(zh ? "给“\(computer.name)”授权" : "Grant access to “\(computer.name)”")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                CloseButton { onClose() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ConfirmButton(zh ? "签名授权" : "Sign", isWorking: model.isWorking) {
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
            }
        }
    }
}

/// 审批中心里电脑发来的高危操作，是审批中心列表里的一组（“电脑上的操作”）：每条一行，电脑名和剩余时间、说明（AI 生成）、
/// 工具、参数，拒绝 / 批准两个玻璃胶囊（都要面容 ID 签名）。没有时不显示。
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
            Section {
                ForEach(model.pendingRequests) { request in
                    requestRow(request)
                }
            } header: {
                Text(zh ? "电脑上的操作" : "On your computer").groupHeader()
            } footer: {
                if let error = model.error {
                    Text(ComputerLinkText.error(error, language: language))
                        .foregroundStyle(StatusTone.failure.color)
                }
            }
            .themedRow()
        }
    }

    private func requestRow(_ request: ComputerApprovalRequest) -> some View {
        let zh = language == .chinese
        let computer = model.name(of: request.desktopID) ?? (zh ? "电脑" : "Computer")
        return VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            HStack(spacing: Metrics.Spacing.xs) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(Theme.inkSecondary)
                    .accessibilityHidden(true)
                Text(computer)
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                Spacer(minLength: 0)
                Text(ComputerLinkText.expires(request.expiresAt, now: Date(), language: language))
                    .typography(.caption)
                    .foregroundStyle(Theme.warning)
            }
            Text(ComputerLinkText.approvalDescription(request, language: language))
                .typography(.headline)
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
                Button {
                    decide(request, approve: false, computer: computer)
                } label: {
                    Label(zh ? "拒绝" : "Reject", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .glassButtonStyle()
                Button {
                    decide(request, approve: true, computer: computer)
                } label: {
                    Label(zh ? "批准" : "Approve", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .glassButtonStyle(.prominent)
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .padding(.top, Metrics.Spacing.xxs)
            .disabled(model.isWorking || app.isOffline)
        }
        .padding(.vertical, Metrics.Spacing.xxs)
    }

    private func decide(_ request: ComputerApprovalRequest, approve: Bool, computer: String) {
        let reason = ComputerLinkText.signReason(approve ? .approve : .reject, computer: computer, language: language)
        Task {
            _ = await model.decide(request, approve: approve, reason: reason)
            // 审批的角标也数电脑发来的。
            await app.refreshBadges()
        }
    }
}
