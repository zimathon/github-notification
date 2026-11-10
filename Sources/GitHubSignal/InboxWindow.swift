import AppKit

final class InboxWindow: NSWindow {
    var undoAcknowledgement: @MainActor () -> Bool = { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers == "z", attachedSheet == nil,
           (firstResponder as? NSTextView)?.isEditable != true,
           undoAcknowledgement() {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
