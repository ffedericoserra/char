import XCTest
import AppKit
@testable import Think

private final class DiscreteWheelEvent: NSEvent {
    var step: CGFloat = -6
    override var hasPreciseScrollingDeltas: Bool { false }
    override var scrollingDeltaY: CGFloat { step }
}

final class PlainTextTests: XCTestCase {
    func testUnicodeRoundTrip() throws {
        let text = "Pensieri — caffè ☕️\n日本語\nمرحبا\n👨‍👩‍👧‍👦"
        XCTAssertEqual(try PlainText.decode(PlainText.encode(text)), text)
    }

    func testEmptyAndLineEndingsArePreserved() throws {
        for text in ["", "one\r\ntwo\r\n", "one\rtwo", "one\ntwo\n\n", "\t  "] {
            XCTAssertEqual(try PlainText.decode(PlainText.encode(text)), text)
        }
    }

    func testUnicodeByteOrderMarks() throws {
        let text = "Caffè 日本語"
        for (encoding, prefix): (String.Encoding, [UInt8]) in [
            (.utf8, [0xEF, 0xBB, 0xBF]),
            (.utf16LittleEndian, [0xFF, 0xFE]), (.utf16BigEndian, [0xFE, 0xFF]),
            (.utf32LittleEndian, [0xFF, 0xFE, 0, 0]), (.utf32BigEndian, [0, 0, 0xFE, 0xFF])
        ] {
            XCTAssertEqual(try PlainText.decode(Data(prefix) + text.data(using: encoding)!), text)
        }
    }

    func testInvalidTextIsRejectedWithoutLossyReplacement() {
        XCTAssertThrowsError(try PlainText.decode(Data([0xC3, 0x28])))
        XCTAssertThrowsError(try PlainText.decode(Data([0, 1, 2, 3])))
    }

    func testDirectoryListsOnlyTextFilesAndNavigableFolders() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["note10.txt", "note2.txt", "UPPER.TXT", "image.png", ".hidden.txt"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        let folder = directory.appendingPathComponent("Journal")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("loop"), withDestinationURL: directory)
        let entries = try FolderEntry.contents(of: directory)
        XCTAssertEqual(entries.map(\.url.lastPathComponent), ["Journal", "note2.txt", "note10.txt", "UPPER.TXT"])
        XCTAssertTrue(entries[0].isDirectory)
    }
}

