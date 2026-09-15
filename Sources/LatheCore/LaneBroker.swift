import Foundation

/// Hands out permission to start work, respecting a total and a per-class limit.
///
/// An actor rather than a semaphore because the two limits interact: a permit
/// freed by a finished video does not necessarily let a waiting image start, and
/// a plain counting semaphore cannot express that. The broker decides who is
/// next by looking at what is actually running.
///
/// ## Cancellation
///
/// A waiter suspended here must be resumable by cancellation, or a cancelled
/// bulk run hangs on the first job that never got a lane. Waiters are therefore
/// registered under an identifier that the cancellation handler can use to
/// resume them, and ``acquire(_:)`` reports whether it was cancelled rather than
/// throwing, so the caller records the item as cancelled rather than losing it.
actor LaneBroker {

    private let pool: ResourcePool
    private var active = 0
    private var activeByWorkload: [Workload: Int] = [:]

    private struct Waiter {
        let workload: Workload
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var waiters: [UUID: Waiter] = [:]
    /// Waiting order, kept separately so the wake-up is first-come-first-served
    /// within what is eligible. Without it a dictionary's arbitrary order would
    /// let one item wait behind later arrivals indefinitely.
    private var waitOrder: [UUID] = []

    init(pool: ResourcePool) {
        self.pool = pool
    }

    /// Current occupancy, for tests and diagnostics.
    var occupancy: (total: Int, byWorkload: [Workload: Int]) {
        (active, activeByWorkload)
    }

    /// Waits until a lane is free for `workload`.
    ///
    /// - Returns: `false` if the wait was cancelled, in which case **no lane was
    ///   taken** and the caller must not release one.
    func acquire(_ workload: Workload) async -> Bool {
        if Task.isCancelled { return false }
        if canStart(workload) {
            take(workload)
            return true
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                // Re-checked inside the continuation: cancellation can land
                // between the check above and here, and a waiter registered
                // after the handler has already run would never be woken.
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                waiters[id] = Waiter(workload: workload, continuation: continuation)
                waitOrder.append(id)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Gives a lane back and starts whoever can use it.
    func release(_ workload: Workload) {
        active = Swift.max(0, active - 1)
        activeByWorkload[workload] = Swift.max(0, (activeByWorkload[workload] ?? 1) - 1)
        wakeNext()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waitOrder.removeAll { $0 == id }
        waiter.continuation.resume(returning: false)
    }

    /// Starts the first waiter that can now run.
    ///
    /// Only one, because exactly one lane was freed. Scanning past an ineligible
    /// waiter matters: the freed lane may belong to a class nobody at the front
    /// of the queue is waiting for, and stopping at the first ineligible waiter
    /// would idle a lane while work sat ready.
    private func wakeNext() {
        for (index, id) in waitOrder.enumerated() {
            guard let waiter = waiters[id], canStart(waiter.workload) else { continue }
            waiters.removeValue(forKey: id)
            waitOrder.remove(at: index)
            // The lane is taken here, on the waiter's behalf, BEFORE it resumes.
            // Letting the resumed task take it itself would leave a window in
            // which another acquirer could claim the same lane.
            take(waiter.workload)
            waiter.continuation.resume(returning: true)
            return
        }
    }

    private func canStart(_ workload: Workload) -> Bool {
        active < pool.totalLanes
            && (activeByWorkload[workload] ?? 0) < pool.lanes(for: workload)
    }

    private func take(_ workload: Workload) {
        active += 1
        activeByWorkload[workload, default: 0] += 1
    }
}
