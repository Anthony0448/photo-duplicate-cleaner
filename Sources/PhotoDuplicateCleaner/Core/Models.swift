import Foundation

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
    static let matcherVersion = 1

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

    var canApply: Bool { conflicts.isEmpty && isApproved }
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

struct ScanScope: Equatable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
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
