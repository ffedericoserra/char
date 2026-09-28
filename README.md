# Think

A small native macOS text editor for thoughts and everyday writing. Swift and AppKit, macOS 15.0 or later, with no third-party dependencies or cloud service.

## Run

Open `Think.xcodeproj` in Xcode, select **Think**, and press **Run**. No development team is required for a local build.

Or build a standalone app:

```sh
./scripts/build.sh
open build/Think.app
```

The release build produces a universal app for Apple silicon and Intel. It is locally signed for development; distribution signing and notarization are not configured.

## Writing

Launching Think opens a blank note with the cursor ready. Each new note has its own window and undo history.

| Action | Shortcut |
| --- | --- |
| New note in a new window | ⌘N |
| Open a text file | ⌘O |
| Open a folder | ⇧⌘O |
| Save | ⌘S |
| Save As | ⇧⌘S |
| Show or hide sidebar | ⌘B |
| Increase / decrease font size | ⌘+ / ⌘− |
| Find | ⌘F |
| Undo / redo | ⌘Z / ⇧⌘Z |
| Close window | ⌘W |

The two buttons beside the window controls toggle the sidebar and create a new note. A folder is optional. The sidebar shows folders and `.txt` files, loads each directory when needed, and refreshes when the window becomes active. Hidden files, packages, and directory symlinks are excluded. Drag the sidebar edge to resize it.

Selecting a sidebar file reuses the current window after resolving unsaved changes. If the file is already open, its existing window comes forward. Opening a folder does not replace the current note. When a folder is open, the first Save dialog starts there.

## Files and saving

- Native macOS Open and Save dialogs.
- New notes ask for a name and location on their first save.
- Closing a changed note, switching files, or quitting uses macOS's save/cancel/discard flow. An untouched blank note closes immediately.
- Saving is explicit. Think does not silently overwrite files or autosave new notes to a private library.
- Files are saved as UTF-8 `.txt`. UTF-8 and BOM-marked UTF-16/UTF-32 input are accepted. Unsupported encodings are rejected rather than replaced with corrupted text.
- Pasted content is plain text. Automatic quote, dash, and spelling substitutions are off by default.

## Appearance

The writing surface stays white in both system appearances. The font is the macOS system font, regular, 14 pt by default. Font size changes apply to open and new windows until the app quits; they are not saved. Text wraps in a centered column, up to 720 pt wide, with a 96 pt initial top inset and at least 32 pt side margins. The top inset scrolls away with the content.

Trackpad scrolling and momentum remain native. Discrete mouse-wheel steps ease into place in sync with the display's refresh rate; the animation respects Reduce Motion and yields to direct navigation. A slim native overlay scrollbar appears over the white page without reserving a right-hand gutter. The macOS I-beam pointer appears only over note text; blank space uses the arrow pointer. Narrow top and bottom overlays combine an AppKit backdrop blur with a gradient into white, without intercepting selection or scrolling.

The window controls and note buttons share a center line 24 pt below the top edge. Double-click the empty top bar to maximize the window, and double-click again to restore it. The caret stays 1 pt wide and the same height on empty and populated lines.

Layout constants are in `Think/Sources/EditorView.swift`.

## Tests

```sh
./scripts/test.sh
```

The tests cover Unicode and encoding failures, exact text round trips, folder filtering, native document save/reopen, dirty-state tracking through undo/redo, and independent windows. They require Xcode and access to the macOS test runner.

Manual checks for UI changes:

1. Launch, type without clicking, save a new note, close it, and reopen it.
2. Close a changed note: cancel, save, and discard in separate passes.
3. Make a new window; verify that typing and undo affect only that window.
4. Open a folder, expand nested folders, and select notes. Cancel a file switch with unsaved changes.
5. Scroll a long note through both edges; resize the window, toggle the sidebar, and use full screen.
6. Check native Find and scrollbar behavior, including the system's “Always” setting.

## Structure

- `NoteDocument`: text persistence and native document lifecycle.
- `EditorWindowController`: windows, titlebar buttons, folder selection, and safe document switching.
- `EditorView`: native text view, responsive insets, scrolling, and edge softening.
- `FolderBrowser`: asynchronous, lazy folder navigation.
- `PlainText`: lossless text decoding and UTF-8 output.
- `AppMenu` / `AppDelegate`: macOS menus and application lifecycle.
