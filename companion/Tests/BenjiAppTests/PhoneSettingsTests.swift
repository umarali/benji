import AppKit
import XCTest
@testable import BenjiApp
import BenjiCore

/// Settings › Phone needs the Tailscale address pasted into it: ⌘V in the panel must reach the
/// field being edited even while the panel is not the app's key window. No window is shown and the
/// system clipboard is not touched.
final class PhoneSettingsTests: XCTestCase {
    private final class PrivateClipboardEditor: NSTextView {
        let board = NSPasteboard.withUniqueName()
        override func paste(_ sender: Any?) { _ = readSelection(from: board) }
    }

    func testPasteInThePanelReachesTheAddressField() throws {
        _ = NSApplication.shared
        let model = CompanionModel(backend: FakeBackend())
        let panel = CompanionPanel(model: model)
        defer { panel.close() }
        let editor = PrivateClipboardEditor(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        defer { editor.board.releaseGlobally() }
        editor.board.setString("https://mac.example.ts.net", forType: .string)
        panel.contentView = editor
        XCTAssertTrue(panel.makeFirstResponder(editor))
        XCTAssertFalse(panel.isVisible, "no test window is shown")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                   timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                                   characters: "v", charactersIgnoringModifiers: "v",
                                                   isARepeat: false, keyCode: 9))
        XCTAssertTrue(panel.performKeyEquivalent(with: event))
        XCTAssertEqual(editor.string, "https://mac.example.ts.net")
        XCTAssertFalse(panel.isVisible)
    }
}
