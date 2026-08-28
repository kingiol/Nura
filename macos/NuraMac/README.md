# NuraMac

The SwiftUI shell links the Rust `nura-ffi` static library from `target/debug` by default, so Xcode Debug builds can stop in both Swift and Rust code. The video surface is the existing OpenGL `NSView` wrapped by `NSViewRepresentable`.

From the repository root, open the native Xcode project:

```sh
open -a Xcode macos/NuraMac/NuraMac.xcodeproj
```

Select the `NuraMac` scheme and choose `Product > Run`. The Xcode project runs a Rust build phase automatically and links `target/debug/libnura_ffi.a` in Debug. Debug builds discover Homebrew's `libmpv` automatically; for a custom development library, add `NURA_MPV_LIBRARY` to the scheme's Run environment.

Release builds and Archives run the `Bundle Verified libmpv Runtime` build phase. It copies the lock-verified `libmpv` dependency closure into `Nura.app/Contents/Frameworks`, so the resulting app does not require Homebrew on the user's Mac. Run `../../scripts/test-libmpv-runtime.sh` from this directory to verify the runtime independently.

Version settings are in the target's `General` tab (`Version` and `Build`), and the app icon is editable in `Assets.xcassets/AppIcon`.

`project.yml` is the XcodeGen source for the project. If you regenerate the project, keep version changes synchronized there as well.

## UI end-to-end tests

The E2E suite launches the real macOS app with the tracked fixture at
`../../test-fixtures/media/oceans.mp4` and requires the Debug `libmpv` runtime.

From this directory, run:

```sh
../../scripts/test-macos-e2e.sh
```

Use another local file with:

```sh
NURA_E2E_MEDIA_PATH=/absolute/path/to/media.mp4 ../../scripts/test-macos-e2e.sh
```

After changing `project.yml`, install XcodeGen with `brew install xcodegen`,
run `xcodegen generate --spec project.yml`, and commit the generated project
and shared scheme.

Release packaging overrides the library path with `NURA_RUST_LIB_DIR=target/release`; use `scripts/build-macos-app.sh` for that flow.
