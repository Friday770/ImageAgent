import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import ImageAgentCore

func colorGrid(width: Int = 6, height: Int = 5) throws -> PixelImage {
    var bytes: [UInt8] = []
    for y in 0..<height { for x in 0..<width { bytes += [UInt8((x * 30 + 10) % 256), UInt8((y * 30 + 10) % 256), UInt8(((x + y) * 10) % 256), 255] } }
    return try PixelImage(width: width, height: height, rgba: bytes)
}
func pixel(_ image: PixelImage, _ x: Int, _ y: Int) -> [UInt8] {
    Array(image.rgba[((y * image.width + x) * 4)..<((y * image.width + x) * 4 + 4)])
}

@Suite struct RegionEditingTests {
    @Test func penContourMakesItsInteriorEditableInsteadOfLeavingABrushRing() {
        var selection = RegionSelection(width: 64, height: 48)
        let contour: [ImagePoint] = [.init(x: 8, y: 8), .init(x: 56, y: 8), .init(x: 56, y: 40),
                                     .init(x: 8, y: 40), .init(x: 8, y: 9)]
        selection.addPen(points: contour)
        #expect(selection.coverage()[24 * 64 + 32] == 255)
        #expect(selection.coverage()[4 * 64 + 32] == 0)
    }

    @Test func penAutomaticallyClosesAndItsFillDoesNotDependOnWinding() {
        let contour: [ImagePoint] = [.init(x: 1, y: 1), .init(x: 9, y: 1), .init(x: 9, y: 7), .init(x: 1, y: 7)]
        var forward = RegionSelection(width: 10, height: 8)
        forward.addPen(points: contour)
        var reversed = RegionSelection(width: 10, height: 8)
        reversed.addPen(points: contour.reversed())
        var closed = RegionSelection(width: 10, height: 8)
        closed.addPen(points: contour + [contour[0]])
        #expect(forward.coverage().filter { $0 == 255 }.count == 48)
        #expect(reversed.coverage() == forward.coverage())
        #expect(closed == forward)
        #expect(forward.outlines == [.pen(contour)])
    }

    @Test func concavePenKeepsItsNotchOutsideAndCrossingsUseEvenOddFill() {
        let contour: [ImagePoint] = [.init(x: 1, y: 1), .init(x: 8, y: 1), .init(x: 8, y: 3),
                                     .init(x: 3, y: 3), .init(x: 3, y: 8), .init(x: 1, y: 8)]
        var selection = RegionSelection(width: 10, height: 10)
        selection.addPen(points: contour)
        let coverage = selection.coverage()
        #expect(coverage.filter { $0 == 255 }.count == 24)
        #expect(coverage[2 * 10 + 6] == 255 && coverage[6 * 10 + 2] == 255)
        #expect(coverage[6 * 10 + 6] == 0)
        var reversed = RegionSelection(width: 10, height: 10)
        reversed.addPen(points: contour.reversed())
        #expect(reversed.coverage() == coverage)
        var crossing = RegionSelection(width: 10, height: 10)
        crossing.addPen(points: [.init(x: 1, y: 1), .init(x: 9, y: 9), .init(x: 1, y: 9), .init(x: 9, y: 1)])
        #expect(crossing.coverage()[2 * 10 + 4] == 255 && crossing.coverage()[7 * 10 + 4] == 255)
        #expect(crossing.coverage()[4 * 10 + 1] == 0)
        var twice = RegionSelection(width: 10, height: 10)
        twice.addPen(points: contour + [contour[0]] + contour + [contour[0]])
        #expect(twice.isEmpty && !twice.canUndo && twice.outlines.isEmpty)
    }

