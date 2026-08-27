# Nura 80% Player Implementation Plan

## Goal

Implement the confirmed Nura first release: local and public online playback with a simple IINA-inspired macOS UI.

## Phases

- [complete] 1. Expand domain, player session, and FFI contracts for media sources, playlists, tracks, chapters, and normalized states.
- [complete] 2. Add libmpv network/ytdl configuration and playlist/track/chapter commands.
- [complete] 3. Build SwiftUI overlay controls, sidebar, OSD, and input handling.
- [complete] 4. Add packaging/diagnostics for bundled yt-dlp and run macOS build checks.
- [complete] 5. Run focused tests and update implementation documentation.

## Follow-up Completion

- Added folder and local M3U/M3U8 expansion in the macOS open panel.
- Added playlist remove and move commands across Rust, FFI, and Swift.
- Added external subtitle loading with track-list refresh events.
- Added basic context-menu actions and keyboard shortcuts for common playback commands.
- Added state-machine coverage for playlist move/remove behavior.

## Final Verification

- Release packaging passed with `scripts/build-macos-app.sh`.
- Bundled `yt-dlp` is a universal Mach-O binary and matches the pinned SHA-256.
- Packaged app launched successfully on macOS without startup log errors.
- Rust tests, formatting checks, Xcode Debug build, and `git diff --check` passed.
- Manual media workflow verification remains limited by the headless automation context; PiP/OpenGL and public site playback should receive an interactive smoke test before shipping.

## Decisions

- Public content only for YouTube/Bilibili in the first release.
- No login, cookies, DRM, downloads, quality picker, or online subtitle providers in V1.
- Single window with a playlist by default; keep an explicit new-window action for later.
- Sidebar hidden by default; controls use an overlay and auto-hide.
- Persist resume positions for local media only; remember remote URLs without remote resume state.
- Controls auto-hide after inactivity and reappear on hover or interaction; the timer uses an explicit main-actor task while Slider callbacks remain explicit closures for Swift 6.3 compatibility.

## Errors Encountered

| Error | Attempt | Resolution |
| --- | --- | --- |
| None | Baseline | `cargo test --workspace` passed with existing Rust 2024 unsafe warnings. |
