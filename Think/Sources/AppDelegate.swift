import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var documentController: NSDocumentController!

    func applicationWillFinishLaunching(_ notification: Notification) {
        documentController = NSDocumentController.shared
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.appearance = NSAppearance(named: .aqua)
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
}

