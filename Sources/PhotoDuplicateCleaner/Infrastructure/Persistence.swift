import Foundation

enum AppStoragePaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("PhotoDuplicateCleaner", isDirectory: true)
    }()
    static let inventory = root.appendingPathComponent("inventory-v1.json")
    static let journal = root.appendingPathComponent("cleanup-journal-v1.json")
    static let reviewSession = root.appendingPathComponent("review-session-v1.json")
}

final class JSONReviewSessionStore: ReviewSessionStore {
    private let url: URL
    init(url: URL = AppStoragePaths.reviewSession) { self.url = url }

    func load() throws -> SavedReviewSession? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let session = try Self.decoder.decode(SavedReviewSession.self, from: Data(contentsOf: url))
        guard session.schemaVersion == SavedReviewSession.schemaVersion,
              session.matcherVersion == MediaFingerprint.matcherVersion else { return nil }
        return session
    }

    func save(_ session: SavedReviewSession) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(session).write(to: url, options: .atomic)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.prettyPrinted, .sortedKeys]
        return value
    }()
    private static let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }()
}

final class JSONInventoryCache: InventoryCache {
    private let url: URL
    init(url: URL = AppStoragePaths.inventory) { self.url = url }

    func load() throws -> [AssetSnapshot] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Self.decoder.decode([AssetSnapshot].self, from: Data(contentsOf: url))
    }

    func save(_ assets: [AssetSnapshot]) throws {
        try ensureParent()
        try Self.encoder.encode(assets).write(to: url, options: .atomic)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func ensureParent() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.prettyPrinted, .sortedKeys]
        return value
    }()
    private static let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }()
}

final class JSONJournalStore: JournalStore {
    private let url: URL
    init(url: URL = AppStoragePaths.journal) { self.url = url }

    func appendPending(_ proposals: [MergeProposal]) throws -> [CleanupJournalEntry] {
        var entries = try load()
        let added = proposals.map {
            CleanupJournalEntry(id: UUID(), createdAt: Date(), status: .pending, proposal: $0)
        }
        entries.append(contentsOf: added)
        try save(entries)
        return added
    }

    func mark(_ entryIDs: [UUID], status: JournalStatus, error: String?) throws {
        let ids = Set(entryIDs)
        var entries = try load()
        for index in entries.indices where ids.contains(entries[index].id) {
            entries[index].status = status
            entries[index].completedAt = Date()
            entries[index].errorMessage = error
        }
        try save(entries)
    }

    func load() throws -> [CleanupJournalEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Self.decoder.decode([CleanupJournalEntry].self, from: Data(contentsOf: url))
    }

    func export(entries: [CleanupJournalEntry], jsonURL: URL, csvURL: URL) throws {
        try Self.encoder.encode(entries).write(to: jsonURL, options: .atomic)
        var rows = ["journal_id,status,created_at,completed_at,confidence,keeper_id,keeper_filename,donor_ids,creation_date,latitude,longitude,error"]
        let formatter = ISO8601DateFormatter()
        for entry in entries {
            let proposal = entry.proposal
            let completedAt = entry.completedAt.map { formatter.string(from: $0) } ?? ""
            let donorIDs = proposal.selectedDonors.map(\.id).joined(separator: "|")
            let creationDate = proposal.proposedCreationDate.map { formatter.string(from: $0) } ?? ""
            let latitude = proposal.proposedLocation.map { String($0.latitude) } ?? ""
            let longitude = proposal.proposedLocation.map { String($0.longitude) } ?? ""
            let columns: [String] = [
                entry.id.uuidString,
                entry.status.rawValue,
                formatter.string(from: entry.createdAt),
                completedAt,
                proposal.confidence.rawValue,
                proposal.keeper.id,
                proposal.keeper.originalFilename,
                donorIDs,
                creationDate,
                latitude,
                longitude,
                entry.errorMessage ?? ""
            ]
            rows.append(columns.map(Self.csvEscape).joined(separator: ","))
        }
        try rows.joined(separator: "\n").data(using: .utf8)!.write(to: csvURL, options: .atomic)
    }

    private func save(_ entries: [CleanupJournalEntry]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(entries).write(to: url, options: .atomic)
    }

    private static func csvEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.prettyPrinted, .sortedKeys]
        return value
    }()
    private static let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }()
}
