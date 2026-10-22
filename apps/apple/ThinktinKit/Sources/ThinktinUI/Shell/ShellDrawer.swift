import SwiftUI
import ThinktinKit

/// 左侧抽屉（WBS 12.16，对应 Claude iOS 的侧边栏）：从上到下是搜索入口、“新任务”、收件箱 / 审批 / 进行中 / 计划 /
/// 团队 / 产出物（带角标）、实例列表（状态点、最后活动时间、等你处理的提示），底部头像进设置。
///
/// 盖在导航栈上面：点空白处、向左划、读屏的“返回”手势都能关掉。每次打开时角标太久没刷新就刷新一次。
struct ShellDrawer: View {
    let model: AppModel

    var body: some View {
        let router = model.router
        ZStack(alignment: .leading) {
            if router.isDrawerOpen {
                // 点空白处关闭；读屏不读这一层，用面板里的关闭按钮。
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { router.closeDrawer() }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                DrawerPanel(model: model)
                    .containerRelativeFrame(.horizontal) { width, _ in min(Metrics.drawerMaxWidth, width * 0.85) }
                    .transition(.move(edge: .leading))
                    // 向左划关闭。和面板里的滚动同时识别，不抢滚动。
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 20).onEnded { value in
                            let width = value.translation.width
                            if width < -60, abs(width) > abs(value.translation.height) { router.closeDrawer() }
                        })
            }
        }
        .animation(.snappy, value: router.isDrawerOpen)
    }
}

/// 抽屉的面板。
private struct DrawerPanel: View {
    let model: AppModel

    @Environment(\.displayLanguage) private var language
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let router = model.router
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                searchButton
                DrawerRow(
                    title: AppRoute.newTask.title(language), systemImage: "square.and.pencil", isEmphasized: true
                ) {
                    model.startNewTask()
                }
            }
            .padding(.horizontal, Metrics.Spacing.s)
            .padding(.bottom, Metrics.Spacing.xs)

            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                    ForEach(DrawerEntry.allCases, id: \.self) { entry in
                        DrawerRow(
                            title: entry.title(language), systemImage: entry.systemImage,
                            badge: model.badges.count(for: entry),
                            badgeLabel: entry.badgeAccessibilityLabel(
                                count: model.badges.count(for: entry), language: language),
                            isSelected: router.path.first == entry.route
                        ) {
                            router.openFromDrawer(entry.route)
                        }
                    }
                    Text(language == .chinese ? "实例" : "Instances")
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                        .padding(.horizontal, Metrics.Spacing.s)
                        .padding(.top, Metrics.Spacing.m)
                        .padding(.bottom, Metrics.Spacing.xxs)
                        .accessibilityAddTraits(.isHeader)
                    DrawerInstanceList(model: model)
                }
                .padding(.horizontal, Metrics.Spacing.s)
                .padding(.bottom, Metrics.Spacing.m)
            }

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: Metrics.hairline(scale: displayScale))
            footer
        }
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
        .accessibilityAction(.escape) { router.closeDrawer() }
        .task { await model.refreshBadgesIfStale() }
    }

    private var header: some View {
        HStack {
            Text(verbatim: "ThinkTin")
                .typography(.title2)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                model.router.closeDrawer()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(language == .chinese ? "关闭侧边栏" : "Close sidebar"))
        }
        .padding(.leading, Metrics.Spacing.m)
        .padding(.trailing, Metrics.Spacing.xs)
        .padding(.top, Metrics.Spacing.xs)
    }

    /// 搜索入口（12.21 做搜索页，这里只是入口）：长得像一个搜索框。
    private var searchButton: some View {
        Button {
            model.router.openFromDrawer(.search)
        } label: {
            HStack(spacing: Metrics.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .accessibilityHidden(true)
                Text(AppRoute.search.title(language))
                Spacer(minLength: 0)
            }
            .typography(.body)
            .foregroundStyle(Theme.inkTertiary)
            .padding(.horizontal, Metrics.Spacing.s)
            .frame(minHeight: Metrics.minTapTarget)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(AppRoute.search.title(language)))
    }

    /// 底部：头像（名字的第一个字）、名字，点开进设置。
    private var footer: some View {
        let name = model.user?.nameForDisplay ?? ""
        return Button {
            model.router.openFromDrawer(.settings)
        } label: {
            HStack(spacing: Metrics.Spacing.s) {
                Text(verbatim: name.first.map(String.init) ?? "·")
                    .typography(.headline)
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                    .background(Theme.accent, in: Circle())
                    .accessibilityHidden(true)
                Text(name)
                    .typography(.body)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: Metrics.Spacing.xs)
                Image(systemName: "gearshape")
                    .foregroundStyle(Theme.inkSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Metrics.Spacing.m)
            .frame(minHeight: Metrics.minTapTarget + Metrics.Spacing.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(name.isEmpty ? AppRoute.settings.title(language) : name))
        .accessibilityHint(Text(language == .chinese ? "打开设置" : "Opens settings"))
    }
}

