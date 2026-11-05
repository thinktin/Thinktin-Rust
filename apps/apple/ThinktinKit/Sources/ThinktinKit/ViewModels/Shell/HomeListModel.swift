import Foundation

/// 首页实例列表的一行（WBS 12.16，规范 docs/ios-ui-redesign.md 4.2.1）：头像（右下角状态角标）、名字、
/// 右边的时间、下面一行预览。点开压栈进它的对话；置顶的画成顶上的大头像（同一份数据）。
public struct HomeRow: Identifiable, Hashable, Sendable {
    public var instance: Instance
    public var activity: InstanceActivity
    /// 本机缓存里的最后一条（`HomeLastMessage.latest(in:)`）；没缓存过的为 nil。
    public var lastMessage: HomeLastMessage?
    /// 最后活动：实例的 `lastActiveAt`、最近一个没结束的运行的创建时间、最后一条的时间里最晚的那个（缓存里的实例
    /// 可能比运行旧）。排序和右边的时间都用它。
    public var lastActivityAt: Date
    public var preview: HomeRowPreview

    public var id: InstanceID { instance.id }

    /// 有运行在等你处理：预览和角标用警告色。
    public var needsAttention: Bool {
        if case .waiting = preview { return true }
        return false
    }

    public init(instance: Instance, activity: InstanceActivity, lastMessage: HomeLastMessage? = nil) {
        self.instance = instance
        self.activity = activity
        self.lastMessage = lastMessage
        lastActivityAt = max(
            instance.lastActiveAt, activity.latestRunAt ?? .distantPast, lastMessage?.at ?? .distantPast)
        preview = HomeRowPreview(state: instance.state, activity: activity, lastMessage: lastMessage)
    }
}

/// 第二行的预览（规范 6.7 B：先显示状态；没有要说的状态时显示本机缓存里的最后一条）。
public enum HomeRowPreview: Hashable, Sendable {
    /// 有运行在等你处理（审批、电脑、key、子任务）：“N 个在等你处理”，警告色。`state` 是最近在等的那个。
    case waiting(count: Int, state: RunState)
    /// 有没结束的运行（排队、启动、运行中、重试等待）：最近那个的状态，不止一个时带个数。
    case active(count: Int, state: RunState)
    /// 没有进行中的运行、Botin 在正常的状态（开着、休眠、归档，发任务会自己唤醒）：最后一条（agent 的摘要带 AI 标识，
    /// 你发的前面加“你：”）。`state` 给头像的角标用。
    case message(HomeLastMessage, state: InstanceState)
    /// 没有进行中的运行，也没有缓存过的消息，或者 Botin 在要说一声的状态（创建中、不认识的状态）：实例自己的状态。
    case idle(InstanceState)

    public init(state: InstanceState, activity: InstanceActivity, lastMessage: HomeLastMessage? = nil) {
        if activity.waitingRuns > 0 {
            self = .waiting(count: activity.waitingRuns, state: activity.latestWaitingState ?? .waitingApproval)
        } else if activity.activeRuns > 0, let latest = activity.latestRunState {
            self = .active(count: activity.activeRuns, state: latest)
        } else if let lastMessage, Self.showsMessage(in: state) {
            self = .message(lastMessage, state: state)
        } else {
            self = .idle(state)
        }
    }

    /// 这些状态下显示最后一条：开着的、休眠的（暂停、归档都是闲下来自己进的，发任务就唤醒）。
    private static func showsMessage(in state: InstanceState) -> Bool {
        switch state {
        case .running, .paused, .archived: true
        case .provisioning, .deleted, .unknown: false
        }
    }
}

/// 首页一行的“最后一条”（规范 6.7 A / B 的后一半）：实例列表接口不带最后一条消息，用本机缓存凑——最近一次运行的
/// 摘要（agent 写的，界面带 AI 标识）；最近一次没有摘要（还在跑、失败了）且是你发的，就是你发的任务。长按的预览卡也用它。
public struct HomeLastMessage: Hashable, Sendable {
    public enum Author: Hashable, Sendable {
        /// agent 的回答摘要（AI 生成）。
        case agent
        /// 你发的任务。
        case user
    }

