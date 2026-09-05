import Foundation
import CryptoKit

enum MediaKind: String, Codable, CaseIterable, Sendable {
    case image
    case video

    var label: String { rawValue.capitalized }
}

enum ResourceKind: String, Codable, Sendable {
    case photo
    case video
    case audio
    case alternatePhoto
    case fullSizePhoto
    case fullSizeVideo
    case adjustmentData
    case adjustmentBasePhoto
    case pairedVideo
    case fullSizePairedVideo
    case adjustmentBaseVideo
    case adjustmentBasePairedVideo
    case photoProxy
    case unknown

    var isOriginalBearing: Bool {
        switch self {
        case .photo, .video, .audio, .alternatePhoto, .pairedVideo:
            return true
        default:
            return false
        }
    }
}

struct GeoPoint: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double?

    func distance(to other: GeoPoint) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let deltaLat = (other.latitude - latitude) * .pi / 180
        let deltaLon = (other.longitude - longitude) * .pi / 180
        let a = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

struct AlbumReference: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var canAddContent: Bool
}

struct ResourceManifest: Codable, Hashable, Identifiable, Sendable {
    var key: String
    var kind: ResourceKind
    var filename: String
    var uniformTypeIdentifier: String
    var pixelWidth: Int
    var pixelHeight: Int
    var byteCount: Int64?
    var sha256: String?

    var id: String { key }
}

struct MediaFingerprint: Codable, Equatable, Sendable {
    static let matcherVersion = 2

    var matcherVersion: Int = MediaFingerprint.matcherVersion
    var contentDigest: String?
    var perceptualHash: UInt64?
    var normalizedLuma: [UInt8] = []
    var visionFeatureArchive: Data?
    var videoFrameHashes: [UInt64] = []
    var completedAt: Date = Date()
}

struct AssetSnapshot: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var mediaKind: MediaKind
    var originalFilename: String
    var contentType: String
    var pixelWidth: Int
    var pixelHeight: Int
    var duration: Double
    var creationDate: Date?
    var addedDate: Date?
    var modificationDate: Date?
    var location: GeoPoint?
    var isFavorite: Bool
    var isHidden: Bool
    var caption: String?
    var keywords: [String]
    var rating: Int?
    var hasAdjustments: Bool
    var adjustmentIdentifier: String?
    var isLivePhoto: Bool
    var isRAW: Bool
    var albums: [AlbumReference]
    var resources: [ResourceManifest]
    var fingerprint: MediaFingerprint?

    var aspectRatio: Double {
        guard pixelHeight > 0 else { return 0 }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    var totalKnownBytes: Int64 {
        resources.compactMap(\.byteCount).reduce(0, +)
    }

    var resourceTopology: Set<ResourceKind> {
        Set(resources.map(\.kind))
    }

    var binarySignature: String? {
        let originals = resources.filter { $0.kind.isOriginalBearing }
        guard !originals.isEmpty, originals.allSatisfy({ $0.sha256 != nil }) else { return nil }
        return originals
            .sorted { $0.key < $1.key }
            .map { "\($0.kind.rawValue):\($0.sha256!)" }
            .joined(separator: "|")
    }
}

enum MatchConfidence: String, Codable, CaseIterable, Sendable {
    case binaryExact
    case contentExact
    case likelyVisual

    var label: String {
        switch self {
        case .binaryExact: return "Binary exact"
        case .contentExact: return "Content exact"
        case .likelyVisual: return "Likely visual"
        }
    }
}

struct DuplicateGroup: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var confidence: MatchConfidence
    var assets: [AssetSnapshot]
    var evidence: [String]
}

enum MetadataField: String, Codable, Sendable {
    case creationDate
    case location
    case caption
    case hidden
    case rating
    case adjustments
    case resourceTopology
}

struct MetadataConflict: Codable, Identifiable, Equatable, Sendable {
    var id: String { field.rawValue }
    var field: MetadataField
    var message: String
    var assetIDs: [String]
}

