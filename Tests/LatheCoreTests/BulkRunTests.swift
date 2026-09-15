import Foundation
import Testing

@testable import LatheCore

/// Running many pieces of work at once inside a pool.
///
/// The tests that matter watch how many things are running *at the same time*,
/// because that is the whole promise and it is not visible in the result. A
/// runner that ignored its limits entirely would pass every test that only
/// checked the outputs.
@Suite("Bulk runs")
struct BulkRunTests {

    /// Records the high-water mark of concurrent work, in total and per class.
    actor ConcurrencyWatch {
        private var active = 0
        private var activeByWorkload: [Workload: Int] = [:]
        private(set) var peak = 0
        private(set) var peakByWorkload: [Workload: Int] = [:]

        func enter(_ workload: Workload) {
            active += 1
            activeByWorkload[workload, default: 0] += 1
            peak = Swift.max(peak, active)
            peakByWorkload[workload] = Swift.max(
                peakByWorkload[workload] ?? 0, activeByWorkload[workload] ?? 0
            )
        }

        func leave(_ workload: Workload) {
            active -= 1
            activeByWorkload[workload, default: 1] -= 1
        }
    }

    // MARK: - The limits

    /// **The headline: the total lane count is never exceeded.**
    @Test("no more than the pool's total run at once")
    func respectsTheTotalLimit() async {
        let watch = ConcurrencyWatch()
        let runner = BulkRun(pool: ResourcePool(totalLanes: 3))

        let report = await runner.run(Array(0..<40), workload: .image) { value in
            await watch.enter(.image)
            try? await Task.sleep(nanoseconds: 2_000_000)
            await watch.leave(.image)
            return value * 2
        }

        let peak = await watch.peak
        #expect(peak <= 3, "\(peak) ran at once with a 3-lane pool")
        #expect(peak > 1, "nothing ran concurrently; the pool serialised everything")
        #expect(report.succeeded.count == 40)
    }

    /// **A class's own limit holds even when there is total headroom**, which is
    /// the reason the pool is not one number: two videos and eight images should
    /// run together, not ten of whichever arrived first.
    @Test("a class limit holds even with plenty of total room")
    func respectsPerClassLimits() async {
        let watch = ConcurrencyWatch()
        let runner = BulkRun(pool: ResourcePool(
            totalLanes: 12, lanes: [.video: 2, .image: 8]
        ))

        var items: [BulkRun.Item<Int>] = []
        for index in 0..<20 { items.append(.init(index, workload: .video)) }
        for index in 20..<60 { items.append(.init(index, workload: .image)) }

        let report = await runner.run(items) { value in
            let workload: Workload = value < 20 ? .video : .image
            await watch.enter(workload)
            try? await Task.sleep(nanoseconds: 2_000_000)
            await watch.leave(workload)
            return value
        }

        let peaks = await watch.peakByWorkload
        let total = await watch.peak
        #expect((peaks[.video] ?? 0) <= 2, "\(peaks[.video] ?? 0) videos ran at once, limit 2")
        #expect((peaks[.image] ?? 0) <= 8, "\(peaks[.image] ?? 0) images ran at once, limit 8")
        #expect(total <= 12)
        #expect(report.succeeded.count == 60)
    }

