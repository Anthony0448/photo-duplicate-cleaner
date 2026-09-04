import AppKit
import AVFoundation
import AVKit
import SwiftUI

private enum CleanerStyle {
    static let accent = Color(red: 0.30, green: 0.47, blue: 1.0)
    static let mint = Color(red: 0.25, green: 0.88, blue: 0.76)
    static let panelRadius: CGFloat = 22
}

private struct AmbientBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [CleanerStyle.accent.opacity(colorScheme == .dark ? 0.18 : 0.12), .clear],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 620
            )
            RadialGradient(
                colors: [CleanerStyle.mint.opacity(colorScheme == .dark ? 0.09 : 0.07), .clear],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

private struct LiquidGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(tint),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
        }
    }
}

private extension View {
    func liquidGlassSurface(
        cornerRadius: CGFloat = CleanerStyle.panelRadius,
        tint: Color = CleanerStyle.accent.opacity(0.06)
    ) -> some View {
        modifier(LiquidGlassSurface(cornerRadius: cornerRadius, tint: tint))
    }
}

private func formattedDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "Unknown duration" }
    let totalSeconds = Int(seconds.rounded())
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let remainingSeconds = totalSeconds % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds) }
    return String(format: "%d:%02d", minutes, remainingSeconds)
}

struct CleanerRootView: View {
    @StateObject private var model = CleanerAppModel()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 290, ideal: 330, max: 390)
        } detail: {
            ZStack {
                AmbientBackdrop()
                detail
            }
        }
        .tint(CleanerStyle.accent)
        .frame(minWidth: 1120, minHeight: 740)
        .toolbar { toolbar }
        .sheet(isPresented: $model.showingConfirmation) { BatchConfirmationView(model: model) }
        .alert("Run a new comparison scan?", isPresented: $model.showingRescanConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Rescan") { model.confirmRescan() }
        } message: {
            Text("The remembered results remain available if the rescan is cancelled or fails. A completed rescan will replace them using the currently selected scope.")
        }
        .alert("Photos Library Changed", isPresented: $model.showingLibraryChangeRescanPrompt) {
            Button("Later", role: .cancel) { model.deferLibraryChangeRescan() }
            Button("Rescan Now") { model.rescanAfterLibraryChange() }
        } message: {
            Text(model.libraryChangePromptMessage)
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
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .background(.thinMaterial)
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
            Button("Review Cleanup (\(model.approvedProposals.count))", systemImage: "photo.badge.checkmark") { model.showingConfirmation = true }
                .disabled(model.approvedProposals.isEmpty || model.state == .applying || model.libraryResultsAreStale)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(CleanerStyle.accent.gradient)
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Duplicate Cleaner").font(.headline)
                    Text("Private & on-device").font(.caption).foregroundStyle(.secondary)
                }
            }

            Picker("Library scope", selection: $model.scope.kind) {
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
                HStack(spacing: 10) {
                    StatChip(value: model.exactCount, label: "Exact", color: CleanerStyle.mint)
                    StatChip(value: model.likelyCount, label: "Visual", color: .orange)
                }
                Button("Add safe exact groups", systemImage: "checkmark.seal") { model.approveAllConflictFreeExact() }
                    .controlSize(.small)
            }
            if let date = model.lastScanDate {
                Label("Saved \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.libraryResultsAreStale {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Photos changed — rescan recommended", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Button("Rescan Now") { model.rescanAfterLibraryChange() }
                        .controlSize(.small)
                }
            }
        }
        .padding(18)
        .disabled(model.state == .scanning)
    }
}

private struct StatChip: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(value, format: .number).fontWeight(.bold).monospacedDigit()
            Text(label).foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.12), in: Capsule())
    }
}

