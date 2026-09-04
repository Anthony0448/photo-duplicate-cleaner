import Foundation

final class FidelityMergePlanner: MergePlanner {
    func proposal(for group: DuplicateGroup, keeperID: String? = nil, deleting donorIDs: Set<String>? = nil) -> MergeProposal {
        let keeper = keeperID.flatMap { requested in group.assets.first { $0.id == requested } }
            ?? group.assets.max(by: { fidelityScore($0) < fidelityScore($1) })!
        let donors = group.assets.filter { $0.id != keeper.id }
        let defaultDeletionIDs = Set(donors.map(\.id))
        let deletionIDs = (donorIDs ?? defaultDeletionIDs)
            .intersection(Set(donors.map(\.id)))
        let selectedDonors = donors.filter { deletionIDs.contains($0.id) }
        let all = [keeper] + selectedDonors
        let conflicts = metadataConflicts(in: all)

        let dates = uniqueDates(all.compactMap(\.creationDate))
        let locations = uniqueLocations(all.compactMap(\.location))
        let captions = Array(Set(all.compactMap { normalized($0.caption) })).sorted()
        let ratings = Array(Set(all.compactMap(\.rating))).sorted()
        let allAlbums = Dictionary(grouping: all.flatMap(\.albums), by: \.id).compactMap { $0.value.first }
        let keeperAlbumIDs = Set(keeper.albums.map(\.id))

        return MergeProposal(
            id: UUID(),
            groupID: group.id,
            confidence: group.confidence,
            keeper: keeper,
            donors: donors,
            donorIDsToDelete: deletionIDs,
            proposedCreationDate: dates.count == 1 ? dates[0] : keeper.creationDate,
            proposedLocation: locations.count == 1 ? locations[0] : keeper.location,
            proposedCaption: captions.count == 1 ? captions[0] : keeper.caption,
            proposedRating: ratings.count == 1 ? ratings[0] : keeper.rating,
            proposedFavorite: all.contains(where: \.isFavorite),
            proposedHidden: keeper.isHidden,
            proposedKeywords: Array(Set(all.flatMap(\.keywords))).sorted(),
            albumsToAdd: allAlbums.filter { !keeperAlbumIDs.contains($0.id) && $0.canAddContent },
            conflicts: conflicts,
            isApproved: false
        )
    }

    func fidelityScore(_ asset: AssetSnapshot) -> Int64 {
        var score: Int64 = 0
        if asset.isLivePhoto { score += 10_000_000_000_000 }
        if asset.isRAW { score += 8_000_000_000_000 }
        if asset.hasAdjustments { score += 4_000_000_000_000 }
        score += Int64(asset.pixelWidth) * Int64(asset.pixelHeight) * 10_000
        if asset.mediaKind == .video, asset.duration > 0, asset.totalKnownBytes > 0 {
            score += min(asset.totalKnownBytes / Int64(max(asset.duration, 1)), 999_999_999)
        }
        score += min(asset.totalKnownBytes, 999_999_999)
        score += Int64(metadataCompleteness(asset) * 100)
        return score
    }

    private func metadataCompleteness(_ asset: AssetSnapshot) -> Int {
        var count = 0
        if asset.creationDate != nil { count += 1 }
        if asset.location != nil { count += 1 }
        if normalized(asset.caption) != nil { count += 1 }
        if !asset.keywords.isEmpty { count += 1 }
        if asset.rating != nil { count += 1 }
        if asset.isFavorite { count += 1 }
        return count
    }

    private func metadataConflicts(in assets: [AssetSnapshot]) -> [MetadataConflict] {
        var conflicts: [MetadataConflict] = []
        let ids = assets.map(\.id)
        if uniqueDates(assets.compactMap(\.creationDate)).count > 1 {
            conflicts.append(.init(field: .creationDate, message: "Capture dates differ by more than two seconds.", assetIDs: ids))
        }
        let locatedAssets = assets.filter { $0.location != nil }
        let uniqueLocationCount = uniqueLocations(locatedAssets.compactMap(\.location)).count
        if !locatedAssets.isEmpty && locatedAssets.count != assets.count {
            let message = uniqueLocationCount > 1
                ? "Some copies have no location, and the available locations differ. Choose the location to preserve."
                : "Location is present on only some copies. Choose whether to preserve it."
            conflicts.append(.init(field: .location, message: message, assetIDs: ids))
        } else if uniqueLocationCount > 1 {
            conflicts.append(.init(field: .location, message: "Locations differ by more than 100 meters.", assetIDs: ids))
        }
        if Set(assets.compactMap { normalized($0.caption) }).count > 1 {
            conflicts.append(.init(field: .caption, message: "Nonempty captions disagree.", assetIDs: ids))
        }
        if Set(assets.map(\.isHidden)).count > 1 {
            conflicts.append(.init(field: .hidden, message: "Hidden states disagree.", assetIDs: ids))
        }
        if Set(assets.compactMap(\.rating)).count > 1 {
            conflicts.append(.init(field: .rating, message: "Ratings disagree.", assetIDs: ids))
        }
        let adjusted = assets.filter(\.hasAdjustments)
        if adjusted.count > 1 && Set(adjusted.map(\.adjustmentIdentifier)).count > 1 {
            conflicts.append(.init(field: .adjustments, message: "More than one distinct edit is present.", assetIDs: adjusted.map(\.id)))
        }
        if Set(assets.map(\.resourceTopology)).count > 1 {
            conflicts.append(.init(field: .resourceTopology, message: "Resource formats differ; confirm which RAW, Live Photo, or encoded version to retain.", assetIDs: ids))
        }
        return conflicts
    }

    private func uniqueDates(_ dates: [Date]) -> [Date] {
        dates.sorted().reduce(into: []) { result, date in
            if result.allSatisfy({ abs($0.timeIntervalSince(date)) > 2 }) { result.append(date) }
        }
    }

    private func uniqueLocations(_ locations: [GeoPoint]) -> [GeoPoint] {
        locations.reduce(into: []) { result, location in
            if result.allSatisfy({ $0.distance(to: location) > 100 }) { result.append(location) }
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
