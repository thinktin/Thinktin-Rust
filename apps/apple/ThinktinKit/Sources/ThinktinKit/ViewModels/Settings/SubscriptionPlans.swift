import Foundation
import Observation

// 订阅（`.subscription`，参考 56；规范 4.9.4、6.20）：参考是一个停在转圈的网页容器。ThinkTin 的 App 内购买（WBS 12.23）
// 等 1.1 拍板，做的话用 StoreKit，不用网页、不放站外购买引导。这里先照参考的“先转圈”排：页面出现时转圈，
// 拿到方案后列出来；方案是本地的演示数据（`SubscriptionDemoData`），订阅、恢复购买弹“即将推出”。

/// 一个方案。
public struct SubscriptionPlan: Identifiable, Hashable, Sendable {
    public enum ID: String, CaseIterable, Hashable, Sendable {
        case free
        case pro
    }

    public var id: ID
    public var name: String
    /// 价格那一行（演示数据里付费方案写“价格即将公布”）。
    public var price: String
    /// 权益，一条一行。
    public var features: [String]
    /// 现在用的方案。
    public var isCurrent: Bool

    public init(id: ID, name: String, price: String, features: [String], isCurrent: Bool) {
        self.id = id
        self.name = name
        self.price = price
        self.features = features
        self.isCurrent = isCurrent
    }
}

/// 订阅页的演示方案（等 12.23 定了换成 StoreKit 的商品）：现在用的免费版，加一个还没开放的专业版。
public enum SubscriptionDemoData {
    public static func plans(_ language: DisplayLanguage = .current) -> [SubscriptionPlan] {
        let zh = language == .chinese
        return [
            SubscriptionPlan(
                id: .free, name: zh ? "免费版" : "Free", price: zh ? "免费" : "Free",
                features: zh
                    ? ["用你自己的模型 key，费用由厂商直接收", "新建 Botin、计划和团队", "收件箱、审批和推送"]
                    : [
                        "Use your own model keys; providers bill you directly", "Create Botins, plans and teams",
                        "Inbox, approvals and notifications",
                    ],
                isCurrent: true),
            SubscriptionPlan(
                id: .pro, name: zh ? "专业版" : "Pro", price: zh ? "价格即将公布" : "Pricing coming soon",
                features: zh
                    ? ["更多 Botin 同时运行", "单次运行时间更长", "更大的工作区", "排队时优先"]
                    : ["More Botins running at once", "Longer runs", "Bigger workspaces", "Priority in the queue"],
                isCurrent: false),
        ]
    }

    /// 演示用的“加载”：等一小会儿再给方案，让页面先出现参考 56 那样的转圈（真的接 StoreKit 时这里是查商品）。
    public static func load(_ language: DisplayLanguage) async -> [SubscriptionPlan] {
        try? await Task.sleep(nanoseconds: 600_000_000)
        return plans(language)
    }
}

/// 订阅页的状态：`plans` 为 nil 时在加载（转圈）。
@Observable @MainActor
public final class SubscriptionModel {
    public private(set) var plans: [SubscriptionPlan]?

    @ObservationIgnored private let loader: @Sendable (DisplayLanguage) async -> [SubscriptionPlan]

    /// - Parameter loader: 拿方案的；默认是演示数据（`SubscriptionDemoData.load`），测试里给一个马上返回的。
    public init(
        loader: @escaping @Sendable (DisplayLanguage) async -> [SubscriptionPlan] = {
            await SubscriptionDemoData.load($0)
        }
    ) {
        self.loader = loader
    }

    public var isLoading: Bool { plans == nil }

    /// 现在用的方案。
    public var currentPlan: SubscriptionPlan? { plans?.first(where: \.isCurrent) }

    public func load(_ language: DisplayLanguage = .current) async {
        plans = await loader(language)
    }
}

/// 订阅页的文案。
public enum SubscriptionText {
    /// 现在用的方案的标记。
    public static func current(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "当前方案" : "Current plan"
    }

    /// 付费方案的按钮。
    public static func subscribe(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "订阅" : "Subscribe"
    }

    public static func restore(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "恢复购买" : "Restore purchases"
    }

    /// 转圈的读屏文字。
    public static func loading(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "正在加载订阅方案" : "Loading plans"
    }

    /// 页面最下面的说明。
    public static func footer(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "这是示例方案，正式的方案和价格以上线时为准。订阅会通过 App Store 购买和管理。"
            : "These are example plans; final plans and prices will be announced at launch. Subscriptions will be "
                + "bought and managed through the App Store."
    }
}
