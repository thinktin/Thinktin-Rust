import Foundation
import Testing

@testable import ThinktinKit

/// 团队测试用的 Mock：演示数据（发版小组：代码审查当负责人、写作助手当成员；内容团队模板三个成员）。
@MainActor
enum TeamsFixture {
    static func mock(_ edit: (inout MockState) -> Void = { _ in }) -> MockClient {
        var state = DemoData.state()
        edit(&state)
        return MockClient(state: state, stepDelay: 0, autoReply: false)
    }
}

@MainActor
@Suite("团队、团队模板、团队编辑")
struct TeamsModelsTests {
    @Test("团队列表：团队和模板都拉到，实例名字认得出")
    func list() async {
        let mock = TeamsFixture.mock()
        let model = TeamsModel(client: mock)
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.teams.map(\.id) == [DemoData.releaseTeamID])
        #expect(model.templates.map(\.id) == [DemoData.contentTemplateID])
        #expect(model.instanceName(DemoData.reviewerID) != nil)
        #expect(model.error == nil)
    }

    @Test("一键领养模板：整个团队建好排在最前，新实例的名字也认得出")
    func adopt() async throws {
        let mock = TeamsFixture.mock()
        let model = TeamsModel(client: mock)
        await model.load()
        let template = try #require(model.templates.first)
        let team = try #require(await model.adopt(template))
        #expect(model.teams.first?.id == team.id)
        #expect(team.members.count == 3)
        #expect(team.lead != nil)
        #expect(team.members.allSatisfy { model.instanceName($0.instanceID) != nil })
        #expect(model.busyTemplate == nil)
    }

    @Test("领养失败（实例数上限）：报错，不加团队")
    func adoptFails() async throws {
        let mock = TeamsFixture.mock()
        let model = TeamsModel(client: mock)
        await model.load()
        let template = try #require(model.templates.first)
        mock.failNext(
            "adoptTeamTemplate(_:name:)",
            with: .api(status: 409, code: .instanceLimit, message: "instance limit", retryAfterSecs: nil))
        #expect(await model.adopt(template) == nil)
        #expect(model.actionError != nil)
        #expect(model.teams.count == 1)
        model.clearActionError()
        #expect(model.actionError == nil)
    }

    @Test("删模板：从列表里去掉；已经被删了（404）也去掉")
    func deleteTemplate() async throws {
        let mock = TeamsFixture.mock()
        let model = TeamsModel(client: mock)
        await model.load()
        let template = try #require(model.templates.first)
        await model.deleteTemplate(template)
        #expect(model.templates.isEmpty)
        #expect(model.actionError == nil)

        let other = TeamsFixture.mock()
        let again = TeamsModel(client: other)
        await again.load()
        let gone = try #require(again.templates.first)
        other.update { $0.teamTemplates = [] }
        await again.deleteTemplate(gone)
        #expect(again.templates.isEmpty)
        #expect(again.actionError == nil)
    }

    @Test("团队详情：负责人排第一；存为模板；删除")
    func detail() async throws {
        let mock = TeamsFixture.mock()
        let model = TeamDetailModel(client: mock, teamID: DemoData.releaseTeamID)
        await model.load()
        #expect(model.team?.name == "发版小组")
        #expect(model.members.map(\.instanceID) == [DemoData.reviewerID, DemoData.writerID])
        #expect(model.members.first?.isLead == true)

        await model.saveAsTemplate()
        let saved = try #require(model.savedTemplate)
        #expect(saved.name == "发版小组")
        #expect(saved.members.count == 2)
        model.clearSavedTemplate()
        #expect(model.savedTemplate == nil)

        await model.delete()
        #expect(model.isDeleted)
        #expect(mock.state.teams.isEmpty)
    }

    @Test("团队详情：找不到的团队")
    func missing() async {
        let model = TeamDetailModel(client: TeamsFixture.mock(), teamID: "nope")
        await model.load()
        #expect(model.isMissing)
        #expect(model.team == nil)
    }

    @Test("新建团队：先选的当负责人；负责人取消选择时换人；问题在点保存后显示")
    func create() async throws {
        let mock = TeamsFixture.mock()
        let model = TeamEditorModel(client: mock)
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.problems == [.nameEmpty, .noMembers])
        #expect(await model.save() == nil)
        #expect(model.showsProblems)

        model.name = "  写作组  "
        model.toggle(DemoData.writerID)
        #expect(model.lead == DemoData.writerID)
        model.toggle(DemoData.reviewerID)
        #expect(model.lead == DemoData.writerID)
        model.toggle(DemoData.writerID)
        #expect(model.lead == DemoData.reviewerID)
        model.setLead(DemoData.writerID)
        #expect(model.selected == [DemoData.reviewerID, DemoData.writerID])
        #expect(model.members.map(\.role) == [.member, .lead])
        #expect(model.members.map(\.position) == [0, 1])
        #expect(model.problems.isEmpty)

        let team = try #require(await model.save())
        #expect(team.name == "写作组")
        #expect(team.lead?.instanceID == DemoData.writerID)
        #expect(mock.state.teams.count == 2)
    }

    @Test("名字太长、成员太多")
    func limits() async {
        let model = TeamEditorModel(client: TeamsFixture.mock())
        await model.load()
        model.name = String(repeating: "名", count: TeamEditorModel.maxName + 1)
        #expect(model.problems.contains(.nameTooLong))
        model.name = String(repeating: "名", count: TeamEditorModel.maxName)
        #expect(!model.problems.contains(.nameTooLong))
        for i in 0...TeamEditorModel.maxMembers { model.setLead(InstanceID(rawValue: "i\(i)")) }
        #expect(model.problems.contains(.tooManyMembers))
    }

    @Test("编辑团队：带出名字、成员和负责人；改名保存")
    func edit() async throws {
        let mock = TeamsFixture.mock()
        let model = TeamEditorModel(client: mock, teamID: DemoData.releaseTeamID)
        await model.load()
        #expect(model.name == "发版小组")
        #expect(model.selected == [DemoData.reviewerID, DemoData.writerID])
        #expect(model.lead == DemoData.reviewerID)
        model.name = "发布小组"
        let team = try #require(await model.save())
        #expect(team.name == "发布小组")
        #expect(mock.state.teams.first?.name == "发布小组")
    }

    @Test("编辑团队：拉不到时还没加载好，重试能恢复")
    func loadFailure() async {
        let mock = TeamsFixture.mock()
        let model = TeamEditorModel(client: mock, teamID: DemoData.releaseTeamID)
        mock.failNext(with: .network(message: "offline"))
        await model.load()
        #expect(!model.hasLoaded)
        #expect(model.error != nil)
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.name == "发版小组")
    }
}
