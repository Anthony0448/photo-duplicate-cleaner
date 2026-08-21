import AppKit
import Foundation
import Testing
@testable import PhotoDuplicateCleaner

@Suite("Duplicate cleaner core")
struct CoreTests {
    @Test func binaryExactResourcesFormExactGroup() {
        let matcher = ConservativeDuplicateMatcher(fingerprinting: StubFingerprinter())
        let hash = String(repeating: "a", count: 64)
        let first = fixture(id: "one", resourceHash: hash)
        let second = fixture(id: "two", resourceHash: hash)

        let groups = matcher.groups(in: [first, second])

        #expect(groups.count == 1)
        #expect(groups.first?.confidence == .binaryExact)
    }

    @Test func contentExactIgnoresDifferentResourceHashes() {
        let matcher = ConservativeDuplicateMatcher(fingerprinting: StubFingerprinter())
        let fingerprint = MediaFingerprint(
            contentDigest: "same-pixels",
            perceptualHash: 0x1122,
            normalizedLuma: [UInt8](repeating: 120, count: 1024)
        )
        var first = fixture(id: "one", resourceHash: "aaa")
        var second = fixture(id: "two", resourceHash: "bbb")
        first.fingerprint = fingerprint
        second.fingerprint = fingerprint

        let groups = matcher.groups(in: [first, second])

        #expect(groups.first?.confidence == .contentExact)
    }

    @Test func visualThresholdRejectsDifferentImages() {
        let matcher = ConservativeDuplicateMatcher(fingerprinting: StubFingerprinter())
        var first = fixture(id: "one", resourceHash: nil)
        var second = fixture(id: "two", resourceHash: nil)
        first.fingerprint = MediaFingerprint(perceptualHash: 0, normalizedLuma: [UInt8](repeating: 0, count: 1024))
        second.fingerprint = MediaFingerprint(perceptualHash: UInt64.max, normalizedLuma: [UInt8](repeating: 255, count: 1024))

        #expect(matcher.groups(in: [first, second]).isEmpty)
    }

    @Test func conservativeVisualImageMatchIsReviewOnly() {
        let matcher = ConservativeDuplicateMatcher(fingerprinting: StubFingerprinter())
        var first = fixture(id: "one", resourceHash: nil)
        var second = fixture(id: "two", resourceHash: nil)
        first.fingerprint = MediaFingerprint(contentDigest: "one", perceptualHash: 0x1000, normalizedLuma: [UInt8](repeating: 120, count: 1024))
        second.fingerprint = MediaFingerprint(contentDigest: "two", perceptualHash: 0x1001, normalizedLuma: [UInt8](repeating: 121, count: 1024))

        let groups = matcher.groups(in: [first, second])

        #expect(groups.first?.confidence == .likelyVisual)
    }

    @Test func videoDurationAndThreeFramesProduceLikelyMatch() {
        let matcher = ConservativeDuplicateMatcher(fingerprinting: StubFingerprinter())
        var first = fixture(id: "one", resourceHash: nil)
        var second = fixture(id: "two", resourceHash: nil)
        first.mediaKind = .video
        second.mediaKind = .video
        first.duration = 10
        second.duration = 10.1
        first.fingerprint = MediaFingerprint(perceptualHash: 0x1000, normalizedLuma: [], videoFrameHashes: [1, 2, 3])
        second.fingerprint = MediaFingerprint(perceptualHash: 0x1001, normalizedLuma: [], videoFrameHashes: [1, 2, 3])

        let groups = matcher.groups(in: [first, second])

        #expect(groups.first?.confidence == .likelyVisual)
    }

    @Test func fidelityPolicyPrefersLivePhotoAndEdits() {
        let planner = FidelityMergePlanner()
        var plain = fixture(id: "plain", resourceHash: "a")
        plain.pixelWidth = 8000
        plain.pixelHeight = 6000
        var live = fixture(id: "live", resourceHash: "b")
        live.isLivePhoto = true
        live.hasAdjustments = true

        #expect(planner.fidelityScore(live) > planner.fidelityScore(plain))
    }

    @Test func plannerFlagsMetadataConflictsAndUnionsSafeFields() {
        let planner = FidelityMergePlanner()
        var first = fixture(id: "one", resourceHash: "a")
        first.creationDate = Date(timeIntervalSince1970: 1_000)
        first.location = .init(latitude: 34.0, longitude: -118.0)
        first.keywords = ["family"]
        first.isFavorite = false
        var second = fixture(id: "two", resourceHash: "b")
        second.creationDate = Date(timeIntervalSince1970: 2_000)
        second.location = .init(latitude: 40.7, longitude: -74.0)
        second.keywords = ["vacation"]
        second.isFavorite = true
        let group = DuplicateGroup(id: UUID(), confidence: .likelyVisual, assets: [first, second], evidence: [])

        let proposal = planner.proposal(for: group, keeperID: first.id)

        #expect(proposal.conflicts.contains { $0.field == .creationDate })
        #expect(proposal.conflicts.contains { $0.field == .location })
        #expect(proposal.proposedKeywords == ["family", "vacation"])
        #expect(proposal.proposedFavorite)
        #expect(!proposal.canApply)
    }