    @Test func penClipsActualEdgesAndExposesOnlyBoundedOutlineCoordinates() {
        var selection = RegionSelection(width: 6, height: 6)
        selection.addPen(points: [.init(x: -4, y: 2), .init(x: 4, y: 2), .init(x: 4, y: 10)])
        let coverage = selection.coverage()
        #expect(coverage.filter { $0 == 255 }.count == 16)
        for y in 0..<6 { for x in 0..<6 {
            #expect(coverage[y * 6 + x] == (x < 4 && y >= 2 ? 255 : 0))
        } }
        for outline in selection.outlines {
            guard case let .pen(points) = outline else { Issue.record("Expected pen outline"); continue }
            #expect(points.allSatisfy { $0.x >= 0 && $0.x <= 6 && $0.y >= 0 && $0.y <= 6 })
        }
        var border = RegionSelection(width: 6, height: 6)
        border.addPen(points: [.init(x: -1, y: -1), .init(x: 7, y: -1), .init(x: 7, y: 7), .init(x: -1, y: 7)])
        #expect(border.coverage() == [UInt8](repeating: 255, count: 36))
        border.addRectangle(from: .init(x: 9, y: 4), to: .init(x: -2, y: -2))
        #expect(border.outlines.last == .rectangle(.init(x: 0, y: 0), .init(x: 6, y: 4)))
    }

    @Test func invalidPenGesturesNeverCreateInvisibleOrUndoableRegions() {
        let invalid: [[ImagePoint]] = [[], [.init(x: 2, y: 2)], [.init(x: 1, y: 1), .init(x: 5, y: 5)],
            [.init(x: 1, y: 1), .init(x: 3, y: 3), .init(x: 5, y: 5)],
            [.init(x: 1, y: 2), .init(x: 3, y: 2), .init(x: 5, y: 2)],
            [.init(x: 2, y: 2), .init(x: 2, y: 2), .init(x: 2, y: 2)],
            [.init(x: .nan, y: 1), .init(x: 4, y: 1), .init(x: 4, y: 4)],
            [.init(x: 1, y: 1), .init(x: .infinity, y: 1), .init(x: 4, y: 4)],
            [.init(x: -5, y: 1), .init(x: -2, y: 1), .init(x: -2, y: 4)],
            [.init(x: 1, y: 1), .init(x: 1.1, y: 1), .init(x: 1, y: 1.1)]]
        for points in invalid {
            var selection = RegionSelection(width: 8, height: 8)
            selection.addPen(points: points)
            #expect(selection.isEmpty && !selection.canUndo && selection.outlines.isEmpty)
        }
    }

    @Test func penAndRectangleUnionUndoAndClearRestoreMatchingGeometry() {
        var selection = RegionSelection(width: 10, height: 10)
        selection.addPen(points: [.init(x: 1, y: 1), .init(x: 5, y: 1), .init(x: 5, y: 5), .init(x: 1, y: 5)])
        let first = selection
        selection.addRectangle(from: .init(x: 3, y: 3), to: .init(x: 7, y: 7))
        #expect(selection.coverage().filter { $0 == 255 }.count == 28 && selection.outlines.count == 2)
        selection.undo()
        #expect(selection == first)
        selection.clear()
        #expect(selection.isEmpty && !selection.canUndo && selection.outlines.isEmpty)
    }

