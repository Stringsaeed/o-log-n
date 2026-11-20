import Foundation
import os

public actor CompressionEngine {
    private var records: [JobID: Job] = [:]
    private var order: [JobID] = []
    private var tasks: [JobID: Task<Void, Never>] = [:]
    private var flags: [JobID: CancelFlag] = [:]
    private var waiters: [JobID: [CheckedContinuation<Job, Never>]] = [:]
    /// Terminal jobs kept after `remove` so a late `waitUntilFinished` can return them.
    private var tombstones: [JobID: Job] = [:]
    private var paused = false
    private var announcedPause = false
    private let lanes: LaneGate
    private let hub = EventHub()
    private var scratchHook: (@Sendable (URL) async -> Void)?
    private var postAcquireHook: (@Sendable () async throws -> Void)?
    private var afterCodecHook: (@Sendable () async -> Void)?

    public init() {
        lanes = LaneGate(cpu: SystemInfo.pCoreCount)
    }

    /// Replays `.added` for every job already known, then forwards later events.
    /// Registration and the replay happen before any later event is published.
    public nonisolated func events() -> AsyncStream<EngineEvent> {
        let hub = self.hub
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let id = UUID()
            hub.subscribe(id, continuation)
            continuation.onTermination = { _ in
                hub.unsubscribe(id)
            }
        }
    }

    /// Returns ids immediately. Kind and size are filled in off the cooperative thread; the job
    /// then emits `.updated` with `inputBytes` set.
    @discardableResult
    public func submit(
        _ urls: [URL],
        mode: CompressionMode,
        settings: EngineSettings,
        batchID: UUID? = nil
    ) -> [JobID] {
        var ids: [JobID] = []
        for url in urls {
            let id = JobID()
            ids.append(id)
            let request = JobRequest(source: url, mode: mode, settings: settings, batchID: batchID)
            flags[id] = CancelFlag()
            let job = Job(
                id: id, request: request, kind: .generic, inputBytes: 0,
                createdAt: Date(), state: .queued)
            store(job)
            kick(id)
        }
        return ids
    }

    public func cancel(_ id: JobID) {
        flags[id]?.cancel()
        guard let job = records[id], !job.state.isTerminal else { return }
        if let task = tasks[id] {
            task.cancel()
        } else {
            finish(id, .cancelled, duration: 0)
        }
    }

    public func cancelAll() {
        for id in order where records[id]?.state.isTerminal == false {
            cancel(id)
        }
    }

    public func remove(_ id: JobID) {
        guard let job = records[id], job.state.isTerminal else { return }
        records[id] = nil
        tasks[id] = nil
        flags[id] = nil
        order.removeAll { $0 == id }
        tombstones[id] = job
        hub.publish(.removed(id))
        let pending = waiters[id] ?? []
        waiters[id] = nil
        for waiter in pending { waiter.resume(returning: job) }
    }

    public func resume() {
        guard paused else { return }
        paused = false
        announcedPause = false
        hub.publish(.resumed)
        for id in order {
            guard let job = records[id], case .queued = job.state, tasks[id] == nil else { continue }
            kick(id)
        }
    }

    public func jobs() -> [Job] {
        order.compactMap { records[$0] }
    }

    /// Returns the terminal job.
    ///
    /// A job passed to `remove` is still returned, as the terminal value it had when it was removed.
    /// An id this engine has never seen returns immediately with state `.cancelled` and does not wait.
    public func waitUntilFinished(_ id: JobID) async -> Job {
        if let job = terminalJob(id) { return job }
        if records[id] == nil { return placeholder(id) }
        return await withCheckedContinuation { continuation in
            if let job = terminalJob(id) {
                continuation.resume(returning: job)
            } else if records[id] == nil {
                continuation.resume(returning: placeholder(id))
            } else {
                waiters[id, default: []].append(continuation)
            }
        }
    }

    func setScratchHookForTesting(_ hook: (@Sendable (URL) async -> Void)?) {
        scratchHook = hook
    }

    func setPostAcquireHookForTesting(_ hook: (@Sendable () async throws -> Void)?) {
        postAcquireHook = hook
    }

    func setAfterCodecHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        afterCodecHook = hook
    }

    private func kick(_ id: JobID) {
        guard tasks[id] == nil else { return }
        tasks[id] = Task { await self.run(id) }
    }

    private func run(_ id: JobID) async {
        guard var job = records[id], !job.state.isTerminal else {
            tasks[id] = nil
            return
        }
        let source = job.request.source
        if Task.isCancelled || flags[id]?.isCancelled == true {
            finish(id, .cancelled, duration: 0)
            return
        }
        let gateStarted = ContinuousClock.now
        if let limit = job.request.settings.maxCPUJobs {
            await lanes.setCPULimit(limit)
        }
        do {
            let inspected = try await Offload.run { token -> (FileKind, Int64) in
                if token.isCancelled { throw CancellationError() }
                let kind = try Router.kind(of: source)
                if token.isCancelled { throw CancellationError() }
                let bytes = try Self.measure(source, kind: kind)
                return (kind, bytes)
            }
            updateIdentity(id, kind: inspected.0, inputBytes: inspected.1)
        } catch {
            if userCancelled(id) || error is CancellationError {
                finish(id, .cancelled, duration: seconds(since: gateStarted))
            } else {
                finish(id, .failed(FailureMap.jobError(error)), duration: seconds(since: gateStarted))
            }
            return
        }
        guard let refreshed = records[id], !refreshed.state.isTerminal else {
            tasks[id] = nil
            return
        }
        job = refreshed
        if paused {
            tasks[id] = nil
            return
        }
        if userCancelled(id) {
            finish(id, .cancelled, duration: seconds(since: gateStarted))
            return
        }

        let directory: URL
        do {
            directory = try destinationDirectory(job.request)
            if job.kind == .folder {
                try rejectDestinationInsideSource(source: job.request.source, directory: directory)
            }
        } catch {
            finish(id, .failed(FailureMap.jobError(error)), duration: seconds(since: gateStarted))
            return
        }

        if job.kind == .generic {
            do {
                let decision = try await Offload.run { token -> (String?, SourceFingerprint) in
                    if token.isCancelled { throw CancellationError() }
                    let fingerprint = try SourceFingerprint.capture(source)
                    let reason = SkipGate.shouldSkip(source) ? SkipGate.reason(for: source) : nil
                    return (reason, fingerprint)
                }
                updateIdentity(id, inputBytes: decision.1.size)
                if let reason = decision.0 {
                    guard let current = records[id], !current.state.isTerminal else {
                        tasks[id] = nil
                        return
                    }
                    finish(
                        id,
                        .finished(optimal(current, reason: reason, since: gateStarted, fingerprint: decision.1)),
                        duration: nil)
                    return
                }
            } catch {
                if userCancelled(id) || error is CancellationError {
                    finish(id, .cancelled, duration: seconds(since: gateStarted))
                } else {
                    finish(id, .failed(FailureMap.jobError(error)), duration: seconds(since: gateStarted))
                }
                return
            }
            if let current = records[id] { job = current }
        }

        let lane = Router.lane(for: job.kind)
        var held = false
        var scratch: URL?
        var started = gateStarted
        do {
            try await lanes.acquire(lane)
            held = true
            if paused {
                // Park before the release `await`: if `resume()` runs during that suspension it must see
                // `tasks[id] == nil` and re-kick this job, or the job is stranded in `.queued` forever.
                tasks[id] = nil
                held = false
                await lanes.release(lane)
                return
            }
            if userCancelled(id) { throw CancellationError() }
            started = ContinuousClock.now
            if let hook = postAcquireHook {
                try await hook()
            }
            if userCancelled(id) { throw CancellationError() }
            let fingerprint = try await Offload.run { token -> SourceFingerprint in
                if token.isCancelled { throw CancellationError() }
                return try SourceFingerprint.capture(source)
            }
            updateIdentity(id, inputBytes: fingerprint.size)
            if let current = records[id], !current.state.isTerminal {
                job = current
            }
            scratch = try OutputWriter.makeScratch(appropriateFor: directory)
            if let hook = scratchHook, let scratch {
                await hook(scratch)
            }
            if userCancelled(id) { throw CancellationError() }
            setRunning(id, 0)
            let flag = flags[id] ?? CancelFlag()
            let tap = ProgressTap { fraction in
                Task { await self.setProgress(id, fraction) }
            }
            let context = CodecContext(
                input: job.request.source,
                inputBytes: fingerprint.size,
                mode: job.request.mode,
                settings: job.request.settings,
                scratch: scratch ?? directory,
                progress: { tap.report($0) },
                isCancelled: { flag.isCancelled || Task.isCancelled })
            let outcome = try await codec(for: job.kind).compress(context)
            if let hook = afterCodecHook {
                await hook()
            }
            if flag.isCancelled || Task.isCancelled || userCancelled(id) {
                throw CancellationError()
            }
            switch outcome {
            case .skipped(let reason):
                removeScratch(&scratch)
                let current = records[id] ?? job
                finish(id, .finished(optimal(current, reason: reason, since: started, fingerprint: fingerprint)), duration: nil)
            case .produced(let temp, let ext, let method, let lossless, let note):
                let again = try await Offload.run { token -> SourceFingerprint in
                    if token.isCancelled { throw CancellationError() }
                    return try SourceFingerprint.capture(source)
                }
                guard again == fingerprint else {
                    throw JobError.unreadable("source changed during compression")
                }
                #if DEBUG
                if lossless {
                    try await LosslessVerifier.verify(original: job.request.source, output: temp)
                }
                #endif
                let request = job.request
                let kind = job.kind
                let published = try await Offload.run { token -> OutputWriter.PublishedOutput? in
                    if token.isCancelled { throw CancellationError() }
                    return try OutputWriter.publish(
                        temp: temp,
                        ext: ext,
                        source: request.source,
                        destinationDirectory: directory,
                        settings: request.settings,
                        kind: kind,
                        inputBytes: fingerprint.size,
                        isCancelled: { token.isCancelled || flag.isCancelled })
                }
                removeScratch(&scratch)
                let current = records[id] ?? job
                if let published {
                    let result = JobResult(
                        outcome: .compressed,
                        kind: current.kind,
                        method: method,
                        lossless: lossless,
                        verified: true,
                        inputBytes: fingerprint.size,
                        outputBytes: published.fingerprint.size,
                        outputURL: published.url,
                        note: note,
                        duration: seconds(since: started),
                        sourceFingerprint: fingerprint,
                        outputFingerprint: published.fingerprint)
                    finish(id, .finished(result), duration: nil)
                } else {
                    finish(
                        id,
                        .finished(optimal(current, reason: "below minimum gain", since: started, fingerprint: fingerprint)),
                        duration: nil)
                }
            }
        } catch {
            removeScratch(&scratch)
            let duration = seconds(since: started)
            if userCancelled(id) {
                finish(id, .cancelled, duration: duration)
            } else {
                let mapped = FailureMap.jobError(error)
                if case .diskFull = mapped { pauseQueue() }
                finish(id, .failed(mapped), duration: duration)
            }
        }
        if held { await lanes.release(lane) }
    }

    private func userCancelled(_ id: JobID) -> Bool {
        flags[id]?.isCancelled == true || Task.isCancelled
    }

    private func codec(for kind: FileKind) -> any Codec {
        switch kind {
        case .png: PNGCodec()
        case .jpeg: JPEGCodec()
        case .heic: HEICCodec()
        case .pdf: PDFCodec()
        case .video: VideoCodec()
        case .audio: AudioCodec()
        case .folder: FolderCodec()
        case .generic: GenericCodec()
        }
    }

    private static func measure(_ url: URL, kind: FileKind) throws -> Int64 {
        if kind == .folder { return try FolderSizing.regularFiles(at: url).bytes }
        return try Files.size(url)
    }

    private func destinationDirectory(_ request: JobRequest) throws -> URL {
        let directory: URL
        switch request.settings.output {
        case .nextToOriginal:
            directory = request.source.deletingLastPathComponent()
        case .folder(let url):
            directory = url
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw JobError.outputNotWritable(directory.path)
        }
        return directory
    }

    /// A folder archive must not be written into the tree it is archiving.
    private func rejectDestinationInsideSource(source: URL, directory: URL) throws {
        let sourcePath = canonicalDirectoryPath(source)
        let destPath = canonicalDirectoryPath(directory)
        if destPath == sourcePath || destPath.hasPrefix(sourcePath + "/") {
            throw JobError.outputNotWritable("destination is inside the source folder")
        }
    }

    private func canonicalDirectoryPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func updateIdentity(_ id: JobID, kind: FileKind? = nil, inputBytes: Int64? = nil) {
        guard var job = records[id], !job.state.isTerminal else { return }
        let nextKind = kind ?? job.kind
        let nextBytes = inputBytes ?? job.inputBytes
        guard nextKind != job.kind || nextBytes != job.inputBytes else { return }
        job = Job(
            id: job.id, request: job.request, kind: nextKind, inputBytes: nextBytes,
            createdAt: job.createdAt, state: job.state)
        records[id] = job
        hub.publish(.updated(job))
    }

    private func terminalJob(_ id: JobID) -> Job? {
        if let job = records[id], job.state.isTerminal { return job }
        return tombstones[id]
    }

    private func store(_ job: Job) {
        records[job.id] = job
        order.append(job.id)
        hub.publish(.added(job))
    }

    private func setRunning(_ id: JobID, _ fraction: Double) {
        guard var job = records[id], !job.state.isTerminal else { return }
        job.state = .running(fraction: fraction)
        records[id] = job
        hub.publish(.updated(job))
    }

    private func setProgress(_ id: JobID, _ fraction: Double) {
        guard var job = records[id], case .running(let current) = job.state else { return }
        let next = min(1, max(current, fraction))
        guard next > current else { return }
        job.state = .running(fraction: next)
        records[id] = job
        hub.publish(.updated(job))
    }

    private func finish(_ id: JobID, _ state: JobState, duration: TimeInterval?) {
        guard var job = records[id], !job.state.isTerminal else {
            let settled = records[id] ?? tombstones[id] ?? placeholder(id)
            waiters[id]?.forEach { $0.resume(returning: settled) }
            waiters[id] = nil
            return
        }
        if let duration, case .finished(let result) = state {
            job.state = .finished(JobResult(
                outcome: result.outcome, kind: result.kind, method: result.method,
                lossless: result.lossless, verified: result.verified,
                inputBytes: result.inputBytes, outputBytes: result.outputBytes,
                outputURL: result.outputURL, note: result.note, duration: duration,
                sourceFingerprint: result.sourceFingerprint,
                outputFingerprint: result.outputFingerprint))
        } else {
            job.state = state
        }
        records[id] = job
        tasks[id] = nil
        hub.publish(.updated(job))
        let pending = waiters[id] ?? []
        waiters[id] = nil
        for waiter in pending { waiter.resume(returning: job) }
    }

    private func pauseQueue() {
        paused = true
        guard !announcedPause else { return }
        announcedPause = true
        hub.publish(.paused(reason: "disk full"))
    }

    private func optimal(
        _ job: Job,
        reason: String,
        since start: ContinuousClock.Instant,
        fingerprint: SourceFingerprint?
    ) -> JobResult {
        JobResult(
            outcome: .alreadyOptimal,
            kind: job.kind,
            method: "",
            lossless: true,
            verified: true,
            inputBytes: job.inputBytes,
            outputBytes: job.inputBytes,
            outputURL: nil,
            note: reason,
            duration: seconds(since: start),
            sourceFingerprint: fingerprint)
    }

    private func placeholder(_ id: JobID) -> Job {
        Job(
            id: id,
            request: JobRequest(source: URL(fileURLWithPath: "/"), mode: .lossless, settings: EngineSettings()),
            kind: .generic,
            inputBytes: 0,
            createdAt: Date(),
            state: .cancelled)
    }

    private func removeScratch(_ url: inout URL?) {
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
    }

    private func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let parts = start.duration(to: .now).components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

