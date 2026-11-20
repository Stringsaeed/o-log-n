import Foundation
import OLogNKit
import os

/// Full-precision file identity. `modified` is `timeIntervalSinceReferenceDate`, so a
/// round trip does not drop the fractional seconds `.iso8601` would discard.
struct StoredFingerprint: Codable, Sendable, Equatable {
    var size: Int64
    var modified: Double
    var fileID: UInt64

    init(_ fingerprint: SourceFingerprint) {
        size = fingerprint.size
        modified = fingerprint.modificationDate.timeIntervalSinceReferenceDate
        fileID = fingerprint.fileID
    }

    var fingerprint: SourceFingerprint {
        SourceFingerprint(
            size: size,
            modificationDate: Date(timeIntervalSinceReferenceDate: modified),
            fileID: fileID)
    }
}

/// One finished card, stored at `~/Library/Application Support/Logn/history.json` (U1).
///
/// `outputState` is `"file"` or `"none"`. `outputPath` is the resolved location after
/// Replace or Undo, never the name the engine first wrote when a later move changed it.
/// A card whose stamps are missing cannot prove ownership; file actions stay disabled.
struct HistoryEntry: Codable, Sendable, Equatable {
    var sourcePath: String
    var mode: CompressionMode
    var kind: FileKind
    var inputBytes: Int64
    var createdAt: Date
    var outcome: String
    var method: String
    var lossless: Bool
    var verified: Bool
    var outputPath: String?
    var outputState: String?
    var outputBytes: Int64
    var note: String?
    var error: String?
    var replaced: Bool
    var replacedNote: String?
    var batch: UUID?
    var settings: EngineSettings
    var sourceStamp: StoredFingerprint?
    var outputStamp: StoredFingerprint?
    /// `JobError` case name. Absent on rows written before typed failures, which restore as `.codec`.
    var failureKind: String?

    init?(_ item: JobItem) {
        guard item.job.state.isTerminal else { return nil }
        sourcePath = item.job.request.source.path
        mode = item.job.request.mode
        kind = item.job.kind
        inputBytes = item.job.inputBytes
        createdAt = item.job.createdAt
        settings = item.job.request.settings
        batch = item.job.request.batchID
        replaced = item.replaced
        replacedNote = item.replacedNote
        failureKind = nil
        switch item.job.state {
        case .finished(let result):
            outcome = result.outcome.rawValue
            method = result.method
            lossless = result.lossless
            verified = result.verified
            outputBytes = result.outputBytes
            note = result.note
            error = nil
            if let fingerprint = result.sourceFingerprint {
                sourceStamp = StoredFingerprint(fingerprint)
            }
        case .cancelled:
            outcome = "cancelled"
            method = ""
            lossless = false
            verified = false
            outputBytes = inputBytes
            note = nil
            error = nil
        case .failed(let jobError):
            outcome = "failed"
            method = ""
            lossless = false
            verified = false
            outputBytes = inputBytes
            note = nil
            error = Self.describe(jobError)
            failureKind = Self.kindName(jobError)
        case .queued, .running:
            return nil
        }
        if let url = item.outputURL {
            outputState = "file"
            outputPath = url.path
            let stamp = item.outputFingerprint ?? Self.resultStamp(item)
            if let stamp {
                outputStamp = StoredFingerprint(stamp)
            }
        } else {
            outputState = "none"
            outputPath = nil
        }
    }

    private static func resultStamp(_ item: JobItem) -> SourceFingerprint? {
        if case .finished(let result) = item.job.state { return result.outputFingerprint }
        return nil
    }

    func makeItem() -> JobItem {
        let source = Self.fileURL(sourcePath, directory: kind == .folder)
        let request = JobRequest(source: source, mode: mode, settings: settings, batchID: batch)
        let sourceFingerprint = sourceStamp?.fingerprint
        let outputFingerprint = outputStamp?.fingerprint
        let resolved = resolvedOutputURL
        let state: JobState
        switch outcome {
        case "compressed":
            state = .finished(JobResult(
                outcome: .compressed,
                kind: kind,
                method: method,
                lossless: lossless,
                verified: verified,
                inputBytes: inputBytes,
                outputBytes: outputBytes,
                outputURL: resolved,
                note: note,
                duration: 0,
                sourceFingerprint: sourceFingerprint,
                outputFingerprint: outputFingerprint))
        case "alreadyOptimal":
            state = .finished(JobResult(
                outcome: .alreadyOptimal,
                kind: kind,
                method: method,
                lossless: lossless,
                verified: verified,
                inputBytes: inputBytes,
                outputBytes: outputBytes,
                outputURL: nil,
                note: note,
                duration: 0,
                sourceFingerprint: sourceFingerprint,
                outputFingerprint: nil))
        case "cancelled":
            state = .cancelled
        case "failed":
            state = .failed(Self.restoreFailure(kind: failureKind, detail: error))
        default:
            state = .failed(.codec(error ?? "Couldn't compress"))
        }
        let job = Job(
            id: JobID(),
            request: request,
            kind: kind,
            inputBytes: inputBytes,
            createdAt: createdAt,
            state: state)
        var item = JobItem(job: job)
        item.replaced = replaced
        item.replacedNote = replacedNote
        item.outputFingerprint = outputStamp?.fingerprint
        // Pin the resolved location so a later engine URL cannot point the card elsewhere.
        item.pin = .pinned(resolved)
        if replaced, let resolved {
            item.replacedLocation = resolved
        }
        return item
    }

