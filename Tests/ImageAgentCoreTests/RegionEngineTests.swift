import Foundation
import Testing
@testable import ImageAgentCore

func regionTool(action: String = "edit", reference: String?, model: String = "gpt-image-2", quality: String = "auto") throws -> HTTPResponse {
    try plannedTool("edit_image", model: model, reference: reference, extra: ["action": .string(action), "size": .string("auto"), "quality": .string(quality)])
}
func imageReply(_ bytes: Data) -> HTTPResponse { httpJSON("{\"data\":[{\"b64_json\":\"\(bytes.base64EncodedString())\"}]}") }
func middleSelection(width: Int, height: Int) -> RegionSelection {
    var selection = RegionSelection(width: width, height: height)
    selection.addRectangle(from: .init(x: Double(width / 3), y: Double(height / 3)), to: .init(x: Double(width * 2 / 3), y: Double(height * 2 / 3)))
    return selection
}

@Suite struct RegionEngineTests {
    @Test func filledPenSendsAnEditableInteriorAndSavesChangedCenterWithEveryOutsidePixelIntact() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths), conversation = try store.createConversation()
        let base = try colorGrid(width: 64, height: 48), originalBytes = try base.pngData()
        let original = try store.saveImage(originalBytes, conversationID: conversation.id, source: .imported)
        var selection = RegionSelection(width: 64, height: 48)
        selection.addPen(points: [.init(x: 8, y: 8), .init(x: 56, y: 8), .init(x: 56, y: 40), .init(x: 8, y: 40), .init(x: 8, y: 9)])
        let patch = try PixelImage(width: 3, height: 2, rgba: Array(repeating: [UInt8(5), 10, 240, 255], count: 6).flatMap { $0 }).pngData()
        let transport = RecordingTransport([try regionTool(reference: original.id), imageReply(patch)])
        let engine = AgentEngine(store: store, client: try APIClient(baseURL: "https://example.test", apiKey: "dummy", transport: transport))
        let outcome = try await engine.submit(.init(conversationID: conversation.id, text: "Change the head inside the contour", regionEdit: .init(assetID: original.id, selection: selection)))
        let asset = try #require(outcome.assets.first)
        #expect(outcome.run.stage == .completed && asset.parentAssetID == original.id)
        let result = try PixelImage(data: Data(contentsOf: store.assetURL(asset)))
        #expect(pixel(result, 32, 24) == [5, 10, 240, 255])
        let snapshot = try RegionEditSnapshot(base: base, selection: selection)
        for y in 0..<48 { for x in 0..<64 where snapshot.coverage[y * 64 + x] == 0 {
            #expect(pixel(result, x, y) == pixel(base, x, y))
        } }
        let requests = await transport.requests
        #expect(requests.count == 2 && requests[1].url?.path == "/v1/images/edits")
        let body = try #require(requests[1].httpBody)
        #expect(body.range(of: snapshot.imagePNG) != nil && body.range(of: snapshot.maskPNG) != nil)
        let mask = try PixelImage(data: snapshot.maskPNG)
        #expect(pixel(mask, 32 - snapshot.roi.x, 24 - snapshot.roi.y)[3] == 0)
        #expect(try Data(contentsOf: store.assetURL(original)) == originalBytes)
        #expect(try Data(contentsOf: #require(store.recoveryURL(outcome.run))) == patch)
    }

    @Test func sendsOnlyCroppedPixelsAndMaskThenSavesFullChildInOriginConversation() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation(); let other = try store.createConversation()
        let base = try colorGrid(width: 90, height: 60)
        let originalBytes = try base.pngData()
        let original = try store.saveImage(originalBytes, conversationID: conversation.id, source: .imported)
        let selection = middleSelection(width: 90, height: 60)
        let patch = try PixelImage(width: 1, height: 1, rgba: [0, 0, 240, 255]).pngData()
        let transport = RecordingTransport([try regionTool(reference: original.id, model: ImageModel.flare.rawValue, quality: "high"), imageReply(patch)])
        let client = try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport)
        let outcome = try await AgentEngine(store: store, client: client).submit(.init(conversationID: conversation.id, text: "改成蓝色", selection: .init(model: .flare, size: .landscape, quality: .high), regionEdit: .init(assetID: original.id, selection: selection)))
        #expect(outcome.run.stage == .completed)
        let asset = try #require(outcome.assets.first)
        #expect(asset.parentAssetID == original.id && asset.conversationID == conversation.id)
        #expect(asset.width == 90 && asset.height == 60 && asset.requestedSize == "auto")
        #expect(try store.assets(in: other.id).isEmpty)
        #expect(try Data(contentsOf: store.assetURL(original)) == originalBytes)
        let result = try PixelImage(data: Data(contentsOf: store.assetURL(asset)))
        let coverage = selection.coverage()
        for y in 0..<60 { for x in 0..<90 where coverage[y * 90 + x] == 0 { #expect(pixel(result, x, y) == pixel(base, x, y)) } }
        let requests = await transport.requests
        #expect(requests.count == 2 && requests[1].url?.path == "/v1/images/edits")
        let expected = try RegionEditSnapshot(base: base, selection: selection)
        #expect(expected.roi.width < base.width && expected.roi.height < base.height)
        let body = try #require(requests[1].httpBody)
        #expect(body.range(of: expected.imagePNG) != nil && body.range(of: expected.maskPNG) != nil)
        #expect(String(decoding: body, as: UTF8.self).contains("name=\"mask\"; filename=\"mask.png\""))
        let recovery = try #require(outcome.run.recoveryRelativePath)
        #expect(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent(recovery).path))
        #expect(try Data(contentsOf: paths.root.appendingPathComponent(recovery)) == patch)
    }

    @Test func rejectsPlannerRetargetingGenerationReplyAndModelChangeBeforeImageCall() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
        let base = try colorGrid(width: 9, height: 9)
        let original = try store.saveImage(base.pngData(), conversationID: conversation.id, source: .imported)
        let other = try store.saveImage(base.pngData(), conversationID: conversation.id, source: .imported)
        for reply in [try regionTool(action: "generate", reference: nil), try regionTool(action: "reply", reference: original.id), try regionTool(reference: other.id), try regionTool(reference: original.id, model: "gpt-image-2.5")] {
            let transport = RecordingTransport([reply])
            let client = try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport)
            let outcome = try await AgentEngine(store: store, client: client).submit(.init(conversationID: conversation.id, text: "改色", regionEdit: .init(assetID: original.id, selection: middleSelection(width: 9, height: 9))))
            #expect(outcome.run.stage == .failed && outcome.assets.isEmpty)
            #expect(await transport.requests.count == 1)
        }
    }

    @Test func rejectsForeignDeletedAndEmptyTargetsBeforePlanning() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation(); let other = try store.createConversation()
        let original = try store.saveImage(colorGrid().pngData(), conversationID: conversation.id, source: .imported)
        let transport = RecordingTransport([])
        let engine = AgentEngine(store: store, client: try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport))
        await #expect(throws: (any Error).self) { try await engine.submit(.init(conversationID: other.id, text: "改色", regionEdit: .init(assetID: original.id, selection: middleSelection(width: 6, height: 5)))) }
        await #expect(throws: (any Error).self) { try await engine.submit(.init(conversationID: conversation.id, text: "改色", regionEdit: .init(assetID: original.id, selection: .init(width: 6, height: 5)))) }
        var invalidPen = RegionSelection(width: 6, height: 5)
        invalidPen.addPen(points: [.init(x: 1, y: 1), .init(x: 2, y: 2), .init(x: 3, y: 3)])
        await #expect(throws: (any Error).self) { try await engine.submit(.init(conversationID: conversation.id, text: "改色", regionEdit: .init(assetID: original.id, selection: invalidPen))) }
        try store.deleteConversation(conversation.id)
        await #expect(throws: (any Error).self) { try await engine.submit(.init(conversationID: conversation.id, text: "改色", regionEdit: .init(assetID: original.id, selection: middleSelection(width: 6, height: 5)))) }
        #expect(await transport.requests.isEmpty)
    }

    @Test func cancellationAfterReturnedPatchPreservesRawAndFullResultWithoutRetry() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
        let original = try store.saveImage(colorGrid().pngData(), conversationID: conversation.id, source: .imported)
        let transport = RecordingTransport([try regionTool(reference: original.id), imageReply()], onRequest: { _, count in if count == 2 { withUnsafeCurrentTask { $0?.cancel() } } })
        let engine = AgentEngine(store: store, client: try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport))
        let task = Task { try await engine.submit(.init(conversationID: conversation.id, text: "改色", regionEdit: .init(assetID: original.id, selection: middleSelection(width: 6, height: 5)))) }
        let outcome = try await task.value
        #expect(outcome.run.stage == .cancelled && outcome.assets.count == 1)
        let recovery = try #require(outcome.run.recoveryRelativePath)
        #expect(try Data(contentsOf: paths.root.appendingPathComponent(recovery)) == testPNG)
        #expect(await transport.requests.count == 2)
    }

    @Test func unexpectedNativeImageRemainsUnverifiedAndNeverCompletesRegionEdit() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
        let original = try store.saveImage(colorGrid().pngData(), conversationID: conversation.id, source: .imported)
        let transport = RecordingTransport([httpJSON("{\"output\":[{\"type\":\"image_generation_call\",\"result\":\"\(testPNG.base64EncodedString())\"}]}")])
        let engine = AgentEngine(store: store, client: try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport))
        let outcome = try await engine.submit(.init(conversationID: conversation.id, text: "改色", regionEdit: .init(assetID: original.id, selection: middleSelection(width: 6, height: 5))))
        #expect(outcome.run.stage == .failed)
        #expect(outcome.assets.first?.modelVerified == false)
        #expect(outcome.assets.first?.width == 1)
        #expect(outcome.run.error?.contains("局部") == true)
        #expect(await transport.requests.count == 1)
    }

    @Test func nativeUnverifiedBytesSurviveFailureRegisteringTheRecoveredAsset() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
        let original = try store.saveImage(colorGrid().pngData(), conversationID: conversation.id, source: .imported)
        let sourceDirectory = paths.assets.appendingPathComponent(conversation.id)
        let backup = paths.root.appendingPathComponent("source-backup")
        let native = httpJSON("{\"output\":[{\"type\":\"image_generation_call\",\"result\":\"\(testPNG.base64EncodedString())\"}]}")
        let transport = RecordingTransport([native], onRequest: { _, _ in
            try FileManager.default.moveItem(at: sourceDirectory, to: backup)
            try Data("block only asset registration".utf8).write(to: sourceDirectory)
        })
        let engine = AgentEngine(store: store, client: try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport))
        let outcome = try await engine.submit(.init(conversationID: conversation.id, text: "改色", regionEdit: .init(assetID: original.id, selection: middleSelection(width: 6, height: 5))))
        #expect(outcome.run.stage == .failed && outcome.assets.isEmpty)
        let recovery = try #require(try store.recoveryURL(outcome.run))
        #expect(try Data(contentsOf: recovery) == testPNG)
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: recovery.deletingLastPathComponent().appendingPathComponent("region.json")))
        #expect(manifest["modelVerified"] == .bool(false))
        #expect(outcome.run.error?.contains("未验证") == true)
        #expect(await transport.requests.count == 1)
    }

    @Test func allRegionalNativeImagesReachDiskBeforeFirstAssetRegistrationCanFail() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
        let original = try store.saveImage(colorGrid().pngData(), conversationID: conversation.id, source: .imported)
        let secondImage = try colorGrid(width: 2, height: 1).pngData()
        #expect(secondImage != testPNG)
        let sourceDirectory = paths.assets.appendingPathComponent(conversation.id)
        let backup = paths.root.appendingPathComponent("source-backup")
        let output: JSONValue = .object(["output": .array([testPNG, secondImage].map { bytes in
            .object(["type": .string("image_generation_call"), "result": .string(bytes.base64EncodedString())])
        })])
        let native = HTTPResponse(data: try JSONEncoder().encode(output), statusCode: 200)
        let transport = RecordingTransport([native], onRequest: { _, _ in
            try FileManager.default.moveItem(at: sourceDirectory, to: backup)
            try Data("block the first asset registration".utf8).write(to: sourceDirectory)
        })
        let engine = AgentEngine(store: store, client: try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport))
        let outcome = try await engine.submit(.init(conversationID: conversation.id, text: "改色", regionEdit: .init(assetID: original.id, selection: middleSelection(width: 6, height: 5))))
        #expect(outcome.run.stage == .failed && outcome.assets.isEmpty && outcome.run.resultAssetIDs.isEmpty)
        let directory = paths.root.appendingPathComponent("recovery/\(outcome.run.id)")
        let firstRecovered = try? Data(contentsOf: directory.appendingPathComponent("native-1.png"))
        let secondRecovered = try? Data(contentsOf: directory.appendingPathComponent("native-2.png"))
        #expect(firstRecovered == testPNG)
        #expect(secondRecovered == secondImage)
        let recovered = try #require(secondRecovered)
        #expect(try DecodedImage(data: recovered).width == 2)
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: directory.appendingPathComponent("region.json")))
        #expect(manifest["modelVerified"] == .bool(false))
        #expect(outcome.run.error?.contains("未验证") == true)
        #expect(await transport.requests.count == 1)
        #expect(await transport.requests.filter { $0.url?.path.contains("/images/") == true }.isEmpty)
    }

    @Test func returnedPatchSurvivesFailureSavingTheCompositedAsset() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
        let original = try store.saveImage(colorGrid().pngData(), conversationID: conversation.id, source: .imported)
        let sourceDirectory = paths.assets.appendingPathComponent(conversation.id)
        let backup = paths.root.appendingPathComponent("source-backup")
        let transport = RecordingTransport([try regionTool(reference: original.id), imageReply()], onRequest: { _, count in
            if count == 2 {
                try FileManager.default.moveItem(at: sourceDirectory, to: backup)
                try Data("block only the full-asset save".utf8).write(to: sourceDirectory)
            }
        })
        let engine = AgentEngine(store: store, client: try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport))
        let outcome = try await engine.submit(.init(conversationID: conversation.id, text: "改色", regionEdit: .init(assetID: original.id, selection: middleSelection(width: 6, height: 5))))
        #expect(outcome.run.stage == .failed && outcome.assets.isEmpty)
        let recovery = try #require(try store.recoveryURL(outcome.run))
        #expect(try Data(contentsOf: recovery) == testPNG)
        #expect(outcome.message.text.contains("已保留"))
        #expect(await transport.requests.count == 2)
        try FileManager.default.removeItem(at: sourceDirectory)
        try FileManager.default.moveItem(at: backup, to: sourceDirectory)
        #expect(FileManager.default.fileExists(atPath: try store.assetURL(original).path))
    }

    @Test func patchRemainsRecoverableAfterLocalFinalizationFails() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
        let original = try store.saveImage(colorGrid().pngData(), conversationID: conversation.id, source: .imported)
        let transport = RecordingTransport([try regionTool(reference: original.id), imageReply()])
        let engine = AgentEngine(store: store, client: try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport), finalizer: TestFinalizer { _, _ in throw ImageAgentError.storage("local failure") })
        let outcome = try await engine.submit(.init(conversationID: conversation.id, text: "改色", regionEdit: .init(assetID: original.id, selection: middleSelection(width: 6, height: 5))))
        #expect(outcome.run.stage == .failed && outcome.assets.first?.width == 6)
        let relativePath = try #require(outcome.run.recoveryRelativePath)
        let url = paths.root.appendingPathComponent(relativePath)
        #expect(try Data(contentsOf: url) == testPNG)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(await transport.requests.count == 2)
    }
}

