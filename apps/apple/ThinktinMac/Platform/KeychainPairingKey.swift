import CryptoKit
import Foundation
import OSLog
import Security
import ThinktinKit

/// 电脑的配对密钥（WBS 14.8，docs/pairing.md 第 1 节）：P-256，出配对二维码时签邀请，手机按它认这台电脑。
///
/// - 有 Secure Enclave（Apple 芯片、带 T2 的 Intel Mac）时私钥在芯片里，钥匙串里存的是只在这台 Mac 上能用的密钥句柄；
///   没有时退到软件密钥，存在钥匙串里。两种都只在这台 Mac 上（`ThisDeviceOnly`，不进 iCloud 钥匙串）。
/// - 出二维码时用户就在电脑前，不再要求触控 ID：签的只是“这台电脑请求配对”的邀请，真正放权限的是手机。
/// - 一台 Mac 一把，换账号登录也用它（手机按设备 id 记公钥）。删掉钥匙串里这一项就是换一把新的，之前配的手机要重新配对。
///
/// 工具服务在自己的线程上同步调用（`publicKey`、`sign`），钥匙串的接口线程安全，生成密钥时加锁。
struct KeychainPairingKey: ComputerPairingKey {
    static let defaultService = "cn.thinktin.pairing-key"
    private static let account = "p256"
    private static let log = Logger(subsystem: "cn.thinktin.mac", category: "pairing")
    /// 第一次用时生成密钥：两个线程同时来时只生成一把。
    private static let lock = NSLock()

    private let service: String

    init(service: String = KeychainPairingKey.defaultService) {
        self.service = service
    }

    /// 钥匙串里存的：哪种密钥、密钥数据（Secure Enclave 的句柄，或者软件密钥的原始私钥）。
    private struct Stored: Codable {
        enum Kind: String, Codable {
            case secureEnclave
            case software
        }

        var kind: Kind
        var key: Data
    }

    /// 签名和取公钥用的私钥。
    private enum Key {
        case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)

        var publicKey: Data {
            switch self {
            case .secureEnclave(let key): key.publicKey.x963Representation
            case .software(let key): key.publicKey.x963Representation
            }
        }

        func sign(_ message: Data) throws -> Data {
            switch self {
            case .secureEnclave(let key): try key.signature(for: message).derRepresentation
            case .software(let key): try key.signature(for: message).derRepresentation
            }
        }
    }

    func publicKey() throws(ComputerHostError) -> Data {
        try loadOrCreate().publicKey
    }

    func sign(_ message: Data) throws(ComputerHostError) -> Data {
        let key = try loadOrCreate()
        do {
            return try key.sign(message)
        } catch {
            Self.log.error("pairing signature failed: \(error.localizedDescription, privacy: .public)")
            throw .pairing("cannot sign with the pairing key")
        }
    }

    // MARK: 内部

    private func loadOrCreate() throws(ComputerHostError) -> Key {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if let stored = load(), let key = Self.key(stored) { return key }
        let stored = Self.create()
        try save(stored)
        guard let key = Self.key(stored) else { throw .pairing("cannot read the pairing key") }
        return key
    }

    private static func key(_ stored: Stored) -> Key? {
        switch stored.kind {
        case .secureEnclave:
            // 换了主板、迁移到别的 Mac 时句柄就打不开了：当作没有，重新生成。
            (try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored.key)).map(Key.secureEnclave)
        case .software:
            (try? P256.Signing.PrivateKey(rawRepresentation: stored.key)).map(Key.software)
        }
    }

    /// 先试 Secure Enclave；没有、或者建不起来（比如没签名的开发版）时用软件密钥。
    private static func create() -> Stored {
        if SecureEnclave.isAvailable,
            let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, [.privateKeyUsage], nil)
        {
            do {
                let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
                return Stored(kind: .secureEnclave, key: key.dataRepresentation)
            } catch {
                log.error(
                    "Secure Enclave key failed, using a software key: \(error.localizedDescription, privacy: .public)")
            }
        }
        return Stored(kind: .software, key: P256.Signing.PrivateKey().rawRepresentation)
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

    private func save(_ stored: Stored) throws(ComputerHostError) {
        guard let data = try? JSONEncoder().encode(stored) else { throw .pairing("cannot encode the pairing key") }
        var item = baseQuery()
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        _ = SecItemDelete(baseQuery() as CFDictionary)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            Self.log.error("keychain add failed: \(status, privacy: .public)")
            throw .pairing("keychain \(status)")
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
