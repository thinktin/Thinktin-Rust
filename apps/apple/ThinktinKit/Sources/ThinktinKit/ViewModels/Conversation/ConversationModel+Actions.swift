import Foundation

/// 输入框的主按钮。
public enum ComposerAction: Hashable, Sendable {
    /// 发送（有字、没超长）。
    case send
    /// 停止正在跑的运行（输入框是空的、有运行没结束）。
    case stop
    /// 正在发送。
    case sending
    /// 正在停止。
    case stopping
}

// MARK: - 输入框

extension ConversationModel {
    /// 去掉首尾空白后的字数（按服务端的算法：Unicode 标量数）。
    public var promptLength: Int {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
    }

    /// 超过 32000 字。
    public var isOverLimit: Bool { promptLength > Self.maxPromptLength }

    /// 快到上限了：显示字数。
    public var showsLengthCounter: Bool {
        promptLength > Self.maxPromptLength - Self.lengthCounterThreshold
    }

    /// 现在能发：有字、没超长、不在发送中、不是“只看本次过程”、实例还在。
    public var canSend: Bool {
        focusRunID == nil && !isMissing && promptLength > 0 && !isOverLimit && !isSending
    }

    /// 正在跑的运行（停止按钮停的就是它）：没结束的运行里最早的、已经开始的；都在排队时是最早排队的。
    public var activeRunID: RunID? {
        let active = turns.filter { $0.runID != nil && ($0.state?.isActive ?? false) }
        let running = active.first { $0.state != .queued }
        return (running ?? active.first)?.runID
    }

    /// 同一个实例同时只跑一个运行：现在发的消息会排队（输入框上方提示“排队中”）。
    public var willQueue: Bool { activeRunID != nil }

    /// 输入框的主按钮：输入框是空的、有运行没结束时是停止，其余是发送。
    public var composerAction: ComposerAction {
        if isSending { return .sending }
        if isStopping { return .stopping }
        if activeRunID != nil && promptLength == 0 { return .stop }
        return .send
    }

    /// 发送：先在本机检查有没有像密码的内容（`detectSecrets`），有就拦下、弹保险箱表单；没有就发。
    public func send() async {
        let text = draft
        guard canSend else { return }
        sendError = nil
        interceptionResends = false
        let found = client.detectSecrets(in: text)
        if !found.isEmpty {
            await intercept(message: text, secrets: found, serverCount: nil)
            return
        }
        await submit(text, allowSecrets: false)
    }

    /// 用户坚持要发（拦截弹层上的“仍然发送”）：带 `allowSecrets` 发出去。
    public func sendAnyway() async {
        guard let interception else { return }
        await submit(interception.message, allowSecrets: true)
    }

    /// 关掉拦截弹层（回去改消息）。
    public func dismissInterception() {
        interception = nil
        interceptionResends = false
    }

    /// 关掉发送失败的提示。
    public func clearSendError() {
        sendError = nil
    }

    /// 改拦截弹层里的一处（名字、用途、账号、只给这个实例用）。
    public func editInterception(_ id: SecretInterception.Entry.ID, _ change: (inout SecretInterception.Entry) -> Void)
    {
        interception?.edit(id, change)
    }