    @Test func filledPenMaskMatchesItsCropAndChangesTheHeadInteriorWhilePreservingOutsideBytesAndICC() throws {
        let grid = try colorGrid(width: 64, height: 48)
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let base = try PixelImage(width: grid.width, height: grid.height, rgba: grid.rgba, colorSpace: p3)
        var selection = RegionSelection(width: base.width, height: base.height)
        selection.addPen(points: [.init(x: 8, y: 8), .init(x: 56, y: 8), .init(x: 56, y: 40), .init(x: 8, y: 40), .init(x: 8, y: 9)])
        let snapshot = try RegionEditSnapshot(base: base, selection: selection, contextPadding: 2)
        #expect(snapshot.roi == .init(x: 6, y: 6, width: 52, height: 36))
        let crop = try PixelImage(data: snapshot.imagePNG), mask = try PixelImage(data: snapshot.maskPNG)
        for y in 0..<snapshot.roi.height { for x in 0..<snapshot.roi.width {
            #expect(pixel(crop, x, y) == pixel(base, x + snapshot.roi.x, y + snapshot.roi.y))
            #expect(pixel(mask, x, y)[3] == 255 - snapshot.coverage[(y + snapshot.roi.y) * base.width + x + snapshot.roi.x])
        } }
        #expect(pixel(mask, 32 - snapshot.roi.x, 24 - snapshot.roi.y)[3] == 0)
        let patchSpace = try #require(CGColorSpace(iccData: base.colorSpaceICCData as CFData))
        let patch = try PixelImage(width: 1, height: 1, rgba: [200, 90, 30, 255], colorSpace: patchSpace)
        let result = try snapshot.composite(patch: patch)
        let saved = try PixelImage(data: result.pngData())
        #expect(pixel(saved, 32, 24) == [200, 90, 30, 255])
        #expect(saved.width == base.width && saved.height == base.height && saved.colorSpaceICCData == base.colorSpaceICCData)
        for y in 0..<base.height { for x in 0..<base.width where snapshot.coverage[y * base.width + x] == 0 {
            #expect(pixel(saved, x, y) == pixel(base, x, y))
        } }
    }

    @Test func normalizedPixelsRoundTripAndRespectOrientation() throws {
        let image = try colorGrid(width: 3, height: 2)
        #expect(try PixelImage(data: image.pngData()) == image)
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image.cgImage(), [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let rotated = try PixelImage(data: output as Data)
        #expect(rotated.width == 2 && rotated.height == 3)
        #expect(pixel(rotated, 0, 0) == pixel(image, 0, 1))
        #expect(pixel(rotated, 1, 0) == pixel(image, 0, 0))
        #expect(pixel(rotated, 0, 2) == pixel(image, 2, 1))
    }

    @Test func displayP3ProfileAndOutsidePixelValuesSurviveEditingAndPNGExport() throws {
        let source = try colorGrid(width: 6, height: 4)
        let cg = try source.cgImage()
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let provider = try #require(cg.dataProvider)
        let tagged = try #require(CGImage(width: cg.width, height: cg.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: cg.bytesPerRow, space: p3, bitmapInfo: cg.bitmapInfo,
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, tagged, nil)
        #expect(CGImageDestinationFinalize(destination))
        let base = try PixelImage(data: output as Data)
        #expect(base.rgba == source.rgba)
        let baseSpace = try #require(base.cgImage().colorSpace)
        #expect(CFEqual(baseSpace, p3))
        var selection = RegionSelection(width: 6, height: 4)
        selection.addRectangle(from: .init(x: 1, y: 1), to: .init(x: 3, y: 2))
        let snapshot = try RegionEditSnapshot(base: base, selection: selection)
        let edited = try snapshot.composite(patch: colorGrid(width: 1, height: 1))
        let saved = try PixelImage(data: edited.pngData())
        let savedSpace = try #require(saved.cgImage().colorSpace)
        #expect(CFEqual(savedSpace, p3))
        for y in 0..<4 { for x in 0..<6 where selection.coverage()[y * 6 + x] == 0 {
            #expect(pixel(saved, x, y) == pixel(source, x, y))
        } }
    }

