import Foundation

actor LaneGate {
    private struct Waiter {
        let id: UUID
        let lane: Lane
        let continuation: CheckedContinuation<Void, Error>
    }

    private var cpuLimit: Int
    private let wideLimit = 1
    private let mediaLimit = 2
    private var cpuInUse = 0
    private var wideInUse = 0
    private var mediaInUse = 0
    private var waiters: [Waiter] = []
    private var cancelledWaits: Set<UUID> = []

    init(cpu: Int) {
        self.cpuLimit = max(1, cpu)
    }

    func setCPULimit(_ count: Int) {
        cpuLimit = max(1, count)
        pump()
    }

    /// Returns when a slot is held. Throws `CancellationError` without taking a slot.
    func acquire(_ lane: Lane) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if cancelledWaits.remove(id) != nil || Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                if canEnter(lane) {
                    enter(lane)
                    cont.resume()
                    return
                }
                waiters.append(Waiter(id: id, lane: lane, continuation: cont))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release(_ lane: Lane) {
        switch lane {
        case .cpu: cpuInUse = max(0, cpuInUse - 1)
        case .wide: wideInUse = max(0, wideInUse - 1)
        case .media: mediaInUse = max(0, mediaInUse - 1)
        }
        pump()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            cancelledWaits.insert(id)
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func limit(_ lane: Lane) -> Int {
        switch lane {
        case .cpu: cpuLimit
        case .wide: wideLimit
        case .media: mediaLimit
        }
    }

    private func inUse(_ lane: Lane) -> Int {
        switch lane {
        case .cpu: cpuInUse
        case .wide: wideInUse
        case .media: mediaInUse
        }
    }

    private func canEnter(_ lane: Lane) -> Bool { inUse(lane) < limit(lane) }

    private func enter(_ lane: Lane) {
        switch lane {
        case .cpu: cpuInUse += 1
        case .wide: wideInUse += 1
        case .media: mediaInUse += 1
        }
    }

    /// FIFO within a lane. A free lane is not blocked behind a saturated one.
    private func pump() {
        var blocked = Set<Lane>()
        var index = 0
        while index < waiters.count {
            let lane = waiters[index].lane
            if blocked.contains(lane) || !canEnter(lane) {
                blocked.insert(lane)
                index += 1
                continue
            }
            let waiter = waiters.remove(at: index)
            enter(waiter.lane)
            waiter.continuation.resume()
        }
    }
}
