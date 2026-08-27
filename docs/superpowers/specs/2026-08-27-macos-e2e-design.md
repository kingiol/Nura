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
fixture and must be tracked by Git so a clean clone can run the suite. Its
source copy remains outside the repository. Test tooling may use
`NURA_E2E_MEDIA_PATH` to override the default for local diagnosis or a future
replacement fixture.

## Architecture

### Test target

Add a `NuraMacUITests` XCUITest bundle (`type: bundle.ui-testing`) with its
own source path and a dependency on the `NuraMac` application target. Add the
bundle to `scheme.testTargets` so `xcodebuild test -scheme NuraMac` discovers
it. The test launches the application as a normal macOS process.

`project.yml` remains the source of truth, but the checked-in Xcode project and
shared scheme must be regenerated and committed too. XcodeGen is a build-time
prerequisite; the setup documentation must state how to install it before
regeneration.

### Test launch configuration

The app accepts these private UI-test launch arguments:

- `-e2e-media-path <absolute-path>`: media opened after the player bridge is
  initialized.
- `-e2e-state-dir <absolute-path>`: isolated player state directory.
- `-e2e-defaults-suite <name>`: isolated UserDefaults suite.
- `-e2e-keep-controls-visible`: disables automatic control hiding.

Production launches do not supply these arguments and preserve current
behavior. The test state directory prevents resume data and recent media from
polluting the user's Application Support directory; the defaults suite isolates
the screenshot-directory preference. The app parses the arguments before it
creates `PlayerBridge`, creates the bridge with the supplied state directory,
and opens the fixture asynchronously after bridge creation succeeds.

### Observable UI contract

The player exposes stable accessibility identifiers for the title, playback
toggle, mute toggle, sidebar toggle, sidebar surface, and status text. Dynamic
controls also expose a concise accessibility value so UI tests can assert state
without matching visual icons or localized user-facing labels.

Media-test launches automatically keep controls visible, so they remain in the
accessibility hierarchy during slow `libmpv` initialization. The production
auto-hide behavior is unchanged.

### Test runner

`scripts/test-macos-e2e.sh` resolves the fixture path relative to the
repository root, validates that it exists, then runs the Xcode UI test target.
`NURA_E2E_MEDIA_PATH` takes precedence over the repository fixture. Before
running Xcode, the script executes `scripts/check-mpv.sh` and exports its
resolved library path as `NURA_MPV_LIBRARY`, ensuring Debug test builds can
initialize the player. After fixture validation, it exports the resolved final
fixture path as `NURA_E2E_MEDIA_PATH`; this environment variable is the sole
fixture input for XCTest.

The UI test owns argument construction: in `setUp`, it reads
`NURA_E2E_MEDIA_PATH`, creates a UUID-named state directory and defaults-suite
name, and passes all E2E launch arguments to `XCUIApplication` before
`launch()`. The runner fails before Xcode when a fixture is missing; direct
Xcode runs skip the media flow with a clear message when the environment value
is absent.

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
directory and defaults suite. Teardown terminates the application before
removing its state directory, and reports any failed cleanup path rather than
silently swallowing it.

## Verification

- `xcodegen generate` regenerates the project and shared scheme with the UI
  test bundle.
- `xcodebuild test` runs the target against the local macOS destination.
- `./scripts/test-macos-e2e.sh` runs the acceptance flow using
  `test-fixtures/media/oceans.mp4` by default.

## Risks

`libmpv` startup timing and OpenGL availability can vary by host. Assertions
therefore wait for semantic accessibility state with bounded timeouts and do
not inspect rendered pixels. The runner resolves the Debug runtime before
launching Xcode. Release-runtime packaging validation remains owned by the
existing runtime scripts.
