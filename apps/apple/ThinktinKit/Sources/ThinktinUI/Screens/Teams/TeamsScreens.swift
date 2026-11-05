import SwiftUI
import ThinktinKit

/// 团队（`.teams`，抽屉里的“团队”，WBS 12.7）：我的团队（负责人、成员数，点进详情）和团队模板（一键领养整个团队、删除）；
/// 右上角新建团队。离线策略是“没有缓存”：离线时显示已经拉到的，写操作禁用。
struct TeamsScreen: View {
    @Environment(\.client) private var client

    var body: some View {
        TeamsContent(model: TeamsModel(client: client), templatesOnly: false)
    }
}

/// 团队模板（`.teamTemplates`）：只列模板。
struct TeamTemplatesScreen: View {
    @Environment(\.client) private var client

    var body: some View {
        TeamsContent(model: TeamsModel(client: client), templatesOnly: true)
    }
}

private struct TeamsContent: View {
    @State private var model: TeamsModel
    @State private var isCreating = false
    @State private var pendingDeletion: TeamTemplate?
    @State private var isConfirmingDeletion = false
    let templatesOnly: Bool

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(model: TeamsModel, templatesOnly: Bool) {
        _model = State(initialValue: model)
        self.templatesOnly = templatesOnly
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        let route: AppRoute = templatesOnly ? .teamTemplates : .teams
        List {
            if let error = visibleError(model.error) {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                        .clearListRow()
                }
            }
            if let error = model.actionError {
                Section {
                    ErrorBanner(error, onDismiss: { model.clearActionError() })
                        .clearListRow()
                }
            }
            if model.hasLoaded {
                if !templatesOnly { teamsSection }
                templatesSection
            }
        }
        .insetGroupedList()
        // 导航栏下面不放说明段落（和计划、产出物一样，规范 4.5.1）：说明挪到第一组的脚注，第一组贴着导航栏。
        .compactGroupedList()
        .themedGroupedBackground()
        .overlay {
            if !model.hasLoaded, visibleError(model.error) == nil { ProgressView() }
        }
        .inlineNavigationTitle(route.title(language))
        .toolbar {
            if !templatesOnly {
                ToolbarItem(placement: ToolbarSlot.trailing) {
                    Button {
                        isCreating = true
                    } label: {
                        Label(zh ? "新建团队" : "New team", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(app.isOffline)
                }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .sheet(isPresented: $isCreating) {
            NavigationStack {
                TeamEditorView(teamID: nil) { team in
                    isCreating = false
                    if let team { router.open(.team(team.id)) }
                }
            }
        }
        .confirmationDialog(
            zh ? "删除模板“\(pendingDeletion?.name ?? "")”？" : "Delete template “\(pendingDeletion?.name ?? "")”?",
            isPresented: $isConfirmingDeletion, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                if let template = pendingDeletion { Task { await model.deleteTemplate(template) } }
            } label: {
                Text(zh ? "删除" : "Delete")
            }
            Button(role: .cancel) {
                pendingDeletion = nil
            } label: {
                Text(zh ? "取消" : "Cancel")
            }
        } message: {
            Text(zh ? "已经用它建好的团队和 Botin 不受影响。" : "Teams and Botins already created from it stay.")
        }
    }

    /// 我的团队：一行一个团队（负责人头像、名字、“负责人 · N 个成员”），点进详情；没有时组里一行灰字（参考 62 的“暂无规则”）。
    private var teamsSection: some View {
        let zh = language == .chinese
        let model = self.model
        return Section {
            if model.teams.isEmpty {
                Text(zh ? "还没有团队。右上角新建，或者用下面的模板新建一个。" : "No teams yet. Create one, or start from a template below.")
                    .typography(.body)
                    .foregroundStyle(Theme.inkTertiary)
            } else {
                ForEach(model.teams) { team in
                    NavigationLink(value: AppRoute.team(team.id)) {
                        TeamRow(
                            team: team, leadName: team.lead.flatMap { model.instanceName($0.instanceID) },
                            leadAppearance: team.lead.map { app.appearances.resolved(for: $0.instanceID) })
                    }
                }
            }
        } header: {
            Text(zh ? "我的团队" : "My teams").groupHeader()
        } footer: {
            Text(TeamsText.intro(language))
        }
        .themedRow()
    }

    /// 团队模板：一行一个模板，右边小玻璃胶囊“新建团队”；左滑、长按删除。
    private var templatesSection: some View {
        let zh = language == .chinese
        let model = self.model
        return Section {
            if model.templates.isEmpty {
                Text(zh ? "还没有模板。在团队详情里“存为模板”。" : "No templates yet. Use “Save as template” on a team.")
                    .typography(.body)
                    .foregroundStyle(Theme.inkTertiary)
            } else {
                ForEach(model.templates) { template in
                    TemplateRow(
                        template: template, isBusy: model.busyTemplate == template.id,
                        canWrite: !app.isOffline && model.busyTemplate == nil,
                        onAdopt: {
                            Task {
                                if let team = await model.adopt(template) {
                                    await app.refresh()
                                    router.open(.team(team.id))
                                }
                            }
                        },
                        onDelete: {
                            pendingDeletion = template
                            isConfirmingDeletion = true
                        })
                }
            }
        } header: {
            Text(zh ? "团队模板" : "Team templates").groupHeader()
        } footer: {
            // 只列模板的页面没有“我的团队”一组，说明放在这里。
            if templatesOnly { Text(TeamsText.intro(language)) }
        }
        .themedRow()
    }
}

/// 团队页的行首：团队的负责人头像、模板的团队图标一样宽，两组的字对齐。
enum TeamsLayout {
    static let leadingIcon: CGFloat = 32
}

/// 我的团队的一行：负责人的头像（没有负责人时是团队图标）、名字、“负责人：X · N 个成员”。
struct TeamRow: View {
    let team: Team
    let leadName: String?
    var leadAppearance: InstanceAppearance?

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        HStack(spacing: Metrics.Spacing.s) {
            if let leadName {
                InstanceAvatar(leadName, appearance: leadAppearance, size: TeamsLayout.leadingIcon)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "person.3")
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: TeamsLayout.leadingIcon, height: TeamsLayout.leadingIcon)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                Text(verbatim: team.name)
                    .typography(.body)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(
                    verbatim: [
                        leadName.map { zh ? "负责人：\($0)" : "Lead: \($0)" },
                        TeamsText.memberCount(team.members.count, language: language),
                    ].compactMap { $0 }.joined(separator: " · ")
                )
                .typography(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 模板的一行：左边团队图标（和团队那一行的头像同宽，两组的字从同一个 x 起）、名字、成员（负责人标出来）；右边强调色的
/// 文字按钮“新建团队”（领养模板；行里不用玻璃胶囊，白底上它的阴影是一圈灰晕）；左滑和长按菜单里删除。
struct TemplateRow: View {
    let template: TeamTemplate
    let isBusy: Bool
    let canWrite: Bool
    let onAdopt: () -> Void
    let onDelete: () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        HStack(spacing: Metrics.Spacing.s) {
            Image(systemName: "person.3")
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: TeamsLayout.leadingIcon, height: TeamsLayout.leadingIcon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                Text(verbatim: template.name)
                    .typography(.body)
                    .foregroundStyle(Theme.ink)
                Text(
                    verbatim: template.members.map { member in
                        member.isLead ? "\(member.name)（\(TeamsText.role(.lead, language: language))）" : member.name
                    }.joined(separator: zh ? "、" : ", ")
                )
                .typography(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if isBusy {
                ProgressView()
            } else {
                Button(zh ? "新建团队" : "Create team") { onAdopt() }
                    .buttonStyle(.borderless)
                    .typography(.subheadline)
                    .disabled(!canWrite)
                    .accessibilityLabel(
                        Text(zh ? "用模板“\(template.name)”新建团队" : "Create a team from “\(template.name)”"))
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // `onDelete` 只弹确认：不用 `.destructive`，不然系统先把行收走。
            Button {
                onDelete()
            } label: {
                Label(zh ? "删除" : "Delete", systemImage: "trash")
            }
            .tint(StatusTone.failure.color)
            .disabled(!canWrite)
        }
        .contextMenu {
            Button {
                onAdopt()
            } label: {
                Label(zh ? "新建团队" : "Create team", systemImage: "person.3")
            }
            .disabled(!canWrite)
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(zh ? "删除" : "Delete", systemImage: "trash")
            }
            .disabled(!canWrite)
        }
    }
}

/// 团队详情（`.team(id)`）：负责人和成员（点进实例详情，“配模型”去模型路由）；编辑、用这个团队建流水线、存为模板、删除。
struct TeamDetailScreen: View {
    let teamID: TeamID

    @Environment(\.client) private var client

    var body: some View {
        TeamDetailContent(model: TeamDetailModel(client: client, teamID: teamID))
    }
}

private struct TeamDetailContent: View {
    @State private var model: TeamDetailModel
    @State private var isEditing = false
    @State private var isConfirmingDeletion = false

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(model: TeamDetailModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        List {
            if let team = model.team, !model.isMissing {
                Section {
                    TeamHeader(
                        name: team.name, memberCount: team.members.count,
                        members: model.members.map {
                            (
                                name: model.instanceName($0.instanceID) ?? "?",
                                appearance: app.appearances.resolved(for: $0.instanceID)
                            )
                        }
                    )
                    .clearListRow()
                }
                if let error = model.actionError {
                    Section {
                        ErrorBanner(error, onDismiss: { model.clearActionError() })
                            .clearListRow()
                    }
                }
                if model.savedTemplate != nil {
                    Section {
                        Button {
                            model.clearSavedTemplate()
                        } label: {
                            NoticeText(text: zh ? "已存为模板。" : "Saved as a template.", tone: .success)
                        }
                        .buttonStyle(.plain)
                    }
                    .themedRow()
                }
                Section {
                    ForEach(model.members) { member in
                        memberRow(member)
                    }
                } header: {
                    Text(TeamsText.memberCount(team.members.count, language: language)).textCase(nil)
                } footer: {
                    Text(
                        zh
                            ? "刚用模板建好的团队要给每个成员选默认模型（main），点“配模型”。"
                            : "A team just created from a template needs a default model (main) for each member. "
                                + "Tap “Models”.")
                }
                .themedRow()
                Section {
                    Button {
                        router.open(.pipelineEditor(planID: nil, teamID: team.id))
                    } label: {
                        Label(
                            zh ? "用这个团队建流水线" : "Build a pipeline with this team",
                            systemImage: "arrow.triangle.branch")
                    }
                    .disabled(app.isOffline)
                    Button {
                        Task { await model.saveAsTemplate() }
                    } label: {
                        Label(zh ? "存为模板" : "Save as template", systemImage: "square.on.square")
                    }
                    .disabled(app.isOffline || model.isWorking)
                }
                .themedRow()
                Section {
                    Button(role: .destructive) {
                        isConfirmingDeletion = true
                    } label: {
                        Text(zh ? "删除团队" : "Delete team")
                    }
                    .disabled(app.isOffline || model.isWorking)
                }
                .themedRow()
            } else if !model.isMissing, let error = visibleError(model.error) {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                        .clearListRow()
                }
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .overlay {
            if model.isMissing {
                ContentUnavailableView {
                    Label(zh ? "找不到这个团队" : "Team not found", systemImage: "questionmark.circle")
                } description: {
                    Text(zh ? "可能已经删掉了。" : "It may have been deleted.")
                }
            } else if model.team == nil, visibleError(model.error) == nil {
                ProgressView()
            }
        }
        .inlineNavigationTitle(model.team?.name ?? AppRoute.team(model.teamID).title(language))
        .toolbar {
            if model.team != nil {
                ToolbarItem(placement: ToolbarSlot.trailing) {
                    Button(zh ? "编辑" : "Edit") { isEditing = true }
                        .disabled(app.isOffline)
                }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: model.isDeleted) {
            if model.isDeleted { router.pop() }
        }
        .sheet(isPresented: $isEditing) {
            NavigationStack {
                TeamEditorView(teamID: model.teamID) { team in
                    isEditing = false
                    if team != nil { Task { await model.load() } }
                }
            }
        }
        .confirmationDialog(
            zh ? "删除团队“\(model.team?.name ?? "")”？" : "Delete team “\(model.team?.name ?? "")”?",
            isPresented: $isConfirmingDeletion, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await model.delete() }
            } label: {
                Text(zh ? "删除团队" : "Delete team")
            }
            Button(role: .cancel) {
            } label: {
                Text(zh ? "取消" : "Cancel")
            }
        } message: {
            Text(
                zh
                    ? "只删团队，成员 Botin 和它们的对话、计划都还在。"
                    : "Only the team goes. Its Botins and their chats and plans stay.")
        }
    }

    /// 一个成员：头像、名字、角色（负责人用成功色），点进 Botin 资料；右边小玻璃胶囊“配模型”去它的模型路由。
    private func memberRow(_ member: TeamMember) -> some View {
        let zh = language == .chinese
        let name = model.instanceName(member.instanceID) ?? (zh ? "已删除的 Botin" : "Deleted Botin")
        return HStack(spacing: Metrics.Spacing.s) {
            NavigationLink(value: AppRoute.instance(member.instanceID)) {
                HStack(spacing: Metrics.Spacing.s) {
                    InstanceAvatar(name, appearance: app.appearances.resolved(for: member.instanceID), size: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                        Text(verbatim: name)
                            .typography(.body)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Text(TeamsText.role(member.role, language: language))
                            .typography(.subheadline)
                            .foregroundStyle(member.isLead ? StatusTone.success.color : Theme.inkSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Button(zh ? "配模型" : "Models") {
                router.open(.modelRoutes(member.instanceID))
            }
            .smallCapsuleButton()
            .accessibilityLabel(Text(zh ? "给“\(name)”配模型" : "Models for “\(name)”"))
        }
    }
}

/// 团队详情的头部（照 Botin 资料页居中排）：成员头像叠在一起（最多 4 个）、团队名 `.title2.bold()`、成员数。
struct TeamHeader: View {
    let name: String
    let memberCount: Int
    let members: [(name: String, appearance: InstanceAppearance)]

    @Environment(\.displayLanguage) private var language

    var body: some View {
        VStack(spacing: Metrics.Spacing.xs) {
            HStack(spacing: -Metrics.Spacing.s) {
                ForEach(Array(members.prefix(4).enumerated()), id: \.offset) { _, member in
                    InstanceAvatar(member.name, appearance: member.appearance, size: 56)
                        .padding(2)
                        .background(Theme.paper, in: Circle())
                }
            }
            .accessibilityHidden(true)
            Text(verbatim: name)
                .font(.title2.bold())
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text(TeamsText.memberCount(memberCount, language: language))
                .typography(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.Spacing.s)
        .accessibilityElement(children: .combine)
    }
}

/// 新建 / 编辑团队（sheet），照参考 11 的选择器版式（规范 4.4.5）：左上 `CloseButton`、右上 `ConfirmButton("保存")`；
/// 名字一组（标签在上的输入框、字数），成员一组（一行一个 Botin：头像、名字，选中的右边系统勾；1–12 个），
/// 负责人一组（选中的成员里挑一个，`Picker(.menu)`）；`.searchable` 按名字筛成员，没有 Botin 时 `ContentUnavailableView`。
struct TeamEditorView: View {
    let teamID: TeamID?
    /// 关掉（保存了带上团队，取消是 nil）。
    let onFinish: @MainActor (Team?) -> Void

    @Environment(\.client) private var client

    var body: some View {
        TeamEditorContent(model: TeamEditorModel(client: client, teamID: teamID), onFinish: onFinish)
    }
}

private struct TeamEditorContent: View {
    @State private var model: TeamEditorModel
    @State private var query = ""
    let onFinish: @MainActor (Team?) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    init(model: TeamEditorModel, onFinish: @escaping @MainActor (Team?) -> Void) {
        _model = State(initialValue: model)
        self.onFinish = onFinish
    }

    /// 搜索框里有字时只列名字里带这些字的 Botin（不分大小写）；选中的不受影响。
    private var shownInstances: [Instance] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return model.instances }
        return model.instances.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        let zh = language == .chinese
        @Bindable var bindable = model
        let problems = model.showsProblems ? model.problems : []
        Form {
            if let error = model.saveError {
                Section {
                    ErrorBanner(error)
                        .clearListRow()
                }
            }
            if model.hasLoaded {
                Section {
                    FormTextField(
                        title: zh ? "团队名" : "Team name", text: $bindable.name,
                        prompt: zh ? "比如：调研小组" : "For example: Research squad", limit: TeamEditorModel.maxName,
                        count: model.name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count,
                        problem: problems.first { $0 == .nameEmpty || $0 == .nameTooLong }.map {
                            TeamsText.teamProblem($0, language: language)
                        })
                }
                .themedRow()
                if !model.instances.isEmpty {
                    Section {
                        ForEach(shownInstances) { instance in
                            memberRow(instance)
                        }
                    } header: {
                        Text(
                            zh
                                ? "成员（最多 \(TeamEditorModel.maxMembers) 个）"
                                : "Members (up to \(TeamEditorModel.maxMembers))"
                        )
                        .textCase(nil)
                    } footer: {
                        if let problem = problems.first(where: { [.noMembers, .tooManyMembers].contains($0) }) {
                            Text(TeamsText.teamProblem(problem, language: language))
                                .foregroundStyle(StatusTone.failure.color)
                        }
                    }
                    .themedRow()
                    Section {
                        Picker(TeamsText.role(.lead, language: language), selection: leadBinding) {
                            Text(zh ? "未选" : "None").tag(InstanceID?.none)
                            ForEach(model.selected, id: \.self) { id in
                                Text(verbatim: model.instances.first { $0.id == id }?.name ?? id.rawValue)
                                    .tag(InstanceID?.some(id))
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(model.selected.isEmpty)
                    } footer: {
                        if problems.contains(.noLead) {
                            Text(TeamsText.teamProblem(.noLead, language: language))
                                .foregroundStyle(StatusTone.failure.color)
                        }
                    }
                    .themedRow()
                }
            } else if let error = model.error {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                        .clearListRow()
                }
            }
        }
        .formStyle(.grouped)
        .themedGroupedBackground()
        .overlay {
            if !model.hasLoaded, model.error == nil {
                ProgressView()
            } else if model.hasLoaded, model.instances.isEmpty {
                ContentUnavailableView {
                    Label(zh ? "还没有 Botin" : "No Botins yet", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text(zh ? "先新建一个 Botin，再来组团队。" : "Create a Botin first, then build a team.")
                }
            } else if model.hasLoaded, shownInstances.isEmpty, !query.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, prompt: Text(zh ? "搜索 Botin" : "Search Botins"))
        .inlineNavigationTitle(model.teamID == nil ? (zh ? "新建团队" : "New team") : (zh ? "编辑团队" : "Edit team"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                CloseButton { onFinish(nil) }
                    .disabled(model.isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                ConfirmButton(zh ? "保存" : "Save", isWorking: model.isSaving) {
                    Task {
                        if let team = await model.save() { onFinish(team) }
                    }
                }
                .disabled(!model.hasLoaded || app.isOffline)
            }
        }
        .task { await model.load() }
    }

    /// 负责人：只能是选中的成员；选“未选”不改（模型里负责人不能清空，取消勾选时自己会换）。
    private var leadBinding: Binding<InstanceID?> {
        Binding(
            get: { model.lead },
            set: { id in
                if let id { model.setLead(id) }
            })
    }

    /// 一个 Botin：头像、名字，选中的右边一个系统勾（参考 11 的单选行，这里能多选）。负责人名字后面标出来。
    private func memberRow(_ instance: Instance) -> some View {
        let zh = language == .chinese
        let isSelected = model.selected.contains(instance.id)
        let isLead = model.lead == instance.id
        return Button {
            model.toggle(instance.id)
        } label: {
            HStack(spacing: Metrics.Spacing.s) {
                InstanceAvatar(instance.name, appearance: app.appearances.resolved(for: instance.id), size: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    Text(verbatim: instance.name)
                        .typography(.body)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if isLead {
                        Text(TeamsText.role(.lead, language: language))
                            .typography(.subheadline)
                            .foregroundStyle(StatusTone.success.color)
                    }
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(Text(isLead ? (zh ? "负责人" : "Lead") : ""))
    }
}