    /// 把拦下的一处存进保险箱（`saveSecretFromMessage`）：成功后消息里的值换成 `[vault:名字]` 放回输入框；
    /// 剩下的按新消息重新认，都处理完了弹层自动关掉（之后用户自己点发送）。重名时提示换个名字（预填一个不重复的）。
    /// 拦下的是“再发一次”的任务时不动输入框，都处理完了直接把换成引用的任务发出去。
    @discardableResult
    public func saveSecret(_ id: SecretInterception.Entry.ID) async -> Bool {
        guard let current = interception, let entry = current.entry(id), entry.canSave else { return false }
        interception?.edit(id) {
            $0.isSaving = true
            $0.error = nil
        }
        do {
            let saved = try await client.saveSecretFromMessage(
                message: current.message, value: entry.secret.value, item: entry.newItem(instanceID: instanceID))
            if !interceptionResends { draft = saved.message }
            guard var next = interception else { return true }
            let detector = client.secretDetector
            next.didSave(
                id, savedName: saved.item.name, message: saved.message,
                secrets: detector.detectSecrets(in: saved.message), takenNames: [],
                uniqueName: { detector.uniqueVaultName(base: $0, taken: $1) })
            interception = next.isResolved ? nil : next
            if next.isResolved && interceptionResends {
                interceptionResends = false
                await submit(saved.message, allowSecrets: false)
            }
            return true
        } catch {
            let failure = ConversationErrors.from(error)
            var suggestion: String?
            if failure?.isConflict == true, let names = try? await client.vaultItems().map(\.name) {
                suggestion = client.secretDetector.uniqueVaultName(base: entry.name, taken: names)
            }
            interception?.edit(id) {
                $0.isSaving = false
                $0.error = failure
                if let suggestion { $0.name = suggestion }
            }
            return false
        }
    }

    /// 停止正在跑的运行（`cancelRun`）。`wholeTree` 时连同子运行一起停（流水线、委派）。
    public func stop(wholeTree: Bool = false) async {
        guard let runID = activeRunID, !isStopping else { return }
        await cancel(runID, wholeTree: wholeTree)
    }

    /// 停止某个运行（运行状态行、运行详情）。
    public func cancel(_ runID: RunID, wholeTree: Bool = false) async {
        isStopping = true
        stopError = nil
        defer { isStopping = false }
        do {
            let run = try await client.cancelRun(runID, wholeTree: wholeTree)
            if merge(runs: [run]) {
                reducer.upsert(run: run)
                render()
            }
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            // 已经结束了（冲突）：拉一次最新的状态就行，不算出错。
            if failure.isConflict {
                await fetchRuns([runID])
            } else {
                stopError = failure
            }
        }
    }

    /// 关掉停止失败的提示。
    public func clearStopError() {
        stopError = nil
    }

    /// 能不能“再发一次”（docs/ios-packages.md 12.5 的消息操作“重试”）：用户自己发的、已经结束的运行。计划、流水线、委派的
    /// 任务不是用户写的，不在对话里重发；“只看本次过程”里不能发消息。
    public func canRetry(_ turn: ConversationTurn) -> Bool {
        guard focusRunID == nil, !isMissing, let run = turn.run, run.source == .user else { return false }
        let state = turn.state ?? run.state
        return state.isTerminal && !run.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 再发一次：用同一个任务再起一个运行（`sendMessage`，和发送一样先在本机检查像密码的内容，命中时弹保险箱表单，
    /// 存好以后直接发）。输入框里正在写的字不动。
    public func retry(_ runID: RunID) async {
        guard !isSending, let turn = turn(for: runID), canRetry(turn), let prompt = turn.run?.prompt else { return }
        sendError = nil
        interceptionResends = true
        let found = client.detectSecrets(in: prompt)
        if !found.isEmpty {
            await intercept(message: prompt, secrets: found, serverCount: nil)
            return
        }
        await submit(prompt, allowSecrets: false)
    }

    // MARK: 内部

    private func intercept(message: String, secrets: [DetectedSecret], serverCount: Int?) async {
        let taken = (try? await client.vaultItems().map(\.name)) ?? []
        let detector = client.secretDetector
        interception = SecretInterception(
            message: message, secrets: secrets, takenNames: taken, serverCount: serverCount,
            uniqueName: { detector.uniqueVaultName(base: $0, taken: $1) })
    }

    private func submit(_ text: String, allowSecrets: Bool) async {
        isSending = true
        defer { isSending = false }
        do {
            let run = try await client.sendMessage(instanceID: instanceID, text: text, allowSecrets: allowSecrets)
            // 发送期间用户又改了输入框就不清。
            if draft == text { draft = "" }
            interception = nil
            sendError = nil
            merge(runs: [run])
            reducer.upsert(run: run)
            render()
            lastSentRunID = run.id
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            if case .containsSecrets(let count) = failure {
                // 服务端的规则认出来了、本机没认出来：照样走拦截流程。
                await intercept(message: text, secrets: client.detectSecrets(in: text), serverCount: count)
                return
            }
            if interception != nil {
                interception = nil
            }
            sendError = failure
        }
    }
}

// MARK: - 审批卡片

extension ConversationModel {
    /// 选审批卡片上的一个选项。批准类的先过本机验证（`BiometricGate`，取消了什么都不做，没通过提示一句）；拒绝直接发
    /// `decideApproval`。决定后卡片按返回的审批记录更新；已经在别处处理过的（冲突、不存在）查一次最新记录，不算出错。
    ///
    /// - Parameters:
    ///   - item: 卡片所在的项（`ConversationItem.id` 是错误、进行中状态的键）。
    ///   - reason: 本机验证弹层上的说明（已经按界面语言取好的，`ConversationText.verificationReason`）。
    public func decide(_ item: ConversationItem, option: ApprovalOption, reason: String) async {
        guard case .approval(let card) = item.content, card.isPending, !decidingApprovals.contains(item.id) else {
            return
        }
        guard let approvalID = card.approvalID else {
            approvalErrors[item.id] = .notLinked
            return
        }
        approvalErrors[item.id] = nil
        // 不是明确拒绝的都先验证（认不出的种类也算批准类）。
        if !option.kind.isReject {
            let result = await biometricGate.authorize(reason: reason)
            switch result {
            case .cancelled:
                return
            case .failed:
                approvalErrors[item.id] = .verificationFailed
                return
            case .approved, .unavailable:
                break
            }
        }
        decidingApprovals.insert(item.id)
        defer { decidingApprovals.remove(item.id) }
        do {
            let approval = try await client.decideApproval(approvalID, optionID: option.id)
            apply(approvals: [approval])
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            if failure.isConflict || failure.isNotFound, let latest = try? await client.getApproval(approvalID) {
                apply(approvals: [latest])
                if !latest.isPending { return }
            }
            approvalErrors[item.id] = .client(failure)
        }
    }

