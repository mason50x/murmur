# Security

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub's private reporting](https://github.com/mason50x/murmur/security/advisories/new)
rather than a public issue. You'll get a reply within a few days, and a fix will ship as an
update that installed copies pick up automatically. Only the latest release is supported.

## How Murmur is built to be trusted

Murmur has the microphone and Accessibility access, so it's worth being precise about what protects
those permissions.

### Distribution

Murmur isn't notarized by Apple. In its place:

- **A stable release certificate.** Every release is signed with the same self-signed "Murmur
  Release" certificate (SHA-1 `3FBEE017D470E6A1C121D2CDEE9C8CFC4CD2B8A8`). The
  [installer](install.sh) refuses an app signed with anything else, and macOS ties your permission
  grants to this signature, so a differently signed copy wouldn't inherit them.
- **The installer** downloads over HTTPS from GitHub Releases, checks the SHA-256 against the
  release's `SHA256SUMS`, verifies the code signature and the pinned certificate, and only then
  removes the quarantine flag. The checksum mostly catches corrupt downloads, since it ships next to
  the zip; the certificate check is what proves who built it. You can check by hand:

  ```sh
  codesign --verify -R '=identifier "com.mason.murmur" and certificate leaf = H"3FBEE017D470E6A1C121D2CDEE9C8CFC4CD2B8A8"' /Applications/Murmur.app
  ```

- `curl | bash` trusts GitHub and this repository at the moment you run it. If you'd rather not,
  download `install.sh`, read it, then run it.

### Updates

[Sparkle 2](https://sparkle-project.org) installs updates. Each update archive is signed with an
Ed25519 key (public key `dmw84SmvS6gRcI9vwOqZpTmpbnXK58Souyph/oE0+Oc=`, in `Info.plist`), and the
appcast feed is signed too (`SURequireSignedFeed`). The app verifies the archive before extracting
it (`SUVerifyUpdateBeforeExtraction`) and ignores unsigned or tampered feeds. The feed and
archives come over HTTPS from GitHub Releases.

### Release keys and builds

The certificate's private key and the Sparkle key are stored in the maintainer's 1Password and as
encrypted secrets of a GitHub `production` environment that only the `main` branch can use.
Releases are built on GitHub's ephemeral macOS runners by the Release workflow, which only the
maintainer can start. It loads the keys into a temporary keychain and checks them against the
certificate pinned in the installer and the public key in the app before signing anything.
Release tags can't be moved or deleted, and published releases are immutable, so an asset can't
be swapped after the fact.

### The app

- **Hardened runtime** is on: no `DYLD_*` library injection, no debugger attach, no unsigned
  executable memory. Two entitlements relax it:
  - `com.apple.security.device.audio-input`, to use the microphone.
  - `com.apple.security.cs.disable-library-validation`. Library validation only accepts
    frameworks signed by the same Apple Team ID, and a self-signed certificate has none, so it
    would reject the bundled `Sparkle.framework`. To keep that from becoming a way in, Murmur
    doesn't link Sparkle: it loads the framework at runtime only after checking that its signature,
    including everything nested inside it, comes from the same certificate as Murmur itself. A
    swapped-in framework is never loaded; updates are just turned off and Settings says so. Murmur
    links no other non-system libraries.
- **Not sandboxed.** Pasting into other apps and reading the text around the cursor require
  Accessibility APIs that the App Sandbox doesn't allow.
- **Release builds ignore `murmur://` links.** The development hooks, including ones that record
  the microphone or read audio files (`mictest`, `simulate`), are compiled only into local
  `scripts/build.sh` builds.
- **Accessibility use** is limited to: watching for the right Option key and Esc, reading the
  focused field's text around the caret to fit punctuation and casing, and posting ⌘V to paste.
  Nothing it reads is logged or stored.
- **Clipboard:** pasting briefly puts the transcript on the clipboard, marked
  `org.nspasteboard.TransientType` so clipboard managers skip it, then restores what was there.

### Data on disk

| What | Where | Notes |
|---|---|---|
| Transcript history (last 50) | `~/Library/Application Support/Murmur/history.json` | Mode 0600. Can be turned off or cleared in Settings. |
| Log | `~/Library/Logs/Murmur.log` | Events and character counts, never transcript text. Mode 0600, rotated at 2 MB. |
| Last recording | `~/Library/Logs/Murmur-last.wav` | Only if you turn on troubleshooting in Settings; deleted when you turn it off. |
| Speech models | `~/Library/Application Support/FluidAudio/Models/` | Downloaded once from Hugging Face. |

### Dependencies

- [FluidAudio](https://github.com/FluidInference/FluidAudio) is pinned by Swift Package Manager
  (`Package.resolved`) and watched by Dependabot.
- Sparkle is downloaded by `scripts/sparkle.sh` from its GitHub release and checked against a
  pinned SHA-256 (the checksum Sparkle publishes in its own `Package.swift`) before it's used.

### Speech models

Models download over HTTPS from the [FluidInference](https://huggingface.co/FluidInference)
repositories on Hugging Face through FluidAudio. They're Core ML models (weights and a compute
graph, not executable code), but they aren't pinned to a specific commit, so you're trusting those
repositories. No audio or text is ever uploaded.
