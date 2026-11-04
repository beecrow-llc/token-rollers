import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Stercorarius

@Suite final class SpriteSheetTests {
    private let directory: URL

    init() throws { directory = try makeTemporaryDirectory() }

    deinit { try? FileManager.default.removeItem(at: directory) }

    @Test func bundledSpritesHaveEightFramesAt221Points() throws {
        for agent in Agent.allCases {
            let sheet = try SpriteSheet.bundled(for: agent)
            #expect(sheet.frames.count == 8)
            #expect(sheet.size == CGSize(width: 221, height: 221))
            #expect(abs(sheet.cycleDuration - 0.8) < 1e-9)
            #expect(sheet.frames.allSatisfy { $0.image.width == 442 && $0.image.height == 442 })
        }
    }

    @Test func cutsFramesInAnimationOrderAndBakesRenderOffsets() throws {
        try writeTwoFrameSheet()

        let sheet = try SpriteSheet.load(name: "beetle", in: directory)

        #expect(sheet.size == CGSize(width: 1.5, height: 2))
        #expect(sheet.frames.map(\.duration) == [0.25, 0.1])
        // Frame "b" plays first; its single pixel moved right 1 and down 2.
        let shifted = try alphaRows(of: try #require(sheet.frames.first).image)
        #expect(shifted == [[0, 0, 0], [0, 0, 0], [0, 255, 0], [0, 0, 0]])
        let block = try alphaRows(of: try #require(sheet.frames.last).image)
        #expect(block == Array(repeating: [255, 255, 255], count: 4))
    }

    @Test func keyTimesStartAtZeroAndCloseAtOne() throws {
        try writeTwoFrameSheet()

        let times = try SpriteSheet.load(name: "beetle", in: directory).keyTimes.map(\.doubleValue)

        #expect(times.count == 3)
        #expect(times.first == 0)
        #expect(abs((times.dropFirst().first ?? 0) - 0.25 / 0.35) < 1e-9)
        #expect(times.last == 1)
    }

    @Test func unknownFrameNameFails() throws {
        try writeAtlas(width: 1, height: 1, opaque: [(0, 0)])
        try writeMetadata(
            #"{"frames": {}, "animations": {"move_right": {"frames": ["ghost"]}},"#
                + #" "meta": {"pixelRatio": 2}}"#)
        #expect(throws: SpriteSheet.LoadError.self) {
            try SpriteSheet.load(name: "beetle", in: self.directory)
        }
    }

    @Test func emptyAnimationFails() throws {
        try writeAtlas(width: 1, height: 1, opaque: [])
        try writeMetadata(#"{"frames": {}, "animations": {}, "meta": {"pixelRatio": 2}}"#)
        #expect(throws: SpriteSheet.LoadError.self) {
            try SpriteSheet.load(name: "beetle", in: self.directory)
        }
    }

    @Test func missingAtlasFails() throws {
        try writeMetadata(#"{"frames": {}, "animations": {}, "meta": {"pixelRatio": 2}}"#)
        #expect(throws: SpriteSheet.LoadError.self) {
            try SpriteSheet.load(name: "beetle", in: self.directory)
        }
    }

    /// A 7×4 atlas: frame "a" is an opaque 3×4 block at x 0...2; frame "b" at x 4...6 has one
    /// opaque pixel in its top-left corner and `renderOffsetPx` (1, 2). Plays "b", then "a".
    private func writeTwoFrameSheet() throws {
        let block = (0..<3).flatMap { x in (0..<4).map { y in (x, y) } }
        try writeAtlas(width: 7, height: 4, opaque: block + [(4, 0)])
        try writeMetadata(
            """
            {
              "frames": {
                "a": {"frame": {"x": 0, "y": 0, "w": 3, "h": 4}, "durationMs": 100,
                      "renderOffsetPx": {"x": 0, "y": 0}},
                "b": {"frame": {"x": 4, "y": 0, "w": 3, "h": 4}, "durationMs": 250,
                      "renderOffsetPx": {"x": 1, "y": 2}}
              },
              "animations": {"move_right": {"frames": ["b", "a"]}},
              "meta": {"pixelRatio": 2}
            }
            """)
    }

    private func writeMetadata(_ json: String) throws {
        try writeFile(json, named: "beetle.json", in: directory)
    }

    /// Writes `beetle.png`: transparent except opaque white `pixels` (x, y from the top left).
    private func writeAtlas(width: Int, height: Int, opaque pixels: [(Int, Int)]) throws {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for (x, y) in pixels {
            let start = (y * width + x) * 4
            rgba.replaceSubrange(start..<start + 4, with: [255, 255, 255, 255])
        }
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let image = try #require(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent))
        let url = directory.appending(path: "beetle.png") as CFURL
        let png = UTType.png.identifier as CFString
        let destination = try #require(CGImageDestinationCreateWithURL(url, png, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// Alpha of every pixel of `image`, rows from the top.
    private func alphaRows(of image: CGImage) throws -> [[UInt8]] {
        let width = image.width
        let height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        try rgba.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (0..<height).map { row in
            (0..<width).map { column in rgba[(row * width + column) * 4 + 3] }
        }
    }
}
