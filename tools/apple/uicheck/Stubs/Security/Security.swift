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
