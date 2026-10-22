import Foundation

/// 把用户数据发给第三方 AI 之前的明示同意（App Store 审核指南 5.1.2(i)，ios-packages.md 12.4 “发给第三方 AI 之前的明示同意”）。
///
/// 用户的消息、文件、产出物经模型网关转发给用户自己配的厂商。规则：
/// - 添加 key 时勾选“我同意把这些内容发给 {厂商} 处理”才能保存，保存成功后记下对这个厂商的同意；
/// - 配模型路由时，路由里用到的厂商有没同意过的，保存前再确认一次（`ModelRoutesModel.vendorsNeedingConsent`）；
/// - 12.5 的“首次在实例里发消息前再拦一次”用 `hasConsented(to:)` 判断这个实例的路由涉及的厂商。
///
/// 记在本机的 `UserDefaults` 里（按厂商记：预置厂商是厂商 id，自定义地址是 `custom:<key 的 id>`，因为每把自定义 key
/// 的地址可能是不同的服务）。说明改版（`currentVersion` 变了）时所有人重新同意。
@MainActor
public struct ThirdPartyAIConsentStore {
    /// 现行说明的版本（数据去向、条款说明改了就改它）。
    public static let currentVersion = "2026-10"
    static let storageKey = "cn.thinktin.models.aiConsent"

    /// 为 nil 时不记（测试、预览）：每次都要重新确认。
    public let defaults: UserDefaults?

    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
    }

    /// 同意记录用的厂商键：预置厂商是厂商 id，自定义地址是 `custom:<key 的 id>`。
    public static func vendorKey(for credential: Credential) -> String {
        credential.vendor == NewCredential.customVendor ? "custom:\(credential.id.rawValue)" : credential.vendor
    }

    /// 同意过把数据发给这个厂商（按现行版本）。
    public func hasConsented(to vendorKey: String) -> Bool {
        records[vendorKey] == Self.currentVersion
    }

    /// 这几把 key 的厂商都同意过了。
    public func hasConsented(toAllOf credentials: [Credential]) -> Bool {
        credentials.allSatisfy { hasConsented(to: Self.vendorKey(for: $0)) }
    }

    /// 记下同意了这些厂商。
    public func record(_ vendorKeys: [String]) {
        guard let defaults, !vendorKeys.isEmpty else { return }
        var all = records
        for key in vendorKeys { all[key] = Self.currentVersion }
        defaults.set(all, forKey: Self.storageKey)
    }

    /// 撤回所有同意（退出登录不清：同意是对这台设备上的数据去向说的，换账号也照样适用）。
    public func withdrawAll() {
        defaults?.removeObject(forKey: Self.storageKey)
    }

    private var records: [String: String] {
        (defaults?.dictionary(forKey: Self.storageKey) as? [String: String]) ?? [:]
    }
}
