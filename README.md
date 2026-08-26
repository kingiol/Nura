# Nura

Nura is a native macOS local-media player for playing audio and video files.

## Features

- Open one local audio or video file at a time.
- Open files through the picker or by dropping them onto the player.
- Control playback and resume from the last saved position.
- Select audio and subtitle tracks.
- Load an external subtitle file with the same name as the media file.
- Remember playback progress between sessions.

## Requirements

- macOS
- Homebrew
- mpv `0.41.0`

## Run

Install the media runtime and launch Nura from the repository root:

```sh
brew bundle --file=Brewfile
./scripts/run-macos.sh
```

To build the app without launching it:

```sh
./scripts/build-macos-app.sh
```

## License

Nura is released under the MIT license.
