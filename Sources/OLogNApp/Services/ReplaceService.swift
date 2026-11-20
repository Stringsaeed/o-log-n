import Foundation
import OLogNKit

// Invariant: no Reveal, Preview, Copy, drag-out, Trash Output, Replace or Undo may act on a file
// unless its identity matches a stamp the engine recorded. Destructive operations must re-check
// identity on the same queue immediately before acting.
//
// Invariant: no sequence of user actions may lose the only copy of a file, overwrite a file
// Logn did not create, or leave a card pointing at a file that is not its output.
//
// The code enforces that as follows.
// 1. Replace refuses before any mutation unless the source on disk still matches the fingerprint
//    taken when compression started and the output still matches the fingerprint taken when the
//    job finished. A missing output is not a reason to trash the source.
// 2. The only destructive steps are "move the original to the Trash" and "exclusive-move the
//    output onto a path that does not exist". If a later step fails, the earlier move is reversed
//    before the error is thrown. If the reverse itself fails, the thrown record describes where
//    the bytes actually are and the caller keeps it until a later undo succeeds.
// 3. Undo moves a file only after its fingerprint matches the file this swap installed. Any other
//    occupant of a path is left untouched. The URL returned to the caller is the path the output
//    bytes landed on, or nil when those bytes are no longer a file we can identify.
//
// Every method here does file I/O. Call them only from `JobFileWork` (a background serial queue).

enum ReplaceError: Error, Equatable, Sendable {
    case notAllowed
    case sourceMissing
    case sourceChanged
    case outputMissing
    case outputChanged
    case trashFailed
    case notInTrash
    case occupied
    case io(String)
    /// A mutation stuck. The record is the recovery handle and must be kept.
    case incomplete(ReplaceRecord)

    var trayMessage: String {
        switch self {
        case .notAllowed:
            "Nothing to replace"
        case .sourceMissing:
            "The original is missing"
        case .sourceChanged:
            "The original changed after compression"
        case .outputMissing:
            "The compressed file is missing"
        case .outputChanged:
            "The compressed file is no longer the one Logn wrote"
        case .trashFailed:
            "Couldn't move the original to the Trash"
        case .notInTrash:
            "Original no longer in Trash"
        case .occupied:
            "A file is in the way"
        case .io(let detail):
            detail.isEmpty ? "Couldn't finish the file operation" : detail
        case .incomplete:
            "Replace didn't finish. The original is in the Trash — undo to put it back."
        }
    }
}

struct ReplaceRecord: Equatable, Sendable {
    var jobID: JobID
    var originalURL: URL
    var outputBefore: URL
    var movedTo: URL?
    var trashedURL: URL
    var extensionChanged: Bool
    var displayName: String
    /// Fingerprint of the file this swap installed, captured after it landed. Nil if it could not be read.
    var installedFingerprint: SourceFingerprint?
    /// Fingerprint of the original as it went into the Trash. Undo restores only that file.
    var trashedFingerprint: SourceFingerprint?
}

/// Where Undo left Logn's output, and the stamp taken on this queue immediately after that move.
struct UndoOutcome: Sendable, Equatable {
    var url: URL?
    var fingerprint: SourceFingerprint?
}

struct ReplaceRequest: Sendable {
    var jobID: JobID
    var original: URL
    var output: URL
    var kind: FileKind
    var sourceFingerprint: SourceFingerprint
    var outputFingerprint: SourceFingerprint
    var displayName: String
}

