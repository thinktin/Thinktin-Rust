import Foundation

/// 这台设备上按 Botin 记的东西，服务端都没有这些字段：头像外观（`InstanceAppearanceStore`）、首页的置顶和隐藏
/// （`InstancePreferencesStore`）、语音通话设置（`BotinVoiceStore`）、表情回应（`MessageReactionStore`）、主 Botin
/// （`PrimaryBotinStore`）。放在一起是为了删的时候一样不漏：删了 Botin、它在服务端没了（`forget(_:)`），注销账号
/// （`forgetAccount(_:)`）。以后再加按 Botin 记在本机的东西，也加到这里。
///
/// 退出登录不清（同一个账号再登录时还在，别的账号的 Botin id 对不上，用不到）。App 里的那一份是 `AppModel.local`。
@MainActor
public struct BotinLocalData {
    public let appearances: InstanceAppearanceStore
    public let preferences: InstancePreferencesStore
    public let voices: BotinVoiceStore
    public let reactions: MessageReactionStore
    public let primary: PrimaryBotinStore

    public init(
        appearances: InstanceAppearanceStore, preferences: InstancePreferencesStore, voices: BotinVoiceStore,
        reactions: MessageReactionStore, primary: PrimaryBotinStore
    ) {
        self.appearances = appearances
        self.preferences = preferences
        self.voices = voices
        self.reactions = reactions
        self.primary = primary
    }

    /// 按 `defaults` 建：nil 是五样都只记在内存里（测试、预览）；`UserDefaults.standard` 时语音、表情回应、主 Botin 用整个 App
    /// 共用的那份（`.shared`，没有 `AppModel` 的地方也读它们），别的 `defaults`（测试的 suite）五样都新建在它上面。
    public init(defaults: UserDefaults?) {
        let isStandard = defaults.map { $0 === UserDefaults.standard } ?? false
        self.init(
            appearances: InstanceAppearanceStore(defaults: defaults),
            preferences: InstancePreferencesStore(defaults: defaults),
            voices: isStandard ? .shared : BotinVoiceStore(defaults: defaults),
            reactions: isStandard ? .shared : MessageReactionStore(defaults: defaults),
            primary: isStandard ? .shared : PrimaryBotinStore(defaults: defaults))
    }

    /// 只记在内存里的一份（测试、预览）。
    public static func inMemory() -> BotinLocalData {
        BotinLocalData(defaults: nil)
    }

    /// 删掉这些 Botin 在这台设备上的全部记录（删了 Botin、它在服务端没了）。是主 Botin 的话清掉。
    public func forget(_ ids: [InstanceID]) {
        guard !ids.isEmpty else { return }
        appearances.forget(ids)
        preferences.forget(ids)
        voices.forget(ids)
        for id in ids {
            reactions.forget(instanceID: id)
            primary.forget(instanceID: id)
        }
    }

    /// 注销账号之后：这个账号的 Botin（注销前的实例列表）的记录都删掉，主 Botin 也清掉（列表没拉全时它可能不在里面，
    /// 账号都没了，留着也用不上）。
    public func forgetAccount(_ ids: [InstanceID]) {
        forget(ids)
        primary.set(nil)
    }
}