struct MergeProposal: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var groupID: UUID
    var confidence: MatchConfidence
    var keeper: AssetSnapshot
    var donors: [AssetSnapshot]
    var donorIDsToDelete: Set<String>
    var proposedCreationDate: Date?
    var proposedLocation: GeoPoint?
    var proposedCaption: String?
    var proposedRating: Int?
    var proposedFavorite: Bool
    var proposedHidden: Bool
    var proposedKeywords: [String]
    var albumsToAdd: [AlbumReference]
    var conflicts: [MetadataConflict]
    var isApproved: Bool

    var selectedDonors: [AssetSnapshot] { donors.filter { donorIDsToDelete.contains($0.id) } }
    var retainedCandidates: [AssetSnapshot] { donors.filter { !donorIDsToDelete.contains($0.id) } }
    var canApprove: Bool { conflicts.isEmpty && !selectedDonors.isEmpty }
    var canApply: Bool { canApprove && isApproved }
}

extension MergeProposal {
    private enum CodingKeys: String, CodingKey {
        case id, groupID, confidence, keeper, donors, donorIDsToDelete
        case proposedCreationDate, proposedLocation, proposedCaption, proposedRating
        case proposedFavorite, proposedHidden, proposedKeywords, albumsToAdd, conflicts, isApproved
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        groupID = try container.decode(UUID.self, forKey: .groupID)
        confidence = try container.decode(MatchConfidence.self, forKey: .confidence)
        keeper = try container.decode(AssetSnapshot.self, forKey: .keeper)
        donors = try container.decode([AssetSnapshot].self, forKey: .donors)
        donorIDsToDelete = try container.decodeIfPresent(Set<String>.self, forKey: .donorIDsToDelete)
            ?? Set(donors.map(\.id))
        proposedCreationDate = try container.decodeIfPresent(Date.self, forKey: .proposedCreationDate)
        proposedLocation = try container.decodeIfPresent(GeoPoint.self, forKey: .proposedLocation)
        proposedCaption = try container.decodeIfPresent(String.self, forKey: .proposedCaption)
        proposedRating = try container.decodeIfPresent(Int.self, forKey: .proposedRating)
        proposedFavorite = try container.decode(Bool.self, forKey: .proposedFavorite)
        proposedHidden = try container.decode(Bool.self, forKey: .proposedHidden)
        proposedKeywords = try container.decode([String].self, forKey: .proposedKeywords)
        albumsToAdd = try container.decode([AlbumReference].self, forKey: .albumsToAdd)
        conflicts = try container.decode([MetadataConflict].self, forKey: .conflicts)
        isApproved = try container.decode(Bool.self, forKey: .isApproved)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(groupID, forKey: .groupID)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(keeper, forKey: .keeper)
        try container.encode(donors, forKey: .donors)
        try container.encode(donorIDsToDelete, forKey: .donorIDsToDelete)
        try container.encodeIfPresent(proposedCreationDate, forKey: .proposedCreationDate)
        try container.encodeIfPresent(proposedLocation, forKey: .proposedLocation)
        try container.encodeIfPresent(proposedCaption, forKey: .proposedCaption)
        try container.encodeIfPresent(proposedRating, forKey: .proposedRating)
        try container.encode(proposedFavorite, forKey: .proposedFavorite)
        try container.encode(proposedHidden, forKey: .proposedHidden)
        try container.encode(proposedKeywords, forKey: .proposedKeywords)
        try container.encode(albumsToAdd, forKey: .albumsToAdd)
        try container.encode(conflicts, forKey: .conflicts)
        try container.encode(isApproved, forKey: .isApproved)
    }
}

enum JournalStatus: String, Codable, Sendable {
    case pending
    case succeeded
    case failed
}

struct CleanupJournalEntry: Codable, Identifiable, Sendable {
    var id: UUID
    var createdAt: Date
    var completedAt: Date?
    var status: JournalStatus
    var proposal: MergeProposal
    var errorMessage: String?
}

struct ScanScope: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case entireLibrary
        case selectedAlbums
        case months

        var id: String { rawValue }
        /// Kept short: these are the three segments of a control in a narrow sidebar.
        var label: String {
            switch self {
            case .entireLibrary: return "Library"
            case .selectedAlbums: return "Albums"
            case .months: return "Months"
            }
        }
    }

    /// Narrows a fetch to one capture-date slice so a huge library can be walked
    /// in batches instead of one unbounded pass.
    enum CaptureFilter: Codable, Equatable, Sendable {
        /// Half-open `start ..< end`, so adjacent months never overlap.
        case window(start: Date, end: Date)
        case undated
    }

    var kind: Kind = .entireLibrary
    var albumIDs: Set<String> = []
    var monthIDs: Set<String> = []
    var captureFilter: CaptureFilter? = nil

    /// The scope the user configured, without any single-batch narrowing applied.
    var withoutCaptureFilter: ScanScope {
        var copy = self
        copy.captureFilter = nil
        return copy
    }
}

