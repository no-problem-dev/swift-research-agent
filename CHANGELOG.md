# Changelog

## [Unreleased]

## [0.3.0] - 2026-08-11

### Changed

- Raised the swift-agent-runtime pin to 0.20.0 and the swift-http-transport pin to 2.1.0.


## [0.2.0] - 2026-08-11

### Fixed

- **The citation gate never checked the final attempt.** Validation was
  `attempt < maxRetries ? validate : []`, so the last answer went out unchecked and
  `maxRetries: 0` disabled the gate entirely — in the package whose whole purpose is stopping an
  agent citing pages it never opened. Every attempt is validated now, and a spent budget fails the
  task carrying the violations and the rejected text rather than completing.
- **A successful fetch whose URL failed normalization was not recorded**, so the gate then blamed
  the model for a ledger gap the registry had caused.
- **`.isoLatin1` never fails, so the Shift_JIS and EUC-JP branches below it were dead.** A Japanese
  page was stored as mojibake and became citable "verified content". Decoding tries UTF-8, then a
  Japanese decode scored by Japanese-script run length, and the byte-accepting encodings strictly
  last.
- `RateLimiter.acquire()` swallowed the cancellation thrown by `Task.sleep` and proceeded
  unthrottled — the caller cancelled and the work continued.


## [0.1.2] - 2026-07-19

See [GitHub Releases](../../releases) for changes up to and including this version.
