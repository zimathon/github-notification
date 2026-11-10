import AppKit
import XCTest
@testable import GitHubSignal

@MainActor
final class InboxWindowTests: XCTestCase {
    func testUndoShortcutWorksWithoutOpeningAMenu() {
        let window = makeWindow()
        var count = 0
        window.undoAcknowledgement = { count += 1; return true }
        XCTAssertTrue(window.performKeyEquivalent(with: key(.command)))
        XCTAssertEqual(count, 1)
        for modifiers: NSEvent.ModifierFlags in [[], .control, [.command, .shift], [.command, .option]] {
            _ = window.performKeyEquivalent(with: key(modifiers))
        }
        XCTAssertEqual(count, 1)
    }

    func testTextEditingKeepsItsOwnUndo() {
        let window = makeWindow()
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        window.contentView = editor
        XCTAssertTrue(window.makeFirstResponder(editor))
        var called = false
        window.undoAcknowledgement = { called = true; return true }
        _ = window.performKeyEquivalent(with: key(.command))
        XCTAssertFalse(called)
        editor.isEditable = false
        XCTAssertTrue(window.performKeyEquivalent(with: key(.command)))
        XCTAssertTrue(called)
    }

    func testNoHistoryDoesNotConsumeShortcut() {
        let window = makeWindow()
        XCTAssertFalse(window.performKeyEquivalent(with: key(.command)))
    }

    private func makeWindow() -> InboxWindow {
        _ = NSApplication.shared
        return InboxWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
                           styleMask: [.titled], backing: .buffered, defer: false)
    }

    private func key(_ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                        timestamp: 0, windowNumber: 0, context: nil, characters: "z",
                        charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
    }
}
