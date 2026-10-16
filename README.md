# Textize

**Live captions & translation for your Mac**

Textize is an on-device STT (speech-to-text) app for macOS. It listens to any audio playing on your Mac
— videos, calls, podcasts — and shows live captions in a floating overlay, with optional real-time
translation shown as subtitles. Everything runs locally with Apple's speech recognition and translation;
no audio leaves your Mac.

## Features

- System audio capture via Core Audio process tap — no screen recording permission needed
- On-device speech recognition (`SpeechAnalyzer`) with sentence-by-sentence line breaks
- On-device translation (`Translation` framework): original, original + translation, or translation only
- Always-on-top, click-through overlay with hover scrollback, drag-to-move, edge resize, auto-hide
- Menu bar control; UI in English, Korean, Japanese, Spanish, French, German

## Requirements

macOS 26 or later. Xcode 26 or later (Swift 6) to build.

## Build & Run

```sh
./scripts/make-dev-cert.sh   # once: local signing certificate
make run                      # build → build/Textize.app → open
```

On first launch, allow **System Audio Recording** when prompted. Always launch with `open` (or `make run`),
not by running the binary directly, or macOS grants the permission to your terminal instead.

## License

The source code is licensed under the [MIT License](LICENSE).

The app icon (`Resources/Textize.icns`) is **not** covered by the MIT License. It is included in this
repository only so that local builds have the proper icon. All rights to the icon are reserved; do not
use it in other projects or redistributed builds. The build works without it (a default icon is used).
