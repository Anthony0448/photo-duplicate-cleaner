import AppKit
import AVFoundation
import Combine
import CryptoKit
import Foundation
import Testing
@testable import PhotoDuplicateCleaner

@Suite("Month batching and large library scanning")
struct LargeLibraryScanTests {

    // MARK: - Month buckets

    @Test func capturedDatesGroupIntoMonthsNewestFirstWithUndatedLast() {
        let buckets = MonthBucketing.buckets(
            forCaptureDates: [
                date(2024, 7, 15), date(2024, 7, 20), date(2024, 7, 2),
                date(2023, 12, 5),
                date(2024, 6, 9), date(2024, 6, 10),
                nil, nil
            ],
            calendar: Self.utc
        )

        #expect(buckets.map(\.id) == ["2024-07", "2024-06", "2023-12", MonthBucket.undatedIdentifier])
        #expect(buckets.map(\.assetCount) == [3, 2, 1, 2])
        #expect(buckets.last?.isUndated == true)
        #expect(buckets.first?.year == 2024)
    }

    @Test func monthWindowsAreHalfOpenAndCoverTheYearBoundary() {
        let july = MonthBucketing.window(for: "2024-07", calendar: Self.utc)
        #expect(july?.start == date(2024, 7, 1, hour: 0))
        #expect(july?.end == date(2024, 8, 1, hour: 0))

        let december = MonthBucketing.window(for: "2023-12", calendar: Self.utc)
        #expect(december?.end == date(2024, 1, 1, hour: 0))

        #expect(MonthBucketing.window(for: MonthBucket.undatedIdentifier, calendar: Self.utc) == nil)
        #expect(MonthBucketing.window(for: "2024-13", calendar: Self.utc) == nil)
    }

