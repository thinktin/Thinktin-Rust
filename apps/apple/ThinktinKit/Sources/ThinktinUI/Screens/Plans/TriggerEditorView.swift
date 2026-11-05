import SwiftUI
import ThinktinKit

/// 触发器编辑器（新建、编辑计划里点开一条规则；详情页的“修改规则”）：
///
/// - 写法：每天、每周几、每月几号、一次性，以及高级的 cron、RRULE，换写法时尽量带上已经填的（`TriggerDraft.setKind`）；
/// - 时刻用系统的时间选择器，时区默认是设备的时区，可以换；
/// - 下面实时显示说成人话的描述和接下来几次的触发时间（App 在本地按 cron / RRULE 算，算不了的写法只描述，
///   保存时由服务端检查），以及保存前要改的问题（太频繁、时间过去了、格式不对）。
///
/// 改版（规范 2.5、2.8）：`Form`，写法是第一行的筛选胶囊（`FilterChipBar`），时间、日期是系统 `DatePicker` 行，周几、几号是
/// 一排玻璃圆按钮（选中的突出），时区是 `NavigationLink` 行，预览一组；左上 `CloseButton`（弹出时）、右上 `ConfirmButton("完成")`。
struct TriggerEditorView: View {
    @State private var draft: TriggerDraft
    let title: String
    /// 正在保存（详情页“修改规则”要等接口回来）。
    var isSaving = false
    /// 保存失败（详情页“修改规则”时服务端拒了）：显示在页面顶上。
    var error: ClientError?
    /// 点“完成”后自己退回上一页（在编辑器里压栈打开时）。
    var dismissOnSave = false
    let onSave: @MainActor (Schedule) -> Void
    var onCancel: (@MainActor () -> Void)?

