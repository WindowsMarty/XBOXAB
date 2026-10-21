import Foundation

/// Explicit delegate-driven task: async completion-handler download helpers can
/// intercept download delegate events. All mutable transfer state is lock protected.
private nonisolated final class WallpaperDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @MainActor @Sendable (Double?) -> Void
    private let destination: URL
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var result: Result<URLResponse, Error>?
    private var cancelled = false

    init(destination: URL, report: @escaping @MainActor @Sendable (Double?) -> Void) {
        self.destination = destination
        self.report = report
    }

    func start(url: URL) async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: url)
                let shouldCancel = lock.withLock {
                    self.continuation = continuation
                    self.task = task
                    return cancelled
                }
                if shouldCancel { task.cancel() }
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        let activeTask = lock.withLock {
            cancelled = true
            return task
        }
        activeTask?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0
            ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil
        Task { @MainActor [report] in report(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // URLSession removes this temporary file after the callback returns.
        // Move it synchronously before resuming the awaiting caller.
        let outcome = Result<URLResponse, Error> {
            guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
            try FileManager.default.moveItem(at: location, to: destination)
            return response
        }
        lock.withLock { result = outcome }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (waiting, outcome) = lock.withLock {
            let outcome: Result<URLResponse, Error>
            if cancelled { outcome = .failure(CancellationError()) }
            else if let error { outcome = .failure(error) }
            else { outcome = result ?? .failure(URLError(.badServerResponse)) }
            let waiting = continuation
            continuation = nil
            self.task = nil
            return (waiting, outcome)
        }
        session.finishTasksAndInvalidate()
        waiting?.resume(with: outcome)
    }
}

struct OfficialWallpaper: Decodable, Identifiable {
    let title: String
    let thumbnailUrl: URL
    let bundleUrl: URL
    let category: String
    let requirement: String?
    // The resource URL remains unique even if display IDs in the feed repeat.
    var id: URL { bundleUrl }
    var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedCategory: String { category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    var isLimited: Bool { !(requirement?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
}

@MainActor
enum OfficialWallpaperCatalog {
    private struct Catalog: Decodable {
        let items: [OfficialWallpaper]
    }

    struct DownloadedProject {
        let folder: URL
        let temporaryDirectory: URL
    }

    static func load() throws -> [OfficialWallpaper] {
        guard let url = Bundle.main.url(forResource: "OfficialWallpapers", withExtension: "json") else {
            throw failure("应用缺少官方壁纸列表")
        }
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url)).items
    }

    static func download(_ wallpaper: OfficialWallpaper,
                         progress: @escaping @MainActor @Sendable (Double?) -> Void) async throws -> DownloadedProject {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("XBOXAB-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: directory) } }
        let archive = directory.appendingPathComponent("wallpaper.zip")
        progress(nil)
        let transfer = WallpaperDownloadProgress(destination: archive, report: progress)
        let response = try await transfer.start(url: wallpaper.bundleUrl)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw failure("官方壁纸下载失败，请稍后重试")
        }
        try Task.checkCancellation()
        progress(1)
        let extracted = directory.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, extracted.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() }
            catch { continuation.resume(returning: -1) }
        }
        try Task.checkCancellation()
        guard status == 0 else { throw failure("无法解压官方壁纸资源") }
        let folder = try findProject(in: extracted)
        succeeded = true
        return DownloadedProject(folder: folder, temporaryDirectory: directory)
    }

    // DirectoryEnumerator's synchronous iterator is unavailable directly in an
    // async function under Swift 6. Keep its entire lifetime in this sync scope.
    private static func findProject(in extracted: URL) throws -> URL {
        // Bundles may contain either a root project or a nested project folder.
        guard let enumerator = FileManager.default.enumerator(at: extracted,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            throw failure("无法读取官方壁纸资源")
        }
        var candidates = Set<URL>()
        for case let url as URL in enumerator {
            if url.lastPathComponent == "__MACOSX" { enumerator.skipDescendants(); continue }
            if url.lastPathComponent == "DynamicConfig" || url.lastPathComponent == "EditorConfig.json" {
                let folder = url.deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: folder.appendingPathComponent("DynamicBg.png").path) {
                    candidates.insert(folder)
                }
            }
        }
        guard let folder = candidates.sorted(by: { $0.path < $1.path }).first else {
            throw failure("该资源包中没有可转换的壁纸工程")
        }
        return folder
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "OfficialWallpaperCatalog", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