    public var author: Author
    /// 原文（预览卡里多行显示）。
    public var text: String
    public var runID: RunID
    /// 摘要是运行结束的时间，任务是发出的时间。
    public var at: Date

    public init(author: Author, text: String, runID: RunID, at: Date) {
        self.author = author
        self.text = text
        self.runID = runID
        self.at = at
    }

    /// 行里单行显示用的：换行和连续的空白并成一个空格。
    public var singleLine: String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 从一个实例缓存里最近的几次运行（顺序不限）里取：新的在前一次一次看，有摘要的就是摘要；没有摘要、是你发的就是
    /// 任务原文；计划、流水线、别的 Botin 派来的又没有摘要的跳过（任务原文不是你说的话）。都没有为 nil。
    public static func latest(in runs: [Run]) -> HomeLastMessage? {
        let ordered = runs.sorted { a, b in
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.id.rawValue > b.id.rawValue
        }
        for run in ordered {
            if let summary = run.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return HomeLastMessage(
                    author: .agent, text: summary, runID: run.id, at: run.finishedAt ?? run.createdAt)
            }
            // 引用回复只取正文（不然预览是“你：> 引用…”）。
            let prompt = MessageQuote.body(run.prompt).trimmingCharacters(in: .whitespacesAndNewlines)
            if run.source == .user, !prompt.isEmpty {
                return HomeLastMessage(author: .user, text: prompt, runID: run.id, at: run.createdAt)
            }
        }
        return nil
    }
}

/// 首页的实例列表怎么排、每行显示什么（纯函数，Linux 上测）。
public enum HomeList {
    /// 列表的行：去掉已删除的，最后活动新的在前；一样新的按名字、再按 id，顺序稳定（刷新时行不乱跳）。
    public static func rows(
        instances: [Instance], activity: [InstanceID: InstanceActivity],
        lastMessages: [InstanceID: HomeLastMessage] = [:]
    ) -> [HomeRow] {
        instances
            .filter { $0.state != .deleted }
            .map { HomeRow(instance: $0, activity: activity[$0.id] ?? .none, lastMessage: lastMessages[$0.id]) }
            .sorted { a, b in
                if a.lastActivityAt != b.lastActivityAt { return a.lastActivityAt > b.lastActivityAt }
                if a.instance.name != b.instance.name { return a.instance.name < b.instance.name }
                return a.id.rawValue < b.id.rawValue
            }
    }

    /// 首页的三部分（规范 4.2.1–4.2.3）：置顶的（按置顶的先后，画成顶上的大头像）、普通的行（按 `rows` 排）、
    /// 隐藏的（首页不显示，“已隐藏的 Botin”页按 `rows` 排）。`pinned`、`hidden` 是 `InstancePreferencesStore` 记的，
    /// 里面已经没有的 Botin（删了、别的账号的）不管；又置顶又隐藏的按隐藏算。
    public static func content(
        instances: [Instance], activity: [InstanceID: InstanceActivity],
        lastMessages: [InstanceID: HomeLastMessage] = [:], pinned: [InstanceID] = [], hidden: Set<InstanceID> = []
    ) -> HomeListContent {
        let all = rows(instances: instances, activity: activity, lastMessages: lastMessages)
        var byID: [InstanceID: HomeRow] = [:]
        for row in all { byID[row.id] = row }
        var pinnedRows: [HomeRow] = []
        for id in pinned where !hidden.contains(id) && !pinnedRows.contains(where: { $0.id == id }) {
            if let row = byID[id] { pinnedRows.append(row) }
        }
        let pinnedIDs = Set(pinnedRows.map(\.id))
        return HomeListContent(
            pinned: pinnedRows,
            rows: all.filter { !pinnedIDs.contains($0.id) && !hidden.contains($0.id) },
            hidden: all.filter { hidden.contains($0.id) })
    }

