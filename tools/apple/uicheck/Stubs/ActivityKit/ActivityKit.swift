// ActivityKit 的桩（WBS 12.10 实时活动）：签名照 iOS 17 SDK，只放用到的。`Activity` 故意不是 Sendable（比真实 SDK
// 严），在这里过了并发检查的写法到真实 SDK 上也过。
@_exported import Foundation

public protocol ActivityAttributes: Decodable, Encodable {
    associatedtype ContentState: Decodable, Encodable, Hashable
}

public enum ActivityState: Hashable, Sendable {
    case active, ended, dismissed, stale
}

public struct ActivityContent<State: Decodable & Encodable & Hashable>: Hashable {
    public var state: State
    public var staleDate: Date?
    public var relevanceScore: Double
    public init(state: State, staleDate: Date?, relevanceScore: Double = 0) {
        self.state = state
        self.staleDate = staleDate
        self.relevanceScore = relevanceScore
    }
}

extension ActivityContent: Sendable where State: Sendable {}

public struct ActivityUIDismissalPolicy: Hashable, Sendable {
    let after: Date?
    public static let `default` = ActivityUIDismissalPolicy(after: nil)
    public static let immediate = ActivityUIDismissalPolicy(after: .distantPast)
    public static func after(_ date: Date) -> ActivityUIDismissalPolicy { ActivityUIDismissalPolicy(after: date) }
}

public struct PushType: Equatable, Sendable {
    public static let token = PushType()
}

public struct ActivityAuthorizationInfo {
    public init() {}
    public var areActivitiesEnabled: Bool { false }
}

public final class Activity<Attributes: ActivityAttributes>: Identifiable {
    public let id: String
    public let attributes: Attributes
    public private(set) var content: ActivityContent<Attributes.ContentState>
    public private(set) var activityState: ActivityState = .active

    init(attributes: Attributes, content: ActivityContent<Attributes.ContentState>) {
        id = UUID().uuidString
        self.attributes = attributes
        self.content = content
    }

    public var pushTokenUpdates: AsyncStream<Data> { AsyncStream { $0.finish() } }
    public var activityStateUpdates: AsyncStream<ActivityState> { AsyncStream { $0.finish() } }

    public static var activities: [Activity<Attributes>] { [] }
    public static var activityUpdates: AsyncStream<Activity<Attributes>> { AsyncStream { $0.finish() } }
    @available(iOS 17.2, *)
    public static var pushToStartTokenUpdates: AsyncStream<Data> { AsyncStream { $0.finish() } }

    public static func request(
        attributes: Attributes, content: ActivityContent<Attributes.ContentState>, pushType: PushType? = nil
    ) throws -> Activity<Attributes> {
        Activity(attributes: attributes, content: content)
    }

    public func update(_ content: ActivityContent<Attributes.ContentState>) async {
        self.content = content
    }

    public func end(
        _ content: ActivityContent<Attributes.ContentState>?, dismissalPolicy: ActivityUIDismissalPolicy = .default
    ) async {
        activityState = .ended
    }
}
