import Foundation
import OLogNKit
import os
import Synchronization

/// State shared with the signal handlers.
enum Interrupt {
    static let signal = Atomic<Int32>(0)
    static let engine = OSAllocatedUnfairLock<CompressionEngine?>(initialState: nil)
}

@main
enum OLogNCLI {
    static func main() async {
        installInterruptHandlers()
        let code = await run(Array(CommandLine.arguments.dropFirst()))
        let signalNumber = Interrupt.signal.load(ordering: .relaxed)
        exit(signalNumber != 0 ? 128 + signalNumber : code)
    }

    /// ⌃C / SIGTERM: stop spawned tools, cancel running jobs, and let them remove their scratch before exiting
    /// 130 / 143. The jobs unwind normally and `main` exits. A second signal, or 10 s without unwinding,
    /// forces the exit.
    private static func installInterruptHandlers() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
            source.setEventHandler {
                if Interrupt.signal.exchange(signalNumber, ordering: .relaxed) != 0 {
                    exit(128 + signalNumber)
                }
                ChildProcesses.terminateAll()
                if let engine = Interrupt.engine.withLock({ $0 }) {
                    Task.detached { await engine.cancelAll() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) { exit(128 + signalNumber) }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    nonisolated(unsafe) private static var signalSources: [any DispatchSourceSignal] = []

    static func run(_ arguments: [String]) async -> Int32 {
        guard let command = arguments.first else {
            usage()
            return 2
        }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "compress":
            return await compress(rest)
        case "verify":
            return await verify(rest)
        case "kind":
            return kind(rest)
        case "-h", "--help", "help":
            usage()
            return 2
        default:
            fputs("unknown command \(command)\n", stderr)
            usage()
            return 2
        }
    }

    private static func compress(_ arguments: [String]) async -> Int32 {
        var mode = CompressionMode.smart
        var settings = EngineSettings()
        var json = false
        var paths: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func value() -> String? {
                guard index + 1 < arguments.count else { return nil }
                index += 1
                return arguments[index]
            }
            switch argument {
            case "--mode":
                guard let raw = value(), let parsed = CompressionMode(rawValue: raw) else { usage(); return 2 }
                mode = parsed
            case "--quality":
                guard let raw = value(), let parsed = QualityPreset(rawValue: raw) else { usage(); return 2 }
                settings.quality = parsed
            case "--archive":
                guard let raw = value(), let parsed = ArchiveFormat(rawValue: raw) else { usage(); return 2 }
                settings.archiveFormat = parsed
            case "--convert":
                guard let raw = value(), let parsed = ImageConversion(rawValue: raw) else { usage(); return 2 }
                settings.imageConversion = parsed
            case "--out":
                guard let raw = value() else { usage(); return 2 }
                settings.output = .folder(URL(fileURLWithPath: raw).standardizedFileURL)
            case "--suffix":
                guard let raw = value() else { usage(); return 2 }
                settings.suffix = raw
            case "--jpeg-lossless":
                guard let raw = value(), let parsed = JPEGLosslessStyle(rawValue: raw) else { usage(); return 2 }
                settings.jpegLossless = parsed
            case "--jobs":
                guard let raw = value(), let jobs = Int(raw), jobs > 0 else { usage(); return 2 }
                settings.maxCPUJobs = jobs
            case "--json":
                json = true
            case "--":
                paths.append(contentsOf: arguments[(index + 1)...])
                index = arguments.count
            default:
                if argument.hasPrefix("-") {
                    fputs("unknown option \(argument)\n", stderr)
                    usage()
                    return 2
                }
                paths.append(argument)
            }
            index += 1
        }
        if paths.isEmpty {
            usage()
            return 2
        }
        let urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let started = ContinuousClock.now
        let engine = CompressionEngine()
        Interrupt.engine.withLock { $0 = engine }
        let ids = await engine.submit(urls, mode: mode, settings: settings)
        var jobs: [Job] = []
        for id in ids {
            jobs.append(await engine.waitUntilFinished(id))
        }
        let wall = seconds(since: started)
        if json {
            let objects = jobs.enumerated().map { offset, job in
                jsonObject(job, wall: ids.count == 1 ? wall : jobDuration(job, wall: wall))
            }
            guard let data = try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys]),
                  var text = String(data: data, encoding: .utf8) else {
                fputs("could not encode json\n", stderr)
                return 1
            }
            if !text.hasSuffix("\n") { text.append("\n") }
            print(text, terminator: "")
        } else {
            for job in jobs {
                print(human(job))
            }
        }
        return jobs.contains { if case .failed = $0.state { true } else { false } } ? 1 : 0
    }

    private static func verify(_ arguments: [String]) async -> Int32 {
        guard arguments.count == 2 else {
            usage()
            return 2
        }
        let original = URL(fileURLWithPath: arguments[0]).standardizedFileURL
        let output = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        do {
            try await LosslessVerifier.verify(original: original, output: output)
            print("identical")
            return 0
        } catch let error as JobError {
            let message = describe(error)
            fputs(message + "\n", stderr)
            return message.hasPrefix("unsupported") ? 2 : 1
        } catch {
            fputs(error.localizedDescription + "\n", stderr)
            return 1
        }
    }

    private static func kind(_ arguments: [String]) -> Int32 {
        guard arguments.count == 1 else {
            usage()
            return 2
        }
        let url = URL(fileURLWithPath: arguments[0]).standardizedFileURL
        do {
            let kind = try Router.kind(of: url)
            print(kind.rawValue)
            return 0
        } catch let error as JobError {
            fputs(describe(error) + "\n", stderr)
            return 1
        } catch {
            fputs(error.localizedDescription + "\n", stderr)
            return 1
        }
    }

    private static func jsonObject(_ job: Job, wall: TimeInterval) -> [String: Any] {
        let input = job.request.source.path
        var output: Any = NSNull()
        var outcome = "failed"
        var method = ""
        var lossless = false
        var verified = false
        var outputBytes = job.inputBytes
        var note: Any = NSNull()
        var error: Any = NSNull()
        var duration = wall
        switch job.state {
        case .finished(let result):
            outcome = result.outcome.rawValue
            method = result.method
            lossless = result.lossless
            verified = result.verified
            outputBytes = result.outputBytes
            note = result.note ?? NSNull()
            duration = result.duration
            if result.outcome == .compressed, let url = result.outputURL {
                output = url.path
            }
        case .failed(let jobError):
            outcome = "failed"
            error = describe(jobError)
        case .cancelled:
            outcome = "cancelled"
        case .queued, .running:
            outcome = "failed"
            error = "not finished"
        }
        let saved = max(0, job.inputBytes - outputBytes)
        let percent: Double
        if job.inputBytes > 0 {
            percent = (Double(saved) * 10_000 / Double(job.inputBytes)).rounded() / 100
        } else {
            percent = 0
        }
        return [
            "input": input,
            "output": output,
            "kind": job.kind.rawValue,
            "mode": job.request.mode.rawValue,
            "outcome": outcome,
            "method": method,
            "lossless": lossless,
            "verified": verified,
            "inputBytes": job.inputBytes,
            "outputBytes": outputBytes,
            "savedPercent": percent,
            "durationMs": Int((duration * 1000).rounded()),
            "note": note,
            "error": error,
        ]
    }

    private static func human(_ job: Job) -> String {
        let name = job.request.source.lastPathComponent
        let input = megabytes(job.inputBytes)
        switch job.state {
        case .finished(let result):
            let output = megabytes(result.outputBytes)
            let label = result.method.isEmpty ? (result.note ?? "already optimal") : result.method
            return "\(name)  \(input) → \(output)  \(percent(result.savedFraction))  \(label)  \(secondsText(result.duration))"
        case .failed(let error):
            return "\(name)  \(input) → \(input)  −0.0%  \(describe(error))  0.00s"
        case .cancelled:
            return "\(name)  \(input) → \(input)  −0.0%  cancelled  0.00s"
        case .queued, .running:
            return "\(name)  \(input) → \(input)  −0.0%  running  0.00s"
        }
    }

    private static func percent(_ fraction: Double) -> String {
        String(format: "−%.1f%%", fraction * 100)
    }

    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    private static func secondsText(_ duration: TimeInterval) -> String {
        String(format: "%.2fs", duration)
    }

    private static func jobDuration(_ job: Job, wall: TimeInterval) -> TimeInterval {
        if case .finished(let result) = job.state { return result.duration }
        return wall
    }

    private static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let parts = start.duration(to: .now).components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    private static func describe(_ error: JobError) -> String {
        switch error {
        case .unreadable(let message): message
        case .outputNotWritable(let message): message
        case .diskFull: "disk full"
        case .verificationFailed(let message): message
        case .codec(let message): message
        }
    }

    private static func usage() {
        let text = """
        ologn-cli compress <paths…> [--mode smart|lossless] [--quality compact|balanced|studio] [--archive xz|zip] [--convert keep|heic|avif] [--jpeg-lossless pixelExact|progressive] [--out <dir>] [--suffix <s>] [--jobs <n>] [--json]
        ologn-cli verify <original> <output>
        ologn-cli kind <path>
        """
        fputs(text + "\n", stderr)
    }
}
