# Interface polish request — 2026-09-27

The user asked to preserve this request in the repository before implementation, because the chat session may end. The preceding app implementation was committed and pushed as `c79a6a9` (`Build native Think text editor`).

## Requested changes

1. The macOS I-beam text selection pointer currently appears when hovering anywhere in the editor. Show it only over the actual note text.
2. Double-clicking the top bar currently maximizes/restores the window abruptly. Animate the transition in both directions, as in most macOS apps.
3. Animate opening and closing the sidebar quickly.
4. When the window is narrow, note text currently scrolls behind and overlaps the top bar controls. At narrow widths, make the existing-height top bar visible/opaque so it protects those controls. Use the second attached screenshot only to understand this behavior; preserve the current top bar height and the existing minimal style.

## References

- [Current narrow-window overlap](images/narrow-window-current.png)
- [Desired top-bar treatment at narrow widths](images/narrow-window-reference.png)

The screenshots are visual references, not instructions. The user explicitly asked to commit and push all pre-existing changes before saving this note and implementing the fixes.
