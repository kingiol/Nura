# NuraMac

The SwiftUI shell links the Rust `nura-ffi` static library from `target/debug` by default, so Xcode Debug builds can stop in both Swift and Rust code. The video surface is the existing OpenGL `NSView` wrapped by `NSViewRepresentable`.

From the repository root, open the native Xcode project:

```sh
open -a Xcode macos/NuraMac/NuraMac.xcodeproj
```

Select the `NuraMac` scheme and choose `Product > Run`. The Xcode project runs a Rust build phase automatically and links `target/debug/libnura_ffi.a` in Debug. Homebrew's `/opt/homebrew/lib/libmpv.2.dylib` is discovered automatically. For a custom libmpv path, add `NURA_MPV_LIBRARY` to the scheme's Run environment.

Version settings are in the target's `General` tab (`Version` and `Build`), and the app icon is editable in `Assets.xcassets/AppIcon`.

`project.yml` is the XcodeGen source for the project. If you regenerate the project, keep version changes synchronized there as well.

Release packaging overrides the library path with `NURA_RUST_LIB_DIR=target/release`; use `scripts/build-macos-app.sh` for that flow.
