import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 计划管理（WBS 12.6）的界面：每个页面在浅色中文、深色英文、大字号下都能布局；列表的几种状态（有计划、没有、
/// 规则失效、等确认）、编辑页、触发器编辑器的每种写法、时区、预授权工具、确认页（新建、改了用户的计划、不用确认）。
/// 视图模型的逻辑在 ThinktinKitTests 的 Plans 里测。
@MainActor
@Suite("计划管理的界面")
struct PlansScreensTests {
    static let routes: [AppRoute] = [
        .plans, .plan(DemoData.digestPlanID), .plan(PlansPreviewClients.pipelinePlanID),
        .plan(PlansPreviewClients.invalidPlanID), .plan(DemoData.agentPlanID), .plan("gone"),
        .newPlan(instanceID: DemoData.writerID), .newPlan(instanceID: nil), .editPlan(DemoData.digestPlanID),
        .confirmPlan(DemoData.agentPlanID), .confirmPlan(DemoData.digestPlanID), .confirmPlan("gone"),
    ]

    @Test("每个页面都能布局（中文浅色、英文深色）")
    func everyRoute() {
        for route in Self.routes {
            hostAndLayout(PlansDestination(route: route).previewShell(client: PlansPreviewClients.withPlans()))
            hostAndLayout(
                PlansDestination(route: route).previewShell(
                    .english, scheme: .dark, client: PlansPreviewClients.withPlans()))
        }
    }

    @Test("大字号（AX3）也能布局")
    func accessibilitySizes() {
        for route in Self.routes {
            hostAndLayout(
                PlansDestination(route: route).previewShell(client: PlansPreviewClients.withPlans())
                    .dynamicTypeSize(.accessibility3))
        }
    }

    @Test("没有计划；agent 改了用户的计划")
    func states() {
        hostAndLayout(PlanListScreen().previewShell(client: PlansPreviewClients.empty()))
        hostAndLayout(
            PlanConfirmScreen(planID: DemoData.digestPlanID).previewShell(
                client: PlansPreviewClients.agentEditedUserPlan()))
        hostAndLayout(
            PlanConfirmScreen(planID: DemoData.digestPlanID).previewShell(
                .english, scheme: .dark, client: PlansPreviewClients.agentEditedUserPlan()))
    }

    @Test("触发器编辑器：每种写法、太频繁、算不了的")
    func triggerEditor() {
        let schedules: [Schedule] = [
            .cron(expression: "0 9 * * *", timeZone: "Asia/Shanghai"),
            .cron(expression: "30 9 * * 1-5", timeZone: "Asia/Shanghai"),
            .cron(expression: "0 8 1,15 * *", timeZone: "Asia/Tokyo"),
            .once(Date().addingTimeInterval(86400)),
            .cron(expression: "* * * * *", timeZone: "Asia/Shanghai"),
            .cron(expression: "0 9 L * *", timeZone: "Asia/Shanghai"),
            .rrule("DTSTART;TZID=Asia/Tokyo:20261101T183000\nRRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=FR"),
            .rrule("DTSTART:20261101T010000Z\nRRULE:FREQ=DAILY\nEXDATE:20261102T010000Z"),
        ]
        for schedule in schedules {
            let view = TriggerEditorView(draft: TriggerDraft(schedule: schedule), title: "规则") { _ in }
            hostAndLayout(view.previewShell())
            hostAndLayout(view.previewShell(.english, scheme: .dark).dynamicTypeSize(.accessibility3))
        }
    }

    @Test("时区、预授权的工具")
    func pickers() {
        hostAndLayout(TimeZonePickerView(selection: .constant("Asia/Shanghai")).previewShell())
        hostAndLayout(TimeZonePickerView(selection: .constant("UTC")).previewShell(.english, scheme: .dark))
        let draft = PlanPolicyDraft(PlanPolicy(preauthorizedTools: ["read", "execute", "custom_kind"]))
        hostAndLayout(PlanToolsPicker(policy: .constant(draft)).previewShell())
        hostAndLayout(PlanToolsPicker(policy: .constant(draft)).previewShell(.english, scheme: .dark))
    }

    @Test("小组件能出图")
    func render() {
        let state = PlansPreviewClients.withPlans().state
        let plans = state.plans
        for plan in plans {
            renderInBothAppearances(PlanStatusLabel(status: plan.status))
            renderInBothAppearances(PlanTitleText(plan: plan))
            for trigger in plan.triggers {
                renderInBothAppearances(
                    PlanTriggerRow(trigger: trigger, plan: plan, canEdit: true, onFix: {}, onDelete: {}))
            }
        }
        renderInBothAppearances(PlansCountBadge(count: 3))
        renderInBothAppearances(PlansCountBadge(count: 120))
        renderInBothAppearances(PlansFilterChip(title: "写作助手", count: 2, isSelected: true) {})
        renderInBothAppearances(PlansFilterChip(title: "Cron", count: nil, isSelected: false) {})
        renderInBothAppearances(PlanChangedTag())
        renderInBothAppearances(PlansDayToggle(text: "一", accessibilityName: "周一", isOn: true) {})
        for run in state.runs where run.planID != nil {
            renderInBothAppearances(PlanRunRow(run: run) {})
        }
        renderInBothAppearances(
            PlansTextField(
                title: "标题", text: .constant("每周周报"), limit: Plan.maxTitleLength, count: 4, problem: nil,
                hint: "最多 100 个字"))
        renderInBothAppearances(
            PlansTextField(title: "cron", text: .constant("0 9 * * *"), problem: "格式不对", monospaced: true))
    }

    @Test("计划的状态色：待确认是等待色，规则失效是失败色，暂停是静音色")
    func statusTones() {
        #expect(PlanStatus.awaitingConfirmation.tone == .waiting)
        #expect(PlanStatus.invalidRule.tone == .failure)
        #expect(PlanStatus.paused.tone == .muted)
        #expect(PlanStatus.scheduled(next: Date()).tone == .active)
        #expect(PlanStatus.idle.tone == .neutral)
    }

    @Test("时区的显示名")
    func timeZoneNames() {
        #expect(plansTimeZoneName("UTC", language: .chinese) == "UTC")
        #expect(plansTimeZoneName("Nowhere/City", language: .english) == "Nowhere/City")
        #expect(plansTimeZoneName("Asia/Shanghai", language: .english).contains("Asia/Shanghai"))
    }
}