@MainActor
final class DocumentTests: XCTestCase {
    func testTitlebarGeometry() throws {
        let controller = EditorWindowController()
        let window = try XCTUnwrap(controller.window as? NoteWindow)
        defer { window.close() }
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 800, height: 500)] {
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            let nativeButtons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
            let controls = nativeButtons + window.noteButtons
            XCTAssertEqual(controls.count, 5)
            for (button, centerX) in zip(controls, [23.0, 43.0, 63.0, 102.0, 136.0]) {
                let frame = button.convert(button.bounds, to: nil)
                XCTAssertEqual(frame.midX, centerX, accuracy: 0.5)
                XCTAssertEqual(window.frame.height - frame.midY, 24, accuracy: 0.5)
            }
        }
    }

    func testMaximizeRestoresPreviousFrame() throws {
        let controller = EditorWindowController()
        let window = try XCTUnwrap(controller.window as? NoteWindow)
        defer { window.close() }
        window.setFrame(NSRect(x: 100, y: 100, width: 900, height: 600), display: false)
        let original = window.frame
        window.toggleMaximize()
        XCTAssertEqual(window.frame, try XCTUnwrap(window.screen).visibleFrame)
        window.toggleMaximize()
        XCTAssertEqual(window.frame, original)
    }

    func testMouseWheelEasesAndSettles() throws {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            throw XCTSkip("Reduce Motion intentionally disables wheel animation.")
        }
        let note = NoteDocument()
        note.text = String(repeating: "A line of text for scrolling.\n", count: 200)
        note.makeWindowControllers()
        defer { note.close() }
        let controller = try XCTUnwrap(note.windowControllers.first as? EditorWindowController)
        controller.showWindow(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let scroll = controller.editor.scrollView
        let initialY = scroll.contentView.bounds.minY
        let event = DiscreteWheelEvent()
        scroll.scrollWheel(with: event)
        // A coarse wheel step must no longer jump to its destination immediately.
        XCTAssertEqual(scroll.contentView.bounds.minY, initialY, accuracy: 0.01)
        let settled = expectation(description: "Wheel animation reaches its destination")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            XCTAssertEqual(scroll.contentView.bounds.minY, initialY + 6 * scroll.verticalLineScroll, accuracy: 0.5)
            settled.fulfill()
        }
        wait(for: [settled], timeout: 2)
    }

    func testNewDocumentAndEditorDefaults() throws {
        let note = NoteDocument()
        note.makeWindowControllers()
        defer { note.close() }
        let controller = try XCTUnwrap(note.windowControllers.first as? EditorWindowController)
        XCTAssertEqual(note.text, "")
        XCTAssertNil(note.fileURL)
        XCTAssertFalse(note.isDocumentEdited)
        XCTAssertEqual(controller.editor.textView.font?.pointSize, 14)
        XCTAssertFalse(controller.editor.textView.isRichText)
        XCTAssertTrue(controller.editor.textView.undoManager === note.undoManager)
        XCTAssertFalse(NoteDocument.autosavesInPlace)
    }

    func testEditingUndoRedoAndDirtyState() throws {
        let note = NoteDocument()
        note.makeWindowControllers()
        defer { note.close() }
        let editor = try XCTUnwrap((note.windowControllers.first as? EditorWindowController)?.editor.textView)
        let undo = try XCTUnwrap(note.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.insertText("A thought ☕️", replacementRange: NSRange(location: 0, length: 0))
        editor.breakUndoCoalescing()
        undo.endUndoGrouping()
        XCTAssertEqual(note.text, "A thought ☕️")
        XCTAssertTrue(note.isDocumentEdited)
        undo.undo()
        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(note.text, "")
        XCTAssertFalse(note.isDocumentEdited)
        undo.redo()
        XCTAssertEqual(note.text, "A thought ☕️")
        XCTAssertTrue(note.isDocumentEdited)
    }

    func testReadFailurePreservesExistingText() {
        let note = NoteDocument()
        note.text = "Keep my thought"
        XCTAssertThrowsError(try note.read(from: Data([0xC3, 0x28]), ofType: "public.plain-text"))
        XCTAssertEqual(note.text, "Keep my thought")
    }

    func testSaveAndReopen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let note = NoteDocument()
        note.text = "A saved thought\nCaffè ☕️"
        note.updateChangeCount(.changeDone)
        let saved = expectation(description: "Native document saves")
        note.save(to: url, ofType: "public.plain-text", for: .saveOperation) { error in
            XCTAssertNil(error)
            saved.fulfill()
        }
        wait(for: [saved], timeout: 10)
        XCTAssertFalse(note.isDocumentEdited)
        XCTAssertEqual(note.fileURL, url)
        let reopened = try NoteDocument(contentsOf: url, ofType: "public.plain-text")
        XCTAssertEqual(reopened.text, note.text)
        XCTAssertEqual(try Data(contentsOf: url), Data(note.text.utf8))
    }

    func testWindowsHaveIndependentTextAndUndo() throws {
        let first = NoteDocument()
        let second = NoteDocument()
        first.makeWindowControllers()
        second.makeWindowControllers()
        defer { first.close(); second.close() }
        let editor = try XCTUnwrap((first.windowControllers.first as? EditorWindowController)?.editor.textView)
        editor.insertText("Only in first", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(first.text, "Only in first")
        XCTAssertEqual(second.text, "")
        XCTAssertFalse(first.undoManager === second.undoManager)
        XCTAssertFalse(second.isDocumentEdited)
    }
}
