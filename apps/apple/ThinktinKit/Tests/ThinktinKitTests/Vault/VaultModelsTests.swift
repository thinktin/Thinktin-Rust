import Foundation
import Testing

@testable import ThinktinKit

/// 保险箱测试用的 Mock：演示数据（github 所有实例能用；aliyun-oss 只给代码审查；npm 的填写请求在等）。
enum VaultFixture {
    static func mock(_ edit: (inout MockState) -> Void = { _ in }) -> MockClient {
        var state = DemoData.state()
        edit(&state)
        return MockClient(state: state, stepDelay: 0, autoReply: false)
    }

    static func request(
        _ id: VaultRequestID, name: String, status: VaultRequestStatus = .pending, expiresIn: TimeInterval = 3600,
        fields: [VaultField] = [.username, .password]
    ) -> VaultRequest {
        VaultRequest(
            id: id, instanceID: DemoData.writerID, name: name, purpose: "登录 \(name)", fields: fields, status: status,
            createdAt: Date().addingTimeInterval(-60), expiresAt: Date().addingTimeInterval(expiresIn))
    }
}

@MainActor
@Suite("保险箱")
struct VaultModelsTests {
    @Test("规则：密码 4 个字符起、4096 字节以内、不能有控制字符")
    func rules() {
        #expect(VaultRules.passwordProblem("abc") == .tooShort)
        #expect(VaultRules.passwordProblem("密码四位") == nil)
        #expect(VaultRules.passwordProblem(String(repeating: "a", count: 4097)) == .tooLong)
        #expect(VaultRules.passwordProblem("ab\tcd") == .controlCharacters)
        #expect(VaultRules.hasControlCharacters("a\nb"))
        #expect(!VaultRules.hasControlCharacters("正常 文字"))
    }

