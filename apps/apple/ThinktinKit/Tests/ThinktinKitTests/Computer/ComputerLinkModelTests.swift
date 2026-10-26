import Foundation
import Testing

@testable import ThinktinKit

/// 假的 client-core 编码：消息是可读的文本，电脑的签名是 `desktop:` 加消息。真的编码在 ThinktinCoreAdapterTests 里测。
private struct FakeCodec: PairingCodec {
    func parseOffer(_ uri: String) throws(PairingCodecError) -> PairingOffer {
        let parts = uri.split(separator: ":").map(String.init)
        guard parts.count == 4, parts[0] == "pair", let expires = Double(parts[3]) else {
            throw .malformed("pairing code")
        }
        let expiresAt = Date(timeIntervalSince1970: expires)
        guard expiresAt > Date() else { throw .expired }
        return PairingOffer(
            desktopID: DeviceID(parts[1]), desktopKey: "dk-\(parts[1])", nonce: parts[2], expiresAt: expiresAt)
    }

    func responseMessage(offer: PairingOffer, phoneID: DeviceID, phoneKey: String) throws(PairingCodecError) -> Data {
        Data("response|\(offer.desktopID.rawValue)|\(offer.nonce)|\(phoneID.rawValue)|\(phoneKey)".utf8)
    }

    func verifyConfirmation(offer: PairingOffer, phoneID: DeviceID, phoneKey: String, signature: Data)
        throws(PairingCodecError)
    {
        let expected = "desktop:confirm|\(offer.desktopKey)|\(offer.nonce)|\(phoneID.rawValue)|\(phoneKey)"
        guard signature == Data(expected.utf8) else { throw .badSignature }
    }

    func approvalMessage(_ request: ComputerApprovalRequest, approve: Bool) throws(PairingCodecError) -> Data {
        Data("approval|\(request.requestID)|\(approve)".utf8)
    }

    func capabilityMessage(_ grant: CapabilityGrant) throws(PairingCodecError) -> Data {
        Data("capability|\(grant.tokenID)|\(grant.dirs.joined(separator: ","))".utf8)
    }

    func encodePublicKey(_ sec1: Data) throws(PairingCodecError) -> String { PairingEncoding.base64url(sec1) }

    static func confirmation(offer: PairingOffer, phoneID: DeviceID, phoneKey: String) -> String {
        PairingEncoding.base64url(
            Data("desktop:confirm|\(offer.desktopKey)|\(offer.nonce)|\(phoneID.rawValue)|\(phoneKey)".utf8))
    }
}

/// 假的安全芯片：签名是 `signed:` 加消息。
private actor FakeSigner: DeviceSigner {
    var available = true
    var key = Data("phone-key-1".utf8)
    var failNext: DeviceSignerError?
    private(set) var reasons: [String] = []

    func setAvailable(_ value: Bool) { available = value }
    func setKey(_ value: Data) { key = value }
    func setFailNext(_ value: DeviceSignerError?) { failNext = value }

    func isAvailable() -> Bool { available }
    func publicKey() throws(DeviceSignerError) -> Data { key }

    func sign(_ message: Data, reason: String) throws(DeviceSignerError) -> Data {
        reasons.append(reason)
        if let failNext {
            self.failNext = nil
            throw failNext
        }
        return Data("signed:".utf8) + message
    }

    func resetKey() { key = Data("phone-key-2".utf8) }
}

