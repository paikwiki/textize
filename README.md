# Textize

**Live captions & translation for your Mac**

Textize is a macOS app that turns the audio your Mac is playing into live captions. It shows them in a
floating window above other apps and can translate them into subtitles as they appear. Speech recognition
and translation use the frameworks built into macOS, and the app does not send audio or text anywhere.

Website, support and privacy policy: https://paikwiki.github.io/textize/

## Features

- Captures system audio with a Core Audio process tap, which needs the System Audio Recording permission and nothing else.
- Recognizes speech on device with `SpeechAnalyzer` and breaks the text into one line per sentence.
- Translates on device with the `Translation` framework. Display modes are original, original with translation, and translation only.
- The caption window stays above other windows and passes clicks through. You can move it with the move button at its top, resize it from the edges, scroll back through earlier lines from its right edge, and let it hide itself after a quiet period.
- Controlled from the menu bar. The interface is available in English, Korean, Japanese, Spanish, French and German.

## Requirements

macOS 26 or later. Building needs Xcode 26 or later.

## Build & Run

```sh
./scripts/make-dev-cert.sh   # once: local signing certificate
make run                      # build → build/Textize.app → open
make test                     # unit tests (swift test)
```

On first launch, allow System Audio Recording when macOS asks. Launch the app with `open` or `make run`.
If you run the binary directly from a terminal, macOS grants the permission to the terminal instead of to Textize.

## Release

`make release` builds a notarized `dist/Textize-<version>.dmg`. It needs a Developer ID Application certificate in the keychain and notarization credentials stored once with `xcrun notarytool store-credentials textize-notary`. The script signs the app with the hardened runtime, notarizes and staples the app, then wraps it in a DMG and notarizes that too. See the comment at the top of `scripts/release.sh`.

## Website

The `docs/` folder is the project website, served by GitHub Pages from the `main` branch. It is plain HTML
with no build step; edit the files and push.

## License

The source code is licensed under the [MIT License](LICENSE).

The app icon (`Resources/Textize.icns`) is not covered by the MIT License. It is included in this repository
so that local builds have the proper icon. All rights to the icon are reserved; do not use it in other
projects or in builds you redistribute. The build works without it and falls back to the default icon.
