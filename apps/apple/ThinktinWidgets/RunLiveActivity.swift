import ActivityKit
import SwiftUI
import ThinktinKit
import WidgetKit

/// 运行的实时活动（WBS 12.10）：锁屏横幅和灵动岛。只显示实例名、状态、步数、耗时（推送里也只有这些，锁屏上谁都
/// 看得见）；点开去运行详情（深链 `thinktin://run/{id}`）。文案跟着系统语言。
struct RunLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunActivityAttributes.self) { context in
            RunActivityBanner(attributes: context.attributes, state: context.state)
                .padding(16)
                .widgetURL(Self.url(context.attributes))
        } dynamicIsland: { context in
            let state = context.state
            let language = RunActivityBanner.language
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.title).lineLimit(1)
                    } icon: {
                        StateIcon(state: state)
                    }
                    .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedText(state: state, language: language)
                        .font(.headline)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(LiveActivityText.headline(state, language: language)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(LiveActivityText.steps(state.steps, language: language))
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            } compactLeading: {
                StateIcon(state: state)
            } compactTrailing: {
                ElapsedText(state: state, language: language)
                    .monospacedDigit()
                    .frame(maxWidth: 52)
            } minimal: {
                StateIcon(state: state)
            }
            .widgetURL(Self.url(context.attributes))
        }
    }

    static func url(_ attributes: RunActivityAttributes) -> URL? {
        DeepLink.url(for: .run(RunID(attributes.runId)))
    }
}

/// 锁屏上的横幅（也是通知中心里的样子）。
struct RunActivityBanner: View {
    let attributes: RunActivityAttributes
    let state: RunActivityContentState

    static var language: DisplayLanguage {
        DisplayLanguage(languageTag: Locale.preferredLanguages.first ?? "zh-Hans")
    }

    var body: some View {
        let language = Self.language
        HStack(alignment: .center, spacing: 12) {
            StateIcon(state: state)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(attributes.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(LiveActivityText.headline(state, language: language))
                    .font(.subheadline)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                ElapsedText(state: state, language: language)
                    .font(.headline)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                Text(LiveActivityText.steps(state.steps, language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 状态图标：要用户做点什么（等审批、等 key 要处理）时用醒目的颜色。
private struct StateIcon: View {
    let state: RunActivityContentState

    var body: some View {
        Image(systemName: LiveActivityText.symbol(state.runState))
            .foregroundStyle(LiveActivityText.needsAttention(state) ? Color.orange : Color.accentColor)
    }
}

/// 耗时：还在跑的用系统的计时器（不用推送也会走），结束了的显示用了多久，还没开始的不显示。
private struct ElapsedText: View {
    let state: RunActivityContentState
    let language: DisplayLanguage

    var body: some View {
        if let text = LiveActivityText.elapsed(state, language: language) {
            Text(text)
        } else if let start = state.startDate {
            Text(timerInterval: start...start.addingTimeInterval(LiveActivityLimits.maxAge), countsDown: false)
        } else {
            Text(verbatim: "")
        }
    }
}
