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

    /// Identifiers are cheap to list but snapshots are not, so inventory is taken a
    /// page at a time. Several pages run at once because the cost is dominated by
    /// per-asset round trips into Photos rather than by local computation.
    private static let inventoryPageSize = 200
    private static let inventoryPagesInFlight = 3

    @Published var state: State = .idle
    @Published var authorization: PhotoLibraryAccess = .notDetermined
    @Published var albums: [AlbumReference] = []
    @Published private(set) var months: [MonthBucket] = []
    @Published private(set) var isLoadingMonths = false
    @Published var scope = ScanScope()
    @Published var progress: ScanProgress?
    @Published var proposals: [MergeProposal] = []
    @Published var selectedProposalID: UUID?
    @Published var isPaused = false
    @Published var journalEntries: [CleanupJournalEntry] = []
    @Published var showingConfirmation = false
    @Published var showingRescanConfirmation = false
    @Published var showingLibraryChangeRescanPrompt = false
    @Published private(set) var libraryResultsAreStale = false
    @Published var lastScanDate: Date?
    @Published private(set) var batch: BatchScanState?
    /// Non-fatal things the finished scan wants the user to know, such as assets that
    /// could not be read or a comparison budget that ran out.
    @Published private(set) var scanNotices: [String] = []

    let library: PhotoLibraryClient
    private let fingerprinting: Fingerprinting
    private let matcher: DuplicateMatcher
    private let planner: MergePlanner
    private let cache: FingerprintCache
    private let journal: JournalStore
    private let reviewSessionStore: ReviewSessionStore
    private var scanTask: Task<Void, Never>?
    private var monthsTask: Task<Void, Never>?
    private var pendingLibraryChangePrompt = false
    private var hasPromptedForCurrentStaleness = false
    private var libraryChangedDuringScan = false
    private var savedLibraryRevision: String?
    private var savedScanCouldNotBeVerified = false

    init(
        library: PhotoLibraryClient = PhotoKitLibraryClient(),
        fingerprinting: Fingerprinting = MediaFingerprinter(),
        cache: FingerprintCache = AppendingFingerprintCache(),
        journal: JournalStore = JSONJournalStore(),
        reviewSessionStore: ReviewSessionStore = JSONReviewSessionStore()
    ) {
        self.library = library
        self.fingerprinting = fingerprinting
        self.matcher = ConservativeDuplicateMatcher(fingerprinting: fingerprinting)
        self.planner = FidelityMergePlanner()
        self.cache = cache
        self.journal = journal
        self.reviewSessionStore = reviewSessionStore
        self.authorization = library.authorizationStatus()
        self.journalEntries = (try? journal.load()) ?? []
        if let session = try? reviewSessionStore.load() {
            self.scope = session.scope
            self.proposals = session.proposals
            self.lastScanDate = session.lastScanDate
            self.selectedProposalID = session.proposals.first?.id
            self.savedLibraryRevision = session.libraryRevision
            self.batch = session.batch
            self.months = session.months
            self.state = .review
        }
    }

    var approvedProposals: [MergeProposal] { proposals.filter(\.canApply) }
    var selectedProposal: MergeProposal? {
        guard let selectedProposalID else { return proposals.first }
        return proposals.first { $0.id == selectedProposalID }
    }
    var exactProposals: [MergeProposal] { proposals.filter { $0.confidence != .likelyVisual } }
    var likelyProposals: [MergeProposal] { proposals.filter { $0.confidence == .likelyVisual } }
    var exactCount: Int { exactProposals.count }
    var likelyCount: Int { likelyProposals.count }
    var hasSavedScan: Bool { lastScanDate != nil }

    /// True when a by-month scan stopped part way through and the remaining months can
    /// be picked up without redoing the ones already compared. Changing the selection
    /// invalidates the remembered batch, since resuming it would no longer answer the
    /// question being asked.
    var canResumeScan: Bool {
        guard state != .scanning, let batch, batch.isMultiSegment, !batch.isComplete else { return false }
        return batch.segments == ScanPlanner.segments(for: scope, months: months)
    }
    var remainingSegmentCount: Int { batch?.pendingSegments.count ?? 0 }
    var completedSegmentCount: Int { batch?.completedCount ?? 0 }
    var totalSegmentCount: Int { batch?.segments.count ?? 0 }

    var selectedMonths: [MonthBucket] { months.filter { scope.monthIDs.contains($0.id) } }
    var selectedMonthAssetCount: Int { selectedMonths.reduce(0) { $0 + $1.assetCount } }
    var libraryAssetCount: Int { months.reduce(0) { $0 + $1.assetCount } }

    var scanScopeIsEmpty: Bool {
        switch scope.kind {
        case .entireLibrary: return false
        case .selectedAlbums: return scope.albumIDs.isEmpty
        case .months: return selectedMonths.isEmpty
        }
    }

    var libraryChangePromptMessage: String {
        if libraryChangedDuringScan {
            return "Photos changed while the comparison was running, so that scan was stopped before it could replace your remembered results. Run a fresh scan against the updated library."
        }
        if savedScanCouldNotBeVerified {
            return "This remembered scan was created before library change tracking was available. Your review choices are preserved, but run a fresh scan once to establish a verified baseline."
        }
        return "Photos changed since these results were created. Your remembered review choices are preserved, but cleanup is paused until a fresh scan verifies the selected scope."
    }

    func bootstrap() {
        AppStoragePaths.removeSupersededFiles()
        guard authorization == .authorized else { return }
        Task {
            do {
                if albums.isEmpty { albums = try await library.fetchAlbums() }
                if hasSavedScan {
                    try beginObservingLibraryChanges()
                    try await validateSavedLibraryRevision()
                }
            }
            catch { state = .failed(error.localizedDescription) }
        }
    }

    func requestAccessAndLoadAlbums() {
        Task {
            authorization = await library.requestAuthorization()
            guard authorization == .authorized else {
                state = .failed(authorization == .limited
                    ? CleanerError.limitedAccessUnsupported.localizedDescription
                    : CleanerError.photoAccessRequired.localizedDescription)
                return
            }
            do {
                albums = try await library.fetchAlbums()
                if hasSavedScan {
                    try beginObservingLibraryChanges()
                    try await validateSavedLibraryRevision()
                }
            }
            catch { state = .failed(error.localizedDescription) }
        }
    }

    /// Reads the capture-date histogram that drives month-sized batches. Cheap enough
    /// to run on demand because it only touches indexed properties.
    func loadMonths(force: Bool = false) {
        guard authorization == .authorized else { return }
        guard force || months.isEmpty else { return }
        guard monthsTask == nil else { return }
        isLoadingMonths = true
        monthsTask = Task {
            defer {
                isLoadingMonths = false
                monthsTask = nil
            }
            do {
                let buckets = try await library.fetchMonthBuckets()
                months = buckets
                scope.monthIDs = scope.monthIDs.intersection(Set(buckets.map(\.id)))
            } catch is CancellationError {
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func startScan() {
        scanTask?.cancel()
        clearLibraryChangeFlags()
        scanNotices = []
        batch = nil
        scanTask = Task { await runScan(resumingBatch: false) }
    }

    /// Continues a partly finished by-month scan, keeping the groups already found.
    func resumeScan() {
        guard canResumeScan else { return }
        scanTask?.cancel()
        clearLibraryChangeFlags()
        scanNotices = []
        scanTask = Task { await runScan(resumingBatch: true) }
    }

    func requestScan() {
        if hasSavedScan { showingRescanConfirmation = true }
        else { startScan() }
    }

    func confirmRescan() {
        showingRescanConfirmation = false
        startScan()
    }

    func rescanAfterLibraryChange() {
        showingLibraryChangeRescanPrompt = false
        startScan()
    }

    func deferLibraryChangeRescan() {
        showingLibraryChangeRescanPrompt = false
    }

    func pauseOrResume() { isPaused.toggle() }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isPaused = false
        progress = nil
        state = (hasSavedScan || !proposals.isEmpty) ? .review : .idle
        presentPendingLibraryChangePromptIfPossible()
    }

    /// One-based position of a proposal in the review list, for the footer counter.
    func position(of proposalID: UUID) -> (index: Int, total: Int)? {
        guard let index = proposals.firstIndex(where: { $0.id == proposalID }) else { return nil }
        return (index + 1, proposals.count)
    }

    func toggleAlbum(_ albumID: String) {
        if scope.albumIDs.contains(albumID) { scope.albumIDs.remove(albumID) }
        else { scope.albumIDs.insert(albumID) }
    }

    func toggleMonth(_ monthID: String) {
        if scope.monthIDs.contains(monthID) { scope.monthIDs.remove(monthID) }
        else { scope.monthIDs.insert(monthID) }
    }

    func selectMonths(_ monthIDs: [String]) {
        scope.monthIDs.formUnion(monthIDs)
    }

    func deselectMonths(_ monthIDs: [String]) {
        scope.monthIDs.subtract(monthIDs)
    }

    func selectAllMonths() {
        scope.monthIDs = Set(months.map(\.id))
    }

    func clearSelectedMonths() {
        scope.monthIDs = []
    }

    func chooseKeeper(proposalID: UUID, assetID: String) {
        guard let index = proposals.firstIndex(where: { $0.id == proposalID }) else { return }
        let current = proposals[index]
        guard current.keeper.id != assetID else { return }
        let group = DuplicateGroup(
            id: current.groupID,
            confidence: current.confidence,
            assets: [current.keeper] + current.donors,
            evidence: []
        )
        let deletionIDs = Set(group.assets.map(\.id)).subtracting([assetID])
        var replacement = planner.proposal(for: group, keeperID: assetID, deleting: deletionIDs)
        replacement.id = proposalID
        replacement.isApproved = false
        proposals[index] = replacement
        persistReviewSession()
    }

    func toggleDeletion(proposalID: UUID, assetID: String) {
        guard let index = proposals.firstIndex(where: { $0.id == proposalID }) else { return }
        let current = proposals[index]
        guard current.keeper.id != assetID else { return }
        var deletionIDs = current.donorIDsToDelete
        if deletionIDs.contains(assetID) { deletionIDs.remove(assetID) }
        else { deletionIDs.insert(assetID) }
        let group = DuplicateGroup(
            id: current.groupID,
            confidence: current.confidence,
            assets: [current.keeper] + current.donors,
            evidence: []
        )
        var replacement = planner.proposal(for: group, keeperID: current.keeper.id, deleting: deletionIDs)
        replacement.id = proposalID
        replacement.isApproved = false
        proposals[index] = replacement
        persistReviewSession()
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
        persistReviewSession()
    }

    func setApproved(_ approved: Bool, proposalID: UUID) {
        guard let index = proposals.firstIndex(where: { $0.id == proposalID }), proposals[index].canApprove else { return }
        proposals[index].isApproved = approved
        persistReviewSession()
    }

    func approveAndAdvance(proposalID: UUID) {
        setApproved(true, proposalID: proposalID)
        guard proposals.first(where: { $0.id == proposalID })?.isApproved == true else { return }
        selectAdjacent(to: proposalID, offset: 1, preferUnapproved: true)
    }

    func selectAdjacent(to proposalID: UUID, offset: Int, preferUnapproved: Bool = false) {
        guard let currentIndex = proposals.firstIndex(where: { $0.id == proposalID }), !proposals.isEmpty else { return }
        if preferUnapproved {
            let following = proposals.dropFirst(currentIndex + 1).first { !$0.isApproved }
            let wrapped = proposals.prefix(currentIndex).first { !$0.isApproved }
            if let next = following ?? wrapped { selectedProposalID = next.id; return }
        }
        let nextIndex = min(max(currentIndex + offset, 0), proposals.count - 1)
        selectedProposalID = proposals[nextIndex].id
    }

    func approveAllConflictFreeExact() {
        for index in proposals.indices where proposals[index].confidence != .likelyVisual && proposals[index].conflicts.isEmpty {
            proposals[index].isApproved = true
        }
        persistReviewSession()
    }

    func applyApproved() {
        let approved = approvedProposals
        guard !approved.isEmpty, !libraryResultsAreStale else { return }
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
                persistReviewSession()
                presentPendingLibraryChangePromptIfPossible()
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
        state = (hasSavedScan || !proposals.isEmpty) ? .review : .idle
        presentPendingLibraryChangePromptIfPossible()
    }

    // MARK: - Scanning

    private struct SegmentOutcome {
        var proposals: [MergeProposal] = []
        var unreadableAssetCount = 0
        var comparisonBudgetExhausted = false
    }

    private func runScan(resumingBatch: Bool) async {
        state = .scanning
        isPaused = false
        progress = .init(phase: .inventory, completed: 0, total: 1, detail: "Reading the Photos index")
        do {
            try await requireAuthorizedLibrary()
            if albums.isEmpty { albums = try await library.fetchAlbums() }
            if scope.kind == .months && months.isEmpty {
                progress = .init(phase: .inventory, completed: 0, total: 1, detail: "Grouping photos by month")
                months = try await library.fetchMonthBuckets()
            }
            try validateScopeSelection()
            try beginObservingLibraryChanges()

            let plannedSegments = ScanPlanner.segments(for: scope, months: months)
            guard !plannedSegments.isEmpty else {
                throw CleanerError.invalidProposal("The selected scope has nothing to scan.")
            }

            var work: BatchScanState
            if resumingBatch, let existing = batch, existing.segments == plannedSegments {
                work = existing
            } else {
                work = BatchScanState(segments: plannedSegments)
                proposals = []
                selectedProposalID = nil
            }
            work.activeSegmentID = nil
            batch = work

            // Captured before any comparison so a run that is stopped part way through
            // still has a baseline describing the library it was compared against.
            let baselineRevision = LibraryRevision.signature(
                for: try await library.fetchRevisionTokens(scope: scope.withoutCaptureFilter)
            )

            var unreadable = 0
            var budgetExhausted = false
            for segment in work.pendingSegments {
                try await waitIfPaused()
                try Task.checkCancellation()
                work.activeSegmentID = segment.id
                batch = work

                let outcome = try await scan(segment: segment, in: work)
                proposals.append(contentsOf: outcome.proposals.map(\.withoutFingerprints))
                unreadable += outcome.unreadableAssetCount
                budgetExhausted = budgetExhausted || outcome.comparisonBudgetExhausted

                work.completedSegmentIDs.insert(segment.id)
                work.activeSegmentID = nil
                batch = work
                selectedProposalID = selectedProposalID ?? proposals.first?.id
                lastScanDate = Date()
                savedLibraryRevision = baselineRevision
                persistReviewSession()
            }

            // A change that arrived after the last batch finished has already cancelled
            // this task, but nothing checks for it between there and here. Without this
            // the results would be published as verified against a library they no
            // longer describe.
            try Task.checkCancellation()
            guard !libraryChangedDuringScan else { throw CancellationError() }

            scanNotices = Self.notices(unreadableAssetCount: unreadable, comparisonBudgetExhausted: budgetExhausted)
            clearLibraryChangeFlags()
            progress = nil
            state = .review
        } catch is CancellationError {
            progress = nil
            state = (hasSavedScan || !proposals.isEmpty) ? .review : .idle
            presentPendingLibraryChangePromptIfPossible()
        } catch {
            progress = nil
            state = .failed(error.localizedDescription)
        }
    }

    private func scan(segment: ScanSegment, in work: BatchScanState) async throws -> SegmentOutcome {
        let label = Self.batchLabel(for: segment, in: work)
        var outcome = SegmentOutcome()

        progress = .init(phase: .inventory, completed: 0, total: 1, detail: "Listing photos", batchLabel: label)
        let identifiers = try await library.fetchAssetIdentifiers(scope: segment.scope)
        try Task.checkCancellation()
        guard !identifiers.isEmpty else { return outcome }

        let reusable = try await cachedRecords(for: Set(identifiers))
        var assets = try await takeInventory(of: identifiers, reusing: reusable, label: label)
        try Task.checkCancellation()
        guard !assets.isEmpty else { return outcome }

        outcome.unreadableAssetCount += try await addFingerprints(to: &assets, label: label)

        progress = .init(phase: .matching, completed: 0, total: 1, detail: "Finding candidates", batchLabel: label)
        let preliminary = try await findGroups(in: assets)
        let candidateIDs = Set(preliminary.groups.flatMap { $0.assets.map(\.id) })
        let candidates = assets.indices.filter { candidateIDs.contains(assets[$0].id) && assets[$0].binarySignature == nil }
        outcome.unreadableAssetCount += try await confirmOriginals(at: candidates, in: &assets, label: label)

        progress = .init(phase: .matching, completed: 1, total: 1, detail: "Building review groups", batchLabel: label)
        let confirmed = try await findGroups(in: assets)
        outcome.comparisonBudgetExhausted = preliminary.comparisonBudgetExhausted || confirmed.comparisonBudgetExhausted
        outcome.proposals = confirmed.groups.map { planner.proposal(for: $0, keeperID: nil, deleting: nil) }
        return outcome
    }

    private func takeInventory(
        of identifiers: [String],
        reusing reusable: [String: FingerprintRecord],
        label: String?
    ) async throws -> [AssetSnapshot] {
        let pages = Self.pages(of: identifiers, size: Self.inventoryPageSize)
        var assets: [AssetSnapshot] = []
        assets.reserveCapacity(identifiers.count)
        var completed = 0

        for wave in Self.pages(of: pages, size: Self.inventoryPagesInFlight) {
            try await waitIfPaused()
            try Task.checkCancellation()
            let library = self.library
            let fetched = try await withThrowingTaskGroup(of: (Int, [AssetSnapshot]).self) { group in
                for (offset, page) in wave.enumerated() {
                    group.addTask { (offset, try await library.fetchSnapshots(ids: page)) }
                }
                var byOffset: [Int: [AssetSnapshot]] = [:]
                for try await (offset, snapshots) in group { byOffset[offset] = snapshots }
                return (0..<wave.count).flatMap { byOffset[$0] ?? [] }
            }

            for var snapshot in fetched {
                if let record = reusable[snapshot.id] { _ = snapshot.applyCachedWork(record) }
                assets.append(snapshot)
            }
            completed += wave.reduce(0) { $0 + $1.count }
            progress = .init(
                phase: .inventory,
                completed: completed,
                total: identifiers.count,
                detail: "\(assets.count) photos and videos read",
                batchLabel: label
            )
        }
        return assets
    }

    /// Fingerprints everything without usable cached work, in chunks so progress,
    /// pausing, cancellation, and cache flushes all happen at a sensible cadence.
    /// A single unreadable asset is skipped rather than failing the whole scan: on a
    /// large library there is almost always at least one asset Photos cannot produce.
    private func addFingerprints(to assets: inout [AssetSnapshot], label: String?) async throws -> Int {
        let pending = assets.indices.filter { assets[$0].fingerprint == nil }
        guard !pending.isEmpty else { return 0 }

        let concurrency = Self.fingerprintConcurrency
        var completed = 0
        var unreadable = 0
        progress = .init(phase: .thumbnails, completed: 0, total: pending.count, detail: "Generating local fingerprints", batchLabel: label)

        for chunk in Self.pages(of: pending, size: concurrency * 4) {
            try await waitIfPaused()
            try Task.checkCancellation()

            let library = self.library
            let fingerprinting = self.fingerprinting
            let inputs = chunk.map { (index: $0, asset: assets[$0]) }
            let results = try await withThrowingTaskGroup(of: (Int, MediaFingerprint?).self) { group in
                for input in inputs {
                    group.addTask {
                        do {
                            let images: [NSImage]
                            if input.asset.mediaKind == .video {
                                images = try await library.videoFrames(assetID: input.asset.id)
                            } else {
                                images = [try await library.thumbnail(
                                    assetID: input.asset.id,
                                    targetSize: .init(width: 512, height: 512),
                                    networkAccessAllowed: true
                                )]
                            }
                            return (input.index, try await fingerprinting.fingerprint(asset: input.asset, images: images))
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            return (input.index, nil)
                        }
                    }
                }
                var collected: [(Int, MediaFingerprint?)] = []
                for try await result in group { collected.append(result) }
                return collected
            }

            var flush: [FingerprintRecord] = []
            for (index, fingerprint) in results {
                guard let fingerprint else {
                    unreadable += 1
                    continue
                }
                assets[index].fingerprint = fingerprint
                flush.append(assets[index].fingerprintRecord)
            }
            completed += chunk.count
            try await store(flush)
            progress = .init(
                phase: .thumbnails,
                completed: completed,
                total: pending.count,
                detail: assets[chunk[chunk.count - 1]].originalFilename,
                batchLabel: label
            )
        }
        return unreadable
    }

    private func confirmOriginals(at candidates: [Int], in assets: inout [AssetSnapshot], label: String?) async throws -> Int {
        guard !candidates.isEmpty else { return 0 }
        let concurrency = Self.originalHashConcurrency
        var completed = 0
        var unreadable = 0
        progress = .init(phase: .confirming, completed: 0, total: candidates.count, detail: "Hashing candidate originals", batchLabel: label)

        for chunk in Self.pages(of: candidates, size: concurrency * 2) {
            try await waitIfPaused()
            try Task.checkCancellation()

            let library = self.library
            let inputs = chunk.map { (index: $0, asset: assets[$0]) }
            let results = try await withThrowingTaskGroup(of: (Int, AssetSnapshot?).self) { group in
                for input in inputs {
                    group.addTask {
                        do {
                            return (input.index, try await library.updateOriginalHashes(for: input.asset))
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            return (input.index, nil)
                        }
                    }
                }
                var collected: [(Int, AssetSnapshot?)] = []
                for try await result in group { collected.append(result) }
                return collected
            }

            var flush: [FingerprintRecord] = []
            for (index, updated) in results {
                guard let updated else {
                    unreadable += 1
                    continue
                }
                assets[index] = updated
                flush.append(updated.fingerprintRecord)
            }
            completed += chunk.count
            try await store(flush)
            progress = .init(
                phase: .confirming,
                completed: completed,
                total: candidates.count,
                detail: assets[chunk[chunk.count - 1]].originalFilename,
                batchLabel: label
            )
        }
        return unreadable
    }

    /// Matching is CPU bound and can run for minutes on a large scope, so it is kept
    /// off the main actor to leave the interface responsive and cancellable.
    private nonisolated func findGroups(in assets: [AssetSnapshot]) async throws -> MatchResult {
        try matcher.match(in: assets)
    }

    private nonisolated func cachedRecords(for ids: Set<String>) async throws -> [String: FingerprintRecord] {
        (try? cache.records(for: ids)) ?? [:]
    }

    private nonisolated func store(_ records: [FingerprintRecord]) async throws {
        guard !records.isEmpty else { return }
        try? cache.upsert(records)
    }

    private func validateScopeSelection() throws {
        switch scope.kind {
        case .entireLibrary:
            return
        case .selectedAlbums:
            guard scope.albumIDs.isEmpty else { return }
            throw CleanerError.invalidProposal("Select at least one album to scan.")
        case .months:
            guard selectedMonths.isEmpty else { return }
            throw CleanerError.invalidProposal("Select at least one month to scan.")
        }
    }

    private func requireAuthorizedLibrary() async throws {
        if library.authorizationStatus() != .authorized {
            authorization = await library.requestAuthorization()
        }
        guard authorization == .authorized || library.authorizationStatus() == .authorized else {
            throw authorization == .limited ? CleanerError.limitedAccessUnsupported : CleanerError.photoAccessRequired
        }
        authorization = .authorized
    }

    private func waitIfPaused() async throws {
        while isPaused {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func beginObservingLibraryChanges() throws {
        try library.startObservingChanges(scope: scope.withoutCaptureFilter) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleLibraryChange()
            }
        }
    }

    private func validateSavedLibraryRevision() async throws {
        let currentRevision = LibraryRevision.signature(
            for: try await library.fetchRevisionTokens(scope: scope.withoutCaptureFilter)
        )
        guard let savedLibraryRevision else {
            savedScanCouldNotBeVerified = true
            handleLibraryChange()
            return
        }
        guard savedLibraryRevision == currentRevision else {
            handleLibraryChange()
            return
        }
    }

    private func handleLibraryChange() {
        guard hasSavedScan || state == .scanning else { return }
        libraryResultsAreStale = true
        showingConfirmation = false
        if state == .scanning {
            libraryChangedDuringScan = true
            scanTask?.cancel()
        }
        guard !hasPromptedForCurrentStaleness else { return }
        pendingLibraryChangePrompt = true
        presentPendingLibraryChangePromptIfPossible()
    }

    private func presentPendingLibraryChangePromptIfPossible() {
        guard pendingLibraryChangePrompt,
              !hasPromptedForCurrentStaleness,
              state == .idle || state == .review else { return }
        pendingLibraryChangePrompt = false
        hasPromptedForCurrentStaleness = true
        showingLibraryChangeRescanPrompt = true
    }

    private func clearLibraryChangeFlags() {
        showingLibraryChangeRescanPrompt = false
        pendingLibraryChangePrompt = false
        hasPromptedForCurrentStaleness = false
        libraryChangedDuringScan = false
        savedScanCouldNotBeVerified = false
        libraryResultsAreStale = false
    }

    private func persistReviewSession() {
        guard let lastScanDate else { return }
        let session = SavedReviewSession(
            savedAt: Date(),
            lastScanDate: lastScanDate,
            scope: scope.withoutCaptureFilter,
            proposals: proposals.map(\.withoutFingerprints),
            libraryRevision: savedLibraryRevision,
            batch: batch,
            months: months
        )
        do { try reviewSessionStore.save(session) }
        catch { state = .failed("The remembered scan could not be saved: \(error.localizedDescription)") }
    }

    private static var fingerprintConcurrency: Int {
        max(2, min(6, ProcessInfo.processInfo.activeProcessorCount))
    }

    private static var originalHashConcurrency: Int {
        max(2, min(4, ProcessInfo.processInfo.activeProcessorCount))
    }

    private static func batchLabel(for segment: ScanSegment, in work: BatchScanState) -> String? {
        guard work.isMultiSegment else { return nil }
        guard let index = work.segments.firstIndex(where: { $0.id == segment.id }) else { return segment.title }
        return "Batch \(index + 1) of \(work.segments.count) · \(segment.title)"
    }

    private static func notices(unreadableAssetCount: Int, comparisonBudgetExhausted: Bool) -> [String] {
        var notices: [String] = []
        if unreadableAssetCount > 0 {
            let noun = unreadableAssetCount == 1 ? "item" : "items"
            notices.append("\(unreadableAssetCount) \(noun) could not be read from Photos and were left out of the comparison. They are usually assets still downloading from iCloud; scanning again later will include them.")
        }
        if comparisonBudgetExhausted {
            notices.append("This scope contained more near-identical candidates than one pass compares. The groups shown are real, but scan by month to cover everything.")
        }
        return notices
    }

    private static func pages<T>(of values: [T], size: Int) -> [[T]] {
        guard size > 0, !values.isEmpty else { return values.isEmpty ? [] : [values] }
        return stride(from: 0, to: values.count, by: size).map {
            Array(values[$0..<min($0 + size, values.count)])
        }
    }
}
