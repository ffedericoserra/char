import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var fontSettings: FontSettingsController?

    @objc func showSettings(_ sender: Any?) {
        if fontSettings == nil { fontSettings = FontSettingsController() }
        fontSettings?.showWindow(sender)
        fontSettings?.window?.makeKeyAndOrderFront(sender)
    }

    @objc func toggleSecondaryFont(_ sender: Any?) { EditorSession.toggleSecondaryFont() }

    @objc func toggleDarkTheme(_ sender: Any?) { AppTheme.toggle() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSecondaryFont(_:)) {
            item.state = EditorSession.usesSecondaryFont ? .on : .off
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

    @objc func newTab(_ sender: Any?) {
        if let controller = NSApp.mainWindow?.windowController as? EditorWindowController {
            controller.newTab(sender)
        } else {
            documentController.newDocument(sender)
        }
    }

    /// Editor windows close their selected tab; other windows simply close.
    @objc func closeCurrentTab(_ sender: Any?) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        if let controller = window.windowController as? EditorWindowController {
            controller.closeCurrentTab(sender)
        } else {
            window.performClose(sender)
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
        // Files opened from Finder or the Open panel become tabs of the front window.
        let host = displayDocument ? NSApp.mainWindow?.windowController as? EditorWindowController : nil
        super.openDocument(withContentsOf: url, display: displayDocument && host == nil) { document, alreadyOpen, error in
            if let host, let note = document as? NoteDocument {
                if alreadyOpen || note.tabHost != nil {
                    note.showWindows()
                } else if !host.openTab(note) {
                    note.makeWindowControllers()
                    note.showWindows()
                }
            }
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
