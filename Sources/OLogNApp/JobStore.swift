import AppKit
import Foundation
import OLogNKit

struct JobItem: Identifiable, Equatable, Sendable {
    var job: Job
    var replaced = false
    var trashedURL: URL?
    var replacedLocation: URL?
    var replacedNote: String?
    var pin: OutputPin = .engine
    var outputFingerprint: SourceFingerprint?
    var actionError: String?
    var id: JobID { job.id }

    var outputURL: URL? {
        let engineURL: URL?
        if case .finished(let result) = job.state {
            engineURL = result.outputURL
        } else {
            engineURL = nil
        }
        return pin.resolved(engineURL: engineURL, replacedLocation: replacedLocation)
    }

    var revealURL: URL? {
        outputURL ?? job.request.source
    }

    /// Folders stay out of Replace Original. A same-length rewrite of a child leaves the folder
    /// fingerprint unchanged, so v1 does not offer the swap.
    var canReplaceOriginal: Bool {
        guard job.kind != .folder else { return false }
        guard !replaced, case .finished(let result) = job.state else { return false }
        let stamp = outputFingerprint ?? result.outputFingerprint
        return result.outcome == .compressed
            && result.savedBytes > 0
            && outputURL != nil
            && stamp != nil
            && result.sourceFingerprint != nil
    }

    var replaceOriginalHelp: String {
        if job.kind == .folder {
            return "Replace Original is unavailable for folders. The archive keeps the original folder."
        }
        return "Replace Original"
    }
}

enum UndoAction {
    case replace(ReplaceRecord)
    case remove([JobItem])
}

// Invariant: no Reveal, Preview, Copy, drag-out, Trash Output, Replace or Undo may act on a file
// unless its identity matches a stamp the engine recorded. Destructive operations must re-check
// identity on the same queue immediately before acting.
//
// The stamp is `JobResult.outputFingerprint` (or the fingerprint Replace captured on the same
// queue as the move). This store never fingerprints whatever currently sits at a path and then
// treats that reading as the stamp.

@MainActor
@Observable
final class JobStore {
    private(set) var items: [JobItem] = []
    private(set) var active = 0
    private(set) var savedBytesSession: Int64 = 0
    private(set) var pausedReason: String?
    private(set) var toast: TrayToast?
    var selectedID: JobID?
    var persistsHistory = true
    /// `--demo` never constructs the engine and never touches the filesystem.
    let simulated: Bool

    private let settingsStore: SettingsStore
    private var engine: CompressionEngine?
    private var listenTask: Task<Void, Never>?
    private var counted: Set<JobID> = []
    private var ledger = UndoLedger()
    private var fileActionInFlight = false
    private var toastToken = 0
    private var speeds: [JobID: Double] = [:]
    private var rateMarks: [JobID: (Date, Double)] = [:]
    private var historyGeneration: UInt64 = 0
    /// loading: a restore is in flight and no save may run.
    /// restored: the file was read (or there was nothing to read).
    /// failed: the file could not be read. It has been preserved. Do not replace it.
    private(set) var historyPhase: HistoryPhase = .loading
    private var lastUI = ContinuousClock.now
    private var queuedUI: Task<Void, Never>?
    var onChange: (@MainActor () -> Void)?
    private var pendingSelectBatch: UUID?

    init(settings: SettingsStore, simulated: Bool = false) {
        settingsStore = settings
        self.simulated = simulated
        if simulated {
            historyPhase = .restored
        }
    }

    func start(loadHistory: Bool = true) {
        guard listenTask == nil else { return }
        if simulated {
            historyPhase = .restored
            return
        }
        let engine = requireEngine()
        let stream = engine.events()
        listenTask = Task { @MainActor [weak self] in
            for await event in stream {
                self?.apply(event)
            }
        }
        guard loadHistory, persistsHistory else {
            historyPhase = .restored
            return
        }
        historyPhase = .loading
        let days = settingsStore.settings.historyDays
        Task { @MainActor [weak self] in
            let loaded = await HistoryStore.load(keepingDays: days)
            self?.applyHistory(loaded)
        }
    }

    private func requireEngine() -> CompressionEngine {
        if let engine { return engine }
        let created = CompressionEngine()
        engine = created
        return created
    }

    func installPreview(_ items: [JobItem], sessionSaved: Int64, toast: String?, paused: String? = nil) {
        persistsHistory = false
        self.items = items
        savedBytesSession = sessionSaved
        pausedReason = paused
        if let toast {
            self.toast = TrayToast(message: toast, offerUndo: true)
        }
        selectedID = items.first { item in
            if case .finished(let result) = item.job.state, result.outcome == .compressed, !item.replaced {
                return true
            }
            return false
        }?.id ?? items.first?.id
        recount()
        changed()
    }

