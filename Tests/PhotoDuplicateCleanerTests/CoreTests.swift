import AppKit
import AVFoundation
import Foundation
import Testing
@testable import PhotoDuplicateCleaner

@Suite("Duplicate cleaner core")
struct CoreTests {
    @Test func binaryExactResourcesFormExactGroup() throws {
        let matcher = ConservativeDuplicateMatcher(fingerprinting: StubFingerprinter())
        let hash = String(repeating: "a", count: 64)
        let first = fixture(id: "one", resourceHash: hash)
        let second = fixture(id: "two", resourceHash: hash)

        let groups = try matcher.groups(in: [first, second])

        #expect(groups.count == 1)
        #expect(groups.first?.confidence == .binaryExact)
    }

    @Test func contentExactIgnoresDifferentResourceHashes() throws {
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

        let groups = try matcher.groups(in: [first, second])

        #expect(groups.first?.confidence == .contentExact)
    }

    @Test func visualThresholdRejectsDifferentImages() throws {
        let matcher = ConservativeDuplicateMatcher(fingerprinting: StubFingerprinter())
        var first = fixture(id: "one", resourceHash: nil)
        var second = fixture(id: "two", resourceHash: nil)
        first.fingerprint = MediaFingerprint(perceptualHash: 0, normalizedLuma: [UInt8](repeating: 0, count: 1024))
        second.fingerprint = MediaFingerprint(perceptualHash: UInt64.max, normalizedLuma: [UInt8](repeating: 255, count: 1024))

        #expect(try matcher.groups(in: [first, second]).isEmpty)
    }

    @Test func conservativeVisualImageMatchIsReviewOnly() throws {
        let matcher = ConservativeDuplicateMatcher(fingerprinting: StubFingerprinter())
        var first = fixture(id: "one", resourceHash: nil)
        var second = fixture(id: "two", resourceHash: nil)
        first.fingerprint = MediaFingerprint(contentDigest: "one", perceptualHash: 0x1000, normalizedLuma: [UInt8](repeating: 120, count: 1024))
        second.fingerprint = MediaFingerprint(contentDigest: "two", perceptualHash: 0x1001, normalizedLuma: [UInt8](repeating: 121, count: 1024))

        let groups = try matcher.groups(in: [first, second])

        #expect(groups.first?.confidence == .likelyVisual)
    }

    @Test func videoDurationAndThreeFramesProduceLikelyMatch() throws {
        let matcher = ConservativeDuplicateMatcher(fingerprinting: StubFingerprinter())
        var first = fixture(id: "one", resourceHash: nil)
        var second = fixture(id: "two", resourceHash: nil)
        first.mediaKind = .video
        second.mediaKind = .video
        first.duration = 10
        second.duration = 10.1
        first.fingerprint = MediaFingerprint(perceptualHash: 0x1000, normalizedLuma: [], videoFrameHashes: [1, 2, 3])
        second.fingerprint = MediaFingerprint(perceptualHash: 0x1001, normalizedLuma: [], videoFrameHashes: [1, 2, 3])

        let groups = try matcher.groups(in: [first, second])

        #expect(groups.first?.confidence == .likelyVisual)
        #expect(groups.first?.evidence.contains { $0.contains("10.00s vs 10.10s") } == true)
    }

    @Test func videoDurationDifferenceRejectsOtherwiseSimilarFrames() throws {
        let matcher = ConservativeDuplicateMatcher(fingerprinting: StubFingerprinter())
        var first = fixture(id: "one", resourceHash: nil)
        var second = fixture(id: "two", resourceHash: nil)
        first.mediaKind = .video
        second.mediaKind = .video
        first.duration = 10
        second.duration = 10.4
        first.fingerprint = MediaFingerprint(perceptualHash: 0x1000, normalizedLuma: [], videoFrameHashes: [1, 2, 3])
        second.fingerprint = MediaFingerprint(perceptualHash: 0x1001, normalizedLuma: [], videoFrameHashes: [1, 2, 3])

        #expect(try matcher.groups(in: [first, second]).isEmpty)
    }