    /// `"none"` is explicit. A legacy row with only a path still exposes that path, but
    /// without `outputStamp` the card cannot prove it owns the file.
    private var resolvedOutputURL: URL? {
        if outputState == "none" { return nil }
        guard let outputPath, !outputPath.isEmpty else { return nil }
        if outputState == "file" || outcome == "compressed" {
            return Self.fileURL(outputPath, directory: false)
        }
        return nil
    }

    private static func fileURL(_ path: String, directory: Bool) -> URL {
        URL(fileURLWithPath: path, isDirectory: directory)
    }

    private static func describe(_ error: JobError) -> String {
        switch error {
        case .unreadable(let detail): detail.isEmpty ? "Read failed" : detail
        case .outputNotWritable(let detail): detail.isEmpty ? "No write permission" : detail
        case .diskFull: "Disk full"
        case .verificationFailed(let detail), .codec(let detail):
            detail.isEmpty ? "Couldn't compress" : detail
        }
    }

    private static func kindName(_ error: JobError) -> String {
        switch error {
        case .unreadable: "unreadable"
        case .outputNotWritable: "outputNotWritable"
        case .diskFull: "diskFull"
        case .verificationFailed: "verificationFailed"
        case .codec: "codec"
        }
    }

    /// Restores the typed failure before a card builds its actions. A row with no kind is `.codec`.
    private static func restoreFailure(kind: String?, detail: String?) -> JobError {
        let text = detail ?? ""
        switch kind {
        case "unreadable":
            return .unreadable(text.isEmpty ? "Read failed" : text)
        case "outputNotWritable":
            return .outputNotWritable(text.isEmpty ? "No write permission" : text)
        case "diskFull":
            return .diskFull
        case "verificationFailed":
            return .verificationFailed(text.isEmpty ? "Couldn't compress" : text)
        case "codec":
            return .codec(text.isEmpty ? "Couldn't compress" : text)
        default:
            return .codec(text.isEmpty ? "Couldn't compress" : text)
        }
    }
}

enum HistoryPhase: Sendable {
    case loading
    case restored
    case failed
}

enum HistoryLoad: Sendable {
    case restored([JobItem])
    case failed
}

enum HistoryStore {
    static let cap = 2_000

    private static let overrideLock = OSAllocatedUnfairLock<URL?>(initialState: nil)

    /// Selftests point this at a temporary directory. Production leaves it nil.
    static var directoryOverride: URL? {
        get { overrideLock.withLock { $0 } }
        set { overrideLock.withLock { $0 = newValue } }
    }

