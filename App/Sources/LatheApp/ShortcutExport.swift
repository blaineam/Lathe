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

    /// Where the Shortcut writes, as Shortcuts expresses it.
    ///
    /// Save File's path is relative to the service it saves into, and the
    /// service it picks by default is the Shortcuts folder — which is why a
    /// path of "/Lathe Inbox/" landed in Shortcuts/Lathe Inbox. Naming iCloud
    /// Drive as the service puts the folder where Lathe is watching.
    private static let storageService = "iCloud Drive"

    private static let destinationPath = "/\(Inbox.folderName)/"

    /// A menu the share sheet shows, and the line it writes for each answer.
    private struct Choice {
        let title: String
        let line: String
    }

    private static let scopeChoices = [
        Choice(title: "Download just this", line: "lathe-scope: single"),
        Choice(title: "Download everything", line: "lathe-scope: everything"),
        Choice(title: "Just queue it", line: "lathe-queue: yes"),
    ]

    private static let destinationChoices = [
        Choice(title: "Save to \(Inbox.outputFolderName)", line: "lathe-destination: shared"),
        Choice(title: "Save to Downloads", line: "lathe-destination: downloads"),
    ]

    /// Text carrying a variable, which is how Shortcuts stores an action's
    /// input when it is another action's output.
    private static func token(from uuid: String, named name: String) -> [String: Any] {
        [
            "Value": [
                "string": "\u{FFFC}",
                "attachmentsByRange": [
                    "{0, 1}": [
                        "Type": "ActionOutput",
                        "OutputUUID": uuid,
                        "OutputName": name,
                    ],
                ],
            ],
            "WFSerializationType": "WFTextTokenString",
        ]
    }

    /// A menu, plus one "set variable" per answer, so the rest of the
    /// shortcut can read the answer back by name.
    private static func menu(prompt: String, choices: [Choice],
                             variable: String) -> [[String: Any]] {
        let grouping = UUID().uuidString
        var actions: [[String: Any]] = [[
            "WFWorkflowActionIdentifier": "is.workflow.actions.choosefrommenu",
            "WFWorkflowActionParameters": [
                "GroupingIdentifier": grouping,
                "WFControlFlowMode": 0,
                "WFMenuPrompt": prompt,
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
            actions.append([
                "WFWorkflowActionIdentifier": "is.workflow.actions.setvariable",
                "WFWorkflowActionParameters": [
                    "WFVariableName": variable,
                    "WFInput": [
                        "Value": ["string": choice.line],
                        "WFSerializationType": "WFTextTokenString",
                    ],
                ],
            ])
        }
        actions.append([
            "WFWorkflowActionIdentifier": "is.workflow.actions.choosefrommenu",
            "WFWorkflowActionParameters": [
                "GroupingIdentifier": grouping,
                "WFControlFlowMode": 2,
            ],
        ])
        return actions
    }

    private static func workflow() -> [String: Any] {
        let scopeVariable = "Lathe Scope"
        let destinationVariable = "Lathe Destination"
        let payloadUUID = UUID().uuidString

        // The link, then the two answers — one directive per line, which is
        // what Lathe's inbox reads. Answering here is the point: the download
        // starts when the file lands rather than when someone comes back to
        // the Mac.
        let payload: [String: Any] = [
            "Value": [
                "string": "\u{FFFC}\n\u{FFFC}\n\u{FFFC}",
                "attachmentsByRange": [
                    "{0, 1}": ["Type": "ExtensionInput"],
                    "{2, 1}": ["Type": "Variable", "VariableName": scopeVariable],
                    "{4, 1}": ["Type": "Variable", "VariableName": destinationVariable],
                ],
            ],
            "WFSerializationType": "WFTextTokenString",
        ]

        var actions: [[String: Any]] = []
        actions += menu(prompt: "Send to Lathe", choices: scopeChoices,
                        variable: scopeVariable)
        actions += menu(prompt: "Where should the files go?", choices: destinationChoices,
                        variable: destinationVariable)
        actions.append([
            "WFWorkflowActionIdentifier": "is.workflow.actions.gettext",
            "WFWorkflowActionParameters": [
                "UUID": payloadUUID,
                "WFTextActionText": payload,
            ],
        ])
        actions.append([
            "WFWorkflowActionIdentifier": "is.workflow.actions.documentpicker.save",
            "WFWorkflowActionParameters": [
                "UUID": UUID().uuidString,
                // Never ask. A share-sheet action that opens a file picker is
                // slower than pasting the link would have been.
                "WFAskWhereToSave": false,
                "WFFileStorageService": storageService,
                "WFFileDestinationPath": destinationPath,
                // The text the action above built. Without this the Save File
                // action takes whatever Shortcuts guesses its input is, which
                // was the share's own URL and none of the answers.
                "WFInput": token(from: payloadUUID, named: "Text"),
                // Not overwriting is what makes two shares in quick succession
                // both survive: Shortcuts numbers the second file rather than
                // replacing the first, and the watcher reads whatever it finds.
                "WFSaveFileOverwrite": false,
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
