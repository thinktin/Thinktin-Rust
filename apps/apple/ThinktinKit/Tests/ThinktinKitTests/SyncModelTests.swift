import Foundation
import Testing

@testable import ThinktinKit

// 合 backend-core f9f87b3 带进来的模型（W1 第 1.5 轮）：审批事件的新键（11.8）、实时活动的内容（10.6、10.7）。

@Suite("审批事件的新键（docs/agent-integration.md 第 6 节）")
struct ApprovalEventKeyTests {
    private func payload(_ kind: InstanceEventKind, _ json: String) -> EventPayload {
        EventPayload(kind: kind, json: json)
    }

    @Test("permission_requested：attempt、approval_id；类型不对的当作没有，不丢整张卡片")
    func requested() throws {
        guard
            case .permissionRequested(let p) = payload(
                .permissionRequested,
                #"{"request_id":"perm-1","title":"删除","options":[],"attempt":2,"approval_id":"ap-1"}"#)
        else {
            Issue.record("没解析出来")
            return
        }
        #expect(p.attempt == 2)
        #expect(p.approvalID == "ap-1")

        guard
            case .permissionRequested(let bad) = payload(
                .permissionRequested, #"{"request_id":"perm-1","attempt":"two","approval_id":7}"#)
        else {
            Issue.record("类型不对的键不该让整条载荷解析失败")
            return
        }
        #expect(bad.attempt == nil)
        #expect(bad.approvalID == nil)
        #expect(bad.requestID == "perm-1")

        // 编码再解码不变（Mock、测试里拼事件用）。
        let original = PermissionRequestedPayload(
            requestID: "perm-3", title: "t", options: DemoData.approvalOptions, attempt: 3, approvalID: "ap-3")
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(PermissionRequestedPayload.self, from: data) == original)
    }

    @Test("permission_resolved：attempt、approval_id、approval_state；老的事件都没有")
    func resolved() {
        guard
            case .permissionResolved(let p) = payload(
                .permissionResolved,
                #"{"request_id":"perm-1","by":"user","attempt":1,"approval_id":"ap-1","approval_state":"expired"}"#)
        else {
            Issue.record("没解析出来")
            return
        }
        #expect(p.by == .user)
        #expect(p.optionID == nil)
        #expect(p.attempt == 1)
        #expect(p.approvalID == "ap-1")
        #expect(p.approvalState == .expired)

        guard case .permissionResolved(let old) = payload(.permissionResolved, #"{"request_id":"r","by":"policy"}"#)
        else {
            Issue.record("没解析出来")
            return
        }
        #expect(old.attempt == nil && old.approvalID == nil && old.approvalState == nil)
        guard
            case .permissionResolved(let future) = payload(
                .permissionResolved, #"{"request_id":"r","by":"user","approval_state":"escalated"}"#)
        else {
            Issue.record("没解析出来")
            return
        }
        #expect(future.approvalState == .unknown("escalated"))
    }

    @Test("approval.decided：request_id、attempt；老的事件没有")
    func decided() {
        guard
            case .approvalDecided(let p) = payload(
                .approvalDecided,
                #"{"approval_id":"ap-1","state":"approved","option_id":"ok","request_id":"perm-1","attempt":2}"#)
        else {
            Issue.record("没解析出来")
            return
        }
        #expect(p.requestID == "perm-1")
        #expect(p.attempt == 2)
        guard
            case .approvalDecided(let old) = payload(
                .approvalDecided, #"{"approval_id":"ap-1","state":"rejected","option_id":null}"#)
        else {
            Issue.record("没解析出来")
            return
        }
        #expect(old.requestID == nil && old.attempt == nil)
        #expect(old.state == .rejected)
    }

    @Test("Approval：选中的选项")
    func approvalDecidedOption() {
        var approval = Approval(
            id: "ap-1", runID: "r", instanceID: "i", title: nil, options: DemoData.approvalOptions,
            expiresAt: Date(), createdAt: Date(), requestID: "perm-1", attempt: 1)
        #expect(approval.decidedOptionInfo == nil)
        approval.decidedOption = DemoData.approvalOptions[0].id
        #expect(approval.decidedOptionInfo == DemoData.approvalOptions[0])
        approval.decidedOption = "gone"
        #expect(approval.decidedOptionInfo == nil)
    }
}

@Suite("实时活动的内容（docs/live-activities.md 第 3 节）")
struct RunActivityContentStateTests {
    @Test("编码：驼峰键名、Unix 秒的整数，没有的键不写")
    func encode() throws {
        let state = RunActivityContentState(
            state: "waiting_quota", steps: 7, startedAt: 1_700_000_000, waitCode: "no_balance")
        let data = try JSONEncoder().encode(state)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["state", "steps", "startedAt", "waitCode"])
        #expect(object["startedAt"] as? Int == 1_700_000_000)
        #expect(object["waitCode"] as? String == "no_balance")
        #expect(try JSONDecoder().decode(RunActivityContentState.self, from: data) == state)
    }

    @Test("解码后台推的内容（ActivityKit 用默认的 JSONDecoder）；老的推送没有 waitCode")
    func decodeFromBackend() throws {
        let json = #"{"state":"succeeded","steps":12,"startedAt":1700000000,"endedAt":1700000360}"#
        let state = try JSONDecoder().decode(RunActivityContentState.self, from: Data(json.utf8))
        #expect(state.runState == .succeeded)
        #expect(state.steps == 12)
        #expect(state.startDate == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(state.endDate == Date(timeIntervalSince1970: 1_700_000_360))
        #expect(state.waitCode == nil && state.runWaitCode == nil)

        let waiting = try JSONDecoder().decode(
            RunActivityContentState.self,
            from: Data(#"{"state":"waiting_device","steps":3,"startedAt":1700000000,"waitCode":"device_offline"}"#.utf8)
        )
        #expect(waiting.runState == .waitingDevice)
        #expect(waiting.runWaitCode == .deviceOffline)
        #expect(waiting.endDate == nil)
        // 以后的取值：不认识的状态、原因码照样解得开。
        let future = try JSONDecoder().decode(
            RunActivityContentState.self, from: Data(#"{"state":"hibernating","steps":0,"waitCode":"solar"}"#.utf8))
        #expect(future.runState == .unknown("hibernating"))
        #expect(future.runWaitCode == .unknown("solar"))
        #expect(future.startedAt == nil)
    }

    @Test("从运行记录拼第一帧：秒向下取整，等待原因码只在等 key、等电脑时带")
    func fromRun() throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000.9)
        let waiting = Run(
            id: "r", instanceID: "i", prompt: "p", state: .waitingQuota, createdAt: started, startedAt: started,
            waitCode: .rateLimited)
        let state = RunActivityContentState(run: waiting, steps: 4)
        #expect(state.state == "waiting_quota")
        #expect(state.steps == 4)
        #expect(state.startedAt == 1_700_000_000)
        #expect(state.endedAt == nil)
        #expect(state.waitCode == "rate_limited")

        var done = waiting
        done.state = .succeeded
        done.finishedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let finished = RunActivityContentState(run: done)
        #expect(finished.waitCode == nil, "不在等的不带原因码")
        #expect(finished.endedAt == 1_700_000_100)
        #expect(finished.steps == 0)
        let roundTrip = try JSONDecoder().decode(
            RunActivityContentState.self, from: try JSONEncoder().encode(finished))
        #expect(roundTrip == finished)
    }
}
