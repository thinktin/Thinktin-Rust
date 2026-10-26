// AppIntents 的桩（WBS 12.20 快捷指令、Siri）：签名照 iOS 17 SDK，只放用到的。
// LocalizedStringResource、CustomLocalizedStringResourceConvertible 在真实 SDK 里属于 Foundation（Apple 平台才有），
// Linux 的 Foundation 没有；用到它们的文件都 import 了 AppIntents，放这里。
@_exported import Foundation

public struct LocalizedStringResource: ExpressibleByStringInterpolation, Hashable, Sendable {
    public init(stringLiteral value: String) {}
    public init(stringInterpolation: DefaultStringInterpolation) {}
}

public protocol CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { get }
}

public struct IntentDescription: Sendable {
    public init(
        _ descriptionText: LocalizedStringResource, categoryName: LocalizedStringResource? = nil,
        searchKeywords: [LocalizedStringResource] = []
    ) {}
}

public struct IntentDialog: ExpressibleByStringInterpolation, Sendable {
    public init(_ full: LocalizedStringResource) {}
    public init(stringLiteral value: String) {}
    public init(stringInterpolation: DefaultStringInterpolation) {}
}

// MARK: - 结果

public protocol IntentResult: Sendable {}
public protocol ProvidesDialog: IntentResult {}
public protocol ReturnsValue<Value>: IntentResult {
    associatedtype Value
}

public struct IntentResultContainer<Value: Sendable, Dialog: Sendable>: IntentResult,
    ProvidesDialog, ReturnsValue
{}

extension IntentResult where Self == IntentResultContainer<Never, IntentDialog> {
    public static func result(dialog: IntentDialog) -> Self { .init() }
}

extension IntentResult {
    public static func result<V: Sendable>(value: V, dialog: IntentDialog) -> Self
    where Self == IntentResultContainer<V, IntentDialog> { .init() }
}

// MARK: - 意图与参数

public protocol AppIntent: Sendable {
    associatedtype PerformResult: IntentResult
    static var title: LocalizedStringResource { get }
    static var description: IntentDescription? { get }
    static var openAppWhenRun: Bool { get }
    init()
    func perform() async throws -> PerformResult
}

extension AppIntent {
    public static var description: IntentDescription? { nil }
    public static var openAppWhenRun: Bool { false }
    public typealias Parameter<Value> = IntentParameter<Value>
}

@propertyWrapper
public final class IntentParameter<Value>: @unchecked Sendable {
    private var value: Value?
    public var wrappedValue: Value {
        get { value! }
        set { value = newValue }
    }
    public init(title: LocalizedStringResource, description: LocalizedStringResource? = nil) {}
    public init(
        title: LocalizedStringResource, description: LocalizedStringResource? = nil, default: Value
    ) {
        value = `default`
    }
}

// MARK: - 实体

public struct TypeDisplayRepresentation: ExpressibleByStringInterpolation, Sendable {
    public init(name: LocalizedStringResource) {}
    public init(stringLiteral value: String) {}
    public init(stringInterpolation: DefaultStringInterpolation) {}
}

public struct DisplayRepresentation: ExpressibleByStringInterpolation, Sendable {
    public init(title: LocalizedStringResource, subtitle: LocalizedStringResource? = nil) {}
    public init(stringLiteral value: String) {}
    public init(stringInterpolation: DefaultStringInterpolation) {}
}

public protocol AppEntity: Identifiable, Sendable where ID: Sendable {
    associatedtype DefaultQuery: EntityQuery
    static var typeDisplayRepresentation: TypeDisplayRepresentation { get }
    static var defaultQuery: DefaultQuery { get }
    var displayRepresentation: DisplayRepresentation { get }
}

public protocol EntityQuery: Sendable {
    associatedtype Entity: AppEntity
    init()
    func entities(for identifiers: [Entity.ID]) async throws -> [Entity]
    func suggestedEntities() async throws -> [Entity]
}

extension EntityQuery {
    public func suggestedEntities() async throws -> [Entity] { [] }
}

// MARK: - App 自带的快捷指令

public enum AppShortcutPhraseToken: Sendable {
    case applicationName
}

public struct AppShortcutPhrase<Intent: AppIntent>: ExpressibleByStringInterpolation, Sendable {
    public struct StringInterpolation: StringInterpolationProtocol {
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) {}
        public mutating func appendInterpolation(_ token: AppShortcutPhraseToken) {}
    }
    public init(stringLiteral value: String) {}
    public init(stringInterpolation: StringInterpolation) {}
}

public struct AppShortcut: Sendable {
    public init<Intent: AppIntent>(
        intent: Intent, phrases: [AppShortcutPhrase<Intent>], shortTitle: LocalizedStringResource,
        systemImageName: String
    ) {}
}

@resultBuilder
public struct AppShortcutsBuilder {
    public static func buildBlock(_ components: AppShortcut...) -> [AppShortcut] { components }
}

public protocol AppShortcutsProvider {
    @AppShortcutsBuilder static var appShortcuts: [AppShortcut] { get }
}