    static var realDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logn", isDirectory: true)
    }

    static var directory: URL {
        directoryOverride ?? realDirectory
    }

    static var fileURL: URL {
        directory.appendingPathComponent("history.json", isDirectory: false)
    }

    static func pruned(_ entries: [HistoryEntry], days: Int) -> [HistoryEntry] {
        guard days > 0 else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let fresh = entries.filter { $0.createdAt >= cutoff }
        guard fresh.count > cap else { return fresh }
        return Array(fresh.sorted { $0.createdAt > $1.createdAt }.prefix(cap))
    }

    /// Reads off the caller's actor. One bad record is skipped. An unreadable file is
    /// renamed to `history.corrupt-<date>.json` and reported as `.failed`. A file that
    /// parses but contains a bad record is copied aside under that name, then the good
    /// rows replace `history.json` atomically before this returns them. Recovery is not
    /// complete until that write succeeds. A second load reads the good file.
    static func load(keepingDays days: Int) async -> HistoryLoad {
        let url = fileURL
        return await Task.detached(priority: .utility) {
            switch loadSync(url: url, days: days) {
            case .failed:
                return .failed
            case .entries(let entries):
                return .restored(entries.map { $0.makeItem() })
            }
        }.value
    }

    private enum RawLoad {
        case entries([HistoryEntry])
        case failed
    }

    private static func loadSync(url: URL, days: Int) -> RawLoad {
        let files = FileManager.default
        guard files.fileExists(atPath: url.path) else { return .entries([]) }
        guard days > 0 else { return .entries([]) }
        guard let data = try? Data(contentsOf: url) else {
            quarantine(url)
            return .failed
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            quarantine(url)
            return .failed
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(HistoryDates.decode)
        var good: [HistoryEntry] = []
        var skipped = false
        for element in raw {
            guard JSONSerialization.isValidJSONObject(element),
                  let itemData = try? JSONSerialization.data(withJSONObject: element),
                  let entry = try? decoder.decode(HistoryEntry.self, from: itemData)
            else {
                skipped = true
                continue
            }
            good.append(entry)
        }
        let kept = pruned(good, days: days)
        if skipped {
            guard copyAside(url) else { return .failed }
            guard writeFile(kept, url: url) else { return .failed }
        }
        return .entries(kept)
    }

    static func quarantine(_ url: URL) {
        guard let destination = corruptDestination(near: url) else { return }
        try? FileManager.default.moveItem(at: url, to: destination)
    }

    /// Keeps the corrupt bytes beside the live file. The live path is rewritten afterwards.
    private static func copyAside(_ url: URL) -> Bool {
        guard let destination = corruptDestination(near: url) else { return false }
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return true
        } catch {
            return false
        }
    }

    private static func corruptDestination(near url: URL) -> URL? {
        let directory = url.deletingLastPathComponent()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var destination = directory.appendingPathComponent("history.corrupt-\(stamp).json", isDirectory: false)
        var attempt = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("history.corrupt-\(stamp)-\(attempt).json", isDirectory: false)
            attempt += 1
            if attempt > 100 { return nil }
        }
        return destination
    }

    @discardableResult
    static func writeFile(_ kept: [HistoryEntry], url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if kept.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                return true
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .custom(HistoryDates.encode)
            let data = try encoder.encode(kept)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

enum HistoryDates {
    static func encode(_ date: Date, encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(date.timeIntervalSinceReferenceDate)
    }

    static func decode(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        if let interval = try? container.decode(Double.self) {
            return Date(timeIntervalSinceReferenceDate: interval)
        }
        if let text = try? container.decode(String.self) {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: text) { return date }
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unreadable date")
    }
}

/// One serial queue for every history commit. A generation older than one already
/// applied is dropped, so a stale save cannot recreate a file a newer clear removed.
final class HistoryWriter: @unchecked Sendable {
    static let shared = HistoryWriter()

    private let queue = DispatchQueue(label: "app.ologn.history-writer")
    private var applied: UInt64 = 0

    func commit(
        generation: UInt64,
        entries: [HistoryEntry],
        days: Int,
        url: URL,
        completion: (@Sendable () -> Void)? = nil
    ) {
        queue.async {
            self.perform(generation: generation, entries: entries, days: days, url: url)
            completion?()
        }
    }

    /// Converts the value snapshot on this writer queue, not on the caller's actor.
    func commit(
        generation: UInt64,
        items: [JobItem],
        days: Int,
        url: URL,
        completion: (@Sendable () -> Void)? = nil
    ) {
        queue.async {
            let entries = items.compactMap { HistoryEntry($0) }
            self.perform(generation: generation, entries: entries, days: days, url: url)
            completion?()
        }
    }

    /// Process exit only. The queue is not the main queue, so this cannot deadlock
    /// the cooperative pool. It does wait so the write finishes before the process ends.
    func commitBlocking(generation: UInt64, entries: [HistoryEntry], days: Int, url: URL) {
        queue.sync {
            self.perform(generation: generation, entries: entries, days: days, url: url)
        }
    }

    func commitBlocking(generation: UInt64, items: [JobItem], days: Int, url: URL) {
        queue.sync {
            let entries = items.compactMap { HistoryEntry($0) }
            self.perform(generation: generation, entries: entries, days: days, url: url)
        }
    }

    func wait() {
        queue.sync {}
    }

    /// Selftests build several stores in one process. Each store's generation starts at zero,
    /// so a later store's save would look older than a commit this process already applied.
    /// Production has one store and never calls this. The reset runs on the writer queue,
    /// after any commit already queued.
    func resetAppliedGeneration() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.applied = 0
                continuation.resume()
            }
        }
    }

    private func perform(generation: UInt64, entries: [HistoryEntry], days: Int, url: URL) {
        guard generation >= applied else { return }
        applied = generation
        HistoryStore.writeFile(HistoryStore.pruned(entries, days: days), url: url)
    }
}
