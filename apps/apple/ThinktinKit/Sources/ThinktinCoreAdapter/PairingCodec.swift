import Foundation
import ThinktinCore
import ThinktinKit

/// ThinktinKit 的 `PairingCodec`（WBS 12.9）：client-core 的配对与验签（`crates/client-core/src/pairing.rs`，
/// docs/pairing.md）。手机和电脑用同一份实现，签的字节一定一致；签名在 App 的安全芯片里做。
public struct CorePairingCodec: PairingCodec {
    public init() {}

    public func parseOffer(_ uri: String) throws(PairingCodecError) -> ThinktinKit.PairingOffer {
        let offer = try Self.run { try ThinktinCore.parsePairingOffer(uri: uri) }
        return ThinktinKit.PairingOffer(
            desktopID: DeviceID(offer.desktopId), desktopKey: offer.desktopKey, nonce: offer.nonce,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(offer.expiresAt)))
    }

    public func responseMessage(offer: ThinktinKit.PairingOffer, phoneID: DeviceID, phoneKey: String)
        throws(PairingCodecError) -> Data
    {
        try Self.run {
            try ThinktinCore.pairingResponseMessage(
                offer: Self.core(offer), phoneId: phoneID.rawValue, phoneKey: phoneKey)
        }
    }

    public func verifyConfirmation(
        offer: ThinktinKit.PairingOffer, phoneID: DeviceID, phoneKey: String, signature: Data
    ) throws(PairingCodecError) {
        try Self.run {
            try ThinktinCore.verifyPairingConfirmation(
                offer: Self.core(offer), phoneId: phoneID.rawValue, phoneKey: phoneKey, signature: signature)
        }
    }

    public func approvalMessage(_ request: ComputerApprovalRequest, approve: Bool) throws(PairingCodecError) -> Data {
        let core = ThinktinCore.ApprovalRequest(
            desktopId: request.desktopID.rawValue, requestId: request.requestID, tool: request.tool,
            argumentsJson: request.argumentsJSON, summary: request.summary, issuedAt: Self.seconds(request.issuedAt),
            expiresAt: Self.seconds(request.expiresAt))
        return try Self.run { try ThinktinCore.approvalMessage(request: core, approve: approve) }
    }

    public func capabilityMessage(_ grant: ThinktinKit.CapabilityGrant) throws(PairingCodecError) -> Data {
        let core = ThinktinCore.CapabilityGrant(
            desktopId: grant.desktopID.rawValue, tokenId: grant.tokenID, dirs: grant.dirs, apps: grant.apps,
            expiresAt: Self.seconds(grant.expiresAt))
        return try Self.run { try ThinktinCore.capabilityMessage(grant: core) }
    }

    public func encodePublicKey(_ sec1: Data) throws(PairingCodecError) -> String {
        try Self.run { try ThinktinCore.encodePublicKey(sec1: sec1) }
    }

    // MARK: 转换

    static func core(_ offer: ThinktinKit.PairingOffer) -> ThinktinCore.PairingOffer {
        ThinktinCore.PairingOffer(
            desktopId: offer.desktopID.rawValue, desktopKey: offer.desktopKey, nonce: offer.nonce,
            expiresAt: seconds(offer.expiresAt))
    }

    /// `Date` → Unix 秒（向下取整，和 client-core 一样）。
    static func seconds(_ date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970.rounded(.down)))
    }

    static func run<T>(_ body: () throws -> T) throws(PairingCodecError) -> T {
        do {
            return try body()
        } catch let error as ThinktinCore.PairingError {
            switch error {
            case .Malformed(let detail): throw .malformed(detail)
            case .Expired: throw .expired
            case .BadSignature: throw .badSignature
            }
        } catch {
            throw .malformed(String(describing: error))
        }
    }
}

/// 测试用：电脑那边生成的二维码内容（手机不需要生成）。
func pairingOfferURIForTesting(_ offer: ThinktinKit.PairingOffer) throws -> String {
    try ThinktinCore.pairingOfferUri(offer: CorePairingCodec.core(offer))
}
