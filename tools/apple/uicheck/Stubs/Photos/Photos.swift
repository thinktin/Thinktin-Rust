import Foundation

// Photos 的桩（第 1 轮 D 线：图片全屏查看的“保存到相册”，只申请“添加”权限）。签名照 iOS 17 SDK。

public enum PHAccessLevel: Int, Sendable {
    case addOnly = 1
    case readWrite = 2
}

public enum PHAuthorizationStatus: Int, Sendable {
    case notDetermined = 0
    case restricted = 1
    case denied = 2
    case authorized = 3
    case limited = 4
}

open class PHPhotoLibrary: NSObject {
    open class func shared() -> PHPhotoLibrary { PHPhotoLibrary() }
    open class func authorizationStatus(for accessLevel: PHAccessLevel) -> PHAuthorizationStatus { .notDetermined }
    open class func requestAuthorization(for accessLevel: PHAccessLevel) async -> PHAuthorizationStatus {
        .notDetermined
    }
    open func performChanges(_ changeBlock: @escaping () -> Void) async throws {}
}

public enum PHAssetResourceType: Int, Sendable {
    case photo = 1
    case video = 2
    case audio = 3
}

open class PHAssetResourceCreationOptions: NSObject {}

open class PHAssetChangeRequest: NSObject {}

open class PHAssetCreationRequest: PHAssetChangeRequest {
    open class func forAsset() -> Self { Self() }
    open func addResource(with type: PHAssetResourceType, fileURL: URL, options: PHAssetResourceCreationOptions?) {}
    open func addResource(with type: PHAssetResourceType, data: Data, options: PHAssetResourceCreationOptions?) {}
    public required override init() {}
}
