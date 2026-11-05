import SwiftUI
import AppKit
import ImageAgentCore

struct EditorCanvas: NSViewRepresentable {
    let image: PixelImage
    @Binding var selection: RegionSelection
    let tool: EditorTool
    let command: CanvasCommand
    @Binding var zoom: Double
    let enabled: Bool
    var onEscape: () -> Void = {}

    final class Coordinator {
        var commandID: UUID?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> CanvasScrollView {
        let view = CanvasScrollView()
        view.canvas.onSelection = { selection = $0 }
        view.canvas.onEscape = onEscape
        view.onZoom = { value in DispatchQueue.main.async { zoom = value } }
        return view
    }
    func updateNSView(_ view: CanvasScrollView, context: Context) {
        view.canvas.onSelection = { selection = $0 }
        view.canvas.onEscape = onEscape
        view.onZoom = { value in DispatchQueue.main.async { zoom = value } }
        view.canvas.configure(image: image, selection: selection, tool: tool, enabled: enabled)
        if context.coordinator.commandID != command.id {
            context.coordinator.commandID = command.id
            view.apply(command.action)
        }
    }
}

private final class CenteredClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        if let documentView {
            if documentView.frame.width < result.width { result.origin.x = (documentView.frame.width - result.width) / 2 }
            if documentView.frame.height < result.height { result.origin.y = (documentView.frame.height - result.height) / 2 }
        }
        return result
    }
}

final class CanvasScrollView: NSScrollView {
    let canvas = CanvasImageView()
    var fitToWindow = true
    var onZoom: ((Double) -> Void)?
    private var magnificationObservation: NSKeyValueObservation?
    private var programmaticZoom = false
    private var lastViewport = NSSize.zero
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = CenteredClipView()
        documentView = canvas
        hasVerticalScroller = true; hasHorizontalScroller = true
        autohidesScrollers = true; borderType = .noBorder
        drawsBackground = true; backgroundColor = NSColor(calibratedWhite: 0.065, alpha: 1)
        allowsMagnification = true; minMagnification = 0.05; maxMagnification = 16
        magnificationObservation = observe(\.magnification, options: [.new]) { [weak self] _, change in
            guard let self, let value = change.newValue else { return }
            if !self.programmaticZoom { self.fitToWindow = false }
            self.canvas.needsDisplay = true
            self.onZoom?(Double(value))
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let viewport = contentView.frame.size
        if viewport != lastViewport {
            lastViewport = viewport
            if fitToWindow { fit() }
        }
    }
    private func fit() {
        guard canvas.frame.width > 0, canvas.frame.height > 0, contentView.frame.width > 0, contentView.frame.height > 0 else { return }
        let scale = min(contentView.frame.width / canvas.frame.width, contentView.frame.height / canvas.frame.height) * 0.97
        minMagnification = min(0.05, scale)
        setZoom(scale, center: NSPoint(x: canvas.frame.midX, y: canvas.frame.midY))
    }
    private func setZoom(_ value: CGFloat, center: NSPoint? = nil) {
        programmaticZoom = true
        let visible = documentVisibleRect
        setMagnification(min(maxMagnification, max(minMagnification, value)), centeredAt: center ?? NSPoint(x: visible.midX, y: visible.midY))
        programmaticZoom = false
        onZoom?(Double(magnification))
    }
    func apply(_ action: CanvasAction) {
        switch action {
        case .fit: fitToWindow = true; fit()
        case .actualSize: fitToWindow = false; setZoom(1)
        case .zoomIn: fitToWindow = false; setZoom(magnification * 1.25)
        case .zoomOut: fitToWindow = false; setZoom(magnification / 1.25)
        }
    }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            fitToWindow = false
            let center = canvas.convert(event.locationInWindow, from: nil)
            setZoom(magnification * exp(event.scrollingDeltaY * 0.015), center: center)
        } else { super.scrollWheel(with: event) }
    }
}

