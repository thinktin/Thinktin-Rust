// WidgetKit 的桩（WBS 12.20 主屏小组件）：签名照 iOS 17 SDK，只放用到的。
@_exported import Foundation
import SwiftUI

public enum WidgetFamily: CaseIterable, Hashable, Sendable {
    case systemSmall, systemMedium, systemLarge, systemExtraLarge
    case accessoryCircular, accessoryRectangular, accessoryInline
}

extension EnvironmentValues {
    public var widgetFamily: WidgetFamily { .systemSmall }
}

public protocol TimelineEntry {
    var date: Date { get }
}

public struct TimelineProviderContext: Sendable {
    public var family: WidgetFamily { .systemSmall }
    public var isPreview: Bool { false }
    public var displaySize: CGSize { .zero }
}

public struct TimelineReloadPolicy: Equatable, Sendable {
    let date: Date?
    public static let atEnd = TimelineReloadPolicy(date: nil)
    public static let never = TimelineReloadPolicy(date: .distantFuture)
    public static func after(_ date: Date) -> TimelineReloadPolicy {
        TimelineReloadPolicy(date: date)
    }
}

public struct Timeline<EntryType: TimelineEntry> {
    public let entries: [EntryType]
    public let policy: TimelineReloadPolicy
    public init(entries: [EntryType], policy: TimelineReloadPolicy) {
        self.entries = entries
        self.policy = policy
    }
}

public protocol TimelineProvider {
    associatedtype Entry: TimelineEntry
    typealias Context = TimelineProviderContext
    func placeholder(in context: Context) -> Entry
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void)
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void)
}

@MainActor @preconcurrency
public protocol WidgetConfiguration {
    associatedtype Body: WidgetConfiguration
    @WidgetConfigurationBuilder var body: Body { get }
}

extension Never: WidgetConfiguration {}

@resultBuilder
public struct WidgetConfigurationBuilder {
    public static func buildBlock<C: WidgetConfiguration>(_ content: C) -> C { content }
}

public struct StaticConfiguration<Content: View>: WidgetConfiguration {
    public init<Provider: TimelineProvider>(
        kind: String, provider: Provider, @ViewBuilder content: @escaping (Provider.Entry) -> Content
    ) {}
    public var body: Never { fatalError() }
}

public struct ModifiedWidgetConfiguration<Content: WidgetConfiguration>: WidgetConfiguration {
    public var body: Never { fatalError() }
}

extension WidgetConfiguration {
    public func configurationDisplayName(_ displayName: Text) -> ModifiedWidgetConfiguration<Self> {
        .init()
    }
    public func configurationDisplayName(_ displayNameKey: LocalizedStringKey)
        -> ModifiedWidgetConfiguration<Self>
    {
        .init()
    }
    @_disfavoredOverload
    public func configurationDisplayName<S: StringProtocol>(_ displayName: S)
        -> ModifiedWidgetConfiguration<Self>
    {
        .init()
    }
    public func description(_ description: Text) -> ModifiedWidgetConfiguration<Self> { .init() }
    public func description(_ descriptionKey: LocalizedStringKey) -> ModifiedWidgetConfiguration<Self> { .init() }
    @_disfavoredOverload
    public func description<S: StringProtocol>(_ description: S) -> ModifiedWidgetConfiguration<Self> { .init() }
    public func supportedFamilies(_ families: [WidgetFamily]) -> ModifiedWidgetConfiguration<Self> {
        .init()
    }
}

@MainActor @preconcurrency
public protocol Widget {
    associatedtype Body: WidgetConfiguration
    init()
    @WidgetConfigurationBuilder var body: Body { get }
}

@MainActor @preconcurrency
public protocol WidgetBundle {
    associatedtype Body: Widget
    init()
    @WidgetBundleBuilder var body: Body { get }
}

@resultBuilder
public struct WidgetBundleBuilder {
    public static func buildBlock<W: Widget>(_ content: W) -> W { content }
    public static func buildBlock<each W: Widget>(_ content: repeat each W) -> TupleWidget<(repeat each W)> {
        TupleWidget()
    }
}

public struct TupleWidget<T>: Widget {
    public init() {}
    public var body: Never { fatalError() }
}

extension WidgetBundle {
    @MainActor public static func main() {}
}

public struct ContainerBackgroundPlacement: Hashable, Sendable {
    public static let widget = ContainerBackgroundPlacement()
}

extension View {
    public func widgetURL(_ url: URL?) -> some View { _widgetStub() }
    public func containerBackground<S: ShapeStyle>(
        _ style: S, for container: ContainerBackgroundPlacement
    ) -> some View {
        _widgetStub()
    }
    public func containerBackground<V: View>(
        for container: ContainerBackgroundPlacement, alignment: Alignment = .center,
        @ViewBuilder content: () -> V
    ) -> some View { _widgetStub() }

    /// 桩里没法用 SwiftUI 桩模块里的内部方法（`_m()`），这里自己包一层。
    fileprivate func _widgetStub() -> some View { self }
}

public final class WidgetCenter: @unchecked Sendable {
    public static let shared = WidgetCenter()
    public func reloadTimelines(ofKind kind: String) {}
    public func reloadAllTimelines() {}
}

// 真实 SDK 里在 Foundation（Apple 平台才有），Linux 的 Foundation 没有；用到它的文件都 import 了 WidgetKit，放这里。
extension FileManager {
    public func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        nil
    }
}
