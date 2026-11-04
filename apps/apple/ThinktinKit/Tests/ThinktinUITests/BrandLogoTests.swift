import CoreGraphics
import Testing

@testable import ThinktinUI

/// Logo（`BrandLogoGeometry`，几何由 tools/apple/brand_assets.py 从 docs/brand/logo 生成）的换算。
@Suite("Logo")
struct BrandLogoTests {
    @Test("内容区等比缩放：给多大的框都按较短的一边放进去")
    func scale() {
        let bounds = BrandLogoGeometry.contentBounds
        #expect(BrandLogoGeometry.scale(for: bounds.size) == 1)
        #expect(BrandLogoGeometry.scale(for: CGSize(width: bounds.width * 3, height: bounds.height)) == 1)
        #expect(abs(BrandLogoGeometry.scale(for: CGSize(width: 100, height: 1000)) - 100 / bounds.width) < 1e-9)
    }

    @Test("内容区在 1000 × 1000 的画板里，罐子比宽高")
    func bounds() {
        let bounds = BrandLogoGeometry.contentBounds
        #expect(bounds.minX >= 0 && bounds.minY >= 0 && bounds.maxX <= 1000 && bounds.maxY <= 1000)
        #expect(bounds.height > bounds.width)
    }

    @Test("渐变轴在内容区里、从左上到右下；色标 0 到 1 按顺序，九个")
    func gradient() {
        let start = BrandLogoGeometry.relativePosition(BrandLogoGeometry.gradientStart)
        let end = BrandLogoGeometry.relativePosition(BrandLogoGeometry.gradientEnd)
        for point in [start, end] {
            #expect((0...1).contains(point.x) && (0...1).contains(point.y))
        }
        #expect(start.x < end.x && start.y < end.y)
        let locations = BrandLogoGeometry.gradientStops.map(\.location)
        #expect(locations.count == 9)
        #expect(locations.first == 0 && locations.last == 1)
        #expect(locations == locations.sorted())
    }
}