    @State private var now = Date()

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayLanguage) private var language
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        draft: TriggerDraft, title: String, isSaving: Bool = false, error: ClientError? = nil,
        dismissOnSave: Bool = false, onSave: @escaping @MainActor (Schedule) -> Void,
        onCancel: (@MainActor () -> Void)? = nil
    ) {
        _draft = State(initialValue: draft)
        self.title = title
        self.isSaving = isSaving
        self.error = error
        self.dismissOnSave = dismissOnSave
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        let zh = language == .chinese
        let problem = draft.problem(now: now)
        Form {
            Section {
                kindPicker
                    .clearListRow()
            }
            if let error {
                Section {
                    ErrorBanner(error)
                        .clearListRow()
                }
            }
            switch draft.kind {
            case .daily:
                Section { timeRow }
                    .themedRow()
            case .weekly:
                weekdayPicker
                Section { timeRow }
                    .themedRow()
            case .monthly:
                monthDayPicker
                Section { timeRow }
                    .themedRow()
            case .once:
                onceRow
            case .cron:
                cronField
            case .rrule:
                rruleFields
            }
            if draft.kind != .once && !(draft.kind == .rrule && draft.rruleHasOwnStart) { timeZoneRow }
            preview(problem: problem)
        }
        .formStyle(.grouped)
        .themedGroupedBackground()
        .scrollDismissesKeyboard(.interactively)
        .inlineNavigationTitle(title)
        .toolbar {
            if let onCancel {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton { onCancel() }
                        .disabled(isSaving)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                ConfirmButton(zh ? "完成" : "Done", isWorking: isSaving) {
                    // 点的时候再查一次（停在页面上时间过去了）。
                    now = Date()
                    guard draft.problem(now: now) == nil else { return }
                    onSave(draft.schedule)
                    if dismissOnSave { dismiss() }
                }
                .disabled(problem != nil)
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    // MARK: 写法

    private var kindPicker: some View {
        let kinds = TriggerDraft.Kind.allCases
        let selection = Binding<TriggerDraft.Kind>(
            get: { draft.kind }, set: { draft.setKind($0, now: Date()) })
        return FilterChipBar(
            kinds.map { .init(value: $0, title: kindName($0)) }, selection: selection, horizontalInset: 0
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(language == .chinese ? "规则的写法" : "Kind of schedule"))
    }

    private func kindName(_ kind: TriggerDraft.Kind) -> String {
        let zh = language == .chinese
        switch kind {
        case .daily: return zh ? "每天" : "Daily"
        case .weekly: return zh ? "每周" : "Weekly"
        case .monthly: return zh ? "每月" : "Monthly"
        case .once: return zh ? "一次" : "Once"
        case .cron: return zh ? "cron" : "Cron"
        case .rrule: return "RRULE"
        }
    }

    // MARK: 时刻

    /// 时间选择器只当“几点几分”用（按本机日历换算，存进规则时是规则时区的本地时间）。
    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: draft.hour, minute: draft.minute, second: 0, of: now) ?? now
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft.hour = c.hour ?? draft.hour
                draft.minute = c.minute ?? draft.minute
            })
    }

    private var timeRow: some View {
        let zh = language == .chinese
        return DatePicker(selection: timeBinding, displayedComponents: .hourAndMinute) {
            Label(zh ? "时间" : "Time", systemImage: "clock")
        }
    }

    private var onceRow: some View {
        let zh = language == .chinese
        return Section {
            DatePicker(selection: $draft.onceAt, in: now...) {
                Label(zh ? "日期和时间" : "Date and time", systemImage: "calendar")
            }
        } footer: {
            Text(
                zh
                    ? "按本机时区（\(plansTimeZoneName(TimeZone.current.identifier, language: language))），到时间跑一次。"
                    : "Uses this device's time zone (\(plansTimeZoneName(TimeZone.current.identifier, language: language))) and runs once."
            )
        }
        .themedRow()
    }

    // MARK: 每周、每月

    private var weekdayPicker: some View {
        let zh = language == .chinese
        // 周一在前（cron 里周日是 0）。
        let order = [1, 2, 3, 4, 5, 6, 0]
        let short = zh ? ["日", "一", "二", "三", "四", "五", "六"] : ["S", "M", "T", "W", "T", "F", "S"]
        let full =
            zh
            ? ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            : ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let rows = dynamicTypeSize.isAccessibilitySize ? [Array(order.prefix(4)), Array(order.suffix(3))] : [order]
        return Section {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: Metrics.Spacing.xs) {
                        ForEach(row, id: \.self) { day in
                            PlansDayToggle(
                                text: short[day], accessibilityName: full[day], isOn: draft.weekdays.contains(day)
                            ) {
                                if draft.weekdays.contains(day) {
                                    draft.weekdays.remove(day)
                                } else {
                                    draft.weekdays.insert(day)
                                }
                            }
                        }
                    }
                }
                PlansButtonRow {
                    Button(zh ? "工作日" : "Weekdays") { draft.weekdays = [1, 2, 3, 4, 5] }
                        .smallCapsuleButton()
                    Button(zh ? "周末" : "Weekends") { draft.weekdays = [0, 6] }
                        .smallCapsuleButton()
                    Button(zh ? "每天" : "Every day") { draft.weekdays = Set(0...6) }
                        .smallCapsuleButton()
                }
                .padding(.top, Metrics.Spacing.xxs)
            }
            .padding(.vertical, Metrics.Spacing.xxs)
        } header: {
            Text(zh ? "每周的哪几天" : "Days of the week").textCase(nil)
        }
        .themedRow()
    }

    private var monthDayPicker: some View {
        let zh = language == .chinese
        let perRow = dynamicTypeSize.isAccessibilitySize ? 4 : 7
        let rows = Swift.stride(from: 1, through: 31, by: perRow).map { start in
            Array(start...min(31, start + perRow - 1))
        }
        return Section {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: Metrics.Spacing.xs) {
                        ForEach(row, id: \.self) { day in
                            PlansDayToggle(
                                text: "\(day)", accessibilityName: zh ? "\(day) 日" : "Day \(day)",
                                isOn: draft.monthDays.contains(day)
                            ) {
                                if draft.monthDays.contains(day) {
                                    draft.monthDays.remove(day)
                                } else {
                                    draft.monthDays.insert(day)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, Metrics.Spacing.xxs)
        } header: {
            Text(zh ? "每月的哪几号" : "Days of the month").textCase(nil)
        } footer: {
            if draft.monthDays.contains(where: { $0 > 28 }) {
                Text(zh ? "没有这一天的月份（比如 2 月 30 日）跳过。" : "Months without that day (like February 30) are skipped.")
            }
        }
        .themedRow()
    }

    // MARK: 高级

    private var cronField: some View {
        let zh = language == .chinese
        return Section {
            FormTextField(
                title: zh ? "cron 表达式" : "Cron expression", text: $draft.cronExpression, prompt: "0 9 * * 1-5",
                hint: zh
                    ? "五段，用空格隔开：分 时 日 月 周（0 和 7 都是周日）。比如 0 9 * * 1-5 是工作日 9 点。"
                    : "Five fields separated by spaces: minute hour day month weekday (0 and 7 are Sunday). "
                        + "For example, 0 9 * * 1-5 is 9:00 on weekdays.", monospaced: true)
        }
        .themedRow()
    }

    /// RRULE 的开始日期（按本机日历换算）。
    private var startDayBinding: Binding<Date> {
        Binding(
            get: {
                let d = draft.startDay
                return Calendar.current.date(from: DateComponents(year: d.year, month: d.month, day: d.day)) ?? now
            },
            set: { date in
                let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
                draft.startDay = LocalDay(
                    year: c.year ?? draft.startDay.year, month: c.month ?? draft.startDay.month,
                    day: c.day ?? draft.startDay.day)
            })
    }

    @ViewBuilder
    private var rruleFields: some View {
        let zh = language == .chinese
        Section {
            FormTextField(
                title: zh ? "重复规则（RRULE）" : "Recurrence rule (RRULE)", text: $draft.rruleText,
                prompt: "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO", multiline: true,
                hint: zh
                    ? "iCalendar 的 RRULE，比如每两周的周一：FREQ=WEEKLY;INTERVAL=2;BYDAY=MO。也可以贴带 DTSTART 的完整规则。"
                    : "An iCalendar RRULE, for example every other Monday: FREQ=WEEKLY;INTERVAL=2;BYDAY=MO. "
                        + "You can also paste a full rule with DTSTART.", monospaced: true)
        }
        .themedRow()
        if !draft.rruleHasOwnStart {
            Section {
                DatePicker(selection: startDayBinding, displayedComponents: .date) {
                    Label(zh ? "从哪天开始" : "Starts", systemImage: "calendar")
                }
                timeRow
            }
            .themedRow()
        }
    }

    // MARK: 时区

    private var timeZoneRow: some View {
        let zh = language == .chinese
        let isDevice = draft.timeZoneID == TimeZone.current.identifier
        return Section {
            NavigationLink {
                TimeZonePickerView(selection: $draft.timeZoneID)
            } label: {
                LabeledRow(
                    systemImage: "globe", title: zh ? "时区" : "Time zone",
                    detail: plansTimeZoneName(draft.timeZoneID, language: language)
                        + (isDevice ? (zh ? " · 本机" : " · this device") : ""))
            }
        }
        .themedRow()
    }

    // MARK: 预览

    private func preview(problem: TriggerProblem?) -> some View {
        let zh = language == .chinese
        let schedule = draft.schedule
        let fires = problem == nil && draft.warning == nil ? draft.upcoming(now: now, count: 5) ?? [] : []
        return Section {
            Text(ScheduleDescription.describe(schedule, language: language))
                .typography(.headline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Label(problem.message(language), systemImage: "exclamationmark.circle")
                    .typography(.subheadline)
                    .foregroundStyle(StatusTone.failure.color)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let warning = draft.warning {
                Text(warning.message(language))
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(fires, id: \.self) { date in
                LabeledContent(Formatting.dateTime(date, now: now, language: language), value: weekday(date))
                    .monospacedDigit()
            }
        } header: {
            Text(zh ? "预览" : "Preview").textCase(nil)
        } footer: {
            if !fires.isEmpty {
                Text(
                    zh
                        ? "上面是接下来几次（按本机时区）。App 在本地算的，实际以服务端为准；为了错开高峰可能晚几分钟开始。"
                        : "Coming up, in this device's time. Worked out on this device; the server has the final say, "
                            + "and runs may start a few minutes late.")
            }
        }
        .themedRow()
    }

    private func weekday(_ date: Date) -> String {
        let index = Calendar.current.component(.weekday, from: date) - 1
        let names =
            language == .chinese
            ? ["周日", "周一", "周二", "周三", "周四", "周五", "周六"] : ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return names[max(0, min(6, index))]
    }
}

/// 选日子的小圆按钮（周几、几号）：系统按钮的玻璃圆，选中的是突出的那种（强调色）。读屏读全名和“已选”。
struct PlansDayToggle: View {
    let text: String
    let accessibilityName: String
    let isOn: Bool
    let action: @MainActor () -> Void

    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 30

    var body: some View {
        Button(action: action) {
            Text(verbatim: text)
                .font(.subheadline.weight(isOn ? .semibold : .regular))
                .monospacedDigit()
                .frame(width: size, height: size)
        }
        .glassButtonStyle(isOn ? .prominent : .regular)
        .buttonBorderShape(.circle)
        .accessibilityLabel(Text(accessibilityName))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// 选时区：本机的、常用的、全部（可以搜）。
struct TimeZonePickerView: View {
    @Binding var selection: String
    @State private var query = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayLanguage) private var language

    /// 常用的几个（中国大陆、港澳台、日本、新加坡、欧美、UTC）。
    static let common = [
        "Asia/Shanghai", "Asia/Hong_Kong", "Asia/Taipei", "Asia/Tokyo", "Asia/Singapore", "Europe/London",
        "Europe/Berlin", "America/New_York", "America/Los_Angeles", "UTC",
    ]

    var body: some View {
        let zh = language == .chinese
        let device = TimeZone.current.identifier
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let matches =
            trimmed.isEmpty ? [] : (["UTC"] + TimeZone.knownTimeZoneIdentifiers).filter { matchesQuery($0, trimmed) }
        List {
            if trimmed.isEmpty {
                group([device], title: zh ? "本机" : "This device")
                group(Self.common.filter { $0 != device }, title: zh ? "常用" : "Common")
                group(TimeZone.knownTimeZoneIdentifiers, title: zh ? "全部" : "All")
            } else if !matches.isEmpty {
                group(matches, title: nil)
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .overlay {
            if !trimmed.isEmpty, matches.isEmpty {
                ContentUnavailableView.search(text: trimmed)
            }
        }
        .inlineNavigationTitle(zh ? "时区" : "Time zone")
        .searchable(text: $query, prompt: Text(zh ? "城市或地区，比如 Shanghai" : "City or region, e.g. London"))
    }

    /// 一组时区：一行名字、右边灰色的“GMT+8”，选中的右边系统勾；点了选上并退回去。
    private func group(_ ids: [String], title: String?) -> some View {
        Section {
            ForEach(ids, id: \.self) { id in
                Button {
                    selection = id
                    dismiss()
                } label: {
                    HStack(spacing: Metrics.Spacing.xs) {
                        LabeledContent(plansTimeZoneName(id, language: language), value: offset(id) ?? "")
                            .foregroundStyle(Theme.ink)
                        if id == selection {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(id == selection ? [.isButton, .isSelected] : .isButton)
            }
        } header: {
            if let title { Text(title).textCase(nil) }
        }
        .themedRow()
    }

    private func matchesQuery(_ id: String, _ query: String) -> Bool {
        id.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            || plansTimeZoneName(id, language: language).range(of: query, options: .caseInsensitive) != nil
    }

    /// “GMT+8”。
    private func offset(_ id: String) -> String? {
        guard let zone = TimeZone(identifier: id) else { return nil }
        let seconds = zone.secondsFromGMT()
        let hours = seconds / 3600
        let minutes = abs(seconds % 3600) / 60
        let sign = seconds >= 0 ? "+" : "-"
        return "GMT" + sign + "\(abs(hours))" + (minutes == 0 ? "" : String(format: ":%02d", minutes))
    }
}

#Preview("触发器编辑器 · 每周 · 浅色中文") {
    TriggerEditorView(
        draft: TriggerDraft(schedule: .cron(expression: "30 9 * * 1-5", timeZone: "Asia/Shanghai")), title: "修改触发规则"
    ) { _ in }
    .previewShell()
}

#Preview("触发器编辑器 · RRULE · 深色英文") {
    TriggerEditorView(
        draft: TriggerDraft(
            schedule: .rrule("DTSTART;TZID=Asia/Tokyo:20261101T183000\nRRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=FR")),
        title: "Edit schedule"
    ) { _ in }
    .previewShell(.english, scheme: .dark)
}

#Preview("触发器编辑器 · 太频繁 · 浅色中文") {
    TriggerEditorView(
        draft: TriggerDraft(schedule: .cron(expression: "* * * * *", timeZone: "Asia/Shanghai")), title: "修改规则"
    ) { _ in }
    .previewShell()
}

#Preview("时区 · 深色英文") {
    TimeZonePickerView(selection: .constant("Asia/Shanghai"))
        .previewShell(.english, scheme: .dark)
}

#Preview("时区 · 浅色中文") {
    TimeZonePickerView(selection: .constant("Asia/Tokyo"))
        .previewShell()
}