@Suite struct RegionRecoveryStorageTests {
    @Test func restartFindsPatchCommittedBeforeRunRecoveryPathWasSaved() throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
        let base = try colorGrid()
        let asset = try store.saveImage(base.pngData(), conversationID: conversation.id, source: .imported)
        let run = RunRecord(conversationID: conversation.id, stage: .editing, request: "regional edit")
        try store.saveRun(run)
        let path = try store.saveRegionPatch(testPNG, run: run, sourceAssetID: asset.id,
                                            snapshot: RegionEditSnapshot(base: base, selection: middleSelection(width: 6, height: 5)))
        let reopened = try SQLiteStore(paths: paths); try reopened.recoverInterruptedRuns()
        let recovered = try #require(try reopened.run(run.id))
        #expect(recovered.stage == .interrupted && recovered.recoveryRelativePath == path)
        #expect(try reopened.messages(in: conversation.id).last?.text.contains("局部") == true)
        #expect(try Data(contentsOf: #require(try reopened.recoveryURL(recovered))) == testPNG)
    }

    @Test func deletingConversationRemovesOnlyItsOwnedRecoveryImages() throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths)
        let first = try store.createConversation(); let second = try store.createConversation()
        let base = try colorGrid(); let selection = middleSelection(width: 6, height: 5)
        let snapshot = try RegionEditSnapshot(base: base, selection: selection)
        var recovery: [URL] = []
        for conversation in [first, second] {
            let asset = try store.saveImage(base.pngData(), conversationID: conversation.id, source: .imported)
            var run = RunRecord(conversationID: conversation.id, request: "regional edit")
            try store.saveRun(run)
            run.recoveryRelativePath = try store.saveRegionPatch(testPNG, run: run, sourceAssetID: asset.id, snapshot: snapshot)
            try store.saveRun(run)
            recovery.append(try #require(try store.recoveryURL(run)))
        }
        try store.deleteConversation(first.id)
        #expect(!FileManager.default.fileExists(atPath: recovery[0].deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: recovery[1].path))
        #expect(try store.conversation(second.id) != nil)
        #expect(try store.assets(in: second.id).count == 1)
    }
}