    @Test func longVideosUsePercentageBasedDurationTolerance() throws {
        let matcher = ConservativeDuplicateMatcher(fingerprinting: StubFingerprinter())
        var first = fixture(id: "one", resourceHash: nil)
        var second = fixture(id: "two", resourceHash: nil)
        first.mediaKind = .video
        second.mediaKind = .video
        first.duration = 600
        second.duration = 602
        first.fingerprint = MediaFingerprint(perceptualHash: 0x1000, normalizedLuma: [], videoFrameHashes: [1, 2, 3])
        second.fingerprint = MediaFingerprint(perceptualHash: 0x1001, normalizedLuma: [], videoFrameHashes: [1, 2, 3])

        #expect(try matcher.groups(in: [first, second]).first?.confidence == .likelyVisual)
    }

    @Test func videoGroupRejectsTransitiveDurationDrift() throws {
        let matcher = ConservativeDuplicateMatcher(fingerprinting: StubFingerprinter())
        var first = fixture(id: "one", resourceHash: nil)
        var middle = fixture(id: "middle", resourceHash: nil)
        var last = fixture(id: "last", resourceHash: nil)
        first.mediaKind = .video
        middle.mediaKind = .video
        last.mediaKind = .video
        first.duration = 10
        middle.duration = 10.2
        last.duration = 10.4
        first.fingerprint = MediaFingerprint(perceptualHash: 0x1000, normalizedLuma: [], videoFrameHashes: [1, 2, 3])
        middle.fingerprint = MediaFingerprint(perceptualHash: 0x1001, normalizedLuma: [], videoFrameHashes: [1, 2, 3])
        last.fingerprint = MediaFingerprint(perceptualHash: 0x1003, normalizedLuma: [], videoFrameHashes: [1, 2, 3])

        #expect(try matcher.groups(in: [first, middle, last]).isEmpty)
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

        let proposal = planner.proposal(for: group, keeperID: first.id, deleting: [second.id])

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

        #expect(proposal.conflicts.contains { $0.field == .location })
        #expect(proposal.proposedCreationDate == donor.creationDate)
        #expect(proposal.proposedLocation == donor.location)
        #expect(proposal.proposedCaption == donor.caption)
        #expect(proposal.albumsToAdd.map(\.id) == ["album-b"])
    }

    @Test func plannerHighlightsLocationPresentOnOnlySomeCopies() {
        let planner = FidelityMergePlanner()
        var keeper = fixture(id: "keeper", resourceHash: "a")
        keeper.location = nil
        var donor = fixture(id: "donor", resourceHash: "b")
        donor.location = .init(latitude: 34.05, longitude: -118.25)
        let group = DuplicateGroup(id: UUID(), confidence: .contentExact, assets: [keeper, donor], evidence: [])

        let proposal = planner.proposal(for: group, keeperID: keeper.id, deleting: [donor.id])

        let conflict = proposal.conflicts.first { $0.field == .location }
        #expect(conflict?.message == "Location is present on only some copies. Choose whether to preserve it.")
        #expect(proposal.proposedLocation == donor.location)
        #expect(!proposal.canApprove)
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

        let proposal = planner.proposal(for: group, keeperID: first.id, deleting: [second.id])

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

        let proposal = planner.proposal(for: group, keeperID: first.id, deleting: [second.id])

        #expect(proposal.conflicts.contains { $0.field == .adjustments })
        #expect(proposal.conflicts.contains { $0.field == .resourceTopology })
    }

    @Test func selectingKeeperMarksAllOtherExactAndVisualCopiesForDeletion() {
        let planner = FidelityMergePlanner()
        let first = fixture(id: "one", resourceHash: "a")
        let second = fixture(id: "two", resourceHash: "b")
        let visual = DuplicateGroup(id: UUID(), confidence: .likelyVisual, assets: [first, second], evidence: [])
        let exact = DuplicateGroup(id: UUID(), confidence: .contentExact, assets: [first, second], evidence: [])

        let visualProposal = planner.proposal(for: visual, keeperID: first.id)
        let exactProposal = planner.proposal(for: exact, keeperID: first.id)

        #expect(visualProposal.selectedDonors.map(\.id) == [second.id])
        #expect(visualProposal.canApprove)
        #expect(exactProposal.selectedDonors.map(\.id) == [second.id])
        #expect(exactProposal.canApprove)
    }

    @Test func explicitlyDeselectedDonorsRemainKept() {
        let planner = FidelityMergePlanner()
        let first = fixture(id: "one", resourceHash: "a")
        let second = fixture(id: "two", resourceHash: "b")
        let group = DuplicateGroup(id: UUID(), confidence: .likelyVisual, assets: [first, second], evidence: [])

        let proposal = planner.proposal(for: group, keeperID: first.id, deleting: [])

        #expect(proposal.selectedDonors.isEmpty)
        #expect(proposal.retainedCandidates.map(\.id) == [second.id])
        #expect(!proposal.canApprove)
    }

