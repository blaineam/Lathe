import AppIntents
import Foundation

/// How a Shortcut, Siri or another application reaches Lathe.
///
/// ## Why App Intents and not only the folder
///
/// The watched folder is what makes a *phone* able to send a link to a *Mac* —
/// intents do not cross devices, and no amount of wanting them to changes that.
/// But on the Mac itself a folder is a clumsy way for a Shortcut to talk to an
/// app that is already running: it means writing a file, waiting for a watcher
/// to notice, and having no way to learn what happened.
///
/// An intent is a function call. It takes arguments, it returns a result, and
/// Shortcuts can put that result into the next action. So both exist, each
/// where it is the better mechanism: the folder for the cross-device hop, and
/// these for everything local.
///
/// ## Why the queue is reached through a bridge
///
/// An intent is created by the system, not by the app, so it cannot be handed
/// dependencies. `IntentBridge` is where the running app publishes the queue
/// for them to find — and it is `nil` until the app has finished launching,
/// which is a state these have to handle rather than assume away.
@MainActor
final class IntentBridge {
    static let shared = IntentBridge()
    private init() {}

    /// Set by the app once its state exists.
    weak var queue: Queue?

    /// The queue, or a failure an intent can report.
    func requireQueue() throws -> Queue {
        guard let queue else {
            throw IntentFailure.notReady
        }
        return queue
    }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case noValidURLs

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady:
            return "Lathe is still starting up. Try again in a moment."
        case .noValidURLs:
            return "None of that was a web address."
        }
    }
}

/// Add links to the queue, and optionally start them.
struct QueueDownloadIntent: AppIntent {
    static let title: LocalizedStringResource = "Download with Lathe"
    static let description = IntentDescription(
        "Adds one or more links to Lathe's queue, and can start them immediately.",
        categoryName: "Downloads")

    /// Runs without bringing the app forward.
    ///
    /// The whole point of sending a link to a downloader is not to be
    /// interrupted by it. The app launches if it is not running — an intent
    /// cannot run in a process that does not exist — but it stays where it is.
    static let openAppWhenRun = false

    @Parameter(
        title: "Links",
        description: "One or more web addresses; anything else is ignored.")
    var urls: [URL]

    @Parameter(
        title: "Start now",
        description: "Begin downloading immediately rather than only queueing.",
        default: true)
    var startNow: Bool

    @Parameter(
        title: "How much",
        description: "Whether a link that names a collection means the one item or all of it.",
        default: .single)
    var scope: DownloadScopeAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Download \(\.$urls) with Lathe") {
            \.$startNow
            \.$scope
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let queue = try IntentBridge.shared.requireQueue()

        let text = urls.map(\.absoluteString).joined(separator: "\n")
        let added = queue.add(text: text, scope: scope.scope)
        guard added > 0 else { throw IntentFailure.noValidURLs }

        if startNow {
            // Not awaited. An intent that waits for a download is an intent
            // that times out on anything worth downloading, and Shortcuts
            // shows that as a failure of the shortcut rather than as a long
            // download.
            Task { await queue.start() }
        }
        return .result(value: added)
    }
}

/// What is happening right now, for a shortcut that wants to check.
struct DownloadStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Lathe's Status"
    static let description = IntentDescription(
        "How many downloads are running and how many have finished.",
        categoryName: "Downloads")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let queue = try IntentBridge.shared.requireQueue()
        let active = queue.activeCount
        return .result(
            value: active,
            dialog: active == 0
                ? "Nothing is downloading."
                : "\(active) downloading.")
    }
}

/// Where finished files go — the destination the user picked.
///
/// Readable by a shortcut so that a chain can put something else in the same
/// place, rather than having the path typed twice and drifting.
struct DownloadFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Lathe's Download Folder"
    static let description = IntentDescription(
        "The folder Lathe saves into.", categoryName: "Downloads")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<URL?> {
        let queue = try IntentBridge.shared.requireQueue()
        return .result(value: queue.destination ?? queue.defaultDestination())
    }
}

/// `Scope`, in the form App Intents needs.
///
/// A separate type rather than conforming `Scope` itself: `AppEnum` requires
/// display representations for every case, and putting those on the model would
/// mix what the app does with how Shortcuts words it.
enum DownloadScopeAppEnum: String, AppEnum {
    case single
    case everything

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Scope")

    static let caseDisplayRepresentations: [DownloadScopeAppEnum: DisplayRepresentation] = [
        .single: DisplayRepresentation(
            title: "Just this one",
            subtitle: "A link naming a collection means the single item"),
        .everything: DisplayRepresentation(
            title: "Everything on the page",
            subtitle: "Take the whole playlist or gallery"),
    ]

    var scope: Scope { self == .single ? .single : .all }
}

/// The phrases that make these reachable by voice and by name.
struct LatheShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QueueDownloadIntent(),
            phrases: [
                "Download with \(.applicationName)",
                "Add to \(.applicationName)",
            ],
            shortTitle: "Download",
            systemImageName: "arrow.down.circle")

        AppShortcut(
            intent: DownloadStatusIntent(),
            phrases: ["What is \(.applicationName) doing"],
            shortTitle: "Status",
            systemImageName: "list.bullet")
    }
}
