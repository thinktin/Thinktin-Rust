import SwiftUI
import ThinktinKit

// 账号与设备页面（WBS 12.2）共用的小组件：分组、行、勾选框、验证码框、协议链接、登录时带的推送令牌。
// 版式参考 Claude iOS App 的设置页：纸色底上一组组圆角卡片，行里左边图标、中间标题、右边值或箭头。

/// 用户协议、隐私政策的地址（16.4 定稿后由法务发布；12.12 的关于页也用这两个）。
enum AccountLinks {
    static let userAgreement = URL(string: "https://thinktin.cn/legal/terms")!
    static let privacyPolicy = URL(string: "https://thinktin.cn/legal/privacy")!
}

/// 登录时带上的推送令牌（12.8 拿到 APNs 设备令牌后注入：`.environment(\.signInPushRegistration, …)`）。
/// 没注入时登录不带令牌，12.8 登录后再 `setPushToken`。
public struct SignInPushRegistration: Sendable {
    public var fetch: @MainActor @Sendable () async -> PushRegistration?

    public init(_ fetch: @escaping @MainActor @Sendable () async -> PushRegistration?) {
        self.fetch = fetch
    }

    /// 不带令牌。
    public static let none = SignInPushRegistration { nil }
}

private struct SignInPushRegistrationKey: EnvironmentKey {
    static let defaultValue = SignInPushRegistration.none
}

extension EnvironmentValues {
    /// 登录时带上的推送令牌（见 `SignInPushRegistration`）。
    public var signInPushRegistration: SignInPushRegistration {
        get { self[SignInPushRegistrationKey.self] }
        set { self[SignInPushRegistrationKey.self] = newValue }
    }
}

/// 一组：小标题、圆角卡片里的几行、可选的脚注。
struct AccountSection<Content: View>: View {
    var title: String?
    var footer: String?
    let content: Content

    @Environment(\.displayScale) private var displayScale

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            if let title {
                Text(title)
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.horizontal, Metrics.Spacing.m)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.paperElevated, in: shape)
            .overlay { shape.strokeBorder(Theme.hairline, lineWidth: Metrics.hairline(scale: displayScale)) }
            if let footer {
                Text(footer)
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metrics.Spacing.m)
            }
        }
    }
}

/// 一组里两行之间的分隔线（从文字开始，不贯穿图标）。
struct AccountRowDivider: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: Metrics.hairline(scale: displayScale))
            .padding(.leading, Metrics.Spacing.m + Metrics.Spacing.xl + Metrics.Spacing.s)
    }
}

/// 一行：图标、标题（可带副标题）、右边的值，可选箭头。整行可点时外面包 `Button` / `NavigationLink`。
struct AccountRow: View {
    let systemImage: String
    let title: String
    var subtitle: String?
    var value: String?
    var tone: Tone = .normal
    var showsChevron = false

    enum Tone {
        case normal
        /// 危险操作（全部停止、注销）：图标和标题用危险色。
        case destructive
    }

