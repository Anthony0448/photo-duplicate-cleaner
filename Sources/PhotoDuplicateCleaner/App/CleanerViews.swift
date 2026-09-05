import AppKit
import AVFoundation
import AVKit
import SwiftUI

// MARK: - Design tokens

/// Spacing and radius values shared by every screen. Sections step in multiples
/// of eight so the banner, cards, panels, and footer keep the same rhythm.
private enum Layout {
    static let micro: CGFloat = 2
    static let tight: CGFloat = 4
    static let small: CGFloat = 8
    static let snug: CGFloat = 12
    static let medium: CGFloat = 16
    static let large: CGFloat = 24

    static let cardRadius: CGFloat = 12
    static let innerRadius: CGFloat = 10
    static let controlRadius: CGFloat = 8

    static let cardWidth: CGFloat = 316
    static let mediaHeight: CGFloat = 208
    static let attributeRowHeight: CGFloat = 16
    static let batchMediaHeight: CGFloat = 120
    static let actionRowHeight: CGFloat = 20
}

private enum Surface {
    static let card = Color(nsColor: .controlBackgroundColor)
    static let inner = Color.primary.opacity(0.05)
    static let hairline = Color(nsColor: .separatorColor)
}

private enum RoleColor {
    static let keeper = Color.green
    static let removal = Color.red
    static let attention = Color.orange
}

private struct CardSurface: ViewModifier {
    var radius: CGFloat = Layout.cardRadius
    var accent: Color?

    func body(content: Content) -> some View {
        content
            .background(Surface.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(accent?.opacity(0.45) ?? Surface.hairline, lineWidth: accent == nil ? 1 : 1.25)
            }
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }
}

/// The sticky footer that carries each screen's single primary action.
private struct ActionBarSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
#if PHOTO_MODERN_UI
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: Rectangle())
                .overlay(alignment: .top) { Divider() }
        } else {
            content
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
        }
#else
        content
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
#endif
    }
}

private extension View {
    func cardSurface(radius: CGFloat = Layout.cardRadius, accent: Color? = nil) -> some View {
        modifier(CardSurface(radius: radius, accent: accent))
    }

    func actionBarSurface() -> some View {
        modifier(ActionBarSurface())
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

private func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private extension AssetSnapshot {
    /// A short, readable stand-in for filenames that are mostly a UUID:
    /// the capture date plus the first few characters of the longest identifier.
    var compactLabel: String {
        let stem = (originalFilename as NSString).deletingPathExtension
        let identifier = stem
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count >= 4 && $0.contains(where: \.isNumber) }
            .max { $0.count < $1.count }
            .map { String($0.prefix(6)).uppercased() }
        guard let date = creationDate else {
            return identifier.map { "\(stem.prefix(12)) · \($0)" } ?? originalFilename
        }
        let day = date.formatted(date: .abbreviated, time: .omitted)
        return identifier.map { "\(day) · \($0)" } ?? day
    }
}

private func pluralized(_ count: Int, _ singular: String, _ plural: String) -> String {
    count == 1 ? singular : plural
}

// MARK: - Shared building blocks

/// A titled container. Every grouped section on every screen uses this so radii,
/// padding, and header typography stay identical.
private struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary
    var caption: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.medium) {
            HStack(spacing: Layout.small) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.headline)
                Spacer(minLength: Layout.small)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(Layout.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

/// An aligned label/value grid. The label column is trailing-aligned so values
/// share a single left edge, the way Apple's info panels read.
private struct SpecGrid: View {
    struct Item: Identifiable {
        let label: String
        let value: String
        var systemImage: String?
        var tint: Color?
        var wraps = false

        var id: String { label }
    }

    let items: [Item]
    var labelWidth: CGFloat?

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Layout.medium, verticalSpacing: Layout.small) {
            ForEach(items) { item in
                GridRow {
                    Text(item.label)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                        .frame(width: labelWidth, alignment: .trailing)
                    HStack(spacing: Layout.tight) {
                        if let systemImage = item.systemImage {
                            Image(systemName: systemImage)
                                .imageScale(.small)
                        }
                        Text(item.value)
                            .lineLimit(item.wraps ? 3 : 1)
                            .textSelection(.enabled)
                    }
                    .foregroundStyle(item.tint ?? Color.primary)
                }
            }
        }
        .monospacedDigit()
    }
}

private struct RoleBadge: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: Layout.tight) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, Layout.small)
        .padding(.vertical, Layout.tight)
        .background(color.opacity(0.12), in: Capsule())
    }
}

private struct CountChip: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: Layout.tight) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(value, format: .number)
                .fontWeight(.semibold)
                .monospacedDigit()
            Text(label)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, Layout.small)
        .padding(.vertical, Layout.tight)
        .background(Surface.inner, in: Capsule())
    }
}

// MARK: - Root