    @Test func plannerFillsMissingMetadataAndPreservesAlbumMembership() {
        let planner = FidelityMergePlanner()
        var keeper = fixture(id: "keeper", resourceHash: "a")
        keeper.albums = [.init(id: "album-a", title: "A", canAddContent: true)]
        var donor = fixture(id: "donor", resourceHash: "b")
        donor.creationDate = Date(timeIntervalSince1970: 500)
        donor.location = .init(latitude: 34.05, longitude: -118.25)
        donor.caption = "Important caption"
        donor.albums = [.init(id: "album-b", title: "B", canAddContent: true)]
        let group = DuplicateGroup(id: UUID(), confidence: .contentExact, assets: [keeper, donor], evidence: [])

        let proposal = planner.proposal(for: group, keeperID: keeper.id)

        #expect(proposal.conflicts.isEmpty)
        #expect(proposal.proposedCreationDate == donor.creationDate)
        #expect(proposal.proposedLocation == donor.location)
        #expect(proposal.proposedCaption == donor.caption)
        #expect(proposal.albumsToAdd.map(\.id) == ["album-b"])
    }

    @Test func plannerAcceptsDateAndLocationWithinTolerance() {
        let planner = FidelityMergePlanner()
        var first = fixture(id: "one", resourceHash: "a")
        first.creationDate = Date(timeIntervalSince1970: 1_000)
        first.location = .init(latitude: 34.00000, longitude: -118.00000)
        var second = fixture(id: "two", resourceHash: "b")
        second.creationDate = Date(timeIntervalSince1970: 1_001.5)
        second.location = .init(latitude: 34.00005, longitude: -118.00005)
        let group = DuplicateGroup(id: UUID(), confidence: .contentExact, assets: [first, second], evidence: [])

        let proposal = planner.proposal(for: group, keeperID: first.id)

        #expect(!proposal.conflicts.contains { $0.field == .creationDate })
        #expect(!proposal.conflicts.contains { $0.field == .location })
    }

    @Test func plannerBlocksDifferentResourceTopologyAndCompetingEdits() {
        let planner = FidelityMergePlanner()
        var first = fixture(id: "one", resourceHash: "a")
        first.hasAdjustments = true
        first.adjustmentIdentifier = "edit-a"
        var second = fixture(id: "two", resourceHash: "b")
        second.hasAdjustments = true
        second.adjustmentIdentifier = "edit-b"
        second.resources.append(.init(
            key: "paired|two.mov|1", kind: .pairedVideo, filename: "two.mov", uniformTypeIdentifier: "com.apple.quicktime-movie",
            pixelWidth: 4_000, pixelHeight: 3_000, byteCount: 2_000, sha256: "c"
        ))
        let group = DuplicateGroup(id: UUID(), confidence: .likelyVisual, assets: [first, second], evidence: [])

        let proposal = planner.proposal(for: group, keeperID: first.id)

        #expect(proposal.conflicts.contains { $0.field == .adjustments })
        #expect(proposal.conflicts.contains { $0.field == .resourceTopology })
    }

    @Test func journalRoundTripAndExports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = JSONJournalStore(url: root.appendingPathComponent("journal.json"))
        let asset = fixture(id: "one", resourceHash: "hash")
        let proposal = MergeProposal(
            id: UUID(), groupID: UUID(), confidence: .binaryExact, keeper: asset, donors: [fixture(id: "two", resourceHash: "hash")],
            proposedCreationDate: nil, proposedLocation: nil, proposedCaption: nil, proposedRating: nil,
            proposedFavorite: false, proposedHidden: false, proposedKeywords: [], albumsToAdd: [], conflicts: [], isApproved: true
        )
        let pending = try store.appendPending([proposal])
        try store.mark(pending.map(\.id), status: .succeeded, error: nil)
        let loaded = try store.load()
        let json = root.appendingPathComponent("export.json")
        let csv = root.appendingPathComponent("export.csv")
        try store.export(entries: loaded, jsonURL: json, csvURL: csv)

        #expect(loaded.first?.status == .succeeded)
        #expect(FileManager.default.fileExists(atPath: json.path))
        #expect(FileManager.default.fileExists(atPath: csv.path))
    }

    private func fixture(id: String, resourceHash: String?) -> AssetSnapshot {
        AssetSnapshot(
            id: id,
            mediaKind: .image,
            originalFilename: "\(id).jpg",
            contentType: "public.jpeg",
            pixelWidth: 4_000,
            pixelHeight: 3_000,
            duration: 0,
            creationDate: nil,
            addedDate: nil,
            modificationDate: Date(timeIntervalSince1970: 100),
            location: nil,
            isFavorite: false,
            isHidden: false,
            caption: nil,
            keywords: [],
            rating: nil,
            hasAdjustments: false,
            adjustmentIdentifier: nil,
            isLivePhoto: false,
            isRAW: false,
            albums: [],
            resources: [.init(
                key: "photo|\(id).jpg|0", kind: .photo, filename: "\(id).jpg", uniformTypeIdentifier: "public.jpeg",
                pixelWidth: 4_000, pixelHeight: 3_000, byteCount: 1_000, sha256: resourceHash
            )],
            fingerprint: nil
        )
    }
}

private struct StubFingerprinter: Fingerprinting {
    func fingerprint(asset: AssetSnapshot, images: [NSImage]) async throws -> MediaFingerprint { MediaFingerprint() }
    func visionDistance(_ lhs: MediaFingerprint, _ rhs: MediaFingerprint) -> Float? { 0 }
}
