// 连接目录（ThinktinUI/Screens/Connections，改版规范 4.8）用到的桩：应用图标方块的系统色。
// 签名照 iOS 17 / macOS 14 SDK（`Color` 的这几个静态属性 iOS 13 起就有；`orange` 在 SwiftUI+Widgets.swift 里）。

extension Color {
    public static let red = Color(red: 1, green: 0.23, blue: 0.19)
    public static let yellow = Color(red: 1, green: 0.8, blue: 0)
    public static let green = Color(red: 0.2, green: 0.78, blue: 0.35)
    public static let teal = Color(red: 0.19, green: 0.69, blue: 0.78)
    public static let blue = Color(red: 0, green: 0.48, blue: 1)
    public static let indigo = Color(red: 0.35, green: 0.34, blue: 0.84)
    public static let purple = Color(red: 0.69, green: 0.32, blue: 0.87)
    public static let pink = Color(red: 1, green: 0.18, blue: 0.33)
}
