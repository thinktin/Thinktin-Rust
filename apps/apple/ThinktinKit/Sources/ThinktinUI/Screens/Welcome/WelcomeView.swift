import SwiftUI
import ThinktinKit

/// 欢迎页（占位，WBS 12.1）：仿 Claude App 的首页——纸张底色、正中一句衬线的问候、底部胶囊输入框、左上角抽屉按钮。
///
/// 登录（12.2）、对话（12.5）、抽屉与导航（12.16）还没接：输入框的发送按钮置灰，抽屉里只列实例和状态。
struct WelcomeView: View {
    let client: any ClientProtocol

    @Environment(\.displayLanguage) private var language
    @State private var userName: String?
    @State private var draft = ""
    @State private var isDrawerOpen = false

    var body: some View {
        NavigationStack {
            VStack(spacing: Metrics.Spacing.s) {
                Spacer()
                greeting
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Metrics.Spacing.m)
            .background(Theme.paper)
            .safeAreaInset(edge: .bottom) {
                ComposerBar(text: $draft, placeholder: Self.composerPlaceholder(language))
                    .frame(maxWidth: Metrics.readableWidth)
                    .padding(.horizontal, Metrics.Spacing.m)
                    .padding(.bottom, Metrics.Spacing.xs)
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        isDrawerOpen = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(Theme.ink)
                    }
                    .accessibilityLabel(Text(language == .chinese ? "打开侧边栏" : "Open sidebar"))
                }
            }
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .tint(Theme.accent)
        .overlay {
            InstanceDrawer(client: client, isOpen: $isDrawerOpen)
        }
        .task { await loadUserName() }
    }

    /// 衬线的问候语，每分钟按时段刷新一次（“下午好”到点变“晚上好”）。
    private var greeting: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: Metrics.Spacing.xs) {
                Text(Greeting.text(at: context.date, name: userName, language: language))
                    .typography(.largeTitle)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(language == .chinese ? "今天想让 agent 做点什么？" : "What should your agents do today?")
                    .typography(.body)
                    .foregroundStyle(Theme.inkSecondary)
            }
            .multilineTextAlignment(.center)
        }
    }

    /// 问候语里的名字：拉不到（没登录、离线）就只说“下午好”。
    private func loadUserName() async {
        guard client.signedIn() else { return }
        if let user = try? await client.me() {
            userName = user.nameForDisplay
        }
    }

    static func composerPlaceholder(_ language: DisplayLanguage) -> String {
        language == .chinese ? "给 agent 布置一个任务" : "Give an agent a task"
    }
}

/// 左侧抽屉（占位）：实例列表和状态点。先显示缓存，再拉最新的；出错显示横幅，可以重试。
/// 收件箱、审批、计划、团队等入口和实例切换在 12.16 接。
struct InstanceDrawer: View {
    let client: any ClientProtocol
    @Binding var isOpen: Bool

    @Environment(\.displayLanguage) private var language
    @Environment(\.displayScale) private var displayScale
    @State private var instances: [Instance]?
    @State private var loadError: ClientError?

    var body: some View {
        ZStack(alignment: .leading) {
            if isOpen {
                // 点空白处关闭；读屏不读这一层，用面板里的关闭按钮。
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { isOpen = false }
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
            if isOpen {
                panel
                    .containerRelativeFrame(.horizontal) { width, _ in min(Metrics.drawerMaxWidth, width * 0.85) }
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.snappy, value: isOpen)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.m) {
            HStack {
                Text(verbatim: "ThinkTin")
                    .typography(.title2)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    isOpen = false
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(language == .chinese ? "关闭侧边栏" : "Close sidebar"))
            }

            Text(language == .chinese ? "实例" : "Instances")
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)

            if let loadError {
                ErrorBanner(loadError, onRetry: { Task { await load() } })
            }
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.Spacing.m)
        .padding(.top, Metrics.Spacing.xs)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.paperElevated)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: Metrics.hairline(scale: displayScale))
                .ignoresSafeArea()
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { isOpen = false }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let instances {
            if instances.isEmpty {
                EmptyStateView(
                    systemImage: "square.stack.3d.up",
                    title: language == .chinese ? "还没有实例" : "No instances yet",
                    message: language == .chinese
                        ? "从 agent 目录领养一个，就可以给它布置任务了。"
                        : "Adopt an agent from the catalog to start giving it tasks."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(instances) { instance in
                            InstanceRow(instance: instance)
                        }
                    }
                }
            }
        } else if loadError == nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, Metrics.Spacing.xl)
        }
    }

    /// 先读缓存（离线也有东西看），再从服务端拉。
    private func load() async {
        if instances == nil, let cached = try? client.cachedInstances(), !cached.isEmpty {
            instances = cached
        }
        do {
            instances = try await client.instances()
            loadError = nil
        } catch {
            // 抽屉关了（任务被取消）不算出错。
            if error is CancellationError || Task.isCancelled { return }
            loadError = (error as? ClientError) ?? .internal(message: String(describing: error))
        }
    }
}

/// 抽屉里的一行：状态点、实例名、状态名。读屏合成一句“写作助手，运行中”。
private struct InstanceRow: View {
    let instance: Instance

    @Environment(\.displayLanguage) private var language

    var body: some View {
        HStack(spacing: Metrics.Spacing.s) {
            // 状态名已经写在右边，读屏不再读状态点，免得念两遍。
            StatusDot(instance.state)
                .accessibilityHidden(true)
            Text(instance.name)
                .typography(.body)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: Metrics.Spacing.xs)
            Text(instance.state.localizedName(language))
                .typography(.caption)
                .foregroundStyle(Theme.inkSecondary)
        }
        .frame(minHeight: Metrics.minTapTarget)
        .accessibilityElement(children: .combine)
    }
}

#Preview("欢迎页") {
    WelcomeView(client: MockClient())
}

#Preview("欢迎页 · 深色、英文") {
    WelcomeView(client: MockClient())
        .environment(\.displayLanguage, .english)
        .preferredColorScheme(.dark)
}

#Preview("抽屉") {
    InstanceDrawer(client: MockClient(latency: 0.5), isOpen: .constant(true))
}
