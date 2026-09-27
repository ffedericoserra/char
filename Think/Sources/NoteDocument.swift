import AppKit
import UniformTypeIdentifiers

@objc(NoteDocument)
final class NoteDocument: NSDocument {
    var text = ""

    // Explicit saving keeps the standard Save / Don't Save / Cancel close flow.
    override class var autosavesInPlace: Bool { false }
    override class var autosavesDrafts: Bool { false }
    override class var usesUbiquitousStorage: Bool { false }

    override func makeWindowControllers() {
        let controller = EditorWindowController()
        addWindowController(controller)
        controller.display(self)
    }

    override func data(ofType typeName: String) throws -> Data {
        PlainText.encode(text)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        text = try PlainText.decode(data)
        for case let controller as EditorWindowController in windowControllers {
            controller.display(self)
        }
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowedContentTypes = [UTType(filenameExtension: "txt")!]
        savePanel.allowsOtherFileTypes = false
        savePanel.isExtensionHidden = false
        if fileURL == nil,
           let controller = windowControllers.first as? EditorWindowController,
           let folderURL = controller.folderURL {
            savePanel.directoryURL = folderURL
        }
        return true
    }

    override var fileURL: URL? {
        didSet {
            for case let controller as EditorWindowController in windowControllers {
                controller.documentLocationDidChange()
            }
        }
    }
}

