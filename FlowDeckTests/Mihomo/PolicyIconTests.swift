import UIKit
import XCTest

@testable import FlowDeck

/// 名称识别和离线资产是列表不出现空白、误配品牌的边界。
final class PolicyIconTests: XCTestCase {
    func testRoutingAndCommonAliases() {
        let cases = [
            "DIRECT": "direct", "REJECT-DROP": "reject-drop", "Proxies": "proxy", "自动选择": "auto",
            "漏网之鱼": "final", "🎬 Netflix": "netflix", "ChatGPT": "openai", "Claude Code": "claude",
            "Google Drive": "googledrive", "Google AI": "gemini", "GitHub Copilot": "copilot",
            "巴哈姆特": "bahamut", "🇺🇸 美国": "region-US", "Hong Kong": "region-HK", "🇮🇸": "region-IS",
        ]
        for (name, expected) in cases {
            XCTAssertEqual(PolicyIconCatalog.resolve(name: name).id, expected, name)
        }
    }

    func testShortCodesDoNotMatchInsideWords() {
        XCTAssertEqual(PolicyIconCatalog.resolve(name: "business").id, "custom")
        XCTAssertEqual(PolicyIconCatalog.resolve(name: "rainbow").id, "custom")
        XCTAssertEqual(PolicyIconCatalog.resolve(name: "unknown", groupType: "URLTest").id, "auto")
        XCTAssertEqual(PolicyIconCatalog.resolve(name: "unknown", groupType: "Fallback").id, "fallback")
        XCTAssertEqual(PolicyIconCatalog.resolve(name: "unknown", groupType: "NewType").id, "custom")
    }

    func testKnownIconHintAndCountryNames() {
        XCTAssertEqual(PolicyIconCatalog.resolve(name: "我的助手", iconURL: "https://example.invalid/ChatGPT.png").id, "openai")
        XCTAssertEqual(PolicyIconCatalog.resolve(name: "Netflix 香港").id, "netflix")
        XCTAssertEqual(PolicyIconCatalog.resolve(name: "日本自动选择").id, "auto")
        XCTAssertEqual(PolicyIconCatalog.resolve(name: "JP 优选").regionCode, "JP")
        XCTAssertEqual(PolicyIconCatalog.resolve(name: "德国").regionCode, "DE")
    }

    func testRegionalDisplayAssetsPreserveRoutingIdentity() {
        for name in ["CN", "cn", "🇨🇳", "中国大陆"] {
            XCTAssertEqual(PolicyIconCatalog.resolve(name: name).flagAssetName, "Region-CN", name)
        }
        for name in ["TW", "台湾", "台灣", "Taiwan", "🇹🇼"] {
            let spec = PolicyIconCatalog.resolve(name: name)
            XCTAssertEqual(spec.id, "region-TW", name)
            XCTAssertEqual(spec.regionCode, "TW", name)
            XCTAssertEqual(spec.flagAssetName, "Region-CN", name)
        }
        XCTAssertEqual(PolicyIconCatalog.resolve(name: "日本").flagAssetName, "Region-JP")
        XCTAssertNil(PolicyIconCatalog.resolve(name: "Netflix").flagAssetName)
    }

    /// 旧 SVG 能加载且有红底，却丢失了引用的星星；必须检查实际像素，而非仅检查资源存在。
    func testChinaStarsAndJapanCircleSurviveAssetCompilation() throws {
        for code in ["CN", "JP"] {
            let image = try XCTUnwrap(UIImage(named: "Region-" + code))
            XCTAssertEqual(image.size.width / image.size.height, 4.0 / 3.0, accuracy: 0.01)
            let width = 192
            let height = 144
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let context = try XCTUnwrap(
                CGContext(
                    data: &pixels, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(try XCTUnwrap(image.cgImage), in: CGRect(x: 0, y: 0, width: width, height: height))
            let indices = (0..<(width * height)).map { $0 * 4 }
            let red = indices.filter { pixels[$0] > 150 && pixels[$0 + 1] < 90 && pixels[$0 + 2] < 110 }
            if code == "CN" {
                let yellow = indices.filter { pixels[$0] > 200 && pixels[$0 + 1] > 180 && pixels[$0 + 2] < 80 }
                XCTAssertGreaterThan(yellow.count, 300, "星星路径丢失")
                XCTAssertGreaterThan(red.count, 24_000, "旗面不完整")
            } else {
                let white = indices.filter { pixels[$0] > 235 && pixels[$0 + 1] > 235 && pixels[$0 + 2] > 235 }
                XCTAssertGreaterThan(white.count, 20_000, "白色旗面不完整")
                XCTAssertGreaterThan(red.count, 5_000, "圆形路径丢失")
                XCTAssertLessThan(red.count, 7_000, "圆形被放大或裁切")
            }
        }
    }

    func testCatalogResourcesArePresent() {
        XCTAssertGreaterThanOrEqual(PolicyIconCatalog.services.count, 100)
        XCTAssertGreaterThanOrEqual(PolicyIconCatalog.regions.count, 240)
        let specs = PolicyIconCatalog.services + PolicyIconCatalog.regions + PolicyIconCatalog.continents
        XCTAssertEqual(Set(specs.map(\.id)).count, specs.count)
        for spec in specs {
            if let asset = spec.asset {
                let image = UIImage(named: asset)
                XCTAssertNotNil(image, asset)
                if let image { assertVisibleGlyph(image, name: asset) }
            }
            if let symbol = spec.symbol { XCTAssertNotNil(UIImage(systemName: symbol), symbol) }
        }
        for code in ["US", "HK", "TW", "JP", "KR", "SG", "GB", "DE", "FR", "CA", "AU", "CN", "MN"] {
            let image = UIImage(named: "Region-" + code)
            XCTAssertNotNil(image, code)
            if let image { assertVisibleGlyph(image, name: code) }
        }
        XCTAssertNotNil(Bundle.main.url(forResource: "FlagIcons", withExtension: "txt"))
        XCTAssertNotNil(Bundle.main.url(forResource: "LobeIcons", withExtension: "txt"))
        XCTAssertNotNil(Bundle.main.url(forResource: "SimpleIcons", withExtension: "txt"))
    }

    /// 资源可加载不代表矢量路径可绘制；检查实际模板轮廓，捕获缩成一个点的 SVG。
    private func assertVisibleGlyph(_ image: UIImage, name: String) {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        guard let cgImage = rendered.cgImage else {
            XCTFail("无法绘制 " + name)
            return
        }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard
            let context = CGContext(
                data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo)
        else {
            XCTFail("无法创建图标位图")
            return
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        let occupied = (0..<(side * side)).filter { pixels[$0 * 4 + 3] > 32 }
        let columns = Set(occupied.map { $0 % side })
        let rows = Set(occupied.map { $0 / side })
        XCTAssertGreaterThan(columns.count, 8, name + " 横向轮廓异常")
        XCTAssertGreaterThan(rows.count, 8, name + " 纵向轮廓异常")
    }

    func testDisplayDecorationDoesNotChangeIdentity() {
        XCTAssertEqual(PolicyIconCatalog.displayName("🇭🇰 香港"), "香港")
        XCTAssertEqual(PolicyIconCatalog.displayName("🚀 Proxies"), "Proxies")
        XCTAssertEqual(PolicyIconCatalog.displayName("🇭🇰"), "🇭🇰")
        XCTAssertEqual(PolicyIconCatalog.displayName("Group 1"), "Group 1")
    }
}