    /// 行右边的时间：今天的“14:05”，更早的显示日期（“10月21日”，往年的带年份）。
    public static func timestamp(
        _ date: Date, now: Date = Date(), language: DisplayLanguage = .current, calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return Formatting.clockTime(date, calendar: calendar) }
        return Formatting.shortDate(date, now: now, language: language, calendar: calendar)
    }
}

/// 首页的三部分（`HomeList.content`）。
public struct HomeListContent: Hashable, Sendable {
    /// 置顶的，先置顶的在前。
    public var pinned: [HomeRow]
    /// 普通的行，最后活动新的在前。
    public var rows: [HomeRow]
    /// 隐藏的，最后活动新的在前。
    public var hidden: [HomeRow]

    public init(pinned: [HomeRow] = [], rows: [HomeRow] = [], hidden: [HomeRow] = []) {
        self.pinned = pinned
        self.rows = rows
        self.hidden = hidden
    }

    /// 首页上看得见的：置顶的在前，再是普通的行（“首页第一行”、截图参数用）。
    public var visible: [HomeRow] { pinned + rows }

    /// 有 Botin，但都隐藏了（参考 113 的空状态）。
    public var isAllHidden: Bool { pinned.isEmpty && rows.isEmpty && !hidden.isEmpty }
}

/// 首页列表空着时显示什么（`HomeList.placeholder`）；列表有行、或者拉取失败（横幅说了怎么回事、可以重试）时不显示。
public enum HomePlaceholder: Hashable, Sendable {
    /// 第一次在拉、这台设备上没有缓存：转圈。
    case loading
    /// 离线、这台设备上没有 Botin 可显示（第 0 轮的离线文案，`HomeText.offlineEmptyMessage`）。
    case offlineWithoutCache
    /// 联网拉到了，账号里还没有 Botin（第一次登录就是这样）：“还没有 Botin”和“新建 Botin”按钮。
    case noBotins
    /// 有 Botin，但在这台设备上都隐藏了（参考 113）：“所有 Botin 都已隐藏”和“显示已隐藏的 Botin”。
    case allHidden
}

extension HomeList {
    /// 列表空着时显示什么（规范 4.2.1 的状态）。`isEmpty` 是一个 Botin 都没有（隐藏的也算有），`hasLoaded` 是实例列表
    /// 拿到过（缓存或服务端，`AppModel.hasLoadedInstances`），`hasError` 是刷新失败了（不是网络问题，`AppModel.refreshError`），
    /// `isAllHidden` 是有 Botin 但都隐藏了（离线、出错时也这么说：隐藏是这台设备上的事）。离线时不引导新建（表单离线
    /// 不能提交），只说这台设备上没有。
    public static func placeholder(
        isEmpty: Bool, hasLoaded: Bool, isOffline: Bool, hasError: Bool, isAllHidden: Bool = false
    ) -> HomePlaceholder? {
        guard isEmpty else { return isAllHidden ? .allHidden : nil }
        if isOffline { return .offlineWithoutCache }
        if hasError { return nil }
        return hasLoaded ? .noBotins : .loading
    }
}

/// 首页空状态的文案（用户 2026-11-05 定的：第一次登录首页是空的，引导新建 Botin）。按钮文字用 `AppRoute.adopt` 的标题“新建 Botin”。
public enum HomeText {
    public static func emptyTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "还没有 Botin" : "No Botins yet"
    }

    public static func emptyMessage(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "Botin 是替你干活的助手。起个名字、选一个引擎，它就能帮你写东西、查资料、跑任务。"
            : "A Botin is an assistant that works for you. Give it a name and pick an engine, and it can write, "
                + "look things up and run tasks for you."
    }

    /// 离线、这台设备上又没有缓存时（顶部横幅已经说了“显示的是缓存内容”，这里只说缓存是空的）。
    public static func offlineEmptyMessage(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "这台设备上还没有保存的 Botin，联网后会自动刷新。"
            : "No Botins are saved on this device yet. They'll appear when you're back online."
    }
}