    /// 关掉审批卡片上的错误。
    public func clearApprovalError(_ itemID: String) {
        approvalErrors[itemID] = nil
    }
}

// MARK: - 保险箱填写请求

extension ConversationModel {
    /// 填好 agent 要的账号密码（只进保险箱，agent 只拿到名字）。返回成功没有。
    @discardableResult
    public func fulfillVaultRequest(_ requestID: VaultRequestID, username: String, password: String) async -> Bool {
        guard !busyVaultRequests.contains(requestID), !password.isEmpty else { return false }
        busyVaultRequests.insert(requestID)
        vaultErrors[requestID] = nil
        defer { busyVaultRequests.remove(requestID) }
        do {
            let request = try await client.fulfillVaultRequest(
                requestID, username: username.trimmingCharacters(in: .whitespaces), password: password, purpose: nil)
            vaultRecords[requestID] = request
            return true
        } catch {
            await recordVaultFailure(requestID, error)
            return false
        }
    }

    /// 拒绝 agent 的填写请求。
    @discardableResult
    public func declineVaultRequest(_ requestID: VaultRequestID) async -> Bool {
        guard !busyVaultRequests.contains(requestID) else { return false }
        busyVaultRequests.insert(requestID)
        vaultErrors[requestID] = nil
        defer { busyVaultRequests.remove(requestID) }
        do {
            vaultRecords[requestID] = try await client.declineVaultRequest(requestID)
            return true
        } catch {
            await recordVaultFailure(requestID, error)
            return false
        }
    }

    public func clearVaultError(_ requestID: VaultRequestID) {
        vaultErrors[requestID] = nil
    }

    /// 已经处理过、过期了（冲突）：拉一次最新的请求，卡片显示结果，不算出错。
    private func recordVaultFailure(_ requestID: VaultRequestID, _ error: any Error) async {
        guard let failure = ConversationErrors.from(error) else { return }
        if failure.isConflict, let list = try? await client.vaultRequests(all: true),
            let latest = list.first(where: { $0.id == requestID })
        {
            vaultRecords[requestID] = latest
            if latest.status != .pending { return }
        }
        vaultErrors[requestID] = failure
    }
}
