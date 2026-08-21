import AppKit
import SwiftUI

struct CleanerRootView: View {
    @StateObject private var model = CleanerAppModel()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 270, ideal: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 1050, minHeight: 700)
        .toolbar { toolbar }
        .sheet(isPresented: $model.showingConfirmation) { BatchConfirmationView(model: model) }
        .alert("Photo Duplicate Cleaner", isPresented: errorBinding) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(errorMessage)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScopeView(model: model)
            Divider()
            if model.proposals.isEmpty {
                ContentUnavailableView(
                    model.state == .scanning ? "Scanning Photos" : "No Review Groups",
                    systemImage: model.state == .scanning ? "photo.stack" : "checkmark.circle",
                    description: Text(model.state == .scanning ? "Candidates will appear after verification." : "Start a scan to find duplicates.")
                )
            } else {
                List(selection: $model.selectedProposalID) {
                    Section("Exact (\(model.exactCount))") {
                        ForEach(model.proposals.filter { $0.confidence != .likelyVisual }) { proposal in
                            ProposalRow(proposal: proposal).tag(proposal.id)
                        }
                    }
                    Section("Likely visual (\(model.likelyCount))") {
                        ForEach(model.proposals.filter { $0.confidence == .likelyVisual }) { proposal in
                            ProposalRow(proposal: proposal).tag(proposal.id)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let proposal = model.selectedProposal {
            ProposalDetailView(model: model, proposal: proposal)
                .id(proposal.id.uuidString + "-\(proposal.conflicts.count)-\(proposal.keeper.id)")
        } else if model.state == .scanning, let progress = model.progress {
            ScanProgressView(progress: progress, paused: model.isPaused)
        } else {
            WelcomeView(model: model)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if model.state == .scanning {
                Button(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill") { model.pauseOrResume() }
                Button("Cancel", systemImage: "xmark") { model.cancelScan() }
            } else {
                Button("Scan", systemImage: "magnifyingglass") { model.startScan() }
            }
            Button("Export Journal", systemImage: "square.and.arrow.up") { model.exportJournal() }
                .disabled(model.journalEntries.isEmpty)
            Button("Review Batch", systemImage: "checklist") { model.showingConfirmation = true }
                .disabled(model.approvedProposals.isEmpty || model.state == .applying)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { if case .failed = model.state { return true }; return false }, set: { if !$0 { model.dismissError() } })
    }
    private var errorMessage: String {
        if case .failed(let message) = model.state { return message }
        return ""
    }
}

private struct ScopeView: View {
    @ObservedObject var model: CleanerAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scan scope").font(.headline)
            Picker("Scope", selection: $model.scope.kind) {
                ForEach(ScanScope.Kind.allCases) { kind in Text(kind.label).tag(kind) }
            }
            .pickerStyle(.segmented)
            if model.authorization != .authorized {
                Button("Grant Photos Access", systemImage: "photo.badge.checkmark") { model.requestAccessAndLoadAlbums() }
                    .buttonStyle(.borderedProminent)
            } else if model.scope.kind == .selectedAlbums {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(model.albums) { album in
                            Toggle(album.title, isOn: Binding(
                                get: { model.scope.albumIDs.contains(album.id) },
                                set: { _ in model.toggleAlbum(album.id) }
                            ))
                            .disabled(!album.canAddContent)
                        }
                    }
                }.frame(maxHeight: 180)
            }
            if !model.proposals.isEmpty {
                Button("Approve conflict-free exact groups") { model.approveAllConflictFreeExact() }
                    .font(.caption)
            }
        }
        .padding()
    }
}

private struct WelcomeView: View {
    @ObservedObject var model: CleanerAppModel

    var body: some View {
        ContentUnavailableView {
            Label("Clean duplicates safely", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("The scan is local. Nothing changes in Photos until you choose keepers, resolve conflicts, and confirm a batch.")
        } actions: {
            Button("Start Scan") { model.startScan() }.buttonStyle(.borderedProminent)
        }
    }
}

private struct ScanProgressView: View {
    let progress: ScanProgress
    let paused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: paused ? "pause.circle" : "photo.stack").font(.system(size: 54)).foregroundStyle(.tint)
            Text(paused ? "Scan paused" : progress.phase.rawValue).font(.title2.bold())
            ProgressView(value: progress.fraction).frame(width: 380)
            Text("\(progress.completed) of \(progress.total)").monospacedDigit()
            Text(progress.detail).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

private struct ProposalRow: View {
    let proposal: MergeProposal

