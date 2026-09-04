# Contributing

Thanks for helping improve Photo Duplicate Cleaner.

## Before opening a change

- Search existing issues before filing a new one.
- For behavior changes, open an issue first so the safety and user-experience tradeoffs can be discussed.
- Never attach a Photos library, exported journal, or screenshot containing private media or location data to a public issue.

## Development setup

You need macOS 14 or later and a current Xcode or Command Line Tools installation.

```sh
swift test
Scripts/build-app.sh debug
```

Open `dist/Photo Duplicate Cleaner.app` to exercise PhotoKit behavior. Use a backed-up test library or test album rather than your primary library.

## Pull requests

- Keep changes focused and explain their user-visible effect.
- Add or update tests for matching, merge planning, persistence, and cleanup-safety behavior.
- Run `swift test` and `git diff --check` before submitting.
- Avoid weakening explicit confirmation, stale-library detection, journaling, or conflict handling without a documented rationale.
- Confirm that no personal photos, journals, local paths, credentials, build products, or `.DS_Store` files are included.

By contributing, you agree that your contribution is licensed under the MIT License.
