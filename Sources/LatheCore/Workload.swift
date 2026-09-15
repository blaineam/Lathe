import Foundation

/// What kind of resource a piece of work actually contends for.
///
/// ## Why one lane count is the wrong model
///
/// "Use N threads" is the obvious knob and it is wrong for media, because the
/// jobs do not contend for the same thing:
///
/// - **Video** contends for the hardware encoder. A machine has a small, fixed
///   number of encode engines, and running sixteen transcodes at once does not
///   use sixteen of them — it queues on the same few while holding sixteen jobs'
///   worth of frame buffers in memory. More lanes here make a bulk run slower
///   and much hungrier, which is the opposite of what the knob was turned for.
/// - **Stills** contend for CPU, and scale with cores about as well as anything
///   does.
/// - **Text recognition** contends for the Neural Engine, which is one shared
///   unit however many cores the machine has.
/// - **Network** contends for nothing local at all. Its right lane count is far
///   higher than the core count, because a stalled download is not using a core
///   while it waits.
///
/// So a pool is configured per class. A run of a thousand mixed files can have
/// its images saturating the CPU while two videos use the encoder and eight
/// downloads are in flight, which is the arrangement that actually finishes
/// first.
public enum Workload: String, Sendable, Hashable, CaseIterable {
    /// Video encoding and decoding. Contends for the hardware encoder.
    case video
    /// Still images. Contends for CPU.
    case image
    /// Audio encoding and analysis. Cheap, and CPU-bound.
    case audio
    /// PDFs and archives — mostly I/O and CPU.
    case document
    /// Text recognition. Contends for the Neural Engine.
    case recognition
    /// Reading or writing over a network. Contends for bandwidth, not cores.
    case network

    public var description: String { rawValue }
}

/// How many pieces of work may run at once, in total and per class.
///
/// Both limits apply: a run never exceeds ``totalLanes`` however the classes are
/// configured, and never exceeds a class's own limit however much total headroom
/// there is. The total exists because memory is shared even when the units of
/// contention are not — eight images and four videos may each be within their
/// class and still be more than a phone can hold at once.
public struct ResourcePool: Sendable, Equatable {

    /// The ceiling across every class.
    public var totalLanes: Int

    /// The ceiling within each class. A class absent from the map falls back to
    /// ``totalLanes``, which is the permissive reading — an unconfigured class
    /// is unconstrained rather than serialised.
    public var lanes: [Workload: Int]

    public init(totalLanes: Int, lanes: [Workload: Int] = [:]) {
        self.totalLanes = Swift.max(1, totalLanes)
        self.lanes = lanes.mapValues { Swift.max(1, $0) }
    }

    /// The limit for one class.
    public func lanes(for workload: Workload) -> Int {
        Swift.min(totalLanes, lanes[workload] ?? totalLanes)
    }

    /// A pool sized to the machine it is running on.
    ///
    /// The numbers are reasoned rather than measured, and each is written down
    /// so that measuring can replace it:
    ///
    /// - **Video is 2, regardless of how many cores there are.** Apple silicon
    ///   has a small number of video encode engines, and beyond them extra
    ///   concurrency is queueing plus memory. Two keeps the engine fed while one
    ///   job is setting up or tearing down.
    /// - **Recognition is 2** for the same reason: one Neural Engine.
    /// - **Images, audio and documents scale with cores**, at the active count
    ///   rather than the total — a throttled machine reports fewer, which is
    ///   exactly when fewer should be started.
    /// - **Network is 6 and not tied to cores at all.** A stalled transfer
    ///   occupies no core, and six is a polite ceiling against one host.
    ///
    /// Thermal state and Low Power Mode both cut the whole pool, because the
    /// right response to a hot or battery-saving machine is to do less at once
    /// rather than to finish the same work while throttled.
    public static var automatic: ResourcePool { automatic(cores: nil) }

    /// ``automatic`` with the core count supplied, for tests and for a caller
    /// that knows better than `ProcessInfo`.
    public static func automatic(
        cores: Int? = nil,
        thermalState: ProcessInfo.ThermalState? = nil,
        lowPower: Bool? = nil
    ) -> ResourcePool {
        let info = ProcessInfo.processInfo
        let cores = cores ?? info.activeProcessorCount
        let thermal = thermalState ?? info.thermalState
        let saving = lowPower ?? info.isLowPowerModeEnabled

        // A machine that is hot or saving battery should do LESS at once, not
        // the same amount more slowly: fewer concurrent jobs finish sooner in
        // wall time once throttling starts, and each one holds its memory for
        // less of the run.
        let scale: Double = switch thermal {
        case .nominal: saving ? 0.5 : 1.0
        case .fair: saving ? 0.4 : 0.75
        case .serious: 0.4
        case .critical: 0.25
        @unknown default: 0.5
        }

        func scaled(_ value: Int, floor: Int = 1) -> Int {
            Swift.max(floor, Int((Double(value) * scale).rounded()))
        }

        let cpuLanes = scaled(Swift.max(2, cores))
        return ResourcePool(
            totalLanes: Swift.max(2, cpuLanes + 2),
            lanes: [
                .video: scaled(2),
                .recognition: scaled(2),
                .image: cpuLanes,
                .audio: cpuLanes,
                .document: scaled(Swift.max(2, cores / 2)),
                .network: scaled(6, floor: 2),
            ]
        )
    }

    /// One at a time. The setting for reproducing a problem, and for a caller
    /// that wants a bulk run to behave exactly like a loop.
    public static let serial = ResourcePool(totalLanes: 1)
}
