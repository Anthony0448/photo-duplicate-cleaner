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
        .alert("Run a new comparison scan?", isPresented: $model.showingRescanConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Rescan") { model.confirmRescan() }
        } message: {
            Text("The remembered results remain available if the rescan is cancelled or fails. A completed rescan will replace them using the currently selected scope.")
        }
        .alert("Photo Duplicate Cleaner", isPresented: errorBinding) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(errorMessage)
        }
        .task { model.bootstrap() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScopeView(model: model)
            Divider()
            if model.proposals.isEmpty {
                ContentUnavailableView(
                    model.state == .scanning ? "Scanning Photos" : "No Review Groups",
                    systemImage: model.state == .scanning ? "photo.stack" : "checkmark.circle",
                    description: Text(emptySidebarDescription)
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
        if model.state == .scanning, let progress = model.progress {
            ScanProgressView(progress: progress, paused: model.isPaused)
        } else if let proposal = model.selectedProposal {
            ProposalDetailView(model: model, proposal: proposal)
                .id(proposal.id.uuidString + "-\(proposal.conflicts.count)-\(proposal.keeper.id)-\(proposal.donorIDsToDelete.sorted().joined())")
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
                Button(model.hasSavedScan ? "Rescan" : "Scan", systemImage: "arrow.clockwise") { model.requestScan() }
            }
            Button("Export Journal", systemImage: "square.and.arrow.up") { model.exportJournal() }
                .disabled(model.journalEntries.isEmpty)
            Button("Review Batch (\(model.approvedProposals.count))", systemImage: "checklist") { model.showingConfirmation = true }
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

    private var emptySidebarDescription: String {
        if model.state == .scanning { return "Remembered results will be replaced after verification finishes." }
        if let date = model.lastScanDate {
            return "Remembered scan from \(date.formatted(date: .abbreviated, time: .shortened)) has no remaining review groups. Use Rescan to compare again."
        }
        return "Start a scan to find duplicates."
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
                Button("Add safe exact groups to batch") { model.approveAllConflictFreeExact() }
                    .font(.caption)
            }
            if let date = model.lastScanDate {
                Label("Remembered: \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
        .disabled(model.state == .scanning)
    }
}

private struct WelcomeView: View {
    @ObservedObject var model: CleanerAppModel

    var body: some View {
        ContentUnavailableView {
            Label("Clean duplicates safely", systemImage: "photo.on.rectangle.angled")
        } description: {
            if let date = model.lastScanDate {
                Text("The remembered scan from \(date.formatted(date: .abbreviated, time: .shortened)) has no remaining groups. Run a manual rescan whenever you want to compare the selected scope again.")
            } else {
                Text("The scan is local. Nothing changes in Photos until you choose keepers, resolve conflicts, and confirm a batch.")
            }
        } actions: {
            Button(model.hasSavedScan ? "Manual Rescan" : "Start Scan") { model.requestScan() }.buttonStyle(.borderedProminent)
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
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading) {
                Text(proposal.keeper.originalFilename).lineLimit(1)
                Text(statusText)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var statusIcon: String {
        if proposal.isApproved { return "checkmark.circle.fill" }
        if !proposal.conflicts.isEmpty { return "exclamationmark.triangle.fill" }
        if proposal.selectedDonors.isEmpty { return "hand.tap" }
        return "circle.dashed"
    }

    private var statusColor: Color {
        if proposal.isApproved { return .green }
        if !proposal.conflicts.isEmpty { return .orange }
        return .secondary
    }

    private var statusText: String {
        if proposal.isApproved { return "Ready • deletes \(proposal.selectedDonors.count)" }
        if !proposal.conflicts.isEmpty { return "Resolve \(proposal.conflicts.count) metadata conflict\(proposal.conflicts.count == 1 ? "" : "s")" }
        if proposal.selectedDonors.isEmpty { return "Choose copies to delete • \(proposal.confidence.label)" }
        return "Not yet added • deletes \(proposal.selectedDonors.count)"
    }
}

private struct ProposalDetailView: View {
    @ObservedObject var model: CleanerAppModel
    let proposal: MergeProposal

    private var assets: [AssetSnapshot] { [proposal.keeper] + proposal.donors }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(proposal.confidence.label).font(.title2.bold())
                                Text("Review this group before anything is changed in Photos.").foregroundStyle(.secondary)
                            }
                            Spacer()
                            if proposal.isApproved {
                                Label("In Cleanup Batch", systemImage: "checkmark.circle.fill")
                                    .font(.headline).foregroundStyle(.green)
                            }
                        }
                        ReviewSteps(proposal: proposal)
                    }

                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(assets) { asset in
                                AssetCard(
                                    library: model.library,
                                    asset: asset,
                                    isKeeper: asset.id == proposal.keeper.id,
                                    willDelete: proposal.donorIDsToDelete.contains(asset.id),
                                    chooseKeeper: { model.chooseKeeper(proposalID: proposal.id, assetID: asset.id) },
                                    toggleDeletion: { model.toggleDeletion(proposalID: proposal.id, assetID: asset.id) }
                                )
                            }
                        }
                    }

                    if !proposal.conflicts.isEmpty {
                        GroupBox("Step 3: Choose metadata to preserve") {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(proposal.conflicts) { conflict in
                                    VStack(alignment: .leading, spacing: 7) {
                                        Label(conflict.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                        Text("Select the value to keep:").font(.caption).foregroundStyle(.secondary)
                                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 235, maximum: 340), spacing: 10)], alignment: .leading, spacing: 10) {
                                            ForEach(Array(([proposal.keeper] + proposal.selectedDonors).enumerated()), id: \.element.id) { index, asset in
                                                MetadataChoiceCard(
                                                    library: model.library,
                                                    asset: asset,
                                                    isKeeper: index == 0,
                                                    roleLabel: index == 0 ? "Selected keeper" : "Copy \(index + 1) • marked DELETE",
                                                    value: conflictValue(conflict.field, asset: asset)
                                                ) {
                                                    model.resolve(conflict, proposalID: proposal.id, using: asset.id)
                                                }
                                            }
                                        }
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    GroupBox("What will happen") {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                            MetadataGridRow(label: "Keep in Photos", value: proposal.keeper.originalFilename)
                            MetadataGridRow(label: "Move to Recently Deleted", value: proposal.selectedDonors.isEmpty ? "Nothing selected" : proposal.selectedDonors.map(\.originalFilename).joined(separator: ", "))
                            MetadataGridRow(label: "Also keep", value: proposal.retainedCandidates.isEmpty ? "No additional copies" : proposal.retainedCandidates.map(\.originalFilename).joined(separator: ", "))
                            MetadataGridRow(label: "Capture date", value: proposal.proposedCreationDate?.formatted(date: .abbreviated, time: .standard) ?? "None")
                            MetadataGridRow(label: "Location", value: proposal.proposedLocation.map { String(format: "%.5f, %.5f", $0.latitude, $0.longitude) } ?? "None")
                            MetadataGridRow(label: "Caption", value: proposal.proposedCaption ?? "None")
                            MetadataGridRow(label: "Favorite", value: proposal.proposedFavorite ? "Yes" : "No")
                            MetadataGridRow(label: "Keywords", value: proposal.proposedKeywords.isEmpty ? "None" : proposal.proposedKeywords.joined(separator: ", "))
                            MetadataGridRow(label: "Albums added", value: proposal.albumsToAdd.isEmpty ? "None" : proposal.albumsToAdd.map(\.title).joined(separator: ", "))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if proposal.confidence == .likelyVisual {
                        Label("This is a visual match. All non-keepers are initially marked DELETE; use Undo Delete on any copy you want to retain.", systemImage: "eye.trianglebadge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                }
                .padding(24)
            }
            Divider()
            reviewActions
        }
    }

    private var reviewActions: some View {
        HStack(spacing: 12) {
            Button("Previous", systemImage: "chevron.left") { model.selectAdjacent(to: proposal.id, offset: -1) }
            Button("Next", systemImage: "chevron.right") { model.selectAdjacent(to: proposal.id, offset: 1) }
            Spacer()
            if proposal.isApproved {
                Button("Remove from Batch") { model.setApproved(false, proposalID: proposal.id) }
                Label("\(proposal.selectedDonors.count) selected for deletion", systemImage: "trash")
                    .foregroundStyle(.secondary)
            } else {
                if proposal.selectedDonors.isEmpty {
                    Text("Mark at least one non-keeper copy for deletion.").foregroundStyle(.secondary)
                } else if !proposal.conflicts.isEmpty {
                    Text("Resolve \(proposal.conflicts.count) metadata conflict\(proposal.conflicts.count == 1 ? "" : "s") first.").foregroundStyle(.orange)
                }
                Button("Add \(proposal.selectedDonors.count) to Cleanup Batch & Next", systemImage: "checkmark.circle.fill") {
                    model.approveAndAdvance(proposalID: proposal.id)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!proposal.canApprove)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private func conflictValue(_ field: MetadataField, asset: AssetSnapshot) -> String {
        switch field {
        case .creationDate: return asset.creationDate?.formatted(date: .abbreviated, time: .standard) ?? "No capture date"
        case .location: return asset.location.map { String(format: "%.4f, %.4f", $0.latitude, $0.longitude) } ?? "No location"
        case .caption: return asset.caption ?? "No caption"
        case .hidden: return asset.isHidden ? "Hidden" : "Visible"
        case .rating: return asset.rating.map { "\($0) stars" } ?? "No rating"
        case .adjustments: return asset.hasAdjustments ? "Edited version" : "Unedited version"
        case .resourceTopology:
            var parts: [String] = []
            if asset.isRAW { parts.append("RAW") }
            if asset.isLivePhoto { parts.append("Live Photo") }
            parts.append(asset.contentType)
            return parts.joined(separator: " • ")
        }
    }
}

private struct MetadataChoiceCard: View {
    let library: PhotoLibraryClient
    let asset: AssetSnapshot
    let isKeeper: Bool
    let roleLabel: String
    let value: String
    let choose: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    if let image { Image(nsImage: image).resizable().scaledToFill() }
                    else { Image(systemName: asset.mediaKind == .video ? "video" : "photo").foregroundStyle(.secondary) }
                }
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    Text(roleLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isKeeper ? Color.green : Color.red)
                    Text(value)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(asset.originalFilename)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: "checkmark.circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.22)))
        }
        .buttonStyle(.plain)
        .help("Keep this metadata value")
        .task {
            image = try? await library.thumbnail(assetID: asset.id, targetSize: .init(width: 116, height: 116))
        }
    }

}

private struct ReviewSteps: View {
    let proposal: MergeProposal

    var body: some View {
        HStack(spacing: 8) {
            StepPill(number: 1, text: "Keeper: \(proposal.keeper.originalFilename)", complete: true)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            StepPill(number: 2, text: proposal.selectedDonors.isEmpty ? "Choose deletions" : "Delete \(proposal.selectedDonors.count)", complete: !proposal.selectedDonors.isEmpty)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            StepPill(number: 3, text: proposal.conflicts.isEmpty ? "Metadata ready" : "Resolve metadata", complete: proposal.conflicts.isEmpty)
        }
        .font(.caption.weight(.medium))
    }
}

private struct StepPill: View {
    let number: Int
    let text: String
    let complete: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: complete ? "checkmark.circle.fill" : "\(number).circle.fill")
            Text(text).lineLimit(1)
        }
        .foregroundStyle(complete ? Color.green : Color.gray)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background((complete ? Color.green : Color.gray).opacity(0.1), in: Capsule())
    }
}

