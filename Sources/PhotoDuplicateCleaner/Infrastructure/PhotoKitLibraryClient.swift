import AppKit
import AVFoundation
import CoreLocation
import CryptoKit
import Foundation
import Photos
import UniformTypeIdentifiers

final class PhotoKitLibraryClient: PhotoLibraryClient, ResourceLoader, CleanupApplier {
    private let library = PHPhotoLibrary.shared()
    private let imageManager = PHCachingImageManager()
    private let resourceManager = PHAssetResourceManager.default()

    func authorizationStatus() -> PhotoLibraryAccess {
        Self.mapAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotoLibraryAccess {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: Self.mapAuthorization(status))
            }
        }
    }

    func fetchAlbums() async throws -> [AlbumReference] {
        try requireAuthorization()
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var albums: [AlbumReference] = []
        result.enumerateObjects { collection, _, _ in
            guard collection.assetCollectionSubtype != .albumCloudShared else { return }
            albums.append(.init(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Untitled album",
                canAddContent: collection.canPerform(.addContent)
            ))
        }
        return albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func fetchAssets(scope: ScanScope) async throws -> [AssetSnapshot] {
        try requireAuthorization()
        let albums = try await fetchAlbums()
        let membership = albumMembership(albums: albums)
        let fetchOptions = PHFetchOptions()
        fetchOptions.includeAssetSourceTypes = [.typeUserLibrary]
#if PHOTO_EXTENDED_METADATA
        if #available(macOS 27.0, *) { fetchOptions.prefetchAssetExtendedMetadata = true }
#endif

        var fetched: [PHAsset] = []
        if scope.kind == .entireLibrary {
            PHAsset.fetchAssets(with: fetchOptions).enumerateObjects { asset, _, _ in fetched.append(asset) }
        } else {
            var seen = Set<String>()
            let selected = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: Array(scope.albumIDs), options: nil)
            selected.enumerateObjects { collection, _, _ in
                PHAsset.fetchAssets(in: collection, options: fetchOptions).enumerateObjects { asset, _, _ in
                    if seen.insert(asset.localIdentifier).inserted { fetched.append(asset) }
                }
            }
        }

        return fetched.compactMap { asset in
            guard asset.sourceType.contains(.typeUserLibrary), asset.mediaType == .image || asset.mediaType == .video else { return nil }
            return snapshot(asset: asset, albums: membership[asset.localIdentifier] ?? [])
        }
    }

    func thumbnail(assetID: String, targetSize: CGSize) async throws -> NSImage {
        try requireAuthorization()
        guard let asset = fetchAsset(assetID) else { throw CleanerError.assetUnavailable(assetID) }
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.version = .current
            options.isNetworkAccessAllowed = true
            options.progressHandler = { _, error, _, _ in
                if let error { /* Completion reports the definitive result. */ _ = error }
            }
            imageManager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options) { image, info in
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    continuation.resume(throwing: CleanerError.cancelled)
                } else if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: CleanerError.assetUnavailable(assetID))
                }
            }
        }
    }

    func videoFrames(assetID: String) async throws -> [NSImage] {
        try requireAuthorization()
        guard let asset = fetchAsset(assetID), asset.mediaType == .video else {
            throw CleanerError.assetUnavailable(assetID)
        }
        let avAsset: AVAsset = try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = .current
            options.isNetworkAccessAllowed = true
            imageManager.requestAVAsset(forVideo: asset, options: options) { value, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else if let value {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(throwing: CleanerError.assetUnavailable(assetID))
                }
            }
        }
        let loadedDuration = try await avAsset.load(.duration)
        return try await Task.detached(priority: .utility) {
            let generator = AVAssetImageGenerator(asset: avAsset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let duration = CMTimeGetSeconds(loadedDuration)
            return try [0.1, 0.5, 0.9].map { fraction in
                let time = CMTime(seconds: max(0, duration * fraction), preferredTimescale: 600)
                let image = try generator.copyCGImage(at: time, actualTime: nil)
                return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        }.value
    }

    func updateOriginalHashes(for asset: AssetSnapshot) async throws -> AssetSnapshot {
        try requireAuthorization()
        guard let phAsset = fetchAsset(asset.id) else { throw CleanerError.assetUnavailable(asset.id) }
        let resources = PHAssetResource.assetResources(for: phAsset)
        var updated = asset
        for index in updated.resources.indices where updated.resources[index].kind.isOriginalBearing {
            let key = updated.resources[index].key
            guard let resource = resources.enumerated().first(where: { resourceKey($0.element, index: $0.offset) == key })?.element else {
                throw CleanerError.assetUnavailable("\(asset.id)/\(key)")
            }
            let result = try await hash(resource: resource)
            updated.resources[index].sha256 = result.digest
            updated.resources[index].byteCount = result.byteCount
        }
        return updated
    }

    func apply(proposals: [MergeProposal]) async throws {
        try requireAuthorization()
        guard !proposals.isEmpty, proposals.allSatisfy(\.canApply) else {
            throw CleanerError.invalidProposal("Every item must be approved and conflict-free.")
        }

        let allSnapshots = proposals.flatMap { [$0.keeper] + $0.donors }
        let ids = allSnapshots.map(\.id)
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assetsByID: [String: PHAsset] = [:]
        fetchResult.enumerateObjects { asset, _, _ in assetsByID[asset.localIdentifier] = asset }
        guard assetsByID.count == Set(ids).count else { throw CleanerError.assetUnavailable("One or more selected assets") }

        for snapshot in allSnapshots {
            guard let current = assetsByID[snapshot.id] else { throw CleanerError.assetUnavailable(snapshot.id) }
            if let scanned = snapshot.modificationDate, let now = current.modificationDate,
               abs(scanned.timeIntervalSince(now)) > 0.001 {
                throw CleanerError.staleAsset(snapshot.id)
            }
        }

        let albumIDs = Array(Set(proposals.flatMap { $0.albumsToAdd.map(\.id) }))
        let albumFetch = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: albumIDs, options: nil)
        var albumsByID: [String: PHAssetCollection] = [:]
        albumFetch.enumerateObjects { album, _, _ in albumsByID[album.localIdentifier] = album }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            library.performChanges {
                for proposal in proposals {
                    guard let keeper = assetsByID[proposal.keeper.id] else { continue }
                    let request = PHAssetChangeRequest(for: keeper)
                    request.creationDate = proposal.proposedCreationDate
                    request.location = proposal.proposedLocation.map(Self.location)
                    request.isFavorite = proposal.proposedFavorite
                    request.isHidden = proposal.proposedHidden
#if PHOTO_EXTENDED_METADATA
                    if #available(macOS 27.0, *) {
                        request.caption = proposal.proposedCaption
                        if let rating = proposal.proposedRating, let value = PHAsset.Rating(rawValue: rating) {
                            request.rating = value
                        }
                        let existing = Set(proposal.keeper.keywords)
                        for keyword in proposal.proposedKeywords where !existing.contains(keyword) { request.addKeyword(keyword) }
                    }
#endif
                    for album in proposal.albumsToAdd {
                        guard let collection = albumsByID[album.id],
                              let collectionRequest = PHAssetCollectionChangeRequest(for: collection) else { continue }
                        collectionRequest.addAssets([keeper] as NSArray)
                    }
                    let donors = proposal.donors.compactMap { assetsByID[$0.id] }
                    PHAssetChangeRequest.deleteAssets(donors as NSArray)
                }
            } completionHandler: { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? CleanerError.invalidProposal("Photos rejected the change transaction.")) }
            }
        }
    }

    func restoreKeeperMetadata(from entries: [CleanupJournalEntry]) async throws {
        try requireAuthorization()
        let snapshots = entries.filter { $0.status == .succeeded }.map { $0.proposal.keeper }
        guard !snapshots.isEmpty else { return }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: snapshots.map(\.id), options: nil)
        var byID: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            library.performChanges {
                for snapshot in snapshots {
                    guard let asset = byID[snapshot.id] else { continue }
                    let request = PHAssetChangeRequest(for: asset)
                    request.creationDate = snapshot.creationDate
                    request.location = snapshot.location.map(Self.location)
                    request.isFavorite = snapshot.isFavorite
                    request.isHidden = snapshot.isHidden
#if PHOTO_EXTENDED_METADATA
                    if #available(macOS 27.0, *) {
                        request.caption = snapshot.caption
                        if let rating = snapshot.rating, let value = PHAsset.Rating(rawValue: rating) { request.rating = value }
                    }
#endif
                }
            } completionHandler: { success, error in
                success ? continuation.resume() : continuation.resume(throwing: error ?? CleanerError.persistence("Photos rejected metadata restoration."))
            }
        }
    }

    private func snapshot(asset: PHAsset, albums: [AlbumReference]) -> AssetSnapshot {
        let resources = PHAssetResource.assetResources(for: asset)
        let manifests = resources.enumerated().map { index, resource in
            ResourceManifest(
                key: resourceKey(resource, index: index),
                kind: Self.resourceKind(resource.type),
                filename: Self.resourceFilename(resource),
                uniformTypeIdentifier: Self.resourceUTI(resource),
                pixelWidth: resource.pixelWidth,
                pixelHeight: resource.pixelHeight,
                byteCount: Self.resourceSize(resource),
                sha256: nil
            )
        }
        let extended: (String?, [String], Int?)
#if PHOTO_EXTENDED_METADATA
        if #available(macOS 27.0, *) {
            extended = (asset.extendedMetadata.caption, asset.extendedMetadata.keywords, asset.rating.rawValue)
        } else {
            extended = (nil, [], nil)
        }
