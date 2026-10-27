// 登录项（14.6）的桩：签名照 macOS 14 SDK（macOS 13 起的 SMAppService）。
@_exported import Foundation

open class SMAppService: @unchecked Sendable {
    public enum Status: Int, Sendable {
        case notRegistered, enabled, requiresApproval, notFound
    }

    open class var mainApp: SMAppService { SMAppService() }
    open var status: Status { .notRegistered }
    open func register() throws {}
    open func unregister() throws {}
    open class func openSystemSettingsLoginItems() {}
}
