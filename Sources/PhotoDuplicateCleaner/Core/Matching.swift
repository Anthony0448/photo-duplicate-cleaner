import Foundation
import Vision

/// Outcome of one matching pass.
struct MatchResult: Sendable {
    var groups: [DuplicateGroup]
    /// True when the comparison budget ran out before every candidate pair was
    /// examined. The groups found are still valid; there may simply be more.
    var comparisonBudgetExhausted: Bool = false
}

final class ConservativeDuplicateMatcher: DuplicateMatcher {
    static let imageAspectTolerance = 0.01
    static let imageHashDistance = 6
    static let imageFeatureDistance: Float = 0.15
    static let imageSimilarity = 0.985
    static let videoDurationFraction = 0.005
    static let videoDurationSeconds = 0.25
    static let videoFrameMaxDistance = 8
    static let videoFrameMeanDistance = 5.0

    /// Ceiling on candidate comparisons for one pass. Libraries with very large runs
    /// of near-identical frames (burst shots, flat colour screenshots) can otherwise
    /// generate pairs quadratically and never finish. Hitting the ceiling is reported
    /// rather than hidden so the scan can suggest smaller batches.
    static let defaultComparisonBudget = 40_000_000

    private let fingerprinting: Fingerprinting
    private let comparisonBudget: Int

    init(fingerprinting: Fingerprinting, comparisonBudget: Int = ConservativeDuplicateMatcher.defaultComparisonBudget) {
        self.fingerprinting = fingerprinting
        self.comparisonBudget = comparisonBudget
    }

    func match(in assets: [AssetSnapshot]) throws -> MatchResult {
        var context = MatchContext(assets: assets, fingerprinting: fingerprinting, remainingComparisons: comparisonBudget)

        let binaryBuckets = Dictionary(grouping: assets.indices.filter { assets[$0].binarySignature != nil }) {
            assets[$0].binarySignature!
        }
        var binaryGroupID: Int32 = 0
        for indices in binaryBuckets.values where indices.count > 1 {
            try context.linkBinaryBucket(indices, groupID: binaryGroupID)
            binaryGroupID += 1
        }

        var localityBuckets: [LocalityKey: [Int]] = [:]
        for index in assets.indices {
            guard let hash = assets[index].fingerprint?.perceptualHash else { continue }
            for band in 0..<4 {
                let value = UInt16(truncatingIfNeeded: hash >> UInt64(band * 16))
                localityBuckets[LocalityKey(kind: assets[index].mediaKind, band: UInt8(band), value: value), default: []].append(index)
            }
        }

        for indices in localityBuckets.values where indices.count > 1 {
            try context.compareWithinAspectWindow(indices)
        }

        return MatchResult(groups: try context.groups(), comparisonBudgetExhausted: context.budgetExhausted)
    }

    static func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    static func videoDurationTolerance(_ lhs: Double, _ rhs: Double) -> Double {
        max(videoDurationSeconds, max(lhs, rhs) * videoDurationFraction)
    }

    static func videoDurationsMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        guard lhs.isFinite, rhs.isFinite, lhs > 0, rhs > 0 else { return false }
        return abs(lhs - rhs) <= videoDurationTolerance(lhs, rhs)
    }

    static func lumaSimilarity(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 0 }
        let mse = zip(lhs, rhs).reduce(0.0) { result, pair in
            let delta = Double(pair.0) - Double(pair.1)
            return result + delta * delta
        } / Double(lhs.count)
        return max(0, 1 - mse / (255 * 255))
    }
}

private struct LocalityKey: Hashable {
    var kind: MediaKind
    var band: UInt8
    var value: UInt16
}

private enum MatchEvidence: UInt8 {
    case binaryResourceHash
    case normalizedPixels
    case videoFrames
    case imageSimilarity

    var message: String {
        switch self {
        case .binaryResourceHash: return "Original resource SHA-256 values match."
        case .normalizedPixels: return "Normalized pixels and dimensions match."
        case .videoFrames: return "Sampled video frames, duration, and aspect ratio match."
        case .imageSimilarity: return "Aspect ratio, perceptual hash, Vision feature, and normalized image similarity agree."
        }
    }
}

private struct MatchEdge {
    var left: Int32
    var right: Int32
    var confidence: MatchConfidence
    var evidence: MatchEvidence
    /// Only populated where the evidence carries measured values worth showing.
    var detail: String?
}

/// Holds the mutable state of a single matching pass.
///
/// Edges store interned evidence rather than strings, and candidate pairs are found
/// by sweeping each bucket in aspect-ratio order, so a bucket costs
/// `O(k log k + pairs actually within tolerance)` instead of `O(k²)`.
private struct MatchContext {
    let assets: [AssetSnapshot]
    let fingerprinting: Fingerprinting
    var remainingComparisons: Int
    var budgetExhausted = false

