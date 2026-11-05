import AppKit
import ImageIO
import ImageAgentCore

/// One clipboard item may advertise both PNG and TIFF; those are representations of one image.
enum PasteboardImageReader {
    static let maximumBytes = 100 * 1024 * 1024
    static func containsImage(_ pasteboard: NSPasteboard) -> Bool {
        (pasteboard.pasteboardItems ?? []).contains { $0.types.contains(.png) || $0.types.contains(.tiff) || $0.types.contains(.fileURL) }
    }
    static func read(_ pasteboard: NSPasteboard) throws -> Data? {
        let items = pasteboard.pasteboardItems ?? []
        let images = items.filter { item in item.types.contains(.png) || item.types.contains(.tiff) || item.types.contains(.fileURL) }
        guard !images.isEmpty else { return nil }
        guard images.count == 1, items.count == 1, let item = images.first else {
            throw ImageAgentError.invalidImage("请一次只粘贴一张图片；当前文字和参考附件已保留。")
        }
        if item.types.contains(.fileURL) {
            guard let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL else {
                throw ImageAgentError.invalidImage("请粘贴一张本地图片文件。")
            }
            return try readFile(url)
        }
        let type: NSPasteboard.PasteboardType = item.types.contains(.png) ? .png : .tiff
        guard let data = item.data(forType: type) else { throw ImageAgentError.invalidImage("剪贴板图片无法读取，请重新复制。") }
        return try validate(data)
    }
    static func readFile(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw ImageAgentError.invalidImage("请选择本地图片。") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maximumBytes else {
            throw ImageAgentError.invalidImage("图片文件必须有效且不超过 100 MiB。")
        }
        return try validate(Data(contentsOf: url, options: .mappedIfSafe))
    }
    static func validate(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumBytes, hasCompletePNGEnvelope(data),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw ImageAgentError.invalidImage("图片损坏、包含多帧或超过 100 MiB；原草稿和附件已保留。")
        }
        let image = try DecodedImage(data: data)
        // Screenshots commonly advertise TIFF; image edit services accept PNG reliably.
        if !["image/png", "image/jpeg", "image/webp"].contains(image.mediaType.lowercased()) { return try PixelImage(data: data).pngData() }
        return data
    }
    private static func hasCompletePNGEnvelope(_ bytes: Data) -> Bool {
        guard bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { return true }
        // ImageIO can decode a PNG missing IEND; that is still a truncated clipboard file.
        var offset = 8
        while offset <= bytes.count - 12 {
            let length = (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(bytes[offset + $1]) }
            guard Int(length) <= bytes.count - offset - 12 else { return false }
            if bytes[(offset + 4)..<(offset + 8)].elementsEqual([73, 69, 78, 68]) { return length == 0 }
            offset += Int(length) + 12
        }
        return false
    }

}
