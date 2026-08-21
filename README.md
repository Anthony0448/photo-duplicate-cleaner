# Photo Duplicate Cleaner

A local macOS app for reviewing duplicate media in the System Photo Library, preserving the keeper's best metadata, and moving only explicitly approved copies to Photos' **Recently Deleted** area.

## Safety model

- Scanning and fingerprinting are read-only.
- The app never opens or edits the private `.photoslibrary` database; all access goes through Apple's PhotoKit framework.
- Exact and likely-visual matches are shown separately. Likely matches are never approved automatically.
- Conflicting dates, locations, captions, ratings, hidden states, formats, and edits block cleanup until you choose a value.
- Favorites, keywords, and writable user-album membership are unioned onto the keeper.
- A journal is written before every cleanup transaction. It records metadata and identifiers, not media files.
- Deleted media must be restored in Photos before Apple permanently removes it. The app can restore journaled keeper metadata, but it cannot restore permanently deleted image/video data.

Back up the Photos library before the first large cleanup. Start with a small test album and inspect its results on every synced device.

## Requirements

- macOS 14 or later; macOS 27 enables captions, keywords, ratings, added dates, and newer resource metadata.
- A matching Swift compiler and macOS SDK from current Command Line Tools or Xcode.
- iCloud Photos originals may be downloaded on demand for candidate verification. The app itself has no network service, analytics, or account system.

The currently installed command-line compiler and SDK on this Mac report different build versions. Update Command Line Tools before building, then confirm `swift --version` succeeds against the active SDK. Until then, the build script falls back to the installed macOS 26.5 SDK; that build retains stable date/location/favorite/hidden/album cleanup but disables macOS 27-only extended fields.

## Build and run

The Photo Library privacy prompt requires an application bundle with an `Info.plist`; do not use `swift run` for real-library access.

```sh
chmod +x Scripts/build-app.sh
Scripts/build-app.sh
open "dist/Photo Duplicate Cleaner.app"
```

The script builds a release binary, assembles `dist/Photo Duplicate Cleaner.app`, and ad-hoc signs it. No Apple Developer account is required for personal use on this Mac.

To run unit tests:

```sh
swift test
```

On this Mac's currently mismatched toolchain, use `Scripts/test-current-toolchain.sh`; it selects the compatible SDK and installed Testing runtime explicitly.

## Workflow

1. Open the app and grant full Photos read/write access.
2. Scan the personal library or select writable albums.
3. Wait while thumbnails are fingerprinted and only candidate originals are hashed.
4. Review the recommended keeper in every group. Resolve all highlighted conflicts.
5. Include reviewed groups in a batch, inspect the final summary, and confirm.
6. Verify keepers and Recently Deleted in Photos, then export the JSON/CSV journal.

The app excludes shared/synced-library sources, faces, Memories, Google Takeout JSON sidecars, and permanent deletion.
