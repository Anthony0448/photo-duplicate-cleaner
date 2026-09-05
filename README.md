# Photo Duplicate Cleaner

Photo Duplicate Cleaner is a free, open-source macOS app for reviewing duplicate media in the System Photo Library, preserving the keeper's best metadata, and moving only explicitly approved copies to Photos' **Recently Deleted** area.

The app runs locally. It has no analytics, advertising, account system, or developer-operated network service.

> [!CAUTION]
> This software changes your Photos library. Back up the library before cleanup, begin with a small test album, and verify Recently Deleted and every synced device before permanently deleting anything. The software is provided without warranty.

## Features

- Finds byte-identical media and conservative likely-visual matches.
- Scans the whole library, chosen albums, or one month at a time.
- Scans month by month so a very large library can be worked through in batches, stopped after any month, and resumed later.
- Reports real progress for each phase, can be paused or cancelled at any point, and reuses fingerprints already computed.
- Uses duration, aspect ratio, and sampled frames to avoid grouping unrelated videos.
- Requires an explicit keeper and explicit deletion choices.
- Stops for conflicts involving dates, locations, captions, ratings, hidden states, formats, and edits.
- Unions favorites, keywords, and writable user-album membership onto the keeper.
- Provides large photo previews and video playback before cleanup.
- Writes a metadata journal before every cleanup transaction.
- Restores scan results and review choices between launches.
- Detects Photos library changes, marks results stale, and requires a rescan before cleanup.

## Safety model and limitations

- Scanning and fingerprinting are read-only.
- All library access uses Apple's PhotoKit framework; the app never opens or edits the private `.photoslibrary` database.
- Exact and likely-visual matches are displayed separately. Likely matches always require review.
- Choosing a keeper initially marks every other copy for deletion; switch any copy you want to retain back to **Keep**.
- Likely-matching videos must have compatible durations and aspect ratios as well as matching sampled frames. The full duration span is checked again before a video group is shown.
- If location exists on only some copies, cleanup pauses for an explicit choice so missing GPS metadata is not silently overlooked.
- A journal records metadata and identifiers, not copies of the media files.
- Deleted media must be restored in Photos before Apple permanently removes it. The app can restore journaled keeper metadata, but it cannot restore permanently deleted photo or video data.
- Shared/synced-library sources, faces, Memories, Google Takeout JSON sidecars, and permanent deletion are outside the app's scope.

See [PRIVACY.md](PRIVACY.md) for the local data the app retains.

## Requirements

- macOS 14 or later.
- Xcode or Command Line Tools with Swift 6.0 or later.
- Full Photos read/write permission when prompted.
- Enough local space for any originals that Photos downloads from iCloud on demand.

macOS 27 and its SDK enable captions, keywords, ratings, added dates, and newer resource metadata. Builds made with an older SDK retain stable date, location, favorite, hidden-state, and album cleanup behavior.

## Build and run

There is currently no notarized binary release. Clone or download this repository, then build the app from its root directory:

```sh
Scripts/build-app.sh
open "dist/Photo Duplicate Cleaner.app"
```

The script builds a release binary, assembles `dist/Photo Duplicate Cleaner.app`, and ad-hoc signs it. A paid Apple Developer account is not required for a local build.

The Photo Library privacy prompt requires an application bundle with an `Info.plist`; do not use `swift run` for real-library access.

Run the test suite with:

```sh
swift test
```

If Swift reports that the SDK is not supported by the compiler, update or reinstall Xcode/Command Line Tools and make sure `xcode-select` points to that installation. The compiler and SDK must come from a matching toolchain.

## Workflow

1. Open the app and grant full Photos read/write access.
2. Choose a scope: the whole library, writable albums, or **Months**.
3. Wait while thumbnails are fingerprinted and only candidate originals are hashed.
4. Click a photo or video preview, or focus its card and press Space, to inspect it at a large size. Choose the keeper and explicitly review every deletion choice.
5. Resolve the metadata choices in **Metadata to preserve**, choose **Add to Cleanup Batch**, and inspect the thumbnail-based keep/delete comparison.
6. Confirm cleanup, verify the keepers and Recently Deleted in Photos, and export the JSON/CSV journal if desired.

If Photos changes after a scan, whether while the app is open or between launches, the app preserves the existing review, marks it stale, and offers a fresh scan. Choosing **Later** avoids repeated prompts for that stale scan, but cleanup remains disabled until verification succeeds.

## Scanning very large libraries

A whole-library scan compares every asset against every other, which is what finds copies filed under different dates. That comparison has to hold the whole library's fingerprints at once, so on libraries of a few hundred thousand items it is slow and memory-hungry even though it is interruptible.

**Months** exists for that case. The app reads a capture-date histogram of the library, you pick the months to cover, and each month is scanned as its own batch. Progress names the batch being compared, groups appear as each month finishes, and the scan can be stopped and resumed from the next unscanned month. Because each batch is self-contained, month batches only find copies that share a capture month; copies filed under different months need a whole-library scan.

Fingerprints and original hashes are cached across scans, so rescanning after adding a few photos only does work for what changed. Assets Photos cannot produce, usually ones still downloading from iCloud, are skipped and reported instead of failing the scan.

## Contributing and security

Bug reports and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before contributing. Do not post private photos, filenames, asset identifiers, locations, or exported journals in an issue.

Report vulnerabilities according to [SECURITY.md](SECURITY.md), especially anything that could expose library metadata, bypass confirmation, or cause data loss.

## License

Photo Duplicate Cleaner is available under the [MIT License](LICENSE).