    @Test("列表：条目按名字排，请求分成等你填写的和处理过的（过了期限的算过期）")
    func list() async {
        let mock = VaultFixture.mock { state in
            state.vaultRequests += [
                VaultFixture.request("vr-old", name: "gitlab", expiresIn: -60),
                VaultFixture.request("vr-done", name: "pypi", status: .declined),
            ]
        }
        let model = VaultModel(client: mock)
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.items.map(\.name) == ["aliyun-oss", "github"])
        #expect(model.pendingRequests.map(\.id) == [DemoData.npmVaultRequestID])
        #expect(Set(model.pastRequests.map(\.id)) == ["vr-old", "vr-done"])
        let old = model.requests.first { $0.id == "vr-old" }!
        #expect(model.status(of: old) == .expired)
        #expect(!model.isFull)
        let oss = model.items.first { $0.name == "aliyun-oss" }!
        #expect(VaultText.instances(oss, names: model.instanceNames, language: .chinese) == "只给：代码审查")
        #expect(
            VaultText.instances(model.items.first { $0.name == "github" }!, names: [:], language: .english)
                == "All instances")
    }

    @Test("满 200 条：列表提示、新建时拦下")
    func full() async {
        let mock = VaultFixture.mock { state in
            state.vaultItems = (0..<VaultRules.maxItems).map { i in
                VaultItem(id: VaultItemID(rawValue: "v\(i)"), name: "item\(i)", purpose: "", createdAt: Date())
            }
        }
        let model = VaultModel(client: mock)
        await model.load()
        #expect(model.isFull)
        let editor = VaultItemEditorModel(client: mock)
        await editor.load()
        editor.setName("new")
        editor.password = "abcd"
        #expect(await editor.save() == nil)
        #expect(editor.visibleProblems.contains(.full))
    }

    @Test("删除：从列表去掉；已经被删了（404）也去掉")
    func delete() async throws {
        let mock = VaultFixture.mock()
        let model = VaultModel(client: mock)
        await model.load()
        let github = try #require(model.items.first { $0.name == "github" })
        await model.delete(github)
        #expect(model.items.map(\.name) == ["aliyun-oss"])
        let oss = try #require(model.items.first)
        mock.update { $0.vaultItems = [] }
        await model.delete(oss)
        #expect(model.items.isEmpty)
        #expect(model.actionError == nil)
    }

    @Test("条目详情：账号、引用；删除")
    func detail() async throws {
        let mock = VaultFixture.mock()
        let model = VaultItemModel(client: mock, itemID: DemoData.githubVaultID)
        await model.load()
        let detail = try #require(model.detail)
        #expect(detail.username == "zhangsan")
        #expect(detail.item.reference == "[vault:github]")
        await model.delete()
        #expect(model.isDeleted)
        #expect(!mock.state.vaultItems.contains { $0.id == DemoData.githubVaultID })

        let missing = VaultItemModel(client: mock, itemID: "nope")
        await missing.load()
        #expect(missing.isMissing)
    }

    @Test("新建：名字只收规则内的字符；问题点保存后才显示；限定实例")
    func create() async throws {
        let mock = VaultFixture.mock()
        let editor = VaultItemEditorModel(client: mock)
        await editor.load()
        #expect(editor.hasLoaded)
        editor.setName("My Token!")
        #expect(editor.name == "my-token")
        #expect(editor.visibleProblems.isEmpty)
        #expect(await editor.save() == nil)
        #expect(editor.visibleProblems == [.password(.tooShort)])

        editor.password = "tok_123456"
        editor.purpose = "  发布包  "
        editor.allInstances = false
        #expect(editor.problems == [.noInstances])
        editor.toggle(DemoData.reviewerID)
        let item = try #require(await editor.save())
        #expect(item.name == "my-token")
        #expect(item.purpose == "发布包")
        #expect(item.instanceIDs == [DemoData.reviewerID])
        #expect(editor.password.isEmpty)
    }

    @Test("新建重名：换一个不重复的名字，提示一句，再点保存才存")
    func rename() async throws {
        let mock = VaultFixture.mock()
        let editor = VaultItemEditorModel(client: mock)
        await editor.load()
        editor.setName("github")
        editor.password = "ghp_abcdef"
        #expect(await editor.save() == nil)
        #expect(editor.name == "github_2")
        #expect(editor.renamedTo == "github_2")
        let item = try #require(await editor.save())
        #expect(item.name == "github_2")

        // 别处刚建了同名的（服务端 409）：同样换名字。
        let other = VaultItemEditorModel(client: mock)
        await other.load()
        other.setName("fresh")
        other.password = "abcd1234"
        _ = try await mock.createVaultItem(NewVaultItem(name: "fresh", purpose: "", password: "abcd1234"))
        #expect(await other.save() == nil)
        #expect(other.name == "fresh_2")
        #expect(other.saveError == nil)
    }

    @Test("修改：带出原来的值；只发改了的字段；密码不填不改")
    func edit() async throws {
        let mock = VaultFixture.mock()
        let editor = VaultItemEditorModel(client: mock, itemID: DemoData.ossVaultID)
        await editor.load()
        #expect(editor.isEditing)
        #expect(editor.name == "aliyun-oss")
        #expect(editor.username == "LTAI5t-demo")
        #expect(!editor.allInstances)
        #expect(editor.selected == [DemoData.reviewerID])
        #expect(!editor.hasChanges)
        #expect(editor.problems.isEmpty, "修改时密码可以不填")

        editor.allInstances = true
        #expect(editor.hasChanges)
        let saved = try #require(await editor.save())
        #expect(saved.isAvailableToAllInstances)
        #expect(try await mock.vaultItem(DemoData.ossVaultID).username == "LTAI5t-demo")

        editor.password = "ab"
        #expect(await editor.save() == nil)
        #expect(editor.visibleProblems == [.password(.tooShort)])
    }

    @Test("填写请求：填好存进保险箱，页面显示结果；已有同名条目先提示")
    func fulfill() async throws {
        let mock = VaultFixture.mock { state in
            state.vaultRequests.append(VaultFixture.request("vr-gh", name: "github"))
        }
        let npm = VaultRequestModel(client: mock, requestID: DemoData.npmVaultRequestID)
        await npm.load()
        #expect(npm.canFill)
        #expect(npm.existingItem == nil)
        #expect(npm.request?.needsUsername == false)
        npm.password = "abc"
        #expect(await npm.fulfill() == false)
        #expect(npm.visibleProblems == [.password(.tooShort)])
        npm.password = "npm_token_123"
        #expect(await npm.fulfill())
        #expect(npm.status == .fulfilled)
        #expect(npm.password.isEmpty)
        #expect(mock.state.vaultItems.contains { $0.name == "npm" })

        let gh = VaultRequestModel(client: mock, requestID: "vr-gh")
        await gh.load()
        #expect(gh.existingItem?.id == DemoData.githubVaultID)
        #expect(
            VaultText.requestReplaces("github", language: .chinese) == "保险箱里已经有“github”了：填好后会换掉它的账号密码。")
    }

    @Test("拒绝；别处已经处理过（冲突）时显示最新结果、不算出错；过期的不能填")
    func declineAndConflicts() async throws {
        let mock = VaultFixture.mock { state in
            state.vaultRequests += [
                VaultFixture.request("vr-a", name: "a1"), VaultFixture.request("vr-b", name: "b1"),
                VaultFixture.request("vr-old", name: "c1", expiresIn: -1),
            ]
        }
        let a = VaultRequestModel(client: mock, requestID: "vr-a")
        await a.load()
        #expect(await a.decline())
        #expect(a.status == .declined)
        #expect(!a.canFill)

        let b = VaultRequestModel(client: mock, requestID: "vr-b")
        await b.load()
        _ = try await mock.declineVaultRequest("vr-b")
        b.password = "abcd1234"
        #expect(await b.fulfill() == false)
        #expect(b.actionError == nil)
        #expect(b.status == .declined)

        let old = VaultRequestModel(client: mock, requestID: "vr-old")
        await old.load()
        #expect(old.status == .expired)
        old.password = "abcd1234"
        #expect(await old.fulfill() == false)

        let missing = VaultRequestModel(client: mock, requestID: "nope")
        await missing.load()
        #expect(missing.isMissing)
    }
}
