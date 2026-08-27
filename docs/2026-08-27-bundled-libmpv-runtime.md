# Bundled libmpv Runtime Implementation Plan

> For agentic workers: REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Keep Homebrew as Nura's development-time libmpv source while bundling a verified, relocated libmpv dependency closure into every Release Nura.app built by Xcode or scripts/build-macos-app.sh.

**Architecture:** Shell utilities discover, lock, and package the complete non-system Mach-O closure of a developer-selected libmpv. A Release-only Xcode phase invokes the same packager used by the shell build; the Rust loader uses the bundle in Release while preserving Homebrew fallback for Debug.

**Tech Stack:** macOS sh, otool, install_name_tool, codesign, Xcode/XcodeGen project files, Rust 2024 with libloading.

## Execution Status

- [x] Lock and verify the complete `arm64` libmpv dependency closure.
- [x] Package, relocate, and validate the runtime in `Contents/Frameworks`.
- [x] Run the same Release packager from Xcode and the shell build.
- [x] Load the bundled library for Release while retaining Debug Homebrew fallback.
- [x] Update developer and release documentation.
- [ ] Validate a signed app on a macOS installation without Homebrew and complete the license review before public distribution.

## Global Constraints

- The current arm64 target remains unchanged.
- Release runtime locking records every copied filename, resolved source path, SHA-256, and architecture.
- Only /System/Library and /usr/lib are treated as system dependencies.
- Copied dylibs use @rpath/<filename> IDs and sibling references use @loader_path/<filename>.
- Release app startup may not fall back to Homebrew; Debug startup may.
- The packager signs each dylib only when Xcode provides EXPANDED_CODE_SIGN_IDENTITY.
- Public distribution remains behind the manual license/notice review described in the design specification.

---

### Task 1: Discover and Lock the Complete Runtime Closure

**Files:**
- Create: scripts/libmpv-runtime.sh
- Create: scripts/update-libmpv-runtime-lock.sh
- Create: runtime/macos-arm64.lock
- Create: scripts/test-libmpv-runtime.sh

**Interfaces:**
- Consumes: NURA_MPV_LIBRARY or scripts/check-mpv.sh.
- Produces: a deterministic TSV lock: filename<TAB>source_path<TAB>sha256<TAB>architectures.

- [ ] Step 1: Write the failing lock test.

    #!/bin/sh
    set -eu
    ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
    "$ROOT/scripts/update-libmpv-runtime-lock.sh"
    awk -F '\t' 'NR > 1 { print $1 }' "$ROOT/runtime/macos-arm64.lock" | grep -qx 'libmpv.2.dylib'

- [ ] Step 2: Run sh scripts/test-libmpv-runtime.sh. Expected: failure because the lock updater does not exist.

- [ ] Step 3: Implement scripts/libmpv-runtime.sh with nura_resolve_mpv_source and nura_collect_runtime_closure. The first returns NURA_MPV_LIBRARY when set, otherwise invokes scripts/check-mpv.sh. The collector performs a breadth-first scan of otool -L, resolves absolute paths directly, and resolves @loader_path, @executable_path, and @rpath using the current loader plus LC_RPATH entries from otool -l. Dereference symlinks, include every non-system source once, require arm64 from lipo -archs, and fail for unresolved references or basename collisions.

- [ ] Step 4: Implement scripts/update-libmpv-runtime-lock.sh. It calls the collector, calculates hashes with shasum -a 256, sorts by output filename, and atomically writes this exact header:

    # filename	source_path	sha256	architectures

  Its final message states that a lock update requires review and a committed runtime upgrade.

- [ ] Step 5: Run sh scripts/test-libmpv-runtime.sh and inspect the first twelve lock rows. Expected: libmpv.2.dylib and all recursive Homebrew dylibs appear with arm64.

- [ ] Step 6: Commit with message: feat: lock libmpv runtime closure.

### Task 2: Package, Relocate, and Verify the Runtime

**Files:**
- Create: scripts/package-libmpv-runtime.sh
- Modify: scripts/test-libmpv-runtime.sh

