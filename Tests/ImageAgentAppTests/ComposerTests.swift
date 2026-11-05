import AppKit
import Testing
import ImageAgentCore
@testable import ImageAgent

func frontendPNG() throws -> Data {
    try PixelImage(width: 4, height: 3, rgba: [UInt8](repeating: 160, count: 4 * 3 * 4)).pngData()
}

@MainActor @Suite struct ComposerTests {
    private func board() -> NSPasteboard { NSPasteboard(name: .init("ImageAgentPasteTest-\(UUID().uuidString)")) }
    private func fixture() throws -> (AppModel, SQLiteStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImageAgentComposer-\(UUID().uuidString)")
        let store = try SQLiteStore(paths: .init(root: root)); let chat = try store.createConversation()
        let model = AppModel(store: store); model.selectedID = chat.id; model.draft = "保留正在写的文字"
        return (model, store, root)
    }
    @Test func pngScreenshotPastesAsReferenceWithoutSendingOrClearingText() throws {
        let (model, store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pasteboard = board(); defer { pasteboard.releaseGlobally() }
        pasteboard.setData(try frontendPNG(), forType: .png)
        #expect(model.pasteReference(from: pasteboard))
        #expect(model.selectedReference?.width == 4)
        #expect(model.draft == "保留正在写的文字")
        #expect(try store.messages(in: model.selectedID!).isEmpty)
    }
    @Test func tiffScreenshotAndSingleLocalImageAreAccepted() throws {
        let pasteboard = board(); defer { pasteboard.releaseGlobally() }
        let png = try frontendPNG()
        let image = try #require(NSImage(data: png))
        pasteboard.setData(image.tiffRepresentation!, forType: .tiff)
        let data = try #require(try PasteboardImageReader.read(pasteboard))
        #expect(try DecodedImage(data: data).mediaType == "image/png")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ImageAgent-paste-\(UUID()).png")
        try frontendPNG().write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        pasteboard.clearContents(); pasteboard.writeObjects([url as NSURL])
        #expect(try PasteboardImageReader.read(pasteboard) == frontendPNG())
    }
    @Test func textPasteRetainsOrdinaryTextPath() throws {
        let pasteboard = board(); defer { pasteboard.releaseGlobally() }
        pasteboard.setString("中文\nordinary text", forType: .string)
        #expect(try PasteboardImageReader.read(pasteboard) == nil)
    }
    @Test func attachmentBusyAndEditorConflictsPreserveDraftAndReference() throws {
        let (model, store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pasteboard = board(); defer { pasteboard.releaseGlobally() }
        pasteboard.setData(try frontendPNG(), forType: .png)
        let original = try store.saveImage(frontendPNG(), conversationID: model.selectedID!, source: .imported)
        model.refresh(); model.referenceID = original.id
        #expect(!model.pasteReference(from: pasteboard))
        #expect(model.referenceID == original.id && model.error != nil)
        model.referenceID = nil; model.error = nil; model.isBusy = true
        #expect(!model.pasteReference(from: pasteboard))
        #expect(model.referenceID == nil && model.error != nil)
        #expect(!model.useReference(original))
        model.isBusy = false; model.openImageWorkspace(original); model.error = nil
        #expect(!model.pasteReference(from: pasteboard))
        #expect(model.draft == "保留正在写的文字" && model.referenceID == nil)
        #expect(try store.assets(in: model.selectedID!).count == 1)
    }
    @Test func corruptOversizedAndMultipleImagesAreRejectedWithoutMutations() throws {
        let (model, store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pasteboard = board(); defer { pasteboard.releaseGlobally() }
        for data in [Data("invalid png".utf8), Data(try frontendPNG().dropLast(12)), Data(repeating: 0, count: 100 * 1024 * 1024 + 1)] {
            pasteboard.clearContents(); pasteboard.setData(data, forType: .png)
            #expect(!model.pasteReference(from: pasteboard))
            #expect(model.error != nil && model.referenceID == nil)
        }
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        first.setData(try frontendPNG(), forType: .png); second.setData(try frontendPNG(), forType: .png)
        pasteboard.clearContents(); pasteboard.writeObjects([first, second])
        #expect(!model.pasteReference(from: pasteboard))
        #expect(model.error != nil && model.draft == "保留正在写的文字" && model.referenceID == nil)
        #expect(try store.assets(in: model.selectedID!).isEmpty)
    }
    @Test func nativeTextPasteUndoAndImagePastePreservePlainTextAndSelection() throws {
        let pasteboard = board(); defer { pasteboard.releaseGlobally() }
        let view = ComposerNativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        view.isRichText = false; view.allowsUndo = true
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view; window.makeFirstResponder(view)
        view.string = "原文："; view.setSelectedRange(NSRange(location: 3, length: 0))
        pasteboard.setString("中文\nnext line", forType: .string); view.paste(from: pasteboard)
        #expect(view.string == "原文：中文\nnext line")
        #expect(view.undoManager?.canUndo == true)
        view.undoManager?.undo(); #expect(view.string == "原文：")
        let originalRange = view.selectedRange(); var imagePastes = 0
        view.onImagePaste = { _ in imagePastes += 1 }
        pasteboard.clearContents(); pasteboard.setData(try frontendPNG(), forType: .png)
        view.paste(from: pasteboard)
        #expect(imagePastes == 1 && view.string == "原文：" && view.selectedRange() == originalRange)
        var submissions = 0; view.onSubmit = { submissions += 1 }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        view.keyDown(with: event); #expect(submissions == 1)
        view.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        view.keyDown(with: event); #expect(submissions == 1)
    }

    @Test func nativePasteCommandRecognizesImageOnlyBoardsAndRoutesStandardReadSelection() throws {
        let pasteboard = board(); defer { pasteboard.releaseGlobally() }
        pasteboard.setData(try frontendPNG(), forType: .png)
        let view = ComposerNativeTextView(frame: .zero); view.isRichText = false; view.importsGraphics = false
        var pasted = false; view.onImagePaste = { _ in pasted = true }
        #expect(view.readablePasteboardTypes.contains(.png))
        #expect(view.readablePasteboardTypes.contains(.tiff))
        #expect(view.readablePasteboardTypes.contains(.fileURL))
        #expect(view.readSelection(from: pasteboard, type: .png))
        #expect(pasted && view.string.isEmpty)
    }

}
