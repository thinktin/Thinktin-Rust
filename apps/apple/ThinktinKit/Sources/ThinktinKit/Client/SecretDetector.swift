import Foundation

/// 发送前检查消息里的密码、key（11.6），不联网。真实实现在 client-core（`CoreSecretDetector`），
/// Mock 里是一套简化的规则。
public protocol SecretDetector: Sendable {
    /// 消息里像密码、key 的内容（按出现顺序）。有命中时 App 拦下，弹表单存进保险箱。
    func detectSecrets(in text: String) -> [DetectedSecret]
    /// 把消息里的值都换成 `[vault:名字]`（所有出现的地方）。
    func redactMessage(_ text: String, references: [SecretReference]) -> String
    /// 建议名已经被占用时，换一个不重复的（`github` → `github_2`）。`taken` 是现有条目的名字。
    func uniqueVaultName(base: String, taken: [String]) -> String
}