**Interfaces:**
- Consumes: scripts/package-libmpv-runtime.sh /path/to/Nura.app and the committed lock.
- Produces: Contents/Frameworks/*.dylib and Contents/Resources/libmpv-runtime-manifest.tsv.

- [ ] Step 1: Extend the failing test to run scripts/build-macos-app.sh and assert that build/Nura.app contains Frameworks/libmpv.2.dylib and Resources/libmpv-runtime-manifest.tsv. For every bundled dylib, otool -L must not contain /opt/homebrew or /usr/local.

- [ ] Step 2: Run sh scripts/test-libmpv-runtime.sh. Expected: failure because the Release app has no Frameworks runtime.

- [ ] Step 3: Implement the packager. It accepts an App argument, removes stale copied dylibs, rediscovers the closure, and requires an exact filename, resolved path, SHA-256, and architecture match to the committed lock before copying with cp -L. It sets each copied dylib ID to @rpath/<filename>, rewrites bundled dependency references to @loader_path/<filename>, scans all final Mach-O dependencies, and writes the verified closure to libmpv-runtime-manifest.tsv.

  When EXPANDED_CODE_SIGN_IDENTITY is nonempty, run these commands for each copied dylib:

    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$dylib"
    codesign --verify --strict "$dylib"

- [ ] Step 4: Run sh scripts/test-libmpv-runtime.sh. Expected: pass; the packaged closure contains no Homebrew library reference.

- [ ] Step 5: Commit with message: feat: bundle verified libmpv runtime.

### Task 3: Use One Release Packaging Path from Xcode and Shell Builds

**Files:**
- Modify: macos/NuraMac/project.yml
- Modify: macos/NuraMac/NuraMac.xcodeproj/project.pbxproj
- Modify: scripts/build-macos-app.sh

**Interfaces:**
- Consumes: scripts/package-libmpv-runtime.sh "$TARGET_BUILD_DIR/$WRAPPER_NAME".
- Produces: a Release-only Xcode build phase shared by Archive and script builds.

- [ ] Step 1: Add this target-level postBuildScripts entry to project.yml:

    postBuildScripts:
      - name: Bundle Verified libmpv Runtime
        basedOnDependencyAnalysis: false
        script: |
          if [ "$CONFIGURATION" = "Release" ]; then
            "$SRCROOT/../../scripts/package-libmpv-runtime.sh" "$TARGET_BUILD_DIR/$WRAPPER_NAME"
          fi

- [ ] Step 2: XcodeGen is unavailable locally. Add the equivalent PBXShellScriptBuildPhase to project.pbxproj after Resources, with alwaysOutOfDate = 1 and the exact script above. This places nested dylib signing before Xcode signs the outer application.

- [ ] Step 3: After copying the Xcode product in scripts/build-macos-app.sh, assert both Frameworks/libmpv.2.dylib and Resources/libmpv-runtime-manifest.tsv exist. Do not call the packager twice; xcodebuild -configuration Release is the single release package path.

- [ ] Step 4: Run:

    ./scripts/build-macos-app.sh
    xcodebuild -project macos/NuraMac/NuraMac.xcodeproj -scheme NuraMac \
      -configuration Release -derivedDataPath build/NuraReleaseVerification \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

  Expected: both apps contain the same runtime manifest.

- [ ] Step 5: Commit with message: feat: package libmpv in release builds.

### Task 4: Load Bundled libmpv in Release and Keep Debug Ergonomic

**Files:**
- Modify: crates/nura-mpv/src/lib.rs
- Test: crates/nura-mpv/src/lib.rs

**Interfaces:**
- Produces: mpv_library_candidates(override_path, executable, release_build) -> Vec<PathBuf>.

- [ ] Step 1: Write a failing release candidate-ordering test. Given /Applications/Nura.app/Contents/MacOS/Nura and a custom override, candidates must be the override then /Applications/Nura.app/Contents/Frameworks/libmpv.2.dylib. Write a Debug test that confirms /opt/homebrew/lib/libmpv.2.dylib remains a candidate.

- [ ] Step 2: Run cargo test -p nura-mpv. Expected: failure because the helper is undefined.

- [ ] Step 3: Implement the helper. Build the bundled path by taking the executable parent twice and appending Frameworks/libmpv.2.dylib. Call the helper from MpvApi::load with !cfg!(debug_assertions). For a Release executable inside .app, return only override and bundled candidates. For Debug, append the existing Homebrew and bare-name fallbacks. Preserve symbol validation and error reporting.

- [ ] Step 4: Run cargo test -p nura-mpv and cargo test. Expected: all Rust tests pass.

- [ ] Step 5: Commit with message: feat: load bundled libmpv in release.

### Task 5: Document the Release Contract and Run Final Checks

**Files:**
- Modify: README.md
- Modify: macos/NuraMac/README.md
- Modify: Brewfile
- Modify: docs/2026-08-27-bundled-libmpv-runtime-design.md

- [ ] Step 1: State that Homebrew supplies development-only runtime input and Release builds include the lock-verified runtime. Document sh scripts/test-libmpv-runtime.sh as the local release-runtime verification command. State that Xcode Debug uses Homebrew and Release/Archive invokes the packager.

- [ ] Step 2: Record this exact manual release gate in the design specification: launch the signed Release app from Finder on a macOS installation without Homebrew and play a local H.264/AAC media file. Do not report this as completed until it runs.

- [ ] Step 3: Run:

    sh scripts/test-libmpv-runtime.sh
    cargo test
    git diff --check
    git status --short

  Expected: checks pass. The clean-machine acceptance test, signing, notarization, and license review remain explicit manual release gates.

- [ ] Step 4: Commit with message: docs: describe bundled release runtime.

## Self-Review

Task 1 locks the complete runtime closure. Task 2 copies, relocates, verifies, manifests, and conditionally signs it. Task 3 applies one Release packager to Xcode and shell builds. Task 4 preserves Xcode Debug/Homebrew development while disallowing Homebrew in Release app loading. Task 5 records the remaining release and legal gates.

The plan intentionally excludes building mpv/FFmpeg from source, Intel support, notarization configuration, and legal approval.
