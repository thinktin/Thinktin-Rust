import Foundation
import ThinktinKit

/// APNs 推送注册（WBS 12.8 实现，这里先放协议和空实现，让 App 的装配和视图模型的注入点先定下来）。
///
/// 流程（12.8）：请求通知权限 → `UIApplication.registerForRemoteNotifications()` → App 代理收到设备令牌
/// → `PushRegistration.forThisBuild(deviceToken:)` 转成十六进制、按构建选好通道（`apns` / `apns_sandbox`），交给
/// client-core 的 `set_push_token`（登录时也可以随 `login` 一起带上）。推送送达、点开时交给 `AppModel.receive(push:)`、
/// `AppModel.open(push:)`（先处理账号冻结 / 解冻，再按 docs/ios.md 第 6.1 节跳转）。
///
/// 视图模型（ThinktinKit）要用到时，把协议挪进 ThinktinKit，实现留在这里。
protocol PushRegistrar: Sendable {
    /// 请求通知权限并向 APNs 注册。返回用户是否允许通知。
    func register() async -> Bool

    /// APNs 回调的设备令牌（App 代理转过来），上报给服务端。
    func didRegister(deviceToken: Data) async

    /// 注册失败（模拟器、没有推送权限的描述文件等）。
    func didFailToRegister(error: any Error) async
}

/// 空实现：不请求权限、不注册。12.8 之前和 Mock 模式下用。
struct NoopPushRegistrar: PushRegistrar {
    func register() async -> Bool { false }
    func didRegister(deviceToken: Data) async {}
    func didFailToRegister(error: any Error) async {}
}

extension PushRegistration {
    /// 这个构建报的推送令牌（docs/push.md 第 1 节）：Debug 构建用开发证书签名（project.yml 里 `aps-environment` 是
    /// development），APNs 给的是沙盒环境的令牌，报 `apns_sandbox`；Release（TestFlight、App Store）报 `apns`。
    /// 报错了环境，令牌会被 APNs 判成 `BadDeviceToken`、服务端清掉。
    static func forThisBuild(deviceToken: Data) -> PushRegistration {
        .apns(deviceToken: deviceToken, sandbox: AppConfiguration.usesAPNsSandbox)
    }
}
