import CoreGraphics
import CoreImage
import Foundation
import SwiftUI
import ThinktinUI

/// 配对二维码（WBS 14.8）：CoreImage 的二维码滤镜把 `thinktin-pair:v1?…` 画成图，菜单栏面板显示
/// （`\.pairingCodeImage`）。纠错等级 M：邀请两三百个字符，手机隔着屏幕扫也稳。
enum PairingQRCode {
    static let environmentValue = PairingCodeImage { code in image(for: code) }

    /// 每个模块放大成几个像素（再交给界面按 200 点显示，`interpolation(.none)` 不糊）。
    private static let moduleScale: CGFloat = 8

    @MainActor
    static func image(for code: String) -> Image? {
        guard
            let filter = CIFilter(
                name: "CIQRCodeGenerator",
                parameters: ["inputMessage": Data(code.utf8), "inputCorrectionLevel": "M"]),
            let output = filter.outputImage
        else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: moduleScale, y: moduleScale))
        guard let cgImage = CIContext(options: nil).createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }
}