    @Test func allEightEXIFOrientationsNormalizeNonSquareImages() throws {
        let base = try colorGrid(width: 3, height: 2)
        let expected = [[0,1,2,3,4,5], [2,1,0,5,4,3], [5,4,3,2,1,0], [3,4,5,0,1,2],
                        [0,3,1,4,2,5], [3,0,4,1,5,2], [5,2,4,1,3,0], [2,5,1,4,0,3]]
        for orientation in 1...8 {
            let output = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(output, UTType.tiff.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try base.cgImage(), [kCGImagePropertyOrientation: orientation] as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
            let normalized = try PixelImage(data: output as Data)
            #expect(normalized.width == (orientation > 4 ? 2 : 3))
            #expect(normalized.height == (orientation > 4 ? 3 : 2))
            for (index, source) in expected[orientation - 1].enumerated() {
                #expect(pixel(normalized, index % normalized.width, index / normalized.width) == pixel(base, source % 3, source / 3))
            }
        }
    }

    @Test func transparentOutsidePixelsRemainUnchangedAcrossPNGSave() throws {
        let raw = try PixelImage(width: 3, height: 2, rgba: [50,25,0,128, 0,0,0,0, 10,20,30,90, 25,40,70,100, 120,30,40,140, 255,255,255,255])
        let base = try PixelImage(data: raw.pngData())
        var selection = RegionSelection(width: 3, height: 2)
        selection.addRectangle(from: .init(x: 2, y: 1), to: .init(x: 3, y: 2))
        let result = try RegionEditSnapshot(base: base, selection: selection).composite(patch: colorGrid(width: 1, height: 1))
        let saved = try PixelImage(data: result.pngData())
        for index in 0..<5 { #expect(pixel(saved, index % 3, index / 3) == pixel(base, index % 3, index / 3)) }
    }

    @Test func reversedRectangleClipsAndUndoRestoresPreviousSelection() throws {
        var selection = RegionSelection(width: 6, height: 5)
        #expect(selection.isEmpty)
        selection.addRectangle(from: .init(x: 4, y: 3), to: .init(x: -2, y: 1))
        let first = selection.coverage()
        #expect(first.filter { $0 == 255 }.count == 8)
        #expect(first[1 * 6] == 255 && first[0] == 0 && first[3 * 6] == 0)
        selection.addRectangle(from: .init(x: 5, y: 4), to: .init(x: 6, y: 5))
        #expect(selection.coverage().filter { $0 == 255 }.count == 9)
        selection.undo()
        #expect(selection.coverage() == first)
        selection.clear()
        #expect(selection.isEmpty && !selection.canUndo)
        selection.addRectangle(from: .init(x: 9, y: 9), to: .init(x: 12, y: 12))
        #expect(selection.isEmpty)
    }

    @Test func brushSupportsSingleClicksContinuousStrokesAndImageCoordinates() throws {
        var selection = RegionSelection(width: 10, height: 8)
        selection.addBrush(points: [.init(x: 2.5, y: 2.5)], diameter: 1)
        #expect(selection.coverage()[2 * 10 + 2] == 255)
        #expect(selection.coverage().filter { $0 == 255 }.count == 1)
        selection.addBrush(points: [.init(x: 1.5, y: 5.5), .init(x: 8.5, y: 5.5)], diameter: 1)
        #expect((1...8).allSatisfy { selection.coverage()[5 * 10 + $0] == 255 })
        selection.undo()
        #expect(selection.coverage().filter { $0 == 255 }.count == 1)
        selection.addBrush(points: [.init(x: -10, y: -10)], diameter: 1)
        #expect(selection.coverage().filter { $0 == 255 }.count == 1)
    }

    @Test func onePixelBrushClicksHaveAnInImageFootprintAtIntegerAndFractionalCoordinates() {
        let clicks = [ImagePoint(x: 2, y: 2), .init(x: 2.1, y: 2.1), .init(x: 2.5, y: 2.5),
                      .init(x: 2.99, y: 2.99), .init(x: 0, y: 0), .init(x: 5.999, y: 4.999)]
        for point in clicks {
            var selection = RegionSelection(width: 6, height: 5)
            selection.addBrush(points: [point], diameter: 1)
            let coverage = selection.coverage()
            #expect(coverage[Int(point.y) * 6 + Int(point.x)] == 255)
            #expect(coverage.filter { $0 > 0 }.count == 1)
        }
        for point in [ImagePoint(x: -0.1, y: -0.1), .init(x: -0.001, y: 2.5), .init(x: 6.001, y: 2.5), .init(x: 2.5, y: 5.001)] {
            var selection = RegionSelection(width: 6, height: 5)
            selection.addBrush(points: [point], diameter: 1)
            #expect(selection.isEmpty)
        }
    }

    @Test func cropAndAPIMaskHaveMatchingTopLeftCoordinatesAndInverseAlpha() throws {
        let base = try colorGrid(width: 8, height: 7)
        var selection = RegionSelection(width: 8, height: 7)
        selection.addRectangle(from: .init(x: 1, y: 2), to: .init(x: 3, y: 4))
        let snapshot = try RegionEditSnapshot(base: base, selection: selection, contextPadding: 1)
        #expect(snapshot.roi == PixelRect(x: 0, y: 1, width: 4, height: 4))
        let crop = try PixelImage(data: snapshot.imagePNG)
        let mask = try PixelImage(data: snapshot.maskPNG)
        #expect(crop.width == mask.width && crop.height == mask.height)
        #expect(pixel(crop, 0, 0) == pixel(base, 0, 1))
        #expect(pixel(mask, 0, 0)[3] == 255)
        #expect(pixel(mask, 1, 1)[3] == 0)
        #expect(pixel(mask, 2, 2)[3] == 0)
        #expect(pixel(mask, 1, 3)[3] == 255)
        #expect(snapshot.maskPNG.count < 4 * 1024 * 1024)
    }

    @Test func arbitraryPatchSizePreservesEveryOutsideSelectionPixelAndSourceSize() throws {
        let base = try colorGrid()
        var selection = RegionSelection(width: base.width, height: base.height)
        selection.addBrush(points: [.init(x: 2.5, y: 2.5)], diameter: 3)
        let snapshot = try RegionEditSnapshot(base: base, selection: selection, contextPadding: 2)
        let patch = try PixelImage(width: 1, height: 2, rgba: [200, 25, 50, 255, 200, 25, 50, 255])
        let result = try snapshot.composite(patch: patch)
        #expect(result.width == base.width && result.height == base.height)
        let coverage = selection.coverage()
        for y in 0..<base.height { for x in 0..<base.width {
            #expect(pixel(result, x, y) == (coverage[y * base.width + x] == 0 ? pixel(base, x, y) : [200, 25, 50, 255]))
        } }
        #expect(try PixelImage(data: result.pngData()) == result)
    }

    @Test func inwardFeatherBlendsSelectedBoundaryAndFullyAppliesInteriorWithoutChangingOutside() throws {
        let base = try PixelImage(width: 64, height: 48, rgba: Array(repeating: [UInt8(20), 40, 60, 255], count: 64 * 48).flatMap { $0 })
        let patch = try PixelImage(width: 1, height: 1, rgba: [220, 160, 100, 255])
        var selection = RegionSelection(width: 64, height: 48)
        selection.addRectangle(from: .init(x: 8, y: 8), to: .init(x: 56, y: 40))
        let snapshot = try RegionEditSnapshot(base: base, selection: selection)
        let result = try snapshot.composite(patch: patch)
        let boundary = pixel(result, 8, 24)
        let next = pixel(result, 9, 24)
        #expect(boundary[0] > 20 && boundary[0] < 220)
        #expect(next[0] > boundary[0] && next[0] < 220)
        #expect(pixel(result, 32, 24) == [220, 160, 100, 255])
        #expect(result.width == base.width && result.height == base.height)
        #expect(result.colorSpaceICCData == base.colorSpaceICCData)
        for y in 0..<base.height { for x in 0..<base.width where snapshot.coverage[y * base.width + x] == 0 {
            #expect(pixel(result, x, y) == pixel(base, x, y))
        } }
        let mask = try PixelImage(data: snapshot.maskPNG)
        #expect(pixel(mask, 8 - snapshot.roi.x, 24 - snapshot.roi.y)[3] == 0)
    }

    @Test func tinyAndThinSelectionsKeepTheirFullPatchStrength() throws {
        let base = try colorGrid(width: 64, height: 48)
        let patch = try PixelImage(width: 1, height: 1, rgba: [220, 160, 100, 255])
        var tiny = RegionSelection(width: 64, height: 48)
        tiny.addRectangle(from: .init(x: 8, y: 8), to: .init(x: 10, y: 10))
        var thin = RegionSelection(width: 64, height: 48)
        thin.addBrush(points: [.init(x: 1.5, y: 1.5), .init(x: 60.5, y: 44.5)], diameter: 1)
        for selection in [tiny, thin] {
            let snapshot = try RegionEditSnapshot(base: base, selection: selection)
            let result = try snapshot.composite(patch: patch)
            for y in 0..<base.height { for x in 0..<base.width where snapshot.coverage[y * base.width + x] > 0 {
                #expect(pixel(result, x, y) == [220, 160, 100, 255])
            } }
        }
    }

    @Test func disjointFineMarksKeepFullStrengthBesideAFeatheredLargeRegion() throws {
        let base = try PixelImage(width: 160, height: 100, rgba: Array(repeating: [UInt8(20), 40, 60, 255], count: 160 * 100).flatMap { $0 })
        let patch = try PixelImage(width: 1, height: 1, rgba: [220, 160, 100, 255])
        var selection = RegionSelection(width: 160, height: 100)
        selection.addRectangle(from: .init(x: 10, y: 10), to: .init(x: 90, y: 90))
        selection.addBrush(points: [.init(x: 110, y: 10)], diameter: 1)
        selection.addRectangle(from: .init(x: 115, y: 10), to: .init(x: 117, y: 12))
        selection.addBrush(points: [.init(x: 110.5, y: 30.5), .init(x: 145.5, y: 70.5)], diameter: 1)
        let snapshot = try RegionEditSnapshot(base: base, selection: selection)
        let originalMask = snapshot.maskPNG
        let result = try snapshot.composite(patch: patch)
        #expect(pixel(result, 10, 40)[0] > 20 && pixel(result, 10, 40)[0] < 220)
        #expect(pixel(result, 50, 50) == [220, 160, 100, 255])
        for y in 0..<base.height { for x in 0..<base.width {
            if snapshot.coverage[y * base.width + x] == 0 { #expect(pixel(result, x, y) == pixel(base, x, y)) }
            else if x >= 100 { #expect(pixel(result, x, y) == [220, 160, 100, 255]) }
        } }
        #expect(snapshot.maskPNG == originalMask)
        let mask = try PixelImage(data: snapshot.maskPNG)
        for y in 0..<snapshot.roi.height { for x in 0..<snapshot.roi.width {
            let selected = snapshot.coverage[(y + snapshot.roi.y) * base.width + x + snapshot.roi.x]
            #expect(pixel(mask, x, y)[3] == 255 - selected)
        } }
    }

    @Test func inwardFeatherStopsWithinTwelveOriginalPixels() throws {
        let base = try PixelImage(width: 240, height: 220, rgba: Array(repeating: [UInt8(20), 40, 60, 255], count: 240 * 220).flatMap { $0 })
        let patch = try PixelImage(width: 1, height: 1, rgba: [220, 160, 100, 255])
        var selection = RegionSelection(width: 240, height: 220)
        selection.addRectangle(from: .init(x: 20, y: 20), to: .init(x: 220, y: 200))
        let result = try RegionEditSnapshot(base: base, selection: selection).composite(patch: patch)
        #expect(pixel(result, 31, 100)[0] < 220)
        #expect(pixel(result, 32, 100) == [220, 160, 100, 255])
        #expect(pixel(result, 19, 100) == pixel(base, 19, 100))
    }

    @Test func emptyOrMismatchedSelectionsCannotPrepareRequest() throws {
        let base = try colorGrid()
        #expect(throws: (any Error).self) { try RegionEditSnapshot(base: base, selection: .init(width: 6, height: 5)) }
        var selection = RegionSelection(width: 3, height: 3)
        selection.addRectangle(from: .init(x: 0, y: 0), to: .init(x: 2, y: 2))
        #expect(throws: (any Error).self) { try RegionEditSnapshot(base: base, selection: selection) }
    }
}
