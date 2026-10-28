# Contributing

## Requirements

- macOS 14 or later, Apple Silicon.
- Xcode 16 / Swift 6 toolchain.

## Build and test

```sh
swift test
./scripts/build-app.sh dist --mode local
./scripts/validate-app.sh dist/AIUsageIsland.app local
```

Release signing and notarization require a Developer ID Application identity and a configured notary profile; see [docs/updates-publishing.md](docs/updates-publishing.md).

## Pull requests

- Keep changes focused and include tests for behavior changes.
- Do not commit tokens, cookies, account data, Bark URLs, personal screenshots, or generated build artifacts.
- By contributing, you agree that your contributions are licensed under the project's [MIT License](LICENSE).
