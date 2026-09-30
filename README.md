# Think

Minimal native macOS text editor.

## Run

Open `Think.xcodeproj` in Xcode, select **Think**, and press **Run**.

Or build a standalone app:

```sh
./scripts/build.sh
open build/Think.app
```

The release build produces a universal app for Apple silicon and Intel. It is locally signed for development; distribution signing and notarization are not configured.