private struct AssetCard: View {
    let library: PhotoLibraryClient
    let asset: AssetSnapshot
    let isKeeper: Bool
    let willDelete: Bool
    let chooseKeeper: () -> Void
    let toggleDeletion: () -> Void
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let image { Image(nsImage: image).resizable().scaledToFit() }
                else { ProgressView() }
                VStack {
                    HStack {
                        Spacer()
                        Text(isKeeper ? "KEEPER" : (willDelete ? "DELETE" : "KEEP"))
                            .font(.caption.bold())
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(isKeeper ? Color.green : (willDelete ? Color.red : Color.secondary), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Spacer()
                }.padding(8)
            }
            .frame(width: 280, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { if !isKeeper { chooseKeeper() } }
            if isKeeper {
                Label("Selected keeper", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
            } else {
                HStack {
                    Button("Make Keeper", action: chooseKeeper).buttonStyle(.bordered)
                    if willDelete {
                        Button("Undo Delete", action: toggleDeletion).buttonStyle(.bordered)
                    } else {
                        Button("Delete This Copy", role: .destructive, action: toggleDeletion)
                            .buttonStyle(.borderedProminent).tint(.red)
                    }
                }
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
        .background(isKeeper ? Color.green.opacity(0.10) : (willDelete ? Color.red.opacity(0.08) : Color.clear), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isKeeper ? Color.green : (willDelete ? Color.red : Color.secondary.opacity(0.25)), lineWidth: isKeeper || willDelete ? 2 : 1))
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
            Text("\(model.approvedProposals.count) groups will keep the selected media and move \(model.approvedProposals.flatMap(\.selectedDonors).count) explicitly selected copies to Recently Deleted.")
            List(model.approvedProposals) { proposal in
                VStack(alignment: .leading) {
                    Text("Keep \(proposal.keeper.originalFilename)").font(.headline)
                    Text("Delete: \(proposal.selectedDonors.map(\.originalFilename).joined(separator: ", "))").font(.caption).foregroundStyle(.red)
                    if !proposal.retainedCandidates.isEmpty {
                        Text("Also keep: \(proposal.retainedCandidates.map(\.originalFilename).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                    }
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
