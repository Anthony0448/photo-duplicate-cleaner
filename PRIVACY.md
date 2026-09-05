# Privacy

Photo Duplicate Cleaner is a local macOS application. It has no analytics, advertising, account system, telemetry, or developer-operated network service.

## Photos access

The app requests read/write access to the System Photo Library through Apple's PhotoKit framework. It uses that access to compare media and metadata, update a selected keeper, and move only explicitly approved copies to Recently Deleted. It does not open or modify the private Photos database directly.

If an original is stored in iCloud, PhotoKit may ask Photos to download it. That transfer is handled by Apple and the user's iCloud Photos configuration, not by a service operated by this project.

## Local data

The app stores its fingerprint cache, saved review session, and cleanup journal in:

```text
~/Library/Application Support/PhotoDuplicateCleaner/
```

These files can contain Photos asset identifiers, original filenames, dates, location coordinates, album names, fingerprints, review choices, and cleanup results. They do not contain copies of the photo or video data. Anyone with access to the user's macOS account or backups may be able to read this metadata.

Journal exports are written only to a location selected by the user. Exported JSON and CSV files can contain the same sensitive metadata and should be shared carefully.

## Removing local data

Quit the app, then delete the `PhotoDuplicateCleaner` folder shown above to remove its cache, saved review, and journal. Files left by earlier versions are removed automatically on launch. This does not change the Photos library and cannot restore items already moved to Recently Deleted.
