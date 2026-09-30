# char

char is a macOS text editor. Born with immediacy of use and lack of visual disraction in mind.

## Run

To build a standalone app:

```sh
./scripts/build.sh
open build/char.app
```
## Themes

Use **⌘⇧D** or **View → Dark Theme** to toggle light/dark for all windows.
The choice persists across launches.

Edit `char/Sources/Theme.swift`: `ThemePalette.light` and `ThemePalette.dark`
contain independent values for each theme:

- `editorBackground`: text area, top bar backdrop, footer and scroll-edge fade.
- `sidebarBackground`: sidebar background.
- `text` / `sidebarText` / `secondaryText`: editor/title, file names, and status text.
- `icons`: sidebar, top bar and Finder button icons (native traffic lights retain macOS colors).
- `divider`: separator colors.
- `editorFontFamily`: default editor font family, e.g. `"Menlo"`; `""` uses the system font.
- `sidebarFont`, `titleFont`, `statusFont`: UI font sizes, families and weights.

Colors can use `NSColor(white: 0.12, alpha: 1)` (0 = black, 1 = white), or
`NSColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 1)` for RGB values.
For a custom UI font, use `NSFont(name: "Menlo", size: 13)!` with an installed font.
The editor's initial size is `EditorMetrics.defaultFontSize` in
`char/Sources/EditorView.swift`. Saved font settings override the default editor
family and size; reset them in Settings when experimenting with defaults.

After editing, run `./scripts/build.sh`, quit the running app, and reopen
`build/char.app` to see the rebuilt version.