    var body: some View {
        HStack(spacing: Metrics.Spacing.s) {
            Image(systemName: systemImage)
                .frame(width: Metrics.Spacing.xl)
                .foregroundStyle(tone == .destructive ? Theme.danger : Theme.inkSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                Text(title)
                    .typography(.body)
                    .foregroundStyle(tone == .destructive ? Theme.danger : Theme.ink)
                if let subtitle {
                    Text(subtitle)
                        .typography(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Metrics.Spacing.xs)
            if let value {
                Text(value)
                    .typography(.body)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(Typography.footnote.font.weight(.semibold))
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Metrics.Spacing.m)
        .padding(.vertical, Metrics.Spacing.s)
        .frame(minHeight: Metrics.minTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// 勾选框（同意协议、“我已了解注销后无法恢复”）：圆形的勾，读屏读成“已选中 / 未选中”的按钮。
/// 文字可以带链接（`AttributedString` 的 `link`），链接单独可点，不会顺带勾选。
struct CheckboxRow: View {
    let isOn: Bool
    let label: AttributedString
    /// 读屏念的名字（链接的文字念不清楚时给一句完整的）。
    let accessibilityLabel: String
    let toggle: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.xs) {
            Button(action: toggle) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .typography(.body)
                    .foregroundStyle(isOn ? Theme.accent : Theme.inkTertiary)
                    .frame(minWidth: Metrics.minTapTarget, minHeight: Metrics.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityValue(Text(checkedText))
            .accessibilityAddTraits(isOn ? .isSelected : [])
            // 文字不加点按手势：里面的链接要能单独点开。
            Text(label)
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension CheckboxRow {
    fileprivate var checkedText: String {
        let zh = language == .chinese
        return isOn ? (zh ? "已勾选" : "Checked") : (zh ? "未勾选" : "Not checked")
    }
}

extension AttributedString {
    /// 普通文字和链接拼在一起（“我已阅读并同意《用户协议》和《隐私政策》”）。
    static func withLinks(_ parts: [(String, URL?)]) -> AttributedString {
        var result = AttributedString()
        for (text, url) in parts {
            var piece = AttributedString(text)
            // 链接的颜色跟着外面的 `tint`（`AppShell` 设成了强调色）。
            if let url { piece.link = url }
            result.append(piece)
        }
        return result
    }

    /// 同意协议那一句。
    static func termsConsent(_ language: DisplayLanguage) -> AttributedString {
        language == .chinese
            ? withLinks([
                ("我已阅读并同意", nil), ("《用户协议》", AccountLinks.userAgreement), ("和", nil),
                ("《隐私政策》", AccountLinks.privacyPolicy),
            ])
            : withLinks([
                ("I have read and agree to the ", nil), ("Terms of Service", AccountLinks.userAgreement),
                (" and the ", nil), ("Privacy Policy", AccountLinks.privacyPolicy), (".", nil),
            ])
    }
}

/// 验证码框：大号等宽数字、居中，系统从短信里自动填充（`oneTimeCode`），数字键盘。
struct VerificationCodeField: View {
    let code: String
    let onChange: @MainActor (String) -> Void
    var isDisabled = false
    var onSubmit: (@MainActor () -> Void)?

    @Environment(\.displayLanguage) private var language
    @Environment(\.displayScale) private var displayScale
    @FocusState private var isFocused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
        TextField(
            language == .chinese ? "6 位验证码" : "6-digit code",
            text: Binding(get: { code }, set: { onChange($0) })
        )
        .font(Typography.title2.monospacedFont)
        .multilineTextAlignment(.center)
        .foregroundStyle(Theme.ink)
        .oneTimeCodeInput()
        .focused($isFocused)
        .submitLabel(.done)
        .onSubmit { onSubmit?() }
        .disabled(isDisabled)
        .padding(.horizontal, Metrics.Spacing.m)
        .frame(minHeight: Metrics.minTapTarget + Metrics.Spacing.s)
        .background(Theme.paperElevated, in: shape)
        .overlay {
            shape.strokeBorder(
                isFocused ? Theme.accent : Theme.hairline,
                lineWidth: isFocused ? 1 : Metrics.hairline(scale: displayScale))
        }
        .accessibilityLabel(Text(language == .chinese ? "验证码" : "Verification code"))
        .onAppear { isFocused = true }
    }
}

extension View {
    /// 验证码输入框的系统设置：自动填充短信验证码、数字键盘（iOS），macOS 上也能从信息里填。
    func oneTimeCodeInput() -> some View {
        #if canImport(UIKit)
            self.textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
        #else
            self.textContentType(.oneTimeCode)
        #endif
    }

    /// 手机号输入框的系统设置：自动填充本机号码、电话键盘（iOS）。
    func phoneNumberInput() -> some View {
        #if canImport(UIKit)
            self.textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
        #else
            self
        #endif
    }
}

/// 输入框下面的一行红字（号码不对、验证码不对、昵称太长）。
struct FieldMessage: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .typography(.footnote)
            .foregroundStyle(Theme.danger)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 限流提示：每秒刷新剩余秒数，倒数完就不显示（`message(date)` 返回 nil）。
struct CountdownNotice: View {
    let message: @MainActor (Date) -> String?

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            if let text = message(context.date) {
                Label(text, systemImage: "clock.arrow.circlepath")
                    .font(Typography.footnote.font.monospacedDigit())
                    .foregroundStyle(StatusTone.waiting.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// 头像：名字的第一个字，强调色圆底（和抽屉底部的一样）。
struct AccountAvatar: View {
    let name: String
    var size: CGFloat = Metrics.Spacing.xxxl

    var body: some View {
        Text(verbatim: name.first.map(String.init) ?? "·")
            .font(Typography.title2.font.weight(.semibold))
            .foregroundStyle(Theme.onAccent)
            .frame(width: size, height: size)
            .background(Theme.accent, in: Circle())
            .accessibilityHidden(true)
    }
}

/// 页面的大标题区：衬线标题和一句说明（登录、注销这类单任务的页面用）。
struct AccountPageHeader: View {
    let title: String
    var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            Text(title)
                .typography(.title)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message)
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 离线又没有数据的页面（账号、设备不缓存，docs/ios.md 6.2）。顶部的离线横幅由 `AppShell` 放。
struct AccountOfflineState: View {
    @Environment(\.displayLanguage) private var language

    var body: some View {
        EmptyStateView(
            systemImage: "wifi.slash", title: language == .chinese ? "离线" : "Offline",
            message: OfflinePolicy.unavailable.bannerMessage(language))
    }
}

/// 账号页面共用的滚动容器：纸色底、可读宽度居中、页边距。
struct AccountScrollPage<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xl) {
                content
            }
            .frame(maxWidth: Metrics.readableWidth)
            .padding(.horizontal, Metrics.Spacing.m)
            .padding(.vertical, Metrics.Spacing.l)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.paper)
    }
}

/// 预览、界面测试用的客户端。
enum AccountPreviewClients {
    /// 没登录、验证码固定 123456。
    static func signedOut() -> MockClient { ShellPreviewClients.signedOut() }

    /// 已登录、演示数据（三台设备，电脑在线）。
    static func signedIn() -> MockClient { ShellPreviewClients.signedIn() }

    /// 只有本机登录着。
    static func singleDevice() -> MockClient {
        let mock = ShellPreviewClients.signedIn()
        mock.update { $0.devices = [DemoData.currentDevice()] }
        return mock
    }
}