private final class EventHub: @unchecked Sendable {
    private struct State {
        var jobs: [JobID: Job] = [:]
        var order: [JobID] = []
        var subscribers: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// Registers the subscriber and replays `.added` before returning, so a publish cannot land first.
    func subscribe(_ id: UUID, _ continuation: AsyncStream<EngineEvent>.Continuation) {
        lock.withLock { state in
            state.subscribers[id] = continuation
            for jobID in state.order {
                if let job = state.jobs[jobID] {
                    continuation.yield(.added(job))
                }
            }
        }
    }

    func unsubscribe(_ id: UUID) {
        lock.withLock { $0.subscribers[id] = nil }
    }

    func publish(_ event: EngineEvent) {
        lock.withLock { state in
            switch event {
            case .added(let job):
                if state.jobs[job.id] == nil {
                    state.order.append(job.id)
                }
                state.jobs[job.id] = job
            case .updated(let job):
                guard state.jobs[job.id] != nil else { return }
                state.jobs[job.id] = job
            case .removed(let id):
                state.jobs[id] = nil
                state.order.removeAll { $0 == id }
            case .paused, .resumed:
                break
            }
            for subscriber in state.subscribers.values {
                subscriber.yield(event)
            }
        }
    }
}

private final class ProgressTap: @unchecked Sendable {
    private struct State {
        var value = 0.0
        var at: ContinuousClock.Instant?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let sink: @Sendable (Double) -> Void

    init(_ sink: @escaping @Sendable (Double) -> Void) {
        self.sink = sink
    }

    func report(_ fraction: Double) {
        let now = ContinuousClock.now
        let send: Double? = lock.withLock { state in
            let next = min(1, max(state.value, fraction))
            let elapsed = state.at.map { $0.duration(to: now) } ?? .zero
            let due = state.at == nil || next >= 1 || elapsed >= .milliseconds(66)
            guard due, next > state.value || state.at == nil else {
                state.value = next
                return nil
            }
            state.value = next
            state.at = now
            return next
        }
        if let send { sink(send) }
    }
}