    @Test func undatedBucketScansByAbsenceOfCaptureDateRatherThanAWindow() {
        let bucket = MonthBucketing.bucket(identifier: MonthBucket.undatedIdentifier, assetCount: 4, calendar: Self.utc)
        #expect(bucket.captureFilter == .undated)
        #expect(MonthBucketing.bucket(identifier: "2024-07", assetCount: 1, calendar: Self.utc).captureFilter
                == .window(start: date(2024, 7, 1, hour: 0)!, end: date(2024, 8, 1, hour: 0)!))
    }

    // MARK: - Planning

    @Test func monthScopePlansOneBatchPerSelectedMonthNewestFirst() {
        let months = MonthBucketing.buckets(
            forCaptureDates: [date(2024, 7, 15), date(2024, 6, 15), date(2024, 5, 15), nil],
            calendar: Self.utc
        )
        let scope = ScanScope(kind: .months, monthIDs: ["2024-05", "2024-07", MonthBucket.undatedIdentifier])

        let segments = ScanPlanner.segments(for: scope, months: months)

        #expect(segments.map(\.id) == ["2024-07", "2024-05", MonthBucket.undatedIdentifier])
        #expect(segments.allSatisfy { $0.scope.kind == .months })
        #expect(segments.map { $0.scope.monthIDs } == [["2024-07"], ["2024-05"], [MonthBucket.undatedIdentifier]])
        #expect(segments.last?.scope.captureFilter == .undated)
        if case .window(let start, _)? = segments.first?.scope.captureFilter {
            #expect(start == date(2024, 7, 1, hour: 0))
        } else {
            Issue.record("The newest batch should carry a capture window.")
        }
    }

    @Test func planningIgnoresMonthsThatAreNotInTheLibrary() {
        let months = MonthBucketing.buckets(forCaptureDates: [date(2024, 7, 15)], calendar: Self.utc)
        let scope = ScanScope(kind: .months, monthIDs: ["2024-07", "1998-01"])

        #expect(ScanPlanner.segments(for: scope, months: months).map(\.id) == ["2024-07"])
    }

    @Test func wholeLibraryAndAlbumScopesPlanASingleBatchWithoutACaptureFilter() {
        let library = ScanPlanner.segments(for: ScanScope(kind: .entireLibrary), months: [])
        #expect(library.map(\.id) == [ScanPlanner.entireLibraryID])
        #expect(library.first?.scope.captureFilter == nil)

        let albums = ScanPlanner.segments(for: ScanScope(kind: .selectedAlbums, albumIDs: ["a"]), months: [])
        #expect(albums.map(\.id) == [ScanPlanner.selectedAlbumsID])
        #expect(albums.first?.scope.albumIDs == ["a"])
    }

    @Test func batchStateTracksRemainingWork() {
        let segments = ["a", "b", "c"].map { ScanSegment(id: $0, title: $0, scope: ScanScope()) }
        var state = BatchScanState(segments: segments)

        #expect(state.pendingSegments.map(\.id) == ["a", "b", "c"])
        #expect(!state.isComplete)
        #expect(state.isMultiSegment)

        state.completedSegmentIDs.insert("a")
        state.activeSegmentID = "b"
        #expect(state.completedCount == 1)
        #expect(state.activePosition == 2)
        #expect(state.pendingSegments.map(\.id) == ["b", "c"])

        state.completedSegmentIDs.formUnion(["b", "c"])
        #expect(state.isComplete)
    }

    // MARK: - Reusing earlier work

    @Test func cachedWorkIsReusedOnlyWhileTheAssetAndMatcherAreUnchanged() {
        var asset = snapshot(id: "one", captureDate: date(2024, 7, 15))
        asset.resources[0].sha256 = nil
        let record = FingerprintRecord(
            id: "one",
            modificationDate: asset.modificationDate,
            fingerprint: MediaFingerprint(contentDigest: "digest", perceptualHash: 42),
            resourceHashes: ["photo|one.jpg|0": .init(sha256: "abc", byteCount: 99)]
        )

        var unchanged = asset
        let reusedUnchanged = unchanged.applyCachedWork(record)
        #expect(reusedUnchanged)
        #expect(unchanged.fingerprint?.perceptualHash == 42)
        #expect(unchanged.resources[0].sha256 == "abc")
        #expect(unchanged.resources[0].byteCount == 99)

        var editedInPhotos = asset
        editedInPhotos.modificationDate = Date(timeIntervalSince1970: 777)
        let reusedEdited = editedInPhotos.applyCachedWork(record)
        #expect(!reusedEdited)
        #expect(editedInPhotos.fingerprint == nil)

        var stale = asset
        var staleRecord = record
        staleRecord.matcherVersion = MediaFingerprint.matcherVersion - 1
        let reusedStale = stale.applyCachedWork(staleRecord)
        #expect(!reusedStale)
        #expect(stale.fingerprint == nil)
    }

    @Test func fingerprintCacheAppendsInsteadOfRewritingWhatIsAlreadyStored() throws {
        let url = temporaryDirectory().appendingPathComponent("fingerprints.jsonl")
        let cache = AppendingFingerprintCache(url: url)

        try cache.upsert([record(id: "one", hash: 1)])
        let afterFirst = try Data(contentsOf: url)
        try cache.upsert([record(id: "two", hash: 2), record(id: "three", hash: 3)])
        let afterSecond = try Data(contentsOf: url)

        // Growing without touching earlier bytes is the whole point: rewriting the
        // store on every flush is what made whole-library scans quadratic.
        #expect(afterSecond.count > afterFirst.count)
        #expect(afterSecond.prefix(afterFirst.count) == afterFirst)

        let all = try cache.records(for: ["one", "two", "three"])
        #expect(all.count == 3)
        #expect(all["two"]?.fingerprint?.perceptualHash == 2)
        #expect(try cache.records(for: ["two"]).keys.sorted() == ["two"])
        #expect(try cache.records(for: ["missing"]).isEmpty)
    }

    @Test func rewritingAnAssetSupersedesItsEarlierRecord() throws {
        let url = temporaryDirectory().appendingPathComponent("fingerprints.jsonl")
        let cache = AppendingFingerprintCache(url: url)

        try cache.upsert([record(id: "one", hash: 1)])
        try cache.upsert([record(id: "one", hash: 2)])

        #expect(try cache.records(for: ["one"])["one"]?.fingerprint?.perceptualHash == 2)
    }

    @Test func cacheCompactsAwaySupersededLinesWithoutLosingTheNewestValues() throws {
        let url = temporaryDirectory().appendingPathComponent("fingerprints.jsonl")
        let cache = AppendingFingerprintCache(url: url, compactionSlack: 0)

        for generation in 1...6 {
            try cache.upsert([record(id: "one", hash: UInt64(generation)), record(id: "two", hash: UInt64(100 + generation))])
        }
        let beforeCompaction = try Data(contentsOf: url).count
        #expect(lineCount(of: url) == 12)

        // Reading is what notices the store has drifted and folds it back down.
        _ = try cache.records(for: ["one"])

        #expect(lineCount(of: url) == 2)
        #expect(try Data(contentsOf: url).count < beforeCompaction)
        let reloaded = try cache.records(for: ["one", "two"])
        #expect(reloaded["one"]?.fingerprint?.perceptualHash == 6)
        #expect(reloaded["two"]?.fingerprint?.perceptualHash == 106)
    }

    @Test func clearingTheCacheRemovesEverything() throws {
        let url = temporaryDirectory().appendingPathComponent("fingerprints.jsonl")
        let cache = AppendingFingerprintCache(url: url)
        try cache.upsert([record(id: "one", hash: 1)])
        try cache.clear()
        #expect(try cache.records(for: ["one"]).isEmpty)
        try cache.clear()
    }

    // MARK: - Matching at scale

    @Test func binaryIdenticalCopiesStayBinaryExactEvenWhenAlsoVisuallySimilar() throws {
        let matcher = ConservativeDuplicateMatcher(fingerprinting: StubFingerprinter())
        let fingerprint = MediaFingerprint(
            contentDigest: "same",
            perceptualHash: 0x2222,
            normalizedLuma: [UInt8](repeating: 120, count: 1_024)
        )
        var first = snapshot(id: "one", captureDate: nil, sha256: "identical")
        var second = snapshot(id: "two", captureDate: nil, sha256: "identical")
        var third = snapshot(id: "three", captureDate: nil, sha256: "identical")
        first.fingerprint = fingerprint
        second.fingerprint = fingerprint
        third.fingerprint = fingerprint

        let groups = try matcher.groups(in: [first, second, third])

        #expect(groups.count == 1)
        #expect(groups.first?.confidence == .binaryExact)
        #expect(groups.first?.assets.count == 3)
    }

    @Test func aspectRatioSweepStillComparesPairsSittingOnTheTolerance() throws {
        let matcher = ConservativeDuplicateMatcher(fingerprinting: StubFingerprinter())
        let fingerprint = MediaFingerprint(
            contentDigest: nil,
            perceptualHash: 0x3333,
            normalizedLuma: [UInt8](repeating: 120, count: 1_024)
        )
        var narrow = snapshot(id: "narrow", captureDate: nil)
        narrow.pixelWidth = 4_000
        narrow.pixelHeight = 3_000
        narrow.fingerprint = fingerprint

        // Just inside the one percent aspect tolerance.
        var justInside = snapshot(id: "inside", captureDate: nil)
        justInside.pixelWidth = 4_030
        justInside.pixelHeight = 3_000
        justInside.fingerprint = fingerprint

        // Comfortably outside it.
        var outside = snapshot(id: "outside", captureDate: nil)
        outside.pixelWidth = 4_400
        outside.pixelHeight = 3_000
        outside.fingerprint = fingerprint

        #expect(try matcher.groups(in: [narrow, justInside]).count == 1)
        #expect(try matcher.groups(in: [narrow, outside]).isEmpty)
    }

    @Test func differingAspectRatiosArePrunedWithoutBurningTheComparisonBudget() throws {
        // All 2000 assets share one perceptual hash, so they all land in the same
        // locality buckets. Comparing every pair would be about 1,999,000 comparisons;
        // sweeping each bucket in aspect-ratio order should only compare within each of
        // the 40 shape classes, roughly 49,000.
        let shapeClasses = 40
        let copiesPerClass = 50
        let assets = (0..<shapeClasses).flatMap { shape -> [AssetSnapshot] in
            let width = Int((1_000.0 * pow(1.03, Double(shape))).rounded())
            return (0..<copiesPerClass).map { copy -> AssetSnapshot in
                var asset = snapshot(id: "shape\(shape)-copy\(copy)", captureDate: nil)
                asset.pixelWidth = width
                asset.pixelHeight = 1_000
                asset.fingerprint = MediaFingerprint(
                    contentDigest: "shape-\(shape)",
                    perceptualHash: 0x4444,
                    normalizedLuma: [UInt8](repeating: 120, count: 1_024)
                )
                return asset
            }
        }
        let matcher = ConservativeDuplicateMatcher(fingerprinting: StubFingerprinter(), comparisonBudget: 200_000)

        let result = try matcher.match(in: assets)

        #expect(result.groups.count == shapeClasses)
        #expect(result.groups.allSatisfy { $0.assets.count == copiesPerClass })
        #expect(!result.comparisonBudgetExhausted)
    }

    @Test func exhaustingTheComparisonBudgetIsReportedRatherThanHidden() throws {
        let fingerprint = MediaFingerprint(perceptualHash: 0x5555, normalizedLuma: [UInt8](repeating: 120, count: 1_024))
        let assets = (0..<1_200).map { index -> AssetSnapshot in
            var asset = snapshot(id: "asset-\(index)", captureDate: nil)
            asset.fingerprint = fingerprint
            return asset
        }
        let matcher = ConservativeDuplicateMatcher(fingerprinting: StubFingerprinter(), comparisonBudget: 500)

        let result = try matcher.match(in: assets)

        #expect(result.comparisonBudgetExhausted)
    }

    // MARK: - Scanning

    @Test @MainActor func monthScopeScansOneBatchPerMonthAndReportsRealTotals() async throws {
        let library = ScriptedLibrary(assets: [
            snapshot(id: "jul-a", captureDate: date(2024, 7, 15)),
            snapshot(id: "jul-b", captureDate: date(2024, 7, 15)),
            snapshot(id: "jul-solo", captureDate: date(2024, 7, 16)),
            snapshot(id: "jun-a", captureDate: date(2024, 6, 10)),
            snapshot(id: "jun-b", captureDate: date(2024, 6, 10)),
            snapshot(id: "may-solo", captureDate: date(2024, 5, 4))
        ])
        let model = makeModel(library: library, contentKeys: [
            "jul-a": "sunset", "jul-b": "sunset",
            "jun-a": "beach", "jun-b": "beach"
        ])
        var recorded: [ScanProgress?] = []
        let observer = model.$progress.sink { recorded.append($0) }
        defer { observer.cancel() }

        model.loadMonths()
        try await settle { !model.months.isEmpty }
        #expect(model.months.map(\.id) == ["2024-07", "2024-06", "2024-05"])
        #expect(model.months.map(\.assetCount) == [3, 2, 1])

        model.scope.kind = .months
        model.selectAllMonths()
        #expect(model.selectedMonthAssetCount == 6)

        model.startScan()
        try await settle { model.state == .review }

        #expect(model.batch?.segments.map(\.id) == ["2024-07", "2024-06", "2024-05"])
        #expect(model.batch?.isComplete == true)
        #expect(model.proposals.count == 2)
        #expect(Set(model.proposals.flatMap { [$0.keeper.id] + $0.donors.map(\.id) }) == ["jul-a", "jul-b", "jun-a", "jun-b"])

        // One fetch per month, each narrowed to that month's capture window.
        let monthFetches = library.identifierScopes.filter { $0.monthIDs.count == 1 }
        #expect(monthFetches.map { $0.monthIDs.first } == ["2024-07", "2024-06", "2024-05"])
        #expect(monthFetches.allSatisfy { $0.captureFilter != nil })

        // Progress must describe the batch and count real assets, not a placeholder total.
        #expect(recorded.contains { $0?.batchLabel == "Batch 1 of 3 · \(model.months[0].title)" })
        #expect(recorded.contains { $0?.phase == .thumbnails && $0?.total == 3 })
        #expect(recorded.contains { $0?.phase == .thumbnails && $0?.total == 2 })
        #expect(model.progress == nil)
    }

    @Test @MainActor func wholeLibraryScanReportsRealTotalsForEveryPhase() async throws {
        let assets = (0..<40).map { snapshot(id: "asset-\($0)", captureDate: date(2024, 7, 15)) }
        var contentKeys: [String: String] = [:]
        for index in assets.indices { contentKeys["asset-\(index)"] = "scene-\(index / 2)" }
        let library = ScriptedLibrary(assets: assets)
        let model = makeModel(library: library, contentKeys: contentKeys)

        var recorded: [ScanProgress] = []
        let observer = model.$progress.compactMap { $0 }.sink { recorded.append($0) }
        defer { observer.cancel() }

        #expect(model.scope.kind == .entireLibrary)
        model.startScan()
        try await settle { model.state == .review }

        #expect(model.proposals.count == 20)
        #expect(model.batch?.segments.map(\.id) == [ScanPlanner.entireLibraryID])

        // The original complaint was a whole-library scan that looked stuck. Each phase
        // has to publish the real denominator and climb all the way to it.
        for phase in [ScanProgress.Phase.inventory, .thumbnails, .confirming] {
            let updates = recorded.filter { $0.phase == phase }
            #expect(updates.contains { $0.total == assets.count }, "\(phase) never reported the real total")
            #expect(updates.contains { $0.completed == assets.count }, "\(phase) never finished counting")
        }
        #expect(recorded.allSatisfy { $0.completed <= $0.total })
        #expect(recorded.allSatisfy { $0.batchLabel == nil })
        #expect(model.progress == nil)
    }

    @Test @MainActor func rescanningReusesCachedFingerprintsInsteadOfRedoingThem() async throws {
        let root = temporaryDirectory()
        let library = ScriptedLibrary(assets: [
            snapshot(id: "jul-a", captureDate: date(2024, 7, 15)),
            snapshot(id: "jul-b", captureDate: date(2024, 7, 15))
        ])
        let fingerprinter = CountingFingerprinter(contentKeys: ["jul-a": "sunset", "jul-b": "sunset"])
        let model = CleanerAppModel(
            library: library,
            fingerprinting: fingerprinter,
            cache: AppendingFingerprintCache(url: root.appendingPathComponent("fingerprints.jsonl")),
            journal: JSONJournalStore(url: root.appendingPathComponent("journal.json")),
            reviewSessionStore: JSONReviewSessionStore(url: root.appendingPathComponent("review.json"))
        )

        model.startScan()
        try await settle { model.state == .review }
        #expect(model.proposals.count == 1)
        #expect(fingerprinter.callCount == 2)

        // Reaching the fetch log and then landing back in review only both hold once the
        // second scan has actually run, so this cannot observe the first one.
        library.resetFetchLog()
        model.startScan()
        try await settle { model.state == .review && !library.identifierScopes.isEmpty }

        #expect(model.proposals.count == 1)
        #expect(fingerprinter.callCount == 2, "a rescan re-fingerprinted work it had already cached")
    }

    @Test @MainActor func cancellingABatchKeepsFinishedMonthsAndResumeSkipsThem() async throws {
        let library = ScriptedLibrary(assets: [
            snapshot(id: "jul-a", captureDate: date(2024, 7, 15)),
            snapshot(id: "jul-b", captureDate: date(2024, 7, 15)),
            snapshot(id: "jun-a", captureDate: date(2024, 6, 10)),
            snapshot(id: "jun-b", captureDate: date(2024, 6, 10)),
            snapshot(id: "may-a", captureDate: date(2024, 5, 4)),
            snapshot(id: "may-b", captureDate: date(2024, 5, 4))
        ])
        let model = makeModel(library: library, contentKeys: [
            "jul-a": "sunset", "jul-b": "sunset",
            "jun-a": "beach", "jun-b": "beach",
            "may-a": "snow", "may-b": "snow"
        ])

        model.loadMonths()
        try await settle { model.months.count == 3 }
        model.scope.kind = .months
        model.selectAllMonths()

        library.blockIdentifierFetch(forMonth: "2024-06")
        model.startScan()
        try await settle { library.isBlocked }

        model.cancelScan()
        library.releaseBlockedFetch()
        try await settle { model.state != .scanning }

        #expect(model.batch?.completedSegmentIDs == ["2024-07"])
        #expect(model.proposals.count == 1)
        #expect(model.canResumeScan)
        #expect(model.remainingSegmentCount == 2)

        library.resetFetchLog()
        model.resumeScan()
        try await settle { model.state == .review && model.batch?.isComplete == true }

        #expect(model.proposals.count == 3)
        // July was already compared, so resuming must not fetch it again.
        let resumedMonths = library.identifierScopes.filter { $0.monthIDs.count == 1 }.compactMap { $0.monthIDs.first }
        #expect(resumedMonths == ["2024-06", "2024-05"])
    }

    @Test @MainActor func aChangeMidBatchKeepsFinishedGroupsButStillBlocksCleanup() async throws {
        let library = ScriptedLibrary(assets: [
            snapshot(id: "jul-a", captureDate: date(2024, 7, 15)),
            snapshot(id: "jul-b", captureDate: date(2024, 7, 15)),
            snapshot(id: "jun-a", captureDate: date(2024, 6, 10)),
            snapshot(id: "jun-b", captureDate: date(2024, 6, 10))
        ])
        let model = makeModel(library: library, contentKeys: [
            "jul-a": "sunset", "jul-b": "sunset",
            "jun-a": "beach", "jun-b": "beach"
        ])

        model.loadMonths()
        try await settle { model.months.count == 2 }
        model.scope.kind = .months
        model.selectAllMonths()

        // July is compared and persisted, then Photos changes while June is being read.
        library.blockIdentifierFetch(forMonth: "2024-06")
        model.startScan()
        try await settle { library.isBlocked }
        #expect(model.batch?.completedSegmentIDs == ["2024-07"])

        await library.notifyChange()
        library.releaseBlockedFetch()
        try await settle { model.state != .scanning }

        // Finishing a batch must not look like verifying the library: July's groups are
        // kept for review, but cleanup stays blocked until a fresh scan agrees.
        #expect(model.proposals.count == 1)
        #expect(model.state == .review)
        #expect(model.libraryResultsAreStale)
        #expect(model.showingLibraryChangeRescanPrompt)

        model.applyApproved()
        #expect(model.state == .review)
        #expect(model.journalEntries.isEmpty)
    }

    @Test @MainActor func assetsPhotosCannotProduceAreSkippedRatherThanFailingTheScan() async throws {
        let library = ScriptedLibrary(assets: [
            snapshot(id: "good-a", captureDate: date(2024, 7, 15)),
            snapshot(id: "good-b", captureDate: date(2024, 7, 15)),
            snapshot(id: "still-in-icloud", captureDate: date(2024, 7, 16))
        ])
        library.unreadableIDs = ["still-in-icloud"]
        let model = makeModel(library: library, contentKeys: ["good-a": "sunset", "good-b": "sunset"])

        model.startScan()
        try await settle { model.state == .review }

        #expect(model.proposals.count == 1)
        #expect(model.scanNotices.contains { $0.contains("could not be read") })
    }

    @Test @MainActor func selectingNoMonthsIsReportedInsteadOfScanningEverything() async throws {
        let library = ScriptedLibrary(assets: [snapshot(id: "jul-a", captureDate: date(2024, 7, 15))])
        let model = makeModel(library: library, contentKeys: [:])

        model.loadMonths()
        try await settle { !model.months.isEmpty }
        model.scope.kind = .months
        model.clearSelectedMonths()

        #expect(model.scanScopeIsEmpty)
        model.startScan()
        try await settle {
            if case .failed = model.state { return true }
            return false
        }
        guard case .failed(let message) = model.state else {
            Issue.record("A month scan with nothing selected should report why it cannot run.")
            return
        }
        #expect(message.contains("at least one month"))
    }

    @Test @MainActor func savedSessionRestoresMonthsAndUnfinishedBatchAcrossLaunches() async throws {
        let root = temporaryDirectory()
        let store = JSONReviewSessionStore(url: root.appendingPathComponent("review.json"))
        let months = MonthBucketing.buckets(forCaptureDates: [date(2024, 7, 15), date(2024, 6, 15)], calendar: .current)
        let segments = ScanPlanner.segments(
            for: ScanScope(kind: .months, monthIDs: Set(months.map(\.id))),
            months: months
        )
        var batch = BatchScanState(segments: segments)
        batch.completedSegmentIDs = [segments[0].id]
        try store.save(.init(
            savedAt: Date(),
            lastScanDate: Date(),
            scope: ScanScope(kind: .months, monthIDs: Set(months.map(\.id))),
            proposals: [],
            libraryRevision: "revision",
            batch: batch,
            months: months
        ))

        let model = CleanerAppModel(
            library: ScriptedLibrary(assets: []),
            fingerprinting: StubFingerprinter(),
            cache: AppendingFingerprintCache(url: root.appendingPathComponent("fingerprints.jsonl")),
            journal: JSONJournalStore(url: root.appendingPathComponent("journal.json")),
            reviewSessionStore: store
        )

        #expect(model.months.map(\.id) == months.map(\.id))
        #expect(model.scope.kind == .months)
        #expect(model.canResumeScan)
        #expect(model.completedSegmentCount == 1)
        #expect(model.remainingSegmentCount == 1)
    }

    @Test @MainActor func fingerprintsAreNotCarriedInRememberedResults() async throws {
        let root = temporaryDirectory()
        let store = JSONReviewSessionStore(url: root.appendingPathComponent("review.json"))
        let library = ScriptedLibrary(assets: [
            snapshot(id: "jul-a", captureDate: date(2024, 7, 15)),
            snapshot(id: "jul-b", captureDate: date(2024, 7, 15))
        ])
        let model = CleanerAppModel(
            library: library,
            fingerprinting: ScriptedFingerprinter(contentKeys: ["jul-a": "sunset", "jul-b": "sunset"]),
            cache: AppendingFingerprintCache(url: root.appendingPathComponent("fingerprints.jsonl")),
            journal: JSONJournalStore(url: root.appendingPathComponent("journal.json")),
            reviewSessionStore: store
        )

        model.startScan()
        try await settle { model.state == .review }

        #expect(model.proposals.count == 1)
        let saved = try #require(try store.load())
        let savedAssets = saved.proposals.flatMap { [$0.keeper] + $0.donors }
        #expect(!savedAssets.isEmpty)
        #expect(savedAssets.allSatisfy { $0.fingerprint == nil })
        #expect(model.proposals.allSatisfy { $0.keeper.fingerprint == nil })
    }

    // MARK: - Helpers

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    @MainActor
    private func makeModel(library: ScriptedLibrary, contentKeys: [String: String]) -> CleanerAppModel {
        let root = temporaryDirectory()
        return CleanerAppModel(
            library: library,
            fingerprinting: ScriptedFingerprinter(contentKeys: contentKeys),
            cache: AppendingFingerprintCache(url: root.appendingPathComponent("fingerprints.jsonl")),
            journal: JSONJournalStore(url: root.appendingPathComponent("journal.json")),
            reviewSessionStore: JSONReviewSessionStore(url: root.appendingPathComponent("review.json"))
        )
    }

    /// Waits for main-actor state to reach a condition rather than sleeping for a
    /// guessed duration, so the scanning tests stay deterministic.
    @MainActor
    private func settle(
        timeout: Duration = .seconds(10),
        until condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for the expected state.")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func lineCount(of url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return data.filter { $0 == 0x0a }.count
    }

    private func record(id: String, hash: UInt64) -> FingerprintRecord {
        FingerprintRecord(
            id: id,
            modificationDate: Date(timeIntervalSince1970: 100),
            fingerprint: MediaFingerprint(perceptualHash: hash)
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date? {
        Self.utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))
    }

    private func snapshot(id: String, captureDate: Date?, sha256: String? = nil) -> AssetSnapshot {
        AssetSnapshot(
            id: id,
            mediaKind: .image,
            originalFilename: "\(id).jpg",
            contentType: "public.jpeg",
            pixelWidth: 4_000,
            pixelHeight: 3_000,
            duration: 0,
            creationDate: captureDate,
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
                pixelWidth: 4_000, pixelHeight: 3_000, byteCount: 1_000, sha256: sha256
            )],
            fingerprint: nil
        )
    }
}

