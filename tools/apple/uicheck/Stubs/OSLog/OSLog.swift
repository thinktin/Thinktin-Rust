@_exported import Foundation

public struct OSLogPrivacy: Sendable {
    public static let `public` = OSLogPrivacy()
    public static let `private` = OSLogPrivacy()
}

public struct OSLogMessage: ExpressibleByStringInterpolation {
    public struct StringInterpolation: StringInterpolationProtocol {
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) {}
        public mutating func appendInterpolation(_ value: @autoclosure @escaping () -> String, privacy: OSLogPrivacy = .private) {}
        public mutating func appendInterpolation(_ value: @autoclosure @escaping () -> Int32, privacy: OSLogPrivacy = .private) {}
        public mutating func appendInterpolation(_ value: @autoclosure @escaping () -> Int, privacy: OSLogPrivacy = .private) {}
    }
    public init(stringLiteral value: String) {}
    public init(stringInterpolation: StringInterpolation) {}
}

public struct Logger: Sendable {
    public init(subsystem: String, category: String) {}
    public func info(_ message: OSLogMessage) {}
    public func error(_ message: OSLogMessage) {}
}
