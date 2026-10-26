// CryptoKit 的桩（12.9 Secure Enclave 里的签名密钥）：签名照 iOS 17 SDK，只放用到的。
@_exported import Foundation
import LocalAuthentication
import Security

public enum P256 {
    public enum Signing {
        public struct PublicKey: Sendable {
            public var x963Representation: Data { Data() }
        }

        public struct ECDSASignature: Sendable {
            public var derRepresentation: Data { Data() }
        }
    }
}

public enum SecureEnclave {
    public static var isAvailable: Bool { false }

    public enum P256 {
        public enum Signing {
            public struct PrivateKey: Sendable {
                public init(
                    compactRepresentable: Bool = true, accessControl: SecAccessControl,
                    authenticationContext: LAContext? = nil
                ) throws {}
                public init(dataRepresentation: Data, authenticationContext: LAContext? = nil) throws {}
                public var dataRepresentation: Data { Data() }
                public var publicKey: CryptoKit.P256.Signing.PublicKey { CryptoKit.P256.Signing.PublicKey() }
                public func signature<D: DataProtocol>(for data: D) throws -> CryptoKit.P256.Signing.ECDSASignature {
                    CryptoKit.P256.Signing.ECDSASignature()
                }
            }
        }
    }
}