private func makeDefaults() -> UserDefaults {
    let name = "computer-link-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
@Suite("手机控制电脑（12.9）")
struct ComputerLinkModelTests {
    private let phone = DemoData.deviceID
    private let mac = DemoData.macDeviceID
    private var phoneKey: String { PairingEncoding.base64url(Data("phone-key-1".utf8)) }

    private func code(_ desktop: DeviceID, nonce: String = "n1", expires: TimeInterval = 600) -> String {
        "pair:\(desktop.rawValue):\(nonce):\(Int(Date().timeIntervalSince1970 + expires))"
    }

    private func make(
        _ mock: MockClient = makeShellMock(), signer: FakeSigner = FakeSigner(), defaults: UserDefaults = makeDefaults()
    ) -> ComputerLinkModel {
        ComputerLinkModel(client: mock, codec: FakeCodec(), signer: signer, userID: DemoData.userID, defaults: defaults)
    }

    /// 电脑发一条消息给手机（直接放进 Mock 的状态）。
    private func deliver(_ mock: MockClient, kind: DeviceMessageKind, body: JSONValue) {
        mock.update { s in
            s.deviceMessages.append(
                DeviceMessage(
                    id: DeviceMessageID(UUID().uuidString.lowercased()), fromDeviceID: mac, toDeviceID: phone,
                    kind: kind,
                    bodyJSON: body.compactString(), createdAt: Date()))
        }
    }

    private func pairMac(_ model: ComputerLinkModel, _ mock: MockClient) async throws {
        #expect(await model.pair(code: code(mac), reason: "配对"))
        let offer = try #require(model.state.pending?.offer)
        deliver(
            mock, kind: .pairConfirm,
            body: [
                "nonce": "n1",
                "signature": .string(FakeCodec.confirmation(offer: offer, phoneID: phone, phoneKey: phoneKey)),
            ])
        await model.sync()
    }

    @Test("配对：签回复发给电脑，电脑确认后记下；消息收下就确认掉")
    func pairs() async throws {
        let mock = makeShellMock()
        let signer = FakeSigner()
        let model = make(mock, signer: signer)
        await model.load()
        #expect(model.computers.map(\.id) == [mac])
        #expect(model.canSign)

        #expect(await model.pair(code: code(mac), reason: "配对电脑"))
        #expect(model.isPairing)
        let sent = try #require(mock.state.deviceMessages.last)
        #expect(sent.kind == .pairResponse)
        #expect(sent.toDeviceID == mac)
        #expect(sent.body?["nonce"]?.stringValue == "n1")
        #expect(sent.body?["phone_key"]?.stringValue == phoneKey)
        let signature = try #require(sent.body?["signature"]?.stringValue.flatMap(PairingEncoding.data(base64url:)))
        #expect(
            String(decoding: signature, as: UTF8.self)
                == "signed:response|\(mac.rawValue)|n1|\(phone.rawValue)|\(phoneKey)")
        #expect(await signer.reasons == ["配对电脑"])

        // 别的随机数（旧邀请）的确认不算。
        deliver(mock, kind: .pairConfirm, body: ["nonce": "old", "signature": "eA"])
        await model.sync()
        #expect(model.isPairing)
        #expect(mock.state.deviceMessages.filter { $0.toDeviceID == phone }.isEmpty)

        let offer = try #require(model.state.pending?.offer)
        deliver(
            mock, kind: .pairConfirm,
            body: [
                "nonce": "n1",
                "signature": .string(FakeCodec.confirmation(offer: offer, phoneID: phone, phoneKey: phoneKey)),
            ])
        await model.sync()
        #expect(!model.isPairing)
        #expect(model.paired(mac)?.desktopKey == "dk-\(mac.rawValue)")
        #expect(model.error == nil)
    }

    @Test("配对出错：不是自己的电脑、码不对、过期、签名不对、用户取消验证")
    func pairingErrors() async throws {
        let mock = makeShellMock()
        let signer = FakeSigner()
        let model = make(mock, signer: signer)
        await model.load()
        #expect(!(await model.pair(code: code("0192f3a0-0000-7000-8000-0000000000ff"), reason: "")))
        #expect(model.error == .notYourComputer)
        #expect(!(await model.pair(code: "https://example.com", reason: "")))
        #expect(model.error == .pairing(.malformed("pairing code")))
        #expect(!(await model.pair(code: code(mac, expires: -60), reason: "")))
        #expect(model.error == .pairing(.expired))
        await signer.setFailNext(.cancelled)
        #expect(!(await model.pair(code: code(mac), reason: "")))
        #expect(model.error == .signer(.cancelled))
        #expect(!model.isPairing)

        #expect(await model.pair(code: code(mac), reason: ""))
        deliver(mock, kind: .pairConfirm, body: ["nonce": "n1", "signature": "Zm9yZ2Vk"])
        await model.sync()
        #expect(model.error == .pairing(.badSignature))
        #expect(!model.isPairing)
        #expect(model.paired(mac) == nil)
    }

    @Test("等确认：收到了就停；邀请过期了算失败")
    func awaitsConfirmation() async throws {
        let mock = makeShellMock()
        let model = make(mock)
        await model.load()
        #expect(await model.pair(code: code(mac, expires: 1), reason: ""))
        // 邀请 1 秒后过期，再过 5 分钟的时钟误差才算超时：把等的时间缩短，看循环在配好后停下。
        let offer = try #require(model.state.pending?.offer)
        let waiting = Task { await model.awaitConfirmation(interval: .milliseconds(10)) }
        deliver(
            mock, kind: .pairConfirm,
            body: [
                "nonce": "n1",
                "signature": .string(FakeCodec.confirmation(offer: offer, phoneID: phone, phoneKey: phoneKey)),
            ])
        await waiting.value
        #expect(model.paired(mac) != nil)

        // 过期：时间往后拨。
        var clock = Date()
        let late = ComputerLinkModel(
            client: mock, codec: FakeCodec(), signer: FakeSigner(), userID: DemoData.userID, defaults: makeDefaults(),
            now: { clock })
        await late.load()
        #expect(await late.pair(code: code(mac, nonce: "n2"), reason: ""))
        clock = clock.addingTimeInterval(20 * 60)
        await late.sync()
        #expect(!late.isPairing)
        #expect(late.error == .pairingTimedOut)
    }

    @Test("审批：只收配好的电脑发来的、没过期的；批准、拒绝都签名发回；存在本机")
    func approvals() async throws {
        let mock = makeShellMock()
        let defaults = makeDefaults()
        let model = make(mock, defaults: defaults)
        await model.load()

        func request(_ id: String, from desktop: DeviceID? = nil, expires: TimeInterval = 600) -> JSONValue {
            [
                "request": [
                    "desktop_id": .string((desktop ?? mac).rawValue), "request_id": .string(id),
                    "tool": "delete_files", "arguments_json": #"{"paths":["/tmp/a"]}"#,
                    "summary": "删除 /tmp/a", "issued_at": .number(Date().timeIntervalSince1970.rounded(.down)),
                    "expires_at": .number((Date().timeIntervalSince1970 + expires).rounded(.down)),
                ]
            ]
        }
        // 还没配对：不收。
        deliver(mock, kind: .approvalRequest, body: request("r0"))
        await model.sync()
        #expect(model.pendingRequests.isEmpty)

        try await pairMac(model, mock)
        deliver(mock, kind: .approvalRequest, body: request("r1"))
        deliver(mock, kind: .approvalRequest, body: request("r2", expires: -1))
        deliver(mock, kind: .approvalRequest, body: request("r3", from: DemoData.iPadDeviceID))
        deliver(mock, kind: .approvalRequest, body: ["request": "not an object"])
        await model.sync()
        #expect(model.pendingRequests.map(\.requestID) == ["r1"])
        // 收下的都确认掉了，请求自己存着：换个模型（重新打开 App）还在。
        #expect(mock.state.deviceMessages.filter { $0.toDeviceID == phone }.isEmpty)
        let reopened = make(mock, defaults: defaults)
        #expect(reopened.pendingRequests.map(\.requestID) == ["r1"])

        let r1 = try #require(model.pendingRequests.first)
        #expect(await model.decide(r1, approve: false, reason: "拒绝"))
        let decision = try #require(mock.state.deviceMessages.last)
        #expect(decision.kind == .approvalDecision)
        #expect(decision.body?["request_id"]?.stringValue == "r1")
        #expect(decision.body?["approve"]?.boolValue == false)
        let signature = try #require(
            decision.body?["signature"]?.stringValue.flatMap(PairingEncoding.data(base64url:)))
        #expect(String(decoding: signature, as: UTF8.self) == "signed:approval|r1|false")
        #expect(model.pendingRequests.isEmpty)
    }

    @Test("能力令牌：整理、校验目录和应用，签名发出；吊销")
    func grants() async throws {
        let mock = makeShellMock()
        let model = make(mock)
        await model.load()
        #expect(await model.issueGrant(to: mac, dirs: ["/Users/me"], apps: [], duration: 3600, reason: "") == nil)
        #expect(model.error == .notPaired)
        try await pairMac(model, mock)

        #expect(await model.issueGrant(to: mac, dirs: ["relative/path"], apps: [], duration: 3600, reason: "") == nil)
        #expect(model.error == .invalidGrant)
        #expect(await model.issueGrant(to: mac, dirs: ["/Users/me/../x"], apps: [], duration: 3600, reason: "") == nil)
        #expect(await model.issueGrant(to: mac, dirs: [" "], apps: [], duration: 3600, reason: "") == nil)

        let issued = try #require(
            await model.issueGrant(
                to: mac, dirs: [" /Users/me/Documents ", "/Users/me/Documents", ""], apps: ["com.apple.Safari"],
                duration: 3600, reason: "授权"))
        #expect(issued.grant.dirs == ["/Users/me/Documents"])
        #expect(issued.grant.apps == ["com.apple.Safari"])
        let sent = try #require(mock.state.deviceMessages.last)
        #expect(sent.kind == .capability)
        #expect(sent.body?["grant"]?["token_id"]?.stringValue == issued.grant.tokenID)
        #expect(sent.body?["grant"]?["expires_at"]?.doubleValue == issued.grant.expiresAt.timeIntervalSince1970)
        // Unix 秒是整数（服务端是 u64）。
        #expect(
            sent.bodyJSON.range(of: #""expires_at":[0-9]+[,}]"#, options: .regularExpression) != nil, "\(sent.bodyJSON)"
        )
        #expect(model.activeGrants(for: mac).map(\.id) == [issued.id])

        await model.revoke(issued)
        let revocation = try #require(mock.state.deviceMessages.last)
        #expect(revocation.kind == .revocation)
        #expect(revocation.body?["token_id"]?.stringValue == issued.grant.tokenID)
        #expect(model.activeGrants(for: mac).isEmpty)
    }

    @Test("换了面容（密钥变了）：要重新配对；重置后忘掉所有电脑；解除配对先吊销令牌")
    func keyChangesAndUnpairing() async throws {
        let mock = makeShellMock()
        let signer = FakeSigner()
        let defaults = makeDefaults()
        let model = make(mock, signer: signer, defaults: defaults)
        await model.load()
        try await pairMac(model, mock)
        let issued = try #require(
            await model.issueGrant(to: mac, dirs: ["/Users/me"], apps: [], duration: 3600, reason: ""))

        await signer.setKey(Data("new-key".utf8))
        let reopened = make(mock, signer: signer, defaults: defaults)
        await reopened.load()
        #expect(reopened.needsRepair)
        await signer.setFailNext(.keyInvalidated)
        _ = await reopened.issueGrant(to: mac, dirs: ["/x"], apps: [], duration: 3600, reason: "")
        #expect(reopened.error == .signer(.keyInvalidated))
        await reopened.resetKey()
        #expect(reopened.pairedComputers.isEmpty)
        #expect(!reopened.needsRepair)

        // 解除配对：先吊销发给它的令牌。
        await model.unpair(mac)
        #expect(model.paired(mac) == nil)
        #expect(
            mock.state.deviceMessages.contains { $0.kind == .revocation && $0.bodyJSON.contains(issued.grant.tokenID) })
    }

    @Test("规则：目录、bundle id")
    func rules() {
        #expect(CapabilityRules.isValidDirectory("/Users/me"))
        #expect(!CapabilityRules.isValidDirectory("Users/me"))
        #expect(!CapabilityRules.isValidDirectory("/Users/../etc"))
        #expect(CapabilityRules.isValidBundleID("com.apple.Safari"))
        #expect(!CapabilityRules.isValidBundleID("Safari"))
        #expect(!CapabilityRules.isValidBundleID("com..apple"))
        #expect(!CapabilityRules.isValid(dirs: [], apps: []))
        #expect(
            PairingEncoding.data(base64url: PairingEncoding.base64url(Data([0xfb, 0xff, 0x01])))
                == Data([0xfb, 0xff, 0x01]))
        #expect(PairingEncoding.base64url(Data([0xfb, 0xff])) == "-_8")
    }
}

