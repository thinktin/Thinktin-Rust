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
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                PageHeader(title: route.title(language), message: TeamsText.intro(language))
                if let error = visibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                if let error = model.actionError {
                    ErrorBanner(error, onDismiss: { model.clearActionError() })
                }
                if !model.hasLoaded {
                    LoadingStateView()
                } else {
                    if !templatesOnly { teamsSection }
                    templatesSection
                }
            }
            .pageLayout()
        }
        .background(Theme.paper)
        .inlineNavigationTitle(route.title(language))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !templatesOnly {
                    Button {
                        isCreating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(app.isOffline)
                    .accessibilityLabel(Text(zh ? "新建团队" : "New team"))
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
            Text(zh ? "已经领养的团队和实例不受影响。" : "Teams and instances already adopted from it stay.")
        }
    }

    @ViewBuilder
    private var teamsSection: some View {
        let zh = language == .chinese
        let model = self.model
        SectionHeader(title: zh ? "我的团队" : "My teams")
        if model.teams.isEmpty {
            InlineNotice(
                systemImage: "person.3", tone: .neutral,
                text: zh ? "还没有团队。右上角新建，或者领养一个模板。" : "No teams yet. Create one, or adopt a template.")
        } else {
            GroupedSection {
                ForEach(model.teams) { team in
                    if team.id != model.teams.first?.id { Divider() }
                    ListRow(
                        systemImage: "person.3", title: team.name,
                        detail: [
                            team.lead.flatMap { model.instanceName($0.instanceID) }.map {
                                zh ? "负责人：\($0)" : "Lead: \($0)"
                            },
                            TeamsText.memberCount(team.members.count, language: language),
                        ].compactMap { $0 }.joined(separator: " · ")
                    ) {
                        router.open(.team(team.id))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var templatesSection: some View {
        let zh = language == .chinese
        let model = self.model
        SectionHeader(title: zh ? "团队模板" : "Team templates")
        if model.templates.isEmpty {
            InlineNotice(
                systemImage: "square.on.square", tone: .neutral,
                text: zh ? "还没有模板。在团队详情里“存为模板”。" : "No templates yet. Use “Save as template” on a team.")
        } else {
            GroupedSection {
                ForEach(model.templates) { template in
                    if template.id != model.templates.first?.id { Divider() }
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
        }
    }
}

/// 模板的一行：名字、成员（负责人标出来）；“领养”和“更多”里删除。
struct TemplateRow: View {
    let template: TeamTemplate
    let isBusy: Bool
    let canWrite: Bool
    let onAdopt: () -> Void
    let onDelete: () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        HStack(spacing: Metrics.Spacing.xs) {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                Text(verbatim: template.name)
                    .typography(.body)
                    .foregroundStyle(Theme.ink)
                Text(
                    verbatim: template.members.map { member in
                        member.isLead ? "\(member.name)（\(TeamsText.role(.lead, language: language))）" : member.name
                    }.joined(separator: zh ? "、" : ", ")
                )
                .typography(.caption)
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isBusy {
                ProgressView()
                    .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
            } else {
                Button {
                    onAdopt()
                } label: {
                    Text(zh ? "领养" : "Adopt")
                        .typography(.subheadline)
                        .frame(minHeight: Metrics.minTapTarget)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .disabled(!canWrite)
                Menu {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label(zh ? "删除" : "Delete", systemImage: "trash")
                    }
                    .disabled(!canWrite)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text(zh ? "“\(template.name)”的更多操作" : "More for “\(template.name)”"))
            }
        }
        .padding(.leading, Metrics.Spacing.m)
        .padding(.trailing, Metrics.Spacing.xxs)
        .padding(.vertical, Metrics.Spacing.s)
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
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                if model.isMissing {
                    EmptyStateView(
                        systemImage: "questionmark.circle", title: zh ? "找不到这个团队" : "Team not found",
                        message: zh ? "可能已经删掉了。" : "It may have been deleted.")
                } else if let team = model.team {
                    if let error = model.actionError {
                        ErrorBanner(error, onDismiss: { model.clearActionError() })
                    }
                    if model.savedTemplate != nil {
                        NoticeText(text: zh ? "已存为模板。" : "Saved as a template.", tone: .success)
                            .onTapGesture { model.clearSavedTemplate() }
                    }
                    SectionHeader(title: TeamsText.memberCount(team.members.count, language: language))
                    GroupedSection {
                        ForEach(model.members) { member in
                            if member.id != model.members.first?.id { Divider() }
                            ListRow(
                                systemImage: member.isLead ? "star" : "person",
                                title: model.instanceName(member.instanceID) ?? (zh ? "已删除的实例" : "Deleted instance"),
                                detail: TeamsText.role(member.role, language: language),
                                detailTone: member.isLead ? .success : nil,
                                action: { router.open(.instance(member.instanceID)) }
                            ) {
                                Button {
                                    router.open(.modelRoutes(member.instanceID))
                                } label: {
                                    Text(zh ? "配模型" : "Models")
                                        .typography(.footnote)
                                        .frame(minHeight: Metrics.minTapTarget)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    InlineNotice(
                        systemImage: "cpu", tone: .neutral,
                        text: zh
                            ? "刚领养的团队要给每个成员选默认模型（main），点“配模型”。"
                            : "A freshly adopted team needs a default model (main) for each member. Tap “Models”.")
                    PillButton(
                        zh ? "用这个团队建流水线" : "Build a pipeline with this team", systemImage: "arrow.triangle.branch"
                    ) {
                        router.open(.pipelineEditor(planID: nil, teamID: team.id))
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(app.isOffline)
                    PillButton(zh ? "存为模板" : "Save as template", systemImage: "square.on.square", kind: .secondary) {
                        Task { await model.saveAsTemplate() }
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(app.isOffline || model.isWorking)
                    Button(role: .destructive) {
                        isConfirmingDeletion = true
                    } label: {
                        Text(zh ? "删除团队" : "Delete team")
                            .typography(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StatusTone.failure.color)
                    .disabled(app.isOffline || model.isWorking)
                } else if let error = visibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                } else {
                    LoadingStateView()
                }
            }
            .pageLayout()
        }
        .background(Theme.paper)
        .inlineNavigationTitle(model.team?.name ?? AppRoute.team(model.teamID).title(language))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.team != nil {
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
                    ? "只删团队，成员实例和它们的对话、计划都还在。"
                    : "Only the team goes. Its instances and their chats and plans stay.")
        }
    }
}

/// 新建 / 编辑团队（sheet）：名字、成员（勾选实例，1–12 个）、负责人（一个）。
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
    let onFinish: @MainActor (Team?) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    init(model: TeamEditorModel, onFinish: @escaping @MainActor (Team?) -> Void) {
        _model = State(initialValue: model)
        self.onFinish = onFinish
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        let problems = model.showsProblems ? model.problems : []
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                if let error = model.saveError {
                    ErrorBanner(error)
                }
                if !model.hasLoaded {
                    if let error = model.error {
                        ErrorBanner(error) { Task { await model.load() } }
                    } else {
                        LoadingStateView()
                    }
                } else {
                    PlansTextField(
                        title: zh ? "团队名" : "Team name", text: $model.name,
                        prompt: zh ? "比如：调研小组" : "For example: Research squad", limit: TeamEditorModel.maxName,
                        count: model.name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count,
                        problem: problems.first { $0 == .nameEmpty || $0 == .nameTooLong }.map {
                            TeamsText.teamProblem($0, language: language)
                        })
                    SectionHeader(
                        title: zh
                            ? "成员（最多 \(TeamEditorModel.maxMembers) 个）" : "Members (up to \(TeamEditorModel.maxMembers))"
                    )
                    if let problem = problems.first(where: { [.noMembers, .tooManyMembers, .noLead].contains($0) }) {
                        Text(TeamsText.teamProblem(problem, language: language))
                            .typography(.footnote)
                            .foregroundStyle(StatusTone.failure.color)
                    }
                    if model.instances.isEmpty {
                        InlineNotice(
                            systemImage: "exclamationmark.triangle", tone: .waiting,
                            text: zh ? "还没有实例，先去 agent 目录领养。" : "No instances yet. Adopt one from the catalog first.")
                    } else {
                        GroupedSection {
                            ForEach(model.instances) { instance in
                                if instance.id != model.instances.first?.id { Divider() }
                                memberRow(instance)
                            }
                        }
                    }
                }
            }
            .pageLayout()
        }
        .background(Theme.paper)
        .inlineNavigationTitle(model.teamID == nil ? (zh ? "新建团队" : "New team") : (zh ? "编辑团队" : "Edit team"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(zh ? "取消" : "Cancel") { onFinish(nil) }
                    .disabled(model.isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(model.isSaving ? (zh ? "正在保存…" : "Saving…") : (zh ? "保存" : "Save")) {
                    Task {
                        if let team = await model.save() { onFinish(team) }
                    }
                }
                .disabled(model.isSaving || !model.hasLoaded || app.isOffline)
            }
        }
        .task { await model.load() }
    }

    private func memberRow(_ instance: Instance) -> some View {
        let zh = language == .chinese
        let model = self.model
        let isSelected = model.selected.contains(instance.id)
        let isLead = model.lead == instance.id
        return HStack(spacing: Metrics.Spacing.s) {
            Button {
                model.toggle(instance.id)
            } label: {
                HStack(spacing: Metrics.Spacing.s) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Theme.accent : Theme.inkTertiary)
                        .accessibilityHidden(true)
                    Text(verbatim: instance.name)
                        .typography(.body)
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Metrics.minTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(isSelected ? (zh ? "已选" : "Selected") : (zh ? "未选" : "Not selected")))
            if isSelected {
                Button {
                    model.setLead(instance.id)
                } label: {
                    Label(
                        TeamsText.role(.lead, language: language), systemImage: isLead ? "star.fill" : "star"
                    )
                    .typography(.footnote)
                    .frame(minHeight: Metrics.minTapTarget)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isLead ? Theme.accent : Theme.inkSecondary)
                .accessibilityLabel(Text(zh ? "让“\(instance.name)”当负责人" : "Make “\(instance.name)” the lead"))
                .accessibilityValue(Text(isLead ? (zh ? "是负责人" : "Lead") : ""))
            }
        }
        .padding(.horizontal, Metrics.Spacing.m)
    }
}