/// Derives fingerprints from a declared content key, so tests can say which assets are
/// meant to be copies of each other without needing real pixels.
private struct ScriptedFingerprinter: Fingerprinting {
    let contentKeys: [String: String]

    func fingerprint(asset: AssetSnapshot, images: [NSImage]) async throws -> MediaFingerprint {
        let key = contentKeys[asset.id] ?? asset.id
        return MediaFingerprint(
            contentDigest: key,
            perceptualHash: Self.hash(of: key),
            normalizedLuma: [UInt8](repeating: 120, count: 1_024)
        )
    }

    func visionFeature(from fingerprint: MediaFingerprint) -> VisionFeature? { nil }
    func distance(_ lhs: VisionFeature, _ rhs: VisionFeature) -> Float? { nil }

    private static func hash(of key: String) -> UInt64 {
        SHA256.hash(data: Data(key.utf8)).withUnsafeBytes { $0.load(as: UInt64.self) }
    }
}

/// Counts how often real fingerprinting work was requested, so a rescan can be shown to
/// reuse what it already computed rather than paying for it twice.
private final class CountingFingerprinter: Fingerprinting, @unchecked Sendable {
    private let inner: ScriptedFingerprinter
    private let lock = NSLock()
    private var calls = 0

    init(contentKeys: [String: String]) {
        inner = ScriptedFingerprinter(contentKeys: contentKeys)
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func fingerprint(asset: AssetSnapshot, images: [NSImage]) async throws -> MediaFingerprint {
        countCall()
        return try await inner.fingerprint(asset: asset, images: images)
    }

    private func countCall() {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
    }

    func visionFeature(from fingerprint: MediaFingerprint) -> VisionFeature? { nil }
    func distance(_ lhs: VisionFeature, _ rhs: VisionFeature) -> Float? { nil }
}

/// A Photos stand-in that honours scan scopes, can stall a specific batch, and records
/// what it was asked for.
private final class ScriptedLibrary: PhotoLibraryClient, @unchecked Sendable {
    var assets: [AssetSnapshot]
    var unreadableIDs: Set<String> = []

