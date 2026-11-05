import SwiftUI
import ThinktinKit

/// 自己的账号头像（设置根页和账号页的第一行、首页左上；参考 53、54）：中性灰的圆，里面是名字的第一个字（次要文字色），
/// 和 Botin 按名字取色的彩色头像分得开。底色用 `Theme.userBubble`（你自己发的消息也是这个灰）。名字是空的（还没拉到
/// 用户）放 `person.fill`。只是装饰：旁边都写着名字，读屏由调用方处理（这里对读屏隐藏）。
struct AccountAvatar: View {
    private let name: String
    /// 直径，跟着动态字体缩放。
    @ScaledMetric private var size: CGFloat

    init(_ name: String, size: CGFloat) {
        self.name = name
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    var body: some View {
        glyph
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: size, height: size)
            .background(Theme.userBubble, in: Circle())
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
        } else {
            Text(verbatim: AgentsText.monogram(of: name))
                .font(.system(size: size * 0.4, weight: .semibold))
        }
    }
}