enum ReplaceService {
    static func replace(_ request: ReplaceRequest) throws -> ReplaceRecord {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let original = request.original
        let output = request.output
        // Folder Replace is disabled in v1: a folder fingerprint can't prove the tree is unchanged.
        // Refuse here too, not only in the store and UI, so no caller can reach `trashItem` for a folder.
        guard request.kind != .folder else { throw ReplaceError.notAllowed }
        guard original.standardizedFileURL != output.standardizedFileURL else { throw ReplaceError.notAllowed }
        guard fileExists(original) else { throw ReplaceError.sourceMissing }
        guard identity(original, request.sourceFingerprint) else { throw ReplaceError.sourceChanged }
        guard fileExists(output) else { throw ReplaceError.outputMissing }
        guard identity(output, request.outputFingerprint) else { throw ReplaceError.outputChanged }

        let archive = request.kind == .folder || request.kind == .generic
        let sameExtension = output.pathExtension.lowercased() == original.pathExtension.lowercased()
        let trashed = try trash(original)
        guard !fileExists(original) else { throw ReplaceError.trashFailed }
        var record = ReplaceRecord(
            jobID: request.jobID,
            originalURL: original,
            outputBefore: output,
            movedTo: nil,
            trashedURL: trashed,
            extensionChanged: archive || !sameExtension,
            displayName: request.displayName,
            installedFingerprint: request.outputFingerprint,
            trashedFingerprint: request.sourceFingerprint)
        do {
            // Re-check right before the output is used: it may have been swapped while the original moved.
            guard fileExists(output), identity(output, request.outputFingerprint) else {
                throw ReplaceError.outputChanged
            }
            if archive {
                guard fileExists(output), identity(output, request.outputFingerprint) else {
                    throw ReplaceError.outputMissing
                }
                return record
            }
            let destination = try placeOutput(output: output, original: original, sameExtension: sameExtension)
            // Path checks can't close the gap between the check above and the rename, so verify what
            // actually landed. If it isn't Logn's output, put it back where it was and undo the trash.
            let crossVolume = onDifferentVolumes(output, original)
            guard landedIsOutput(destination, expected: request.outputFingerprint, crossVolume: crossVolume) else {
                _ = FileMove.exclusive(from: destination, to: output)
                throw ReplaceError.outputChanged
            }
            record.movedTo = destination
            record.installedFingerprint = try? SourceFingerprint.capture(destination)
            record.extensionChanged = !sameExtension
            return record
        } catch let error as ReplaceError {
            try rollbackTrash(trashed, to: original, record: record, error: error)
        } catch {
            try rollbackTrash(trashed, to: original, record: record, error: .io(error.localizedDescription))
        }
    }

    /// Restores the original. The URL is where Logn's output landed, or nil when that file is gone
    /// or is no longer one Logn installed. The fingerprint is taken on this queue immediately after
    /// the move, from the file this call just placed.
    static func undo(_ record: ReplaceRecord) throws -> UndoOutcome {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard fileExists(record.trashedURL) else { throw ReplaceError.notInTrash }
        // Restore only the file Replace put in the Trash, never whatever now sits at that path.
        guard let trashedStamp = record.trashedFingerprint, identity(record.trashedURL, trashedStamp) else {
            throw ReplaceError.notInTrash
        }

        var restored: URL?
        var stamp: SourceFingerprint?
        if let moved = record.movedTo {
            if fileExists(moved) {
                guard let expected = record.installedFingerprint, identity(moved, expected) else {
                    throw ReplaceError.outputChanged
                }
                if moved.standardizedFileURL != record.originalURL.standardizedFileURL, fileExists(record.originalURL) {
                    throw ReplaceError.occupied
                }
                let destination = try relocate(from: moved, preferred: record.outputBefore)
                restored = destination
                stamp = try? SourceFingerprint.capture(destination)
                do {
                    try restore(trashed: record.trashedURL, to: record.originalURL)
                } catch let error as ReplaceError {
                    if destination.standardizedFileURL != moved.standardizedFileURL {
                        switch FileMove.exclusive(from: destination, to: moved) {
                        case .stored:
                            throw error
                        case .exists, .failed:
                            var stuck = record
                            stuck.movedTo = destination
                            stuck.installedFingerprint = try? SourceFingerprint.capture(destination)
                            throw ReplaceError.incomplete(stuck)
                        }
                    }
                    throw error
                }
                return UndoOutcome(url: restored, fingerprint: stamp)
            }
            restored = nil
        } else if let expected = record.installedFingerprint, identity(record.outputBefore, expected) {
            restored = record.outputBefore
            stamp = expected
        }

        if fileExists(record.originalURL) { throw ReplaceError.occupied }
        try restore(trashed: record.trashedURL, to: record.originalURL)
        return UndoOutcome(url: restored, fingerprint: stamp)
    }