struct CleanerRootView: View {
    @StateObject private var model = CleanerAppModel()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 264, ideal: 296, max: 360)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 1_080, minHeight: 720)
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
            Divider()
            if model.proposals.isEmpty {
                ContentUnavailableView(
                    model.state == .scanning ? "Scanning Photos" : "No Review Groups",
                    systemImage: model.state == .scanning ? "photo.stack" : "checkmark.circle",
                    description: Text(emptySidebarDescription)
                )
            } else {
                List(selection: $model.selectedProposalID) {
                    if !model.exactProposals.isEmpty {
                        Section("Exact (\(model.exactCount))") {
                            ForEach(model.exactProposals) { proposal in
                                ProposalRow(proposal: proposal).tag(proposal.id)
                            }
                        }
                    }
                    if !model.likelyProposals.isEmpty {
                        Section("Likely visual (\(model.likelyCount))") {
                            ForEach(model.likelyProposals) { proposal in
                                ProposalRow(proposal: proposal).tag(proposal.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if model.state == .scanning {
            // A scan briefly has no measured phase, between batches and while the Photos
            // index is being read. Showing the idle screen there would offer a Scan
            // button in the middle of a scan.
            ScanProgressView(
                progress: model.progress ?? ScanProgress(phase: .inventory, completed: 0, total: 1, detail: "Reading the Photos index"),
                paused: model.isPaused
            )
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
                if model.canResumeScan {
                    Button("Resume", systemImage: "play.fill") { model.resumeScan() }
                }
                Button(model.hasSavedScan ? "Rescan" : "Scan", systemImage: "arrow.clockwise") { model.requestScan() }
                    .disabled(model.scanScopeIsEmpty)
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

// MARK: - Sidebar

private struct ScopeView: View {
    @ObservedObject var model: CleanerAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.medium) {
            HStack(spacing: Layout.snug) {
                ZStack {
                    RoundedRectangle(cornerRadius: Layout.controlRadius, style: .continuous)
                        .fill(Color.accentColor)
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: Layout.micro) {
                    Text("Duplicate Cleaner")
                        .font(.subheadline.weight(.semibold))
                    Text("Private & on-device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: Layout.small) {
                Text("Library scope")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Library scope", selection: $model.scope.kind) {
                    ForEach(ScanScope.Kind.allCases) { kind in Text(kind.label).tag(kind) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if model.authorization != .authorized {
                    Button("Grant Photos Access", systemImage: "photo.badge.checkmark") { model.requestAccessAndLoadAlbums() }
                        .buttonStyle(.bordered)
                } else if model.scope.kind == .selectedAlbums {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Layout.tight) {
                            ForEach(model.albums) { album in
                                Toggle(album.title, isOn: Binding(
                                    get: { model.scope.albumIDs.contains(album.id) },
                                    set: { _ in model.toggleAlbum(album.id) }
                                ))
                                .lineLimit(1)
                                .disabled(!album.canAddContent)
                            }
                        }
                        .padding(Layout.small)
                    }
                    .frame(maxHeight: 176)
                    .background(Surface.inner, in: RoundedRectangle(cornerRadius: Layout.controlRadius, style: .continuous))
                } else if model.scope.kind == .months {
                    MonthScopeView(model: model)
                }
            }

            if model.canResumeScan {
                BatchResumeCard(model: model)
            }

            if !model.scanNotices.isEmpty {
                VStack(alignment: .leading, spacing: Layout.small) {
                    ForEach(Array(model.scanNotices.enumerated()), id: \.offset) { notice in
                        Label(notice.element, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Layout.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Surface.inner, in: RoundedRectangle(cornerRadius: Layout.controlRadius, style: .continuous))
            }

            if !model.proposals.isEmpty {
                VStack(alignment: .leading, spacing: Layout.small) {
                    HStack(spacing: Layout.small) {
                        CountChip(value: model.exactCount, label: "Exact", color: RoleColor.keeper)
                        CountChip(value: model.likelyCount, label: "Visual", color: RoleColor.attention)
                    }
                    if model.exactCount > 0 {
                        Button("Add safe exact groups", systemImage: "checkmark.seal") { model.approveAllConflictFreeExact() }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }
            }

            if model.libraryResultsAreStale {
                VStack(alignment: .leading, spacing: Layout.small) {
                    Label("Photos changed since this scan", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(RoleColor.attention)
                    Button("Rescan Now") { model.rescanAfterLibraryChange() }
                        .controlSize(.small)
                }
                .padding(Layout.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoleColor.attention.opacity(0.10), in: RoundedRectangle(cornerRadius: Layout.controlRadius, style: .continuous))
            } else if let date = model.lastScanDate {
                Text("Saved \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Layout.medium)
        .disabled(model.state == .scanning)
        .task(id: model.scope.kind) {
            if model.scope.kind == .months { model.loadMonths() }
        }
        .onChange(of: model.authorization) { _, access in
            if access == .authorized && model.scope.kind == .months { model.loadMonths() }
        }
    }
}

/// Month-sized batches, for libraries too large to compare in one pass.
private struct MonthScopeView: View {
    @ObservedObject var model: CleanerAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.small) {
            if model.isLoadingMonths && model.months.isEmpty {
                HStack(spacing: Layout.small) {
                    ProgressView().controlSize(.small)
                    Text("Grouping your library by month…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if model.months.isEmpty {
                Text("No photos or videos were found in this library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: Layout.small) {
                    Button("All") { model.selectAllMonths() }
                    Button("None") { model.clearSelectedMonths() }
                    Spacer(minLength: Layout.tight)
                    if model.isLoadingMonths { ProgressView().controlSize(.small) }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Layout.small, pinnedViews: [.sectionHeaders]) {
                        ForEach(yearGroups, id: \.year) { group in
                            Section {
                                ForEach(group.months) { month in
                                    Toggle(isOn: Binding(
                                        get: { model.scope.monthIDs.contains(month.id) },
                                        set: { _ in model.toggleMonth(month.id) }
                                    )) {
                                        HStack(spacing: Layout.tight) {
                                            Text(month.shortTitle)
                                            Spacer(minLength: Layout.tight)
                                            Text(month.assetCount, format: .number)
                                                .foregroundStyle(.secondary)
                                                .monospacedDigit()
                                        }
                                    }
                                    .lineLimit(1)
                                }
                            } header: {
                                YearHeader(model: model, group: group)
                            }
                        }
                    }
                    .padding(Layout.small)
                }
                .frame(maxHeight: 220)
                .background(Surface.inner, in: RoundedRectangle(cornerRadius: Layout.controlRadius, style: .continuous))

                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var summary: String {
        guard !model.selectedMonths.isEmpty else {
            return "Pick the months to compare. Each month is scanned as its own batch, so you can stop after any month and pick up the rest later."
        }
        let monthCount = model.selectedMonths.count
        let items = model.selectedMonthAssetCount.formatted(.number)
        return "\(monthCount) \(pluralized(monthCount, "month", "months")) selected · \(items) \(pluralized(model.selectedMonthAssetCount, "item", "items")). Batches only compare within a month, so copies filed under different months need a whole-library scan."
    }

    private var yearGroups: [YearGroup] {
        var order: [String] = []
        var grouped: [String: [MonthBucket]] = [:]
        for month in model.months {
            let key = month.year.map(String.init) ?? "Undated"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(month)
        }
        return order.map { YearGroup(year: $0, months: grouped[$0] ?? []) }
    }
}

private struct YearGroup {
    let year: String
    let months: [MonthBucket]
}

private struct YearHeader: View {
    @ObservedObject var model: CleanerAppModel
    let group: YearGroup

    var body: some View {
        HStack(spacing: Layout.small) {
            Text(group.year)
                .font(.caption.weight(.semibold))
            Text(assetCount, format: .number)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: Layout.tight)
            Button(allSelected ? "Clear" : "Add") {
                let ids = group.months.map(\.id)
                if allSelected { model.deselectMonths(ids) } else { model.selectMonths(ids) }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.vertical, Layout.micro)
        .background(Surface.card)
    }

    private var assetCount: Int {
        group.months.reduce(0) { $0 + $1.assetCount }
    }

    private var allSelected: Bool {
        !group.months.isEmpty && group.months.allSatisfy { model.scope.monthIDs.contains($0.id) }
    }
}

/// Shown when a batched scan stopped early, so the remaining months are one click away.
private struct BatchResumeCard: View {
    @ObservedObject var model: CleanerAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.small) {
            Label(
                "\(model.completedSegmentCount) of \(model.totalSegmentCount) batches compared",
                systemImage: "pause.circle"
            )
            .font(.caption)
            ProgressView(value: Double(model.completedSegmentCount), total: Double(max(model.totalSegmentCount, 1)))
            Text("The groups already found are kept. Resuming compares only the \(model.remainingSegmentCount) remaining \(pluralized(model.remainingSegmentCount, "batch", "batches")).")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Resume Scan", systemImage: "play.fill") { model.resumeScan() }
                .controlSize(.small)
        }
        .padding(Layout.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: Layout.controlRadius, style: .continuous))
    }
}

private struct ProposalRow: View {
    let proposal: MergeProposal

    var body: some View {
        HStack(spacing: Layout.small) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(proposal.keeper.compactLabel)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Layout.tight)
            // A shape cue as well as colour for the state users act on most.
            if proposal.isApproved {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Layout.tight)
        .help(tooltip)
    }

    private var statusColor: Color {
        if proposal.isApproved { return RoleColor.keeper }
        if !proposal.conflicts.isEmpty { return RoleColor.attention }
        return Color.secondary.opacity(0.35)
    }

    private var tooltip: String {
        let status: String
        if proposal.isApproved {
            status = "In cleanup batch · \(proposal.selectedDonors.count) to delete"
        } else if !proposal.conflicts.isEmpty {
            status = "\(proposal.conflicts.count) metadata \(pluralized(proposal.conflicts.count, "choice", "choices")) to make"
        } else if proposal.selectedDonors.isEmpty {
            status = "No copies marked for deletion yet"
        } else {
            status = "Ready to add · \(proposal.selectedDonors.count) to delete"
        }
        return "\(proposal.keeper.originalFilename)\n\(proposal.confidence.label) · \(status)"
    }
}

// MARK: - Idle and progress

private struct WelcomeView: View {
    @ObservedObject var model: CleanerAppModel

    var body: some View {
        VStack(spacing: Layout.large) {
            Image(systemName: model.hasSavedScan ? "checkmark.circle" : "photo.on.rectangle.angled")
                .font(.system(size: 48, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(model.hasSavedScan ? RoleColor.keeper : Color.accentColor)

            VStack(spacing: Layout.small) {
                Text(model.hasSavedScan ? "Your library is tidy" : "Find duplicates, keep the best")
                    .font(.title2.weight(.semibold))
                Text(welcomeDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Button(model.hasSavedScan ? "Scan Again" : "Scan Photo Library") { model.requestScan() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.scanScopeIsEmpty)

            if model.scanScopeIsEmpty {
                Text(model.scope.kind == .months
                     ? "Choose at least one month in the sidebar."
                     : "Choose at least one album in the sidebar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Layout.large) {
                Label("On-device", systemImage: "lock.shield")
                Label("Review first", systemImage: "eye")
                Label("Recently Deleted", systemImage: "arrow.uturn.backward.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, Layout.small)
        }
        .padding(Layout.large)
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
        VStack(spacing: Layout.medium) {
            Image(systemName: paused ? "pause.circle" : "photo.stack")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
            VStack(spacing: Layout.tight) {
                if let batchLabel = progress.batchLabel {
                    Text(batchLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                Text(paused ? "Scan paused" : progress.phase.rawValue)
                    .font(.title3.weight(.semibold))
                Text("\(progress.completed.formatted(.number)) of \(progress.total.formatted(.number))")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress.fraction)
                .frame(width: 320)
            Text(progress.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 360)
        }
        .padding(Layout.large)
    }
}

// MARK: - Review

private enum CopyDisposition: Hashable {
    case keep
    case delete
}

private struct ProposalDetailView: View {
    @ObservedObject var model: CleanerAppModel
    let proposal: MergeProposal
    @State private var previewedAsset: AssetSnapshot?

    private var assets: [AssetSnapshot] { [proposal.keeper] + proposal.donors }
    private var showsDuration: Bool { assets.contains { $0.mediaKind == .video } }
    private var locationNeedsAttention: Bool { Set(assets.map { $0.location != nil }).count > 1 }
    private var reclaimedBytes: Int64 { proposal.selectedDonors.reduce(0) { $0 + $1.totalKnownBytes } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Layout.large) {
                    header
                    comparison
                    if !proposal.conflicts.isEmpty { conflictSection }
                    summarySection
                    if proposal.confidence == .likelyVisual {
                        Text("Likely visual matches start with every non-keeper marked for deletion. Switch any copy back to Keep to leave it in Photos.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(Layout.large)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            actionBar
        }
        .sheet(item: $previewedAsset) { asset in
            MediaQuickLookView(library: model.library, asset: asset)
        }
    }

    // Quiet page title, then a demoted step trail. Neither competes with the cards.
    private var header: some View {
        VStack(alignment: .leading, spacing: Layout.small) {
            HStack(alignment: .firstTextBaseline, spacing: Layout.medium) {
                VStack(alignment: .leading, spacing: Layout.micro) {
                    Text("Compare copies")
                        .font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if proposal.isApproved {
                    RoleBadge(text: "In cleanup batch", systemImage: "checkmark.circle.fill", color: RoleColor.keeper)
                }
            }
            ReviewSteps(proposal: proposal)
        }
    }

    private var subtitle: String {
        "\(assets.count) copies · \(proposal.confidence.label)"
    }

    private var comparison: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Layout.medium) {
                ForEach(assets) { asset in
                    AssetCard(
                        library: model.library,
                        asset: asset,
                        isKeeper: asset.id == proposal.keeper.id,
                        willDelete: proposal.donorIDsToDelete.contains(asset.id),
                        showsDuration: showsDuration,
                        locationNeedsAttention: locationNeedsAttention,
                        quickLook: { previewedAsset = asset },
                        chooseKeeper: { model.chooseKeeper(proposalID: proposal.id, assetID: asset.id) },
                        toggleDeletion: { model.toggleDeletion(proposalID: proposal.id, assetID: asset.id) }
                    )
                }
            }
            .padding(.vertical, Layout.tight)
        }
    }

    private var conflictSection: some View {
        SectionCard(
            title: "Metadata to preserve",
            systemImage: "slider.horizontal.3",
            tint: RoleColor.attention,
            caption: "Step 3"
        ) {
            VStack(alignment: .leading, spacing: Layout.medium) {
                ForEach(Array(proposal.conflicts.enumerated()), id: \.element.id) { index, conflict in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: Layout.small) {
                        Text(conflict.message)
                            .font(.callout)
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 248, maximum: 360), spacing: Layout.small)],
                            alignment: .leading,
                            spacing: Layout.small
                        ) {
                            ForEach(Array(([proposal.keeper] + proposal.selectedDonors).enumerated()), id: \.element.id) { position, asset in
                                MetadataChoiceCard(
                                    library: model.library,
                                    asset: asset,
                                    isKeeper: position == 0,
                                    isSelected: metadataChoiceIsSelected(conflict.field, asset: asset),
                                    roleLabel: position == 0 ? "Selected keeper" : "Copy \(position + 1) · marked for deletion",
                                    value: conflictValue(conflict.field, asset: asset)
                                ) {
                                    model.resolve(conflict, proposalID: proposal.id, using: asset.id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var summarySection: some View {
        SectionCard(title: "Cleanup summary", systemImage: "arrow.right.circle", tint: .secondary) {
            SpecGrid(items: summaryItems, labelWidth: 168)
                .font(.callout)
        }
    }

    private var summaryItems: [SpecGrid.Item] {
        [
            .init(label: "Keep in Photos", value: proposal.keeper.originalFilename, wraps: true),
            .init(
                label: "Move to Recently Deleted",
                value: proposal.selectedDonors.isEmpty ? "Nothing selected" : proposal.selectedDonors.map(\.originalFilename).joined(separator: ", "),
                wraps: true
            ),
            .init(
                label: "Also keep",
                value: proposal.retainedCandidates.isEmpty ? "No additional copies" : proposal.retainedCandidates.map(\.originalFilename).joined(separator: ", "),
                wraps: true
            ),
            .init(label: "Capture date", value: proposal.proposedCreationDate?.formatted(date: .abbreviated, time: .standard) ?? "None"),
            .init(label: "Location", value: proposal.proposedLocation.map { String(format: "%.5f, %.5f", $0.latitude, $0.longitude) } ?? "None"),
            .init(label: "Caption", value: proposal.proposedCaption ?? "None", wraps: true),
            .init(label: "Favorite", value: proposal.proposedFavorite ? "Yes" : "No"),
            .init(label: "Keywords", value: proposal.proposedKeywords.isEmpty ? "None" : proposal.proposedKeywords.joined(separator: ", "), wraps: true),
            .init(label: "Albums added", value: proposal.albumsToAdd.isEmpty ? "None" : proposal.albumsToAdd.map(\.title).joined(separator: ", "), wraps: true)
        ]
    }

    // One filled button per screen; navigation and batch edits stay plain.
    private var actionBar: some View {
        HStack(spacing: Layout.medium) {
            HStack(spacing: Layout.tight) {
                Button {
                    model.selectAdjacent(to: proposal.id, offset: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Previous group")
                Button {
                    model.selectAdjacent(to: proposal.id, offset: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .help("Next group")
            }
            .buttonStyle(.borderless)

            if let position = model.position(of: proposal.id) {
                Text("\(position.index) of \(position.total)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Layout.medium)

            if proposal.isApproved {
                Button("Remove from Batch") { model.setApproved(false, proposalID: proposal.id) }
                    .buttonStyle(.borderless)
                Button("Next Group") { model.selectAdjacent(to: proposal.id, offset: 1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                statusHint
                Button("Add \(proposal.selectedDonors.count) to Cleanup Batch") {
                    model.approveAndAdvance(proposalID: proposal.id)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!proposal.canApprove)
            }
        }
        .padding(.horizontal, Layout.large)
        .padding(.vertical, Layout.medium)
        .actionBarSurface()
    }

    @ViewBuilder private var statusHint: some View {
        if proposal.selectedDonors.isEmpty {
            Label("Mark at least one copy for deletion", systemImage: "circle.dashed")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !proposal.conflicts.isEmpty {
            Label(
                "Resolve \(proposal.conflicts.count) metadata \(pluralized(proposal.conflicts.count, "choice", "choices"))",
                systemImage: "exclamationmark.circle"
            )
            .font(.caption)
            .foregroundStyle(RoleColor.attention)
        } else if reclaimedBytes > 0 {
            Label("Frees \(formattedBytes(reclaimedBytes))", systemImage: "internaldrive")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
            return parts.joined(separator: " · ")
        }
    }

    private func metadataChoiceIsSelected(_ field: MetadataField, asset: AssetSnapshot) -> Bool {
        switch field {
        case .creationDate:
            return asset.creationDate == proposal.proposedCreationDate
        case .location:
            return asset.location == proposal.proposedLocation
        case .caption:
            return asset.caption?.trimmingCharacters(in: .whitespacesAndNewlines)
                == proposal.proposedCaption?.trimmingCharacters(in: .whitespacesAndNewlines)
        case .hidden:
            return asset.isHidden == proposal.proposedHidden
        case .rating:
            return asset.rating == proposal.proposedRating
        case .adjustments, .resourceTopology:
            return asset.id == proposal.keeper.id
        }
    }
}

private struct ReviewSteps: View {
    let proposal: MergeProposal

    var body: some View {
        HStack(spacing: Layout.small) {
            step(number: 1, text: "Keeper chosen", complete: true)
            separator
            step(
                number: 2,
                text: proposal.selectedDonors.isEmpty ? "Choose deletions" : "\(proposal.selectedDonors.count) marked for deletion",
                complete: !proposal.selectedDonors.isEmpty
            )
            separator
            step(
                number: 3,
                text: proposal.conflicts.isEmpty ? "Metadata ready" : "Choose metadata",
                complete: proposal.conflicts.isEmpty
            )
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var separator: some View {
        Image(systemName: "chevron.compact.right")
            .foregroundStyle(.tertiary)
    }

    private func step(number: Int, text: String, complete: Bool) -> some View {
        HStack(spacing: Layout.tight) {
            Image(systemName: complete ? "checkmark.circle.fill" : "\(number).circle")
                .imageScale(.small)
            Text(text)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .fontWeight(complete ? .regular : .medium)
    }
}

private struct AssetCard: View {
    let library: PhotoLibraryClient
    let asset: AssetSnapshot
    let isKeeper: Bool
    let willDelete: Bool
    let showsDuration: Bool
    let locationNeedsAttention: Bool
    let quickLook: () -> Void
    let chooseKeeper: () -> Void
    let toggleDeletion: () -> Void

    @State private var image: NSImage?
    @State private var thumbnailUnavailable = false
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var accent: Color? {
        if isKeeper { return RoleColor.keeper }
        if willDelete { return RoleColor.removal }
        return nil
    }

    private var disposition: Binding<CopyDisposition> {
        Binding(
            get: { willDelete ? .delete : .keep },
            set: { newValue in
                if (newValue == .delete) != willDelete { toggleDeletion() }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.medium) {
            media
            VStack(alignment: .leading, spacing: Layout.small) {
                badge
                Text(asset.originalFilename)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(asset.originalFilename)
                SpecGrid(items: specs, labelWidth: 68)
                    .font(.caption)
                attributes
            }
            Divider()
            actions
        }
        .padding(Layout.medium)
        .frame(width: Layout.cardWidth, alignment: .leading)
        .cardSurface(accent: accent)
        .overlay {
            // Keyboard focus ring sits outside the card so the role accent stays readable.
            if isFocused {
                RoundedRectangle(cornerRadius: Layout.cardRadius + 2, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2)
                    .padding(-3)
            }
        }
        .task {
            do {
                image = try await library.thumbnail(
                    assetID: asset.id,
                    targetSize: .init(width: 640, height: 480),
                    networkAccessAllowed: false
                )
            } catch {
                thumbnailUnavailable = true
            }
        }
    }

    private var media: some View {
        Button(action: quickLook) {
            ZStack {
                RoundedRectangle(cornerRadius: Layout.innerRadius, style: .continuous)
                    .fill(Surface.inner)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(2)
                } else if thumbnailUnavailable {
                    VStack(spacing: Layout.small) {
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.title3)
                        Text("Open preview to load")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                if asset.mediaKind == .video || isHovering {
                    Image(systemName: asset.mediaKind == .video ? "play.circle.fill" : "eye.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.4))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                }
            }
            .frame(height: Layout.mediaHeight)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Layout.innerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Layout.innerRadius, style: .continuous)
                    .strokeBorder(Surface.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .onKeyPress(.space) {
            quickLook()
            return .handled
        }
        .help(asset.mediaKind == .video ? "Play this video · Space" : "Open a large preview · Space")
    }

    @ViewBuilder private var badge: some View {
        if isKeeper {
            RoleBadge(text: "Keeper", systemImage: "checkmark.circle.fill", color: RoleColor.keeper)
        } else if willDelete {
            RoleBadge(text: "Delete", systemImage: "trash", color: RoleColor.removal)
        } else {
            RoleBadge(text: "Keep", systemImage: "photo.on.rectangle", color: .secondary)
        }
    }

    private var specs: [SpecGrid.Item] {
        var items: [SpecGrid.Item] = [
            .init(label: "Resolution", value: "\(asset.pixelWidth) × \(asset.pixelHeight)"),
            .init(label: "Size", value: formattedBytes(asset.totalKnownBytes))
        ]
        if showsDuration {
            items.append(.init(
                label: "Duration",
                value: asset.mediaKind == .video ? formattedDuration(asset.duration) : "—"
            ))
        }
        items.append(.init(label: "Date", value: asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "None"))
        if let location = asset.location {
            items.append(.init(
                label: "Location",
                value: String(format: "%.4f, %.4f", location.latitude, location.longitude),
                systemImage: "location.fill",
                tint: locationNeedsAttention ? RoleColor.attention : nil
            ))
        } else {
            items.append(.init(
                label: "Location",
                value: locationNeedsAttention ? "Missing — compare" : "None",
                systemImage: "location.slash",
                tint: locationNeedsAttention ? RoleColor.attention : nil
            ))
        }
        return items
    }

    private var attributes: some View {
        HStack(spacing: Layout.small) {
            if asset.isLivePhoto { Label("Live", systemImage: "livephoto") }
            if asset.isRAW { Label("RAW", systemImage: "camera.aperture") }
            if asset.hasAdjustments { Label("Edited", systemImage: "slider.horizontal.3") }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(height: Layout.attributeRowHeight, alignment: .leading)
    }

    @ViewBuilder private var actions: some View {
        if isKeeper {
            Text("Stays in Photos")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: Layout.actionRowHeight)
        } else {
            HStack(spacing: Layout.small) {
                Picker("Disposition", selection: disposition) {
                    Text("Keep").tag(CopyDisposition.keep)
                    Text("Delete").tag(CopyDisposition.delete)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                Spacer(minLength: Layout.tight)
                Button("Make Keeper", action: chooseKeeper)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            .frame(height: Layout.actionRowHeight)
        }
    }
}

private struct MetadataChoiceCard: View {
    let library: PhotoLibraryClient
    let asset: AssetSnapshot
    let isKeeper: Bool
    let isSelected: Bool
    let roleLabel: String
    let value: String
    let choose: () -> Void

    @State private var image: NSImage?
    @State private var isHovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: Layout.snug) {
                ZStack {
                    RoundedRectangle(cornerRadius: Layout.controlRadius, style: .continuous)
                        .fill(Surface.inner)
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: asset.mediaKind == .video ? "video" : "photo")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: Layout.controlRadius, style: .continuous))

                VStack(alignment: .leading, spacing: Layout.tight) {
                    HStack(spacing: Layout.tight) {
                        Circle()
                            .fill(isKeeper ? RoleColor.keeper : RoleColor.removal)
                            .frame(width: 5, height: 5)
                        Text(roleLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(value)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: Layout.tight)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .imageScale(.large)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .padding(Layout.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHovering ? Color.accentColor.opacity(0.08) : Surface.inner,
                in: RoundedRectangle(cornerRadius: Layout.innerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Layout.innerRadius, style: .continuous)
                    .strokeBorder(isHovering ? Color.accentColor.opacity(0.6) : Surface.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Keep this value on the keeper")
        .task {
            image = try? await library.thumbnail(
                assetID: asset.id,
                targetSize: .init(width: 104, height: 104),
                networkAccessAllowed: false
            )
        }
    }
}

// MARK: - Preview sheet

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
            HStack(spacing: Layout.snug) {
                Image(systemName: asset.mediaKind == .video ? "video.fill" : "photo.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: Layout.micro) {
                    Text(asset.originalFilename)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Layout.medium)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Layout.medium)

            Divider()

            ZStack {
                Color.black
                if needsPhotoAccess {
                    ContentUnavailableView {
                        Label("Photos Access Needed", systemImage: "photo.badge.exclamationmark")
                    } description: {
                        Text("PhotoKit needs full Photos access to open this selected library item.")
                    } actions: {
                        HStack(spacing: Layout.small) {
                            Button("Open Privacy Settings") { openPhotosPrivacySettings() }
                            Button("Try Again") { Task { await loadPreview() } }
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
                        .padding(Layout.medium)
                } else if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(Layout.medium)
                } else if isLoading {
                    VStack(spacing: Layout.small) {
                        ProgressView()
                            .controlSize(.large)
                        Text(asset.mediaKind == .video ? "Loading video…" : "Loading photo…")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
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
        return details.joined(separator: " · ")
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

// MARK: - Cleanup confirmation

private struct BatchAssetPreview: View {
    let library: PhotoLibraryClient
    let asset: AssetSnapshot
    let isKeeper: Bool
    let locationNeedsAttention: Bool

    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.small) {
            ZStack {
                RoundedRectangle(cornerRadius: Layout.innerRadius, style: .continuous)
                    .fill(Surface.inner)
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ProgressView().controlSize(.small)
                }
                if asset.mediaKind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 26))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.4))
                }
            }
            .frame(width: 200, height: Layout.batchMediaHeight)
            .clipShape(RoundedRectangle(cornerRadius: Layout.innerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Layout.innerRadius, style: .continuous)
                    .strokeBorder(Surface.hairline, lineWidth: 1)
            }

            RoleBadge(
                text: isKeeper ? "Keeper" : "Delete",
                systemImage: isKeeper ? "checkmark.circle.fill" : "trash",
                color: isKeeper ? RoleColor.keeper : RoleColor.removal
            )

            VStack(alignment: .leading, spacing: Layout.micro) {
                Text(asset.originalFilename)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(asset.originalFilename)
                Text(specLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "No capture date")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if locationNeedsAttention {
                    Label(
                        asset.location == nil ? "No location" : "Has location",
                        systemImage: asset.location == nil ? "location.slash" : "location.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(RoleColor.attention)
                }
            }
        }
        .frame(width: 200, alignment: .leading)
        .padding(Layout.snug)
        .background(Surface.inner, in: RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
        .task {
            image = try? await library.thumbnail(
                assetID: asset.id,
                targetSize: .init(width: 400, height: 240),
                networkAccessAllowed: false
            )
        }
    }

    private var specLine: String {
        var parts = ["\(asset.pixelWidth) × \(asset.pixelHeight)", formattedBytes(asset.totalKnownBytes)]
        if asset.mediaKind == .video { parts.append(formattedDuration(asset.duration)) }
        return parts.joined(separator: " · ")
    }
}

private struct BatchProposalCard: View {
    let library: PhotoLibraryClient
    let proposal: MergeProposal

    private var displayedAssets: [AssetSnapshot] { [proposal.keeper] + proposal.selectedDonors }
    private var locationNeedsAttention: Bool { Set(displayedAssets.map { $0.location != nil }).count > 1 }

    var body: some View {
        SectionCard(
            title: proposal.keeper.compactLabel,
            systemImage: proposal.keeper.mediaKind == .video ? "video" : "photo",
            caption: "1 kept · \(proposal.selectedDonors.count) deleted"
        ) {
            VStack(alignment: .leading, spacing: Layout.medium) {
                HStack(alignment: .top, spacing: Layout.medium) {
                    BatchAssetPreview(
                        library: library,
                        asset: proposal.keeper,
                        isKeeper: true,
                        locationNeedsAttention: locationNeedsAttention
                    )

                    Image(systemName: "arrow.right")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(height: Layout.batchMediaHeight)

                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: Layout.small) {
                            ForEach(proposal.selectedDonors) { asset in
                                BatchAssetPreview(
                                    library: library,
                                    asset: asset,
                                    isKeeper: false,
                                    locationNeedsAttention: locationNeedsAttention
                                )
                            }
                        }
                        .padding(.bottom, Layout.tight)
                    }
                }

                if locationNeedsAttention || !proposal.retainedCandidates.isEmpty {
                    VStack(alignment: .leading, spacing: Layout.tight) {
                        if locationNeedsAttention {
                            Label("Keeper location will be \(finalLocationText)", systemImage: "location")
                                .foregroundStyle(RoleColor.attention)
                        }
                        if !proposal.retainedCandidates.isEmpty {
                            Label(
                                "\(proposal.retainedCandidates.count) additional \(pluralized(proposal.retainedCandidates.count, "copy stays", "copies stay")) in Photos",
                                systemImage: "photo.on.rectangle"
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var finalLocationText: String {
        guard let location = proposal.proposedLocation else { return "empty" }
        return String(format: "%.4f, %.4f", location.latitude, location.longitude)
    }
}

private struct BatchConfirmationView: View {
    @ObservedObject var model: CleanerAppModel
    @Environment(\.dismiss) private var dismiss

    private var deletionCount: Int { model.approvedProposals.flatMap(\.selectedDonors).count }
    private var reclaimedBytes: Int64 {
        model.approvedProposals.flatMap(\.selectedDonors).reduce(0) { $0 + $1.totalKnownBytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Layout.small) {
                Text("Confirm cleanup")
                    .font(.title3.weight(.semibold))
                Text("Review exactly what stays in Photos and what moves to Recently Deleted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: Layout.small) {
                    CountChip(
                        value: model.approvedProposals.count,
                        label: pluralized(model.approvedProposals.count, "group", "groups"),
                        color: .accentColor
                    )
                    CountChip(value: deletionCount, label: "to delete", color: RoleColor.removal)
                }
                .padding(.top, Layout.tight)
            }
            .padding(Layout.large)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            ScrollView {
                LazyVStack(spacing: Layout.medium) {
                    ForEach(model.approvedProposals) { proposal in
                        BatchProposalCard(library: model.library, proposal: proposal)
                    }
                }
                .padding(Layout.large)
            }
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            HStack(spacing: Layout.medium) {
                Label(
                    "Photos keeps deleted items temporarily. The journal restores metadata, not media that Photos has removed for good.",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: Layout.small)

                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
                Button(deleteButtonTitle, role: .destructive) { model.applyApproved() }
                    .buttonStyle(.borderedProminent)
                    .tint(RoleColor.removal)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Layout.large)
            .padding(.vertical, Layout.medium)
        }
        .frame(width: 920, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var deleteButtonTitle: String {
        let noun = pluralized(deletionCount, "Copy", "Copies")
        return reclaimedBytes > 0
            ? "Delete \(deletionCount) \(noun) · \(formattedBytes(reclaimedBytes))"
            : "Delete \(deletionCount) \(noun)"
    }
}
