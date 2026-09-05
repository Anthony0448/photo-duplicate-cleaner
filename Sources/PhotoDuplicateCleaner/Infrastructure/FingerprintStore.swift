import Foundation

/// Append-only store for the per-asset work a scan can reuse: fingerprints and
/// original-resource hashes.
///
/// The previous inventory cache re-encoded and rewrote every known asset on each
/// flush. A whole-library scan flushes thousands of times, so that made the cost of
/// scanning grow with the square of the library size and left large libraries
/// apparently frozen. Here a flush appends only the records in that batch, and
/// superseded lines are folded away by an occasional compaction.
///
/// Each line is a percent-encoded asset identifier, a tab, then the record JSON.
/// Keeping the identifier outside the JSON lets a read skip decoding records it does
/// not need, which matters when one month is being scanned out of a whole library.
final class AppendingFingerprintCache: FingerprintCache, @unchecked Sendable {
    private let url: URL
    private let compactionSlack: Int
    private let chunkSize: Int
    private let lock = NSLock()

    init(url: URL = AppStoragePaths.fingerprints, compactionSlack: Int = 512, chunkSize: Int = 1 << 20) {
        self.url = url
        self.compactionSlack = compactionSlack
        self.chunkSize = chunkSize
    }

    func records(for ids: Set<String>) throws -> [String: FingerprintRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }

        var matches: [String: FingerprintRecord] = [:]
        var lineCount = 0
        var distinctIDs = Set<String>()
        try enumerateLines(in: url) { id, payload in
            lineCount += 1
            distinctIDs.insert(id)
            guard ids.contains(id), let record = try? Self.decoder.decode(FingerprintRecord.self, from: payload) else { return }
            matches[id] = record
        }

        if lineCount > distinctIDs.count * 2 + compactionSlack {
            try? compact()
        }
        return matches
    }

    func upsert(_ records: [FingerprintRecord]) throws {
        guard !records.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        var payload = Data()
        for record in records {
            payload.append(Self.line(id: record.id, payload: try Self.encoder.encode(record)))
        }

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
            } else {
                try payload.write(to: url, options: .atomic)
            }
        } catch {
            throw CleanerError.persistence(error.localizedDescription)
        }
    }

    func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Rewrites the store keeping only the newest line per asset. Both passes read
    /// identifiers alone, so peak memory stays proportional to the asset count rather
    /// than to the size of the stored fingerprints.
    private func compact() throws {
        var newestLine: [String: Int] = [:]
        var position = 0
        try enumerateLines(in: url) { id, _ in
            newestLine[id] = position
            position += 1
        }

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).compacting")
        try? FileManager.default.removeItem(at: temporary)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { return }
        let output = try FileHandle(forWritingTo: temporary)

        position = 0
        do {
            var buffered = Data()
            try enumerateLines(in: url) { id, payload in
                defer { position += 1 }
                guard newestLine[id] == position else { return }
                buffered.append(Self.line(id: id, payload: payload))
                if buffered.count >= chunkSize {
                    try output.write(contentsOf: buffered)
                    buffered.removeAll(keepingCapacity: true)
                }
            }
            if !buffered.isEmpty { try output.write(contentsOf: buffered) }
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }

        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    private func enumerateLines(in url: URL, _ body: (String, Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var pending: [UInt8] = []
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            pending.append(contentsOf: chunk)
            var lineStart = 0
            for index in pending.indices where pending[index] == Self.newline {
                try Self.emit(pending[lineStart..<index], to: body)
                lineStart = index + 1
            }
            if lineStart > 0 { pending.removeFirst(lineStart) }
        }
        if !pending.isEmpty { try Self.emit(pending[...], to: body) }
    }

    private static func emit(_ line: ArraySlice<UInt8>, to body: (String, Data) throws -> Void) throws {
        guard let separator = line.firstIndex(of: tab),
              let encodedID = String(bytes: line[line.startIndex..<separator], encoding: .utf8),
              let id = encodedID.removingPercentEncoding, !id.isEmpty else { return }
        try body(id, Data(line[line.index(after: separator)...]))
    }

    private static func line(id: String, payload: Data) -> Data {
        var data = Data((id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id).utf8)
        data.append(tab)
        data.append(payload)
        data.append(newline)
        return data
    }

    private static let tab: UInt8 = 0x09
    private static let newline: UInt8 = 0x0a

    private static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        // Deliberately compact: every line must stay on a single line.
        value.outputFormatting = [.sortedKeys]
        return value
    }()

    private static let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }()
}
