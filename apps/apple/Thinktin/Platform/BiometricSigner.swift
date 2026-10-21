import Foundation

/// 审批与配对签名（WBS 12.9 实现，这里先放协议和空实现）。
///
/// 私钥是 Secure Enclave 里的 P-256 密钥（不出芯片），每次签名前用面容 ID / 触控 ID 确认
/// （`LocalAuthentication`，Info.plist 的 `NSFaceIDUsageDescription`）。签什么由 client-core 给出
/// （`approval_message`、`pairing_response_message`、`capability_message` 的规范编码），这里只管签：
/// ECDSA P-256 + SHA-256，输出 DER；公钥用 SEC1 格式（client-core 两种都认，见 crates/client-core/src/pairing.rs）。
///
/// 视图模型（ThinktinKit）要用到时，把协议挪进 ThinktinKit，实现留在这里。
protocol BiometricSigner: Sendable {
    /// 这台设备能不能签：有 Secure Enclave，且设置了面容 ID / 触控 ID / 密码。
    var isAvailable: Bool { get async }

    /// 签名密钥的公钥（SEC1，不压缩 65 字节）。没有密钥时先生成。
    func publicKey() async throws -> Data

    /// 生物识别通过后签 `message`，返回 DER 编码的签名。`reason` 显示在系统的验证弹层上。
    func sign(_ message: Data, reason: String) async throws -> Data
}

enum BiometricSignerError: Error, Equatable {
    /// 设备不支持，或还没实现（12.9 之前）。
    case unavailable
    /// 用户取消了生物识别。
    case cancelled
}

/// 空实现：永远不可用。12.9 之前和 Mock 模式下用。
struct UnavailableBiometricSigner: BiometricSigner {
    var isAvailable: Bool { get async { false } }
    func publicKey() async throws -> Data { throw BiometricSignerError.unavailable }
    func sign(_ message: Data, reason: String) async throws -> Data { throw BiometricSignerError.unavailable }
}
