import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

@main enum GenerateWindowsParityFixtures {
    struct Case: Codable {
        let name: String
        let selection: RegionSelection
        let coverage: Data
        let roi: PixelRect?
        let compositeRGBA: Data?
        let selectedPixels: Int
    }
    struct Manifest: Encodable {
        let version = 1
        let sourceRevision = "677146984a186f3824e01b977c916c21da46a861"
        let width: Int
        let height: Int
        let sourceRGBA: Data
        let patchRGBA: [UInt8]
        let sourcePNG: String
        let p3PNG: String
        let p3Profile: String
        let cases: [Case]
    }
    struct OrientationCase: Encodable {
        let file: String
        let orientation: Int
        let width: Int
        let height: Int
        let rgba: Data
    }
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "windows/ParityFixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let width = 96, height = 64
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            bytes[i] = UInt8((x * 17 + y * 3) % 256)
            bytes[i + 1] = UInt8((x * 5 + y * 13) % 256)
            bytes[i + 2] = UInt8((x * 11 + y * 7) % 256)
            bytes[i + 3] = 255
        } }
        let image = try PixelImage(width: width, height: height, rgba: bytes)
        let png = try image.pngData(); try png.write(to: output.appendingPathComponent("reference.png"))
        let decoded = try PixelImage(data: png)
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let p3Image = try PixelImage(width: width, height: height, rgba: bytes, colorSpace: p3)
        try p3Image.pngData().write(to: output.appendingPathComponent("display-p3.png"))
        try p3Image.colorSpaceICCData.write(to: output.appendingPathComponent("display-p3.icc"))
        var transparent = bytes
        for y in 0..<height { for x in 0..<width where x % 3 != 0 {
            let i = (y * width + x) * 4
            let a: UInt8 = x % 3 == 1 ? 128 : 0
            transparent[i] = a == 128 ? 64 : 0; transparent[i + 1] = 0; transparent[i + 2] = a; transparent[i + 3] = a
        } }
        try PixelImage(width: width, height: height, rgba: transparent).pngData().write(to: output.appendingPathComponent("transparent.png"))
        var shapes: [(String, RegionSelection)] = []
        func selection(_ body: (inout RegionSelection) -> Void) -> RegionSelection {
            var value = RegionSelection(width: width, height: height); body(&value); return value
        }
        shapes.append(("fractional-rectangle", selection { $0.addRectangle(from: .init(x: 6.3, y: 4.8), to: .init(x: 28.2, y: 17.1)) }))
        shapes.append(("reverse-large-rectangle", selection { $0.addRectangle(from: .init(x: 88, y: 53), to: .init(x: 20, y: 9)) }))
        shapes.append(("clipped-concave-pen", selection { $0.addPen(points: [.init(x: -10, y: 10), .init(x: 30, y: -8), .init(x: 70, y: 15), .init(x: 35, y: 20), .init(x: 80, y: 55), .init(x: 2, y: 45)]) }))
        shapes.append(("crossed-pen", selection { $0.addPen(points: [.init(x: 10, y: 8), .init(x: 75, y: 53), .init(x: 10, y: 53), .init(x: 75, y: 8)]) }))
        shapes.append(("large-region-plus-fine-legacy-brush", selection {
            $0.addRectangle(from: .init(x: 10, y: 10), to: .init(x: 72, y: 54))
            $0.addBrush(points: [.init(x: 90.5, y: 58.5)], diameter: 0.5)
        }))
        shapes.append(("outside-collinear-pen-is-empty", selection { $0.addPen(points: [.init(x: -20, y: 9), .init(x: 5, y: 13), .init(x: 30, y: 17)]) }))
        let patchColor: [UInt8] = [60, 160, 100, 255]
        var cases: [Case] = []
        for (name, selection) in shapes {
            let coverage = selection.coverage()
            if selection.isEmpty {
                cases.append(.init(name: name, selection: selection, coverage: Data(coverage), roi: nil, compositeRGBA: nil, selectedPixels: 0))
                continue
            }
            let snapshot = try RegionEditSnapshot(base: decoded, selection: selection)
            var patch = [UInt8](); patch.reserveCapacity(snapshot.roi.width * snapshot.roi.height * 4)
            for _ in 0..<(snapshot.roi.width * snapshot.roi.height) { patch.append(contentsOf: patchColor) }
            let result = try snapshot.composite(patch: PixelImage(width: snapshot.roi.width, height: snapshot.roi.height, rgba: patch))
            try snapshot.maskPNG.write(to: output.appendingPathComponent(name + "-mask.png"))
            cases.append(.init(name: name, selection: selection, coverage: Data(coverage), roi: snapshot.roi, compositeRGBA: Data(result.rgba), selectedPixels: coverage.filter { $0 != 0 }.count))
        }
        let manifest = Manifest(width: width, height: height, sourceRGBA: Data(decoded.rgba), patchRGBA: patchColor, sourcePNG: "reference.png", p3PNG: "display-p3.png", p3Profile: "display-p3.icc", cases: cases)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: output.appendingPathComponent("manifest.json"))
        var orientations: [OrientationCase] = []
        for orientation in 1...8 {
            let file = "orientation-\(orientation).tiff"
            let url = output.appendingPathComponent(file)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else { throw ImageAgentError.invalidImage("Cannot write TIFF fixture") }
            CGImageDestinationAddImage(destination, try p3Image.cgImage(), [kCGImagePropertyOrientation: orientation] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ImageAgentError.invalidImage("Cannot finish TIFF fixture") }
            let value = try PixelImage(data: Data(contentsOf: url))
            orientations.append(.init(file: file, orientation: orientation, width: value.width, height: value.height, rgba: Data(value.rgba)))
        }
        try encoder.encode(orientations).write(to: output.appendingPathComponent("orientation-manifest.json"))
        print("Swift core parity fixtures: \(cases.count) cases, \(width)×\(height), P3/alpha assets generated.")
    }
}
