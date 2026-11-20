import Foundation
import os

final class CancelFlag: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { state.withLock { $0 } }
    func cancel() { state.withLock { $0 = true } }
}

enum Offload {
    /// Runs `body` on the user-initiated queue. The flag flips when the calling task is cancelled.
    static func run<T: Sendable>(_ body: @escaping @Sendable (CancelFlag) throws -> T) async throws -> T {
        let token = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        cont.resume(returning: try body(token))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            token.cancel()
        }
    }
}

enum FailureMap {
    static func jobError(_ error: Error) -> JobError {
        if let job = error as? JobError { return job }
        if error is CancellationError { return .codec("cancelled") }
        if isDiskFull(error as NSError) { return .diskFull }
        return .codec((error as NSError).localizedDescription)
    }

    private static func isDiskFull(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC) { return true }
        if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, isDiskFull(underlying) {
            return true
        }
        if let many = error.userInfo[NSUnderlyingErrorKey] as? [NSError], many.contains(where: isDiskFull) {
            return true
        }
        return error.underlyingErrors.contains { isDiskFull($0 as NSError) }
    }
}
