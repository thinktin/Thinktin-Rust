import Foundation
import Testing

@testable import ThinktinKit

// 深链 thinktin://…（docs/ios.md 第 6.1 节，和安卓同一套）。

@Suite("深链")
struct DeepLinkTests {
    private func route(_ string: String) -> AppRoute? {
        DeepLink.route(from: string)
    }

    @Test("文档里的七种格式")
    func documentedFormats() {
        let id = "0192f3a0-0000-7000-8000-000000000201"
        #expect(route("thinktin://run/\(id)") == .run(RunID(id)))
        #expect(route("thinktin://approval/appr-9") == .approval("appr-9"))
        #expect(route("thinktin://plan/plan_1") == .plan("plan_1"))
        #expect(route("thinktin://inbox") == .inbox)
        #expect(route("thinktin://inbox/item-3") == .inboxItem("item-3"))
        #expect(route("thinktin://vault/request/req-7") == .vaultRequest("req-7"))
        // 和安卓一致：实例深链打开实例详情。
        #expect(route("thinktin://instance/inst-1") == .instance("inst-1"))
    }

    @Test("宽松的地方：大小写、结尾斜杠、查询参数、没有 host 的写法")
    func lenientForms() {
        #expect(route("THINKTIN://RUN/AbC") == .run("AbC"))  // 种类不分大小写，id 原样保留
        #expect(route("thinktin://run/abc/") == .run("abc"))
        #expect(route("thinktin://run/abc?from=widget#top") == .run("abc"))
        #expect(route("thinktin:run/abc") == .run("abc"))
        #expect(route("thinktin:///run/abc") == .run("abc"))
        #expect(route("thinktin://inbox/") == .inbox)
        #expect(route("thinktin://Vault/Request/r1") == .vaultRequest("r1"))
        #expect(route("  thinktin://plan/p1\n") == .plan("p1"))
    }

    @Test("认不出的一律不认")
    func rejects() {
        for bad in [
            "https://thinktin.cn/run/abc",  // 不是我们的 scheme
            "thinktin://",  // 什么都没有
            "thinktin://run",  // 少了 id
            "thinktin://run/a/b",  // 多了一段
            "thinktin://teams",  // 不是深链能到的页面
            "thinktin://vault/abc",  // 少了 request
            "thinktin://vault/request",  // 少了 id
            "thinktin://vault/item/abc",
            "thinktin://run/a%20b",  // id 里有空格
            "thinktin://run/%E4%BD%A0",  // 非 ASCII
            "thinktin://run/" + String(repeating: "a", count: 129),  // 太长
            "thinktin://inbox/a/b",
        ] {
            #expect(route(bad) == nil, "\(bad)")
        }
        #expect(route("thinktin://run/" + String(repeating: "a", count: 128)) != nil)
    }

    @Test("id 的格式")
    func idFormat() {
        #expect(DeepLink.isValidID("0192f3a0-0000-7000-8000-000000000201"))
        #expect(DeepLink.isValidID("claude"))
        #expect(DeepLink.isValidID("A_b-9"))
        #expect(!DeepLink.isValidID(""))
        #expect(!DeepLink.isValidID("a/b"))
        #expect(!DeepLink.isValidID("a.b"))
        #expect(!DeepLink.isValidID("a b"))
        #expect(!DeepLink.isValidID("../x"))
    }

    @Test("页面 → 深链，再解析回来")
    func roundTrip() throws {
        let linkable: [AppRoute] = [
            .run("r1"), .approval("a1"), .plan("p1"), .instance("i1"), .inbox, .inboxItem("x1"), .vaultRequest("v1"),
        ]
        for route in linkable {
            let url = try #require(DeepLink.url(for: route), "\(route)")
            #expect(url.scheme == DeepLink.scheme)
            #expect(DeepLink.route(from: url) == route)
        }
        #expect(DeepLink.url(for: .run("r1"))?.absoluteString == "thinktin://run/r1")
        #expect(DeepLink.url(for: .vaultRequest("v1"))?.absoluteString == "thinktin://vault/request/v1")
        // 其他页面没有深链；id 不合格式的也不给。
        for route in RouteSamples.all
        where !linkable.map(RouteSamples.index(of:)).contains(RouteSamples.index(of: route)) {
            #expect(DeepLink.url(for: route) == nil, "\(route)")
        }
        #expect(DeepLink.url(for: .run("a b")) == nil)
    }
}
