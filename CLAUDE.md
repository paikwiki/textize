# Textize Development Notes

A macOS 26 app that captures the audio playing on the Mac, runs it through Apple's on-device speech recognition, and shows the result as overlay captions.
Uses only macOS frameworks; no external models or servers. The microphone is never used. Bundle ID is `wiki.paik.textize`.
Build and run instructions are in the README; each file's role and pitfalls are in the comment at the top of the source.

## Run & Test

```sh
./scripts/restart-app.sh      # Quit gracefully, then relaunch. Never pkill (the tap and aggregate device must be torn down cleanly)
/usr/bin/log stream --level info --predicate 'subsystem == "wiki.paik.textize"' --style compact   # Use the full path; zsh has a builtin `log` that shadows it
say -v Yuna "안녕하세요. 자막 테스트입니다."   # If captions appear, it works
```

Unit tests live in `Tests/TextizeTests` (Swift Testing, `make test`). They cover the pure logic only: `CaptionModel`, `SentenceSplitter`, `Settings`, `MenuState`, and the string catalog (every `L()` key present in all 6 languages, no dead keys). Audio capture, recognition, translation and the overlay are verified by hand.

## Permissions (System Audio Recording)

- Never run the binary directly from the terminal. The permission gets attached to the terminal. Always use `open build/Textize.app`.
- Ad-hoc signing resets the permission on every build. Always sign with the `Textize Dev` certificate (`scripts/make-dev-cert.sh`; the build script uses it automatically).
- Changing the .app name or bundle ID triggers the permission prompt again. Reset: `tccutil reset AudioCapture wiki.paik.textize`
- The "System Settings > …" path names in the permission guidance text are taken verbatim from macOS 26 system resources. Do not change them.

## Rules

- The menu bar menu must not observe the caption model directly (`MenuState`). If it does, the menu is rebuilt on every caption update and any open submenu closes.
- Look up UI strings only via `L("…")` and put all 6 languages (en·ko·ja·es·fr·de) in `Localizable.xcstrings` (include English explicitly so that en.lproj is generated).
  Adding a language is just adding it to the catalog and adding a case to `AppLanguage`. A run without `.lproj` (`swift run`) shows English only.
- Write logs in English and never put caption text or translations in logs (lengths only).
- Pre-translation: if speech does not pause, final results may not arrive for tens of seconds. So completed sentences among the volatile ones are translated ahead of time and shown dimmed; on finalization, if the sentence is identical, the translation is carried over as is.
- Terminology: captions = same-language text, subtitles = translated text. The menu says Captions because recognition is the default behavior.
- App Store subtitle `Live captions & translation`, keywords `STT,speech to text,live captions,subtitles,transcription,translation,caption,overlay,accessibility`.

## Next Up

Saving caption history, keyboard shortcuts, display duration control, capturing only a specific app's audio. Forced sentence splitting during fast speech is on hold.
