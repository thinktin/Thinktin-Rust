import Foundation

/// 深链 `thinktin://…`（docs/ios.md 第 6.1 节，和安卓 docs/android-design.md 第 3 节同一套）：推送点击、收件箱跳转、
/// 实时活动、小组件都走它。
///
/// | 深链 | 页面 |
/// |---|---|
/// | `thinktin://run/{id}` | 运行详情 |
/// | `thinktin://approval/{id}` | 审批详情 |
/// | `thinktin://plan/{id}` | 计划详情 |
/// | `thinktin://instance/{id}` | 实例详情（安卓也是实例设置页） |
/// | `thinktin://inbox`、`thinktin://inbox/{id}` | 收件箱、收件箱里的一条 |
/// | `thinktin://vault/request/{id}` | 保险箱的填写请求 |
/// | `thinktin://approvals` | 审批中心（小组件的“待审批”，12.20） |
/// | `thinktin://active` | 进行中（小组件的“进行中”，12.20；安卓没有这一页，不认） |
/// | `thinktin-pair:v1?…` | 和电脑配对（12.9）：电脑上的二维码，用系统相机扫到时打开；整条深链就是配对码 |
///
/// 打开后返回栈是“根（当前实例的对话）→ 目标页”，和安卓的冷启动一致（`Router.show(_:in:)`）。
/// 深链是外部输入：认不出的格式、多余的路径段、不像 id 的 id 一律不认（返回 nil），查询参数和片段忽略。
public enum DeepLink {
    /// URL scheme（project.yml 的 `CFBundleURLTypes` 注册了它）。
    public static let scheme = "thinktin"
    /// 电脑配对二维码的 scheme（docs/pairing.md 第 2 节；也注册了）。
    public static let pairingScheme = "thinktin-pair"
    /// 配对码最长几个字符（正常的不到 300）。
    static let maxPairingCodeLength = 1024

    /// id 最长几个字符。
    static let maxIDLength = 128

    /// 解析深链；不是 `thinktin://` 或认不出时返回 nil。
    public static func route(from url: URL) -> AppRoute? {
        if url.scheme?.lowercased() == pairingScheme {
            // 内容由配对页交给 client-core 解析、校验；这里只挡掉太长的。
            let code = url.absoluteString
            return code.count <= maxPairingCodeLength ? .pairComputer(code: code) : nil
        }
        guard url.scheme?.lowercased() == scheme,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        // `thinktin://run/abc` 的 host 是 run；也认 `thinktin:run/abc`、`thinktin:///run/abc`（没有 host）。
        var segments: [String] = []
        if let host = components.host, !host.isEmpty { segments.append(host) }
        segments += components.path.split(separator: "/").map(String.init)
        return route(segments: segments)
    }

    /// 解析深链文本（`thinktin://run/abc`）。
    public static func route(from string: String) -> AppRoute? {
        URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { route(from: $0) }
    }

    /// 页面的深链；不是深链能到的页面（或 id 不合格式）时返回 nil。`route(from:)` 的逆运算。
    public static func url(for route: AppRoute) -> URL? {
        let segments: [String]
        switch route {
        case .run(let id): segments = ["run", id.rawValue]
        case .approval(let id): segments = ["approval", id.rawValue]
        case .plan(let id): segments = ["plan", id.rawValue]
        case .instance(let id): segments = ["instance", id.rawValue]
        case .inbox: segments = ["inbox"]
        case .inboxItem(let id): segments = ["inbox", id.rawValue]
        case .vaultRequest(let id): segments = ["vault", "request", id.rawValue]
        case .approvals: segments = ["approvals"]
        case .activeRuns: segments = ["active"]
        default: return nil
        }
        guard segments.dropFirst().allSatisfy({ isValidID($0) || $0 == "request" }) else { return nil }
        return URL(string: "\(scheme)://" + segments.joined(separator: "/"))
    }

    /// 像服务端 id 的字符串：1 到 128 个 ASCII 字母、数字、`-`、`_`（服务端的 id 是 UUID，agent id 是小写字母）。
    public static func isValidID(_ id: String) -> Bool {
        guard (1...maxIDLength).contains(id.utf8.count) else { return false }
        return id.utf8.allSatisfy { b in
            (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z")) || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
                || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")) || b == UInt8(ascii: "-")
                || b == UInt8(ascii: "_")
        }
    }

    /// 按路径段解析（第一段是种类，不分大小写；id 原样保留）。
    static func route(segments: [String]) -> AppRoute? {
        guard let kind = segments.first?.lowercased() else { return nil }
        let rest = Array(segments.dropFirst())
        func id() -> String? {
            guard rest.count == 1, isValidID(rest[0]) else { return nil }
            return rest[0]
        }
        switch kind {
        case "run": return id().map { .run(RunID($0)) }
        case "approval": return id().map { .approval(ApprovalID($0)) }
        case "plan": return id().map { .plan(PlanID($0)) }
        case "instance": return id().map { .instance(InstanceID($0)) }
        case "inbox":
            if rest.isEmpty { return .inbox }
            return id().map { .inboxItem(InboxItemID($0)) }
        case "approvals": return rest.isEmpty ? .approvals : nil
        case "active": return rest.isEmpty ? .activeRuns : nil
        case "vault":
            guard rest.count == 2, rest[0].lowercased() == "request", isValidID(rest[1]) else { return nil }
            return .vaultRequest(VaultRequestID(rest[1]))
        default:
            return nil
        }
    }
}
