import Foundation
import Vision

final class ConservativeDuplicateMatcher: DuplicateMatcher {
    static let imageAspectTolerance = 0.01
    static let imageHashDistance = 6
    static let imageFeatureDistance: Float = 0.15
    static let imageSimilarity = 0.985
    static let videoDurationFraction = 0.005
    static let videoDurationSeconds = 0.25
    static let videoFrameMaxDistance = 8
    static let videoFrameMeanDistance = 5.0

    private let fingerprinting: Fingerprinting

    init(fingerprinting: Fingerprinting) {
        self.fingerprinting = fingerprinting
    }

    func groups(in assets: [AssetSnapshot]) -> [DuplicateGroup] {
        var edges: [(Int, Int, MatchConfidence, [String])] = []
        var seenPairs = Set<String>()

        let binaryBuckets = Dictionary(grouping: assets.indices.filter { assets[$0].binarySignature != nil }) {
            assets[$0].binarySignature!
        }
        for indices in binaryBuckets.values where indices.count > 1 {
            addAllPairs(indices, assets: assets, seen: &seenPairs, edges: &edges, forced: .binaryExact)
        }

        var localityBuckets: [String: [Int]] = [:]
        for index in assets.indices {
            guard let hash = assets[index].fingerprint?.perceptualHash else { continue }
            for band in 0..<4 {
                let value = (hash >> UInt64(band * 16)) & 0xffff
                let durationBucket = assets[index].mediaKind == .video
                    ? Int((assets[index].duration / 0.25).rounded())
                    : 0
                let durationBuckets = assets[index].mediaKind == .video
                    ? [durationBucket - 1, durationBucket, durationBucket + 1]
                    : [0]
                for bucket in durationBuckets {
                    let key = "\(assets[index].mediaKind.rawValue):\(band):\(value):\(bucket)"
                    localityBuckets[key, default: []].append(index)
                }
            }
        }

        for indices in localityBuckets.values where indices.count > 1 {
            addAllPairs(indices, assets: assets, seen: &seenPairs, edges: &edges, forced: nil)
        }

        var union = UnionFind(count: assets.count)
        var edgeEvidence: [String: (MatchConfidence, [String])] = [:]
        for edge in edges {
            union.union(edge.0, edge.1)
            edgeEvidence[pairKey(edge.0, edge.1)] = (edge.2, edge.3)
        }

        let components = Dictionary(grouping: assets.indices, by: { union.find($0) })
        return components.values.compactMap { indices in
            guard indices.count > 1 else { return nil }
            let relevant = edges.filter { indices.contains($0.0) && indices.contains($0.1) }
            guard !relevant.isEmpty else { return nil }
            let confidence: MatchConfidence
            if relevant.allSatisfy({ $0.2 == .binaryExact }) {
                confidence = .binaryExact
            } else if relevant.allSatisfy({ $0.2 != .likelyVisual }) {
                confidence = .contentExact
            } else {
                confidence = .likelyVisual
            }
            return DuplicateGroup(
                id: UUID(),
                confidence: confidence,
                assets: indices.map { assets[$0] },
                evidence: Array(Set(relevant.flatMap(\.3))).sorted()
            )
        }.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence {
                return confidenceRank(lhs.confidence) < confidenceRank(rhs.confidence)
            }
            return lhs.assets.count > rhs.assets.count
        }
    }

    private func addAllPairs(
        _ indices: [Int],
        assets: [AssetSnapshot],
        seen: inout Set<String>,
        edges: inout [(Int, Int, MatchConfidence, [String])],
        forced: MatchConfidence?
    ) {
        for leftOffset in 0..<(indices.count - 1) {
            for rightOffset in (leftOffset + 1)..<indices.count {
                let left = indices[leftOffset]
                let right = indices[rightOffset]
                let key = pairKey(left, right)
                guard seen.insert(key).inserted else { continue }
                if let forced {
                    edges.append((left, right, forced, ["Original resource SHA-256 values match."]))
                } else if let match = classify(assets[left], assets[right]) {
                    edges.append((left, right, match.0, match.1))
                }
            }
        }
    }

    private func classify(_ lhs: AssetSnapshot, _ rhs: AssetSnapshot) -> (MatchConfidence, [String])? {
        guard lhs.mediaKind == rhs.mediaKind,
              lhs.aspectRatio > 0,
              abs(lhs.aspectRatio - rhs.aspectRatio) / max(lhs.aspectRatio, rhs.aspectRatio) <= Self.imageAspectTolerance,
              let leftFingerprint = lhs.fingerprint,
              let rightFingerprint = rhs.fingerprint,
              let leftHash = leftFingerprint.perceptualHash,
              let rightHash = rightFingerprint.perceptualHash else { return nil }

        if lhs.pixelWidth == rhs.pixelWidth,
           lhs.pixelHeight == rhs.pixelHeight,
           leftFingerprint.contentDigest != nil,
           leftFingerprint.contentDigest == rightFingerprint.contentDigest,
           lhs.mediaKind == .image {
            return (.contentExact, ["Normalized pixels and dimensions match."])
        }

        if lhs.mediaKind == .video {
            let allowedDuration = max(Self.videoDurationSeconds, max(lhs.duration, rhs.duration) * Self.videoDurationFraction)
            guard abs(lhs.duration - rhs.duration) <= allowedDuration,
                  leftFingerprint.videoFrameHashes.count == 3,
                  rightFingerprint.videoFrameHashes.count == 3 else { return nil }
            let distances = zip(leftFingerprint.videoFrameHashes, rightFingerprint.videoFrameHashes)
                .map { Self.hammingDistance($0, $1) }
            guard distances.max() ?? .max <= Self.videoFrameMaxDistance,
                  Double(distances.reduce(0, +)) / 3.0 <= Self.videoFrameMeanDistance else { return nil }
            return (.likelyVisual, ["Duration, aspect ratio, and sampled video frames closely match."])
        }

        let hamming = Self.hammingDistance(leftHash, rightHash)
        guard hamming <= Self.imageHashDistance,
              Self.lumaSimilarity(leftFingerprint.normalizedLuma, rightFingerprint.normalizedLuma) >= Self.imageSimilarity else {
            return nil
        }
        if let distance = fingerprinting.visionDistance(leftFingerprint, rightFingerprint),
           distance > Self.imageFeatureDistance {
            return nil
        }
        return (.likelyVisual, ["Aspect ratio, perceptual hash, Vision feature, and normalized image similarity agree."])
    }

    static func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    static func lumaSimilarity(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 0 }
        let mse = zip(lhs, rhs).reduce(0.0) { result, pair in
            let delta = Double(pair.0) - Double(pair.1)
            return result + delta * delta
        } / Double(lhs.count)
        return max(0, 1 - mse / (255 * 255))
    }

    private func pairKey(_ lhs: Int, _ rhs: Int) -> String {
        lhs < rhs ? "\(lhs):\(rhs)" : "\(rhs):\(lhs)"
    }

    private func confidenceRank(_ value: MatchConfidence) -> Int {
        switch value {
        case .binaryExact: return 0
        case .contentExact: return 1
        case .likelyVisual: return 2
        }
    }
}

private struct UnionFind {
    private var parents: [Int]

    init(count: Int) { parents = Array(0..<count) }

    mutating func find(_ value: Int) -> Int {
        if parents[value] != value { parents[value] = find(parents[value]) }
        return parents[value]
    }

    mutating func union(_ lhs: Int, _ rhs: Int) {
        let leftRoot = find(lhs)
        let rightRoot = find(rhs)
        if leftRoot != rightRoot { parents[rightRoot] = leftRoot }
    }
}
