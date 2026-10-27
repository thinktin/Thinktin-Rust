import CryptoKit
import Foundation
import LocalAuthentication
import OSLog
import Security
import ThinktinKit

/// 安全芯片里的签名密钥（WBS 12.9，docs/pairing.md 第 1 节）：Secure Enclave 里的 P-256 私钥，不出芯片；
/// 每次签名先过面容 ID / 触控 ID（`LAContext`，验过的上下文交给密钥，不会再弹第二次），签 ECDSA P-256 + SHA-256，输出 DER。
///
/// - 私钥的访问控制是 `.biometryCurrentSet`：录入了新的面容、指纹，系统让旧密钥失效。生成密钥时记下生物识别的
///   “登记状态”（`evaluatedPolicyDomainState`），签名前对一下，变了就报 `keyInvalidated`（要重新生成、重新配对），
///   不等系统的错误。
/// - Secure Enclave 给的是加密过的密钥句柄（`dataRepresentation`，只在这台设备的芯片里能用），存在 Keychain
///   （`WhenPasscodeSetThisDeviceOnly`：不随备份走，关掉锁屏密码就没了）。
/// - 没有 Secure Enclave（模拟器）或没设生物识别时不可用。
struct SecureEnclaveSigner: DeviceSigner {
    static let defaultService = "cn.thinktin.signing-key"
    private static let account = "p256"
    private static let log = Logger(subsystem: "cn.thinktin.app", category: "signing")

    private let service: String

    init(service: String = SecureEnclaveSigner.defaultService) {
        self.service = service
    }

    /// Keychain 里存的：密钥句柄和生成时的生物识别登记状态。
    private struct Stored: Codable {
        var key: Data
        var domainState: Data?
    }

    func isAvailable() async -> Bool {
        guard SecureEnclave.isAvailable else { return false }
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    func publicKey() async throws(DeviceSignerError) -> Data {
        let stored = try loadOrCreate()
        do {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored.key).publicKey
                .x963Representation
        } catch {
            throw .keyInvalidated
        }
    }

    func sign(_ message: Data, reason: String) async throws(DeviceSignerError) -> Data {
        guard await isAvailable() else { throw .unavailable }
        let stored = try loadOrCreate()
        let context = LAContext()
        context.localizedReason = reason
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            else { throw DeviceSignerError.cancelled }
        } catch let error as LAError {
            throw Self.map(error)
        } catch let error as DeviceSignerError {
            throw error
        } catch {
            throw .failed(error.localizedDescription)
        }
        if let state = stored.domainState, context.evaluatedPolicyDomainState != state { throw .keyInvalidated }
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: stored.key, authenticationContext: context)
            return try key.signature(for: message).derRepresentation
        } catch {
            Self.log.error("signing failed: \(error.localizedDescription, privacy: .public)")
            throw .keyInvalidated
        }
    }

    func resetKey() async {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Self.log.error("keychain delete failed: \(status, privacy: .public)")
        }
    }

    // MARK: 内部

    private static func map(_ error: LAError) -> DeviceSignerError {
        switch error.code {
        case .userCancel, .appCancel, .systemCancel, .userFallback: .cancelled
        case .passcodeNotSet, .biometryNotEnrolled, .biometryNotAvailable: .unavailable
        default: .failed(error.localizedDescription)
        }
    }

    private func loadOrCreate() throws(DeviceSignerError) -> Stored {
        if let stored = load() { return stored }
        guard SecureEnclave.isAvailable,
            let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], nil)
        else { throw .unavailable }
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            throw .unavailable
        }
        let key: SecureEnclave.P256.Signing.PrivateKey
        do {
            key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        } catch {
            Self.log.error("cannot create the signing key: \(error.localizedDescription, privacy: .public)")
            throw .unavailable
        }
        let stored = Stored(key: key.dataRepresentation, domainState: context.evaluatedPolicyDomainState)
        try save(stored)
        return stored
    }

    private func load() -> Stored? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private func save(_ stored: Stored) throws(DeviceSignerError) {
        guard let data = try? JSONEncoder().encode(stored) else { throw .failed("cannot encode the key") }
        var item = baseQuery()
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        _ = SecItemDelete(baseQuery() as CFDictionary)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            Self.log.error("keychain add failed: \(status, privacy: .public)")
            throw .failed("keychain \(status)")
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
    }
}
