import Foundation

/// 配对好的一台电脑（手机这边记下的）。
public struct PairedComputer: Identifiable, Hashable, Codable, Sendable {
    public var desktopID: DeviceID
    /// 电脑的公钥（SEC1，base64url，二维码里来的）。
    public var desktopKey: String
    /// 配对时手机的公钥（base64url）：密钥换了（录入了新面容）就对不上，要重新配对。
    public var phoneKey: String
    public var pairedAt: Date

    public var id: DeviceID { desktopID }

    public init(desktopID: DeviceID, desktopKey: String, phoneKey: String, pairedAt: Date) {
        self.desktopID = desktopID
        self.desktopKey = desktopKey
        self.phoneKey = phoneKey
        self.pairedAt = pairedAt
    }
}

/// 扫了码、发了配对回复、等电脑确认。
public struct PendingPairing: Hashable, Codable, Sendable {
    public var offer: PairingOffer
    public var phoneKey: String
    public var sentAt: Date

    public init(offer: PairingOffer, phoneKey: String, sentAt: Date) {
        self.offer = offer
        self.phoneKey = phoneKey
        self.sentAt = sentAt
    }
}

/// 签发出去的一个能力令牌。
public struct IssuedGrant: Identifiable, Hashable, Codable, Sendable {
    public var grant: CapabilityGrant
    public var issuedAt: Date
    public var isRevoked: Bool

    public var id: String { grant.tokenID }

    public init(grant: CapabilityGrant, issuedAt: Date, isRevoked: Bool = false) {
        self.grant = grant
        self.issuedAt = issuedAt
        self.isRevoked = isRevoked
    }

    public func isActive(now: Date) -> Bool { !isRevoked && grant.expiresAt > now }
}

/// 手机和电脑之间的状态，存在本机（`UserDefaults`，按账号分开）：配好的电脑、等确认的配对、收到还没处理的审批请求、
/// 签发过的令牌。审批请求从服务端收下就确认掉了（不确认会一直重发），所以要自己存着，处理了或过期了再删。
public struct ComputerLinkState: Hashable, Codable, Sendable {
    public var computers: [PairedComputer] = []
    public var pending: PendingPairing?
    public var requests: [ComputerApprovalRequest] = []
    public var grants: [IssuedGrant] = []

    public init() {}

    /// 等这台手机批准的电脑操作有几个（抽屉、审批中心的角标）：存着的没过期的请求，加上服务端还没收下的新请求（配好的电脑
    /// 发来的、没过期的、没存过的）。只是数一数：收下、确认掉在 `ComputerLinkModel.sync()` 里，打开审批中心时做。
    public func pendingApprovals(messages: [DeviceMessage], now: Date) -> Int {
        var ids = Set(requests.filter { !$0.isExpired(now: now) }.map(\.requestID))
        for message in messages where message.kind == .approvalRequest {
            guard let request = ComputerApprovalRequest(body: message.body), request.desktopID == message.fromDeviceID,
                computers.contains(where: { $0.desktopID == request.desktopID }), !request.isExpired(now: now)
            else { continue }
            ids.insert(request.requestID)
        }
        return ids.count
    }
}

/// 存取 `ComputerLinkState`。键里带用户 id：同一台手机换了账号，看不到上一个账号的电脑。
public struct ComputerLinkStore {
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    static func key(_ userID: UserID) -> String { "computerLink.\(userID.rawValue)" }

    public func load(userID: UserID) -> ComputerLinkState {
        guard let data = defaults?.data(forKey: Self.key(userID)),
            let state = try? JSONDecoder().decode(ComputerLinkState.self, from: data)
        else { return ComputerLinkState() }
        return state
    }

    public func save(_ state: ComputerLinkState, userID: UserID) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults?.set(data, forKey: Self.key(userID))
    }
}
