import Foundation

/// Where a card's output file is. `.pinned(nil)` means the card must not claim a file.
enum OutputPin: Equatable, Sendable {
    case engine
    case pinned(URL?)

    func resolved(engineURL: URL?, replacedLocation: URL?) -> URL? {
        switch self {
        case .engine:
            if let replacedLocation { return replacedLocation }
            return engineURL
        case .pinned(let url):
            return url
        }
    }
}

enum UndoApplication {
    /// A failed undo keeps the recovery record. A file we can no longer prove is ours is unpinned
    /// so the card stops pointing at it.
    static func apply(error: ReplaceError, pin: inout OutputPin, replacedLocation: inout URL?) {
        switch error {
        case .outputChanged, .outputMissing:
            pin = .pinned(nil)
            replacedLocation = nil
        case .notAllowed, .sourceMissing, .sourceChanged, .trashFailed, .notInTrash, .occupied, .io, .incomplete:
            break
        }
    }
}

/// Peek, then drop the top action only after it succeeded.
struct UndoLedger {
    private(set) var actions: [UndoAction] = []

    var count: Int { actions.count }

    func peek() -> UndoAction? { actions.last }

    mutating func push(_ action: UndoAction) {
        actions.append(action)
    }

    mutating func commitSuccess() {
        _ = actions.popLast()
    }

    mutating func dropTop() {
        _ = actions.popLast()
    }

    mutating func replaceTop(_ action: UndoAction) {
        guard !actions.isEmpty else {
            actions.append(action)
            return
        }
        actions[actions.count - 1] = action
    }
}
