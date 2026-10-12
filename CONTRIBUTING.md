# Contributing

Bug reports, ideas, and pull requests are welcome.

- **Bugs:** open an [issue](https://github.com/mason50x/murmur/issues/new/choose) with your macOS
  version, Mac, Murmur version (Settings › Updates) and speech model. Relevant lines from
  `~/Library/Logs/Murmur.log` help a lot; the log never contains what you said.
- **Security issues:** report them privately, as described in [SECURITY.md](SECURITY.md).
- **Code:** `make` builds, installs, and opens a development copy; `make test` runs the tests.
  Match the style of the code around your change, keep commits focused, and describe how you
  tested it. Commit subjects become release notes, so write them for users ("Fix pasting into
  Slack"), or start them with `internal:` for changes users won't notice. UI changes are easiest
  to review with before/after images from `Murmur --render-ui`.

Murmur's promises to its users are part of the code review: transcription stays on the device,
nothing is collected or uploaded, and transcript text is never written to logs.
