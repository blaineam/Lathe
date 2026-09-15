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
        let folder = try Inbox.location()
        let unsigned = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-unsigned-\(UUID().uuidString).shortcut")

        // Named for what it will be called once added — Shortcuts takes the
        // shortcut's name from the file's.
        let signed = FileManager.default.temporaryDirectory
            .appendingPathComponent("Send to Lathe.shortcut")

        try PropertyListSerialization
            .data(fromPropertyList: workflow(savingInto: folder), format: .binary, options: 0)
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

    /// Where the Shortcut writes, as Shortcuts expresses it.
    ///
    /// Save File's paths are relative to iCloud Drive's root, so this is the
    /// folder name and not the absolute path the Mac uses for the same place.
    private static func destination(for folder: URL) -> String {
        Inbox.isUsingiCloud ? "/\(Inbox.folderName)/" : "/\(Inbox.folderName)/"
    }

    private static func workflow(savingInto folder: URL) -> [String: Any] {
        // The shortcut's input, as an attributed string carrying one
        // attachment — the format Shortcuts uses for a variable inside text.
        let input: [String: Any] = [
            "Value": [
                "string": "\u{FFFC}",
                "attachmentsByRange": ["{0, 1}": ["Type": "ExtensionInput"]],
            ],
            "WFSerializationType": "WFTextTokenString",
        ]

        let actions: [[String: Any]] = [
            [
                "WFWorkflowActionIdentifier": "is.workflow.actions.gettext",
                "WFWorkflowActionParameters": [
                    "UUID": UUID().uuidString,
                    "WFTextActionText": input,
                ],
            ],
            [
                "WFWorkflowActionIdentifier": "is.workflow.actions.documentpicker.save",
                "WFWorkflowActionParameters": [
                    "UUID": UUID().uuidString,
                    // Never ask. A share-sheet action that opens a file picker
                    // is slower than pasting the link would have been.
                    "WFAskWhereToSave": false,
                    "WFFileDestinationPath": destination(for: folder),
                    // Not overwriting is what makes two shares in quick
                    // succession both survive: Shortcuts numbers the second
                    // file rather than replacing the first, and the watcher
                    // reads whatever it finds.
                    "WFSaveFileOverwrite": false,
                ],
            ],
        ]

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
