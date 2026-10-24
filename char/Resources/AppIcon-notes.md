# char app icon

The artwork is the user's "char" wordmark (charcoal serif lettering with a thin text cursor), placed on a rounded macOS tile: 824 px square with a 185 px corner radius, centered on a 1024 px transparent canvas.

`AppIcon.png` is the master. `AppIcon.iconset` contains all standard macOS sizes, resized with `sips`; `AppIcon.icns` is packaged with `iconutil` and included in the app's resources by both Xcode and `scripts/build.sh`.
