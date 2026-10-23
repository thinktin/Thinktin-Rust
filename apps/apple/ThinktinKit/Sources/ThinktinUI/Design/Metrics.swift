import CoreGraphics

/// 尺寸令牌（docs/ios.md 第 4 节）：圆角卡片 16、输入框 24、小控件 10；间距都是 4 的倍数。
public enum Metrics {
    /// 圆角（都用 `.continuous` 的圆角样式）。
    public enum Radius {
        /// 卡片、用户消息、横幅。
        public static let card: CGFloat = 16
        /// 底部输入框（单行时看起来是胶囊）。
        public static let input: CGFloat = 24
        /// 小控件：标签、小按钮、代码块。
        public static let control: CGFloat = 10
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
    /// 抽屉的最大宽度。
    public static let drawerMaxWidth: CGFloat = 320
    /// 正文的最大可读宽度（横屏、大屏时居中）。
    public static let readableWidth: CGFloat = 680

    /// 一个物理像素宽的分隔线：`1 / displayScale`（从 `@Environment(\.displayScale)` 取）。
    public static func hairline(scale: CGFloat) -> CGFloat {
        scale > 0 ? 1 / scale : 1
    }
}
