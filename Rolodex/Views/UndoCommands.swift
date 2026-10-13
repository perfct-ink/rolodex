import AppKit
import SwiftUI

/// What the Edit menu's Undo and Redo do for the contact being shown.
struct ContactUndoActions {
    var undoName: String?
    var redoName: String?
    var undo: () -> Void
    var redo: () -> Void
}

private struct ContactUndoKey: FocusedValueKey {
    typealias Value = ContactUndoActions
}

extension FocusedValues {
    var contactUndo: ContactUndoActions? {
        get { self[ContactUndoKey.self] }
        set { self[ContactUndoKey.self] = newValue }
    }
}

struct UndoRedoCommands: View {
    @FocusedValue(\.contactUndo) private var actions

    var body: some View {
        Button(actions?.undoName.map { "Undo \($0)" } ?? "Undo") {
            if let actions, actions.undoName != nil {
                actions.undo()
            } else {
                // Nothing to undo on the contact: leave undo to whatever is focused.
                NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
            }
        }
        .keyboardShortcut("z", modifiers: .command)

        Button(actions?.redoName.map { "Redo \($0)" } ?? "Redo") {
            if let actions, actions.redoName != nil {
                actions.redo()
            } else {
                NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
            }
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])
    }
}