    private var edges: [MatchEdge] = []
    private var seenPairs = Set<UInt64>()
    /// Which set of binary-identical originals each asset belongs to, or -1. Comparing
    /// two members of the same set again could only produce weaker evidence, so this
    /// lets those pairs be skipped in constant time rather than by recording every
    /// pair of a potentially large set.
    private var binaryGroupIDs: [Int32]
    /// Lazily decoded Vision feature prints, so an archive is unpacked at most once
    /// per asset instead of once per comparison it takes part in.
    private var decodedFeatures: [VisionFeature??]

    init(assets: [AssetSnapshot], fingerprinting: Fingerprinting, remainingComparisons: Int) {
        self.assets = assets
        self.fingerprinting = fingerprinting
        self.remainingComparisons = remainingComparisons
        self.binaryGroupIDs = Array(repeating: -1, count: assets.count)
        self.decodedFeatures = Array(repeating: nil, count: assets.count)
    }

    /// Links a set of assets whose original resource hashes are identical. Chaining is
    /// enough: the component and its confidence come out the same as linking every
    /// pair would give, without the quadratic edge count.
    mutating func linkBinaryBucket(_ indices: [Int], groupID: Int32) throws {
        try Task.checkCancellation()
        for index in indices { binaryGroupIDs[index] = groupID }
        for offset in 1..<indices.count {
            append(indices[offset - 1], indices[offset], .binaryExact, .binaryResourceHash, detail: nil)
        }
    }

    mutating func compareWithinAspectWindow(_ indices: [Int]) throws {
        let ordered = indices.sorted { assets[$0].aspectRatio < assets[$1].aspectRatio }
        for leftOffset in ordered.indices {
            try Task.checkCancellation()
            let left = ordered[leftOffset]
            let leftAspect = assets[left].aspectRatio
            guard leftAspect > 0 else { continue }
            // Sorted ascending, so `abs(l - r) / max(l, r) <= tolerance` fails for every
            // remaining member once this bound is passed.
            let upperBound = leftAspect / (1 - ConservativeDuplicateMatcher.imageAspectTolerance)

            var rightOffset = leftOffset + 1
            while rightOffset < ordered.count {
                let right = ordered[rightOffset]
                rightOffset += 1
                guard assets[right].aspectRatio <= upperBound else { break }
                let binaryGroup = binaryGroupIDs[left]
                guard binaryGroup < 0 || binaryGroup != binaryGroupIDs[right] else { continue }
                guard seenPairs.insert(Self.pairKey(left, right)).inserted else { continue }
                guard remainingComparisons > 0 else {
                    budgetExhausted = true
                    return
                }
                remainingComparisons -= 1
                if let match = classify(left, right) {
                    append(left, right, match.confidence, match.evidence, detail: match.detail)
                }
            }
        }
    }

