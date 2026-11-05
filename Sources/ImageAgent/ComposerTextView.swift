import SwiftUI
import AppKit

/// Plain NSTextView retains AppKit's text input, selection, marked text and undo behavior.
final class ComposerNativeTextView: NSTextView {
    var onImagePaste: ((NSPasteboard) -> Void)?
    var onSubmit: (() -> Void)?
    var placeholder = "描述你的画面，或说说想怎样修改…"
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.png, .tiff, .fileURL] + super.readablePasteboardTypes
    }
    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if PasteboardImageReader.containsImage(pasteboard) { onImagePaste?(pasteboard); return true }
        return super.readSelection(from: pasteboard, type: type)
    }
    override func paste(_ sender: Any?) { paste(from: .general) }
    func paste(from pasteboard: NSPasteboard) {
        if PasteboardImageReader.containsImage(pasteboard) { onImagePaste?(pasteboard) }
        else { _ = readSelection(from: pasteboard, type: .string) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, event.modifierFlags.contains(.command), !hasMarkedText() { onSubmit?(); return }
        super.keyDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
                withAttributes: [.font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.placeholderTextColor])
        }
    }
}

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let focusID: UUID
    let conversationID: String?
    let onPaste: (NSPasteboard) -> Void
    let onSubmit: () -> Void
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let view = ComposerNativeTextView(frame: .zero)
        view.isRichText = false; view.importsGraphics = false; view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.drawsBackground = false; view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.textColor = .labelColor; view.textContainerInset = NSSize(width: 0, height: 5)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = context.coordinator
        view.string = text
        view.setAccessibilityLabel("创作需求输入框")
        let scroll = NSScrollView(); scroll.documentView = view; scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        context.coordinator.focusID = focusID
        context.coordinator.conversationID = conversationID
        updateHandlers(view)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ComposerNativeTextView else { return }
        updateHandlers(view)
        let switchedConversation = context.coordinator.conversationID != conversationID
        if switchedConversation { view.unmarkText(); context.coordinator.conversationID = conversationID }
        if switchedConversation || (view.string != text && !view.hasMarkedText()) {
            view.string = text; view.needsDisplay = true
            view.undoManager?.removeAllActions()
        }
        if context.coordinator.focusID != focusID {
            context.coordinator.focusID = focusID
            DispatchQueue.main.async { [weak view] in if let view { view.window?.makeFirstResponder(view) } }
        }
        context.coordinator.resize(view)
    }
    private func updateHandlers(_ view: ComposerNativeTextView) { view.onImagePaste = onPaste; view.onSubmit = onSubmit }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var focusID: UUID?
        var conversationID: String?
        init(_ parent: ComposerTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? ComposerNativeTextView else { return }
            parent.text = view.string; view.needsDisplay = true; resize(view)
        }
        func resize(_ view: NSTextView) {
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let measured = min(144, max(48, ceil(layout.usedRect(for: container).height + view.textContainerInset.height * 2)))
            if parent.height != measured {
                DispatchQueue.main.async { [weak self] in self?.parent.height = measured }
            }
        }
    }
}
