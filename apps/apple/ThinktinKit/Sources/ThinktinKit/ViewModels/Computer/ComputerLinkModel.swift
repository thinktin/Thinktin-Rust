import Foundation
import Observation

/// 手机控制电脑出的错。
public enum ComputerLinkError: Error, Hashable, Sendable {
    case client(ClientError)
    case pairing(PairingCodecError)
    case signer(DeviceSignerError)
    /// 二维码里的电脑没登录这个账号（或者已经下线）。
    case notYourComputer
    /// 这台电脑还没配对。
    case notPaired
    /// 等电脑确认的时候邀请过期了（电脑没在线、没收到）。
    case pairingTimedOut
    /// 能力令牌的目录、应用不对（见 `CapabilityRules`）。
    case invalidGrant
}

/// 能力令牌（普通操作）的规则：和电脑那边（`desktop` 的 `policy.rs`、client-core 的 `capability_allows_path`）一样
/// 目录要是绝对路径、不能有 `..`；应用是 bundle id。至少给一个目录或一个应用。
public enum CapabilityRules {
    /// 有效期可选的几档。
    public static let durations: [TimeInterval] = [3600, 8 * 3600, 24 * 3600, 7 * 24 * 3600]

    public static func isValidDirectory(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\n") else { return false }
        return !path.split(separator: "/").contains("..")
    }

    public static func isValidBundleID(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty
                && part.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        }
    }

    /// 整理用户填的：去掉首尾空白、空行、重复的。
    public static func cleaned(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }

    public static func isValid(dirs: [String], apps: [String]) -> Bool {
        !(dirs.isEmpty && apps.isEmpty) && dirs.allSatisfy(isValidDirectory) && apps.allSatisfy(isValidBundleID)
    }
}

/// 手机控制电脑（WBS 12.9，docs/pairing.md）：配对、电脑发来的高危操作审批、普通操作的能力令牌。
///
/// - **配对**：扫电脑上的二维码（`pair(code:)`）→ 解析邀请、确认是自己账号的电脑 → 安全芯片签配对回复（要面容 ID）→ 经平台发给电脑
///   （`pair_response`）→ 等电脑签的确认（`pair_confirm`，用二维码里的电脑公钥验）→ 记下电脑。等确认时每隔几秒收一次消息
///   （`awaitConfirmation`），邀请过期了还没等到就算失败。
/// - **审批**：电脑的删除、执行命令这类操作发来 `approval_request`（推送到手机、进收件箱）；只收配好的电脑发来的、没过期的。
///   批准或拒绝都要签名（签的是参数和说明的摘要、决定），发回 `approval_decision`。收下的请求马上在服务端确认掉，自己存着，
///   处理了或过期了再删。
/// - **能力令牌**：给配好的电脑签发普通操作能碰的目录、应用和有效期（`capability`），随时吊销（`revocation`，不用签名）。
/// - 密钥是安全芯片里的，录入了新的面容、指纹后失效（`needsRepair`）：要重新生成、重新配对。
@Observable @MainActor
public final class ComputerLinkModel {
    /// 这个账号登录着的电脑（`devices()` 里的 macOS 设备）。
    public private(set) var computers: [DeviceInfo] = []
    public private(set) var state = ComputerLinkState()
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    /// 正在签名、发送（按钮转圈）。
    public private(set) var isWorking = false
    public var error: ComputerLinkError?
    /// 这台设备能签名（有安全芯片、设了锁屏）。
    public private(set) var canSign = true
    /// 密钥换了（录入了新面容）：配过的电脑要重新配对。
    public private(set) var needsRepair = false

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let codec: any PairingCodec
    @ObservationIgnored private let signer: any DeviceSigner
    @ObservationIgnored private let store: ComputerLinkStore
    @ObservationIgnored private let userID: UserID
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var currentDeviceID: DeviceID?

    public init(
        client: any ClientProtocol, codec: any PairingCodec, signer: any DeviceSigner, userID: UserID,
        defaults: UserDefaults? = .standard, now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.codec = codec
        self.signer = signer
        self.userID = userID
        self.store = ComputerLinkStore(defaults: defaults)
        self.now = now
        state = store.load(userID: userID)
    }

