import Foundation

/// Rolling copies of `state.json`.
///
/// There is one state file, rewritten on every change, and it holds every tab,
/// group and pinned URL. A logic bug that produces an empty snapshot overwrites
/// the good one and the previous contents are gone — which has already happened
/// once here: an archive sweep read stale timestamps and closed a full set of
/// Today tabs, and there was nothing to go back to.
///
/// So: before each write, the file that's about to be replaced is copied aside.
/// Cheap, and the copy is of a state that demonstrably loaded.
///
/// Two rules shape the rest:
///   • **Throttled**, because `save()` runs on nearly every interaction and a
///     backup per keystroke is churn, not safety.
///   • **Except when the tab count drops sharply**, which is the exact shape of
///     the failure this exists for. That case bypasses the throttle, because it's
///     the one moment a backup is worth more than the disk it costs.
enum StateBackups {
    static let keep = 12
    static let throttle: TimeInterval = 10 * 60
    /// A drop this large is treated as suspicious rather than intentional.
    static let suspiciousDrop = 3

    static var directory: URL { AppPaths.supportFile("backups") }

    struct Entry: Identifiable {
        var id: URL { url }
        let url: URL
        let date: Date
        /// Tabs in that snapshot, so a list of timestamps is actually readable.
        let tabCount: Int
        let bytes: Int
    }

    /// Should a copy be taken now? Pure, so the policy is testable.
    static func shouldBackUp(lastBackup: Date?, now: Date,
                             previousTabCount: Int, newTabCount: Int) -> Bool {
        if previousTabCount - newTabCount >= suspiciousDrop { return true }
        guard let lastBackup else { return true }
        return now.timeIntervalSince(lastBackup) >= throttle
    }

    /// Counts tabs in a snapshot without decoding the whole model — the backup
    /// list must not depend on the current `Snapshot` shape, or an old backup
    /// becomes unreadable the next time that struct changes.
    static func tabCount(in data: Data) -> Int {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return 0 }
        func count(_ nodes: Any?) -> Int {
            guard let list = nodes as? [[String: Any]] else { return 0 }
            return list.reduce(0) { total, node in
                total + (node["tab"] != nil ? 1 : 0) + count(node["children"])
            }
        }
        return count(root["todayNodes"]) + count(root["pinned"])
            + ((root["favorites"] as? [[String: Any]])?.count ?? 0)
    }

    @discardableResult
    static func record(existing url: URL, now: Date = Date()) -> URL? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.backupStamp.string(from: now)
        let target = directory.appendingPathComponent("state-\(stamp).json")
        do {
            try data.write(to: target, options: .atomic)
            prune()
            return target
        } catch {
            return nil
        }
    }

    static func list() -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey,
                                                        .fileSizeKey])) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey,
                                                               .fileSizeKey])
                let data = (try? Data(contentsOf: url)) ?? Data()
                return Entry(url: url,
                             date: values?.contentModificationDate ?? .distantPast,
                             tabCount: tabCount(in: data),
                             bytes: values?.fileSize ?? data.count)
            }
            .sorted { $0.date > $1.date }
    }

    /// Keeps the newest `keep`. Sorted by name, which is the timestamp, so this
    /// doesn't depend on filesystem dates being trustworthy.
    static func prune(keeping limit: Int = keep) {
        let urls = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard urls.count > limit else { return }
        for url in urls.dropFirst(limit) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Puts a backup back. The current file is copied aside first — restoring the
    /// wrong snapshot shouldn't be the mistake you can't undo either.
    static func restore(_ entry: Entry, to url: URL, now: Date = Date()) throws {
        record(existing: url, now: now)
        let data = try Data(contentsOf: entry.url)
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw NSError(domain: "Ark", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "That backup isn't readable JSON."])
        }
        try data.write(to: url, options: .atomic)
    }
}

extension ISO8601DateFormatter {
    /// Sortable, filename-safe, and readable: 20260820-142530.
    static let backupStamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay,
                                   .withTime, .withColonSeparatorInTime]
        return formatter
    }()
}
