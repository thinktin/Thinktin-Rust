import SwiftUI
import ThinktinKit

// Mac 菜单栏弹出的“手机控制”（WBS 14.5、14.6、14.8）：状态和开始 / 停止、配对二维码、配对的手机、手机给的授权、解除配对。
// 二维码的图由 App 画（`\.pairingCodeImage`，macOS 上用 CoreImage）；没有时显示配对码文字，可以复制。

/// 把配对码画成二维码。
public struct PairingCodeImage: Sendable {
    public let make: @MainActor @Sendable (_ code: String) -> Image?

    public init(make: @escaping @MainActor @Sendable (_ code: String) -> Image?) {
        self.make = make
    }
}

private struct PairingCodeImageKey: EnvironmentKey {
    static let defaultValue: PairingCodeImage? = nil
}

extension EnvironmentValues {
    /// 画配对二维码（14.8）；nil 时只显示配对码文字。
    public var pairingCodeImage: PairingCodeImage? {
        get { self[PairingCodeImageKey.self] }
        set { self[PairingCodeImageKey.self] = newValue }
    }
}

public struct ComputerHostPanel: View {
    private let model: ComputerHostModel

    @Environment(\.displayLanguage) private var language
    @Environment(\.pairingCodeImage) private var codeImage
    @State private var confirmsUnpair = false

    public init(model: ComputerHostModel) {
        self.model = model
    }

    public var body: some View {
        let zh = language == .chinese
        VStack(alignment: .leading, spacing: Metrics.Spacing.m) {
            header
            if let error = model.error {
                Text(ComputerHostText.error(error, language: language))
                    .typography(.footnote)
                    .foregroundStyle(StatusTone.failure.color)
            }
            Divider()
            pairingSection
            if model.phone != nil {
                Divider()
                grantsSection
                Button(zh ? "解除配对" : "Unpair", role: .destructive) { confirmsUnpair = true }
                    .typography(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(StatusTone.failure.color)
            }
        }
        .padding(Metrics.Spacing.m)
        .frame(width: 340, alignment: .leading)
        .background(Theme.paper)
        .task { await model.observe() }
        .confirmationDialog(
            zh ? "解除和手机的配对？" : "Unpair your phone?", isPresented: $confirmsUnpair, titleVisibility: .visible
        ) {
            Button(zh ? "解除配对" : "Unpair", role: .destructive) { model.unpair() }
            Button(zh ? "取消" : "Cancel", role: .cancel) {}
        } message: {
            Text(
                zh
                    ? "之后手机控制不了这台电脑，手机给的授权也作废。手机那边也要解除。"
                    : "Your phone can no longer control this Mac and its access ends. Unpair on the phone as well.")
        }
    }

    private var tone: StatusTone {
        if model.stopReason != nil { return .failure }
        if model.activeTool != nil { return .active }
        switch model.connection {
        case .offline: return .muted
        case .connecting: return .neutral
        case .connected: return model.phone == nil ? .waiting : .success
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            HStack(spacing: Metrics.Spacing.s) {
                Circle()
                    .fill(tone.color)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(ComputerHostText.title(language))
                    .typography(.headline)
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                PillButton(
                    ComputerHostText.toggle(isEnabled: model.isEnabled, language: language),
                    kind: model.isEnabled ? .secondary : .primary, size: .compact
                ) {
                    if model.isEnabled { model.stop() } else { model.start() }
                }
            }
            Text(ComputerHostText.status(model, language: language))
                .typography(.footnote)
                .foregroundStyle(model.stopReason == nil ? Theme.inkSecondary : StatusTone.failure.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var pairingSection: some View {
        let zh = language == .chinese
        VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            if let code = model.pairingCode {
                Text(ComputerHostText.pairInstructions(language))
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let image = codeImage?.make(code) {
                    image
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(Text(zh ? "配对二维码" : "Pairing QR code"))
                }
                Text(verbatim: code)
                    .font(Typography.caption.monospacedFont)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                PillButton(zh ? "取消" : "Cancel", kind: .secondary, size: .compact) { model.cancelPairing() }
            } else {
                if model.pairingExpired {
                    Text(ComputerHostText.pairExpired(language))
                        .typography(.footnote)
                        .foregroundStyle(StatusTone.waiting.color)
                } else if case .failed = model.pairing {
                    Text(ComputerHostText.pairingFailed(language))
                        .typography(.footnote)
                        .foregroundStyle(StatusTone.failure.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.phone != nil {
                    Label(
                        ComputerHostText.paired(name: model.phoneName, language: language),
                        systemImage: "iphone"
                    )
                    .typography(.subheadline)
                    .foregroundStyle(Theme.ink)
                }
                PillButton(
                    ComputerHostText.pairButton(hasPhone: model.phone != nil, language: language),
                    systemImage: "qrcode", kind: model.phone == nil ? .primary : .secondary, size: .compact
                ) {
                    model.startPairing()
                }
            }
        }
    }

    private var grantsSection: some View {
        let zh = language == .chinese
        let now = Date()
        return VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            Text(zh ? "手机给的授权" : "Access from your phone")
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityAddTraits(.isHeader)
            if model.activeGrants.isEmpty {
                Text(ComputerHostText.noGrants(language))
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.activeGrants, id: \.tokenID) { grant in
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    Text(ComputerLinkText.grantSummary(grant, language: language))
                        .typography(.footnote)
                        .foregroundStyle(Theme.ink)
                    Text(ComputerLinkText.expires(grant.expiresAt, now: now, language: language))
                        .typography(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

#Preview("手机控制 · 配好了") {
    let host = FakeComputerHost(
        phone: HostPhone(deviceID: DemoData.deviceID, publicKey: "k"),
        grants: [
            CapabilityGrant(
                desktopID: DemoData.macDeviceID, tokenID: "t1", dirs: ["/Users/me/Documents"],
                apps: ["com.apple.Safari"], expiresAt: Date().addingTimeInterval(8 * 3600))
        ])
    ComputerHostPanel(model: ComputerHostModel(host: host))
}

#Preview("手机控制 · 没配对 · 英文") {
    ComputerHostPanel(model: ComputerHostModel(host: FakeComputerHost()))
        .environment(\.displayLanguage, .english)
}
