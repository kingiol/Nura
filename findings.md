# Findings

## Baseline

- `nura-domain::MediaItem` is path-only and rejects non-files.
- `TrackKind` currently has only audio and subtitle variants; video tracks are missing.
- `PlaybackSnapshot` only carries one item, duration, position, volume, mute, audio tracks, subtitle tracks, and an error.
- `PlaybackEngine` already abstracts load/play/pause/seek/volume/mute/select-track/external-subtitle/stop/events.
- `nura-ffi` serializes normalized JSON events and owns a worker thread, but its open command accepts a path string and exposes no playlist/chapter/video-track API.
- `nura-mpv` uses libmpv dynamically and currently initializes with `hwdec=no`, `idle=yes`, `keep-open=yes`, and `input-default-bindings=no`.
- `Nura/Brewfile` currently declares only `mpv`; no `yt-dlp` runtime is bundled or checked.
- SwiftUI currently renders `header + surface + controls`; the render bridge can remain as the AppKit boundary while the visible shell becomes an overlay layout.
- `MediaItem` now supports `LocalFile` and validated public `http/https` URLs; local resume and same-name subtitle loading remain local-only.
- `PlaybackSnapshot` now includes playlist/index, chapters, speed, delays, buffering, and video tracks; `nura-mpv` maps video tracks to `vid` and loads either local locators or URLs.

## Compatibility Constraints

- Keep raw libmpv properties and commands inside `nura-mpv`.
- Keep portable Rust crates free of AppKit dependencies.
- Preserve existing local resume behavior and unit-test seams.
- Avoid adding a media-library scan or plugin system in this implementation pass.

## Implementation Notes

- `PlayerSession` owns playlist sequencing so libmpv remains a media engine rather than a second source of truth.
- `EngineEvent::Ended` advances to the next queued item and falls back to `Ended` when the queue is exhausted.
- Chapters are read from `chapter-list/*`; buffering is normalized from `cache-buffering-state`.
- Release packaging copies a discovered `yt-dlp` executable into `Contents/Resources/bin` and the mpv layer checks that path first.
- Release packaging now pins and verifies the universal standalone `yt-dlp` artifact (`2026.08.19`) before copying it into the app bundle; development lookup still accepts the Homebrew shim.
- Swift 6.3.3 IRGen crashes when a `@MainActor` method is passed directly as a `Slider` `Double` closure. Explicit closures avoid the crash.