#else
        extended = (nil, [], nil)
#endif
        let originalFilename: String
#if PHOTO_EXTENDED_METADATA
        if #available(macOS 27.0, *), let filename = asset.extendedMetadata.originalFilename {
            originalFilename = filename
        } else {
            originalFilename = resources.first?.originalFilename ?? "Untitled"
        }
#else
        originalFilename = resources.first?.originalFilename ?? "Untitled"
#endif
        let contentType: String
        if #available(macOS 26.0, *) { contentType = asset.contentType.identifier }
        else { contentType = resources.first?.uniformTypeIdentifier ?? "public.data" }
        let addedDate: Date?
        if #available(macOS 26.0, *) { addedDate = asset.addedDate }
        else { addedDate = nil }
        let isRaw = manifests.contains { manifest in
            manifest.uniformTypeIdentifier.localizedCaseInsensitiveContains("raw")
                || ["dng", "cr2", "cr3", "nef", "arw", "raf"].contains((manifest.filename as NSString).pathExtension.lowercased())
        }
        return AssetSnapshot(
            id: asset.localIdentifier,
            mediaKind: asset.mediaType == .video ? .video : .image,
            originalFilename: originalFilename,
            contentType: contentType,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            creationDate: asset.creationDate,
            addedDate: addedDate,
            modificationDate: asset.modificationDate,
            location: asset.location.map { .init(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, horizontalAccuracy: $0.horizontalAccuracy) },
            isFavorite: asset.isFavorite,
            isHidden: asset.isHidden,
            caption: extended.0,
            keywords: extended.1,
            rating: extended.2,
            hasAdjustments: asset.hasAdjustments,
            adjustmentIdentifier: asset.adjustmentFormatIdentifier,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            isRAW: isRaw,
            albums: albums,
            resources: manifests,
            fingerprint: nil
        )
    }

    private func albumMembership(albums: [AlbumReference]) -> [String: [AlbumReference]] {
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: albums.map(\.id), options: nil)
        let albumsByID = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        var membership: [String: [AlbumReference]] = [:]
        collections.enumerateObjects { collection, _, _ in
            guard let reference = albumsByID[collection.localIdentifier] else { return }
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                membership[asset.localIdentifier, default: []].append(reference)
            }
        }
        return membership
    }

    private func fetchAsset(_ id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    private func requireAuthorization() throws {
        switch authorizationStatus() {
        case .authorized: return
        case .limited: throw CleanerError.limitedAccessUnsupported
        default: throw CleanerError.photoAccessRequired
        }
    }

    private func hash(resource: PHAssetResource) async throws -> (digest: String, byteCount: Int64) {
        let accumulator = DigestAccumulator()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        return try await withCheckedThrowingContinuation { continuation in
            resourceManager.requestData(for: resource, options: options) { data in
                accumulator.update(data)
            } completionHandler: { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: accumulator.finish()) }
            }
        }
    }

    private func resourceKey(_ resource: PHAssetResource, index: Int) -> String {
        "\(resource.type.rawValue)|\(Self.resourceFilename(resource))|\(index)"
    }

    private static func resourceFilename(_ resource: PHAssetResource) -> String {
#if PHOTO_EXTENDED_METADATA
        if #available(macOS 27.0, *), let filename = resource.filename { return filename }
#endif
        return resource.originalFilename
    }

    private static func resourceUTI(_ resource: PHAssetResource) -> String {
        if #available(macOS 26.0, *) { return resource.contentType.identifier }
        return resource.uniformTypeIdentifier
    }

    private static func resourceSize(_ resource: PHAssetResource) -> Int64? {
#if PHOTO_EXTENDED_METADATA
        if #available(macOS 27.0, *) { return resource.dataSize.map(Int64.init) }
#endif
        return nil
    }

    private static func location(_ point: GeoPoint) -> CLLocation {
        CLLocation(
            coordinate: .init(latitude: point.latitude, longitude: point.longitude),
            altitude: 0,
            horizontalAccuracy: point.horizontalAccuracy ?? -1,
            verticalAccuracy: -1,
            timestamp: Date()
        )
    }

    private static func mapAuthorization(_ status: PHAuthorizationStatus) -> PhotoLibraryAccess {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .limited: return .limited
        case .authorized: return .authorized
        @unknown default: return .denied
        }
    }

    private static func resourceKind(_ type: PHAssetResourceType) -> ResourceKind {
        switch type {
        case .photo: return .photo
        case .video: return .video
        case .audio: return .audio
        case .alternatePhoto: return .alternatePhoto
        case .fullSizePhoto: return .fullSizePhoto
        case .fullSizeVideo: return .fullSizeVideo
        case .adjustmentData: return .adjustmentData
        case .adjustmentBasePhoto: return .adjustmentBasePhoto
        case .pairedVideo: return .pairedVideo
        case .fullSizePairedVideo: return .fullSizePairedVideo
        case .adjustmentBaseVideo: return .adjustmentBaseVideo
        case .adjustmentBasePairedVideo: return .adjustmentBasePairedVideo
        case .photoProxy: return .photoProxy
        @unknown default: return .unknown
        }
    }
}

private final class DigestAccumulator {
    private var hasher = SHA256()
    private var count: Int64 = 0
    private let lock = NSLock()

    func update(_ data: Data) {
        lock.lock()
        hasher.update(data: data)
        count += Int64(data.count)
        lock.unlock()
    }

    func finish() -> (digest: String, byteCount: Int64) {
        lock.lock()
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let finalCount = count
        lock.unlock()
        return (digest, finalCount)
    }
}