    mutating func groups() throws -> [DuplicateGroup] {
        var union = UnionFind(count: assets.count)
        for edge in edges { union.union(Int(edge.left), Int(edge.right)) }

        var edgesByRoot: [Int: [MatchEdge]] = [:]
        for edge in edges { edgesByRoot[union.find(Int(edge.left)), default: []].append(edge) }

        var membersByRoot: [Int: [Int]] = [:]
        for index in assets.indices {
            let root = union.find(index)
            guard edgesByRoot[root] != nil else { continue }
            membersByRoot[root, default: []].append(index)
        }

        var results: [DuplicateGroup] = []
        for (root, indices) in membersByRoot {
            try Task.checkCancellation()
            guard indices.count > 1, let relevant = edgesByRoot[root], !relevant.isEmpty else { continue }
            let componentAssets = indices.map { assets[$0] }
            if componentAssets.first?.mediaKind == .video {
                let durations = componentAssets.map(\.duration)
                guard let shortest = durations.min(), let longest = durations.max(),
                      ConservativeDuplicateMatcher.videoDurationsMatch(shortest, longest) else { continue }
            }

            let confidence: MatchConfidence
            if relevant.allSatisfy({ $0.confidence == .binaryExact }) {
                confidence = .binaryExact
            } else if relevant.allSatisfy({ $0.confidence != .likelyVisual }) {
                confidence = .contentExact
            } else {
                confidence = .likelyVisual
            }

            let messages = relevant.map { $0.detail ?? $0.evidence.message }
            results.append(DuplicateGroup(
                id: UUID(),
                confidence: confidence,
                assets: componentAssets,
                evidence: Array(Set(messages)).sorted()
            ))
        }

        return results.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence {
                return Self.confidenceRank(lhs.confidence) < Self.confidenceRank(rhs.confidence)
            }
            if lhs.assets.count != rhs.assets.count { return lhs.assets.count > rhs.assets.count }
            return lhs.assets[0].id < rhs.assets[0].id
        }
    }

    private mutating func append(
        _ left: Int,
        _ right: Int,
        _ confidence: MatchConfidence,
        _ evidence: MatchEvidence,
        detail: String?
    ) {
        edges.append(MatchEdge(
            left: Int32(left),
            right: Int32(right),
            confidence: confidence,
            evidence: evidence,
            detail: detail
        ))
    }

    private mutating func classify(
        _ leftIndex: Int,
        _ rightIndex: Int
    ) -> (confidence: MatchConfidence, evidence: MatchEvidence, detail: String?)? {
        let lhs = assets[leftIndex]
        let rhs = assets[rightIndex]
        guard lhs.mediaKind == rhs.mediaKind,
              lhs.aspectRatio > 0,
              abs(lhs.aspectRatio - rhs.aspectRatio) / max(lhs.aspectRatio, rhs.aspectRatio) <= ConservativeDuplicateMatcher.imageAspectTolerance,
              let leftFingerprint = lhs.fingerprint,
              let rightFingerprint = rhs.fingerprint,
              let leftHash = leftFingerprint.perceptualHash,
              let rightHash = rightFingerprint.perceptualHash else { return nil }

        if lhs.pixelWidth == rhs.pixelWidth,
           lhs.pixelHeight == rhs.pixelHeight,
           leftFingerprint.contentDigest != nil,
           leftFingerprint.contentDigest == rightFingerprint.contentDigest,
           lhs.mediaKind == .image {
            return (.contentExact, .normalizedPixels, nil)
        }

        if lhs.mediaKind == .video {
            guard ConservativeDuplicateMatcher.videoDurationsMatch(lhs.duration, rhs.duration),
                  leftFingerprint.videoFrameHashes.count == 3,
                  rightFingerprint.videoFrameHashes.count == 3 else { return nil }
            let distances = zip(leftFingerprint.videoFrameHashes, rightFingerprint.videoFrameHashes)
                .map { ConservativeDuplicateMatcher.hammingDistance($0, $1) }
            guard distances.max() ?? .max <= ConservativeDuplicateMatcher.videoFrameMaxDistance,
                  Double(distances.reduce(0, +)) / 3.0 <= ConservativeDuplicateMatcher.videoFrameMeanDistance else { return nil }
            let delta = abs(lhs.duration - rhs.duration)
            let tolerance = ConservativeDuplicateMatcher.videoDurationTolerance(lhs.duration, rhs.duration)
            let detail = String(
                format: "Video durations differ by %.2fs (%.2fs vs %.2fs), within the %.2fs tolerance; aspect ratio and sampled frames also match.",
                delta, lhs.duration, rhs.duration, tolerance
            )
            return (.likelyVisual, .videoFrames, detail)
        }

        guard ConservativeDuplicateMatcher.hammingDistance(leftHash, rightHash) <= ConservativeDuplicateMatcher.imageHashDistance,
              ConservativeDuplicateMatcher.lumaSimilarity(leftFingerprint.normalizedLuma, rightFingerprint.normalizedLuma) >= ConservativeDuplicateMatcher.imageSimilarity else {
            return nil
        }
        if let left = feature(at: leftIndex), let right = feature(at: rightIndex),
           let distance = fingerprinting.distance(left, right),
           distance > ConservativeDuplicateMatcher.imageFeatureDistance {
            return nil
        }
        return (.likelyVisual, .imageSimilarity, nil)
    }

    private mutating func feature(at index: Int) -> VisionFeature? {
        if let cached = decodedFeatures[index] { return cached }
        let decoded = assets[index].fingerprint.flatMap { fingerprinting.visionFeature(from: $0) }
        decodedFeatures[index] = .some(decoded)
        return decoded
    }

    private static func pairKey(_ lhs: Int, _ rhs: Int) -> UInt64 {
        let low = UInt64(UInt32(truncatingIfNeeded: min(lhs, rhs)))
        let high = UInt64(UInt32(truncatingIfNeeded: max(lhs, rhs)))
        return high << 32 | low
    }

    private static func confidenceRank(_ value: MatchConfidence) -> Int {
        switch value {
        case .binaryExact: return 0
        case .contentExact: return 1
        case .likelyVisual: return 2
        }
    }
}

/// Iterative so that a long chain of matches cannot overflow the stack, and merged
/// by size so lookups stay near constant time on large components.
private struct UnionFind {
    private var parents: [Int]
    private var sizes: [Int]

    init(count: Int) {
        parents = Array(0..<count)
        sizes = Array(repeating: 1, count: count)
    }

    mutating func find(_ value: Int) -> Int {
        var root = value
        while parents[root] != root { root = parents[root] }
        var current = value
        while parents[current] != root {
            let next = parents[current]
            parents[current] = root
            current = next
        }
        return root
    }

    mutating func union(_ lhs: Int, _ rhs: Int) {
        var leftRoot = find(lhs)
        var rightRoot = find(rhs)
        guard leftRoot != rightRoot else { return }
        if sizes[leftRoot] < sizes[rightRoot] { swap(&leftRoot, &rightRoot) }
        parents[rightRoot] = leftRoot
        sizes[leftRoot] += sizes[rightRoot]
    }
}