/// One month's worth of the library, used both to describe what is available and
/// to drive a single batch of a by-month scan.
struct MonthBucket: Codable, Hashable, Identifiable, Sendable {
    static let undatedIdentifier = "undated"

    var id: String
    var start: Date?
    var end: Date?
    var assetCount: Int

    var isUndated: Bool { start == nil || end == nil }
    var year: Int? { Int(id.prefix(4)) }

    var title: String {
        guard let start else { return "No capture date" }
        return start.formatted(.dateTime.year().month(.wide))
    }

    var shortTitle: String {
        guard let start else { return "Undated" }
        return start.formatted(.dateTime.month(.abbreviated))
    }

    var captureFilter: ScanScope.CaptureFilter {
        guard let start, let end else { return .undated }
        return .window(start: start, end: end)
    }
}

enum MonthBucketing {
    static func identifier(for date: Date?, calendar: Calendar = .current) -> String {
        guard let date else { return MonthBucket.undatedIdentifier }
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else { return MonthBucket.undatedIdentifier }
        return String(format: "%04d-%02d", year, month)
    }

    static func window(for identifier: String, calendar: Calendar = .current) -> (start: Date, end: Date)? {
        let parts = identifier.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month),
              let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return (start, end)
    }

    static func bucket(identifier: String, assetCount: Int, calendar: Calendar = .current) -> MonthBucket {
        let range = window(for: identifier, calendar: calendar)
        return MonthBucket(id: range == nil ? MonthBucket.undatedIdentifier : identifier,
                           start: range?.start,
                           end: range?.end,
                           assetCount: assetCount)
    }

    /// Newest month first, with undated assets last so the common case is on top.
    static func buckets(forCaptureDates dates: [Date?], calendar: Calendar = .current) -> [MonthBucket] {
        var counts: [String: Int] = [:]
        for date in dates { counts[identifier(for: date, calendar: calendar), default: 0] += 1 }
        return counts
            .map { bucket(identifier: $0.key, assetCount: $0.value, calendar: calendar) }
            .sorted(by: isOrderedBefore)
    }

    static func isOrderedBefore(_ lhs: MonthBucket, _ rhs: MonthBucket) -> Bool {
        switch (lhs.start, rhs.start) {
        case let (left?, right?): return left > right
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return lhs.id < rhs.id
        }
    }
}

/// A single unit of scanning work. Whole-library and album scans are one segment;
/// a by-month scan is one segment per selected month.
struct ScanSegment: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var scope: ScanScope
}

enum ScanPlanner {
    static let entireLibraryID = "entire-library"
    static let selectedAlbumsID = "selected-albums"

    static func segments(for scope: ScanScope, months: [MonthBucket]) -> [ScanSegment] {
        switch scope.kind {
        case .entireLibrary:
            return [ScanSegment(id: entireLibraryID, title: "Whole library", scope: scope.withoutCaptureFilter)]
        case .selectedAlbums:
            return [ScanSegment(id: selectedAlbumsID, title: "Selected albums", scope: scope.withoutCaptureFilter)]
        case .months:
            return months
                .filter { scope.monthIDs.contains($0.id) && $0.assetCount > 0 }
                .sorted(by: MonthBucketing.isOrderedBefore)
                .map { bucket in
                    var segmentScope = scope.withoutCaptureFilter
                    segmentScope.monthIDs = [bucket.id]
                    segmentScope.captureFilter = bucket.captureFilter
                    return ScanSegment(id: bucket.id, title: bucket.title, scope: segmentScope)
                }
        }
    }
}

/// Tracks which segments of a multi-batch scan are already done so a cancelled or
/// interrupted run can pick up where it stopped instead of starting over.
struct BatchScanState: Codable, Equatable, Sendable {
    var segments: [ScanSegment]
    var completedSegmentIDs: Set<String> = []
    var activeSegmentID: String? = nil

    var pendingSegments: [ScanSegment] { segments.filter { !completedSegmentIDs.contains($0.id) } }
    var completedCount: Int { segments.count - pendingSegments.count }
    var isComplete: Bool { pendingSegments.isEmpty }
    var isMultiSegment: Bool { segments.count > 1 }

