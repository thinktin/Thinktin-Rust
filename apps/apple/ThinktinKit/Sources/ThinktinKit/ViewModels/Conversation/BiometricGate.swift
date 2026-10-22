import Foundation

/// 批准审批前的本机验证（面容 ID / 触控 ID，没有时退到锁屏密码；`decide_approval` 的注释要求批准前原生端先做生物识别确认，
/// docs/android-design.md 8.5）。拒绝不用验证。
///
/// 协议放在这里，视图模型只认它：App 的 Platform 层用 LocalAuthentication 实现（`LAContext.evaluatePolicy`，
/// `.deviceOwnerAuthentication`），预览、测试、Mock 模式用 `PassthroughBiometricGate` 直接通过。
public protocol BiometricGate: Sendable {
    /// 弹系统的验证。`reason` 显示在验证弹层上（已经按界面语言取好的）。
    func authorize(reason: String) async -> BiometricGateResult
}

/// 本机验证的结果。
public enum BiometricGateResult: Hashable, Sendable {
    /// 验证通过。
    case approved
    /// 用户取消了（什么都不做，卡片保持原样）。
    case cancelled
    /// 这台设备没有设置面容 ID、触控 ID、锁屏密码，没法验证：照常批准（服务端不验签，拦下来只会让运行等到超时）。
    case unavailable
    /// 验证没通过（多次失败、被锁定）：不批准，提示一句。
    case failed
}

extension BiometricGateResult {
    /// 可以接着批准。
    public var allowsApproval: Bool {
        self == .approved || self == .unavailable
    }
}

/// 直接通过（预览、测试、Mock 模式）。
public struct PassthroughBiometricGate: BiometricGate {
    public init() {}

    public func authorize(reason: String) async -> BiometricGateResult { .approved }
}

/// 固定返回某个结果、并记下被问过几次（测试用）。
public final class ScriptedBiometricGate: BiometricGate, Sendable {
    private struct State {
        var result: BiometricGateResult
        var reasons: [String] = []
    }

    private let state: Locked<State>

    public init(result: BiometricGateResult = .approved) {
        state = Locked(State(result: result))
    }

    /// 之后返回的结果。
    public var result: BiometricGateResult {
        get { state.withLock { $0.result } }
        set { state.withLock { $0.result = newValue } }
    }

    /// 每次验证时显示的说明（按调用顺序）。
    public var reasons: [String] { state.withLock { $0.reasons } }

    public func authorize(reason: String) async -> BiometricGateResult {
        state.withLock { s in
            s.reasons.append(reason)
            return s.result
        }
    }
}
