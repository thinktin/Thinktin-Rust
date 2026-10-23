import Foundation

extension Date {
    /// 从 Unix 毫秒构造（ThinktinCore 的时间字段都是毫秒）。
    public init(unixMilliseconds ms: Int64) {
        self.init(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    /// Unix 毫秒（四舍五入到整毫秒）。
    public var unixMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }
}