    /// A lane freed by one class must not idle while another class has work
    /// ready — the broker scans past an ineligible waiter for exactly this.
    @Test("a freed lane is given to whoever can use it, not only to the front of the queue")
    func aFreedLaneGoesToSomeoneEligible() async {
        let watch = ConcurrencyWatch()
        // Video is capped at 1, so after the first video starts, every other
        // video waits. The images behind them must still run.
        let runner = BulkRun(pool: ResourcePool(totalLanes: 4, lanes: [.video: 1]))

        var items = (0..<8).map { BulkRun.Item($0, workload: .video) }
        items += (8..<16).map { BulkRun.Item($0, workload: .image) }

        let report = await runner.run(items) { value in
            let workload: Workload = value < 8 ? .video : .image
            await watch.enter(workload)
            try? await Task.sleep(nanoseconds: 2_000_000)
            await watch.leave(workload)
            return value
        }

        let peaks = await watch.peakByWorkload
        #expect((peaks[.video] ?? 0) == 1)
        #expect((peaks[.image] ?? 0) > 1,
                "images never ran concurrently — they were stuck behind the video queue")
        #expect(report.succeeded.count == 16)
    }

    @Test("a serial pool runs exactly one at a time")
    func serialPoolIsSerial() async {
        let watch = ConcurrencyWatch()
        let report = await BulkRun(pool: .serial).run(Array(0..<12), workload: .audio) { value in
            await watch.enter(.audio)
            try? await Task.sleep(nanoseconds: 1_000_000)
            await watch.leave(.audio)
            return value
        }
        #expect(await watch.peak == 1)
        #expect(report.succeeded.count == 12)
    }

    // MARK: - Failure

    /// **One bad file does not end the run.** A bulk pass over a library meets a
    /// corrupt file eventually, and abandoning the other nine hundred is the
    /// wrong answer.
    @Test("one failure does not stop the others, and is reported against its input")
    func failuresAreIsolated() async {
        struct Boom: Error, Equatable { var index: Int }

        let report = await BulkRun(pool: ResourcePool(totalLanes: 4))
            .run(Array(0..<30), workload: .image) { value in
                if value % 7 == 3 { throw Boom(index: value) }
                return value
            }

        #expect(report.outcomes.count == 30)
        #expect(!report.isCompleteSuccess)
        let expectedFailures = (0..<30).filter { $0 % 7 == 3 }
        #expect(report.failures.count == expectedFailures.count)
        #expect(report.succeeded.count == 30 - expectedFailures.count)

        // And a caller can tell WHICH inputs failed, which is what a retry pass
        // and a report to the user both need.
        let failedInputs = report.failedInputs.map(\.input).sorted()
        #expect(failedInputs == expectedFailures)
    }

    /// Results must line up with what was submitted, whatever order they
    /// finished in — otherwise a caller has to match on identity.
    @Test("outcomes come back in submission order, not completion order")
    func resultsAreInSubmissionOrder() async {
        let report = await BulkRun(pool: ResourcePool(totalLanes: 8))
            .run(Array(0..<40), workload: .image) { value in
                // Later items finish first.
                try? await Task.sleep(nanoseconds: UInt64((40 - value) * 200_000))
                return value * 10
            }

        #expect(report.outcomes.count == 40)
        for (index, outcome) in report.outcomes.enumerated() {
            let note = "position \(index) held \(String(describing: outcome.value))"
            #expect(outcome.value == index * 10, "\(note)")
        }
        #expect(report.inputs == Array(0..<40))
    }

    // MARK: - Cancellation

    /// **Cancelling must return, not hang.** Items waiting for a lane that will
    /// never free are the ones that hang a naive implementation, and they are
    /// the majority of a large run.
    @Test("cancelling a run returns promptly and accounts for every item")
    func cancellationReturnsAndAccountsForEverything() async {
        let runner = BulkRun(pool: ResourcePool(totalLanes: 2))
        let started = Date()

        let task = Task {
            await runner.run(Array(0..<200), workload: .image) { value in
                try await Task.sleep(nanoseconds: 50_000_000)
                return value
            }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        let report = await task.value

        let elapsed = Date().timeIntervalSince(started)
        let note = "cancelling took \(elapsed)s — something waited on a lane that was never "
            + "going to free"
        #expect(elapsed < 5, "\(note)")
        // Every item is accounted for. A cancelled run that silently returned
        // fewer outcomes than inputs would misalign against the submission list.
        #expect(report.outcomes.count == 200)
        #expect(report.cancelledCount > 0, "nothing was reported cancelled")
    }

    @Test("an already-cancelled run does no work")
    func alreadyCancelledDoesNothing() async {
        let ran = Counter()
        let task = Task {
            await BulkRun(pool: ResourcePool(totalLanes: 4))
                .run(Array(0..<50), workload: .image) { value in
                    await ran.increment()
                    return value
                }
        }
        task.cancel()
        let report = await task.value

        #expect(report.outcomes.count == 50)
        let count = await ran.value
        #expect(count < 50, "\(count) of 50 items ran after the run was cancelled")
    }

    // MARK: - Edges

    @Test("an empty run is not an error")
    func emptyRun() async {
        let report = await BulkRun().run([Int](), workload: .image) { $0 }
        #expect(report.outcomes.isEmpty)
        #expect(report.isCompleteSuccess, "a run with nothing in it succeeded at everything")
    }

    @Test("progress counts every item exactly once")
    func progressReachesTheEnd() async {
        let sink = RecordingSink()
        let handle = ProgressHandle(sink: sink, throttle: .unthrottled)

        _ = await BulkRun(pool: ResourcePool(totalLanes: 4))
            .run(Array(0..<20), workload: .image, progress: handle) { $0 }

        let last = sink.last
        #expect(last?.unitIndex == 20)
        #expect(last?.unitCount == 20)
    }

    // MARK: - The automatic pool

    /// The numbers are reasoned, and the reasoning is the thing to protect: a
    /// machine with more cores must not be given more video lanes, because it
    /// does not have more video encoders.
    @Test("more cores buys more CPU lanes, and no more video lanes")
    func automaticPoolScalesTheRightThings() {
        let small = ResourcePool.automatic(cores: 4, thermalState: .nominal, lowPower: false)
        let large = ResourcePool.automatic(cores: 24, thermalState: .nominal, lowPower: false)

        #expect(large.lanes(for: .image) > small.lanes(for: .image),
                "more cores should mean more image lanes")
        #expect(large.lanes(for: .video) == small.lanes(for: .video),
                "video lanes scaled with cores; a 24-core machine has no more encoders")
        #expect(large.lanes(for: .recognition) == small.lanes(for: .recognition),
                "there is one Neural Engine however many cores there are")
    }

    /// Network is not tied to cores at all: a stalled transfer occupies none.
    @Test("network lanes are not the core count")
    func networkIsNotCoreBound() {
        let pool = ResourcePool.automatic(cores: 2, thermalState: .nominal, lowPower: false)
        #expect(pool.lanes(for: .network) > pool.lanes(for: .video))
    }

    /// A hot or battery-saving machine should do LESS at once — fewer concurrent
    /// jobs finish sooner in wall time once throttling starts, and each holds
    /// its memory for less of the run.
    @Test("heat and low power both shrink the pool")
    func thermalAndPowerReduceLanes() {
        let nominal = ResourcePool.automatic(cores: 10, thermalState: .nominal, lowPower: false)
        let hot = ResourcePool.automatic(cores: 10, thermalState: .serious, lowPower: false)
        let critical = ResourcePool.automatic(cores: 10, thermalState: .critical, lowPower: false)
        let saving = ResourcePool.automatic(cores: 10, thermalState: .nominal, lowPower: true)

        #expect(hot.totalLanes < nominal.totalLanes)
        #expect(critical.totalLanes < hot.totalLanes)
        #expect(saving.totalLanes < nominal.totalLanes)
        // And never to zero: a throttled machine still has to make progress.
        #expect(critical.totalLanes >= 1)
        #expect(critical.lanes(for: .video) >= 1)
    }

    /// A class nobody configured is unconstrained rather than serialised —
    /// the permissive reading, since the total still applies.
    @Test("an unconfigured class falls back to the total, not to one")
    func unconfiguredClassIsNotSerialised() {
        let pool = ResourcePool(totalLanes: 6, lanes: [.video: 2])
        #expect(pool.lanes(for: .video) == 2)
        #expect(pool.lanes(for: .document) == 6)
    }

    @Test("a class limit above the total is capped by the total")
    func classLimitCannotExceedTheTotal() {
        let pool = ResourcePool(totalLanes: 3, lanes: [.image: 99])
        #expect(pool.lanes(for: .image) == 3)
    }

    @Test("nonsensical lane counts are clamped rather than accepted")
    func nonsensicalCountsAreClamped() {
        let pool = ResourcePool(totalLanes: 0, lanes: [.image: -5])
        #expect(pool.totalLanes == 1)
        #expect(pool.lanes(for: .image) == 1)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Keeps the last progress report. A final class with a lock rather than an
/// actor, because ProgressSink.report is synchronous and returns a value.
private final class RecordingSink: ProgressSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LatheProgress?

    var last: LatheProgress? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func report(_ progress: LatheProgress) -> Bool {
        lock.lock()
        stored = progress
        lock.unlock()
        return true
    }
}
