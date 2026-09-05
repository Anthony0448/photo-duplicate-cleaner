import AppKit
import CryptoKit
import Foundation
import Vision

/// A decoded Vision feature print, kept behind a reference so the matcher can hold on
/// to one per asset for the length of a pass.
final class VisionFeature: @unchecked Sendable {
    fileprivate let observation: VNFeaturePrintObservation

    fileprivate init(observation: VNFeaturePrintObservation) {
        self.observation = observation
    }
}

final class MediaFingerprinter: Fingerprinting {
    func fingerprint(asset: AssetSnapshot, images: [NSImage]) async throws -> MediaFingerprint {
        guard let primary = images.first, let primaryCGImage = primary.cleanerCGImage else {
            throw CleanerError.unsupportedMedia("Could not decode a representative image.")
        }

        return try await Task.detached(priority: .utility) {
            let normalized = try Self.normalizedLuma(primaryCGImage, width: 32, height: 32)
            let contentPixels = try Self.normalizedRGBA(primaryCGImage, width: 256, height: 256)
            let digest = SHA256.hash(data: contentPixels).map { String(format: "%02x", $0) }.joined()
            let featureData = try? Self.visionFeatureArchive(primaryCGImage)
            let frameHashes = try images.prefix(3).compactMap { image -> UInt64? in
                guard let cgImage = image.cleanerCGImage else { return nil }
                return try Self.differenceHash(cgImage)
            }

            return MediaFingerprint(
                contentDigest: digest,
                perceptualHash: try Self.differenceHash(primaryCGImage),
                normalizedLuma: normalized,
                visionFeatureArchive: featureData,
                videoFrameHashes: asset.mediaKind == .video ? frameHashes : []
            )
        }.value
    }

    func visionFeature(from fingerprint: MediaFingerprint) -> VisionFeature? {
        guard let archive = fingerprint.visionFeatureArchive,
              let observation = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: archive) else {
            return nil
        }
        return VisionFeature(observation: observation)
    }

    func distance(_ lhs: VisionFeature, _ rhs: VisionFeature) -> Float? {
        var distance: Float = 0
        do {
            try lhs.observation.computeDistance(&distance, to: rhs.observation)
            return distance
        } catch {
            return nil
        }
    }

    private static func visionFeatureArchive(_ image: CGImage) throws -> Data {
        let request = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw CleanerError.unsupportedMedia("Vision could not generate a feature print.")
        }
        return try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }

    private static func differenceHash(_ image: CGImage) throws -> UInt64 {
        let pixels = try normalizedLuma(image, width: 9, height: 8)
        var hash: UInt64 = 0
        for row in 0..<8 {
            for column in 0..<8 {
                hash <<= 1
                if pixels[row * 9 + column] > pixels[row * 9 + column + 1] { hash |= 1 }
            }
        }
        return hash
    }

    private static func normalizedLuma(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { throw CleanerError.unsupportedMedia("Could not create an image fingerprint context.") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private static func normalizedRGBA(_ image: CGImage, width: Int, height: Int) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CleanerError.unsupportedMedia("Could not normalize image pixels.") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Data(pixels)
    }
}

private extension NSImage {
    var cleanerCGImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
