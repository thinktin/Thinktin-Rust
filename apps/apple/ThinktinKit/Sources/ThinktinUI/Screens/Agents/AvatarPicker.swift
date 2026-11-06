import SwiftUI
import ThinktinKit

/// 头像选择（新建 Botin 表单和建好之后改头像共用；规范 4.4.4、4.7.1，参考 18、34）：形状网格（3 × 5，`AvatarShape`）和色板
/// （2 × 6，选中的带环，`AvatarColor`），两块之间不画分隔线（参考 18）；每一格都是那个形状的脸，用现在选的颜色（没选按名字取）画。
/// 改头像页放在一张卡片里（参考 18），卡片最下面加分隔线和“重置为默认”（`footer`）；新建表单直接画在 sheet 的底上
/// （参考 34、35、117，`showsCard: false`）。不能改时调用方加 `.disabled`。
struct AvatarPicker<Footer: View>: View {
    let name: String
    let shape: Binding<AvatarShape>
    /// 挑的颜色；nil 是按名字取。
    let color: Binding<AvatarColor?>
    /// 色板上带环的颜色（挑过的，没挑过是按名字取的那个）。
    let resolvedColor: AvatarColor
    /// 画不画卡片底（`paperElevated` 圆角卡片和上下的内边距）。
    var showsCard = true
    private let footer: Footer

    @Environment(\.displayLanguage) private var language

    private static var shapeColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Metrics.Spacing.xs), count: 5)
    }

    private static var colorColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Metrics.Spacing.xs), count: 6)
    }

    init(
        name: String, shape: Binding<AvatarShape>, color: Binding<AvatarColor?>, resolvedColor: AvatarColor,
        showsCard: Bool = true, @ViewBuilder footer: () -> Footer
    ) {
        self.name = name
        self.shape = shape
        self.color = color
        self.resolvedColor = resolvedColor
        self.showsCard = showsCard
        self.footer = footer()
    }

    var body: some View {
        let shape = self.shape
        let color = self.color
        VStack(spacing: Metrics.Spacing.m) {
            LazyVGrid(columns: Self.shapeColumns, spacing: Metrics.Spacing.xs) {
                ForEach(AvatarShape.allCases, id: \.self) { option in
                    AvatarShapeCell(
                        shape: option, name: name, color: color.wrappedValue, isSelected: shape.wrappedValue == option
                    ) {
                        shape.wrappedValue = option
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(NewBotinText.shapeTitle(language)))
            LazyVGrid(columns: Self.colorColumns, spacing: Metrics.Spacing.xs) {
                ForEach(AvatarColor.allCases, id: \.self) { option in
                    AvatarColorDot(color: option, isSelected: resolvedColor == option) {
                        color.wrappedValue = option
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(NewBotinText.colorTitle(language)))
            footer
        }
        .padding(.horizontal, Metrics.Spacing.m)
        .padding(.vertical, showsCard ? Metrics.Spacing.m : 0)
        .background(
            showsCard ? Theme.paperElevated : Color.clear,
            in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
        )
        .appFeedback(
            .selection, trigger: InstanceAppearance(shape: shape.wrappedValue, color: color.wrappedValue))
    }
}

extension AvatarPicker where Footer == EmptyView {
    init(
        name: String, shape: Binding<AvatarShape>, color: Binding<AvatarColor?>, resolvedColor: AvatarColor,
        showsCard: Bool = true
    ) {
        self.init(name: name, shape: shape, color: color, resolvedColor: resolvedColor, showsCard: showsCard) {
            EmptyView()
        }
    }
}

/// 形状网格的一格：这个形状的脸、现在的颜色，按格子的宽度画（窄屏、大字号时也不会挤出格子）；不眨眼、不转眼（一屏
/// 十五个一起动太闹，上面的大预览会动），换颜色时照样渐变。选中的外面一圈细的中性灰环，贴着形状（参考 18），不用强调色的框。
private struct AvatarShapeCell: View {
    static let maxSide: CGFloat = 56

    let shape: AvatarShape
    let name: String
    let color: AvatarColor?
    let isSelected: Bool
    let action: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let ring = Circle()
        let appearance = InstanceAppearance(shape: shape, color: color)
        Button(action: action) {
            GeometryReader { proxy in
                BotinFace(
                    name: name, appearance: appearance, size: min(proxy.size.width, proxy.size.height), live: false
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(Metrics.Spacing.xs)
            .overlay {
                if isSelected {
                    ring.strokeBorder(Theme.inkSecondary, lineWidth: 2)
                }
            }
            .contentShape(ring)
            // 格子最大 56pt（形状 40pt）：按整列宽画时三行太高，新建表单的色板被挤到底部的“新建”按钮后面（2026-11-05 截图）；
            // 参考稿的形状也是这么大。窄屏、大字号时照样按列宽缩小。
            .frame(maxWidth: Self.maxSide)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(shape.localizedName(language)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 色板的一个点；选中的外面一圈同色的环。
private struct AvatarColorDot: View {
    let color: AvatarColor
    let isSelected: Bool
    let action: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    private static let dot: CGFloat = 30

    var body: some View {
        let hex = InstanceAvatar.colors(of: color)
        let fill = Color(light: hex.light, dark: hex.dark)
        Button(action: action) {
            Circle()
                .fill(fill)
                .frame(width: Self.dot, height: Self.dot)
                .padding(Metrics.Spacing.xxs + 1)
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(fill, lineWidth: 2.5)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(color.localizedName(language)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
