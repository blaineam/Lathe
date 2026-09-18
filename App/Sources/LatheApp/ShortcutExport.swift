import AppKit
import Foundation

/// Builds the "Send to Lathe" shortcut and hands it to the Shortcuts app.
///
/// ## Why this is generated rather than described
///
/// A page of instructions asking somebody to build a two-action shortcut by
/// hand, and to type a path correctly, is a page most people close. A shortcut
/// file that opens straight into "Add Shortcut" with the path already right is
/// the same feature with none of that.
///
/// ## How a shortcut file is made
///
/// It is a property list of actions. Shortcuts will not import an unsigned
/// one, but macOS ships the signer: `shortcuts sign --mode anyone` turns the
/// plist into the signed archive the app accepts. So the whole thing is a
/// plist, a subprocess, and an `open`.
///
/// Spawning a process is fine here and would not be on iOS. The Mac app is
/// the only place this feature exists, because it is the Mac that is being
/// sent to.
enum ShortcutExport {

    enum Failure: LocalizedError {
        case signingFailed(String)

        var errorDescription: String? {
            switch self {
            case .signingFailed(let detail):
                return "The shortcut could not be signed: \(detail)"
            }
        }
    }

    /// Writes the shortcut, signs it, and opens it in Shortcuts.
    @discardableResult
    static func install() throws -> URL {
        // Creating the folder now means the Shortcut's first run has somewhere
        // to land rather than failing on a path that does not exist yet.
        _ = try Inbox.location()
        let unsigned = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-unsigned-\(UUID().uuidString).shortcut")

        // Named for what it will be called once added — Shortcuts takes the
        // shortcut's name from the file's.
        let signed = FileManager.default.temporaryDirectory
            .appendingPathComponent("Send to Lathe.shortcut")

        try PropertyListSerialization
            .data(fromPropertyList: workflow(), format: .binary, options: 0)
            .write(to: unsigned)
        defer { try? FileManager.default.removeItem(at: unsigned) }
        try? FileManager.default.removeItem(at: signed)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = [
            "sign",
            // "anyone", because this file is going to be handed to the person
            // sitting here and possibly to their phone. The default only
            // admits people already in their contacts.
            "--mode", "anyone",
            "--input", unsigned.path,
            "--output", signed.path,
        ]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw Failure.signingFailed(
                detail.isEmpty ? "exit status \(process.terminationStatus)" : detail)
        }

        NSWorkspace.shared.open(signed)
        return signed
    }

    /// One answer the share sheet offers, and the file it writes for it.
    ///
    /// Both decisions — how much to take, and where it goes — are in a single
    /// menu rather than two. It is one tap on a phone instead of two, and more
    /// to the point the answer travels as the *name of the file*, which is the
    /// one thing about a Save File action that Shortcuts cannot quietly
    /// substitute. An earlier version composed the answers into the file's
    /// text and Shortcuts wrote the bare URL instead, so the questions were
    /// asked and the answers silently dropped.
    private struct Choice {
        let title: String
        /// The file name, which Lathe reads the answer out of.
        let file: String
    }

    private static let choices = [
        Choice(title: "Just this → \(Inbox.outputFolderName)", file: "single-shared.txt"),
        Choice(title: "Just this → Downloads", file: "single-downloads.txt"),
        Choice(title: "Everything → \(Inbox.outputFolderName)", file: "all-shared.txt"),
        Choice(title: "Everything → Downloads", file: "all-downloads.txt"),
        Choice(title: "Just queue it", file: "queue.txt"),
    ]

    /// The share's own URL, as an attributed string with one attachment —
    /// which is the shape Shortcuts uses for a variable inside text, and the
    /// only input the Save File action reliably honours.
    private static var shareInput: [String: Any] {
        [
            "Value": [
                "string": "\u{FFFC}",
                "attachmentsByRange": ["{0, 1}": ["Type": "ExtensionInput"]],
            ],
            "WFSerializationType": "WFTextTokenString",
        ]
    }

    private static func save(_ choice: Choice) -> [String: Any] {
        [
            "WFWorkflowActionIdentifier": "is.workflow.actions.documentpicker.save",
            "WFWorkflowActionParameters": [
                "UUID": UUID().uuidString,
                // Never ask. A share-sheet action that opens a file picker is
                // slower than pasting the link would have been.
                "WFAskWhereToSave": false,
                "WFFileDestinationPath": "/\(Inbox.folderName)/\(choice.file)",
                "WFInput": shareInput,
                // Not overwriting is what makes two shares in quick succession
                // both survive: Shortcuts numbers the second file rather than
                // replacing the first, and Lathe reads the answer out of the
                // name either way.
                "WFSaveFileOverwrite": false,
            ],
        ]
    }

    private static func workflow() -> [String: Any] {
        let grouping = UUID().uuidString
        var actions: [[String: Any]] = [[
            "WFWorkflowActionIdentifier": "is.workflow.actions.choosefrommenu",
            "WFWorkflowActionParameters": [
                "GroupingIdentifier": grouping,
                "WFControlFlowMode": 0,
                "WFMenuPrompt": "Send to Lathe",
                "WFMenuItems": choices.map(\.title),
            ],
        ]]
        for choice in choices {
            actions.append([
                "WFWorkflowActionIdentifier": "is.workflow.actions.choosefrommenu",
                "WFWorkflowActionParameters": [
                    "GroupingIdentifier": grouping,
                    "WFControlFlowMode": 1,
                    "WFMenuItemAttributedTitle": [
                        "Value": ["string": choice.title],
                        "WFSerializationType": "WFTextTokenString",
                    ],
                    "WFMenuItemTitle": choice.title,
                ],
            ])
            actions.append(save(choice))
        }
        actions.append([
            "WFWorkflowActionIdentifier": "is.workflow.actions.choosefrommenu",
            "WFWorkflowActionParameters": [
                "GroupingIdentifier": grouping,
                "WFControlFlowMode": 2,
            ],
        ])

        return [
            "WFWorkflowClientVersion": "3110.0.3",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": [
                "WFWorkflowIconGlyphNumber": 59511,
                "WFWorkflowIconStartColor": 4_274_264_319,
            ],
            "WFWorkflowImportQuestions": [],
            // ActionExtension is what puts it in the share sheet, which is the
            // only place it is meant to be used from.
            "WFWorkflowTypes": ["ActionExtension"],
            "WFWorkflowInputContentItemClasses": [
                "WFURLContentItem", "WFStringContentItem",
            ],
            "WFWorkflowHasShortcutInputVariables": true,
            "WFWorkflowHasOutputFallback": false,
            "WFWorkflowActions": actions,
            "WFQuickActionSurfaces": [],
        ]
    }
}