    /// One-based position of the segment being scanned, for progress labels.
    var activePosition: Int? {
        guard let activeSegmentID, let index = segments.firstIndex(where: { $0.id == activeSegmentID }) else { return nil }
        return index + 1
    }
}

/// Identity plus change stamp for one asset. Cheap enough to gather for an entire
/// library, unlike a full snapshot, so it is what staleness checks compare.
struct AssetRevisionToken: Codable, Hashable, Sendable {
    var id: String
    var modificationDate: Date?
}

enum LibraryRevision {
    static func signature(for tokens: [AssetRevisionToken]) -> String {
        var hasher = SHA256()
        for token in tokens.sorted(by: { $0.id < $1.id }) {
            hasher.update(data: Data(token.id.utf8))
            let stamp = token.modificationDate?.timeIntervalSinceReferenceDate ?? .infinity
            hasher.update(data: withUnsafeBytes(of: stamp.bitPattern.littleEndian) { Data($0) })
            hasher.update(data: Data([0x1e]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func tokens(for assets: [AssetSnapshot]) -> [AssetRevisionToken] {
        assets.map { AssetRevisionToken(id: $0.id, modificationDate: $0.modificationDate) }
    }

    static func signature(for assets: [AssetSnapshot]) -> String { signature(for: tokens(for: assets)) }
}

/// What the app reuses between scans. Only the derived data is stored, so the file
/// stays a fraction of the size of a full snapshot inventory.
struct FingerprintRecord: Codable, Equatable, Sendable {
    struct ResourceHash: Codable, Equatable, Sendable {
        var sha256: String
        var byteCount: Int64?
    }

    var id: String
    var modificationDate: Date?
    var matcherVersion: Int = MediaFingerprint.matcherVersion
    var fingerprint: MediaFingerprint?
    var resourceHashes: [String: ResourceHash] = [:]
}

extension AssetSnapshot {
    var fingerprintRecord: FingerprintRecord {
        var hashes: [String: FingerprintRecord.ResourceHash] = [:]
        for resource in resources {
            guard let sha256 = resource.sha256 else { continue }
            hashes[resource.key] = .init(sha256: sha256, byteCount: resource.byteCount)
        }
        return FingerprintRecord(
            id: id,
            modificationDate: modificationDate,
            fingerprint: fingerprint,
            resourceHashes: hashes
        )
    }

    /// Reuses previously computed work when the asset has not changed in Photos and
    /// the record came from the current matcher.
    mutating func applyCachedWork(_ record: FingerprintRecord) -> Bool {
        guard record.id == id,
              record.matcherVersion == MediaFingerprint.matcherVersion,
              record.modificationDate == modificationDate else { return false }
        if let cached = record.fingerprint, cached.matcherVersion == MediaFingerprint.matcherVersion {
            fingerprint = cached
        }
        for index in resources.indices {
            guard let saved = record.resourceHashes[resources[index].key] else { continue }
            resources[index].sha256 = saved.sha256
            resources[index].byteCount = saved.byteCount
        }
        return true
    }
}

extension MergeProposal {
    /// Review and cleanup never read fingerprints, and they dominate a snapshot's
    /// size, so they are dropped before a session is held long term or written out.
    var withoutFingerprints: MergeProposal {
        var copy = self
        copy.keeper.fingerprint = nil
        for index in copy.donors.indices { copy.donors[index].fingerprint = nil }
        return copy
    }
}

struct SavedReviewSession: Codable, Sendable {
    static let schemaVersion = 2

    var schemaVersion: Int = SavedReviewSession.schemaVersion
    var matcherVersion: Int = MediaFingerprint.matcherVersion
    var savedAt: Date
    var lastScanDate: Date
    var scope: ScanScope
    var proposals: [MergeProposal]
    var libraryRevision: String? = nil
    var batch: BatchScanState? = nil
    var months: [MonthBucket] = []
}

struct ScanProgress: Equatable, Sendable {
    enum Phase: String, Sendable {
        case inventory = "Reading Photos metadata"
        case thumbnails = "Fingerprinting"
        case confirming = "Confirming originals"
        case matching = "Matching"
    }

    var phase: Phase
    var completed: Int
    var total: Int
    var detail: String
    /// Set while a multi-batch scan is running, e.g. "Month 3 of 14 · July 2024".
    var batchLabel: String? = nil

    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}
