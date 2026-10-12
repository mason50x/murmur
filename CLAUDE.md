# Murmur

Push-to-talk dictation for macOS (Swift, SwiftPM, no Xcode project). Hold right ⌥, talk, let go:
FluidAudio runs NVIDIA Parakeet on the Neural Engine and the text is pasted where the cursor is.
Menu bar app (`LSUIElement`), macOS 26+, Apple silicon only. See README.md for the user-facing
story and SECURITY.md for the trust model.

## Commands

| | |
|---|---|
| `make` | Build a development copy, install it over the user's Murmur, and open it |
| `make app` | Build and sign `build/Murmur.app` only |
| `make test` | Unit tests (Swift Testing, `Tests/MurmurTests`) |
| `make release` | Ship everything since the last release via GitHub Actions. `BUMP=minor`, `major` or `X.Y.Z` |
| `make release-dry-run` | Build and sign a release locally into `dist/` (keys from 1Password); publishes nothing |

Check a change in the real app with the development hooks (`make` builds include them; release
builds don't): `open -g "murmur://preview?state=result"`, `murmur://simulate?path=/abs/file.wav`,
`murmur://onboarding`, and `build/Murmur.app/Contents/MacOS/Murmur --render-ui <dir>` to render
onboarding, Settings and notch states to PNGs. Log: `~/Library/Logs/Murmur.log`.

## Rules that are part of the product

- Transcription stays on the device. The only network traffic is the model download (Hugging
  Face) and update checks (GitHub). Don't add analytics, crash reporting, or any other upload.
- Never log or persist transcript text, except history.json, which the user can turn off.
- Debug hooks that record, read files or show UI go inside `#if MURMUR_DEBUG_HOOKS`.
- Don't link Sparkle; `Updater.swift` loads it only after verifying its signature (SECURITY.md).

## Commits and release notes

Commit straight to `main`. Commit subjects become release notes, so write them for users,
in the imperative: "Fix pasting into Slack", "Add a hands-free indicator". Start the subject with
`internal:` or `chore:` for changes users shouldn't read about (refactors, scripts, docs). To
hand-write the notes instead, add them under a `## Unreleased` heading at the top of
CHANGELOG.md; the release uses that section in place of the commit list.

## Releasing

Only when the user asks to release or ship. Commit and push the work, then run `make release`
with the bump that fits everything since the last tag:

- `patch` (default): fixes and small improvements
- `BUMP=minor`: new features or settings
- `BUMP=major`: changes to how people use Murmur, or dropping support for something

It starts the Release workflow (`.github/workflows/release.yml`) on GitHub and waits for it. The
workflow writes the CHANGELOG section, commits "Release X.Y.Z" to main, signs with the keys in the
`production` environment, tags, and publishes the GitHub release; installed copies update through
Sparkle within a day. Afterwards `make release` pulls that release commit. If it fails, it prints
the failing log: fix the cause, push, and run it again. Nothing is tagged or published until
signing succeeds.

This is the only CI. Don't add workflows that run on push or pull requests.

Don't touch the release keys: never create, rotate or export them, never write them to disk or
the repo, and never change `SUPublicEDKey` in Info.plist or `CERT_SHA1` in install.sh. Release
tags and published releases are immutable; to fix a bad release, ship the next patch.
