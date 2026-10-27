import Foundation

// 手机控制电脑（WBS 12.9，docs/pairing.md）：配对、高危操作的签名审批、普通操作的能力令牌。
// 编码、解析、验签在 client-core（`PairingCodec`，App 里是 ThinktinCore），签名在安全芯片里（`DeviceSigner`，
// App 里是 Secure Enclave），这里只有纯 Swift 的类型和流程。

/// 电脑给出的配对邀请（二维码 `thinktin-pair:v1?…` 里的内容）。
public struct PairingOffer: Hashable, Codable, Sendable {
    public var desktopID: DeviceID
    /// 电脑的公钥（SEC1，base64url）。
    public var desktopKey: String
    /// 一次性随机数（base64url）。
    public var nonce: String
    public var expiresAt: Date

    public init(desktopID: DeviceID, desktopKey: String, nonce: String, expiresAt: Date) {
        self.desktopID = desktopID
        self.desktopKey = desktopKey
        self.nonce = nonce
        self.expiresAt = expiresAt
    }
}

/// 电脑请手机签名批准的高危操作（删除、执行命令……）。经设备中继转发时是消息正文 `{"request": …}`。
public struct ComputerApprovalRequest: Identifiable, Hashable, Codable, Sendable {
    public var desktopID: DeviceID
    public var requestID: String
    /// 工具名，比如 `delete_files`。
    public var tool: String
    /// 工具参数（JSON 文本）；签的是规范化之后的摘要。
    public var argumentsJSON: String
    /// 给人看的说明；签的是它的摘要，界面上显示的和电脑要执行的对得上。
    public var summary: String
    public var issuedAt: Date
    public var expiresAt: Date

    public var id: String { requestID }

    public init(
        desktopID: DeviceID, requestID: String, tool: String, argumentsJSON: String, summary: String,
        issuedAt: Date, expiresAt: Date
    ) {
        self.desktopID = desktopID
        self.requestID = requestID
        self.tool = tool
        self.argumentsJSON = argumentsJSON
        self.summary = summary
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public func isExpired(now: Date) -> Bool { expiresAt <= now }

    /// 从消息正文解析（`{"request": {"desktop_id", "request_id", "tool", "arguments_json", "summary",
    /// "issued_at", "expires_at"}}`，时间是 Unix 秒）；格式不对时为 nil。
    public init?(body: JSONValue?) {
        guard let r = body?["request"],
            let desktop = r["desktop_id"]?.stringValue, let requestID = r["request_id"]?.stringValue,
            let tool = r["tool"]?.stringValue, let arguments = r["arguments_json"]?.stringValue,
            let summary = r["summary"]?.stringValue, let issued = r["issued_at"]?.doubleValue,
            let expires = r["expires_at"]?.doubleValue
        else { return nil }
        self.init(
            desktopID: DeviceID(desktop), requestID: requestID, tool: tool, argumentsJSON: arguments,
            summary: summary, issuedAt: Date(timeIntervalSince1970: issued),
            expiresAt: Date(timeIntervalSince1970: expires))
    }
}

/// 手机签发给电脑的能力令牌：普通操作能碰哪些目录、哪些应用，到什么时候。
public struct CapabilityGrant: Identifiable, Hashable, Codable, Sendable {
    public var desktopID: DeviceID
    public var tokenID: String
    /// 能读写的目录（绝对路径）。
    public var dirs: [String]
    /// 能操作的应用（bundle id）。
    public var apps: [String]
    public var expiresAt: Date

    public var id: String { tokenID }

    public init(desktopID: DeviceID, tokenID: String, dirs: [String], apps: [String], expiresAt: Date) {
        self.desktopID = desktopID
        self.tokenID = tokenID
        self.dirs = dirs
        self.apps = apps
        self.expiresAt = expiresAt
    }

    /// 消息正文里的样子（时间是 Unix 秒）。
    public var wireValue: JSONValue {
        [
            "desktop_id": .string(desktopID.rawValue), "token_id": .string(tokenID),
            "dirs": .array(dirs.map(JSONValue.string)), "apps": .array(apps.map(JSONValue.string)),
            "expires_at": .number(expiresAt.timeIntervalSince1970.rounded(.down)),
        ]
    }
}

/// 编码、解析、验签出的错（client-core 的 `PairingError`）。
public enum PairingCodecError: Error, Hashable, Sendable {
    /// 格式不对：二维码、公钥、字段、签名的编码。
    case malformed(String)
    /// 过期了。
    case expired
    /// 签名验不过。
    case badSignature
}

/// client-core 的配对与验签（docs/pairing.md）：要签的字节、二维码解析、验电脑的签名。手机、电脑两边用同一份实现，
/// 签的字节一定一致。App 里是 ThinktinCore（`CorePairingCodec`），测试里是假的。
public protocol PairingCodec: Sendable {
    func parseOffer(_ uri: String) throws(PairingCodecError) -> PairingOffer
    func responseMessage(offer: PairingOffer, phoneID: DeviceID, phoneKey: String) throws(PairingCodecError) -> Data
    func verifyConfirmation(offer: PairingOffer, phoneID: DeviceID, phoneKey: String, signature: Data)
        throws(PairingCodecError)
    func approvalMessage(_ request: ComputerApprovalRequest, approve: Bool) throws(PairingCodecError) -> Data
    func capabilityMessage(_ grant: CapabilityGrant) throws(PairingCodecError) -> Data
    /// SEC1 公钥 → base64url（顺便检查是不是合法的 P-256 公钥）。
    func encodePublicKey(_ sec1: Data) throws(PairingCodecError) -> String
}

/// 安全芯片里的签名密钥出的错。
public enum DeviceSignerError: Error, Hashable, Sendable {
    /// 这台设备没有安全芯片，或者没设置面容 ID / 触控 ID / 锁屏密码。
    case unavailable
    /// 用户取消了验证。
    case cancelled
    /// 密钥失效了（录入了新的面容、指纹，或者重设了锁屏密码）：要重新生成、重新配对。
    case keyInvalidated
    case failed(String)
}

/// 安全芯片里的 P-256 签名密钥（WBS 12.9）：私钥不出芯片，每次签名都要生物识别。App 里是 Secure Enclave
/// （`SecureEnclaveSigner`），测试里是假的。
public protocol DeviceSigner: Sendable {
    /// 能不能签：有安全芯片，且设置了面容 ID / 触控 ID / 锁屏密码。
    func isAvailable() async -> Bool
    /// 公钥（SEC1，不压缩 65 字节）。没有密钥时先生成。
    func publicKey() async throws(DeviceSignerError) -> Data
    /// 验证通过后签 `message`（ECDSA P-256 + SHA-256），返回 DER。`reason` 显示在系统的验证弹层上。
    func sign(_ message: Data, reason: String) async throws(DeviceSignerError) -> Data
    /// 删掉密钥（失效了、解除所有配对时）；下次 `publicKey()` 生成新的。
    func resetKey() async
}

/// 消息正文里的二进制（签名）：不带填充的 base64url。
public enum PairingEncoding {
    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func data(base64url text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}
