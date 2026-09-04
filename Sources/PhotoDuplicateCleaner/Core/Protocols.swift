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

protocol PhotoLibraryClient: AnyObject {
    func authorizationStatus() -> PhotoLibraryAccess
    func requestAuthorization() async -> PhotoLibraryAccess
    func fetchAlbums() async throws -> [AlbumReference]
    func fetchAssets(scope: ScanScope) async throws -> [AssetSnapshot]
    func thumbnail(assetID: String, targetSize: CGSize, networkAccessAllowed: Bool) async throws -> NSImage
    func videoPlayerItem(assetID: String) async throws -> AVPlayerItem
    func videoFrames(assetID: String) async throws -> [NSImage]
    func updateOriginalHashes(for asset: AssetSnapshot) async throws -> AssetSnapshot
    func apply(proposals: [MergeProposal]) async throws
    func restoreKeeperMetadata(from entries: [CleanupJournalEntry]) async throws
    func startObservingChanges(scope: ScanScope, handler: @escaping @Sendable () -> Void) throws
}

protocol ResourceLoader {
    func thumbnail(assetID: String, targetSize: CGSize, networkAccessAllowed: Bool) async throws -> NSImage
    func videoFrames(assetID: String) async throws -> [NSImage]
    func updateOriginalHashes(for asset: AssetSnapshot) async throws -> AssetSnapshot
}

protocol Fingerprinting {
    func fingerprint(asset: AssetSnapshot, images: [NSImage]) async throws -> MediaFingerprint
    func visionDistance(_ lhs: MediaFingerprint, _ rhs: MediaFingerprint) -> Float?
}

protocol DuplicateMatcher {
    func groups(in assets: [AssetSnapshot]) -> [DuplicateGroup]
}

protocol MergePlanner {
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

protocol InventoryCache {
    func load() throws -> [AssetSnapshot]
    func save(_ assets: [AssetSnapshot]) throws
    func clear() throws
}

protocol ReviewSessionStore {
    func load() throws -> SavedReviewSession?
    func save(_ session: SavedReviewSession) throws
    func clear() throws
}