    private func applyHistory(_ loaded: HistoryLoad) {
        switch loaded {
        case .failed:
            historyPhase = .failed
            return
        case .restored(let restored):
            let fresh = restored.filter { candidate in
                !items.contains {
                    $0.job.request.source == candidate.job.request.source
                        && $0.job.createdAt == candidate.job.createdAt
                }
            }
            if !fresh.isEmpty {
                items.append(contentsOf: fresh)
            }
            capHistory()
            historyPhase = .restored
            recount()
            changed()
        }
    }

    /// Quit while a restore is still running, or after a failed restore, must not
    /// write. An empty snapshot at that moment would delete the user's file.
    func flushHistoryForQuit() {
        guard persistsHistory, historyPhase == .restored else { return }
        capHistory()
        historyGeneration += 1
        let generation = historyGeneration
        let snapshot = items
        let days = settingsStore.settings.historyDays
        let url = HistoryStore.fileURL
        HistoryWriter.shared.commitBlocking(generation: generation, items: snapshot, days: days, url: url)
    }

    func persistHistoryNow(minimumDays: Int? = nil) async {
        guard historyPhase == .restored else { return }
        capHistory()
        historyGeneration += 1
        let generation = historyGeneration
        let snapshot = items
        let days = minimumDays ?? settingsStore.settings.historyDays
        let url = HistoryStore.fileURL
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            HistoryWriter.shared.commit(generation: generation, items: snapshot, days: days, url: url) {
                continuation.resume()
            }
        }
    }

    @discardableResult
    func submit(_ urls: [URL], mode: CompressionMode) -> UUID {
        let batch = UUID()
        let engineSettings = settingsStore.settings.engineForJobs
        pendingSelectBatch = batch
        let token = batch
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            if self.pendingSelectBatch == token { self.pendingSelectBatch = nil }
        }
        guard !simulated else { return batch }
        let engine = requireEngine()
        Task { await engine.submit(urls, mode: mode, settings: engineSettings, batchID: batch) }
        return batch
    }

    func cancel(_ id: JobID) {
        guard !simulated else { return }
        let engine = requireEngine()
        Task { await engine.cancel(id) }
    }

    func cancelAll() {
        guard !simulated else { return }
        let engine = requireEngine()
        Task { await engine.cancelAll() }
    }

    func resume() {
        guard !simulated else {
            pausedReason = nil
            changed()
            return
        }
        let engine = requireEngine()
        Task { await engine.resume() }
    }

    func remove(_ id: JobID) {
        guard !fileActionInFlight else {
            showToast("Wait for the file operation to finish")
            return
        }
        guard let item = items.first(where: { $0.id == id }) else { return }
        if !item.job.state.isTerminal {
            cancel(id)
            return
        }
        items.removeAll { $0.id == id }
        ledger.push(.remove([item]))
        if selectedID == id { selectedID = items.first?.id }
        if !simulated {
            let engine = requireEngine()
            Task { await engine.remove(id) }
        }
        scheduleHistorySave()
        recount()
        changed()
    }

    func clearFinished() {
        guard !fileActionInFlight else {
            showToast("Wait for the file operation to finish")
            return
        }
        let done = items.filter { $0.job.state.isTerminal }
        guard !done.isEmpty else { return }
        let ids = done.map(\.id)
        items.removeAll { $0.job.state.isTerminal }
        ledger.push(.remove(done))
        if let selectedID, !items.contains(where: { $0.id == selectedID }) {
            self.selectedID = items.first?.id
        }
        if !simulated {
            let engine = requireEngine()
            Task {
                for id in ids { await engine.remove(id) }
            }
        }
        scheduleHistorySave()
        recount()
        changed()
    }

    func retry(_ id: JobID) {
        guard !fileActionInFlight else {
            showToast("Wait for the file operation to finish")
            return
        }
        guard let item = items.first(where: { $0.id == id }) else { return }
        let source = item.job.request.source
        let mode = item.job.request.mode
        items.removeAll { $0.id == id }
        if !simulated {
            let engine = requireEngine()
            Task { await engine.remove(id) }
        }
        recount()
        changed()
        submit([source], mode: mode)
    }

    func replaceOriginal(_ id: JobID) async {
        guard let item = items.first(where: { $0.id == id }) else {
            if !simulated { showFailure(id, .notAllowed) }
            return
        }
        guard item.job.kind != .folder else {
            showMessage(id, item.replaceOriginalHelp)
            return
        }
        if simulated {
            let name = item.job.request.source.lastPathComponent
            showToast("Replaced \(name) (original in Trash)", undo: true)
            return
        }
        guard beginFileAction() else { return }
        defer { fileActionInFlight = false }
        guard item.canReplaceOriginal, let output = item.outputURL,
              case .finished(let result) = item.job.state,
              let sourceFingerprint = result.sourceFingerprint,
              let outputFingerprint = outputStamp(of: item)
        else {
            showMessage(id, item.canReplaceOriginal ? "This file can't be verified" : "Nothing to replace")
            return
        }
        let request = ReplaceRequest(
            jobID: id,
            original: item.job.request.source,
            output: output,
            kind: item.job.kind,
            sourceFingerprint: sourceFingerprint,
            outputFingerprint: outputFingerprint,
            displayName: item.job.request.source.lastPathComponent)
        do {
            let record = try await JobFileWork.run(id) { try ReplaceService.replace(request) }
            ledger.push(.replace(record))
            adopt(record, error: nil)
        } catch let error as ReplaceError {
            if case .incomplete(let record) = error {
                ledger.push(.replace(record))
                adopt(record, error: error.trayMessage)
            } else {
                showFailure(id, error)
            }
        } catch {
            showFailure(id, .io(error.localizedDescription))
        }
    }

    func undoLastReplace() async {
        if simulated {
            showToast("Restored the original")
            return
        }
        guard let action = ledger.peek() else { return }
        guard beginFileAction() else { return }
        defer { fileActionInFlight = false }
        switch action {
        case .replace(let record):
            do {
                let outcome = try await JobFileWork.run(record.jobID) {
                    try ReplaceService.undo(record)
                }
                ledger.commitSuccess()
                applyUndoSuccess(record, restored: outcome.url, stamp: outcome.fingerprint)
            } catch let error as ReplaceError {
                if case .incomplete(let updated) = error {
                    ledger.replaceTop(.replace(updated))
                    adopt(updated, error: error.trayMessage)
                } else {
                    applyUndoFailure(record.jobID, error)
                }
            } catch {
                applyUndoFailure(record.jobID, .io(error.localizedDescription))
            }
        case .remove(let restored):
            ledger.commitSuccess()
            restoreRemoved(restored)
        }
    }

    func trashOutput(_ id: JobID) async {
        if simulated {
            showToast("Moved the compressed file to the Trash")
            return
        }
        guard beginFileAction() else { return }
        defer { fileActionInFlight = false }
        guard let item = items.first(where: { $0.id == id }) else { return }
        guard let url = item.outputURL else {
            showMessage(id, "No compressed file")
            return
        }
        guard let expected = outputStamp(of: item) else {
            showMessage(id, "This file can't be verified")
            return
        }
        do {
            try await JobFileWork.run(id) { try ReplaceService.discard(url, expected: expected) }
        } catch let error as ReplaceError {
            showFailure(id, error)
            return
        } catch {
            showFailure(id, .io(error.localizedDescription))
            return
        }
        fileActionInFlight = false
        remove(id)
    }

    /// Compare the file at the card's output path with the stamp the engine recorded.
    /// Nil means the card has no stamp, or the file at that path is not the one Logn wrote.
    /// This does not adopt a new fingerprint.
    func claimOutput(_ id: JobID) async -> URL? {
        if simulated {
            return items.first { $0.id == id }?.outputURL
        }
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        guard let url = item.outputURL else {
            showMessage(id, "No compressed file")
            return nil
        }
        guard let expected = outputStamp(of: item) else {
            showMessage(id, "This file can't be verified")
            return nil
        }
        let matches = (try? await JobFileWork.run(id) {
            (try? SourceFingerprint.capture(url)) == expected
        }) ?? false
        guard matches else {
            showMessage(id, "The compressed file is no longer the one Logn wrote")
            return nil
        }
        return url
    }

    /// Output when the card has one, otherwise the source. Either way the file on disk must
    /// still match the stamp recorded for it. A path with no stamp is not revealed or previewed.
    func claimActionURL(_ id: JobID) async -> URL? {
        if simulated {
            guard let item = items.first(where: { $0.id == id }) else { return nil }
            return item.outputURL ?? item.job.request.source
        }
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        if item.outputURL != nil {
            return await claimOutput(id)
        }
        guard case .finished(let result) = item.job.state, let expected = result.sourceFingerprint else {
            showMessage(id, "This file can't be verified")
            return nil
        }
        let source = item.job.request.source
        let matches = (try? await JobFileWork.run(id) {
            (try? SourceFingerprint.capture(source)) == expected
        }) ?? false
        guard matches else {
            showMessage(id, "The original changed after compression")
            return nil
        }
        return source
    }

    func chooseOutput(for id: JobID) {
        // The panel coordinator owns NSOpenPanel. This marks the card that asked.
        selectedID = id
    }

    var throughputLabel: String {
        let sum = speeds.values.reduce(0, +)
        if sum > 1 { return "\(active) active · \(ByteText.rate(sum))" }
        return "\(active) active"
    }

    func bytesPerSecond(for id: JobID) -> Double? {
        guard let value = speeds[id], value > 1 else { return nil }
        return value
    }

    var queuedCount: Int {
        items.filter { if case .queued = $0.job.state { return true }; return false }.count
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { selectedID = nil; return }
        guard let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) else {
            self.selectedID = delta >= 0 ? items.first?.id : items.last?.id
            return
        }
        let next = min(max(0, index + delta), items.count - 1)
        self.selectedID = items[next].id
    }

    func selectEdge(first: Bool) {
        selectedID = first ? items.first?.id : items.last?.id
    }

    func showToast(_ text: String, undo: Bool = false, dismiss: Bool = false, sticky: Bool = false) {
        toast = TrayToast(message: text, offerUndo: undo, offerDismiss: dismiss)
        toastToken += 1
        let token = toastToken
        if !sticky {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                guard token == self.toastToken else { return }
                self.toast = nil
                self.changed()
            }
        }
        changed()
    }

    /// Drops a permanent "Original no longer in Trash" record so older undos can run.
    func dismissBlockedUndo() {
        guard toast?.offerDismiss == true else { return }
        if case .replace = ledger.peek() {
            ledger.dropTop()
        }
        toast = nil
        changed()
    }

    func waitForBatch(_ batch: UUID, timeout: Duration) async -> String {
        let clock = ContinuousClock()
        let start = clock.now
        while start.duration(to: clock.now) < timeout {
            let batchItems = items.filter { $0.job.request.batchID == batch }
            if !batchItems.isEmpty, batchItems.allSatisfy({ $0.job.state.isTerminal }) {
                switch batchItems[0].job.state {
                case .finished(let result):
                    return result.outcome.rawValue
                case .failed:
                    return "failed"
                case .cancelled:
                    return "cancelled"
                case .queued, .running:
                    break
                }
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return "timeout"
    }

    private func apply(_ event: EngineEvent) {
        switch event {
        case .added(let job):
            items.removeAll { $0.id == job.id }
            items.insert(JobItem(job: job), at: 0)
            if job.request.batchID == pendingSelectBatch { selectedID = job.id }
        case .updated(let job):
            noteSpeed(job)
            let index: Int
            if let existing = items.firstIndex(where: { $0.id == job.id }) {
                items[existing].job = job
                index = existing
            } else {
                items.insert(JobItem(job: job), at: 0)
                index = 0
            }
            if case .finished(let result) = job.state {
                if items[index].outputFingerprint == nil {
                    items[index].outputFingerprint = result.outputFingerprint
                }
                if counted.insert(job.id).inserted {
                    savedBytesSession += result.savedBytes
                }
            }
        case .removed(let id):
            // The store owns completed-card history. This event is the echo of a removal
            // the store already applied. Undo may have put the card back; that echo must not erase it.
            guard !items.contains(where: { $0.id == id }) else { break }
            speeds[id] = nil
            rateMarks[id] = nil
        case .paused(let reason):
            pausedReason = reason
        case .resumed:
            pausedReason = nil
        }
        let immediate: Bool
        if case .updated(let job) = event {
            immediate = job.state.isTerminal
            if job.state.isTerminal { scheduleHistorySave() }
        } else {
            immediate = true
        }
        publish(immediate)
    }

    private func noteSpeed(_ job: Job) {
        guard case .running(let fraction) = job.state else {
            if job.state.isTerminal { speeds[job.id] = nil }
            return
        }
        let now = Date()
        if let (then, previous) = rateMarks[job.id] {
            let elapsed = now.timeIntervalSince(then)
            if elapsed >= 0.25, fraction > previous {
                let bytes = Double(job.inputBytes) * (fraction - previous)
                speeds[job.id] = bytes / elapsed
                rateMarks[job.id] = (now, fraction)
            }
        } else {
            rateMarks[job.id] = (now, fraction)
        }
    }

    private func beginFileAction() -> Bool {
        guard !fileActionInFlight else {
            showToast("Wait for the file operation to finish")
            return false
        }
        fileActionInFlight = true
        return true
    }

    private func outputStamp(of item: JobItem) -> SourceFingerprint? {
        if let stamp = item.outputFingerprint { return stamp }
        if case .finished(let result) = item.job.state { return result.outputFingerprint }
        return nil
    }

    private func adopt(_ record: ReplaceRecord, error: String?) {
        guard let index = items.firstIndex(where: { $0.id == record.jobID }) else {
            if let error { showToast(error) }
            changed()
            return
        }
        items[index].replaced = true
        items[index].trashedURL = record.trashedURL
        items[index].replacedLocation = record.movedTo
        let resolved = record.movedTo ?? record.outputBefore
        items[index].pin = .pinned(resolved)
        items[index].outputFingerprint = record.installedFingerprint
        items[index].actionError = error
        if record.extensionChanged {
            let from = record.originalURL.pathExtension
            let to = record.outputBefore.pathExtension
            items[index].replacedNote = "Replaced \(from.isEmpty ? "file" : ".\(from)") → \(to.isEmpty ? "file" : ".\(to)")"
        }
        if let error {
            showToast(error)
        } else {
            showToast("Replaced \(record.displayName) (original in Trash)", undo: true)
        }
        scheduleHistorySave()
        changed()
    }

    private func applyUndoSuccess(_ record: ReplaceRecord, restored: URL?, stamp: SourceFingerprint?) {
        if let index = items.firstIndex(where: { $0.id == record.jobID }) {
            items[index].replaced = false
            items[index].trashedURL = nil
            items[index].replacedLocation = nil
            items[index].replacedNote = nil
            items[index].pin = .pinned(restored)
            items[index].outputFingerprint = stamp
            items[index].actionError = nil
        }
        showToast("Restored \(record.displayName)")
        scheduleHistorySave()
        changed()
    }

    private func applyUndoFailure(_ id: JobID, _ error: ReplaceError) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            var pin = items[index].pin
            var location = items[index].replacedLocation
            UndoApplication.apply(error: error, pin: &pin, replacedLocation: &location)
            items[index].pin = pin
            items[index].replacedLocation = location
            items[index].actionError = error.trayMessage
        }
        if case .notInTrash = error {
            showToast(error.trayMessage, dismiss: true, sticky: true)
        } else {
            showToast(error.trayMessage)
        }
        scheduleHistorySave()
        changed()
    }

    private func showFailure(_ id: JobID, _ error: ReplaceError) {
        showMessage(id, error.trayMessage)
    }

    private func showMessage(_ id: JobID, _ message: String) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].actionError = message
        }
        showToast(message)
        changed()
    }

    private func restoreRemoved(_ restored: [JobItem]) {
        for item in restored.reversed() where !items.contains(where: { $0.id == item.id }) {
            items.insert(item, at: 0)
        }
        selectedID = restored.first?.id ?? selectedID
        let name = restored.count == 1
            ? restored[0].job.request.source.lastPathComponent
            : "\(restored.count) cards"
        showToast("Restored \(name)")
        scheduleHistorySave()
        recount()
        changed()
    }

    private func recount() {
        active = items.filter { !$0.job.state.isTerminal }.count
    }

    private func publish(_ immediate: Bool) {
        recount()
        if immediate {
            queuedUI?.cancel()
            queuedUI = nil
            lastUI = .now
            changed()
            return
        }
        if lastUI.duration(to: .now) >= .milliseconds(66) {
            lastUI = .now
            changed()
            return
        }
        guard queuedUI == nil else { return }
        queuedUI = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(66))
            guard !Task.isCancelled else { return }
            self.queuedUI = nil
            self.lastUI = .now
            self.changed()
        }
    }

    private func capHistory() {
        let terminal = items.filter { $0.job.state.isTerminal }
        guard terminal.count > HistoryStore.cap else { return }
        let overflow = terminal.sorted { $0.job.createdAt < $1.job.createdAt }
        let drop = Set(overflow.prefix(terminal.count - HistoryStore.cap).map(\.id))
        items.removeAll { drop.contains($0.id) }
    }

    /// Coalesce terminal events, then hand a value snapshot to the writer. The generation is
    /// the token at schedule time. The writer drops it if a newer clear or save already landed.
    /// `HistoryEntry` conversion runs on the writer queue, not on this actor.
    private func scheduleHistorySave() {
        guard persistsHistory, historyPhase == .restored else { return }
        capHistory()
        historyGeneration += 1
        let generation = historyGeneration
        let days = settingsStore.settings.historyDays
        let url = HistoryStore.fileURL
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard generation == self.historyGeneration, self.persistsHistory, self.historyPhase == .restored else { return }
            let snapshot = self.items
            HistoryWriter.shared.commit(generation: generation, items: snapshot, days: days, url: url)
        }
    }

    private func changed() {
        onChange?()
    }
}