@Suite("电脑审批的说明按手机的语言说（12.9）")
struct ComputerApprovalDescriptionTests {
    private func request(_ tool: String, _ arguments: String, summary: String = "from the Mac")
        -> ComputerApprovalRequest
    {
        ComputerApprovalRequest(
            desktopID: DemoData.macDeviceID, requestID: "r1", tool: tool, argumentsJSON: arguments, summary: summary,
            issuedAt: Date(), expiresAt: Date().addingTimeInterval(600))
    }

    @Test("执行命令、删除按参数说，理由照原话附上；英文和电脑的说明一样")
    func runAndDelete() {
        let run = request(
            "computer_run", #"{"command":"rm -rf build","cwd":"/Users/a/app","reason":"clean"}"#,
            summary: "Run a command on your computer (in /Users/a/app): rm -rf build\nWhy: clean")
        #expect(
            ComputerLinkText.approvalDescription(run, language: .chinese)
                == "在电脑上执行命令（在 /Users/a/app）：rm -rf build\n理由：clean")
        #expect(ComputerLinkText.approvalDescription(run, language: .english) == run.summary)
        let delete = request("computer_delete", #"{"path":"/Users/a/x.zip","reason":""}"#)
        #expect(ComputerLinkText.approvalDescription(delete, language: .chinese) == "把电脑上的这个移到废纸篓：/Users/a/x.zip")
        #expect(
            ComputerLinkText.approvalDescription(request("computer_run", #"{"command":"ls"}"#), language: .english)
                == "Run a command on your computer: ls")
    }

    @Test("别的工具、参数不全、参数不是 JSON：用电脑给的说明")
    func fallsBack() {
        #expect(
            ComputerLinkText.approvalDescription(request("computer_type", #"{"text":"hi"}"#), language: .chinese)
                == "from the Mac")
        #expect(
            ComputerLinkText.approvalDescription(request("computer_run", #"{"cwd":"/"}"#), language: .chinese)
                == "from the Mac")
        #expect(
            ComputerLinkText.approvalDescription(request("computer_delete", "not json"), language: .chinese)
                == "from the Mac")
    }
}
