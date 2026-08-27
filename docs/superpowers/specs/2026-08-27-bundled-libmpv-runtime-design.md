# Bundled libmpv Runtime Design

## Goal

Keep Homebrew as the development-time source of `libmpv`, while packaging a
verified `libmpv` runtime inside every Nura Release app built by either Xcode
or `scripts/build-macos-app.sh`.

## Non-goals

- Building mpv or FFmpeg from source.
- Removing Homebrew from local Debug development.
- Supporting Intel Macs in this change; the target remains `arm64`.
- Signing or notarizing release artifacts.

## Runtime Layout

Release packaging copies `libmpv.2.dylib` and each non-system dylib it needs
into `Nura.app/Contents/Frameworks`. The packager rewrites their install names
to `@loader_path/<filename>` so the dynamic loader resolves the complete
runtime from the app bundle rather than Homebrew paths.

`runtime/macos-arm64.lock` records the expected `libmpv` filename and SHA-256.
It is intentionally checked into source control. The source dylib remains the
developer-installed Homebrew copy, selected with `NURA_MPV_LIBRARY` when a
custom location is needed.

## Build Flows

- `scripts/build-macos-app.sh` packages the runtime after Xcode builds the
  Release app.
- A Release-only Xcode post-build script invokes the same packager for Archive
  and Product > Build workflows.
- Debug builds do not package the runtime and continue to use Homebrew.

## Runtime Loading

The Rust player loads a bundled
`Contents/Frameworks/libmpv.2.dylib` first when running in an app bundle. The
explicit `NURA_MPV_LIBRARY` override stays first for local debugging. Homebrew
paths remain fallback candidates for Debug and existing local workflows.

## Failure Behavior

Packaging fails if the source library is missing, the lock-file checksum does
not match, a dependency cannot be found, or a copied dylib still references a
Homebrew path. The error identifies the affected library and recommends the
required developer action.

## Verification

- Run `cargo test`.
- Build the Release app through the shell script and confirm that
  `Contents/Frameworks/libmpv.2.dylib` exists.
- Confirm `otool -L` reports no `/opt/homebrew` or `/usr/local` dynamic-library
  references inside the bundled runtime.
- Build Release through `xcodebuild` and confirm the post-build script creates
  the same Frameworks runtime.
