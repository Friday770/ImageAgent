import AppKit
import Foundation
import Testing
import ImageAgentCore
@testable import ImageAgent

@MainActor @Suite struct EditorCanvasTests {
    private func render(_ canvas: CanvasImageView, scale: CGFloat = 1) -> NSBitmapImageRep {
        let width = Int(canvas.bounds.width * scale), height = Int(canvas.bounds.height * scale)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: width * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private func send(_ type: NSEvent.EventType, point: NSPoint, to canvas: CanvasImageView) throws {
        let event = try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                                                   timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        switch type {
        case .leftMouseDown: canvas.mouseDown(with: event)
        case .leftMouseUp: canvas.mouseUp(with: event)
        default: canvas.mouseDragged(with: event)
        }
    }

    private func gesture(_ points: [NSPoint], on canvas: CanvasImageView) throws {
        for (index, point) in points.enumerated() {
            let type: NSEvent.EventType = index == 0 ? .leftMouseDown : (index == points.count - 1 ? .leftMouseUp : .leftMouseDragged)
            try send(type, point: point, to: canvas)
        }
    }

    @Test func rectangleDisplaysARedBoundaryAndLeavesTheSubjectVisible() throws {
        let image = try PixelImage(width: 80, height: 80, rgba: Array(repeating: [UInt8(240), 240, 240, 255], count: 80 * 80).flatMap { $0 })
        var selection = RegionSelection(width: 80, height: 80)
        selection.addRectangle(from: .init(x: 20, y: 20), to: .init(x: 60, y: 60))
        let canvas = CanvasImageView()
        canvas.configure(image: image, selection: selection, tool: .rectangle, enabled: true)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 80, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 80 * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let interior = try #require(bitmap.colorAt(x: 40, y: 40)?.usingColorSpace(.deviceRGB))
        #expect(abs(interior.redComponent - 240.0 / 255) < 0.02)
        #expect(abs(interior.greenComponent - interior.redComponent) < 0.02)
        #expect(abs(interior.blueComponent - interior.redComponent) < 0.02)
        let boundary = try #require(bitmap.colorAt(x: 20, y: 40)?.usingColorSpace(.deviceRGB))
        #expect(boundary.redComponent > 0.8 && boundary.greenComponent < 0.3 && boundary.blueComponent < 0.3)
    }

    @Test func penAndRectangleStayTwoScreenPointsWideAcrossMagnification() throws {
        let image = try PixelImage(width: 160, height: 120, rgba: Array(repeating: [UInt8(240), 240, 240, 255], count: 160 * 120).flatMap { $0 })
        let scroll = CanvasScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        scroll.fitToWindow = false
        for tool in [EditorTool.rectangle, .pen] {
            var selection = RegionSelection(width: 160, height: 120)
            if tool == .rectangle { selection.addRectangle(from: .init(x: 40, y: 30), to: .init(x: 120, y: 90)) }
            else { selection.addPen(points: [.init(x: 40, y: 30), .init(x: 120, y: 30), .init(x: 120, y: 90), .init(x: 40, y: 90)]) }
            scroll.canvas.configure(image: image, selection: selection, tool: tool, enabled: true)
            for scale in [0.5, 1.0, 2.0, 3.0] {
                scroll.setMagnification(scale, centeredAt: NSPoint(x: 80, y: 60))
                let bitmap = render(scroll.canvas, scale: scale)
                let row = Int(60 * scale), edge = Int(40 * scale)
                let redPixels = ((edge - 4)...(edge + 4)).filter { x in
                    guard let color = bitmap.colorAt(x: x, y: row)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.redComponent > 0.8 && color.greenComponent < 0.3 && color.blueComponent < 0.3
                }
                #expect(redPixels.count == 2, "At \(scale)× the \(tool.title) boundary must remain two screen pixels in a 1× bitmap")
                let interior = try #require(bitmap.colorAt(x: Int(80 * scale), y: row)?.usingColorSpace(.deviceRGB))
                #expect(abs(interior.redComponent - 240.0 / 255) < 0.02 && abs(interior.blueComponent - interior.redComponent) < 0.02)
            }
        }
    }

    @Test func releasedPenGestureClosesAndSelectsItsInterior() throws {
        let image = try PixelImage(width: 80, height: 80, rgba: Array(repeating: [UInt8(240), 240, 240, 255], count: 80 * 80).flatMap { $0 })
        let canvas = CanvasImageView()
        var selection = RegionSelection(width: 80, height: 80)
        canvas.configure(image: image, selection: selection, tool: .pen, enabled: true)
        canvas.onSelection = { selection = $0 }
        try gesture([.init(x: 20, y: 20), .init(x: 60, y: 20), .init(x: 60, y: 60), .init(x: 20, y: 60), .init(x: 20, y: 22)], on: canvas)
        #expect(selection.coverage()[40 * 80 + 40] == 255)
        #expect(selection.coverage()[10 * 80 + 40] == 0)
        canvas.configure(image: image, selection: selection, tool: .pen, enabled: true)
        let bitmap = render(canvas)
        let closure = try #require(bitmap.colorAt(x: 20, y: 40)?.usingColorSpace(.deviceRGB))
        let interior = try #require(bitmap.colorAt(x: 40, y: 40)?.usingColorSpace(.deviceRGB))
        #expect(closure.redComponent > 0.8 && closure.greenComponent < 0.3 && closure.blueComponent < 0.3)
        #expect(abs(interior.redComponent - 240.0 / 255) < 0.02 && abs(interior.blueComponent - interior.redComponent) < 0.02)
    }

    @Test func collinearPenDragBeyondTheImageNeverCreatesARegion() throws {
        let image = try PixelImage(width: 200, height: 200, rgba: [UInt8](repeating: 255, count: 200 * 200 * 4))
        let canvas = CanvasImageView()
        var selection = RegionSelection(width: 200, height: 200)
        canvas.configure(image: image, selection: selection, tool: .pen, enabled: true)
        canvas.onSelection = { selection = $0 }
        try gesture([.init(x: 20, y: 20), .init(x: 240, y: 130), .init(x: 360, y: 190)], on: canvas)
        #expect(selection.isEmpty && !selection.canUndo && selection.outlines.isEmpty)
    }

    @Test func edgeCrossingPenGesturePreservesItsSlantedEdgesWhenClipped() throws {
        let image = try PixelImage(width: 200, height: 200, rgba: [UInt8](repeating: 255, count: 200 * 200 * 4))
        let canvas = CanvasImageView()
        var selection = RegionSelection(width: 200, height: 200)
        canvas.configure(image: image, selection: selection, tool: .pen, enabled: true)
        canvas.onSelection = { selection = $0 }
        try gesture([.init(x: 20, y: 20), .init(x: 240, y: 130), .init(x: 240, y: 190),
                     .init(x: 20, y: 80), .init(x: 20, y: 20)], on: canvas)
        let coverage = selection.coverage()
        // The original parallel edges are y = x/2 + 10 and y = x/2 + 70, including beyond the right edge.
        let mismatchedPixels = coverage.indices.filter { index in
            let x = Double(index % 200) + 0.5, y = Double(index / 200) + 0.5
            let expected: UInt8 = x >= 20 && y >= x / 2 + 10 && y < x / 2 + 70 ? 255 : 0
            return coverage[index] != expected
        }.count
        #expect(mismatchedPixels == 0)
        #expect(coverage[90 * 200 + 150] == 255)
        #expect(coverage[150 * 200 + 150] == 0)
    }

    @Test func penGestureRemainsInSourcePixelsAfterZoomAndPanAndRejectsTapsAndLines() throws {
        let image = try PixelImage(width: 160, height: 120, rgba: [UInt8](repeating: 255, count: 160 * 120 * 4))
        let scroll = CanvasScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        scroll.fitToWindow = false
        for scale in [0.5, 1.0, 2.0, 3.0] {
            var selection = RegionSelection(width: 160, height: 120)
            scroll.canvas.configure(image: image, selection: selection, tool: .pen, enabled: true)
            scroll.setMagnification(scale, centeredAt: NSPoint(x: 80, y: 60))
            scroll.contentView.scroll(to: NSPoint(x: 20, y: 10))
            scroll.canvas.onSelection = { selection = $0 }
            try gesture([.init(x: 40, y: 30), .init(x: 120, y: 30), .init(x: 120, y: 90), .init(x: 40, y: 90), .init(x: 40, y: 31)], on: scroll.canvas)
            #expect(selection.coverage().filter { $0 == 255 }.count == 80 * 60)
            #expect(selection.coverage()[60 * 160 + 80] == 255 && selection.coverage()[20 * 160 + 80] == 0)
        }
        for points: [NSPoint] in [[.init(x: 40, y: 30), .init(x: 40, y: 30)],
                                  [.init(x: 20, y: 20), .init(x: 40, y: 40), .init(x: 60, y: 60)]] {
            var selection = RegionSelection(width: 160, height: 120)
            scroll.canvas.configure(image: image, selection: selection, tool: .pen, enabled: true)
            scroll.canvas.onSelection = { selection = $0 }
            try gesture(points, on: scroll.canvas)
            #expect(selection.isEmpty && !selection.canUndo)
        }
    }

    @Test func clearingOrChangingTheToolCancelsAnUnreleasedGestureWithoutPhantomMarks() throws {
        let image = try PixelImage(width: 80, height: 80, rgba: [UInt8](repeating: 255, count: 80 * 80 * 4))
        let canvas = CanvasImageView()
        var selection = RegionSelection(width: 80, height: 80)
        selection.addRectangle(from: .init(x: 5, y: 5), to: .init(x: 10, y: 10))
        canvas.configure(image: image, selection: selection, tool: .pen, enabled: true)
        canvas.onSelection = { selection = $0 }
        try send(.leftMouseDown, point: .init(x: 20, y: 20), to: canvas)
        try send(.leftMouseDragged, point: .init(x: 60, y: 20), to: canvas)
        selection.clear()
        canvas.configure(image: image, selection: selection, tool: .pen, enabled: true)
        try send(.leftMouseUp, point: .init(x: 40, y: 60), to: canvas)
        #expect(selection.isEmpty && selection.outlines.isEmpty)
        try send(.leftMouseDown, point: .init(x: 20, y: 20), to: canvas)
        try send(.leftMouseDragged, point: .init(x: 60, y: 20), to: canvas)
        canvas.configure(image: image, selection: selection, tool: .rectangle, enabled: true)
        try send(.leftMouseUp, point: .init(x: 40, y: 60), to: canvas)
        #expect(selection.isEmpty && !selection.canUndo)
        let bitmap = render(canvas)
        #expect(bitmap.colorAt(x: 40, y: 20) == bitmap.colorAt(x: 40, y: 40))
    }

    @Test func viewConversionKeepsImagePointStableAcrossMagnificationAndPan() {
        let scroll = CanvasScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.canvas.frame = NSRect(x: 0, y: 0, width: 1600, height: 1200)
        scroll.fitToWindow = false
        for magnification in [0.5, 1.0, 2.0, 3.0] {
            scroll.setMagnification(magnification, centeredAt: NSPoint(x: 700, y: 500))
            scroll.contentView.scroll(to: NSPoint(x: 80, y: 60))
            let imagePoint = NSPoint(x: 345, y: 267)
            let visiblePoint = scroll.contentView.convert(imagePoint, from: scroll.canvas)
            let converted = scroll.canvas.imagePoint(from: visiblePoint, in: scroll.contentView)
            #expect(abs(converted.x - 345) < 0.001)
            #expect(abs(converted.y - 267) < 0.001)
        }
    }
    @Test func fitCanDisplayExtremelyWideValidImages() {
        let scroll = CanvasScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.canvas.frame = NSRect(x: 0, y: 0, width: 100_000, height: 100)
        scroll.apply(.fit)
        #expect(scroll.magnification < 0.01)
        #expect(scroll.canvas.frame.width * scroll.magnification <= scroll.contentView.frame.width)
    }

    @Test func fitAndActualSizeUsePixelSizedDocument() {
        let scroll = CanvasScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.canvas.frame = NSRect(x: 0, y: 0, width: 1600, height: 1200)
        scroll.apply(.fit)
        #expect(scroll.magnification < 0.5)
        scroll.apply(.actualSize)
        #expect(scroll.magnification == 1)
        #expect(scroll.canvas.frame.width == 1600)
        scroll.apply(.zoomIn)
        #expect(scroll.magnification > 1)
        scroll.apply(.zoomOut)
        #expect(abs(scroll.magnification - 1) < 0.001)
    }
    @Test func transparentPixelsRevealCheckerboardAndOpaquePixelsCoverIt() throws {
        var rgba = [UInt8](repeating: 0, count: 48 * 16 * 4)
        for y in 0..<16 { for x in 24..<48 {
            let offset = (y * 48 + x) * 4
            rgba[offset] = 255; rgba[offset + 3] = 255
        } }
        let image = try PixelImage(width: 48, height: 16, rgba: rgba)
        let canvas = CanvasImageView()
        canvas.configure(image: image, selection: .init(width: 48, height: 16), tool: .pan, enabled: true)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 16, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 48 * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        #expect(bitmap.colorAt(x: 2, y: 2) != bitmap.colorAt(x: 14, y: 2))
        #expect(bitmap.colorAt(x: 26, y: 2) == bitmap.colorAt(x: 38, y: 2))
    }

}
