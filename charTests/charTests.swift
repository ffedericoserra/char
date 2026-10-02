import XCTest
import AppKit
@testable import char

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

    func testDirectoryListsAllFileExtensionsAndNavigableFolders() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["note10.txt", "note2.txt", "UPPER.TXT", "image.png", "README", "config.json", ".hidden.txt"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        let folder = directory.appendingPathComponent("Journal")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("loop"), withDestinationURL: directory)
        let entries = try FolderEntry.contents(of: directory)
        XCTAssertEqual(entries.map(\.url.lastPathComponent), ["Journal", "config.json", "image.png", "note2.txt", "note10.txt", "README", "UPPER.TXT"])
        XCTAssertTrue(entries[0].isDirectory)
    }

    func testSidebarOnlyOpensTextOnSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples: [(String, Data, Bool)] = [
            ("README", Data("Notes".utf8), true),
            ("note.custom", Data("Caffè".utf8), true),
            ("empty.txt", Data(), true),
            ("unicode.txt", Data([0xFF, 0xFE, 0x41, 0x00]), true),
            ("binary.txt", Data([0, 1, 2, 3]), false),
            ("file.pdf", Data("%PDF-1.4\n%%EOF".utf8), false),
            ("image.png", Data([0x89, 0x50, 0x4E, 0x47]), false)
        ]
        for (name, data, expected) in samples {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            XCTAssertEqual(FolderEntry(url: url, isDirectory: false).opensOnSelection, expected, name)
        }
        XCTAssertFalse(FolderEntry(url: directory, isDirectory: true).opensOnSelection)
    }
}

