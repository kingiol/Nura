# macOS End-to-End Testing Design

## Goal

Add a deterministic, native end-to-end testing foundation for the Nura macOS
application. Tests must launch the real application, exercise essential player
controls, and use the bundled local media fixture rather than network content
or system file-picker automation.

## Non-goals

- Pixel-compare OpenGL video output.
- Automate `NSOpenPanel` or other macOS-owned dialogs.
- Replace Rust unit and integration tests.
- Add CI configuration in this change.

## Test Fixture

`test-fixtures/media/oceans.mp4` is the repository's default E2E media
fixture. Its source copy remains outside the repository. Test tooling may use
`NURA_E2E_MEDIA_PATH` to override the default for local diagnosis or a future
replacement fixture.

## Architecture

### Test target

Add a `NuraMacUITests` XCUITest bundle to the XcodeGen project definition.
The generated Xcode scheme includes the bundle as a test target. The test
launches the application as a normal macOS process.

### Test launch configuration

The app accepts these private UI-test launch arguments:

- `-e2e-media-path <absolute-path>`: media opened after the player bridge is
  initialized.
- `-e2e-state-dir <absolute-path>`: isolated player state directory.

Production launches do not supply these arguments and preserve current
behavior. The test state directory prevents resume data and recent media from
polluting the user's Application Support directory.

### Observable UI contract

The player exposes stable accessibility identifiers for the title, playback
toggle, mute toggle, sidebar toggle, sidebar surface, and status text. Dynamic
controls also expose a concise accessibility value so UI tests can assert state
without matching visual icons or localized user-facing labels.

### Test runner

`scripts/test-macos-e2e.sh` resolves the fixture path relative to the
repository root, validates that it exists, then runs the Xcode UI test target.
`NURA_E2E_MEDIA_PATH` takes precedence over the repository fixture.

## First Acceptance Flow

1. Launch Nura with `oceans.mp4` and a unique state directory.
2. Wait until the media title is visible and player status reaches a usable
   playback state.
3. Toggle playback and assert its accessibility value changes.
4. Toggle mute and assert its accessibility value changes.
5. Open and close the playlist sidebar.

## Error Handling

If no fixture is available, the test runner fails before Xcode starts. If a
test's player initialization fails, the UI test reports the player status text
and fails rather than silently passing. Each test receives a fresh state
directory and removes it during teardown.

## Verification

- `xcodegen generate` regenerates the project with the UI test bundle.
- `xcodebuild test` runs the target against the local macOS destination.
- `./scripts/test-macos-e2e.sh` runs the acceptance flow using
  `test-fixtures/media/oceans.mp4` by default.

## Risks

`libmpv` startup timing and OpenGL availability can vary by host. Assertions
therefore wait for semantic accessibility state with bounded timeouts and do
not inspect rendered pixels. Release-runtime packaging validation remains
owned by the existing runtime scripts.
