import AppKit
import UniformTypeIdentifiers

@MainActor
enum NoteFileOperations {
    static func rename(_ url: URL, to name: String) throws -> URL {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"),
              !name.contains("\0") else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError,
                          userInfo: [NSLocalizedDescriptionKey: "Enter a valid filename without slashes or colons."])
        }
        let filename = (name as NSString).pathExtension.isEmpty ? name + ".txt" : name
        guard (filename as NSString).pathExtension.lowercased() == "txt" else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError,
                          userInfo: [NSLocalizedDescriptionKey: "The filename must use the .txt extension."])
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(filename)
        return try move(url, to: destination)
    }

    static func copy(_ url: URL, into directory: URL) throws -> URL {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true, url.pathExtension.lowercased() == "txt" else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnsupportedSchemeError,
                          userInfo: [NSLocalizedDescriptionKey: "Only text files can be pasted into the sidebar."])
        }
        var destination = directory.appendingPathComponent(url.lastPathComponent)
        let stem = url.deletingPathExtension().lastPathComponent
        var index = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            destination = directory.appendingPathComponent(stem + suffix).appendingPathExtension(url.pathExtension)
            index += 1
        }
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    static func move(_ url: URL, to destination: URL) throws -> URL {
        guard destination != url else { return url }
        let document = NSDocumentController.shared.document(for: url)
        // Moving the existing file preserves pending edits and the undo history.
        // FileManager refuses to overwrite a different file at the destination.
        try FileManager.default.moveItem(at: url, to: destination)
        document?.fileURL = destination
        document?.windowControllers.forEach { $0.synchronizeWindowTitleWithDocumentName() }
        return destination
    }

    @discardableResult
    static func trash(_ url: URL) throws -> URL? {
        let document = NSDocumentController.shared.document(for: url)
        // Prepare the replacement before touching disk. If Trash fails, the
        // current document and its windows remain intact.
        let replacement = try document.map { _ in
            try NSDocumentController.shared.makeUntitledDocument(ofType: "public.plain-text") as! NoteDocument
        }
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
        if let document, let replacement {
            NSDocumentController.shared.addDocument(replacement)
            for controller in document.windowControllers {
                document.removeWindowController(controller)
                replacement.addWindowController(controller)
                (controller as? EditorWindowController)?.display(replacement)
            }
            document.close()
        }
        return trashedURL as URL?
    }
}

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

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        let isFirstSave = fileURL == nil && (saveOperation == .saveOperation || saveOperation == .saveAsOperation)
        super.save(to: url, ofType: typeName, for: saveOperation) { error in
            if error == nil, isFirstSave {
                for case let controller as EditorWindowController in self.windowControllers {
                    controller.didSaveNewFile(at: url)
                }
            }
            completionHandler(error)
        }
    }

    override var fileURL: URL? {
        didSet {
            for case let controller as EditorWindowController in windowControllers {
                controller.documentLocationDidChange()
            }
        }
    }
}
