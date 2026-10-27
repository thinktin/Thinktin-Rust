import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 手机控制电脑（WBS 12.9）的界面：登录设备里的“电脑”一组、配对页、授权页、审批中心里的电脑请求，浅色中文、
/// 深色英文都能布局；没注入签名密钥时不显示。逻辑在 ThinktinKitTests/Computer 里测。
@MainActor
@Suite("电脑配对与审批的界面")
struct ComputerLinkScreensTests {
    private struct Codec: PairingCodec {
        func parseOffer(_ uri: String) throws(PairingCodecError) -> PairingOffer { throw .malformed("test") }
        func responseMessage(offer: PairingOffer, phoneID: DeviceID, phoneKey: String) throws(PairingCodecError) -> Data
        {
            Data()
        }
        func verifyConfirmation(offer: PairingOffer, phoneID: DeviceID, phoneKey: String, signature: Data)
            throws(PairingCodecError)
        {}
        func approvalMessage(_ request: ComputerApprovalRequest, approve: Bool) throws(PairingCodecError) -> Data {
            Data()
        }
        func capabilityMessage(_ grant: CapabilityGrant) throws(PairingCodecError) -> Data { Data() }
        func encodePublicKey(_ sec1: Data) throws(PairingCodecError) -> String { "key" }
    }

    private struct Signer: DeviceSigner {
        var available = true
        func isAvailable() async -> Bool { available }
        func publicKey() async throws(DeviceSignerError) -> Data { Data([1]) }
        func sign(_ message: Data, reason: String) async throws(DeviceSignerError) -> Data { Data([2]) }
        func resetKey() async {}
    }

    private func layoutBoth(_ view: some View, signer: Signer? = Signer()) {
        let client = ShellPreviewClients.signedIn()
        for (language, scheme) in [(DisplayLanguage.chinese, ColorScheme.light), (.english, .dark)] {
            hostAndLayout(
                view.environment(\.deviceSigner, signer).environment(\.pairingCodec, Codec())
                    .previewShell(language, scheme: scheme, client: client))
        }
    }

    @Test("登录设备里的“电脑”一组：能签名、不能签名、没注入")
    func section() {
        layoutBoth(AccountScrollPage { ComputerLinkSection() })
        layoutBoth(AccountScrollPage { ComputerLinkSection() }, signer: Signer(available: false))
        layoutBoth(AccountScrollPage { ComputerLinkSection() }, signer: nil)
        layoutBoth(DevicesScreen())
    }

    @Test("配对页、授权页、审批中心")
    func sheets() {
        let model = ComputerLinkModel(
            client: ShellPreviewClients.signedIn(), codec: Codec(), signer: Signer(), userID: DemoData.userID,
            defaults: nil)
        let mac = DeviceInfo(id: DemoData.macDeviceID, platform: .macos, name: "MacBook", createdAt: Date())
        layoutBoth(NavigationStack { PairComputerSheet(model: model, computer: mac) {} })
        layoutBoth(NavigationStack { GrantEditorSheet(model: model, computer: mac) {} })
        layoutBoth(ApprovalCenterScreen())
    }
}
