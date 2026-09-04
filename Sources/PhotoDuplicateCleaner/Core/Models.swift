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

        var id: String { rawValue }
        var label: String {
            switch self {
            case .entireLibrary: return "Entire library"
            case .selectedAlbums: return "Selected albums"
            }
        }
    }

    var kind: Kind = .entireLibrary
    var albumIDs: Set<String> = []
}

struct SavedReviewSession: Codable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int = SavedReviewSession.schemaVersion
    var matcherVersion: Int = MediaFingerprint.matcherVersion
    var savedAt: Date
    var lastScanDate: Date
    var scope: ScanScope
    var proposals: [MergeProposal]
    var libraryRevision: String? = nil
}

enum LibraryRevision {
    static func signature(for assets: [AssetSnapshot]) -> String {
        var normalized = assets.sorted { $0.id < $1.id }
        for index in normalized.indices {
            normalized[index].fingerprint = nil
            normalized[index].keywords.sort()
            normalized[index].albums.sort { $0.id < $1.id }
            normalized[index].resources.sort { $0.key < $1.key }
            for resourceIndex in normalized[index].resources.indices {
                normalized[index].resources[resourceIndex].sha256 = nil
                normalized[index].resources[resourceIndex].byteCount = nil
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(normalized)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ScanProgress: Equatable, Sendable {
    enum Phase: String, Sendable {
        case inventory = "Inventory"
        case thumbnails = "Fingerprinting"
        case confirming = "Confirming originals"
        case matching = "Matching"
    }

    var phase: Phase
    var completed: Int
    var total: Int
    var detail: String

    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}
