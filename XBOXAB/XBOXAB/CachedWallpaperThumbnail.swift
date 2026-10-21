import SwiftUI
import AppKit
import CryptoKit
import ImageIO

/// The full URL (including its query) identifies immutable catalog artwork.
/// Cache hits do not make a network request, including after an app restart.
private actor WallpaperThumbnailCache {
    static let shared = WallpaperThumbnailCache()
    private var pending: [URL: Task<Data, Error>] = [:]

    func data(for url: URL) async throws -> Data {
        if let task = pending[url] { return try await task.value }
        let task = Task { try await readOrDownload(url) }
        pending[url] = task
        defer { pending[url] = nil }
        return try await task.value
    }

    private func readOrDownload(_ url: URL) async throws -> Data {
        let directory = try FileManager.default.url(for: .cachesDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("XBOXAB/WallpaperThumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(name)
        if let cached = try? Data(contentsOf: file) {
            if isImage(cached) { return cached }
            try? FileManager.default.removeItem(at: file)
        }
        // Reuse artwork downloaded by the previous application name.
        let legacyFile = directory.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("XBEditor/WallpaperThumbnails").appendingPathComponent(name)
        if let cached = try? Data(contentsOf: legacyFile), isImage(cached) {
            try cached.write(to: file, options: .atomic)
            return cached
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode), isImage(data) else {
            throw URLError(.cannotDecodeContentData)
        }
        // Atomic replacement prevents an interrupted write becoming a cache hit.
        try data.write(to: file, options: .atomic)
        return data
    }

    private func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }
}

struct CachedWallpaperThumbnail: View {
    let url: URL
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if failed {
                Color.primary.opacity(0.06)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            } else {
                Color.primary.opacity(0.06)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: url) {
            image = nil
            failed = false
            do {
                let data = try await WallpaperThumbnailCache.shared.data(for: url)
                try Task.checkCancellation()
                guard let decoded = NSImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                image = decoded
            } catch is CancellationError {
                // A scrolled-away card may still finish populating the disk cache.
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}