    private let lock = NSLock()
    private var fetchLog: [ScanScope] = []
    private var blockedMonthID: String?
    private var blockedContinuations: [CheckedContinuation<Void, Never>] = []
    private var didReachBlockedFetch = false
    private var changeHandler: (@Sendable () -> Void)?

    init(assets: [AssetSnapshot]) {
        self.assets = assets
    }

    var identifierScopes: [ScanScope] {
        lock.lock()
        defer { lock.unlock() }
        return fetchLog
    }

    var isBlocked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didReachBlockedFetch
    }

    func blockIdentifierFetch(forMonth monthID: String) {
        lock.lock()
        blockedMonthID = monthID
        didReachBlockedFetch = false
        lock.unlock()
    }

    func releaseBlockedFetch() {
        lock.lock()
        blockedMonthID = nil
        let waiting = blockedContinuations
        blockedContinuations = []
        lock.unlock()
        for continuation in waiting { continuation.resume() }
    }

    func resetFetchLog() {
        lock.lock()
        fetchLog = []
        lock.unlock()
    }

    /// Fires the change observer and waits for its main-actor hop to land, so a test can
    /// place a Photos change at a chosen point in a scan.
    @MainActor func notifyChange() async {
        currentChangeHandler()?()
        await Task.yield()
    }

