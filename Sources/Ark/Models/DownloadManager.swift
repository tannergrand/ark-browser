import Foundation
import Observation
import WebKit

/// Tracks WebKit downloads and lands them in ~/Downloads.
@Observable
final class DownloadManager: NSObject {
    @Observable
    final class Item: Identifiable {
        let id = UUID()
        var filename: String
        var url: URL?
        var destination: URL?
        var bytesWritten: Int64 = 0
        var bytesExpected: Int64 = 0
        var finished = false
        var failure: String?

        init(filename: String, url: URL?) {
            self.filename = filename
            self.url = url
        }

        var progress: Double {
            bytesExpected > 0 ? Double(bytesWritten) / Double(bytesExpected) : 0
        }

        var subtitle: String {
            if let failure { return failure }
            if finished { return ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file) }
            if bytesExpected > 0 {
                return "\(ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file)) of "
                     + ByteCountFormatter.string(fromByteCount: bytesExpected, countStyle: .file)
            }
            return "Downloading…"
        }
    }

    var items: [Item] = []
    /// Set when a download starts, so the UI can surface the panel once.
    var hasUnseen = false

    var active: Int { items.filter { !$0.finished && $0.failure == nil }.count }

    @ObservationIgnored private var map: [ObjectIdentifier: Item] = [:]
    @ObservationIgnored private var observations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]

    func register(_ download: WKDownload) {
        download.delegate = self
    }

    private func item(for download: WKDownload) -> Item? {
        map[ObjectIdentifier(download)]
    }

    func clearFinished() {
        items.removeAll { $0.finished || $0.failure != nil }
    }

    func reveal(_ item: Item) {
        guard let dest = item.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dest])
    }

    private static func uniqueDestination(for suggested: String) -> URL {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let name = suggested.isEmpty ? "download" : suggested
        var candidate = dir.appendingPathComponent(name)
        var counter = 1
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            candidate = dir.appendingPathComponent(next)
            counter += 1
        }
        return candidate
    }
}

extension DownloadManager: WKDownloadDelegate {
    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let destination = Self.uniqueDestination(for: suggestedFilename)
        let item = Item(filename: destination.lastPathComponent, url: response.url)
        item.destination = destination
        item.bytesExpected = response.expectedContentLength

        map[ObjectIdentifier(download)] = item
        observations[ObjectIdentifier(download)] = [
            download.progress.observe(\.completedUnitCount, options: [.new]) { progress, _ in
                Task { @MainActor in
                    item.bytesWritten = progress.completedUnitCount
                    if progress.totalUnitCount > 0 { item.bytesExpected = progress.totalUnitCount }
                }
            }
        ]

        Task { @MainActor in
            items.insert(item, at: 0)
            hasUnseen = true
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        Task { @MainActor in
            item.finished = true
            if let dest = item.destination,
               let size = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64 {
                item.bytesWritten = size
            }
        }
        cleanup(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error,
                  resumeData: Data?) {
        guard let item = item(for: download) else { return }
        Task { @MainActor in item.failure = error.localizedDescription }
        cleanup(download)
    }

    private func cleanup(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        observations[key]?.forEach { $0.invalidate() }
        observations[key] = nil
        map[key] = nil
    }
}