    @Test func retainedCandidatesDoNotContributeMetadataOrConflicts() {
        let planner = FidelityMergePlanner()
        var keeper = fixture(id: "keeper", resourceHash: "a")
        keeper.creationDate = Date(timeIntervalSince1970: 1_000)
        var deleted = fixture(id: "deleted", resourceHash: "b")
        deleted.creationDate = Date(timeIntervalSince1970: 1_001)
        deleted.keywords = ["merge-me"]
        var retained = fixture(id: "retained", resourceHash: "c")
        retained.creationDate = Date(timeIntervalSince1970: 99_000)
        retained.keywords = ["do-not-merge"]
        let group = DuplicateGroup(id: UUID(), confidence: .likelyVisual, assets: [keeper, deleted, retained], evidence: [])

        let proposal = planner.proposal(for: group, keeperID: keeper.id, deleting: [deleted.id])

        #expect(proposal.selectedDonors.map(\.id) == [deleted.id])
        #expect(proposal.retainedCandidates.map(\.id) == [retained.id])
        #expect(proposal.proposedKeywords == ["merge-me"])
        #expect(!proposal.conflicts.contains { $0.field == .creationDate })
    }

    @Test func journalRoundTripAndExports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = JSONJournalStore(url: root.appendingPathComponent("journal.json"))
        let asset = fixture(id: "one", resourceHash: "hash")
        let proposal = MergeProposal(
            id: UUID(), groupID: UUID(), confidence: .binaryExact, keeper: asset, donors: [fixture(id: "two", resourceHash: "hash")],
            donorIDsToDelete: ["two"],
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

    @Test func reviewSessionRestoresScopeGroupsAndDecisionsAcrossLaunches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = JSONReviewSessionStore(url: root.appendingPathComponent("review.json"))
        let keeper = fixture(id: "keeper", resourceHash: "same")
        let donor = fixture(id: "donor", resourceHash: "same")
        let proposal = MergeProposal(
            id: UUID(), groupID: UUID(), confidence: .binaryExact, keeper: keeper, donors: [donor],
            donorIDsToDelete: [donor.id],
            proposedCreationDate: keeper.creationDate, proposedLocation: nil, proposedCaption: nil, proposedRating: nil,
            proposedFavorite: false, proposedHidden: false, proposedKeywords: [], albumsToAdd: [], conflicts: [], isApproved: true
        )
        let scanDate = Date(timeIntervalSince1970: 123_456)
        let session = SavedReviewSession(
            savedAt: scanDate,
            lastScanDate: scanDate,
            scope: .init(kind: .selectedAlbums, albumIDs: ["album-1", "album-2"]),
            proposals: [proposal]
        )

        try store.save(session)
        let restored = try store.load()

        #expect(restored?.lastScanDate == scanDate)
        #expect(restored?.scope.kind == .selectedAlbums)
        #expect(restored?.scope.albumIDs == ["album-1", "album-2"])
        #expect(restored?.proposals.first?.keeper.id == keeper.id)
        #expect(restored?.proposals.first?.donorIDsToDelete == [donor.id])
        #expect(restored?.proposals.first?.isApproved == true)

        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test @MainActor func photoLibraryChangePromptsOnceAndSuccessfulRescanClearsStaleness() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reviewStore = JSONReviewSessionStore(url: root.appendingPathComponent("review.json"))
        let keeper = fixture(id: "keeper", resourceHash: "same")
        let donor = fixture(id: "donor", resourceHash: "same")
        let proposal = MergeProposal(
            id: UUID(), groupID: UUID(), confidence: .binaryExact, keeper: keeper, donors: [donor],
            donorIDsToDelete: [donor.id],
            proposedCreationDate: nil, proposedLocation: nil, proposedCaption: nil, proposedRating: nil,
            proposedFavorite: false, proposedHidden: false, proposedKeywords: [], albumsToAdd: [], conflicts: [], isApproved: true
        )
        let scope = ScanScope(kind: .selectedAlbums, albumIDs: ["album-1"])
        try reviewStore.save(.init(
            savedAt: Date(),
            lastScanDate: Date(),
            scope: scope,
            proposals: [proposal],
            libraryRevision: LibraryRevision.signature(for: [keeper, donor])
        ))
        let library = ChangeObservingLibraryStub(assets: [keeper, donor])
        let model = CleanerAppModel(
            library: library,
            fingerprinting: StubFingerprinter(),
            cache: AppendingFingerprintCache(url: root.appendingPathComponent("fingerprints.jsonl")),
            journal: JSONJournalStore(url: root.appendingPathComponent("journal.json")),
            reviewSessionStore: reviewStore
        )

        model.bootstrap()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(library.observedScope == scope)

        library.emitChange()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(model.libraryResultsAreStale)
        #expect(model.showingLibraryChangeRescanPrompt)

        model.deferLibraryChangeRescan()
        library.emitChange()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(!model.showingLibraryChangeRescanPrompt)

        model.applyApproved()
        #expect(library.applyCallCount == 0)

        library.assets = []
        model.rescanAfterLibraryChange()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!model.libraryResultsAreStale)
        #expect(model.state == .review)
    }

    @Test @MainActor func launchDetectsChangesMadeWhileAppWasClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reviewStore = JSONReviewSessionStore(url: root.appendingPathComponent("review.json"))
        let scannedAsset = fixture(id: "keeper", resourceHash: "same")
        var changedAsset = scannedAsset
        changedAsset.modificationDate = Date(timeIntervalSince1970: 9_000)
        let proposal = MergeProposal(
            id: UUID(), groupID: UUID(), confidence: .binaryExact, keeper: scannedAsset, donors: [],
            donorIDsToDelete: [],
            proposedCreationDate: nil, proposedLocation: nil, proposedCaption: nil, proposedRating: nil,
            proposedFavorite: false, proposedHidden: false, proposedKeywords: [], albumsToAdd: [], conflicts: [], isApproved: false
        )
        try reviewStore.save(.init(
            savedAt: Date(),
            lastScanDate: Date(),
            scope: .init(),
            proposals: [proposal],
            libraryRevision: LibraryRevision.signature(for: [scannedAsset])
        ))
        let library = ChangeObservingLibraryStub(assets: [changedAsset])
        let model = CleanerAppModel(
            library: library,
            fingerprinting: StubFingerprinter(),
            cache: AppendingFingerprintCache(url: root.appendingPathComponent("fingerprints.jsonl")),
            journal: JSONJournalStore(url: root.appendingPathComponent("journal.json")),
            reviewSessionStore: reviewStore
        )

        model.bootstrap()
        try await Task.sleep(nanoseconds: 30_000_000)

        #expect(model.libraryResultsAreStale)
        #expect(model.showingLibraryChangeRescanPrompt)
    }

    @Test func libraryRevisionIsOrderIndependentButDetectsPhotosEdits() {
        var first = fixture(id: "one", resourceHash: "old-hash")
        let second = fixture(id: "two", resourceHash: "hash")
        let original = LibraryRevision.signature(for: [first, second])

        // Locally computed hashes are ours, not Photos', so they must not count as a change.
        first.resources[0].sha256 = "newly-computed-hash"
        let reordered = LibraryRevision.signature(for: [second, first])
        #expect(original == reordered)

        // Photos stamps every edit, so the modification date is the change signal.
        first.modificationDate = Date(timeIntervalSince1970: 5_000)
        #expect(original != LibraryRevision.signature(for: [first, second]))

        #expect(original != LibraryRevision.signature(for: [second]))
    }

    @Test @MainActor func modelProjectsReviewGroupsAndReportsPosition() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let keeper = fixture(id: "keeper", resourceHash: "same")
        let donor = fixture(id: "donor", resourceHash: "same")
        let exact = MergeProposal(
            id: UUID(), groupID: UUID(), confidence: .binaryExact, keeper: keeper, donors: [donor],
            donorIDsToDelete: [donor.id], proposedCreationDate: nil, proposedLocation: nil,
            proposedCaption: nil, proposedRating: nil, proposedFavorite: false, proposedHidden: false,
            proposedKeywords: [], albumsToAdd: [], conflicts: [], isApproved: false
        )
        let likely = MergeProposal(
            id: UUID(), groupID: UUID(), confidence: .likelyVisual, keeper: donor, donors: [keeper],
            donorIDsToDelete: [keeper.id], proposedCreationDate: nil, proposedLocation: nil,
            proposedCaption: nil, proposedRating: nil, proposedFavorite: false, proposedHidden: false,
            proposedKeywords: [], albumsToAdd: [], conflicts: [], isApproved: false
        )
        let model = CleanerAppModel(
            library: ChangeObservingLibraryStub(),
            fingerprinting: StubFingerprinter(),
            cache: AppendingFingerprintCache(url: root.appendingPathComponent("fingerprints.jsonl")),
            journal: JSONJournalStore(url: root.appendingPathComponent("journal.json")),
            reviewSessionStore: JSONReviewSessionStore(url: root.appendingPathComponent("review.json"))
        )
        model.proposals = [exact, likely]

        #expect(model.exactProposals.map(\.id) == [exact.id])
        #expect(model.likelyProposals.map(\.id) == [likely.id])
        #expect(model.position(of: exact.id)?.index == 1)
        #expect(model.position(of: exact.id)?.total == 2)
        #expect(model.position(of: UUID()) == nil)
    }

    @Test @MainActor func changeDuringScanCancelsBeforePublishingResultsAndPromptsAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = ChangeObservingLibraryStub()
        library.fetchDelayNanoseconds = 1_000_000_000
        let model = CleanerAppModel(
            library: library,
            fingerprinting: StubFingerprinter(),
            cache: AppendingFingerprintCache(url: root.appendingPathComponent("fingerprints.jsonl")),
            journal: JSONJournalStore(url: root.appendingPathComponent("journal.json")),
            reviewSessionStore: JSONReviewSessionStore(url: root.appendingPathComponent("review.json"))
        )

        model.startScan()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(model.state == .scanning)
        #expect(library.observedScope != nil)

        library.emitChange()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(model.state == .idle)
        #expect(model.proposals.isEmpty)
        #expect(model.libraryResultsAreStale)
        #expect(model.showingLibraryChangeRescanPrompt)
        #expect(model.libraryChangePromptMessage.contains("scan was stopped"))
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

