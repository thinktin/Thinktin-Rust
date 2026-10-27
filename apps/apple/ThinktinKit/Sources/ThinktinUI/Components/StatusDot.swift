import SwiftUI
import ThinktinKit

/// 状态点：运行、实例的状态，颜色规则见 docs/ios.md 第 4 节（`RunState.statusAppearance`、
/// `InstanceState.statusAppearance`）。
///
/// 读屏读状态名（“运行中”）。和名字放在同一行时，外层用 `.accessibilityElement(children: .combine)` 合成一句；
/// 旁边已经写了状态名的，给状态点加 `.accessibilityHidden(true)`，免得念两遍。
/// 在动的状态（运行中、启动中、创建中）有一圈向外扩散的动画，开了“减弱动态效果”时不动。
public struct StatusDot: View {
    private let appearance: StatusAppearance
    private let label: (DisplayLanguage) -> String
    private let size: CGFloat

    @Environment(\.displayLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    /// 运行的状态。
    public init(_ state: RunState, size: CGFloat = Metrics.statusDot) {
        appearance = state.statusAppearance
        label = { state.localizedName($0) }
        self.size = size
    }

    /// 实例的状态。
    public init(_ state: InstanceState, size: CGFloat = Metrics.statusDot) {
        appearance = state.statusAppearance
        label = { state.localizedName($0) }
        self.size = size
    }

    /// 直接给样子和读屏文字（不是运行、实例的状态时用，比如“在线”）。
    public init(_ appearance: StatusAppearance, accessibilityLabel: String, size: CGFloat = Metrics.statusDot) {
        self.appearance = appearance
        label = { _ in accessibilityLabel }
        self.size = size
    }

    public var body: some View {
        let color = appearance.tone.color
        dot(color)
            .frame(width: size, height: size)
            .background {
                if appearance.pulses && !reduceMotion {
                    Circle()
                        .fill(color.opacity(0.35))
                        .scaleEffect(isPulsing ? 2.4 : 1)
                        .opacity(isPulsing ? 0 : 1)
                }
            }
            // 扩散的圈画在背景里，不占布局：行高只按点本身算。
            .onAppear { startPulsing() }
            .onChange(of: reduceMotion) { startPulsing() }
            .onChange(of: appearance) { startPulsing() }
            .accessibilityElement()
            .accessibilityLabel(Text(label(language)))
    }

    @ViewBuilder
    private func dot(_ color: Color) -> some View {
        if appearance.isHollow {
            Circle().strokeBorder(color, lineWidth: max(1, size / 5))
        } else {
            Circle().fill(color)
        }
    }

    private func startPulsing() {
        guard appearance.pulses, !reduceMotion else {
            isPulsing = false
            return
        }
        isPulsing = false
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
            isPulsing = true
        }
    }
}

#Preview("运行状态") {
    VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
        ForEach(RunState.knownCases, id: \.self) { state in
            HStack(spacing: Metrics.Spacing.xs) {
                StatusDot(state)
                Text(state.localizedName(.chinese)).typography(.body)
            }
        }
    }
    .padding()
    .background(Theme.paper)
}

#Preview("实例状态 · 深色") {
    VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
        ForEach(InstanceState.knownCases, id: \.self) { state in
            HStack(spacing: Metrics.Spacing.xs) {
                StatusDot(state)
                Text(state.localizedName(.english)).typography(.body).foregroundStyle(Theme.ink)
            }
        }
    }
    .padding()
    .background(Theme.paper)
    .environment(\.displayLanguage, .english)
    .preferredColorScheme(.dark)
}
