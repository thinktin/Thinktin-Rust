import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 模型 key、模型路由、用量（WBS 12.4）的界面：每个页面在浅色中文、深色英文、大字号下都能布局，空状态、没有 key、
/// 等 key、自定义地址的 key 这些情况，以及小组件能出图。视图模型的逻辑在 ThinktinKitTests 的 Models 里测。
@MainActor
@Suite("模型 key、路由与用量的界面")
struct ModelsScreensTests {
    static let routes: [AppRoute] = [
        .credentials, .addCredential, .credential(DemoData.claudeCredentialID), .credential(DemoData.qwenCredentialID),
        .credential("gone"), .modelRoutes(DemoData.writerID), .modelRoutes(DemoData.reviewerID), .modelRoutes("gone"),
        .usage,
    ]

    @Test("每个页面都能布局（中文浅色、英文深色）")
    func everyRoute() {
        for route in Self.routes {
            hostAndLayout(ModelsDestination(route: route).previewShell())
            hostAndLayout(ModelsDestination(route: route).previewShell(.english, scheme: .dark))
        }
    }

    @Test("大字号（AX3）也能布局")
    func accessibilitySizes() {
        for route in Self.routes {
            hostAndLayout(ModelsDestination(route: route).previewShell().dynamicTypeSize(.accessibility3))
        }
    }

    @Test("没有 key、等 key、没有用量、自定义地址的 key")
    func states() {
        hostAndLayout(CredentialsScreen().previewShell(client: ModelsPreviewClients.noKeys()))
        hostAndLayout(
            ModelRoutesScreen(instanceID: DemoData.writerID).previewShell(client: ModelsPreviewClients.noKeys()))
        hostAndLayout(
            ModelRoutesScreen(instanceID: DemoData.writerID)
                .previewShell(.english, scheme: .dark, client: ModelsPreviewClients.waitingForKey()))
        hostAndLayout(UsageScreen().previewShell(client: ModelsPreviewClients.noUsage()))
        hostAndLayout(
            ModelRoutesScreen(instanceID: DemoData.writerID).previewShell(client: ModelsPreviewClients.customKey()))
        hostAndLayout(
            CredentialDetailScreen(credentialID: DemoData.deepseekCredentialID)
                .previewShell(.english, scheme: .dark, client: ModelsPreviewClients.customKey()))
    }

    @Test("改备注、换 key、改每日上限的表单")
    func sheets() {
        let mock = MockClient(autoReply: false)
        let model = CredentialDetailModel(
            client: mock, credentialID: DemoData.claudeCredentialID, credential: mock.state.credentials[0])
        hostAndLayout(CredentialRenameSheet(model: model) {}.previewShell())
        hostAndLayout(ReplaceCredentialSheet(model: model) {}.previewShell(.english, scheme: .dark))
        hostAndLayout(ReplaceCredentialSheet(model: model) {}.previewShell().dynamicTypeSize(.accessibility3))
        hostAndLayout(CredentialDailyLimitSheet(model: model) {}.previewShell())
        hostAndLayout(CredentialDailyLimitSheet(model: model) {}.previewShell(.english, scheme: .dark))
        // 输入框里的问题：不是正整数的才算，留空是不限。
        #expect(CredentialDailyLimitSheet.problem("0") == .notPositiveInteger)
        #expect(CredentialDailyLimitSheet.problem("") == nil)
        #expect(CredentialDailyLimitSheet.problem("2,000,000") == nil)
    }

    @Test("key 的一行、表格的一行、总计卡片、图能出图")
    func render() {
        for credential in DemoData.state().credentials {
            renderInBothAppearances(
                ModelsCredentialRow(summary: CredentialSummary(credential: credential, vendors: DemoData.vendors)))
        }
        let bucket = UsageBucket(
            key: "2026-10-20", requests: 40, inputTokens: 30_000, outputTokens: 4_000, estimatedRequests: 2,
            failedRequests: 3)
        renderInBothAppearances(
            UsageRowView(row: UsageRow(key: bucket.key, title: "10月20日", subtitle: "周二", bucket: bucket)))
        renderInBothAppearances(UsageTotalCard(total: bucket, period: .month))
        renderInBothAppearances(UsageChart(points: UsageChartPreview.points, timeZone: .current))
        renderInBothAppearances(
            ModelsField(
                title: "API key", text: .constant("sk-…"), kind: .secret, problem: "太短了，至少 8 个字符。"))
        // 上游模型名：原样提交，不自动大写、不纠错。
        renderInBothAppearances(
            ModelsField(title: "上游模型", text: .constant("claude-sonnet-5-5"), kind: .identifier, hint: "可以选推荐的，也可以手填。"))
    }

    @Test("横轴的日期文字按看板的时区")
    func axisText() throws {
        let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let calendar = UsageChartFormat.calendar(shanghai)
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 1)))
        #expect(UsageChartFormat.axisText(date, calendar: calendar) == "10/22")
        #expect(UsageChartFormat.spokenDate(date, calendar: calendar, language: .english).hasPrefix("Oct 22"))
    }
}
