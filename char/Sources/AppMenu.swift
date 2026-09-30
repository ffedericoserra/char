import AppKit

@MainActor
enum AppMenu {
    static func install() {
        let main = NSMenu()
        NSApp.mainMenu = main

        let app = submenu("char", in: main)
        item("About char", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), in: app)
        app.addItem(.separator())
        let settings = item("Settings…", #selector(AppDelegate.showSettings(_:)), key: ",", in: app)
        settings.target = NSApp.delegate
        app.addItem(.separator())
        let services = submenu("Services", in: app)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        item("Hide char", #selector(NSApplication.hide(_:)), key: "h", in: app)
        item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option], in: app)
        item("Show All", #selector(NSApplication.unhideAllApplications(_:)), in: app)
        app.addItem(.separator())
        item("Quit char", #selector(NSApplication.terminate(_:)), key: "q", in: app)

        let file = submenu("File", in: main)
        let newNote = item("New Note", #selector(AppDelegate.newNote(_:)), key: "n", in: file)
        newNote.target = NSApp.delegate
        item("New Window", #selector(NSDocumentController.newDocument(_:)), key: "n", modifiers: [.command, .shift], in: file)
        item("Open…", #selector(NSDocumentController.openDocument(_:)), key: "o", in: file)
        let folder = item("Open Folder…", #selector(AppDelegate.openFolder(_:)), key: "o", modifiers: [.command, .shift], in: file)
        folder.target = NSApp.delegate
        file.addItem(.separator())
        item("Close", #selector(NSWindow.performClose(_:)), key: "w", in: file)
        item("Save…", #selector(NSDocument.save(_:)), key: "s", in: file)
        item("Save As…", #selector(NSDocument.saveAs(_:)), key: "s", modifiers: [.command, .shift], in: file)
        item("Revert to Saved…", #selector(NSDocument.revertToSaved(_:)), in: file)

        let edit = submenu("Edit", in: main)
        item("Undo", Selector(("undo:")), key: "z", in: edit)
        item("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift], in: edit)
        edit.addItem(.separator())
        item("Cut", #selector(NSText.cut(_:)), key: "x", in: edit)
        item("Copy", #selector(NSText.copy(_:)), key: "c", in: edit)
        item("Paste", #selector(NSText.paste(_:)), key: "v", in: edit)
        item("Select All", #selector(NSText.selectAll(_:)), key: "a", in: edit)
        edit.addItem(.separator())
        let find = item("Find…", #selector(NSTextView.performFindPanelAction(_:)), key: "f", in: edit)
        find.tag = NSTextFinder.Action.showFindInterface.rawValue

        let view = submenu("View", in: main)
        item("Toggle Sidebar", #selector(EditorWindowController.toggleSidebar(_:)), key: "b", in: view)
        let mono = item("System Monospace", #selector(AppDelegate.toggleSystemMonospace(_:)), key: "m", modifiers: [.command, .shift], in: view)
        mono.target = NSApp.delegate
        item("Increase Font Size", #selector(EditorWindowController.increaseFontSize(_:)), key: "+", in: view)
        item("Decrease Font Size", #selector(EditorWindowController.decreaseFontSize(_:)), key: "-", in: view)
        item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control], in: view)

        let window = submenu("Window", in: main)
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m", in: window)
        item("Zoom", #selector(NSWindow.performZoom(_:)), in: window)
        window.addItem(.separator())
        item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), in: window)
        NSApp.windowsMenu = window
    }

    private static func submenu(_ title: String, in parent: NSMenu) -> NSMenu {
        let menu = NSMenu(title: title)
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.submenu = menu
        parent.addItem(entry)
        return menu
    }

    @discardableResult
    private static func item(_ title: String, _ action: Selector, key: String = "",
                             modifiers: NSEvent.ModifierFlags = .command, in menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.keyEquivalentModifierMask = modifiers
        menu.addItem(entry)
        return entry
    }
}
