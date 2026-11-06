// Botin 头像的脸（ThinktinUI 的 `BotinFace`：形状变形、换颜色的动画）用到、别的桩文件里还没有的 SwiftUI 接口：
// 可动画的数据（`Animatable`、`VectorArithmetic`、`AnimatablePair`）和带参数的 `snappy` 动画。签名照 iOS 17 /
// macOS 14 SDK（都是 iOS 13 / iOS 17 就有的），只为类型检查，实现只够自己的测试用。

// MARK: - 可动画的数据（iOS 13）

/// 能做插值的向量：加减、乘一个数、长度的平方。
public protocol VectorArithmetic: AdditiveArithmetic {
    mutating func scale(by rhs: Double)
    var magnitudeSquared: Double { get }
}

/// 能做动画的类型：动画时 SwiftUI 在两个 `animatableData` 之间插值。
public protocol Animatable {
    associatedtype AnimatableData: VectorArithmetic
    var animatableData: AnimatableData { get set }
}

/// 不做动画的类型的 `animatableData`。
public struct EmptyAnimatableData: VectorArithmetic {
    public init() {}
    public static var zero: EmptyAnimatableData { EmptyAnimatableData() }
    public static func + (lhs: EmptyAnimatableData, rhs: EmptyAnimatableData) -> EmptyAnimatableData { lhs }
    public static func - (lhs: EmptyAnimatableData, rhs: EmptyAnimatableData) -> EmptyAnimatableData { lhs }
    public mutating func scale(by rhs: Double) {}
    public var magnitudeSquared: Double { 0 }
}

extension Animatable where AnimatableData == EmptyAnimatableData {
    public var animatableData: EmptyAnimatableData {
        get { EmptyAnimatableData() }
        set {}
    }
}

/// 两个可动画的值拼在一起。
public struct AnimatablePair<First: VectorArithmetic, Second: VectorArithmetic>: VectorArithmetic {
    public var first: First
    public var second: Second
    public init(_ first: First, _ second: Second) {
        self.first = first
        self.second = second
    }
    public static var zero: AnimatablePair<First, Second> { AnimatablePair(.zero, .zero) }
    public static func + (lhs: AnimatablePair<First, Second>, rhs: AnimatablePair<First, Second>) -> AnimatablePair<
        First, Second
    > {
        AnimatablePair(lhs.first + rhs.first, lhs.second + rhs.second)
    }
    public static func - (lhs: AnimatablePair<First, Second>, rhs: AnimatablePair<First, Second>) -> AnimatablePair<
        First, Second
    > {
        AnimatablePair(lhs.first - rhs.first, lhs.second - rhs.second)
    }
    public mutating func scale(by rhs: Double) {
        first.scale(by: rhs)
        second.scale(by: rhs)
    }
    public var magnitudeSquared: Double { first.magnitudeSquared + second.magnitudeSquared }
}

extension Double: VectorArithmetic {
    public mutating func scale(by rhs: Double) { self *= rhs }
    public var magnitudeSquared: Double { self * self }
}

extension CGFloat: VectorArithmetic {
    public mutating func scale(by rhs: Double) { self *= CGFloat(rhs) }
    public var magnitudeSquared: Double { Double(self * self) }
}

// MARK: - 动画（iOS 17）

extension Animation {
    /// 利落、不太弹的弹簧动画；`extraBounce` 是在默认的弹性上再加多少。
    public static func snappy(duration: TimeInterval = 0.5, extraBounce: Double = 0.0) -> Animation { Animation(tag: 4) }
}
