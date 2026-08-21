import AppKit
import Foundation
import SwiftUI

@MainActor
final class CleanerAppModel: ObservableObject {
    enum State: Equatable {
        case idle
        case scanning
        case review
        case applying
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var authorization: PhotoLibraryAccess = .notDetermined
    @Published var albums: [AlbumReference] = []
    @Published var scope = ScanScope()
    @Published var progress: ScanProgress?
    @Published var proposals: [MergeProposal] = []
    @Published var selectedProposalID: UUID?
    @Published var isPaused = false
    @Published var journalEntries: [CleanupJournalEntry] = []
    @Published var showingConfirmation = false

    let library: PhotoLibraryClient
    private let fingerprinting: Fingerprinting
    private let matcher: DuplicateMatcher
    private let planner: MergePlanner
    private let cache: InventoryCache
    private let journal: JournalStore
    private var scanTask: Task<Void, Never>?

    init(
        library: PhotoLibraryClient = PhotoKitLibraryClient(),
        fingerprinting: Fingerprinting = MediaFingerprinter(),
        cache: InventoryCache = JSONInventoryCache(),
        journal: JournalStore = JSONJournalStore()
    ) {
        self.library = library
        self.fingerprinting = fingerprinting
        self.matcher = ConservativeDuplicateMatcher(fingerprinting: fingerprinting)
        self.planner = FidelityMergePlanner()
        self.cache = cache
        self.journal = journal
        self.authorization = library.authorizationStatus()
        self.journalEntries = (try? journal.load()) ?? []
    }

    var approvedProposals: [MergeProposal] { proposals.filter(\.canApply) }
    var selectedProposal: MergeProposal? {
        guard let selectedProposalID else { return proposals.first }
        return proposals.first { $0.id == selectedProposalID }
    }
    var exactCount: Int { proposals.filter { $0.confidence != .likelyVisual }.count }
    var likelyCount: Int { proposals.filter { $0.confidence == .likelyVisual }.count }

    func requestAccessAndLoadAlbums() {
        Task {
            authorization = await library.requestAuthorization()
            guard authorization == .authorized else {
                state = .failed(authorization == .limited
                    ? CleanerError.limitedAccessUnsupported.localizedDescription
                    : CleanerError.photoAccessRequired.localizedDescription)
                return
            }
            do { albums = try await library.fetchAlbums() }
            catch { state = .failed(error.localizedDescription) }
        }
    }

    func startScan() {
        scanTask?.cancel()
        scanTask = Task { await scan() }
    }

    func pauseOrResume() { isPaused.toggle() }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isPaused = false
        progress = nil
        state = proposals.isEmpty ? .idle : .review
    }

    func toggleAlbum(_ albumID: String) {
        if scope.albumIDs.contains(albumID) { scope.albumIDs.remove(albumID) }
        else { scope.albumIDs.insert(albumID) }
    }

    func chooseKeeper(proposalID: UUID, assetID: String) {
        guard let index = proposals.firstIndex(where: { $0.id == proposalID }) else { return }
        let group = DuplicateGroup(
            id: proposals[index].groupID,
            confidence: proposals[index].confidence,
            assets: [proposals[index].keeper] + proposals[index].donors,
            evidence: []
        )
        var replacement = planner.proposal(for: group, keeperID: assetID)
        replacement.id = proposalID
        replacement.isApproved = false
        proposals[index] = replacement
    }

    func resolve(_ conflict: MetadataConflict, proposalID: UUID, using assetID: String) {
        guard let index = proposals.firstIndex(where: { $0.id == proposalID }) else { return }
        let assets = [proposals[index].keeper] + proposals[index].donors
        guard let source = assets.first(where: { $0.id == assetID }) else { return }
        switch conflict.field {
        case .creationDate: proposals[index].proposedCreationDate = source.creationDate
        case .location: proposals[index].proposedLocation = source.location
        case .caption: proposals[index].proposedCaption = source.caption
        case .hidden: proposals[index].proposedHidden = source.isHidden
        case .rating: proposals[index].proposedRating = source.rating
        case .adjustments, .resourceTopology:
            guard source.id == proposals[index].keeper.id else {
                chooseKeeper(proposalID: proposalID, assetID: source.id)
                return
            }
        }
        proposals[index].conflicts.removeAll { $0.field == conflict.field }
        proposals[index].isApproved = false
    }

    func setApproved(_ approved: Bool, proposalID: UUID) {
        guard let index = proposals.firstIndex(where: { $0.id == proposalID }), proposals[index].conflicts.isEmpty else { return }
        proposals[index].isApproved = approved
    }

    func approveAllConflictFreeExact() {
        for index in proposals.indices where proposals[index].confidence != .likelyVisual && proposals[index].conflicts.isEmpty {
            proposals[index].isApproved = true
        }
    }

    func applyApproved() {
        let approved = approvedProposals
        guard !approved.isEmpty else { return }
        state = .applying
        showingConfirmation = false
        Task {
            var entries: [CleanupJournalEntry] = []
            do {
                entries = try journal.appendPending(approved)
                try await library.apply(proposals: approved)
                try journal.mark(entries.map(\.id), status: .succeeded, error: nil)
                let appliedIDs = Set(approved.map(\.id))
                proposals.removeAll { appliedIDs.contains($0.id) }
                journalEntries = try journal.load()
                selectedProposalID = proposals.first?.id
                state = .review
            } catch {
                try? journal.mark(entries.map(\.id), status: .failed, error: error.localizedDescription)
                journalEntries = (try? journal.load()) ?? journalEntries
                state = .failed(error.localizedDescription)
            }
        }
    }

