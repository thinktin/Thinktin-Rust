import SwiftUI
import ThinktinKit

#if canImport(LocalAuthentication)
    import LocalAuthentication
#endif

// 对话页（12.5）放进环境里的东西：批准审批前的本机验证。
//
// App 的 Platform 层可以注入自己的实现（`.environment(\.biometricGate, …)`）；没注入时按客户端选：Mock 客户端
// （预览、测试、Debug 的演示模式）直接通过，真核心用下面的 `SystemBiometricGate`（LocalAuthentication）。

private struct BiometricGateKey: EnvironmentKey {
    static let defaultValue: (any BiometricGate)? = nil
}

extension EnvironmentValues {
    /// 批准审批前的本机验证；nil 是没注入（按客户端选，见 `ConversationGate.resolve`）。
    public var biometricGate: (any BiometricGate)? {
        get { self[BiometricGateKey.self] }
        set { self[BiometricGateKey.self] = newValue }
    }
}

enum ConversationGate {
    /// 注入了就用注入的；Mock 客户端直接通过；其余用系统的本机验证。
    static func resolve(_ injected: (any BiometricGate)?, client: any ClientProtocol) -> any BiometricGate {
        if let injected { return injected }
        let base = (client as? ObservedClient)?.base ?? client
        if base is MockClient { return PassthroughBiometricGate() }
        return SystemBiometricGate()
    }
}

/// 系统的本机验证：面容 ID / 触控 ID，没有时退到锁屏密码（`.deviceOwnerAuthentication`）。
struct SystemBiometricGate: BiometricGate {
    func authorize(reason: String) async -> BiometricGateResult {
        #if canImport(LocalAuthentication)
            let context = LAContext()
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                // 没设置面容 ID、触控 ID、锁屏密码：没法验证。
                return .unavailable
            }
            do {
                let passed = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                return passed ? .approved : .failed
            } catch let failure as LAError {
                switch failure.code {
                case .userCancel, .appCancel, .systemCancel, .userFallback: return .cancelled
                case .passcodeNotSet, .biometryNotEnrolled, .biometryNotAvailable: return .unavailable
                default: return .failed
                }
            } catch {
                return .failed
            }
        #else
            return .unavailable
        #endif
    }
}
