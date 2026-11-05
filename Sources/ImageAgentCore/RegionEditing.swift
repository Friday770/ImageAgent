import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Image coordinates use pixels, with the origin at the upper-left of the oriented image.
public struct ImagePoint: Equatable, Codable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    var isFinite: Bool { x.isFinite && y.isFinite }
}

public struct PixelRect: Equatable, Codable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
}

/// Canonical premultiplied RGBA8 in the source RGB color space. Row zero is the top of the displayed image.
public struct PixelImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]
    public let colorSpaceICCData: Data
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private var colorSpace: CGColorSpace { CGColorSpace(iccData: colorSpaceICCData as CFData) ?? Self.sRGB }
    private static let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

    public init(width: Int, height: Int, rgba: [UInt8], colorSpace: CGColorSpace? = nil) throws {
        guard width > 0, height > 0, Double(width) * Double(height) <= 150_000_000,
              rgba.count == width * height * 4 else { throw ImageAgentError.invalidImage("图片像素缓冲无效。") }
        let space = colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? Self.sRGB
        guard let profile = space.copyICCData() ?? Self.sRGB.copyICCData() else { throw ImageAgentError.invalidImage("无法读取图片颜色配置。") }
        self.width = width; self.height = height; self.rgba = rgba; colorSpaceICCData = profile as Data
    }
    public init(data: Data) throws {
        _ = try DecodedImage(data: data)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ImageAgentError.invalidImage("无法读取图片像素。") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let space = image.colorSpace.flatMap { $0.model == .rgb && $0.copyICCData() != nil ? $0 : nil } ?? Self.sRGB
        let raw = try Self.render(image, width: image.width, height: image.height, colorSpace: space)
        let swapped = (5...8).contains(orientation)
        let width = swapped ? image.height : image.width
        let height = swapped ? image.width : image.height
        if orientation <= 1 || orientation > 8 {
            try self.init(width: width, height: height, rgba: raw, colorSpace: space)
            return
        }
        var normalized = [UInt8](repeating: 0, count: raw.count)
        for y in 0..<height { for x in 0..<width {
            let sx: Int, sy: Int
            switch orientation {
            case 2: sx = image.width - 1 - x; sy = y
            case 3: sx = image.width - 1 - x; sy = image.height - 1 - y
            case 4: sx = x; sy = image.height - 1 - y
            case 5: sx = y; sy = x
            case 6: sx = y; sy = image.height - 1 - x
            case 7: sx = image.width - 1 - y; sy = image.height - 1 - x
            case 8: sx = image.width - 1 - y; sy = x
            default: sx = x; sy = y
            }
            let from = (sy * image.width + sx) * 4, to = (y * width + x) * 4
            for channel in 0..<4 { normalized[to + channel] = raw[from + channel] }
        } }
        try self.init(width: width, height: height, rgba: normalized, colorSpace: space)
    }
    private static func render(_ image: CGImage, width: Int, height: Int, colorSpace: CGColorSpace) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo) else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw ImageAgentError.invalidImage("无法建立图片像素缓冲。") }
        return bytes
    }
    public func cgImage() throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo), provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw ImageAgentError.invalidImage("无法建立图片。") }
        return image
    }
    public func pngData() throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw ImageAgentError.invalidImage("无法编码 PNG 图片。") }
        CGImageDestinationAddImage(destination, try cgImage(), nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageAgentError.invalidImage("无法保存 PNG 图片。") }
        return output as Data
    }
    func cropped(to rect: PixelRect) throws -> PixelImage {
        guard rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0,
              rect.x + rect.width <= width, rect.y + rect.height <= height else { throw ImageAgentError.invalidInput("选区裁图超出图片边界。") }
        var bytes: [UInt8] = []; bytes.reserveCapacity(rect.width * rect.height * 4)
        for y in rect.y..<(rect.y + rect.height) {
            let start = (y * width + rect.x) * 4
            bytes.append(contentsOf: rgba[start..<(start + rect.width * 4)])
        }
        return try PixelImage(width: rect.width, height: rect.height, rgba: bytes, colorSpace: colorSpace)
    }
    func resized(width: Int, height: Int, colorSpaceICCData: Data? = nil) throws -> PixelImage {
        let profile = colorSpaceICCData ?? self.colorSpaceICCData
        if self.width == width && self.height == height && profile == self.colorSpaceICCData { return self }
        let space = CGColorSpace(iccData: profile as CFData) ?? Self.sRGB
        return try PixelImage(width: width, height: height, rgba: Self.render(cgImage(), width: width, height: height, colorSpace: space), colorSpace: space)
    }
}