    /// Trashes `url` only when it still matches `expected` at the moment of the trash.
    /// Both the check and the trash run on the caller's queue. There is no gap between them.
    static func discard(_ url: URL, expected: SourceFingerprint) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard fileExists(url), identity(url, expected) else { throw ReplaceError.outputChanged }
        _ = try trash(url)
    }

    private static func placeOutput(output: URL, original: URL, sameExtension: Bool) throws -> URL {
        if sameExtension {
            switch FileMove.exclusive(from: output, to: original) {
            case .stored:
                return original
            case .exists:
                throw ReplaceError.occupied
            case .failed(let message):
                throw ReplaceError.io(message)
            }
        }
        let directory = original.deletingLastPathComponent()
        let stem = original.deletingPathExtension().lastPathComponent
        let ext = output.pathExtension
        for attempt in 1...10_000 {
            let destination = FileNames.candidate(directory: directory, stem: stem, ext: ext, attempt: attempt)
            switch FileMove.exclusive(from: output, to: destination) {
            case .stored:
                return destination
            case .exists:
                continue
            case .failed(let message):
                throw ReplaceError.io(message)
            }
        }
        throw ReplaceError.io("could not find a free name")
    }

    private static func relocate(from: URL, preferred: URL) throws -> URL {
        switch FileMove.exclusive(from: from, to: preferred) {
        case .stored:
            return preferred
        case .exists:
            break
        case .failed(let message):
            throw ReplaceError.io(message)
        }
        let directory = preferred.deletingLastPathComponent()
        let ext = preferred.pathExtension
        let stem = preferred.deletingPathExtension().lastPathComponent
        for attempt in 2...10_000 {
            let candidate = FileNames.candidate(directory: directory, stem: stem, ext: ext, attempt: attempt)
            switch FileMove.exclusive(from: from, to: candidate) {
            case .stored:
                return candidate
            case .exists:
                continue
            case .failed(let message):
                throw ReplaceError.io(message)
            }
        }
        throw ReplaceError.io("could not find a free name")
    }

    private static func rollbackTrash(
        _ trashed: URL,
        to original: URL,
        record: ReplaceRecord,
        error: ReplaceError
    ) throws -> Never {
        switch FileMove.exclusive(from: trashed, to: original) {
        case .stored:
            throw error
        case .exists, .failed:
            throw ReplaceError.incomplete(record)
        }
    }

    private static func restore(trashed: URL, to original: URL) throws {
        switch FileMove.exclusive(from: trashed, to: original) {
        case .stored:
            return
        case .exists:
            throw ReplaceError.occupied
        case .failed(let message):
            throw ReplaceError.io(message)
        }
    }

    private static func trash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        } catch {
            throw ReplaceError.trashFailed
        }
        guard let trashed = resulting as URL?, fileExists(trashed) else { throw ReplaceError.trashFailed }
        return trashed
    }

    private static func identity(_ url: URL, _ expected: SourceFingerprint) -> Bool {
        guard let now = try? SourceFingerprint.capture(url) else { return false }
        return now == expected
    }

    /// Verifies the file `placeOutput` just moved. A same-volume rename keeps the file ID, so the stamp
    /// must match exactly. A cross-volume move is a copy (new file ID) that keeps size and the
    /// modification date, so only those must match, and only when the two folders really are on
    /// different volumes.
    private static func landedIsOutput(_ landed: URL, expected: SourceFingerprint, crossVolume: Bool) -> Bool {
        guard let now = try? SourceFingerprint.capture(landed) else { return false }
        if now == expected { return true }
        return crossVolume && now.size == expected.size && now.modificationDate == expected.modificationDate
    }

    private static func onDifferentVolumes(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let va = try? a.deletingLastPathComponent().resourceValues(forKeys: key).volumeIdentifier as? NSObject,
              let vb = try? b.deletingLastPathComponent().resourceValues(forKeys: key).volumeIdentifier as? NSObject
        else { return false }
        return !va.isEqual(vb)
    }

    private static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