struct StubFingerprinter: Fingerprinting {
    func fingerprint(asset: AssetSnapshot, images: [NSImage]) async throws -> MediaFingerprint { MediaFingerprint() }
    func visionFeature(from fingerprint: MediaFingerprint) -> VisionFeature? { nil }
    func distance(_ lhs: VisionFeature, _ rhs: VisionFeature) -> Float? { 0 }
}

final class ChangeObservingLibraryStub: PhotoLibraryClient, @unchecked Sendable {
    var assets: [AssetSnapshot]
    var fetchDelayNanoseconds: UInt64 = 0
    private(set) var observedScope: ScanScope?
    private(set) var applyCallCount = 0
    private var changeHandler: (@Sendable () -> Void)?

    init(assets: [AssetSnapshot] = []) {
        self.assets = assets
    }

    func authorizationStatus() -> PhotoLibraryAccess { .authorized }
    func requestAuthorization() async -> PhotoLibraryAccess { .authorized }
    func fetchAlbums() async throws -> [AlbumReference] { [] }
    func fetchAssetIdentifiers(scope: ScanScope) async throws -> [String] {
        if fetchDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: fetchDelayNanoseconds)
        }
        return assets.map(\.id)
    }
    func fetchSnapshots(ids: [String]) async throws -> [AssetSnapshot] {
        let wanted = Set(ids)
        return assets.filter { wanted.contains($0.id) }
    }
    func thumbnail(assetID: String, targetSize: CGSize, networkAccessAllowed: Bool) async throws -> NSImage {
        throw CleanerError.assetUnavailable(assetID)
    }
    func videoPlayerItem(assetID: String) async throws -> AVPlayerItem {
        throw CleanerError.assetUnavailable(assetID)
    }
    func videoFrames(assetID: String) async throws -> [NSImage] {
        throw CleanerError.assetUnavailable(assetID)
    }
    func updateOriginalHashes(for asset: AssetSnapshot) async throws -> AssetSnapshot { asset }
    func apply(proposals: [MergeProposal]) async throws { applyCallCount += 1 }
    func restoreKeeperMetadata(from entries: [CleanupJournalEntry]) async throws { }
    func startObservingChanges(scope: ScanScope, handler: @escaping @Sendable () -> Void) throws {
        observedScope = scope
        changeHandler = handler
    }

    func emitChange() { changeHandler?() }
}
