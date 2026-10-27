import Charts
import SwiftUI
import ThinktinKit

/// 按天的 token 用量柱状图（Swift Charts）。柱子用强调色（不是状态），横轴是日期（“10/22”，按看板的时区），
/// 纵轴是 token 数（中文按“万”，英文按 K / M）。读屏时每根柱子念日期、token 数、请求数和失败次数。
///
/// 传给 Charts 的闭包里只用先取好的值（语言、日历）和不隔离的函数，不读视图的状态：
/// Charts 的内容闭包、坐标轴闭包不一定在主线程的隔离域里（Swift 6 的严格并发检查）。
struct UsageChart: View {
    let points: [UsageDayPoint]
    /// 按天分组用的时区（和看板一致）。
    let timeZone: TimeZone

    @Environment(\.displayLanguage) private var language
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 200

    var body: some View {
        let language = self.language
        let calendar = UsageChartFormat.calendar(timeZone)
        let xTitle = language == .chinese ? "日期" : "Date"
        Chart(points) { point in
            BarMark(
                x: .value(xTitle, point.date, unit: .day),
                y: .value("Tokens", point.tokens)
            )
            .foregroundStyle(Theme.accent)
            .cornerRadius(3)
            .accessibilityLabel(Text(UsageChartFormat.spokenDate(point.date, calendar: calendar, language: language)))
            .accessibilityValue(Text(point.accessibilityValue(language)))
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(points.count, 7))) { value in
                AxisGridLine()
                    .foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(UsageChartFormat.axisText(date, calendar: calendar))
                            .font(Typography.caption2.font)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                    .foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let tokens = value.as(Int.self) {
                        Text(Formatting.tokens(tokens, language: language))
                            .font(Typography.caption2.font)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel(Text(language == .chinese ? "每天的 token 用量" : "Tokens per day"))
    }
}

/// 图上的日期文字（纯函数，不隔离，Charts 的闭包里能调）。
enum UsageChartFormat {
    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// 横轴上的“10/22”。
    static func axisText(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 1)/\(c.day ?? 1)"
    }

    /// 读屏念的“10月22日” / “Oct 22”。
    static func spokenDate(_ date: Date, calendar: Calendar, language: DisplayLanguage) -> String {
        Formatting.shortDate(date, language: language, calendar: calendar)
    }
}

#Preview("用量图 · 浅色中文") {
    UsageChart(points: UsageChartPreview.points, timeZone: .current)
        .padding()
        .background(Theme.paper)
        .environment(\.displayLanguage, .chinese)
}

#Preview("用量图 · 深色英文") {
    UsageChart(points: UsageChartPreview.points, timeZone: .current)
        .padding()
        .background(Theme.paper)
        .environment(\.displayLanguage, .english)
        .preferredColorScheme(.dark)
}

/// 预览、界面测试用的一周数据（演示数据里的按天用量）。
enum UsageChartPreview {
    static var points: [UsageDayPoint] {
        let calendar = UsageChartFormat.calendar(.current)
        let today = calendar.startOfDay(for: Date())
        let scales = [3, 5, 2, 8, 6, 4, 7]
        return (0..<7).map { i in
            let date = calendar.date(byAdding: .day, value: i - 6, to: today) ?? today
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            let key = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 1, c.day ?? 1)
            let s = scales[i]
            return UsageDayPoint(
                date: date, key: key,
                bucket: UsageBucket(
                    key: key, requests: 40 * s, inputTokens: 52_000 * s, cacheReadTokens: 31_000 * s,
                    outputTokens: 9_000 * s, failedRequests: i == 5 ? 3 : 0))
        }
    }
}