/// Store vector marks for undo rather than retaining a full-sized mask for every pointer event.
public struct RegionSelection: Equatable, Codable, Sendable {
    /// Filled-region boundaries in oriented source coordinates. UI strokes never become image pixels.
    public enum Outline: Equatable, Sendable {
        case rectangle(ImagePoint, ImagePoint)
        case pen([ImagePoint])
    }
    private enum Mark: Equatable, Codable, Sendable {
        case rectangle(ImagePoint, ImagePoint)
        case pen([ImagePoint])
        case brush([ImagePoint], Double)
    }
    public let width: Int
    public let height: Int
    private var marks: [Mark] = []
    public init(width: Int, height: Int) {
        let valid = width > 0 && height > 0 && Double(width) * Double(height) <= 150_000_000
        self.width = valid ? width : 0; self.height = valid ? height : 0
    }
    private enum CodingKeys: String, CodingKey { case width, height, marks }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let width = try values.decode(Int.self, forKey: .width), height = try values.decode(Int.self, forKey: .height)
        let marks = try values.decode([Mark].self, forKey: .marks)
        guard width > 0, height > 0, Double(width) * Double(height) <= 150_000_000, marks.count <= 4096 else {
            throw ImageAgentError.invalidInput("保存的选区尺寸或笔画数量无效。")
        }
        func inside(_ point: ImagePoint) -> Bool {
            point.isFinite && point.x >= 0 && point.y >= 0 && point.x <= Double(width) && point.y <= Double(height)
        }
        var pointsCount = 0
        for mark in marks {
            switch mark {
            case let .rectangle(a, b):
                guard inside(a), inside(b), a.x < b.x, a.y < b.y else { throw ImageAgentError.invalidInput("保存的方框选区无效。") }
                pointsCount += 2
            case let .pen(points):
                guard points.count >= 3, points.allSatisfy(inside) else { throw ImageAgentError.invalidInput("保存的钢笔选区无效。") }
                pointsCount += points.count
            case let .brush(points, diameter):
                guard !points.isEmpty, points.allSatisfy({ $0.isFinite && abs($0.x) <= 1_000_000_000 && abs($0.y) <= 1_000_000_000 }),
                      diameter.isFinite, diameter > 0, diameter <= Double(max(width, height)) * 2 else { throw ImageAgentError.invalidInput("保存的笔刷选区无效。") }
                pointsCount += points.count
            }
            guard pointsCount <= 100_000 else { throw ImageAgentError.invalidInput("保存的选区点数过多。") }
        }
        self.width = width; self.height = height; self.marks = marks
    }
    public var canUndo: Bool { !marks.isEmpty }
    public var isEmpty: Bool { !coverage().contains(where: { $0 != 0 }) }
    /// Legacy brush consumers retain their coverage semantics without exposing a brush in the editor.
    public var outlines: [Outline] {
        marks.compactMap { mark in
            switch mark {
            case let .rectangle(a, b): return .rectangle(a, b)
            case let .pen(points): return .pen(points)
            case .brush: return nil
            }
        }
    }
    public mutating func addRectangle(from: ImagePoint, to: ImagePoint) {
        guard from.isFinite, to.isFinite, from.x != to.x, from.y != to.y else { return }
        guard max(from.x, to.x) > 0, max(from.y, to.y) > 0,
              min(from.x, to.x) < Double(width), min(from.y, to.y) < Double(height) else { return }
        marks.append(.rectangle(.init(x: max(0, min(from.x, to.x)), y: max(0, min(from.y, to.y))),
                                .init(x: min(Double(width), max(from.x, to.x)), y: min(Double(height), max(from.y, to.y)))))
    }
    /// A released contour implicitly closes. Even-odd fill is independent of winding and supports concavity/crossings.
    public mutating func addPen(points: [ImagePoint]) {
        guard width > 0, height > 0, points.count >= 3, points.allSatisfy(\.isFinite) else { return }
        var polygon: [ImagePoint] = []
        for point in points where polygon.last != point { polygon.append(point) }
        if polygon.first == polygon.last { polygon.removeLast() }
        guard polygon.count >= 3 else { return }
        // Clip the boundary rather than clamping individual vertices, which would distort slanted edges.
        for (axis, boundary, keepGreater) in [(0, 0.0, true), (0, Double(width), false),
                                             (1, 0.0, true), (1, Double(height), false)] {
            guard let last = polygon.last else { return }
            var clipped: [ImagePoint] = [], previous = last
            func coordinate(_ point: ImagePoint) -> Double { axis == 0 ? point.x : point.y }
            func inside(_ point: ImagePoint) -> Bool { keepGreater ? coordinate(point) >= boundary : coordinate(point) <= boundary }
            for point in polygon {
                if inside(previous) != inside(point) {
                    let a = coordinate(previous), b = coordinate(point)
                    let scale = max(1, abs(a), abs(b), abs(boundary))
                    let t = (boundary / scale - a / scale) / (b / scale - a / scale)
                    let other = axis == 0 ? previous.y * (1 - t) + point.y * t : previous.x * (1 - t) + point.x * t
                    let intersection = axis == 0 ? ImagePoint(x: boundary, y: other) : ImagePoint(x: other, y: boundary)
                    guard intersection.isFinite else { return }
                    if clipped.last != intersection { clipped.append(intersection) }
                }
                if inside(point), clipped.last != point { clipped.append(point) }
                previous = point
            }
            if clipped.first == clipped.last, !clipped.isEmpty { clipped.removeLast() }
            polygon = clipped
        }
        guard polygon.count >= 3, visitPenSpans(polygon, { _, _ in true }) else { return }
        marks.append(.pen(polygon))
    }
    public mutating func addBrush(points: [ImagePoint], diameter: Double) {
        guard !points.isEmpty, points.allSatisfy(\.isFinite), diameter.isFinite, diameter > 0 else { return }
        marks.append(.brush(points, min(diameter, Double(max(width, height)) * 2)))
    }
    public mutating func undo() { if !marks.isEmpty { marks.removeLast() } }
    public mutating func clear() { marks.removeAll() }
    /// Visit nonempty pixel-center spans; return early when the visitor requests it.
    private func visitPenSpans(_ points: [ImagePoint], _ visit: (Int, Range<Int>) -> Bool) -> Bool {
        guard let minimumY = points.map(\.y).min(), let maximumY = points.map(\.y).max() else { return false }
        let top = max(0, Int(floor(minimumY))), bottom = min(height, Int(ceil(maximumY)))
        guard top < bottom else { return false }
        for y in top..<bottom {
            let centerY = Double(y) + 0.5
            var intersections: [Double] = []
            var previous = points[points.count - 1]
            for point in points {
                if (previous.y > centerY) != (point.y > centerY) {
                    intersections.append(previous.x + (centerY - previous.y) / (point.y - previous.y) * (point.x - previous.x))
                }
                previous = point
            }
            intersections.sort()
            for index in stride(from: 0, to: intersections.count - 1, by: 2) {
                let left = max(0, min(width, Int(ceil(intersections[index] - 0.5))))
                let right = max(0, min(width, Int(ceil(intersections[index + 1] - 0.5))))
                if left < right, visit(y, left..<right) { return true }
            }
        }
        return false
    }
    public func coverage() -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard width > 0, height > 0 else { return pixels }
        func bounded(_ value: Double, maximum: Int, ceilValue: Bool = false) -> Int {
            Int(min(Double(maximum), max(0, ceilValue ? ceil(value) : floor(value))))
        }
        for mark in marks {
            switch mark {
            case let .rectangle(from, to):
                let left = bounded(min(from.x, to.x), maximum: width)
                let top = bounded(min(from.y, to.y), maximum: height)
                let right = bounded(max(from.x, to.x), maximum: width, ceilValue: true)
                let bottom = bounded(max(from.y, to.y), maximum: height, ceilValue: true)
                for y in top..<bottom { for x in left..<right { pixels[y * width + x] = 255 } }
            case let .pen(points):
                _ = visitPenSpans(points) { y, span in
                    for x in span { pixels[y * width + x] = 255 }
                    return false
                }
            case let .brush(points, diameter):
                if points.count == 1, let point = points.first,
                   point.x >= 0, point.x < Double(width), point.y >= 0, point.y < Double(height) {
                    // A small click may fall between every sampled pixel center; retain its containing pixel.
                    pixels[Int(point.y) * width + Int(point.x)] = 255
                }
                let radius = diameter / 2
                let pairs = points.count == 1 ? [(points[0], points[0])] : Array(zip(points, points.dropFirst()))
                for (a, b) in pairs {
                    let left = bounded(min(a.x, b.x) - radius, maximum: width)
                    let right = bounded(max(a.x, b.x) + radius, maximum: width, ceilValue: true)
                    let top = bounded(min(a.y, b.y) - radius, maximum: height)
                    let bottom = bounded(max(a.y, b.y) + radius, maximum: height, ceilValue: true)
                    let dx = b.x - a.x, dy = b.y - a.y
                    let lengthSquared = dx * dx + dy * dy
                    for y in top..<bottom { for x in left..<right {
                        let px = Double(x) + 0.5, py = Double(y) + 0.5
                        let t = lengthSquared > 0 ? min(1, max(0, ((px - a.x) * dx + (py - a.y) * dy) / lengthSquared)) : 0
                        let distanceSquared = pow(px - (a.x + t * dx), 2) + pow(py - (a.y + t * dy), 2)
                        if distanceSquared <= radius * radius { pixels[y * width + x] = 255 }
                    } }
                }
            }
        }
        return pixels
    }
}