    var body: some View {
        HStack {
            Image(systemName: proposal.isApproved ? "checkmark.circle.fill" : (proposal.conflicts.isEmpty ? "circle" : "exclamationmark.triangle.fill"))
                .foregroundStyle(proposal.isApproved ? .green : (proposal.conflicts.isEmpty ? .secondary : .orange))
            VStack(alignment: .leading) {
                Text(proposal.keeper.originalFilename).lineLimit(1)
                Text("\(proposal.keeper.mediaKind.label) • \(proposal.donors.count + 1) copies • \(proposal.confidence.label)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProposalDetailView: View {
    @ObservedObject var model: CleanerAppModel
    let proposal: MergeProposal

    private var assets: [AssetSnapshot] { [proposal.keeper] + proposal.donors }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(proposal.confidence.label).font(.title2.bold())
                        Text("Choose the media to keep, then resolve every metadata conflict.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Include in batch", isOn: Binding(
                        get: { proposal.isApproved },
                        set: { model.setApproved($0, proposalID: proposal.id) }
                    ))
                    .disabled(!proposal.conflicts.isEmpty)
                }

                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(assets) { asset in
                            AssetCard(
                                library: model.library,
                                asset: asset,
                                isKeeper: asset.id == proposal.keeper.id,
                                choose: { model.chooseKeeper(proposalID: proposal.id, assetID: asset.id) }
                            )
                        }
                    }
                }

                if !proposal.conflicts.isEmpty {
                    GroupBox("Conflicts requiring your choice") {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(proposal.conflicts) { conflict in
                                VStack(alignment: .leading, spacing: 7) {
                                    Label(conflict.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    HStack {
                                        ForEach(assets) { asset in
                                            Button(conflictValue(conflict.field, asset: asset)) {
                                                model.resolve(conflict, proposalID: proposal.id, using: asset.id)
                                            }
                                        }
                                    }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                GroupBox("Proposed result") {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                        MetadataGridRow(label: "Keeper", value: proposal.keeper.originalFilename)
                        MetadataGridRow(label: "Capture date", value: proposal.proposedCreationDate?.formatted(date: .abbreviated, time: .standard) ?? "None")
                        MetadataGridRow(label: "Location", value: proposal.proposedLocation.map { String(format: "%.5f, %.5f", $0.latitude, $0.longitude) } ?? "None")
                        MetadataGridRow(label: "Caption", value: proposal.proposedCaption ?? "None")
                        MetadataGridRow(label: "Favorite", value: proposal.proposedFavorite ? "Yes" : "No")
                        MetadataGridRow(label: "Keywords", value: proposal.proposedKeywords.isEmpty ? "None" : proposal.proposedKeywords.joined(separator: ", "))
                        MetadataGridRow(label: "Albums added", value: proposal.albumsToAdd.isEmpty ? "None" : proposal.albumsToAdd.map(\.title).joined(separator: ", "))
                        MetadataGridRow(label: "Moved to Recently Deleted", value: proposal.donors.map(\.originalFilename).joined(separator: ", "))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }

                if proposal.confidence == .likelyVisual {
                    Label("This is a visual match, not an exact-copy guarantee. Compare the full previews before including it.", systemImage: "eye.trianglebadge.exclamationmark")
                        .foregroundStyle(.orange)
                }
            }
            .padding(24)
        }
    }

    private func conflictValue(_ field: MetadataField, asset: AssetSnapshot) -> String {
        switch field {
        case .creationDate: return asset.creationDate?.formatted(date: .numeric, time: .standard) ?? "No date"
        case .location: return asset.location.map { String(format: "%.4f, %.4f", $0.latitude, $0.longitude) } ?? "No location"
        case .caption: return asset.caption ?? "No caption"
        case .hidden: return asset.isHidden ? "Hidden" : "Visible"
        case .rating: return asset.rating.map { "\($0) stars" } ?? "No rating"
        case .adjustments: return asset.id == proposal.keeper.id ? "Keep selected edit" : "Use \(asset.originalFilename)"
        case .resourceTopology: return asset.id == proposal.keeper.id ? "Keep selected format" : "Use \(asset.originalFilename)"
        }
    }
}

private struct AssetCard: View {
    let library: PhotoLibraryClient
    let asset: AssetSnapshot
    let isKeeper: Bool
    let choose: () -> Void
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let image { Image(nsImage: image).resizable().scaledToFit() }
                else { ProgressView() }
            }.frame(width: 260, height: 200).clipShape(RoundedRectangle(cornerRadius: 8))
            if isKeeper {
                Button("Recommended keeper", action: choose).buttonStyle(.borderedProminent)
            } else {
                Button("Keep this copy", action: choose).buttonStyle(.bordered)
            }
            Text(asset.originalFilename).font(.headline).lineLimit(1)
            Text("\(asset.pixelWidth) × \(asset.pixelHeight) • \(ByteCountFormatter.string(fromByteCount: asset.totalKnownBytes, countStyle: .file))")
                .font(.caption).foregroundStyle(.secondary)
            Text(asset.creationDate?.formatted(date: .abbreviated, time: .standard) ?? "No capture date").font(.caption)
            Text(asset.location == nil ? "No location" : "Has location").font(.caption)
            HStack {
                if asset.isLivePhoto { Label("Live", systemImage: "livephoto") }
                if asset.isRAW { Text("RAW") }
                if asset.hasAdjustments { Label("Edited", systemImage: "slider.horizontal.3") }
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(isKeeper ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isKeeper ? Color.accentColor : Color.secondary.opacity(0.25)))
        .task {
            image = try? await library.thumbnail(assetID: asset.id, targetSize: .init(width: 520, height: 400))
        }
    }
}

private struct MetadataGridRow: View {
    let label: String
    let value: String
    var body: some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
    }
}

private struct BatchConfirmationView: View {
    @ObservedObject var model: CleanerAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Confirm cleanup batch").font(.title.bold())
            Text("\(model.approvedProposals.count) groups will keep one asset each and move \(model.approvedProposals.flatMap(\.donors).count) duplicates to Recently Deleted.")
            List(model.approvedProposals) { proposal in
                VStack(alignment: .leading) {
                    Text("Keep \(proposal.keeper.originalFilename)").font(.headline)
                    Text("Remove: \(proposal.donors.map(\.originalFilename).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Label("Photos retains deleted items for a limited recovery period. The journal cannot restore media after Photos permanently deletes it.", systemImage: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Update Keepers & Move Duplicates", role: .destructive) { model.applyApproved() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 680, height: 520)
    }
}