    func exportJournal() {
        let panel = NSSavePanel()
        panel.title = "Export Cleanup Journal"
        panel.nameFieldStringValue = "Photo Duplicate Cleanup.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let jsonURL = panel.url else { return }
        let csvURL = jsonURL.deletingPathExtension().appendingPathExtension("csv")
        do {
            journalEntries = try journal.load()
            try journal.export(entries: journalEntries, jsonURL: jsonURL, csvURL: csvURL)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func restoreKeeperMetadata() {
        let successful = journalEntries.filter { $0.status == .succeeded }
        Task {
            do { try await library.restoreKeeperMetadata(from: successful) }
            catch { state = .failed(error.localizedDescription) }
        }
    }

    func dismissError() {
        state = proposals.isEmpty ? .idle : .review
    }

    private func scan() async {
        state = .scanning
        proposals = []
        selectedProposalID = nil
        isPaused = false
        do {
            if library.authorizationStatus() != .authorized {
                authorization = await library.requestAuthorization()
            }
            guard authorization == .authorized || library.authorizationStatus() == .authorized else {
                throw authorization == .limited ? CleanerError.limitedAccessUnsupported : CleanerError.photoAccessRequired
            }
            authorization = .authorized
            if albums.isEmpty { albums = try await library.fetchAlbums() }
            if scope.kind == .selectedAlbums && scope.albumIDs.isEmpty {
                throw CleanerError.invalidProposal("Select at least one album to scan.")
            }

            progress = .init(phase: .inventory, completed: 0, total: 1, detail: "Reading Photos metadata")
            var assets = try await library.fetchAssets(scope: scope)
            try Task.checkCancellation()
            let cached = (try? cache.load()) ?? []
            let cachedByID = Dictionary(uniqueKeysWithValues: cached.map { ($0.id, $0) })
            for index in assets.indices {
                if let old = cachedByID[assets[index].id], old.modificationDate == assets[index].modificationDate,
                   old.fingerprint?.matcherVersion == MediaFingerprint.matcherVersion {
                    assets[index].fingerprint = old.fingerprint
                    let hashes = Dictionary(uniqueKeysWithValues: old.resources.compactMap { resource in
                        resource.sha256.map { (resource.key, ($0, resource.byteCount)) }
                    })
                    for resourceIndex in assets[index].resources.indices {
                        if let saved = hashes[assets[index].resources[resourceIndex].key] {
                            assets[index].resources[resourceIndex].sha256 = saved.0
                            assets[index].resources[resourceIndex].byteCount = saved.1
                        }
                    }
                }
            }

            progress = .init(phase: .thumbnails, completed: 0, total: assets.count, detail: "Generating local fingerprints")
            for index in assets.indices {
                try await waitIfPaused()
                try Task.checkCancellation()
                if assets[index].fingerprint == nil {
                    let images: [NSImage]
                    if assets[index].mediaKind == .video {
                        images = try await library.videoFrames(assetID: assets[index].id)
                    } else {
                        images = [try await library.thumbnail(assetID: assets[index].id, targetSize: .init(width: 512, height: 512))]
                    }
                    assets[index].fingerprint = try await fingerprinting.fingerprint(asset: assets[index], images: images)
                }
                progress = .init(phase: .thumbnails, completed: index + 1, total: assets.count, detail: assets[index].originalFilename)
                if index.isMultiple(of: 25) { try? cache.save(assets) }
            }
            try cache.save(assets)

            progress = .init(phase: .matching, completed: 0, total: 1, detail: "Finding conservative candidates")
            let preliminary = matcher.groups(in: assets)
            let candidateIDs = Set(preliminary.flatMap { $0.assets.map(\.id) })
            let candidateIndices = assets.indices.filter { candidateIDs.contains(assets[$0].id) && assets[$0].binarySignature == nil }
            progress = .init(phase: .confirming, completed: 0, total: candidateIndices.count, detail: "Hashing candidate originals")
            for (offset, index) in candidateIndices.enumerated() {
                try await waitIfPaused()
                try Task.checkCancellation()
                assets[index] = try await library.updateOriginalHashes(for: assets[index])
                progress = .init(phase: .confirming, completed: offset + 1, total: candidateIndices.count, detail: assets[index].originalFilename)
                if offset.isMultiple(of: 10) { try? cache.save(assets) }
            }
            try cache.save(assets)

            progress = .init(phase: .matching, completed: 1, total: 1, detail: "Building review groups")
            let finalGroups = matcher.groups(in: assets)
            proposals = finalGroups.map { planner.proposal(for: $0, keeperID: nil) }
            selectedProposalID = proposals.first?.id
            progress = nil
            state = .review
        } catch is CancellationError {
            progress = nil
            state = .idle
        } catch {
            progress = nil
            state = .failed(error.localizedDescription)
        }
    }

    private func waitIfPaused() async throws {
        while isPaused {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
