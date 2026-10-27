import Foundation
import Testing
import ThinktinKit

@testable import ThinktinCoreAdapter

/// 配对与验签（12.9）经真实的 client-core：和 `crates/client-core/src/pairing/tests.rs` 同一批测试向量
/// （OpenSSL 独立生成），看转换没丢东西、签的字节对得上。
@Suite("配对与验签（经真实核心）")
struct PairingCodecTests {
    let codec = CorePairingCodec()
    static let phoneKey = "A3ZBMie_HDnUDgWOHXgN_KgD1WVDY2JGkisQVOaV2ztZ"
    static let desktopKey =
        "BHGPuO3emZZPoXZt1QKaW_v0vTGoCGWqM-dmhYZVc_9ziHw6tD4C6tX9UofXGOOguvAbH7jebXfPeeYP8l568Ps"
    static let nonce = "AAECAwQFBgcICQoLDA0ODw"
    static let confirmDER = Data([
        0x30, 0x44, 0x02, 0x20, 0x0f, 0x92, 0x5e, 0x83, 0xfd, 0x16, 0xcc, 0xa4, 0x0f, 0x39, 0xae, 0x0b,
        0xb6, 0x70, 0x2c, 0x0d, 0x6b, 0x5c, 0x32, 0xbe, 0x6a, 0x3b, 0xc0, 0x08, 0xcb, 0x3f, 0xc8, 0x72,
        0x81, 0x91, 0x1d, 0xbc, 0x02, 0x20, 0x21, 0x3f, 0x97, 0x6a, 0xce, 0xfc, 0xdb, 0xef, 0xd7, 0x76,
        0xf1, 0x55, 0xa1, 0x63, 0x00, 0x41, 0x3e, 0x45, 0x27, 0xd0, 0x8a, 0x5d, 0x30, 0x3d, 0x93, 0x8c,
        0x7e, 0xa1, 0x27, 0x93, 0x43, 0x5a,
    ])

    func offer(expiresIn seconds: TimeInterval = 300) -> PairingOffer {
        PairingOffer(
            desktopID: "mac-1", desktopKey: Self.desktopKey, nonce: Self.nonce,
            expiresAt: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + seconds).rounded(.down)))
    }

    @Test("审批要签的字节和独立实现一致")
    func approvalMessage() throws {
        let request = ComputerApprovalRequest(
            desktopID: "mac-1", requestID: "req-42", tool: "delete_files",
            argumentsJSON: #"{"recursive":1,"paths":["/Users/me/old.log","/Users/me/tmp"],"note":"清理\n旧文件"}"#,
            summary: "删除 2 个文件", issuedAt: Date(timeIntervalSince1970: 1_760_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_760_000_600))
        let message = try codec.approvalMessage(request, approve: true)
        #expect(
            String(decoding: message, as: UTF8.self)
                == "thinktin-approval-v1\ndesktop:mac-1\nrequest:req-42\ntool:delete_files\nargs-sha256:812063d33eea6eecb5b080fe8cf105b13725d48b04a57d198dd25781b9d48ce2\nsummary-sha256:4c33c19418c5481ea2fc3897035d3d724c56fbd6fdca1624d8e9132ab5100463\nissued:1760000000\nexpires:1760000600\ndecision:approve\n"
        )
        // 拒绝签的字节不一样。
        #expect(try codec.approvalMessage(request, approve: false) != message)
    }

    @Test("二维码往返；电脑的确认用二维码里的公钥验，别的签名不行")
    func pairing() throws {
        let uri = try ThinktinCoreAdapter.pairingOfferURIForTesting(offer())
        let parsed = try codec.parseOffer(uri)
        #expect(parsed.desktopID == "mac-1")
        #expect(parsed.desktopKey == Self.desktopKey)
        #expect(parsed.nonce == Self.nonce)
        #expect(parsed == offer())

        try codec.verifyConfirmation(
            offer: parsed, phoneID: "iphone-7", phoneKey: Self.phoneKey, signature: Self.confirmDER)
        #expect(throws: PairingCodecError.badSignature) {
            try codec.verifyConfirmation(
                offer: parsed, phoneID: "iphone-8", phoneKey: Self.phoneKey, signature: Self.confirmDER)
        }
        let response = try codec.responseMessage(offer: parsed, phoneID: "iphone-7", phoneKey: Self.phoneKey)
        #expect(String(decoding: response, as: UTF8.self).hasPrefix("thinktin-pair-response-v1\n"))

        #expect(throws: PairingCodecError.expired) {
            try codec.parseOffer(try ThinktinCoreAdapter.pairingOfferURIForTesting(offer(expiresIn: -3600)))
        }
        #expect(throws: (any Error).self) { try codec.parseOffer("https://example.com") }
    }

    @Test("能力令牌要签的字节；公钥编码查格式")
    func capabilityAndKeys() throws {
        let grant = CapabilityGrant(
            desktopID: "mac-1", tokenID: "tok-1", dirs: ["/Users/me/Documents"], apps: ["com.apple.Safari"],
            expiresAt: Date(timeIntervalSince1970: 1_760_003_600))
        let message = String(decoding: try codec.capabilityMessage(grant), as: UTF8.self)
        #expect(message.hasPrefix("thinktin-capability-v1\n"))
        #expect(message.contains("tok-1"))

        let compressed = try #require(PairingEncoding.data(base64url: Self.phoneKey))
        #expect(try codec.encodePublicKey(compressed) == Self.phoneKey)
        #expect(throws: (any Error).self) { try codec.encodePublicKey(Data(repeating: 1, count: 33)) }
    }
}
