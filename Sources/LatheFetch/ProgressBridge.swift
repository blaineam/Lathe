import Foundation
import LatheCore

/// Carries `yt-dlp`'s progress hooks into a ``ProgressHandle``, and the answer
/// back out.
///
/// ## Why a callback and not a poll
///
/// `yt-dlp`'s progress hooks are Python callables, invoked on the thread doing
/// the download — which, here, is the thread blocked inside one
/// ``PythonRuntime/executeDetached(_:arguments:)`` call. Nothing in Swift is
/// running while that call is in flight, so progress cannot be *collected*
/// afterwards; it has to arrive during.
///
/// So Python calls back into Swift, through the same address-passing mechanism
/// ``JavaScriptBridge`` uses and for the same reasons. The callback returns an
/// `int`, and **that return value is the cancellation signal** — which is
/// exactly the contract ``ProgressSink`` already has, so the two fit together
/// with nothing in between. A `0` makes the Python side raise `yt-dlp`'s own
/// `DownloadCancelled`, so the download unwinds through the paths it already
/// has for a user pressing `^C`, including deleting the `.part` file.
///
/// That is a second, more responsive cancellation path than
/// ``PythonRuntime``'s `KeyboardInterrupt`, and it exists because the interrupt
/// one cannot be relied on here: `yt-dlp` catches broad exceptions in its
/// downloader retry loops, which is precisely the behaviour that swallows an
/// interrupt. Both paths are wired; this is the one that works.
///
/// ## Lifetime
///
/// The callback cannot capture anything — it is a C function pointer — so the
/// handle it should report to is found in a process-wide table, keyed by a
/// token that travels out to Python and back in the payload. Registration is
/// scoped to one download by the caller's `defer`, so a stale tick from a
/// download that has already been abandoned finds nothing and answers "stop".
enum ProgressBridge {

    /// One registered download.
    private struct Entry {
        let handle: ProgressHandle
        /// How much of the whole job each part is worth, summing to 1.
        let weights: [Double]
        /// The share of the overall progress bar the download phase owns.
        let scale: Double
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [Int: Entry] = [:]
    nonisolated(unsafe) private static var nextToken = 1

    /// Registers a handle for the duration of one download, returning the token
    /// Python will quote back.
    ///
    /// Parts are weighted by their published sizes when every part published
    /// one. When any did not — which is every HLS stream on the internet — they
    /// are weighted equally, because a weighting derived from a partial total
    /// is worse than an honest guess: it produces a bar that races to 90% and
    /// then crawls.
    static func register(handle: ProgressHandle, selection: FormatSelection, scale: Double) -> Int {
        let sizes = selection.formats.map(\.estimatedByteCount)
        let weights: [Double]
        if !sizes.contains(where: { $0 == nil }) {
            let total = Double(sizes.compactMap { $0 }.reduce(0, +))
            weights = total > 0
                ? sizes.map { Double($0 ?? 0) / total }
                : Array(repeating: 1 / Double(sizes.count), count: sizes.count)
        } else {
            weights = Array(repeating: 1 / Double(max(1, sizes.count)), count: max(1, sizes.count))
        }

        lock.lock()
        defer { lock.unlock() }
        let token = nextToken
        nextToken += 1
        entries[token] = Entry(handle: handle, weights: weights, scale: scale)
        return token
    }

    /// Registers a handle for a job whose parts are not known in advance.
    ///
    /// The gallery case: `gallery-dl` finds files as it goes, so there is no
    /// list of sizes to weight by and often no count until the end. Equal
    /// weights over an estimate, or a single unit when even that is unknown —
    /// an honest "n of many" beats a bar computed from a total that does not
    /// exist yet.
    static func register(handle: ProgressHandle, parts: Int, scale: Double = 1.0) -> Int {
        let count = max(1, parts)
        lock.lock()
        defer { lock.unlock() }
        let token = nextToken
        nextToken += 1
        entries[token] = Entry(
            handle: handle,
            weights: Array(repeating: 1 / Double(count), count: count),
            scale: scale)
        return token
    }

    static func unregister(_ token: Int) {
        lock.lock()
        entries.removeValue(forKey: token)
        lock.unlock()
    }

    private static func entry(for token: Int) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[token]
    }

    // MARK: - The callback

    /// One tick, as Python sends it.
    private struct Tick: Decodable {
        let token: Int
        let part: Int
        let part_count: Int
        let status: String
        let downloaded_bytes: Double?
        let total_bytes: Double?
        let fragment_index: Double?
        let fragment_count: Double?
    }

    /// The C function Python calls. Returns `1` to continue and `0` to stop.
    ///
    /// A thin shell over ``deliver(_:)`` so that the arithmetic — how several
    /// parts share one progress bar — is reachable from a test without going
    /// through a function pointer and a real download.
    private static let callbackFunction: @convention(c) (UnsafePointer<CChar>?) -> Int32 = { payload in
        guard let payload else { return 0 }
        return deliver(String(cString: payload)) ? 1 : 0
    }

    /// One tick's worth of work.
    ///
    /// Never throws, never traps, and answers `false` for anything it cannot
    /// make sense of. A progress callback is the wrong place to discover that a
    /// payload was malformed, and continuing a download whose owner cannot be
    /// found is worse than ending it.
    static func deliver(_ payload: String) -> Bool {
        guard let data = payload.data(using: .utf8),
            let tick = try? JSONDecoder().decode(Tick.self, from: data),
            let entry = entry(for: tick.token)
        else { return false }

        // `finished` arrives once per part with the part complete, so it is
        // reported as the whole of that part rather than at whatever byte count
        // the last `downloading` tick happened to carry.
        let partFraction: Double?
        if tick.status == "finished" {
            partFraction = 1
        } else if let downloaded = tick.downloaded_bytes, let total = tick.total_bytes, total > 0 {
            partFraction = min(1, downloaded / total)
        } else if let index = tick.fragment_index, let count = tick.fragment_count, count > 0 {
            // A fragmented stream publishes no total, but it does publish how
            // many fragments there are, which is the same information in
            // different units.
            partFraction = min(1, index / count)
        } else {
            partFraction = nil
        }

        let completedParts = entry.weights.prefix(max(0, tick.part)).reduce(0, +)
        let currentWeight = tick.part < entry.weights.count ? entry.weights[tick.part] : 0
        let overall = partFraction.map { (completedParts + currentWeight * $0) * entry.scale }

        let unitIndex = UInt64(max(0, tick.downloaded_bytes ?? 0))
        let unitCount = UInt64(max(0, tick.total_bytes ?? 0))

        return entry.handle.report(
            LatheProgress(
                fraction: overall,
                stage: tick.part_count > 1 ? (tick.part == 0 ? "download.video" : "download.audio") : "download",
                unitIndex: unitIndex,
                unitCount: unitCount))
    }

    /// The callback's address, as a decimal string. See ``JavaScriptBridge``
    /// for why an address rather than a symbol name.
    static var callbackAddress: String {
        String(UInt(bitPattern: unsafeBitCast(callbackFunction, to: UnsafeRawPointer.self)))
    }
}
