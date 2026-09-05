import AppKit
import AVFoundation
import Foundation

enum PhotoLibraryAccess: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case limited
    case authorized
}

enum CleanerError: LocalizedError {
    case photoAccessRequired
    case limitedAccessUnsupported
    case assetUnavailable(String)
    case staleAsset(String)
    case unsupportedMedia(String)
    case cancelled
    case invalidProposal(String)
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .photoAccessRequired: return "Full read/write Photos access is required."
        case .limitedAccessUnsupported: return "Limited Photos access cannot safely scan and clean a library."
        case .assetUnavailable(let id): return "The Photos asset is unavailable: \(id)"
        case .staleAsset(let id): return "An asset changed after scanning. Scan it again before cleanup: \(id)"
        case .unsupportedMedia(let reason): return "Unsupported media: \(reason)"
        case .cancelled: return "The operation was cancelled."
        case .invalidProposal(let reason): return "The cleanup proposal is invalid: \(reason)"
        case .persistence(let reason): return "Could not save local state: \(reason)"
        }
    }
}

protocol PhotoLibraryClient: AnyObject, Sendable {
    func authorizationStatus() -> PhotoLibraryAccess
    func requestAuthorization() async -> PhotoLibraryAccess
    func fetchAlbums() async throws -> [AlbumReference]

    /// Enumerating identifiers only touches the Photos index, so it stays fast even
    /// on libraries with hundreds of thousands of assets and gives the scan a real
    /// total to report progress against before any expensive work begins.
    func fetchAssetIdentifiers(scope: ScanScope) async throws -> [String]

    /// Builds full snapshots for one page of identifiers. This is the expensive part
    /// of taking inventory, so the caller drives it a page at a time.
    func fetchSnapshots(ids: [String]) async throws -> [AssetSnapshot]

    /// Capture-date histogram used to offer month-sized batches.
    func fetchMonthBuckets() async throws -> [MonthBucket]

    /// Cheap staleness stamps for a scope, avoiding a full inventory just to check
    /// whether a remembered scan still matches the library.
    func fetchRevisionTokens(scope: ScanScope) async throws -> [AssetRevisionToken]

    func thumbnail(assetID: String, targetSize: CGSize, networkAccessAllowed: Bool) async throws -> NSImage
    func videoPlayerItem(assetID: String) async throws -> AVPlayerItem
    func videoFrames(assetID: String) async throws -> [NSImage]
    func updateOriginalHashes(for asset: AssetSnapshot) async throws -> AssetSnapshot
    func apply(proposals: [MergeProposal]) async throws
    func restoreKeeperMetadata(from entries: [CleanupJournalEntry]) async throws
    func startObservingChanges(scope: ScanScope, handler: @escaping @Sendable () -> Void) throws
}

extension PhotoLibraryClient {
    func fetchAssets(scope: ScanScope) async throws -> [AssetSnapshot] {
        try await fetchSnapshots(ids: try await fetchAssetIdentifiers(scope: scope))
    }

    func fetchMonthBuckets() async throws -> [MonthBucket] {
        MonthBucketing.buckets(forCaptureDates: try await fetchAssets(scope: ScanScope()).map(\.creationDate))
    }

    func fetchRevisionTokens(scope: ScanScope) async throws -> [AssetRevisionToken] {
        LibraryRevision.tokens(for: try await fetchAssets(scope: scope))
    }
}

protocol ResourceLoader {
    func thumbnail(assetID: String, targetSize: CGSize, networkAccessAllowed: Bool) async throws -> NSImage
    func videoFrames(assetID: String) async throws -> [NSImage]
    func updateOriginalHashes(for asset: AssetSnapshot) async throws -> AssetSnapshot
}

protocol Fingerprinting: Sendable {
    func fingerprint(asset: AssetSnapshot, images: [NSImage]) async throws -> MediaFingerprint

    /// Decoding is separated from comparison so the matcher can unpack each asset's
    /// archived feature print once instead of on every comparison it takes part in.
    func visionFeature(from fingerprint: MediaFingerprint) -> VisionFeature?
    func distance(_ lhs: VisionFeature, _ rhs: VisionFeature) -> Float?
}

/// Matching runs off the main actor on a snapshot of the inventory, and throws
/// `CancellationError` when the surrounding scan task is cancelled.
protocol DuplicateMatcher: Sendable {
    func match(in assets: [AssetSnapshot]) throws -> MatchResult
}

extension DuplicateMatcher {
    func groups(in assets: [AssetSnapshot]) throws -> [DuplicateGroup] {
        try match(in: assets).groups
    }
}

protocol MergePlanner: Sendable {
    func proposal(for group: DuplicateGroup, keeperID: String?, deleting donorIDs: Set<String>?) -> MergeProposal
}

protocol CleanupApplier {
    func apply(proposals: [MergeProposal]) async throws
}

protocol JournalStore {
    func appendPending(_ proposals: [MergeProposal]) throws -> [CleanupJournalEntry]
    func mark(_ entryIDs: [UUID], status: JournalStatus, error: String?) throws
    func load() throws -> [CleanupJournalEntry]
    func export(entries: [CleanupJournalEntry], jsonURL: URL, csvURL: URL) throws
}

/// Remembers per-asset derived work between scans. Writes must be incremental: a
/// whole-library scan flushes thousands of times, so rewriting the entire store on
/// each flush is what made large libraries never finish.
protocol FingerprintCache: AnyObject, Sendable {
    func records(for ids: Set<String>) throws -> [String: FingerprintRecord]
    func upsert(_ records: [FingerprintRecord]) throws
    func clear() throws
}

protocol ReviewSessionStore {
    func load() throws -> SavedReviewSession?
    func save(_ session: SavedReviewSession) throws
    func clear() throws
}
