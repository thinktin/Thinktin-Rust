// WidgetKit 里实时活动的界面（WBS 12.10）：锁屏横幅、灵动岛。签名照 iOS 17 SDK，只放用到的。
import ActivityKit
import SwiftUI

public struct ActivityViewContext<Attributes: ActivityAttributes> {
    public let attributes: Attributes
    public let state: Attributes.ContentState
    public let isStale: Bool
    public let activityID: String
}

public struct ActivityConfiguration<Attributes: ActivityAttributes>: WidgetConfiguration {
    public init<Content: View>(
        for attributesType: Attributes.Type,
        @ViewBuilder content: @escaping (ActivityViewContext<Attributes>) -> Content,
        dynamicIsland: @escaping (ActivityViewContext<Attributes>) -> DynamicIsland
    ) {}
    public var body: Never { fatalError() }
}

public struct DynamicIslandExpandedRegionPosition: Hashable, Sendable {
    let v: Int
    public static let leading = DynamicIslandExpandedRegionPosition(v: 0)
    public static let trailing = DynamicIslandExpandedRegionPosition(v: 1)
    public static let center = DynamicIslandExpandedRegionPosition(v: 2)
    public static let bottom = DynamicIslandExpandedRegionPosition(v: 3)
}

public struct DynamicIslandExpandedRegion<Content: View> {
    public init(
        _ position: DynamicIslandExpandedRegionPosition, priority: Double = 0, @ViewBuilder content: () -> Content
    ) {}
}

public struct DynamicIslandExpandedContent<Content> {}

@resultBuilder
public struct DynamicIslandExpandedContentBuilder {
    public static func buildBlock<each C: View>(_ content: repeat DynamicIslandExpandedRegion<each C>)
        -> DynamicIslandExpandedContent<(repeat each C)>
    { DynamicIslandExpandedContent() }
}

public struct DynamicIsland {
    public init<Expanded, CompactLeading: View, CompactTrailing: View, Minimal: View>(
        @DynamicIslandExpandedContentBuilder expanded: () -> DynamicIslandExpandedContent<Expanded>,
        @ViewBuilder compactLeading: () -> CompactLeading,
        @ViewBuilder compactTrailing: () -> CompactTrailing,
        @ViewBuilder minimal: () -> Minimal
    ) {}
    public func widgetURL(_ url: URL?) -> DynamicIsland { self }
    public func keylineTint(_ color: Color?) -> DynamicIsland { self }
}