private struct WelcomeView: View {
    @ObservedObject var model: CleanerAppModel

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(CleanerStyle.accent.opacity(0.14))
                Image(systemName: model.hasSavedScan ? "checkmark.seal.fill" : "photo.on.rectangle.angled")
                    .font(.system(size: 44, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(model.hasSavedScan ? CleanerStyle.mint : CleanerStyle.accent)
            }
            .frame(width: 92, height: 92)

            VStack(spacing: 8) {
                Text(model.hasSavedScan ? "Your library is tidy" : "Find duplicates, keep the best")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(welcomeDescription)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .lineSpacing(3)
            }

            Button(model.hasSavedScan ? "Scan Again" : "Scan Photo Library", systemImage: "sparkles") {
                model.requestScan()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(spacing: 20) {
                Label("On-device", systemImage: "lock.shield")
                Label("Review first", systemImage: "eye")
                Label("Recently Deleted", systemImage: "arrow.uturn.backward.circle")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .padding(44)
        .liquidGlassSurface(cornerRadius: 32)
        .padding(48)
    }

    private var welcomeDescription: String {
        if let date = model.lastScanDate {
            return "No review groups remain from the scan saved \(date.formatted(date: .abbreviated, time: .shortened)). Scan again whenever you’re ready."
        }
        return "Compare your Photos library locally, choose every keeper, and confirm changes before a single duplicate moves to Recently Deleted."
    }
}

private struct ScanProgressView: View {
    let progress: ScanProgress
    let paused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: paused ? "pause.circle.fill" : "photo.stack.fill")
                .font(.system(size: 52)).symbolRenderingMode(.hierarchical).foregroundStyle(CleanerStyle.accent)
            Text(paused ? "Scan paused" : progress.phase.rawValue).font(.title.bold())
            ProgressView(value: progress.fraction).frame(width: 420).controlSize(.large)
            Text("\(progress.completed) of \(progress.total)").font(.headline).monospacedDigit()
            Text(progress.detail).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(38)
        .liquidGlassSurface(cornerRadius: 28)
    }
}

private struct ProposalRow: View {
    let proposal: MergeProposal

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading) {
                Text(proposal.keeper.originalFilename).fontWeight(.medium).lineLimit(1)
                Text(statusText)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
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
    @State private var previewedAsset: AssetSnapshot?

    private var assets: [AssetSnapshot] { [proposal.keeper] + proposal.donors }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(proposal.confidence.label)
                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                Text("Compare every copy, then choose what stays.").foregroundStyle(.secondary)
                            }
                            Spacer()
                            if proposal.isApproved {
                                Label("In Cleanup Batch", systemImage: "checkmark.circle.fill")
                                    .font(.headline).foregroundStyle(CleanerStyle.mint)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(CleanerStyle.mint.opacity(0.12), in: Capsule())
                            }
                        }
                        ReviewSteps(proposal: proposal)
                    }
                    .padding(20)
                    .liquidGlassSurface()

                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(assets) { asset in
                                AssetCard(
                                    library: model.library,
                                    asset: asset,
                                    isKeeper: asset.id == proposal.keeper.id,
                                    willDelete: proposal.donorIDsToDelete.contains(asset.id),
                                    locationNeedsAttention: Set(assets.map { $0.location != nil }).count > 1,
                                    quickLook: { previewedAsset = asset },
                                    chooseKeeper: { model.chooseKeeper(proposalID: proposal.id, assetID: asset.id) },
                                    toggleDeletion: { model.toggleDeletion(proposalID: proposal.id, assetID: asset.id) }
                                )
                            }
                        }
                    }

                    if !proposal.conflicts.isEmpty {
                        GroupBox("Choose metadata to preserve") {
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
                        .groupBoxStyle(GlassGroupBoxStyle(icon: "slider.horizontal.3", tint: .orange))
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
                    .groupBoxStyle(GlassGroupBoxStyle(icon: "arrow.right.circle", tint: CleanerStyle.accent))

                    if proposal.confidence == .likelyVisual {
                        Label("This is a visual match. All non-keepers are initially marked DELETE; use Undo Delete on any copy you want to retain.", systemImage: "eye.trianglebadge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                }
                .padding(26)
            }
            reviewActions
        }
        .sheet(item: $previewedAsset) { asset in
            MediaQuickLookView(library: model.library, asset: asset)
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
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
        .shadow(color: .black.opacity(0.08), radius: 16, y: -4)
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

private struct GlassGroupBoxStyle: GroupBoxStyle {
    let icon: String
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                configuration.label.font(.headline)
            }
            configuration.content
        }
        .padding(18)
        .liquidGlassSurface(tint: tint.opacity(0.04))
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
            .liquidGlassSurface(cornerRadius: 13, tint: isKeeper ? CleanerStyle.mint.opacity(0.08) : CleanerStyle.accent.opacity(0.05))
        }
        .buttonStyle(.plain)
        .help("Keep this metadata value")
        .task {
            image = try? await library.thumbnail(
                assetID: asset.id,
                targetSize: .init(width: 116, height: 116),
                networkAccessAllowed: false
            )
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
        .fixedSize(horizontal: false, vertical: true)
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
        .background((complete ? CleanerStyle.mint : Color.gray).opacity(0.11), in: Capsule())
    }
}

