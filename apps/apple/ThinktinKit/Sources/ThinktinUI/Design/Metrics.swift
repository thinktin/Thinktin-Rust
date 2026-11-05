import CoreGraphics

/// 尺寸令牌（docs/ios.md 第 4 节，改版见 docs/ios-ui-redesign.md 2.4）：自己画的卡片和消息气泡圆角 20、带引用的输入卡片 28、
/// 小控件 10；分组卡片的圆角、导航栏按钮的尺寸由系统给，不自己设；间距都是 4 的倍数。
public enum Metrics {
    /// 圆角（都用 `.continuous` 的圆角样式）。
    public enum Radius {
        /// 消息气泡、自己画的卡片（工具调用、审批）、横幅。`List` 的 insetGrouped 分组卡片用系统自带的圆角。
        public static let card: CGFloat = 20
        /// 输入框带引用、长成卡片时的圆角（单行时是胶囊：圆角取输入框高度的一半，`ComposerBar`）。
        public static let composerCard: CGFloat = 28
        /// 小控件：标签、小按钮、代码块、应用 / agent 的图标方块。
        public static let control: CGFloat = 10
    }

    /// 实例头像（`InstanceAvatar`）的直径，跟着动态字体缩放。
    public enum Avatar {
        /// 导航栏里：标题胶囊、首页左上的账号按钮（放在工具栏的玻璃圆里）。
        public static let title: CGFloat = 24
        /// 搜索结果的行。
        public static let search: CGFloat = 40
        /// 首页列表的行。
        public static let list: CGFloat = 48
        /// 首页置顶的网格。
        public static let pinned: CGFloat = 80
        /// 编辑实例页。
        public static let edit: CGFloat = 100
        /// 实例资料页的头部。
        public static let profile: CGFloat = 120
    }

    /// 间距：4 的倍数。
    public enum Spacing {
        /// 间距的基本单位。
        public static let unit: CGFloat = 4

        /// `n` 个单位（`Spacing.units(3)` = 12）。
        public static func units(_ n: Int) -> CGFloat { CGFloat(n) * unit }

        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let s: CGFloat = 12
        /// 页边距、卡片内边距。
        public static let m: CGFloat = 16
        public static let l: CGFloat = 20
        /// 消息之间、分组之间。
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let xxxl: CGFloat = 48
    }

    /// 可点区域的最小边长（Human Interface Guidelines：44 × 44）。
    public static let minTapTarget: CGFloat = 44
    /// 状态点的直径。
    public static let statusDot: CGFloat = 8
    /// 发送按钮这类圆形图标按钮的直径。
    public static let iconButton: CGFloat = 32
    /// 正文的最大可读宽度（横屏、大屏时居中）。
    public static let readableWidth: CGFloat = 680

    /// 一个物理像素宽的分隔线：`1 / displayScale`（从 `@Environment(\.displayScale)` 取）。
    public static func hairline(scale: CGFloat) -> CGFloat {
        scale > 0 ? 1 / scale : 1
    }
}
