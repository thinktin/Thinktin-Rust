import SwiftUI
import ThinktinKit
import WidgetKit

/// 主屏、锁屏小组件（WBS 12.20）：未读、待审批、进行中三个数。只读 App 写进 App Group 的快照
/// （`WidgetSnapshotFile`），不连服务端；App 在数变了时让 WidgetKit 重新取时间线，这里每半小时自己再取一次
/// （“几分钟前更新”跟着变）。文案跟着系统语言（读不到 App 里选的语言）。
///
/// 点小组件打开收件箱；中号的三个数各自能点：收件箱、审批中心、进行中（深链，`DeepLink`）。
struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.widgetKind, provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
        }
        .configurationDisplayName("ThinkTin")
        .description(WidgetText.description(StatusEntry.language))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct StatusEntry: TimelineEntry {
    let date: Date
    /// nil：App 还没写过（装好还没打开过）。
    let snapshot: WidgetSnapshot?

    static var language: DisplayLanguage {
        DisplayLanguage(languageTag: Locale.preferredLanguages.first ?? "zh-Hans")
    }
}

struct StatusProvider: TimelineProvider {
    /// 多久自己再读一次文件（数变了 App 会让 WidgetKit 马上刷新，这个只管“几分钟前更新”）。
    static let refreshInterval: TimeInterval = 30 * 60

    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), snapshot: .placeholder(at: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        let now = Date()
        // 小组件库里预览：还没有数时给示例的数。
        let snapshot = Self.read() ?? (context.isPreview ? .placeholder(at: now) : nil)
        completion(StatusEntry(date: now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let now = Date()
        let entry = StatusEntry(date: now, snapshot: Self.read())
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(Self.refreshInterval))))
    }

    private static func read() -> WidgetSnapshot? {
        guard
            let directory = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: WidgetSnapshotFile.appGroup)
        else { return nil }
        return WidgetSnapshotFile(directory: directory).load()
    }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusEntry

    private var language: DisplayLanguage { StatusEntry.language }

    var body: some View {
        content
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(DeepLink.url(for: .inbox))
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = entry.snapshot, snapshot.signedIn {
            switch family {
            case .accessoryRectangular: rectangular(snapshot)
            case .systemMedium: medium(snapshot)
            default: small(snapshot)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("ThinkTin").font(.headline)
                Text(WidgetText.signedOut(language)).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CountRow(value: snapshot.inboxUnread, label: WidgetText.unread(language), systemImage: "tray")
            CountRow(
                value: snapshot.pendingApprovals, label: WidgetText.approvals(language), systemImage: "checkmark.shield"
            )
            CountRow(value: snapshot.activeRuns, label: WidgetText.active(language), systemImage: "bolt")
            Spacer(minLength: 0)
            updated(snapshot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                CountTile(
                    value: snapshot.inboxUnread, label: WidgetText.unread(language), destination: .inbox)
                CountTile(
                    value: snapshot.pendingApprovals, label: WidgetText.approvals(language), destination: .approvals)
                CountTile(
                    value: snapshot.activeRuns, label: WidgetText.active(language), destination: .activeRuns)
            }
            updated(snapshot)
        }
    }

    private func rectangular(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ThinkTin").font(.headline)
            Text(
                verbatim:
                    "\(WidgetText.unread(language)) \(snapshot.inboxUnread) · \(WidgetText.approvals(language)) \(snapshot.pendingApprovals)"
            )
            Text(verbatim: "\(WidgetText.active(language)) \(snapshot.activeRuns)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func updated(_ snapshot: WidgetSnapshot) -> some View {
        Text(WidgetText.updated(snapshot.updatedAt, now: entry.date, language: language))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// 小号里的一行：图标、数、名字。
private struct CountRow: View {
    let value: Int
    let label: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(value > 0 ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            Text(ShellBadges.text(value)).font(.title3.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 中号里的一格：点了去对应的页面。
private struct CountTile: View {
    let value: Int
    let label: String
    let destination: AppRoute

    var body: some View {
        Link(destination: DeepLink.url(for: destination) ?? URL(string: "thinktin://inbox")!) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ShellBadges.text(value)).font(.title.bold()).monospacedDigit()
                    .foregroundStyle(value > 0 ? Color.primary : Color.secondary)
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
