import SwiftUI
import ThinktinKit

/// 冻结页（docs/ios.md 第 6 节，ios-packages.md 12.16）：账号被冻结时整页显示，登录状态保留。
///
/// 服务端解冻时不给 App 发事件，所以这里有“重新检查”（`me()`）；回到前台、收到“账号已恢复”的推送时 `AppModel`
/// 也会自动重查。解冻后回到主界面，对话页重新出现时重新订阅事件流。
struct FrozenView: View {
    let model: AppModel

    @Environment(\.displayLanguage) private var language
    @State private var signOutError: ClientError?

    var body: some View {
        let zh = language == .chinese
        AccountStateLayout(
            systemImage: "snowflake", tone: .failure,
            title: AppRoute.frozen.title(language),
            message: zh
                ? "账号冻结期间，agent 不会运行，计划也都暂停了。解冻后一切照常，不用重新登录。如有疑问请联系客服。"
                : "While your account is frozen, agents don't run and plans are paused. Everything resumes once it's "
                    + "unfrozen; you won't need to sign in again. Contact support if you have questions."
        ) {
            if let error = model.accountCheckError ?? signOutError {
                ErrorBanner(error)
            }
            PillButton(
                model.isCheckingAccount ? (zh ? "正在检查…" : "Checking…") : (zh ? "重新检查" : "Check again"),
                systemImage: "arrow.clockwise"
            ) {
                Task { await model.recheckAccount() }
            }
            .disabled(model.isCheckingAccount)
            PillButton(zh ? "退出登录" : "Sign out", kind: .secondary) {
                Task {
                    do {
                        try await model.signOut()
                    } catch {
                        signOutError = (error as? ClientError) ?? .internal(message: String(describing: error))
                    }
                }
            }
        }
    }
}

/// 升级页：版本太老时整页显示，事件流已经全部停掉（升级就是重装，之后不会离开这一页）。
struct UpgradeView: View {
    /// App Store 的地址。App 记录建好、有了 Apple ID 之后再填（12.11）；没有时只给一句文字说明。
    var appStoreURL: URL? = ShellLinks.appStore

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        AccountStateLayout(
            systemImage: "arrow.up.circle", tone: .waiting,
            title: zh ? "请更新 ThinkTin" : "Update ThinkTin",
            message: zh
                ? "当前版本过旧，已经停止同步。请到 App Store 更新到最新版本后继续使用，你的数据都还在。"
                : "This version is too old and has stopped syncing. Update from the App Store to keep going; "
                    + "your data is safe."
        ) {
            if let appStoreURL {
                Link(destination: appStoreURL) {
                    Label(zh ? "前往 App Store" : "Open the App Store", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.pill)
            } else {
                Text(zh ? "在 App Store 搜索“ThinkTin”即可更新。" : "Search for “ThinkTin” in the App Store to update.")
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
    }
}

/// 外部链接。
enum ShellLinks {
    /// App Store 上的 App 页面（`https://apps.apple.com/app/id…`）。App 记录建好之后填（12.11）。
    static let appStore: URL? = nil
}

/// 冻结页、升级页共用的版式：居中的大图标、衬线标题、一段说明、下面一列按钮。内容多时可以滚动（大字号）。
private struct AccountStateLayout<Actions: View>: View {
    let systemImage: String
    let tone: StatusTone
    let title: String
    let message: String
    let actions: Actions

    init(
        systemImage: String, tone: StatusTone, title: String, message: String, @ViewBuilder actions: () -> Actions
    ) {
        self.systemImage = systemImage
        self.tone = tone
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.Spacing.l) {
                Image(systemName: systemImage)
                    .font(Typography.largeTitle.font)
                    .imageScale(.large)
                    .foregroundStyle(tone.color)
                    .accessibilityHidden(true)
                VStack(spacing: Metrics.Spacing.s) {
                    Text(title)
                        .typography(.largeTitle)
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .typography(.body)
                        .foregroundStyle(Theme.inkSecondary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: Metrics.Spacing.s) {
                    actions
                }
            }
            .frame(maxWidth: Metrics.readableWidth)
            .padding(.horizontal, Metrics.Spacing.xl)
            .padding(.vertical, Metrics.Spacing.xxxl)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.paper)
    }
}

#Preview("冻结页 · 浅色中文") {
    let model = AppModel(client: ShellPreviewClients.frozen(), defaults: nil)
    FrozenView(model: model)
        .task { await model.start() }
        .environment(\.displayLanguage, .chinese)
}

#Preview("冻结页 · 深色英文") {
    let model = AppModel(client: ShellPreviewClients.frozen(), defaults: nil)
    FrozenView(model: model)
        .task { await model.start() }
        .environment(\.displayLanguage, .english)
        .preferredColorScheme(.dark)
}

#Preview("升级页 · 浅色中文") {
    UpgradeView()
        .environment(\.displayLanguage, .chinese)
}

#Preview("升级页 · 深色英文、有链接") {
    UpgradeView(appStoreURL: URL(string: "https://apps.apple.com/"))
        .environment(\.displayLanguage, .english)
        .preferredColorScheme(.dark)
}
