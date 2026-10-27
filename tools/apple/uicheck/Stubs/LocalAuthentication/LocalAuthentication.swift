// LocalAuthentication 的桩（12.5 批准前的本机验证、12.9 签名前的面容 ID）：签名照 iOS 17 / macOS 14 SDK，只放用到的。
@_exported import Foundation

public enum LAPolicy: Int, Sendable {
    case deviceOwnerAuthenticationWithBiometrics = 1
    case deviceOwnerAuthentication = 2
}

public struct LAError: Error, Hashable, Sendable {
    public enum Code: Int, Sendable {
        case authenticationFailed = -1
        case userCancel = -2
        case userFallback = -3
        case systemCancel = -4
        case passcodeNotSet = -5
        case appCancel = -9
        case invalidContext = -10
        case biometryNotAvailable = -6
        case biometryNotEnrolled = -7
        case biometryLockout = -8
        case notInteractive = -1004
    }
    public var code: Code
    public init(_ code: Code) { self.code = code }
    public var localizedDescription: String { "LAError \(code.rawValue)" }
}

open class LAContext: NSObject {
    public override init() {}
    open var localizedReason: String = ""
    open var evaluatedPolicyDomainState: Data? { nil }
    open func canEvaluatePolicy(_ policy: LAPolicy, error: UnsafeMutablePointer<NSError?>?) -> Bool { false }
    open func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws -> Bool { false }
}