@MainActor
final class DocumentTests: XCTestCase {
    func testThemeShortcutUpdatesWindowsWithoutEditingDocuments() throws {
        let original = UserDefaults.standard.object(forKey: "darkTheme")
        defer {
            if let original { UserDefaults.standard.set(original, forKey: "darkTheme") }
            else { UserDefaults.standard.removeObject(forKey: "darkTheme") }
            AppTheme.apply()
        }
        UserDefaults.standard.set(false, forKey: "darkTheme")
        AppTheme.apply()
        let note = NoteDocument()
        note.text = "Theme switching preserves text"
        note.makeWindowControllers()
        defer { note.close() }
        let controller = try XCTUnwrap(note.windowControllers.first as? EditorWindowController)
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        let split = try XCTUnwrap(window.contentView as? NSSplitView)
        let sidebar = try XCTUnwrap(split.arrangedSubviews.first as? FolderBrowser)
        let sidebarScroll = try XCTUnwrap(sidebar.subviews.first { $0 is NSScrollView } as? NSScrollView)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "M", charactersIgnoringModifiers: "m", isARepeat: false, keyCode: 46))
        for dark in [true, false] {
            XCTAssertTrue(split.performKeyEquivalent(with: event))
            XCTAssertEqual(AppTheme.isDark, dark)
            let palette = dark ? ThemePalette.dark : ThemePalette.light
            XCTAssertEqual(controller.editor.textView.backgroundColor, palette.editorBackground)
            XCTAssertEqual(controller.editor.textView.textColor, palette.text)
            XCTAssertEqual(sidebarScroll.backgroundColor, palette.sidebarBackground)
            XCTAssertEqual(note.text, "Theme switching preserves text")
            XCTAssertFalse(note.isDocumentEdited)
            XCTAssertEqual(NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), dark ? .darkAqua : .aqua)
        }
    }

    func testFileStatusTracksExistenceAndEdits() throws {
        let note = NoteDocument()
        note.makeWindowControllers()
        defer { note.close() }
        let controller = try XCTUnwrap(note.windowControllers.first as? EditorWindowController)
        let status = try XCTUnwrap(controller.editor.subviews.compactMap { $0 as? NSStackView }.first)
        let button = try XCTUnwrap(status.arrangedSubviews.first as? NSButton)
        let label = try XCTUnwrap(status.arrangedSubviews.last as? NSTextField)
        XCTAssertTrue(button.isHidden)
        XCTAssertTrue(label.isHidden)
        controller.editor.textView.string = "Draft"
        XCTAssertFalse(label.isHidden)
        controller.editor.textView.string = ""
        XCTAssertTrue(label.isHidden)
        XCTAssertEqual(label.stringValue, "Unsaved")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("Saved".utf8).write(to: url)
        note.fileURL = url
        XCTAssertFalse(button.isHidden)
        XCTAssertTrue(label.isHidden)
        note.updateChangeCount(.changeDone)
        XCTAssertFalse(label.isHidden)
        note.updateChangeCount(.changeCleared)
        XCTAssertTrue(label.isHidden)
        try FileManager.default.removeItem(at: url)
        controller.editor.updateFileStatus()
        XCTAssertTrue(button.isHidden)
        XCTAssertFalse(label.isHidden)
    }

    func testBottomWhitespaceTracksWindowAndFontSize() throws {
        let note = NoteDocument()
        note.text = String(repeating: "A line of writing.\n", count: 60) + "Last line"
        note.makeWindowControllers()
        defer { note.close() }
        let controller = try XCTUnwrap(note.windowControllers.first as? EditorWindowController)
        let window = try XCTUnwrap(controller.window)
        let editor = controller.editor
        let text = editor.textView
        let container = try XCTUnwrap(text.textContainer)
        let manager = try XCTUnwrap(text.layoutManager)
        for height: CGFloat in [400, 800] {
            for size: CGFloat in [14, 36] {
                window.setContentSize(NSSize(width: 800, height: height))
                editor.setFontSize(size)
                window.contentView?.layoutSubtreeIfNeeded()
                manager.ensureLayout(for: container)
                text.sizeToFit()
                let contentBottom = manager.usedRect(for: container).maxY + text.textContainerOrigin.y
                let whitespace = text.frame.height - contentBottom
                XCTAssertGreaterThanOrEqual(whitespace, editor.scrollView.contentSize.height / 2 - 1)
                XCTAssertGreaterThanOrEqual(whitespace, 6 * text.writingLineHeight + EditorMetrics.edgeHeight - 1)
                XCTAssertEqual(text.textContainerOrigin.y, EditorMetrics.verticalInset)
                editor.restoreScrollPosition(NSPoint(x: 0, y: text.frame.height))
                XCTAssertGreaterThanOrEqual(editor.scrollView.contentView.bounds.maxY - contentBottom, whitespace - 1)
            }
        }
    }

    func testMovingCaretLeavesNoPixelsOutsideNativeInvalidationRect() throws {
        let textView = NoteTextView(usingTextLayoutManager: false)
        for scale in [1, 2] {
            for font in [NSFont.systemFont(ofSize: 14, weight: .regular),
                         NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                         NSFont.systemFont(ofSize: 23, weight: .regular)] {
                textView.font = font
                let bitmap = try XCTUnwrap(NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 64 * scale, pixelsHigh: 64 * scale,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                NSColor.white.setFill()
                NSRect(x: 0, y: 0, width: 64, height: 64).fill()
                // A fractional glyph advance and a shorter native line box
                // reproduce both ways custom caret pixels can escape erasure.
                let rect = NSRect(x: 10.2, y: 10, width: 1,
                                  height: floor(font.ascender - font.descender))
                textView.drawInsertionPoint(in: rect, color: .black, turnedOn: true)
                context.flushGraphics()
                let hasCaret = (0..<bitmap.pixelsHigh).contains { y in
                    (0..<bitmap.pixelsWide).contains { x in
                        (bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.redComponent ?? 1) < 0.5
                    }
                }
                XCTAssertTrue(hasCaret, "The test must draw a visible caret")
                // Model AppKit repainting the old caret's dirty rectangle.
                // Dirty regions cover whole backing pixels; clearing a
                // fractional rectangle would itself leave antialiased edges.
                let backingRect = NSRect(x: rect.minX * CGFloat(scale), y: rect.minY * CGFloat(scale),
                                         width: rect.width * CGFloat(scale), height: rect.height * CGFloat(scale)).integral
                NSColor.white.setFill()
                NSRect(x: backingRect.minX / CGFloat(scale), y: backingRect.minY / CGFloat(scale),
                       width: backingRect.width / CGFloat(scale), height: backingRect.height / CGFloat(scale)).fill()
                context.flushGraphics()
                NSGraphicsContext.restoreGraphicsState()
                var leftoverPixels = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           min(color.redComponent, color.greenComponent, color.blueComponent) < 0.95 {
                            leftoverPixels += 1
                        }
                    }
                }
                XCTAssertEqual(leftoverPixels, 0, "Caret residue at \(scale)x with \(font.fontName)")
            }
        }
    }

    func testArbitraryFilenamesSurviveCopyRenameAndTextEditing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for filename in ["config.json", "script.swift", "README"] {
            let url = directory.appendingPathComponent(filename)
            let data = Data("hello 🌍".utf8)
            try data.write(to: url)
            let document = NoteDocument()
            try document.read(from: url, ofType: "public.plain-text")
            XCTAssertEqual(try document.data(ofType: "public.plain-text"), data)
            let copy = try NoteFileOperations.copy(url, into: directory)
            XCTAssertEqual(copy.pathExtension, url.pathExtension)
            XCTAssertEqual(try Data(contentsOf: copy), data)
            let renamed = try NoteFileOperations.rename(copy, to: "renamed-" + filename)
            XCTAssertEqual(renamed.lastPathComponent, "renamed-" + filename)
        }
        let panel = NSSavePanel()
        XCTAssertTrue(NoteDocument().prepareSavePanel(panel))
        XCTAssertTrue(panel.allowsOtherFileTypes)
        XCTAssertEqual(panel.allowedContentTypes.first?.preferredFilenameExtension, "txt")
        XCTAssertEqual(panel.nameFieldStringValue, "Untitled.txt")
    }

    func testReturnCopiesLeadingTabsAndSupportsUndo() throws {
        let note = NoteDocument()
        note.text = "Earlier line\n\t\tThought ☕️"
        note.makeWindowControllers()
        defer { note.close() }
        let controller = try XCTUnwrap(note.windowControllers.first as? EditorWindowController)
        let editor = controller.editor.textView
        let original = note.text
        let undo = try XCTUnwrap(note.undoManager)
        undo.groupsByEvent = false
        editor.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
        undo.beginUndoGrouping()
        editor.insertNewline(nil)
        editor.breakUndoCoalescing()
        undo.endUndoGrouping()
        XCTAssertEqual(note.text, original + "\n\t\t")
        XCTAssertEqual(editor.selectedRange().location, (note.text as NSString).length)
        undo.undo()
        XCTAssertEqual(note.text, original)
        undo.redo()
        XCTAssertEqual(note.text, original + "\n\t\t")

        for (text, position, expected) in [
            ("\t\t", 2, "\t\t\n\t\t"),
            ("\t\tabcd", 4, "\t\tab\n\t\tcd"),
            ("\t\tabcd", 1, "\t\n\t\tabcd"),
            ("plain\ttext", 10, "plain\ttext\n"),
            ("\tprevious\n", 10, "\tprevious\n\n")
        ] {
            note.text = text
            controller.display(note)
            editor.setSelectedRange(NSRange(location: position, length: 0))
            undo.beginUndoGrouping()
            editor.insertNewline(nil)
            editor.breakUndoCoalescing()
            undo.endUndoGrouping()
            XCTAssertEqual(note.text, expected)
        }
    }

    func testSidebarTogglePreservesEditorScrollPosition() throws {
        let note = NoteDocument()
        note.text = String(repeating: "A line of text that stays visible while toggling the sidebar.\n", count: 300)
        note.makeWindowControllers()
        defer { note.close() }
        let controller = try XCTUnwrap(note.windowControllers.first as? EditorWindowController)
        let window = try XCTUnwrap(controller.window)
        controller.showWindow(nil)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.contentView?.layoutSubtreeIfNeeded()
        let editor = controller.editor
        for position: CGFloat in [0, 500, 1500] {
            editor.restoreScrollPosition(NSPoint(x: 0, y: position))
            for _ in 0..<6 {
                controller.toggleSidebar(nil)
                window.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                XCTAssertEqual(editor.scrollView.contentView.bounds.minY, position, accuracy: 1)
            }
        }
    }

    func testDeletingOpenNoteReplacesItWithCleanNoteAndKeepsFolder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("delete-test.txt")
        try Data("Saved text".utf8).write(to: url)
        let note = try NoteDocument(contentsOf: url, ofType: "public.plain-text")
        NSDocumentController.shared.addDocument(note)
        note.makeWindowControllers()
        let controller = try XCTUnwrap(note.windowControllers.first as? EditorWindowController)
        let window = try XCTUnwrap(controller.window)
        defer { (controller.document as? NSDocument)?.close() }
        let split = try XCTUnwrap(window.contentView as? NSSplitView)
        let sidebar = try XCTUnwrap(split.arrangedSubviews.first as? FolderBrowser)
        sidebar.setFolder(directory)
        controller.toggleSidebar(nil)
        let undo = try XCTUnwrap(note.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        controller.editor.textView.insertText("Pending edits", replacementRange: NSRange(location: 0, length: 0))
        controller.editor.textView.breakUndoCoalescing()
        undo.endUndoGrouping()
        XCTAssertTrue(note.isDocumentEdited)

        let trashedURL = try NoteFileOperations.trash(url)
        defer { if let trashedURL { try? FileManager.default.removeItem(at: trashedURL) } }
        let replacement = try XCTUnwrap(controller.document as? NoteDocument)
        XCTAssertFalse(replacement === note)
        XCTAssertTrue(controller.window === window)
        XCTAssertEqual(controller.folderURL, directory)
        XCTAssertFalse(sidebar.isHidden)
        XCTAssertEqual(controller.editor.textView.string, "")
        XCTAssertEqual(replacement.text, "")
        XCTAssertNil(replacement.fileURL)
        XCTAssertFalse(replacement.isDocumentEdited)
        XCTAssertFalse(replacement.undoManager?.canUndo ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFileCopyAvoidsOverwriteAndMovePreservesOpenEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = directory.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("note.txt")
        try Data("Saved text".utf8).write(to: original)
        let firstCopy = try NoteFileOperations.copy(original, into: directory)
        let secondCopy = try NoteFileOperations.copy(original, into: directory)
        XCTAssertEqual(firstCopy.lastPathComponent, "note copy.txt")
        XCTAssertEqual(secondCopy.lastPathComponent, "note copy 2.txt")
        XCTAssertEqual(try String(contentsOf: firstCopy, encoding: .utf8), "Saved text")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "Saved text")

        let note = try NoteDocument(contentsOf: original, ofType: "public.plain-text")
        NSDocumentController.shared.addDocument(note)
        defer { NSDocumentController.shared.removeDocument(note) }
        note.text = "Unsaved edits"
        note.updateChangeCount(.changeDone)
        XCTAssertThrowsError(try NoteFileOperations.move(original, to: firstCopy))
        let moved = try NoteFileOperations.move(original, to: destination.appendingPathComponent("note.txt"))
        XCTAssertEqual(note.fileURL, moved)
        XCTAssertEqual(note.text, "Unsaved edits")
        XCTAssertTrue(note.isDocumentEdited)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "Saved text")
    }

    func testNewNoteReusesWindowAndClearsDocumentState() throws {
        let note = NoteDocument()
        NSDocumentController.shared.addDocument(note)
        note.makeWindowControllers()
        let controller = try XCTUnwrap(note.windowControllers.first as? EditorWindowController)
        let window = try XCTUnwrap(controller.window)
        controller.showWindow(nil)
        defer { (controller.document as? NSDocument)?.close() }

        controller.newNote(nil)
        let replaced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { controller.document !== note }
        }, object: nil)
        wait(for: [replaced], timeout: 3)
        let replacement = try XCTUnwrap(controller.document as? NoteDocument)
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(replacement.windowControllers.first === controller)
        XCTAssertTrue(note.windowControllers.isEmpty)
        XCTAssertNil(replacement.fileURL)
        XCTAssertEqual(controller.editor.textView.string, "")
        XCTAssertFalse(replacement.isDocumentEdited)
        XCTAssertFalse(replacement.undoManager?.canUndo ?? false)
    }

    func testFirstSaveShowsContainingFolderAndPreservesAncestorRoot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("Notes")
        let nested = root.appendingPathComponent("Journal/September")
        let sibling = directory.appendingPathComponent("Notes-other")
        for folder in [nested, sibling] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, initialRoot, target, expectedRoot) in [
            (0, nil as URL?, nested, nested),
            (1, root, nested, root),
            (2, root, sibling, sibling)
        ] {
            let note = NoteDocument()
            note.makeWindowControllers()
            let controller = try XCTUnwrap(note.windowControllers.first as? EditorWindowController)
            defer { note.close() }
            let split = try XCTUnwrap(controller.window?.contentView as? NSSplitView)
            let sidebar = try XCTUnwrap(split.arrangedSubviews.first as? FolderBrowser)
            if let initialRoot { sidebar.setFolder(initialRoot) }
            note.text = "First save"
            let saved = expectation(description: "Saved new note \(index)")
            note.save(to: target.appendingPathComponent("note\(index).txt"), ofType: "public.plain-text", for: .saveOperation) { error in
                XCTAssertNil(error)
                saved.fulfill()
            }
            wait(for: [saved], timeout: 10)
            XCTAssertEqual(controller.folderURL?.standardizedFileURL, expectedRoot.standardizedFileURL)
            XCTAssertFalse(sidebar.isHidden)
        }
    }

    func testInlineRenameCommitsAndEscapeCancels() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = InlineFilenameField(labelWithString: "original.txt")
        field.frame = NSRect(x: 20, y: 50, width: 200, height: 24)
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        var committedNames: [String] = []
        field.onCommit = { committedNames.append($0); return true }
        field.beginRename()
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 8))
        editor.string = "renamed.txt"
        XCTAssertTrue(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(committedNames, ["renamed.txt"])
        XCTAssertEqual(field.stringValue, "renamed.txt")
        XCTAssertFalse(field.isRenaming)

        field.beginRename()
        let secondEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        secondEditor.string = "discard.txt"
        XCTAssertTrue(field.control(field, textView: secondEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(committedNames, ["renamed.txt"])
        XCTAssertEqual(field.stringValue, "renamed.txt")
        XCTAssertFalse(field.isEditable)
    }

    func testRenamePreservesOpenDocumentEditsAndRejectsCollisions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.txt")
        let existing = directory.appendingPathComponent("existing.txt")
        try Data("Saved text".utf8).write(to: original)
        try Data("Other note".utf8).write(to: existing)
        let note = try NoteDocument(contentsOf: original, ofType: "public.plain-text")
        NSDocumentController.shared.addDocument(note)
        defer { NSDocumentController.shared.removeDocument(note) }
        note.text = "Pending edits"
        note.updateChangeCount(.changeDone)

        XCTAssertThrowsError(try NoteFileOperations.rename(original, to: "existing.txt"))
        XCTAssertThrowsError(try NoteFileOperations.rename(original, to: "../outside.txt"))
        XCTAssertThrowsError(try NoteFileOperations.rename(original, to: ""))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "Other note")
        XCTAssertEqual(note.fileURL, original)

        let renamed = try NoteFileOperations.rename(original, to: "Renamed ☕️")
        XCTAssertEqual(renamed.lastPathComponent, "Renamed ☕️")
        XCTAssertEqual(note.fileURL, renamed)
        XCTAssertEqual(note.text, "Pending edits")
        XCTAssertTrue(note.isDocumentEdited)
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "Saved text")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    func testCreateAndRenameFolderPreservesOpenDescendantNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try NoteFileOperations.createDirectory(in: root, named: "Drafts.v1")
        let nested = try NoteFileOperations.createDirectory(in: folder, named: "Nested")
        XCTAssertThrowsError(try NoteFileOperations.createDirectory(in: root, named: "Drafts.v1"))
        for invalid in ["", "..", "../outside", "a/b", "a:b"] {
            XCTAssertThrowsError(try NoteFileOperations.createDirectory(in: root, named: invalid))
        }
        let original = nested.appendingPathComponent("note.txt")
        try Data("Saved".utf8).write(to: original)
        let note = try NoteDocument(contentsOf: original, ofType: "public.plain-text")
        NSDocumentController.shared.addDocument(note)
        defer { NSDocumentController.shared.removeDocument(note) }
        note.text = "Pending edits"
        note.updateChangeCount(.changeDone)
        let collision = try NoteFileOperations.createDirectory(in: root, named: "Existing")
        try Data("Keep".utf8).write(to: collision.appendingPathComponent("keep.txt"))
        XCTAssertThrowsError(try NoteFileOperations.rename(folder, to: "Existing"))
        XCTAssertEqual(note.fileURL, original)
        let renamed = try NoteFileOperations.rename(folder, to: "Ideas")
        let destination = renamed.appendingPathComponent("Nested/note.txt")
        XCTAssertEqual(note.fileURL?.standardizedFileURL, destination.standardizedFileURL)
        XCTAssertEqual(note.text, "Pending edits")
        XCTAssertTrue(note.isDocumentEdited)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "Saved")
        let unrelated = root.appendingPathComponent("Drafts.v10/other.txt")
        XCTAssertEqual(NoteFileOperations.relocatedURL(unrelated, from: folder, to: renamed), unrelated)
    }

    func testFolderContextMenuAndInlineRename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try NoteFileOperations.createDirectory(in: root, named: "Drafts.v1")
        try Data("Child".utf8).write(to: folder.appendingPathComponent("child.txt"))
        let controller = EditorWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        controller.showWindow(nil)
        controller.toggleSidebar(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(window.contentView as? NSSplitView)
        let sidebar = try XCTUnwrap(split.arrangedSubviews.first as? FolderBrowser)
        let scroll = try XCTUnwrap(sidebar.subviews.first { $0 is NSScrollView } as? NSScrollView)
        let outline = try XCTUnwrap(scroll.documentView as? NSOutlineView)
        sidebar.setFolder(root)
        waitForRows(1, in: outline)
        outline.expandItem(outline.item(atRow: 0))
        waitForRows(2, in: outline)
        let point = outline.convert(NSPoint(x: 80, y: outline.rect(ofRow: 0).midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(outline.menu(for: event))
        let create = try XCTUnwrap(menu.items.first { $0.title == "New Folder…" })
        XCTAssertEqual((create.representedObject as? URL)?.standardizedFileURL, folder.standardizedFileURL)
        XCTAssertTrue(create.isEnabled)
        let rename = try XCTUnwrap(menu.items.first { $0.title == "Rename…" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(rename.action), to: rename.target, from: rename))
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
        let field = try XCTUnwrap(cell.textField as? InlineFilenameField)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertEqual(editor.selectedRange().length, "Drafts.v1".utf16.count)
        editor.string = "Renamed"
        XCTAssertTrue(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let reloaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                guard outline.numberOfRows == 2,
                      let cell = outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView else { return false }
                return cell.textField?.stringValue == "Renamed" && outline.isItemExpanded(outline.item(atRow: 0))
            }
        }, object: nil)
        wait(for: [reloaded], timeout: 5)
    }

    func testSwitchingToShortAndEmptyNotesClearsTheViewport() throws {
        let controller = EditorWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        controller.showWindow(nil)
        controller.toggleSidebar(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let editor = controller.editor
        let longNote = NoteDocument()
        longNote.text = String(repeating: "Previous paragraph that must disappear.\n", count: 200)
        let originalText = longNote.text
        let nextNote = NoteDocument()

        for replacement in ["Short note", ""] {
            editor.display(longNote)
            editor.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 200))
            window.displayIfNeeded()
            nextNote.text = replacement
            editor.display(nextNote)

            XCTAssertEqual(editor.textView.string, replacement)
            XCTAssertEqual(longNote.text, originalText)
            XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 0, length: 0))
            XCTAssertEqual(editor.scrollView.contentView.bounds.minY, 0, accuracy: 0.5)
            XCTAssertEqual(editor.textView.frame.height, editor.scrollView.contentSize.height, accuracy: 1)
            XCTAssertFalse(nextNote.isDocumentEdited)
            XCTAssertFalse(nextNote.undoManager?.canUndo ?? false)

            window.makeFirstResponder(nil)
            window.displayIfNeeded()
            let textView = editor.textView
            let bitmap = try XCTUnwrap(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
            textView.cacheDisplay(in: textView.bounds, to: bitmap)
            let scaleX = CGFloat(bitmap.pixelsWide) / textView.bounds.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / textView.bounds.height
            let textRects = textView.textCursorRects(in: textView.bounds).map { $0.insetBy(dx: -2, dy: -2) }
            var stalePixels = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                    let point = NSPoint(x: CGFloat(x) / scaleX, y: CGFloat(y) / scaleY)
                    guard !textRects.contains(where: { $0.contains(point) }) else { continue }
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       min(color.redComponent, color.greenComponent, color.blueComponent) < 0.95 {
                        stalePixels += 1
                    }
                }
            }
            XCTAssertEqual(stalePixels, 0, "The area outside the new note must be completely white")
        }
    }

    func testSavingPreservesSidebarScrollAndExpandedFolder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = directory.appendingPathComponent("Journal")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<100 {
            try Data("Note \(index)".utf8).write(to: nested.appendingPathComponent("note\(index).txt"))
        }
        let url = nested.appendingPathComponent("note60.txt")
        let note = try NoteDocument(contentsOf: url, ofType: "public.plain-text")
        note.makeWindowControllers()
        defer { note.close() }
        let controller = try XCTUnwrap(note.windowControllers.first as? EditorWindowController)
        controller.showWindow(nil)
        controller.toggleSidebar(nil)
        let split = try XCTUnwrap(controller.window?.contentView as? NSSplitView)
        let sidebar = try XCTUnwrap(split.arrangedSubviews.first as? FolderBrowser)
        let scroll = try XCTUnwrap(sidebar.subviews.first { $0 is NSScrollView } as? NSScrollView)
        let outline = try XCTUnwrap(scroll.documentView as? NSOutlineView)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        sidebar.setFolder(directory)
        waitForRows(1, in: outline)
        let folder = try XCTUnwrap(outline.item(atRow: 0))
        outline.expandItem(folder)
        waitForRows(101, in: outline)
        sidebar.selectFile(url)
        let selectedRow = outline.selectedRow
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1400))
        scroll.reflectScrolledClipView(scroll.contentView)
        let originalY = scroll.contentView.bounds.minY
        XCTAssertGreaterThan(originalY, 0)
        var selectionCallbacks = 0
        sidebar.onSelectFile = { _ in selectionCallbacks += 1 }

        // A newly discovered file proves the asynchronous refresh completed.
        try Data().write(to: nested.appendingPathComponent("zz-new.txt"))
        note.text = "Saved change"
        note.updateChangeCount(.changeDone)
        let saved = expectation(description: "Note saved")
        note.save(to: url, ofType: "public.plain-text", for: .saveOperation) { error in
            XCTAssertNil(error)
            saved.fulfill()
        }
        wait(for: [saved], timeout: 10)
        waitForRows(102, in: outline)
        XCTAssertEqual(scroll.contentView.bounds.minY, originalY, accuracy: 1)
        XCTAssertTrue(outline.isItemExpanded(folder))
        XCTAssertEqual(outline.selectedRow, selectedRow)
        XCTAssertEqual(selectionCallbacks, 0)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Saved change")
    }

    private func waitForRows(_ count: Int, in outline: NSOutlineView) {
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { outline.numberOfRows == count }
        }, object: nil)
        wait(for: [loaded], timeout: 5)
    }

    func testFolderExpansionSettlesAndKeepsSiblingRowsVisible() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let journal = directory.appendingPathComponent("Journal")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["one.txt", "two.txt", "three.txt"] {
            try Data().write(to: journal.appendingPathComponent(name))
        }
        try Data().write(to: directory.appendingPathComponent("sibling.txt"))
        let controller = EditorWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        controller.showWindow(nil)
        controller.toggleSidebar(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(window.contentView as? NSSplitView)
        let sidebar = try XCTUnwrap(split.arrangedSubviews.first as? FolderBrowser)
        let scroll = try XCTUnwrap(sidebar.subviews.first { $0 is NSScrollView } as? NSScrollView)
        let outline = try XCTUnwrap(scroll.documentView as? NSOutlineView)
        sidebar.setFolder(directory)
        waitForRows(2, in: outline)
        let folder = try XCTUnwrap(outline.item(atRow: 0))
        var expansionCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSOutlineView.itemDidExpandNotification, object: outline, queue: .main
        ) { _ in MainActor.assumeIsolated { expansionCount += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }

        outline.animator().expandItem(folder)
        waitForRows(5, in: outline)
        let settled = expectation(description: "Expansion finishes without repeated reloads")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertLessThanOrEqual(expansionCount, 2, "Loading must not repeatedly restart expansion")
        XCTAssertTrue(outline.isItemExpanded(folder))
        XCTAssertEqual(outline.numberOfRows, 5)
        window.displayIfNeeded()
        for row in 0..<5 {
            let view = try XCTUnwrap(outline.rowView(atRow: row, makeIfNecessary: true))
            XCTAssertEqual(view.frame.minY, outline.rect(ofRow: row).minY, accuracy: 1)
            XCTAssertEqual(view.frame.height, outline.rowHeight, accuracy: 1)
        }
    }

    func testTitlebarGeometry() throws {
        let controller = EditorWindowController()
        let window = try XCTUnwrap(controller.window as? NoteWindow)
        defer { window.close() }
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 800, height: 500),
                     NSSize(width: 1280, height: 800)] {
            window.setContentSize(size)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let nativeButtons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
            let controls = nativeButtons + window.noteButtons
            XCTAssertEqual(controls.count, 5)
            for (index, (button, centerX)) in zip(controls, [23.0, 43.0, 63.0, 102.0, 136.0]).enumerated() {
                let frame = button.convert(button.bounds, to: nil)
                XCTAssertEqual(frame.midX, centerX, accuracy: 0.5)
                XCTAssertEqual(window.frame.height - frame.midY, index == 4 ? 23 : 24, accuracy: 0.5)
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

    func testTitlebarStaysAlignedWhenSidebarSwitchesDocuments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ["Short.txt", "A much longer name for the second note.txt"].map {
            directory.appendingPathComponent($0)
        }
        for url in urls { try Data("A note".utf8).write(to: url) }
        let first = try NoteDocument(contentsOf: urls[0], ofType: "public.plain-text")
        NSDocumentController.shared.addDocument(first)
        first.makeWindowControllers()
        let controller = try XCTUnwrap(first.windowControllers.first as? EditorWindowController)
        let window = try XCTUnwrap(controller.window as? NoteWindow)
        defer { (controller.document as? NoteDocument)?.close() }
        controller.showWindow(nil)
        controller.toggleSidebar(nil)
        let split = try XCTUnwrap(window.contentView as? NSSplitView)
        let sidebar = try XCTUnwrap(split.arrangedSubviews.first as? FolderBrowser)
        sidebar.setFolder(directory)
        let scroll = try XCTUnwrap(sidebar.subviews.first { $0 is NSScrollView } as? NSScrollView)
        let outline = try XCTUnwrap(scroll.documentView as? NSOutlineView)
        waitForRows(2, in: outline)

        for url in [urls[1], urls[0], urls[1]] {
            sidebar.onSelectFile?(url)
            let switched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated {
                    (controller.document as? NoteDocument)?.fileURL == url
                }
            }, object: nil)
            wait(for: [switched], timeout: 5)
            XCTAssertTrue(window.firstResponder === outline)
            XCTAssertGreaterThanOrEqual(outline.selectedRow, 0)
            XCTAssertEqual(outline.view(atColumn: 0, row: outline.selectedRow,
                                        makeIfNecessary: false)?.toolTip.map {
                URL(fileURLWithPath: $0).lastPathComponent
            }, url.lastPathComponent)
            window.makeFirstResponder(controller.editor.textView)
            XCTAssertGreaterThanOrEqual(outline.selectedRow, 0)
            // Let AppKit finish titlebar layout without a mouse or key event.
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let native = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
            for (index, (button, x)) in zip(native + window.noteButtons, [23.0, 43.0, 63.0, 102.0, 136.0]).enumerated() {
                let frame = button.convert(button.bounds, to: nil)
                XCTAssertEqual(frame.midX, x, accuracy: 0.5)
                XCTAssertEqual(window.frame.height - frame.midY, index == 4 ? 23 : 24, accuracy: 0.5)
            }
        }
    }

    func testSidebarOpensAndClosesImmediately() throws {
        let controller = EditorWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        controller.showWindow(nil)
        let split = try XCTUnwrap(window.contentView as? NSSplitView)
        let sidebar = try XCTUnwrap(split.arrangedSubviews.first)
        XCTAssertTrue(sidebar.isHidden)

        controller.toggleSidebar(nil)
        XCTAssertFalse(sidebar.isHidden)
        XCTAssertEqual(sidebar.frame.width, 240, accuracy: 2)
        let scroll = try XCTUnwrap(sidebar.subviews.first { $0 is NSScrollView } as? NSScrollView)
        XCTAssertTrue(scroll is SmoothScrollView)
        XCTAssertEqual(scroll.scrollerStyle, .overlay)

        controller.toggleSidebar(nil)
        XCTAssertTrue(sidebar.isHidden)
    }

    func testFullScreenControlsOverlayContentAndRestoreTitlebar() throws {
        let controller = EditorWindowController()
        let window = try XCTUnwrap(controller.window as? NoteWindow)
        defer { window.close() }
        controller.showWindow(nil)
        let split = try XCTUnwrap(window.contentView as? NSSplitView)
        let toolbar = try XCTUnwrap(window.toolbar)
        let accessory = try XCTUnwrap(window.titlebarAccessoryViewControllers.first)

        for failedToEnter in [false, true] {
            controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            XCTAssertNil(window.toolbar)
            XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
            XCTAssertEqual(split.arrangedSubviews.count, 2, "The controls must not become a split pane")
            for button in window.noteButtons {
                XCTAssertTrue(button.isDescendant(of: split))
                XCTAssertEqual(button.convert(button.bounds, to: nil).midY,
                               window.frame.height - (button === window.noteButtons.last ? 23 : 24), accuracy: 0.5)
            }
            controller.toggleSidebar(nil)
            XCTAssertEqual(split.arrangedSubviews.count, 2)
            controller.toggleSidebar(nil)

            if failedToEnter {
                controller.windowDidFailToEnterFullScreen(window)
            } else {
                let nativeButtons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                    .compactMap { window.standardWindowButton($0) }
                controller.windowWillExitFullScreen(Notification(name: NSWindow.willExitFullScreenNotification, object: window))
                window.displayIfNeeded()
                XCTAssertTrue(nativeButtons.allSatisfy { $0.alphaValue == 0 })
                controller.windowDidFailToExitFullScreen(window)
                XCTAssertTrue(nativeButtons.allSatisfy { $0.alphaValue == 1 })
                controller.windowWillExitFullScreen(Notification(name: NSWindow.willExitFullScreenNotification, object: window))
                controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
                XCTAssertTrue(nativeButtons.allSatisfy { $0.alphaValue == 0 })
                window.displayIfNeeded()
                XCTAssertTrue(nativeButtons.allSatisfy { $0.alphaValue == 1 })
                for (button, x) in zip(nativeButtons + window.noteButtons, [23.0, 43.0, 63.0, 102.0, 136.0]) {
                    XCTAssertEqual(button.convert(button.bounds, to: nil).midX, x, accuracy: 0.5)
                }
            }
            XCTAssertTrue(window.toolbar === toolbar)
            XCTAssertTrue(window.titlebarAccessoryViewControllers.first === accessory)
            XCTAssertEqual(split.subviews.count, 2)
            XCTAssertTrue(window.noteButtons.allSatisfy { $0.superview === accessory.view })
        }
    }

    func testNarrowWindowProtectsTitlebar() throws {
        let controller = EditorWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let backdrop = try XCTUnwrap(controller.editor.subviews.first { $0 is TitlebarBackdropView })
        window.setContentSize(NSSize(width: 480, height: 500))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(backdrop.isHidden)
        XCTAssertEqual(backdrop.frame.height, EditorMetrics.titlebarHeight)

        window.setContentSize(NSSize(width: 1280, height: 800))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(backdrop.isHidden, "The backdrop now protects the maximum filename width too")
        window.setContentSize(NSSize(width: 1600, height: 800))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(backdrop.isHidden)
    }

    func testFindBarStaysBelowOpaqueTitlebar() throws {
        let controller = EditorWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let editor = controller.editor
        let backdrop = try XCTUnwrap(editor.subviews.first { $0 is TitlebarBackdropView })
        window.setContentSize(NSSize(width: 1600, height: 800))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(backdrop.isHidden)

        editor.scrollView.isFindBarVisible = true
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.scrollView.frame.maxY, backdrop.frame.minY)
        XCTAssertFalse(backdrop.isHidden)
        XCTAssertTrue(backdrop.isOpaque)

        window.setContentSize(NSSize(width: 1000, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.scrollView.frame.maxY, backdrop.frame.minY)

        editor.scrollView.isFindBarVisible = false
        window.setContentSize(NSSize(width: 1600, height: 800))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.scrollView.frame, editor.bounds)
        XCTAssertTrue(backdrop.isHidden)
    }

    func testCommandShiftETogglesSidebarWhileEditing() throws {
        let controller = EditorWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        controller.showWindow(nil)
        let split = try XCTUnwrap(window.contentView as? NSSplitView)
        let sidebar = try XCTUnwrap(split.arrangedSubviews.first)
        let textView = controller.editor.textView
        textView.string = "Keep this text"
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "E", charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14
        ))

        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertFalse(sidebar.isHidden)
        let scroll = try XCTUnwrap(sidebar.subviews.first { $0 is NSScrollView } as? NSScrollView)
        window.makeFirstResponder(scroll.documentView)
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertTrue(sidebar.isHidden)
        XCTAssertEqual(textView.string, "Keep this text")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 4))
    }

    func testCursorUpdatesUseArrowOutsideText() throws {
        let controller = EditorWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close(); NSCursor.arrow.set() }
        controller.showWindow(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let textView = controller.editor.textView
        textView.string = "A thought"
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        let textRect = try XCTUnwrap(textView.textCursorRects(in: textView.visibleRect).first)

        for (point, cursor) in [
            (NSPoint(x: textRect.midX, y: textRect.midY), NSCursor.iBeam),
            (NSPoint(x: 10, y: textRect.midY), NSCursor.arrow),
            (NSPoint(x: textRect.maxX + 40, y: textRect.midY), NSCursor.arrow),
            (NSPoint(x: textRect.midX, y: textRect.maxY + 40), NSCursor.arrow)
        ] {
            let event = try XCTUnwrap(NSEvent.enterExitEvent(
                with: .cursorUpdate, location: textView.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
            ))
            textView.cursorUpdate(with: event)
            XCTAssertEqual(NSCursor.current.image.tiffRepresentation, cursor.image.tiffRepresentation, "Pointer at \(point)")
            let moved = try XCTUnwrap(NSEvent.mouseEvent(
                with: .mouseMoved, location: event.locationInWindow, modifierFlags: [],
                timestamp: event.timestamp, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0
            ))
            textView.mouseMoved(with: moved)
            XCTAssertEqual(NSCursor.current.image.tiffRepresentation, cursor.image.tiffRepresentation, "Moving at \(point)")
        }

        controller.toggleSidebar(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        NSCursor.resizeLeftRight.set()
        let outside = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: NSPoint(x: 240, y: 200), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ))
        textView.mouseMoved(with: outside)
        XCTAssertEqual(NSCursor.current.image.tiffRepresentation, NSCursor.resizeLeftRight.image.tiffRepresentation)
    }

    func testTextPointerIsLimitedToRenderedText() throws {
        let controller = EditorWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        controller.showWindow(nil)
        window.setContentSize(NSSize(width: 800, height: 500))
        window.contentView?.layoutSubtreeIfNeeded()
        let textView = controller.editor.textView
        XCTAssertEqual(controller.editor.scrollView.documentCursor?.image.tiffRepresentation,
                       NSCursor.arrow.image.tiffRepresentation)
        XCTAssertTrue(textView.textCursorRects(in: textView.visibleRect).isEmpty)

        textView.string = "A thought"
        let container = try XCTUnwrap(textView.textContainer)
        textView.layoutManager?.ensureLayout(for: container)
        let rect = try XCTUnwrap(textView.textCursorRects(in: textView.visibleRect).first)
        XCTAssertGreaterThanOrEqual(rect.minX, textView.textContainerInset.width - 1)
        XCTAssertLessThan(rect.maxX, textView.textContainerInset.width + 100)
        XCTAssertGreaterThan(rect.minY, textView.visibleRect.minY + 50)

        textView.string = String(repeating: "A thought\n", count: 100)
        textView.layoutManager?.ensureLayout(for: container)
        textView.sizeToFit()
        controller.editor.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
        let scrolledRects = textView.textCursorRects(in: textView.visibleRect)
        XCTAssertFalse(scrolledRects.isEmpty)
        for rect in scrolledRects {
            XCTAssertTrue(window.contentLayoutRect.contains(textView.convert(rect, to: nil)))
        }
    }

    func testMouseWheelBurstAccumulatesFullDistance() throws {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { throw XCTSkip("Reduce Motion disables wheel animation.") }
        let note = NoteDocument()
        note.text = String(repeating: "A line of text.\n", count: 300)
        note.makeWindowControllers()
        defer { note.close() }
        let controller = try XCTUnwrap(note.windowControllers.first as? EditorWindowController)
        controller.showWindow(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let scroll = controller.editor.scrollView
        let initialY = scroll.contentView.bounds.minY
        for _ in 0..<3 { scroll.scrollWheel(with: DiscreteWheelEvent()) }
        let settled = expectation(description: "Burst settles at its full distance")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            XCTAssertEqual(scroll.contentView.bounds.minY, initialY + 72 * scroll.verticalLineScroll, accuracy: 0.5)
            settled.fulfill()
        }
        wait(for: [settled], timeout: 2)
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
            XCTAssertEqual(scroll.contentView.bounds.minY, initialY + 24 * scroll.verticalLineScroll, accuracy: 0.5)
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
        XCTAssertEqual(controller.editor.textView.font?.pointSize, EditorSession.fontSize)
        XCTAssertFalse(controller.editor.textView.isRichText)
        XCTAssertTrue(controller.editor.textView.undoManager === note.undoManager)
        XCTAssertFalse(NoteDocument.autosavesInPlace)
    }

    func testFontSizeChangesApplyAcrossWindowsWithoutEditingNote() throws {
        let originalSize = EditorSession.fontSize
        defer { EditorSession.fontSize = originalSize }
        let note = NoteDocument()
        note.text = "A thought"
        note.makeWindowControllers()
        defer { note.close() }
        let controller = try XCTUnwrap(note.windowControllers.first as? EditorWindowController)

        controller.increaseFontSize(nil)
        XCTAssertEqual(EditorSession.fontSize, originalSize + 1)
        XCTAssertEqual(controller.editor.textView.font?.pointSize, originalSize + 1)
        XCTAssertEqual(note.text, "A thought")
        XCTAssertFalse(note.isDocumentEdited)

        let secondNote = NoteDocument()
        secondNote.makeWindowControllers()
        defer { secondNote.close() }
        let secondEditor = try XCTUnwrap((secondNote.windowControllers.first as? EditorWindowController)?.editor)
        XCTAssertEqual(secondEditor.textView.font?.pointSize, originalSize + 1)

        controller.decreaseFontSize(nil)
        XCTAssertEqual(controller.editor.textView.font?.pointSize, originalSize)
    }

    func testFontPreferencesToggleCustomFamilyAndRestoreDefaults() throws {
        let keys = ["noteFontSize", "noteFontFamily", "noteSystemMonospace"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        EditorSession.restoreDefaults()
        let note = NoteDocument()
        note.text = "Font preview\nAnother line"
        note.makeWindowControllers()
        defer { note.close() }
        let editor = try XCTUnwrap((note.windowControllers.first as? EditorWindowController)?.editor)
        editor.textView.setSelectedRange(NSRange(location: 2, length: 3))
        EditorSession.toggleSystemMonospace()
        XCTAssertEqual(editor.textView.font?.fontName, NSFont.monospacedSystemFont(ofSize: 14, weight: .regular).fontName)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "noteSystemMonospace"))
        EditorSession.toggleSystemMonospace()
        XCTAssertEqual(editor.textView.font?.fontName, NSFont.systemFont(ofSize: 14).fontName)
        let custom = try XCTUnwrap(NSFont(name: "Times-Roman", size: 19)?.familyName)
        EditorSession.fontFamily = custom
        EditorSession.fontSize = 19
        EditorSession.toggleSystemMonospace()
        XCTAssertFalse(EditorSession.systemMonospace)
        XCTAssertEqual(editor.textView.font?.familyName, custom)
        XCTAssertEqual(editor.textView.font?.pointSize, 19)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "noteFontFamily"), custom)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "noteFontSize"), 19)
        EditorSession.restoreDefaults()
        XCTAssertEqual(editor.textView.font?.fontName, NSFont.systemFont(ofSize: 14).fontName)
        XCTAssertEqual(editor.textView.font?.pointSize, 14)
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 2, length: 3))
        XCTAssertEqual(note.text, "Font preview\nAnother line")
        XCTAssertFalse(note.isDocumentEdited)
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
