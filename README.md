<p align="center">
  <img src="macos/NuraMac/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" width="128" alt="Nura app icon">
</p>

<h1 align="center">Nura</h1>

<p align="center">A native macOS media player built with SwiftUI and Rust, powered by libmpv.</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#building">Building</a> ·
  <a href="#contributing">Contributing</a> ·
  <a href="LICENSE">License</a>
</p>

---

## Features

- Play local audio and video files, or open supported public media URLs.
- Open media from the file picker or by dragging files onto the player.
- Resume local media from the last saved position and revisit recent items.
- Switch video, audio, and subtitle tracks, including audio output devices.
- Load matching local subtitle files automatically or add external subtitles manually.
- Adjust subtitle visibility, delay, scale, and position.
- Tune video aspect ratio, rotation, and flipping, plus audio delay.
- Use Picture in Picture while a video is playing.
- Configure playback, video, audio, subtitle, and advanced mpv options from Settings.

## Building

Nura currently targets Apple Silicon Macs running macOS 14 or later.

### Requirements

- The current public version of Xcode.
- Rust with the stable toolchain.
- Homebrew for the development media runtime.

Install the development dependencies:

```sh
brew bundle --file=Brewfile
```

Build and launch the app:

```sh
./scripts/run-macos.sh
```

To create a Release app without launching it:

```sh
./scripts/build-macos-app.sh
```

Release builds bundle Nura's lock-verified `libmpv` runtime into `Nura.app`,
so the resulting application does not require Homebrew or mpv on the user's Mac.

### Verification

Run the Rust test suite:

```sh
cargo test --workspace
```

Check Rust formatting:

```sh
cargo fmt --all -- --check
```

After changing Homebrew or runtime dependencies, validate the bundled runtime:

```sh
./scripts/test-libmpv-runtime.sh
```

For Xcode-based debugging and native UI test notes, see
[`macos/NuraMac/README.md`](macos/NuraMac/README.md).

### GitHub Release

Pushing a tag such as `v0.1.0` starts `.github/workflows/release-macos.yml`.
The workflow builds the arm64 DMG and ZIP, checks that the tag matches
`MARKETING_VERSION`, and creates a GitHub Release with the artifacts and SHA-256
files.

Tag releases use Apple signing and notarization. Configure these repository
secrets before pushing a release tag:

- `APPLE_CERTIFICATE_BASE64`: base64-encoded Developer ID Application `.p12`.
- `APPLE_CERTIFICATE_PASSWORD`: password for the `.p12` file.
- `APPLE_CERTIFICATE_KEYCHAIN_PASSWORD`: temporary CI keychain password.
- `APPLE_SIGNING_IDENTITY`: full Developer ID Application identity.
- `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`: Apple notarization credentials.

#### How to obtain the Secrets

1. Create a `Developer ID Application` certificate in Apple Developer under
   **Certificates, Identifiers & Profiles > Certificates**. Download it,
   install it in Keychain Access, then export the certificate from
   **Keychain Access > My Certificates** as a password-protected `.p12` file.

2. Set `APPLE_CERTIFICATE_BASE64` to the Base64 content of that `.p12` file:

   ```sh
   base64 -i ~/Desktop/NuraDeveloperID.p12 | tr -d '\n' | pbcopy
   ```

   Paste the clipboard value into the GitHub secret. `APPLE_CERTIFICATE_PASSWORD`
   is the password chosen when exporting the `.p12` file.

3. Generate a temporary CI keychain password for `APPLE_CERTIFICATE_KEYCHAIN_PASSWORD`:

   ```sh
   openssl rand -base64 24
   ```

   This password is created by you; it does not come from Apple.

4. Find the exact signing identity for `APPLE_SIGNING_IDENTITY`:

   ```sh
   security find-identity -v -p codesigning
   ```

   Copy the complete `Developer ID Application: ... (TEAMID)` name from the
   output.

5. Set `APPLE_ID` to the Apple Developer account email. Find `APPLE_TEAM_ID`
   in the Apple Developer account's Membership details.

6. Create `APPLE_APP_PASSWORD` at the Apple Account website under
   **Sign-In and Security > App-Specific Passwords**. This is separate from
   your normal Apple Account password.

7. Add all seven values in the GitHub repository under
   **Settings > Secrets and variables > Actions > New repository secret**.

Never commit the `.p12` file or any of these values to the repository. If a
secret is exposed, revoke the certificate or app-specific password and replace
the GitHub secret immediately.

The workflow can also be started from the Actions page. Set `publish_signed` to
`false` to validate the build without Apple credentials; those artifacts are
intentionally named with a `-local` suffix and must not be distributed as a
production release.

## Project Structure

- `crates/` contains the Rust domain, player core, media library, libmpv, and FFI crates.
- `macos/NuraMac/` contains the SwiftUI and AppKit macOS application shell.
- `runtime/` contains the lock file for the bundled `libmpv` runtime.
- `scripts/` contains build, launch, packaging, and verification commands.

## Contributing

Contributions are welcome. Please open an issue to discuss bugs or proposed
features, and keep pull requests focused. Before submitting a change, run the
relevant checks above and include the commands you used to verify it.

When changing `macos/NuraMac/project.yml`, regenerate the Xcode project before
committing:

```sh
xcodegen generate --spec macos/NuraMac/project.yml
```

## License

Nura is released under the [MIT License](LICENSE).