final class CanvasImageView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var onSelection: ((RegionSelection) -> Void)?
    var onEscape: (() -> Void)?
    private var image: PixelImage?
    private var rendered: CGImage?
    private var selection = RegionSelection(width: 0, height: 0)
    private var tool = EditorTool.pan
    private var selectionEnabled = true
    private var stroke: [ImagePoint] = []
    private var start: ImagePoint?
    private var current: ImagePoint?
    private var lastWindowPoint: NSPoint?
    private var spacePanning = false
    private var draggingPan = false

    func configure(image: PixelImage, selection: RegionSelection, tool: EditorTool, enabled: Bool) {
        let imageChanged = self.image != image
        if imageChanged || self.selection != selection || self.tool != tool || !enabled { cancelGesture() }
        if imageChanged {
            self.image = image; rendered = try? image.cgImage()
            frame = NSRect(x: 0, y: 0, width: image.width, height: image.height)
        }
        self.selection = selection
        self.tool = tool; selectionEnabled = enabled
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
    private func drawImage(_ image: CGImage) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        context.restoreGState()
    }
    override func draw(_ dirtyRect: NSRect) {
        // Keep tiles near twelve screen points and limit work to the visible dirty area.
        let cell = 12 / max(enclosingScrollView?.magnification ?? 1, 0.0001)
        let visible = dirtyRect.intersection(bounds)
        NSColor(calibratedWhite: 0.24, alpha: 1).setFill(); visible.fill()
        if !visible.isEmpty {
            NSColor(calibratedWhite: 0.32, alpha: 1).setFill()
            for row in Int(floor(visible.minY / cell))..<Int(ceil(visible.maxY / cell)) {
                for column in Int(floor(visible.minX / cell))..<Int(ceil(visible.maxX / cell)) where (row + column).isMultiple(of: 2) {
                    NSRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell).intersection(visible).fill()
                }
            }
        }
        if let rendered { drawImage(rendered) }
        NSColor.red.setStroke()
        let lineWidth = 2 / max(enclosingScrollView?.magnification ?? 1, 0.0001)
        func drawOutline(_ outline: RegionSelection.Outline) {
            let path: NSBezierPath
            switch outline {
            case let .rectangle(a, b):
                path = NSBezierPath(rect: NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)))
            case let .pen(points):
                guard let first = points.first else { return }
                path = NSBezierPath(); path.move(to: NSPoint(x: first.x, y: first.y))
                for point in points.dropFirst() { path.line(to: NSPoint(x: point.x, y: point.y)) }
                path.close()
            }
            path.lineWidth = lineWidth; path.lineJoinStyle = .round; path.lineCapStyle = .round
            path.stroke()
        }
        for outline in selection.outlines { drawOutline(outline) }
        if tool == .rectangle, let a = start, let b = current {
            drawOutline(.rectangle(a, b))
        } else if tool == .pen, stroke.count > 1 {
            let path = NSBezierPath(); path.lineWidth = lineWidth; path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: NSPoint(x: stroke[0].x, y: stroke[0].y))
            for point in stroke.dropFirst() { path.line(to: NSPoint(x: point.x, y: point.y)) }
            path.stroke()
        }
    }
    /// NSView conversion already accounts for both scroll magnification and display backing scale.
    func imagePoint(from point: NSPoint, in view: NSView?) -> ImagePoint {
        let value = convert(point, from: view)
        return ImagePoint(x: value.x, y: value.y)
    }
    private func selectionPoint(for event: NSEvent) -> ImagePoint? {
        let point = imagePoint(from: event.locationInWindow, in: nil)
        guard point.x.isFinite, point.y.isFinite else { return nil }
        // Preserve edge geometry; RegionSelection clips the completed contour to the image.
        return point
    }
    private func cancelGesture() {
        start = nil; current = nil; stroke = []; lastWindowPoint = nil; draggingPan = false
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: (tool == .pan || spacePanning) ? .openHand : .crosshair) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        draggingPan = tool == .pan || spacePanning || !selectionEnabled
        if draggingPan { lastWindowPoint = event.locationInWindow; NSCursor.closedHand.set(); return }
        guard let point = selectionPoint(for: event) else { return }
        start = point; current = point
        if tool == .pen { stroke = [point] }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        if draggingPan, let last = lastWindowPoint, let scroll = enclosingScrollView {
            let magnification = scroll.magnification
            let origin = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to: NSPoint(x: origin.x - (event.locationInWindow.x - last.x) / magnification,
                                                  y: origin.y + (event.locationInWindow.y - last.y) / magnification))
            scroll.reflectScrolledClipView(scroll.contentView); lastWindowPoint = event.locationInWindow
            return
        }
        guard start != nil else { return }
        guard let point = selectionPoint(for: event) else { return }
        current = point
        if tool == .pen, stroke.last != point { stroke.append(point) }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { cancelGesture(); needsDisplay = true; window?.invalidateCursorRects(for: self) }
        guard !draggingPan, selectionEnabled, let start, let end = selectionPoint(for: event) else { return }
        var updated = selection
        if tool == .rectangle { updated.addRectangle(from: start, to: end) }
        else if tool == .pen { updated.addPen(points: stroke + (stroke.last == end ? [] : [end])) }
        onSelection?(updated)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() }
        else if event.keyCode == 49 { spacePanning = true; window?.invalidateCursorRects(for: self) }
        else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spacePanning = false; window?.invalidateCursorRects(for: self) }
        else { super.keyUp(with: event) }
    }
}
