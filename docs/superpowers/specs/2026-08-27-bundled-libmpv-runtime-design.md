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

`runtime/macos-arm64.lock` records the complete runtime closure, not only
`libmpv`: each materialized output filename, resolved source path, SHA-256,
and architecture. It is intentionally checked into source control.
`scripts/update-libmpv-runtime-lock.sh` discovers the closure from the
developer-installed library and is the only way to update this lock after a
conscious runtime upgrade.

The source library remains the developer-installed Homebrew copy, selected
with `NURA_MPV_LIBRARY` when a custom location is needed. A Release package
may be made only when every discovered source file exactly matches the lock.

## Build Flows

- A Release-only Xcode shell build phase invokes the packager after compiling
  Rust and before Xcode signs the product. This covers Archive and explicit
  Release builds made in Xcode.
- `scripts/build-macos-app.sh` uses `xcodebuild -configuration Release`, so it
  exercises that exact same build phase and produces the same runtime.
- Debug builds do not package the runtime and continue to use Homebrew.

For the unsigned shell flow, the runtime is left unsigned because
`CODE_SIGNING_ALLOWED=NO` is explicit. A signed Xcode Archive must run the
packaging phase before Xcode signs nested code and the outer app.

## Runtime Loading

The Rust player loads in this order: explicit `NURA_MPV_LIBRARY`, bundled
`Contents/Frameworks/libmpv.2.dylib` when running in an app bundle, then
Homebrew paths only for non-bundle development workflows. A bundled app never
falls back to Homebrew, so an incomplete package fails clearly instead of
silently using an unverified local library.

## Closure and Relocation Rules

The packager recursively scans each Mach-O file with `otool -L`. It copies
only non-system dependencies into `Contents/Frameworks` and treats
`/System/Library` and `/usr/lib` as system dependencies. Every copied dylib is
materialized as a regular file under its unique basename; a basename collision
between different source files fails the package.

For every copied file, the packager changes its dylib identifier to
`@rpath/<filename>` and changes references to another copied dylib to
`@loader_path/<filename>`. It verifies the whole packaged closure afterwards
and fails if a bundled Mach-O still references `/opt/homebrew`, `/usr/local`,
or an unresolved loader-relative dependency. Symlinks are dereferenced before
hashing and copying.

## Failure Behavior

Packaging fails if the source library is missing, the complete closure does
not match the lock file, a dependency cannot be resolved, a basename collides,
or a copied dylib still references a Homebrew path. The error identifies the
affected library and recommends the required developer action.

## Distribution Compliance

The package process produces a runtime manifest that can be used to update
third-party notices. Public distribution is a human release gate: the release
owner must review the licenses and source/notice obligations for the locked
mpv, FFmpeg, and transitive runtime before signing or uploading the app.

## Verification

- Run `cargo test`.
- Build the Release app through the shell script and confirm that the generated
  runtime manifest and `Contents/Frameworks/libmpv.2.dylib` exist.
- Confirm every bundled Mach-O is `arm64` and its `otool -L` output contains no
  `/opt/homebrew` or `/usr/local` dynamic-library references.
- Build Release through `xcodebuild` and compare its runtime manifest to the
  shell-build output.
- On a macOS environment without Homebrew, launch the app and play a local
  media file. This is the acceptance test for the independent runtime.
- For signed distribution, verify the final archive with `codesign` and
  `spctl` after signing/notarization is configured.
