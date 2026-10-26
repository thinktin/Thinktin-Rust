@_exported import Foundation

public typealias OSStatus = Int32
public typealias CFTypeRef = AnyObject
public typealias CFString = String
public protocol _CFDictionaryLike {}
extension Dictionary: _CFDictionaryLike {}
public typealias CFDictionary = any _CFDictionaryLike

public let errSecSuccess: OSStatus = 0
public let errSecItemNotFound: OSStatus = -25300

public let kSecClass: CFString = "class"
public let kSecClassGenericPassword: CFString = "genp"
public let kSecAttrService: CFString = "svce"
public let kSecAttrAccount: CFString = "acct"
public let kSecValueData: CFString = "v_Data"
public let kSecReturnData: CFString = "r_Data"
public let kSecMatchLimit: CFString = "m_Limit"
public let kSecMatchLimitOne: CFString = "m_LimitOne"
public let kSecAttrAccessible: CFString = "pdmn"
public let kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: CFString = "cku"

public func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { 0 }
public func SecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { 0 }
public func SecItemUpdate(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus { 0 }
public func SecItemDelete(_ query: CFDictionary) -> OSStatus { 0 }

// Secure Enclave 的访问控制（12.9）。
public let kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly: CFString = "akpu"

public final class SecAccessControl: @unchecked Sendable {}
public final class CFError {}
public typealias CFAllocator = AnyObject

public struct SecAccessControlCreateFlags: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let userPresence = SecAccessControlCreateFlags(rawValue: 1 << 0)
    public static let biometryAny = SecAccessControlCreateFlags(rawValue: 1 << 1)
    public static let biometryCurrentSet = SecAccessControlCreateFlags(rawValue: 1 << 3)
    public static let devicePasscode = SecAccessControlCreateFlags(rawValue: 1 << 4)
    public static let privateKeyUsage = SecAccessControlCreateFlags(rawValue: 1 << 30)
}

public func SecAccessControlCreateWithFlags(
    _ allocator: CFAllocator?, _ protection: CFString, _ flags: SecAccessControlCreateFlags,
    _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?
) -> SecAccessControl? { SecAccessControl() }
