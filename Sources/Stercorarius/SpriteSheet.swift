import CoreGraphics
import Foundation
import ImageIO

/// An agent's walk cycle, cut from a TexturePacker-style atlas: `<name>.png` plus `<name>.json`
/// (format described in `Resources/Sprites/README.md`).
struct SpriteSheet {
    struct Frame {
        let image: CGImage
        let duration: TimeInterval
    }

    enum LoadError: Error, CustomStringConvertible {
        case unreadableAtlas(URL)
        case emptyAnimation(String)
        case missingFrame(String)
        case invalidFrame(String)

        var description: String {
            switch self {
            case .unreadableAtlas(let url): "cannot read sprite atlas \(url.path)"
            case .emptyAnimation(let name): "\(name).json has no move_right frames"
            case .missingFrame(let frame): "move_right refers to unknown frame \(frame)"
            case .invalidFrame(let frame): "frame \(frame) has an invalid size or duration"
            }
        }
    }

    let frames: [Frame]
    /// Display size in points: frame pixels ÷ the atlas pixel ratio.
    let size: CGSize

    /// Length of one walk cycle.
    var cycleDuration: TimeInterval { frames.reduce(0) { $0 + $1.duration } }

    /// Key times for a discrete keyframe animation over `frames`: each frame's start normalized
    /// to 0...1, plus a closing 1 (discrete mode takes one more key time than values).
    var keyTimes: [NSNumber] {
        let total = cycleDuration
        var elapsed: TimeInterval = 0
        var times: [NSNumber] = []
        for frame in frames {
            times.append(NSNumber(value: elapsed / total))
            elapsed += frame.duration
        }
        times.append(1)
        return times
    }
}

extension SpriteSheet {
    /// The sprite bundled for `agent`.
    static func bundled(for agent: Agent) throws -> SpriteSheet {
        let resources = resourceBundle
        guard let directory = resources.url(forResource: "Sprites", withExtension: nil) else {
            throw LoadError.unreadableAtlas(resources.bundleURL.appending(path: "Sprites"))
        }
        return try load(name: agent.spriteName, in: directory)
    }

    /// The package's resource bundle. In the .app it sits in Contents/Resources, where SwiftPM's
    /// generated `Bundle.module` does not look: it would fall back to the absolute path of the
    /// repository's .build directory. So the copy next to the executable comes first.
    private static var resourceBundle: Bundle {
        Bundle.main.url(forResource: "Stercorarius_Stercorarius", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? Bundle.module
    }

    /// Loads `<name>.json` and `<name>.png` from `directory` and cuts the `move_right` frames.
    static func load(name: String, in directory: URL) throws -> SpriteSheet {
        let metadataURL = directory.appending(path: "\(name).json")
        let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metadataURL))
        let atlasURL = directory.appending(path: "\(name).png")
        guard let source = CGImageSourceCreateWithURL(atlasURL as CFURL, nil),
            let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw LoadError.unreadableAtlas(atlasURL) }

        var frames: [Frame] = []
        var pixelSize: CGSize?
        for frameName in metadata.animations["move_right"]?.frames ?? [] {
            guard let info = metadata.frames[frameName] else {
                throw LoadError.missingFrame(frameName)
            }
            let size = CGSize(width: info.frame.w, height: info.frame.h)
            guard info.durationMs > 0, pixelSize == nil || pixelSize == size else {
                throw LoadError.invalidFrame(frameName)
            }
            pixelSize = size
            let image = try render(info, from: atlas, frameName: frameName)
            frames.append(Frame(image: image, duration: info.durationMs / 1000))
        }
        let ratio = metadata.meta.pixelRatio
        guard let pixelSize, ratio > 0 else { throw LoadError.emptyAnimation(name) }
        return SpriteSheet(
            frames: frames,
            size: CGSize(width: pixelSize.width / ratio, height: pixelSize.height / ratio))
    }

    /// Cuts one frame out of the atlas into a transparent frame-sized image, shifted by
    /// `renderOffsetPx` (top-left origin: positive y moves the art down).
    private static func render(
        _ info: Metadata.FrameInfo, from atlas: CGImage, frameName: String
    ) throws -> CGImage {
        let rect = info.frame
        guard rect.w > 0, rect.h > 0,
            let piece = atlas.cropping(
                to: CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)),
            let context = CGContext(
                data: nil, width: rect.w, height: rect.h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw LoadError.invalidFrame(frameName) }
        let offset = info.renderOffsetPx
        context.draw(piece, in: CGRect(x: offset.x, y: -offset.y, width: rect.w, height: rect.h))
        guard let image = context.makeImage() else { throw LoadError.invalidFrame(frameName) }
        return image
    }
}

/// The parts of the sprite metadata JSON that Stercorarius uses.
private struct Metadata: Decodable {
    struct Rect: Decodable {
        let x: Int
        let y: Int
        let w: Int
        let h: Int
    }

    struct Offset: Decodable {
        let x: Int
        let y: Int
    }

    struct FrameInfo: Decodable {
        let frame: Rect
        let durationMs: Double
        let renderOffsetPx: Offset
    }

    struct Animation: Decodable {
        let frames: [String]
    }

    struct Meta: Decodable {
        let pixelRatio: Double
    }

    let frames: [String: FrameInfo]
    let animations: [String: Animation]
    let meta: Meta
}
