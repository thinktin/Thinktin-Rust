import SwiftUI
import ThinktinKit

/// 头像选择（新建 Botin 表单和建好之后改头像共用；规范 4.4.4、4.7.1，参考 18、34）：形状网格（3 × 5，`AvatarShape`）和色板
/// （2 × 6 个鲜明的颜色，选中的带环，`AvatarColor`），两块之间不画分隔线（参考 18）；每一格都是那个形状的脸，用现在选的颜色
/// （没选按名字取）画。选中的形状、颜色外面都是同一种中性灰的细环（`AvatarPickerStyle`）。
/// 选中的那一格是活的（用户 2026-11-06：“选头像的时候，选中时候要有动作展示”）：选中的一刻跳一下、笑一下（`tap` 反应），
/// 选着的时候和在跑的 Botin 一样眨眼、往四处看、随机做小动作；别的格子不动。上面的大预览是 `AvatarPickerPreview`。
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
    /// 选中那一格的节奏（和上面的大预览用同一个）；nil 时按名字定。
    var life: BotinFaceLife?
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
        showsCard: Bool = true, life: BotinFaceLife? = nil, @ViewBuilder footer: () -> Footer
    ) {
        self.name = name
        self.shape = shape
        self.color = color
        self.resolvedColor = resolvedColor
        self.showsCard = showsCard
        self.life = life
        self.footer = footer()
    }

    var body: some View {
        let shape = self.shape
        let color = self.color
        VStack(spacing: Metrics.Spacing.m) {
            LazyVGrid(columns: Self.shapeColumns, spacing: Metrics.Spacing.xs) {
                ForEach(AvatarShape.allCases, id: \.self) { option in
                    AvatarShapeCell(
                        shape: option, name: name, color: color.wrappedValue, isSelected: shape.wrappedValue == option,
                        life: life
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
        showsCard: Bool = true, life: BotinFaceLife? = nil
    ) {
        self.init(
            name: name, shape: shape, color: color, resolvedColor: resolvedColor, showsCard: showsCard, life: life
        ) {
            EmptyView()
        }
    }
}

/// 头像选择上面的大预览（新建表单 120pt、改头像页 80pt）：选的形状、选的颜色（没选按名字取）画的脸，一直是活的（`active`：
/// 眨眼、往四处看、随机做小动作）；换形状时变形过去、挑颜色时渐变（`BotinFace` 自己做），挑了形状或颜色 0.3 秒后笑一下
/// （`happy` 反应，等变形差不多做完），点一下跳一下（`tap` 反应）。固定大小（不跟动态字体缩放）；只是装饰，读屏不念
/// （网格自己会念）。减弱动态效果时不动、不做反应，换形状、颜色直接换。
struct AvatarPickerPreview: View {
    let name: String
    let appearance: InstanceAppearance
    let size: CGFloat
    /// 节奏（新建表单给一个固定的，见 `BotinFace.life`）；nil 时按名字定。
    var life: BotinFaceLife?

    @State private var reactions: [BotinFaceReaction] = []

    /// 挑了形状、颜色以后隔多久笑。
    static let happyDelay: TimeInterval = 0.3

    var body: some View {
        BotinFace(name: name, appearance: appearance, size: size, mood: .active, reactions: reactions, life: life)
            .contentShape(Rectangle())
            .onTapGesture { react(.tap, after: 0) }
            .onChange(of: appearance) { react(.happy, after: Self.happyDelay) }
            .accessibilityHidden(true)
    }

    private func react(_ gesture: BotinFaceGesture, after delay: TimeInterval) {
        let now = Date().timeIntervalSinceReferenceDate
        reactions = BotinFaceReaction.adding(
            BotinFaceReaction(gesture, start: now + delay), to: reactions, now: now)
    }
}

/// 头像选择里选中的环：形状网格、色板选中的那一格外面一圈细的中性灰环（参考 18），不用强调色的框，也不用那一格自己的颜色。
/// 环和颜色之间隔着一圈底色，所以在哪种颜色上都看得见（灰色、琥珀黄这种和环、和浅色的底挨得近的也是）；环本身和底
/// （`paper`、`paperElevated`，新建表单的 sheet、改头像页的卡片）的对比度浅色、深色外观都在 3:1 以上（测试查）。
enum AvatarPickerStyle {
    /// 环的颜色（次要文字色，系统的 `secondaryLabel`）。
    static let ring = ThemeToken.inkSecondary
    /// 环的粗细。
    static let ringWidth: CGFloat = 2
}

/// 形状网格的一格：这个形状的脸、现在的颜色，按格子的宽度画（窄屏、大字号时也不会挤出格子）；换颜色时照样渐变。没选中的
/// 不动（一屏十五个一起动太闹）；选中的一刻跳一下、笑一下（`tap` 反应），选着的时候是活的（`active`）。选中的外面一圈细的
/// 中性灰环（`AvatarPickerStyle`），贴着形状（参考 18）。
private struct AvatarShapeCell: View {
    static let maxSide: CGFloat = 56

    let shape: AvatarShape
    let name: String
    let color: AvatarColor?
    let isSelected: Bool
    let life: BotinFaceLife?
    let action: @MainActor () -> Void

    /// 选中时的反应（换到别的格子以后，这一格还没做完的照样做完再停）。
    @State private var reactions: [BotinFaceReaction] = []
    @Environment(\.displayLanguage) private var language

    var body: some View {
        let ring = Circle()
        let appearance = InstanceAppearance(shape: shape, color: color)
        Button(action: action) {
            GeometryReader { proxy in
                BotinFace(
                    name: name, appearance: appearance, size: min(proxy.size.width, proxy.size.height),
                    mood: isSelected ? .active : .resting, reactions: reactions, life: life
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(Metrics.Spacing.xs)
            .overlay {
                if isSelected {
                    ring.strokeBorder(AvatarPickerStyle.ring.color, lineWidth: AvatarPickerStyle.ringWidth)
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
        .onChange(of: isSelected) {
            guard isSelected else { return }
            let now = Date().timeIntervalSinceReferenceDate
            reactions = BotinFaceReaction.adding(BotinFaceReaction(.tap, start: now), to: reactions, now: now)
        }
    }
}

/// 色板的一个点（`InstanceAvatar.fill(of:)`）；选中的外面隔一圈底色画一个中性灰的环（`AvatarPickerStyle`，参考 18）。
/// 以前用同色的环，换成鲜明的颜色以后琥珀黄的环在浅色的底上几乎看不见。
private struct AvatarColorDot: View {
    let color: AvatarColor
    let isSelected: Bool
    let action: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    private static let dot: CGFloat = 30

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(InstanceAvatar.fill(of: color))
                .frame(width: Self.dot, height: Self.dot)
                .padding(Metrics.Spacing.xxs + 1)
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(AvatarPickerStyle.ring.color, lineWidth: AvatarPickerStyle.ringWidth)
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