    // MARK: 读

    public var pairedComputers: [PairedComputer] { state.computers }

    public func paired(_ id: DeviceID) -> PairedComputer? { state.computers.first { $0.desktopID == id } }

    public func name(of id: DeviceID) -> String? { computers.first { $0.id == id }?.name }

    /// 还没处理、没过期的审批请求，快过期的在前。
    public var pendingRequests: [ComputerApprovalRequest] {
        let now = self.now()
        return state.requests.filter { !$0.isExpired(now: now) }.sorted { $0.expiresAt < $1.expiresAt }
    }

    /// 还有效的令牌（没吊销、没过期），新的在前。
    public func activeGrants(for desktopID: DeviceID) -> [IssuedGrant] {
        let now = self.now()
        return state.grants.filter { $0.grant.desktopID == desktopID && $0.isActive(now: now) }
            .sorted { $0.issuedAt > $1.issuedAt }
    }

    public var isPairing: Bool { state.pending != nil }

    // MARK: 加载、收消息

    /// 拉设备列表、收消息、看密钥换没换。
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let devices = try await client.devices()
            computers = devices.filter(\.isComputer)
            currentDeviceID = devices.first(where: \.isCurrent)?.id
            hasLoaded = true
        } catch {
            fail(error)
            return
        }
        canSign = await signer.isAvailable()
        await checkKey()
        await sync()
    }

    /// 收电脑发来的消息：配对确认、审批请求。收下的都在服务端确认掉（不确认会一直重发）。
    public func sync() async {
        guard let me = currentDeviceID else { return }
        let messages: [DeviceMessage]
        do {
            messages = try await client.deviceMessages()
        } catch {
            fail(error)
            return
        }
        for message in messages {
            switch message.kind {
            case .pairConfirm: confirmPairing(message, me: me)
            case .approvalRequest: receiveRequest(message)
            default: break
            }
        }
        prune()
        save()
        let ids = messages.map(\.id)
        for start in stride(from: 0, to: ids.count, by: DeviceMessage.maxAckCount) {
            let chunk = Array(ids[start..<min(start + DeviceMessage.maxAckCount, ids.count)])
            _ = try? await client.ackDeviceMessages(ids: chunk)
        }
    }

    private func confirmPairing(_ message: DeviceMessage, me: DeviceID) {
        guard let pending = state.pending, message.fromDeviceID == pending.offer.desktopID,
            message.body?["nonce"]?.stringValue == pending.offer.nonce
        else { return }
        state.pending = nil
        guard let encoded = message.body?["signature"]?.stringValue,
            let signature = PairingEncoding.data(base64url: encoded)
        else {
            error = .pairing(.malformed("signature"))
            return
        }
        do {
            try codec.verifyConfirmation(
                offer: pending.offer, phoneID: me, phoneKey: pending.phoneKey, signature: signature)
        } catch {
            self.error = .pairing(error)
            return
        }
        // 重新配对同一台电脑：电脑那边清掉了之前的令牌。
        for i in state.grants.indices where state.grants[i].grant.desktopID == pending.offer.desktopID {
            state.grants[i].isRevoked = true
        }
        state.computers.removeAll { $0.desktopID == pending.offer.desktopID }
        state.computers.append(
            PairedComputer(
                desktopID: pending.offer.desktopID, desktopKey: pending.offer.desktopKey, phoneKey: pending.phoneKey,
                pairedAt: now()))
        needsRepair = false
    }

    private func receiveRequest(_ message: DeviceMessage) {
        guard let request = ComputerApprovalRequest(body: message.body),
            request.desktopID == message.fromDeviceID, paired(request.desktopID) != nil,
            !request.isExpired(now: now()), !state.requests.contains(where: { $0.requestID == request.requestID })
        else { return }
        state.requests.append(request)
    }

    /// 过期的请求、过期的配对邀请去掉；过期、吊销超过一周的令牌不再显示。
    private func prune() {
        let now = self.now()
        state.requests.removeAll { $0.isExpired(now: now) }
        if let pending = state.pending, pending.offer.expiresAt.addingTimeInterval(Self.clockSkew) <= now {
            state.pending = nil
            error = .pairingTimedOut
        }
        state.grants.removeAll { $0.grant.expiresAt.addingTimeInterval(7 * 24 * 3600) <= now }
    }

    /// 两台设备的时钟允许差这么多（client-core 的 `CLOCK_SKEW_SECS`）。
    static let clockSkew: TimeInterval = 5 * 60

    private func checkKey() async {
        guard canSign, !state.computers.isEmpty else { return }
        do {
            let key = try await signer.publicKey()
            let encoded = try codec.encodePublicKey(key)
            needsRepair = state.computers.contains { $0.phoneKey != encoded }
        } catch DeviceSignerError.keyInvalidated {
            needsRepair = true
        } catch {
            fail(error)
        }
    }

    // MARK: 配对

    /// 扫到的二维码（或者粘贴的配对码）：签配对回复发给电脑，之后等确认（`awaitConfirmation`）。成功发出返回 true。
    @discardableResult
    public func pair(code: String, reason: String) async -> Bool {
        guard !isWorking, let me = currentDeviceID else { return false }
        isWorking = true
        defer { isWorking = false }
        error = nil
        do {
            let offer = try codec.parseOffer(code.trimmingCharacters(in: .whitespacesAndNewlines))
            guard computers.contains(where: { $0.id == offer.desktopID }) else {
                throw ComputerLinkError.notYourComputer
            }
            let phoneKey = try await currentPublicKey()
            let message = try codec.responseMessage(offer: offer, phoneID: me, phoneKey: phoneKey)
            let signature = try await signer.sign(message, reason: reason)
            let body: JSONValue = [
                "nonce": .string(offer.nonce), "phone_key": .string(phoneKey),
                "signature": .string(PairingEncoding.base64url(signature)),
            ]
            _ = try await client.sendDeviceMessage(to: offer.desktopID, kind: .pairResponse, body: body)
            state.pending = PendingPairing(offer: offer, phoneKey: phoneKey, sentAt: now())
            save()
            return true
        } catch {
            fail(error)
            return false
        }
    }

    /// 等电脑的确认：每隔 `interval` 收一次消息，直到配好、失败或者邀请过期。
    public func awaitConfirmation(interval: Duration = .seconds(3)) async {
        while state.pending != nil, !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            await sync()
        }
    }

    /// 不等了（取消配对）。
    public func cancelPairing() {
        state.pending = nil
        save()
    }

    /// 解除前先把仍可能有效的令牌吊销；网络失败时保留配对，可继续重试。
    public func unpair(_ desktopID: DeviceID) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await revokeOutstanding(for: desktopID)
            state.computers.removeAll { $0.desktopID == desktopID }
            state.requests.removeAll { $0.desktopID == desktopID }
            if state.pending?.offer.desktopID == desktopID { state.pending = nil }
            save()
        } catch {
            fail(error)
        }
    }

    /// 密钥失效后：删掉旧密钥和所有配对（要重新扫码）。
    public func resetKey() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await revokeOutstanding()
            await signer.resetKey()
            state.computers = []
            state.requests = []
            state.pending = nil
            needsRepair = false
            save()
        } catch {
            fail(error)
        }
    }

    // MARK: 审批

    /// 批准或拒绝电脑的高危操作：都要签名（拒绝的签名不会被当成批准）。过期了的直接拿掉。成功发出返回 true。
    @discardableResult
    public func decide(_ request: ComputerApprovalRequest, approve: Bool, reason: String) async -> Bool {
        guard !isWorking else { return false }
        guard !request.isExpired(now: now()) else {
            state.requests.removeAll { $0.requestID == request.requestID }
            save()
            error = .pairing(.expired)
            return false
        }
        isWorking = true
        defer { isWorking = false }
        error = nil
        do {
            let message = try codec.approvalMessage(request, approve: approve)
            let signature = try await signer.sign(message, reason: reason)
            let body: JSONValue = [
                "request_id": .string(request.requestID), "approve": .bool(approve),
                "signature": .string(PairingEncoding.base64url(signature)),
            ]
            _ = try await client.sendDeviceMessage(to: request.desktopID, kind: .approvalDecision, body: body)
            state.requests.removeAll { $0.requestID == request.requestID }
            save()
            return true
        } catch {
            fail(error)
            return false
        }
    }

    // MARK: 能力令牌

    /// 给配好的电脑签发令牌。目录、应用先整理（去空白、去重）再查。成功返回签发的令牌。
    @discardableResult
    public func issueGrant(
        to desktopID: DeviceID, dirs: [String], apps: [String], duration: TimeInterval, reason: String
    ) async -> IssuedGrant? {
        guard !isWorking else { return nil }
        error = nil
        guard paired(desktopID) != nil else {
            error = .notPaired
            return nil
        }
        let dirs = CapabilityRules.cleaned(dirs)
        let apps = CapabilityRules.cleaned(apps)
        guard CapabilityRules.isValid(dirs: dirs, apps: apps) else {
            error = .invalidGrant
            return nil
        }
        isWorking = true
        defer { isWorking = false }
        let issuedAt = now()
        let grant = CapabilityGrant(
            desktopID: desktopID, tokenID: UUID().uuidString.lowercased(), dirs: dirs, apps: apps,
            expiresAt: Date(timeIntervalSince1970: (issuedAt.timeIntervalSince1970 + duration).rounded(.down)))
        do {
            let message = try codec.capabilityMessage(grant)
            let signature = try await signer.sign(message, reason: reason)
            let body: JSONValue = [
                "grant": grant.wireValue, "signature": .string(PairingEncoding.base64url(signature)),
            ]
            _ = try await client.sendDeviceMessage(to: desktopID, kind: .capability, body: body)
            let issued = IssuedGrant(grant: grant, issuedAt: issuedAt)
            state.grants.append(issued)
            save()
            return issued
        } catch {
            fail(error)
            return nil
        }
    }

    /// 吊销（不用签名：吊销只会收紧权限）。电脑不在线时平台排队 24 小时。
    public func revoke(_ issued: IssuedGrant) async {
        do {
            try await sendRevocation(issued)
        } catch {
            fail(error)
        }
    }

    // MARK: 内部

    private func revokeOutstanding(for desktop: DeviceID? = nil) async throws {
        let cutoff = now().addingTimeInterval(-Self.clockSkew)
        for issued in state.grants where !issued.isRevoked && issued.grant.expiresAt > cutoff {
            if let desktop, issued.grant.desktopID != desktop { continue }
            try await sendRevocation(issued)
        }
    }

    private func sendRevocation(_ issued: IssuedGrant) async throws {
        do {
            _ = try await client.sendDeviceMessage(
                to: issued.grant.desktopID, kind: .revocation, body: ["token_id": .string(issued.grant.tokenID)])
        } catch let error as ClientError where error.isNotFound {
            // The gateway returns 404 for either endpoint. Only retire locally if the target is gone.
            let devices = try await client.devices()
            if devices.contains(where: { $0.id == issued.grant.desktopID }) { throw error }
        }
        if let i = state.grants.firstIndex(where: { $0.id == issued.id }) { state.grants[i].isRevoked = true }
        save()
    }

    private func currentPublicKey() async throws -> String {
        let key: Data
        do {
            key = try await signer.publicKey()
        } catch {
            throw ComputerLinkError.signer(error)
        }
        do {
            return try codec.encodePublicKey(key)
        } catch {
            throw ComputerLinkError.pairing(error)
        }
    }

    private func save() {
        store.save(state, userID: userID)
    }

    private func fail(_ error: any Error) {
        let wrapped = Self.wrap(error)
        self.error = wrapped
        if wrapped == .signer(.keyInvalidated) { needsRepair = true }
    }

    static func wrap(_ error: any Error) -> ComputerLinkError {
        switch error {
        case let error as ComputerLinkError: error
        case let error as ClientError: .client(error)
        case let error as PairingCodecError: .pairing(error)
        case let error as DeviceSignerError: .signer(error)
        default: .client(.internal(message: String(describing: error)))
        }
    }
}
