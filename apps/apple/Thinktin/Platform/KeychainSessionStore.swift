import Foundation
import OSLog
import Security
import ThinktinKit

/// 把 client-core 的登录会话（用户 id、设备 id、访问令牌、刷新令牌）存进 Keychain。
///
/// 实现 ThinktinKit 的 `SessionStoring`；`CoreClient`（ThinktinCoreAdapter）把它桥接成 ThinktinCore 的
/// `SessionStore` 交给 client-core，App 这一层不直接碰 UniFFI 的类型。
///
/// - 一条通用密码项（`kSecClassGenericPassword`），服务名 `cn.thinktin.session`，账号固定 `current`，
///   值是会话的 JSON。
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`：开机解锁过一次后后台也能读（推送唤醒时
///   client-core 要刷新令牌），不进 iCloud 钥匙串、不随备份迁到别的设备（设备 id 是这台设备的）。
/// - `save(nil)` 表示退出登录或会话失效：删掉这一项。
///
/// client-core 在自己的线程上同步调用这两个方法（令牌刷新之后马上存）。Keychain 的接口本身线程安全，
/// 这个类型没有可变状态，满足 `SessionStoring` 要求的 `Sendable`。
final class KeychainSessionStore: SessionStoring {
    static let defaultService = "cn.thinktin.session"
    private static let account = "current"
    private static let log = Logger(subsystem: "cn.thinktin.app", category: "session")

    private let service: String

    /// - Parameter service: Keychain 服务名；测试用别的名字，不碰 App 的会话。
    init(service: String = KeychainSessionStore.defaultService) {
        self.service = service
    }

    func load() -> Session? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            do {
                return try JSONDecoder().decode(StoredSession.self, from: data).session
            } catch {
                // 格式不对（比如以后改了结构）：当作没登录，删掉坏数据，免得每次都读失败。
                Self.log.error("stored session is unreadable, removing it: \(error.localizedDescription, privacy: .public)")
                delete()
                return nil
            }
        case errSecItemNotFound:
            return nil
        default:
            Self.log.error("keychain read failed: \(status, privacy: .public)")
            return nil
        }
    }

    func save(_ session: Session?) {
        guard let session else {
            delete()
            return
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(StoredSession(session))
        } catch {
            Self.log.error("cannot encode session: \(error.localizedDescription, privacy: .public)")
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = baseQuery()
            item.merge(attributes) { _, new in new }
            let added = SecItemAdd(item as CFDictionary, nil)
            if added != errSecSuccess {
                Self.log.error("keychain add failed: \(added, privacy: .public)")
            }
        default:
            Self.log.error("keychain update failed: \(status, privacy: .public)")
        }
    }

    private func delete() {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Self.log.error("keychain delete failed: \(status, privacy: .public)")
        }
    }

    /// 定位这一项的查询条件。只用不可同步的项（`kSecAttrSynchronizable` 默认 false）。
    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
    }
}

/// Keychain 里存的 JSON。不直接用 `Session` 自带的 `Codable`：存下来的格式要跨版本稳定（模型改了字段名，
/// 升级后的 App 也要读得出旧数据，不然用户会被登出），所以字段名在这里固定（和 client-core 的
/// `Session` 记录同名），以后 `Session` 加字段时在这里兼容旧数据。
private struct StoredSession: Codable {
    var userId: String
    var deviceId: String
    var accessToken: String
    var refreshToken: String

    init(_ session: Session) {
        userId = session.userID.rawValue
        deviceId = session.deviceID.rawValue
        accessToken = session.accessToken
        refreshToken = session.refreshToken
    }

    var session: Session {
        Session(
            userID: UserID(rawValue: userId),
            deviceID: DeviceID(rawValue: deviceId),
            accessToken: accessToken,
            refreshToken: refreshToken
        )
    }
}
