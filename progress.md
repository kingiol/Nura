# Progress Log

## 2026-08-26

- Confirmed product direction: cover high-frequency IINA workflows while keeping Nura simple.
- Confirmed public network URLs, YouTube, and Bilibili are in the first release.
- Confirmed public content only; no login or Cookie support in V1.
- Confirmed IINA-inspired overlay/sidebar UI and single-window playlist behavior.
- Added and committed the design specification at `docs/plans/2026-08-26-nura-80-percent-player-design.md`.
- Ran `cargo test --workspace`: all tests passed; existing unsafe-operation warnings remain.
- Completed domain/session protocol expansion for `MediaSource`, public URLs, video tracks, chapters, playlist metadata, buffering state, and local-only resume handling.
- Updated `nura-mpv` to use `MediaItem::locator()` and map video tracks to mpv's `vid` property.
- Re-ran focused Rust tests: all passed; existing Rust 2024 unsafe-operation warnings remain.
- Added playlist enqueue, index selection, previous/next, and auto-advance behavior.
- Added chapter metadata and buffering polling from libmpv properties.
- Added speed and screenshot commands through the Rust FFI bridge.
- Reworked the SwiftUI shell with playlist/chapter actions, track selection, speed menu, screenshot, and previous/next controls.
- Added `yt-dlp` to `Brewfile`, a discovery check, and Release app bundling under `Contents/Resources/bin`.
- Added always-on-top window control and kept playback speed across playlist transitions.
- Restored control auto-hide, added a floating PiP panel, and added loop-current-item control.
- Release packaging now downloads and SHA-256 verifies a pinned universal standalone `yt-dlp` binary when a standalone override is not supplied.
- Fixed a Swift 6.3.3 compiler crash by replacing direct actor-isolated Slider method references with explicit closures; the macOS build now succeeds.
- Ran the latest Release packaging successfully.
- Verified `build/Nura.app/Contents/Resources/bin/yt-dlp` is universal (arm64/x86_64) and matches the pinned SHA-256.
- Launched the packaged app successfully; no startup crash or process log error was observed.
- Final residual risk: interactive playback smoke tests for libmpv rendering, PiP context sharing, and public YouTube/Bilibili URLs still need a real desktop session.
- Fixed sidebar layout alignment so the IINA-style panel is explicitly pinned to the trailing edge; Debug build passed again.
- Added folder import and local M3U/M3U8 playlist expansion with stable path de-duplication.
- Added playlist remove/move operations and sidebar row actions.
- Added manual external subtitle loading and mpv track-list refresh events.
- Added render-surface context menu plus Cmd+O, Cmd+L, Space, and Cmd+F shortcuts.
- Added playlist mutation state-machine coverage; Rust tests, formatting, and Xcode Debug build pass.