public struct RegionEditRequest: Equatable, Codable, Sendable {
    public let assetID: String
    public let selection: RegionSelection
    public init(assetID: String, selection: RegionSelection) { self.assetID = assetID; self.selection = selection }
}

/// Immutable pixels and coverage captured before planning. API alpha and selection coverage are deliberately separate.
public struct RegionEditSnapshot: Sendable {
    public let base: PixelImage
    public let coverage: [UInt8]
    public let roi: PixelRect
    public let imagePNG: Data
    public let maskPNG: Data
    public init(base: PixelImage, selection: RegionSelection, contextPadding: Int? = nil) throws {
        guard selection.width == base.width, selection.height == base.height else { throw ImageAgentError.invalidInput("选区与原始图片尺寸不匹配，请重新打开图片。") }
        let coverage = selection.coverage()
        var left = base.width, top = base.height, right = 0, bottom = 0
        for y in 0..<base.height { for x in 0..<base.width where coverage[y * base.width + x] > 0 {
            left = min(left, x); top = min(top, y); right = max(right, x + 1); bottom = max(bottom, y + 1)
        } }
        guard left < right, top < bottom else { throw ImageAgentError.invalidInput("请先在图片上选择需要修改的区域。") }
        let padding = min(max(0, contextPadding ?? max(16, min(128, max(right - left, bottom - top) / 5))), max(base.width, base.height))
        left = max(0, left - padding); top = max(0, top - padding)
        right = min(base.width, right + padding); bottom = min(base.height, bottom + padding)
        let roi = PixelRect(x: left, y: top, width: right - left, height: bottom - top)
        let crop = try base.cropped(to: roi)
        var mask = [UInt8](repeating: 0, count: roi.width * roi.height * 4)
        for y in 0..<roi.height { for x in 0..<roi.width {
            mask[(y * roi.width + x) * 4 + 3] = 255 - coverage[(y + top) * base.width + x + left]
        } }
        let png = try PixelImage(width: roi.width, height: roi.height, rgba: mask).pngData()
        guard png.count < 4 * 1024 * 1024 else { throw ImageAgentError.invalidInput("选区遮罩超过 4MB，请缩小选区。") }
        self.base = base; self.coverage = coverage; self.roi = roi
        imagePNG = try crop.pngData(); maskPNG = png
    }
    /// A capped distance field fades inward only. Keep API alpha and the immutable selection unchanged.
    private func inwardFeatherWeights() -> [UInt8]? {
        let width = roi.width, height = roi.height
        let cap = 73 // Enough depth to choose the maximum 12-pixel feather without a large integer buffer.
        var depth = [UInt8](repeating: UInt8(cap), count: width * height)
        for y in 0..<height { for x in 0..<width where coverage[(y + roi.y) * base.width + x + roi.x] == 0 {
            depth[y * width + x] = 0
        } }
        func neighbor(_ x: Int, _ y: Int) -> Int {
            if x >= 0, x < width, y >= 0, y < height { return Int(depth[y * width + x]) }
            let imageX = x + roi.x, imageY = y + roi.y
            // Image edges have no neighboring unselected pixel and do not need an artificial fade.
            return imageX >= 0 && imageX < base.width && imageY >= 0 && imageY < base.height ? 0 : cap
        }
        for y in 0..<height { for x in 0..<width where depth[y * width + x] > 0 {
            let previous = min(min(neighbor(x - 1, y), neighbor(x, y - 1)), min(neighbor(x - 1, y - 1), neighbor(x + 1, y - 1)))
            depth[y * width + x] = UInt8(min(Int(depth[y * width + x]), previous + 1))
        } }
        for y in (0..<height).reversed() { for x in (0..<width).reversed() where depth[y * width + x] > 0 {
            let next = min(min(neighbor(x + 1, y), neighbor(x, y + 1)), min(neighbor(x - 1, y + 1), neighbor(x + 1, y + 1)))
            depth[y * width + x] = UInt8(min(Int(depth[y * width + x]), next + 1))
        } }
        guard (depth.max() ?? 0) >= 8 else { return nil }
        var weights = [UInt8](repeating: 0, count: depth.count)
        var component: [Int32] = [] // The 150M-pixel limit fits Int32; reuse this buffer between components.
        for start in depth.indices where depth[start] > 0 && depth[start] < 128 {
            component.removeAll(keepingCapacity: true)
            component.append(Int32(start)); depth[start] |= 128
            var cursor = 0, maximumDepth = 0
            while cursor < component.count {
                let index = Int(component[cursor]); cursor += 1
                maximumDepth = max(maximumDepth, Int(depth[index] & 127))
                let x = index % width, y = index / width
                for dy in -1...1 { for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let next = ny * width + nx
                    if depth[next] > 0 && depth[next] < 128 {
                        depth[next] |= 128; component.append(Int32(next))
                    }
                } }
            }
            // Adapt each separate mark independently so a large region cannot weaken fine marks beside it.
            let radius = maximumDepth < 8 ? 0 : min(12, maximumDepth / 6)
            for value in component {
                let index = Int(value)
                let t = radius == 0 ? 1 : min(1, Double(depth[index] & 127) / Double(radius + 1))
                weights[index] = UInt8((t * t * (3 - 2 * t) * 255).rounded())
            }
        }
        return weights
    }

    public func composite(patch: PixelImage) throws -> PixelImage {
        let patch = try patch.resized(width: roi.width, height: roi.height, colorSpaceICCData: base.colorSpaceICCData)
        let feather = inwardFeatherWeights()
        var result = base.rgba
        for y in 0..<roi.height { for x in 0..<roi.width {
            let basePixel = (y + roi.y) * base.width + x + roi.x
            guard coverage[basePixel] > 0 else { continue }
            let localPixel = y * roi.width + x
            let weight = Int(coverage[basePixel]) * Int(feather?[localPixel] ?? 255) / 255
            let source = localPixel * 4, destination = basePixel * 4
            for channel in 0..<4 {
                result[destination + channel] = UInt8((Int(patch.rgba[source + channel]) * weight + Int(base.rgba[destination + channel]) * (255 - weight) + 127) / 255)
            }
        } }
        return try PixelImage(width: base.width, height: base.height, rgba: result, colorSpace: CGColorSpace(iccData: base.colorSpaceICCData as CFData))
    }
}
