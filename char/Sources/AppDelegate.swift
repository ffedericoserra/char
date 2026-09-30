import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var fontSettings: FontSettingsController?

    @objc func showSettings(_ sender: Any?) {
        if fontSettings == nil { fontSettings = FontSettingsController() }
        fontSettings?.showWindow(sender)
        fontSettings?.window?.makeKeyAndOrderFront(sender)
    }

    @objc func toggleSystemMonospace(_ sender: Any?) { EditorSession.toggleSystemMonospace() }

    @objc func toggleDarkTheme(_ sender: Any?) { AppTheme.toggle() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSystemMonospace(_:)) {
            item.state = EditorSession.systemMonospace && EditorSession.fontFamily.isEmpty ? .on : .off
            return EditorSession.fontFamily.isEmpty
        }
        if item.action == #selector(toggleDarkTheme(_:)) {
            item.state = AppTheme.isDark ? .on : .off
        }
        return true
    }

    private var documentController: NSDocumentController!

    func applicationWillFinishLaunching(_ notification: Notification) {
        documentController = FileDocumentController()
        NSWindow.allowsAutomaticWindowTabbing = false
        AppTheme.apply()
        AppMenu.install()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            documentController.newDocument(nil)
        }
        return true
    }

    @objc func openFolder(_ sender: Any?) {
        if let controller = NSApp.keyWindow?.windowController as? EditorWindowController {
            controller.openFolder(sender)
        } else {
            documentController.newDocument(nil)
            (NSApp.keyWindow?.windowController as? EditorWindowController)?.openFolder(sender)
        }
    }

    @objc func newNote(_ sender: Any?) {
        if let controller = NSApp.keyWindow?.windowController as? EditorWindowController {
            controller.newNote(sender)
        } else {
            documentController.newDocument(sender)
        }
    }
}

/// Treat extensions as filenames, and let the decoder decide whether a file is text.
@MainActor
final class FileDocumentController: NSDocumentController {
    override func typeForContents(of url: URL) throws -> String { "public.plain-text" }

    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?,
                                 completionHandler: @escaping (Int) -> Void) {
        openPanel.allowedContentTypes = []
        openPanel.allowsOtherFileTypes = true
        super.beginOpenPanel(openPanel, forTypes: nil, completionHandler: completionHandler)
    }

    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        super.openDocument(withContentsOf: url, display: displayDocument) { document, alreadyOpen, error in
            if let error = error as NSError?,
               error.domain == NSCocoaErrorDomain,
               error.code == NSFileReadInapplicableStringEncodingError {
                // Never decode binary data lossily or allow saving over it as text.
                if NSWorkspace.shared.open(url) {
                    completionHandler(nil, false, nil)
                    return
                }
            }
            completionHandler(document, alreadyOpen, error)
        }
    }
}