/// 抽屉里的一行入口：图标、标题，右边可选的角标。
private struct DrawerRow: View {
    let title: String
    let systemImage: String
    var badge: Int = 0
    var badgeLabel: String?
    var isSelected = false
    var isEmphasized = false
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.Spacing.s) {
                Image(systemName: systemImage)
                    .frame(width: Metrics.Spacing.xl)
                    .foregroundStyle(isEmphasized ? Theme.accent : Theme.inkSecondary)
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(Theme.ink)
                    .font(isEmphasized ? Typography.body.font.weight(.semibold) : Typography.body.font)
                    .lineLimit(1)
                Spacer(minLength: Metrics.Spacing.xs)
                if badge > 0 {
                    Text(ShellBadges.text(badge))
                        .font(Typography.caption.font.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, Metrics.Spacing.xs)
                        .padding(.vertical, Metrics.Spacing.unit / 2)
                        .background(Theme.accent, in: Capsule())
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Metrics.Spacing.s)
            .frame(minHeight: Metrics.minTapTarget)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous).fill(Theme.userBubble)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(badgeLabel ?? ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 抽屉里的实例列表：先显示缓存，再拉最新的；出错显示横幅，可以重试。
private struct DrawerInstanceList: View {
    let model: AppModel

    @Environment(\.displayLanguage) private var language

    var body: some View {
        if let error = model.refreshError, model.instances.isEmpty {
            ErrorBanner(error, onRetry: { Task { await model.refresh() } })
        } else if !model.hasLoadedInstances {
            if model.isOffline {
                EmptyStateView(
                    systemImage: "wifi.slash", title: language == .chinese ? "离线" : "Offline",
                    message: OfflinePolicy.unavailable.bannerMessage(language))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Metrics.Spacing.xl)
            }
        } else if model.instances.isEmpty {
            EmptyStateView(
                systemImage: "square.stack.3d.up",
                title: language == .chinese ? "还没有实例" : "No instances yet",
                message: language == .chinese
                    ? "从 agent 目录领养一个，就可以给它布置任务了。"
                    : "Adopt an agent from the catalog to start giving it tasks.",
                actionTitle: language == .chinese ? "去领养" : "Browse agents"
            ) {
                model.router.openFromDrawer(.agentCatalog)
            }
        } else {
            if let error = model.refreshError {
                ErrorBanner(error, onRetry: { Task { await model.refresh() } })
            }
            // 每分钟刷新一次“几分钟前”。
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                    ForEach(model.instances) { instance in
                        DrawerInstanceRow(
                            instance: instance, activity: model.activity(for: instance.id),
                            isSelected: instance.id == model.router.currentInstanceID, now: context.date
                        ) {
                            model.selectInstance(instance.id)
                        }
                    }
                }
            }
        }
    }
}

/// 抽屉里的一个实例：状态点、名字、最后活动时间；有运行在等用户时多一行“等你处理”。
/// 读屏合成一句“写作助手，运行中，2 分钟前，1 个在等你处理”。
private struct DrawerInstanceRow: View {
    let instance: Instance
    let activity: InstanceActivity
    let isSelected: Bool
    let now: Date
    let action: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.s) {
                StatusDot(instance.state)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(instance.name)
                            .typography(.body)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: Metrics.Spacing.xs)
                        Text(lastActive)
                            .typography(.caption)
                            .foregroundStyle(Theme.inkTertiary)
                            .lineLimit(1)
                    }
                    if let attention {
                        Label(attention, systemImage: "exclamationmark.circle.fill")
                            .typography(.caption)
                            .foregroundStyle(StatusTone.waiting.color)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, Metrics.Spacing.s)
            .padding(.vertical, Metrics.Spacing.xs)
            .frame(minHeight: Metrics.minTapTarget)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous).fill(Theme.userBubble)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var lastActive: String {
        Formatting.relativeTime(instance.lastActiveAt, now: now, language: language)
    }

    private var attention: String? {
        guard activity.needsAttention else { return nil }
        let n = activity.waitingRuns
        return language == .chinese ? "\(n) 个在等你处理" : "\(n) waiting for you"
    }

    private var accessibilityText: String {
        [instance.name, instance.state.localizedName(language), lastActive, attention]
            .compactMap { $0 }
            .joined(separator: language == .chinese ? "，" : ", ")
    }
}

extension DrawerEntry {
    /// SF Symbol。
    var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .approvals: "checkmark.shield"
        case .activeRuns: "bolt"
        case .plans: "calendar"
        case .teams: "person.3"
        case .artifacts: "doc.text"
        }
    }
}

#Preview("抽屉 · 浅色中文") {
    let model = AppModel(client: ShellPreviewClients.signedIn(), defaults: nil)
    ShellDrawer(model: model)
        .task {
            model.router.openDrawer()
            await model.start()
        }
        .environment(\.displayLanguage, .chinese)
}

#Preview("抽屉 · 深色英文、没有实例") {
    let model = AppModel(client: ShellPreviewClients.empty(), defaults: nil)
    ShellDrawer(model: model)
        .task {
            model.router.openDrawer()
            await model.start()
        }
        .environment(\.displayLanguage, .english)
        .preferredColorScheme(.dark)
}