    private func currentChangeHandler() -> (@Sendable () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return changeHandler
    }

    func authorizationStatus() -> PhotoLibraryAccess { .authorized }
    func requestAuthorization() async -> PhotoLibraryAccess { .authorized }
    func fetchAlbums() async throws -> [AlbumReference] { [] }

    func fetchAssetIdentifiers(scope: ScanScope) async throws -> [String] {
        if recordFetchAndReportWhetherBlocked(scope) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                enqueueOrResume(continuation)
            }
        }
        return matching(scope: scope).map(\.id)
    }

    private func recordFetchAndReportWhetherBlocked(_ scope: ScanScope) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        fetchLog.append(scope)
        let shouldBlock = scope.monthIDs.count == 1 && scope.monthIDs.first == blockedMonthID
        if shouldBlock { didReachBlockedFetch = true }
        return shouldBlock
    }

    private func enqueueOrResume(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        guard blockedMonthID != nil else {
            lock.unlock()
            continuation.resume()
            return
        }
        blockedContinuations.append(continuation)
        lock.unlock()
    }

    func fetchSnapshots(ids: [String]) async throws -> [AssetSnapshot] {
        let wanted = Set(ids)
        return assets.filter { wanted.contains($0.id) }
    }

    func fetchMonthBuckets() async throws -> [MonthBucket] {
        MonthBucketing.buckets(forCaptureDates: assets.map(\.creationDate))
    }

    func fetchRevisionTokens(scope: ScanScope) async throws -> [AssetRevisionToken] {
        LibraryRevision.tokens(for: matching(scope: scope))
    }

    func thumbnail(assetID: String, targetSize: CGSize, networkAccessAllowed: Bool) async throws -> NSImage {
        guard !unreadableIDs.contains(assetID) else { throw CleanerError.assetUnavailable(assetID) }
        return NSImage(size: NSSize(width: 4, height: 4))
    }

    func videoPlayerItem(assetID: String) async throws -> AVPlayerItem {
        throw CleanerError.assetUnavailable(assetID)
    }

    func videoFrames(assetID: String) async throws -> [NSImage] {
        guard !unreadableIDs.contains(assetID) else { throw CleanerError.assetUnavailable(assetID) }
        return [NSImage(size: NSSize(width: 4, height: 4))]
    }

    func updateOriginalHashes(for asset: AssetSnapshot) async throws -> AssetSnapshot {
        guard !unreadableIDs.contains(asset.id) else { throw CleanerError.assetUnavailable(asset.id) }
        return asset
    }

    func apply(proposals: [MergeProposal]) async throws { }
    func restoreKeeperMetadata(from entries: [CleanupJournalEntry]) async throws { }

    func startObservingChanges(scope: ScanScope, handler: @escaping @Sendable () -> Void) throws {
        lock.lock()
        changeHandler = handler
        lock.unlock()
    }

    private func matching(scope: ScanScope) -> [AssetSnapshot] {
        assets.filter { asset in
            switch scope.captureFilter {
            case .window(let start, let end):
                guard let captured = asset.creationDate else { return false }
                return captured >= start && captured < end
            case .undated:
                return asset.creationDate == nil
            case nil:
                return true
            }
        }
    }
}