private struct AssetCard: View {
    let library: PhotoLibraryClient
    let asset: AssetSnapshot
    let isKeeper: Bool
    let willDelete: Bool
    let locationNeedsAttention: Bool
    let quickLook: () -> Void
    let chooseKeeper: () -> Void
    let toggleDeletion: () -> Void
    @State private var image: NSImage?
    @State private var thumbnailUnavailable = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous).fill(.quaternary)
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if thumbnailUnavailable {
                    VStack(spacing: 7) {
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.title2)
                        Text("Open preview to load")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
                VStack {
                    HStack {
                        Spacer()
                        Text(isKeeper ? "KEEPER" : (willDelete ? "DELETE" : "KEEP"))
                            .font(.caption2.bold())
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(isKeeper ? CleanerStyle.mint : (willDelete ? Color.red : Color.secondary), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Spacer()
                }.padding(8)
                VStack {
                    Spacer()
                    HStack {
                        Button(action: quickLook) {
                            Label(asset.mediaKind == .video ? "Play Video" : "Quick Look", systemImage: asset.mediaKind == .video ? "play.fill" : "eye.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.black.opacity(0.68))
                        .controlSize(.small)
                        Spacer()
                    }
                }
                .padding(9)
            }
            .frame(width: 292, height: 226)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                isFocused = true
                quickLook()
            }
            if isKeeper {
                Label("Selected keeper", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(CleanerStyle.mint)
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
            Text(asset.originalFilename).font(.headline).lineLimit(1).truncationMode(.middle)
            Text("\(asset.pixelWidth) × \(asset.pixelHeight) • \(ByteCountFormatter.string(fromByteCount: asset.totalKnownBytes, countStyle: .file))")
                .font(.caption).foregroundStyle(.secondary)
            if asset.mediaKind == .video {
                Label(formattedDuration(asset.duration), systemImage: "timer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CleanerStyle.accent)
            }
            Text(asset.creationDate?.formatted(date: .abbreviated, time: .standard) ?? "No capture date").font(.caption)
            locationLabel
            HStack {
                if asset.isLivePhoto { Label("Live", systemImage: "livephoto") }
                if asset.isRAW { Text("RAW") }
                if asset.hasAdjustments { Label("Edited", systemImage: "slider.horizontal.3") }
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .liquidGlassSurface(
            cornerRadius: 20,
            tint: isKeeper ? CleanerStyle.mint.opacity(0.12) : (willDelete ? Color.red.opacity(0.08) : CleanerStyle.accent.opacity(0.04))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(isKeeper ? CleanerStyle.mint : (willDelete ? Color.red : Color.clear), lineWidth: 1.5)
        }
        .focusable()
        .focused($isFocused)
        .onKeyPress(.space) {
            quickLook()
            return .handled
        }
        .help("Click the media or focus this card and press Space to preview it")
        .task {
            do {
                image = try await library.thumbnail(
                    assetID: asset.id,
                    targetSize: .init(width: 520, height: 400),
                    networkAccessAllowed: false
                )
            } catch {
                thumbnailUnavailable = true
            }
        }
    }

    @ViewBuilder private var locationLabel: some View {
        if let location = asset.location {
            Label(String(format: "%.4f, %.4f", location.latitude, location.longitude), systemImage: "location.fill")
                .foregroundStyle(locationNeedsAttention ? Color.orange : Color.secondary)
                .font(.caption)
                .fontWeight(locationNeedsAttention ? .semibold : .regular)
        } else {
            Label(locationNeedsAttention ? "Location missing — compare carefully" : "No location", systemImage: "location.slash")
                .foregroundStyle(locationNeedsAttention ? Color.orange : Color.secondary)
                .font(.caption)
                .fontWeight(locationNeedsAttention ? .semibold : .regular)
        }
    }
}

private struct MediaQuickLookView: View {
    let library: PhotoLibraryClient
    let asset: AssetSnapshot

    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var needsPhotoAccess = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: asset.mediaKind == .video ? "video.fill" : "photo.fill")
                    .foregroundStyle(CleanerStyle.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.originalFilename)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            ZStack {
                Color.black.opacity(0.94)
                if needsPhotoAccess {
                    ContentUnavailableView {
                        Label("Photos Access Needed", systemImage: "photo.badge.exclamationmark")
                    } description: {
                        Text("PhotoKit needs full Photos access to open this selected library item.")
                    } actions: {
                        HStack {
                            Button("Open Privacy Settings") { openPhotosPrivacySettings() }
                            Button("Try Again") { Task { await loadPreview() } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .foregroundStyle(.white)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Preview Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                    .foregroundStyle(.white)
                } else if asset.mediaKind == .video, let player {
                    NativeVideoPlayer(player: player)
                        .padding(18)
                } else if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(18)
                } else if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text(asset.mediaKind == .video ? "Loading video…" : "Loading photo…")
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
            }
        }
        .frame(minWidth: 820, idealWidth: 1_020, minHeight: 600, idealHeight: 760)
        .task(id: asset.id) { await loadPreview() }
        .onDisappear {
            player?.pause()
            player = nil
        }
        .onExitCommand { dismiss() }
    }

    private var detailText: String {
        var details = ["\(asset.pixelWidth) × \(asset.pixelHeight)"]
        if asset.mediaKind == .video { details.append(formattedDuration(asset.duration)) }
        if asset.isLivePhoto { details.append("Live Photo") }
        if asset.isRAW { details.append("RAW") }
        return details.joined(separator: " • ")
    }

    @MainActor
    private func loadPreview() async {
        isLoading = true
        errorMessage = nil
        needsPhotoAccess = false
        do {
            var access = library.authorizationStatus()
            if access == .notDetermined {
                access = await library.requestAuthorization()
            }
            guard access == .authorized else {
                needsPhotoAccess = true
                throw access == .limited
                    ? CleanerError.limitedAccessUnsupported
                    : CleanerError.photoAccessRequired
            }
            if asset.mediaKind == .video {
                let item = try await library.videoPlayerItem(assetID: asset.id)
                try Task.checkCancellation()
                let loadedPlayer = AVPlayer(playerItem: item)
                player = loadedPlayer
                loadedPlayer.play()
            } else {
                image = try await library.thumbnail(
                    assetID: asset.id,
                    targetSize: .init(width: 2_400, height: 1_800),
                    networkAccessAllowed: true
                )
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func openPhotosPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        playerView.player = player
        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        if playerView.player !== player {
            playerView.player = player
        }
    }

    static func dismantleNSView(_ playerView: AVPlayerView, coordinator: Void) {
        playerView.player?.pause()
        playerView.player = nil
    }
}

private struct MetadataGridRow: View {
    let label: String
    let value: String
    var body: some View {
        GridRow {
            Text(label).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

private struct BatchAssetPreview: View {
    let library: PhotoLibraryClient
    let asset: AssetSnapshot
    let isKeeper: Bool
    let locationNeedsAttention: Bool
    @State private var image: NSImage?

    private var roleColor: Color { isKeeper ? CleanerStyle.mint : .red }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.quaternary)
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ProgressView()
                }
                if asset.mediaKind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.white, .black.opacity(0.35))
                        .shadow(radius: 3)
                }
                VStack {
                    HStack {
                        Text(isKeeper ? "KEEP" : "MOVE TO RECENTLY DELETED")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(roleColor, in: Capsule())
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(8)
            }
            .frame(width: 220, height: 128)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            Text(asset.originalFilename)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                Label("\(asset.pixelWidth) × \(asset.pixelHeight)", systemImage: "aspectratio")
                if asset.mediaKind == .video {
                    Label(formattedDuration(asset.duration), systemImage: "timer")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Label(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "No capture date", systemImage: "calendar")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let location = asset.location {
                Label(String(format: "%.4f, %.4f", location.latitude, location.longitude), systemImage: "location.fill")
                    .font(.caption.weight(locationNeedsAttention ? .semibold : .regular))
                    .foregroundStyle(locationNeedsAttention ? Color.orange : Color.secondary)
            } else {
                Label(locationNeedsAttention ? "Location missing" : "No location", systemImage: "location.slash")
                    .font(.caption.weight(locationNeedsAttention ? .semibold : .regular))
                    .foregroundStyle(locationNeedsAttention ? Color.orange : Color.secondary)
            }
        }
        .frame(width: 220, alignment: .leading)
        .padding(12)
        .background(roleColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(roleColor.opacity(0.5), lineWidth: 1)
        }
        .task {
            image = try? await library.thumbnail(
                assetID: asset.id,
                targetSize: .init(width: 440, height: 256),
                networkAccessAllowed: false
            )
        }
    }
}

private struct BatchProposalCard: View {
    let library: PhotoLibraryClient
    let proposal: MergeProposal

    private var displayedAssets: [AssetSnapshot] { [proposal.keeper] + proposal.selectedDonors }
    private var locationNeedsAttention: Bool {
        Set(displayedAssets.map { $0.location != nil }).count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(proposal.confidence.label, systemImage: proposal.keeper.mediaKind == .video ? "video.fill" : "photo.fill")
                    .font(.headline)
                Spacer()
                Text("1 kept • \(proposal.selectedDonors.count) deleted")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .center, spacing: 14) {
                BatchAssetPreview(
                    library: library,
                    asset: proposal.keeper,
                    isKeeper: true,
                    locationNeedsAttention: locationNeedsAttention
                )

                Image(systemName: "arrow.right")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(proposal.selectedDonors) { asset in
                            BatchAssetPreview(
                                library: library,
                                asset: asset,
                                isKeeper: false,
                                locationNeedsAttention: locationNeedsAttention
                            )
                        }
                    }
                }
                .scrollIndicators(.visible)
            }

            if locationNeedsAttention {
                Label("Final keeper location: \(finalLocationText)", systemImage: "location.fill.viewfinder")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            if !proposal.retainedCandidates.isEmpty {
                Label("\(proposal.retainedCandidates.count) additional cop\(proposal.retainedCandidates.count == 1 ? "y is" : "ies are") staying in Photos.", systemImage: "photo.on.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .liquidGlassSurface(cornerRadius: 20)
    }

    private var finalLocationText: String {
        guard let location = proposal.proposedLocation else { return "No location" }
        return String(format: "%.4f, %.4f", location.latitude, location.longitude)
    }
}

private struct BatchConfirmationView: View {
    @ObservedObject var model: CleanerAppModel
    @Environment(\.dismiss) private var dismiss

    private var deletionCount: Int { model.approvedProposals.flatMap(\.selectedDonors).count }

    var body: some View {
        ZStack {
            AmbientBackdrop()
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: "photo.badge.checkmark")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(CleanerStyle.accent)
                        .frame(width: 56, height: 56)
                        .background(CleanerStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Confirm photo & video cleanup").font(.title.bold())
                        Text("See exactly what stays and what moves to Recently Deleted.").foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 16) {
                    Label("\(model.approvedProposals.count) groups", systemImage: "square.stack.3d.up")
                    Label("\(deletionCount) duplicates", systemImage: "trash")
                }
                .font(.headline)

                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(model.approvedProposals) { proposal in
                            BatchProposalCard(library: model.library, proposal: proposal)
                        }
                    }
                    .padding(2)
                }

                Label("Photos keeps deleted items temporarily. The journal can restore metadata, but not media after permanent deletion.", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.orange)
                    .font(.callout)
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button("Move \(deletionCount) Duplicates to Recently Deleted", role: .destructive) { model.applyApproved() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
            .padding(26)
        }
        .frame(width: 960, height: 720)
    }
}
