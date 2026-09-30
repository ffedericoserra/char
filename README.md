# char

Minimal native macOS text editor.

## Run

Open `char.xcodeproj` in Xcode, select **char**, and press **Run**.

Or build a standalone app:

```sh
./scripts/build.sh
open build/char.app
```

The release build produces a universal app for Apple silicon and Intel. It is locally signed for development; distribution signing and notarization are not configured.