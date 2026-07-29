import Foundation
import os.log

/// Bounded append-only file store for zone-crossing events that need to survive
/// moments when the consumer's JS/Dart runtime is torn down but the polyfence-core
/// native tracker is still alive.
///
/// Off when queueSize is 0 (append is a no-op). Drain always reads whatever is on
/// disk regardless of the current queueSize, so events queued before the caller
/// disabled the feature stay retrievable — the underlying log file is preserved
/// across a queueSize=0 window and only cleared by an explicit drainAll.
///
/// A dedicated serial queue serialises reads and writes; append and drainAll are
/// synchronous from the caller's perspective. drainAll dispatches onto the same
/// serialQueue as append, so a concurrent append cannot lose an event mid-drain.
///
/// After shutdown, in-flight writes are drained; further appends and drainAll
/// calls still work (serial queues are not cancellable in the way Executors are)
/// but callers are expected to move to a new instance. The on-disk log file is
/// preserved across shutdown so a new instance sees the same events.
internal class PendingEventsStore {

    private let queueSize: Int
    private let storeDir: URL
    private let logFile: URL
    private let countFile: URL
    private let serialQueue = DispatchQueue(label: "io.polyfence.pendingEventsStore")
    private var droppedCount: Int64
    private let logger = OSLog(subsystem: "io.polyfence.core", category: "PendingEventsStore")

    init(queueSize: Int, rootDir: URL? = nil) {
        self.queueSize = queueSize
        let baseDir = rootDir ?? PendingEventsStore.defaultBaseDir()
        self.storeDir = baseDir.appendingPathComponent("polyfence-pending-events", isDirectory: true)
        self.logFile = storeDir.appendingPathComponent("queue.jsonl")
        self.countFile = storeDir.appendingPathComponent("dropped_count")
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        PendingEventsStore.excludeFromBackup(url: storeDir)
        self.droppedCount = PendingEventsStore.loadCount(from: countFile)
    }

    /// Returns the number of events evicted by this append.
    @discardableResult
    func append(_ event: [String: Any]) -> Int {
        guard queueSize > 0 else { return 0 }
        return serialQueue.sync { [self] in
            var events = readAllUnsafe()
            events.append(event)
            var evicted = 0
            while events.count > queueSize {
                events.removeFirst()
                evicted += 1
            }
            writeAllUnsafe(events)
            if evicted > 0 {
                droppedCount += Int64(evicted)
                persistCountUnsafe(droppedCount)
            }
            return evicted
        }
    }

    /// Reads every queued event and deletes them in a single serialised block.
    func drainAll() -> [[String: Any]] {
        return serialQueue.sync { [self] in
            let events = readAllUnsafe()
            if !events.isEmpty {
                try? FileManager.default.removeItem(at: logFile)
            }
            return events
        }
    }

    func currentDroppedCount() -> Int64 {
        return serialQueue.sync { droppedCount }
    }

    /// Blocks until any in-flight append or drain has finished. Callers
    /// rebinding the store on a config change use this to guarantee no writer
    /// is still running against the on-disk log when the new store starts
    /// appending — otherwise two serial queues could race on the same file and
    /// the outgoing droppedCount could persist a stale-and-lower value after
    /// the new store loaded its own baseline. Unlike Android's executor
    /// shutdown, this does not prevent post-call appends — callers are
    /// expected to abandon the outgoing instance after invoking this.
    func shutdown() {
        serialQueue.sync {}
    }

    // The methods below run only inside serialQueue.

    private func readAllUnsafe() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: logFile),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var result: [[String: Any]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: []) as? [String: Any] {
                result.append(obj)
            } else {
                os_log("Skipping corrupted queue entry (%d chars)", log: logger, type: .info, trimmed.count)
            }
        }
        return result
    }

    private func writeAllUnsafe(_ events: [[String: Any]]) {
        var text = ""
        for e in events {
            if let data = try? JSONSerialization.data(withJSONObject: e, options: []),
               let line = String(data: data, encoding: .utf8) {
                text.append(line)
                text.append("\n")
            }
        }
        try? text.data(using: .utf8)?.write(to: logFile, options: .atomic)
    }

    private func persistCountUnsafe(_ value: Int64) {
        try? String(value).data(using: .utf8)?.write(to: countFile, options: .atomic)
    }

    private static func loadCount(from url: URL) -> Int64 {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let value = Int64(text.trimmingCharacters(in: .whitespaces)) else { return 0 }
        return value
    }

    // Application Support (never iCloud-synced by default) plus an explicit
    // isExcludedFromBackupKey on the store directory keeps zone-crossing
    // history out of iTunes / iCloud device backups even if the consumer app
    // later opts a parent directory into backup. Application Support persists
    // across app launches — unlike Caches, which the OS can evict mid-drive.
    private static func defaultBaseDir() -> URL {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        return urls.first ?? FileManager.default.temporaryDirectory
    }

    private static func excludeFromBackup(url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }
}
