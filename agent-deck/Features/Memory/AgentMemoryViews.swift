import SwiftUI

struct MemoryScreen: View {
    var viewModel: AppViewModel
    var memoryStore: AgentMemoryStore
    @Binding var searchText: String
    @State private var selectedKind: AgentMemoryKind?
    @State private var selectedScope: AgentMemoryScope?
    @State private var includeSuperseded = false
    @State private var sort: MemorySort = .newest
    @State private var selectedRecordID: String?
    @State private var isEditorPresented = false
    @State private var editingRecord: AgentMemoryRecord?

    var body: some View {
        AppPage("Memory", subtitle: "Inspect and manage canonical Pi persistent memory") {
            overviewCard
            libraryCard
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDeckNewMemoryRequested)) { _ in
            editingRecord = nil
            isEditorPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDeckRefreshMemoryRequested)) { _ in
            viewModel.refreshAgentMemory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDeckDreamMemoryRequested)) { _ in
            viewModel.startDreamMemory()
        }
        .sheet(isPresented: $isEditorPresented) {
            MemoryEditorSheet(record: editingRecord, selectedProjectPath: viewModel.selectedProjectPath) { draft in
                if let editingRecord {
                    viewModel.updateAgentMemory(id: editingRecord.id, title: draft.title, content: draft.content, reasoning: draft.reasoning, kind: draft.kind, scope: draft.scope, tags: draft.tags, weight: draft.weight, supersedes: draft.supersedes)
                } else {
                    viewModel.createAgentMemory(title: draft.title, content: draft.content, reasoning: draft.reasoning, kind: draft.kind, scope: draft.scope, tags: draft.tags, weight: draft.weight, supersedes: draft.supersedes)
                }
            }
        }
        .onAppear { consumePendingMemorySelection() }
        .onChange(of: viewModel.selectedMemoryID) { _, _ in consumePendingMemorySelection() }
    }

    private var scopedRecords: [AgentMemoryRecord] {
        memoryStore.records(projectPath: viewModel.selectedProjectPath)
    }

    private var filteredRecords: [AgentMemoryRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = scopedRecords.filter { record in
            if !includeSuperseded && !record.isInjectable { return false }
            if let selectedKind, record.kind != selectedKind { return false }
            if let selectedScope, record.scope != selectedScope { return false }
            guard !query.isEmpty else { return true }
            let haystack = ([record.title, record.summary, record.writeReason ?? "", record.kind.displayName, record.scope.displayName, record.projectID, record.supersedes ?? "", record.supersededBy ?? ""] + record.tags).joined(separator: " ").lowercased()
            return haystack.contains(query)
        }
        return sort.apply(filtered)
    }

    private var selectedRecord: AgentMemoryRecord? {
        guard let selectedRecordID else { return filteredRecords.first }
        return filteredRecords.first(where: { $0.id == selectedRecordID }) ?? filteredRecords.first
    }

    private var shouldShowDreamPanel: Bool {
        viewModel.isDreamMemoryRunning || viewModel.dreamMemoryResult != nil || viewModel.dreamMemoryError != nil || viewModel.dreamMemoryProgress != nil
    }

    private var dreamButtonTitle: String {
        if viewModel.isDreamMemoryRunning { return "Dreaming…" }
        if viewModel.dreamMemoryResult != nil { return "Dream Ready" }
        return "Dream"
    }

    private var dreamButtonImage: String {
        if viewModel.isDreamMemoryRunning { return "moon.stars.fill" }
        if viewModel.dreamMemoryResult != nil { return "checkmark.circle" }
        if viewModel.dreamMemoryError != nil { return "exclamationmark.triangle" }
        return "moon.stars"
    }

    private var overviewCard: some View {
        AppCard(title: "Pi Memory", trailing: {
            Toggle("Memory", isOn: Binding(get: { viewModel.appSettings.agentMemoryEnabled }, set: { viewModel.setAgentMemoryEnabled($0) }))
                .appSwitch()
        }) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Backed by ~/.pi/agent/memories/memories.db. The library shows General plus the current project by default; superseded history is available on demand.")
                    .foregroundStyle(AppTheme.mutedText)
                if memoryStore.isLoading {
                    Label("Loading memory…", systemImage: "arrow.clockwise")
                        .foregroundStyle(AppTheme.mutedText)
                } else if let error = memoryStore.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var libraryCard: some View {
        AppCard(title: "Memory Library") {
            VStack(alignment: .leading, spacing: 14) {
                filterBar
                if shouldShowDreamPanel {
                    DreamStatusPanel(viewModel: viewModel)
                }
                if filteredRecords.isEmpty {
                    ContentUnavailableView(scopedRecords.isEmpty ? "No Memories" : "No Matching Memories", systemImage: "brain", description: Text(scopedRecords.isEmpty ? "General plus current-project memory will appear here after loading." : "Try changing search, filters, or history visibility."))
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        memoryList
                        Divider()
                        if let selectedRecord {
                            MemoryDetailView(record: selectedRecord, onEdit: {
                                editingRecord = selectedRecord
                                isEditorPresented = true
                            }, onDelete: {
                                deleteMemory(selectedRecord)
                            }, onReinforce: {
                                Task { @MainActor in _ = try? await memoryStore.reinforceMemory(id: selectedRecord.id) }
                            })
                            .frame(maxWidth: .infinity, minHeight: 430, alignment: .topLeading)
                        }
                    }
                }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("Sort", selection: $sort) { ForEach(MemorySort.allCases) { Text($0.displayName).tag($0) } }
                .labelsHidden()
                .frame(width: 170)
            Picker("Scope", selection: Binding(get: { selectedScope?.rawValue ?? "all" }, set: { selectedScope = $0 == "all" ? nil : AgentMemoryScope(rawValue: $0) })) {
                Text("All Scopes").tag("all")
                ForEach(AgentMemoryScope.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .labelsHidden()
            .frame(width: 140)
            Picker("Type", selection: Binding(get: { selectedKind?.rawValue ?? "all" }, set: { selectedKind = $0 == "all" ? nil : AgentMemoryKind(rawValue: $0) })) {
                Text("All Types").tag("all")
                ForEach(AgentMemoryKind.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .labelsHidden()
            .frame(width: 150)
            Toggle("Show Superseded", isOn: $includeSuperseded)
                .toggleStyle(.switch)
                .help("Show memories that have been superseded by newer entries")
            Button {
                viewModel.startDreamMemory()
            } label: {
                Label(dreamButtonTitle, systemImage: dreamButtonImage)
            }
            .appSecondaryButton()
            .disabled(viewModel.isDreamMemoryRunning)
            .help(viewModel.isDreamMemoryRunning ? "Dream is running in the background" : "Analyze memory and propose mutations")
        }
    }

    private var memoryList: some View {
        List {
            ForEach(filteredRecords) { record in
                MemoryRecordRow(record: record, isSelected: record.id == selectedRecord?.id) { selectedRecordID = record.id }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        Button { editingRecord = record; isEditorPresented = true } label: { Label("Edit", systemImage: "pencil") }
                        Button { Task { @MainActor in _ = try? await memoryStore.reinforceMemory(id: record.id) } } label: { Label("Reinforce", systemImage: "plus.circle") }
                        Divider()
                        Button(role: .destructive) { deleteMemory(record) } label: { Label("Delete Memory", systemImage: "trash") }
                    }
            }
        }
        .listStyle(.plain)
        .scrollIndicators(.hidden)
        .hideNativeScrollers()
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .frame(minWidth: 340, idealWidth: 390, maxWidth: 480, minHeight: 430)
    }

    private func deleteMemory(_ record: AgentMemoryRecord) {
        if selectedRecordID == record.id { selectedRecordID = nil }
        viewModel.deleteAgentMemory(record.id)
    }

    private func consumePendingMemorySelection() {
        guard let id = viewModel.selectedMemoryID else { return }
        includeSuperseded = true
        searchText = ""
        selectedRecordID = id
        viewModel.selectedMemoryID = nil
    }
}

struct MemoryInfoPopover: View {
    let enabled: Bool
    let projectName: String
    let recordCount: Int
    let injectableCount: Int
    let staleCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Pi Memory", systemImage: SidebarItem.memory.systemImage).font(.headline).foregroundStyle(AppTheme.brandAccent)
            Text("Canonical persistent memory backed by ~/.pi/agent/memories/memories.db. Current view includes General plus \(projectName).")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
            HStack { stat("Status", enabled ? "Enabled" : "Paused", color: enabled ? .green : .orange); stat("Visible", "\(recordCount)", color: AppTheme.brandAccent); stat("Current", "\(injectableCount)", color: .green); stat("History", "\(staleCount)", color: .yellow) }
        }
        .padding(16)
        .frame(width: 460, alignment: .leading)
    }

    private func stat(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(color); Text(title).font(.caption2).foregroundStyle(AppTheme.mutedText) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private enum MemorySort: String, CaseIterable, Identifiable {
    case newest, effectiveWeight, scope, kind, title, updated, created
    var id: String { rawValue }
    var displayName: String {
        switch self { case .newest: "Newest"; case .effectiveWeight: "Weight/Relevance"; case .scope: "Scope"; case .kind: "Type"; case .title: "Title"; case .updated: "Updated"; case .created: "Created" }
    }
    func apply(_ records: [AgentMemoryRecord]) -> [AgentMemoryRecord] {
        records.sorted { lhs, rhs in
            switch self {
            case .newest, .created: return lhs.createdAt == rhs.createdAt ? lhs.title < rhs.title : lhs.createdAt > rhs.createdAt
            case .updated: return lhs.updatedAt == rhs.updatedAt ? lhs.title < rhs.title : lhs.updatedAt > rhs.updatedAt
            case .effectiveWeight: return lhs.effectiveWeight == rhs.effectiveWeight ? lhs.createdAt > rhs.createdAt : lhs.effectiveWeight > rhs.effectiveWeight
            case .scope: return lhs.scope.rawValue == rhs.scope.rawValue ? lhs.createdAt > rhs.createdAt : lhs.scope.rawValue < rhs.scope.rawValue
            case .kind: return lhs.kind.rawValue == rhs.kind.rawValue ? lhs.createdAt > rhs.createdAt : lhs.kind.rawValue < rhs.kind.rawValue
            case .title: return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }
}

private struct MemoryRecordRow: View {
    let record: AgentMemoryRecord
    let isSelected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: record.kind.systemImage).font(.headline.weight(.semibold)).foregroundStyle(record.status.tint).frame(width: 30, height: 30).background(record.status.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(record.title.isEmpty ? "Untitled Memory" : record.title).font(.body.weight(.semibold)).lineLimit(1); Spacer(); Text(record.status.displayName).font(.caption).foregroundStyle(AppTheme.mutedText) }
                    Text(record.summary.isEmpty ? "No content." : record.summary).font(.callout).foregroundStyle(AppTheme.mutedText).lineLimit(2)
                    HStack(spacing: 6) { Label(record.kind.displayName, systemImage: record.kind.systemImage); Label(record.scope.displayName, systemImage: record.scope.systemImage); Text(String(format: "w %.2f", record.effectiveWeight)) }
                        .font(.caption).foregroundStyle(AppTheme.mutedText).lineLimit(1)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).appContentSurface(cornerRadius: 12, isSelected: isSelected)
        }.buttonStyle(.plain)
    }
}

private struct MemoryDetailView: View {
    let record: AgentMemoryRecord
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onReinforce: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: record.kind.systemImage).font(.title2.weight(.semibold)).foregroundStyle(record.status.tint).frame(width: 44, height: 44).background(record.status.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 6) { Text(record.title).font(.title3.weight(.bold)).fontWidth(.expanded); Text(record.writeReason ?? "No reasoning provided.").foregroundStyle(AppTheme.mutedText) }
                Spacer()
                Button("Reinforce", action: onReinforce).appSecondaryButton()
                Button("Edit", action: onEdit).appSecondaryButton()
                Button("Delete", role: .destructive, action: onDelete).appSecondaryButton()
            }.padding(14).appContentSurface(cornerRadius: 14)
            HStack(alignment: .top, spacing: 12) {
                MemoryInfoPanel(record: record).frame(width: 250)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Memory Content").font(.headline).fontWidth(.expanded)
                    ScrollView { MarkdownTextView(source: record.summary.isEmpty ? "_No content._" : record.summary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(12) }
                        .frame(minHeight: 250).appContentSurface(cornerRadius: 12)
                }
            }
        }
    }
}

private struct MemoryInfoPanel: View {
    let record: AgentMemoryRecord
    private var rows: [(String, String)] {
        var r = [("Type", record.kind.displayName), ("State", record.status.displayName), ("Scope", record.scope.displayName), ("Project", record.projectID), ("Weight", String(format: "%.2f (effective %.2f)", record.weight, record.effectiveWeight)), ("Created", record.createdAt.formatted(date: .abbreviated, time: .shortened)), ("Updated", record.updatedAt.formatted(date: .abbreviated, time: .shortened)), ("Accesses", "\(record.useCount)"), ("ID", record.id)]
        if let supersedes = record.supersedes { r.append(("Supersedes", supersedes)) }
        if let supersededBy = record.supersededBy { r.append(("Superseded By", supersededBy)) }
        if let synthesized = record.synthesizedFrom, !synthesized.isEmpty { r.append(("Synthesized From", synthesized.joined(separator: ", "))) }
        if !record.tags.isEmpty { r.append(("Tags", record.tags.joined(separator: ", "))) }
        return r
    }
    var body: some View { VStack(alignment: .leading, spacing: 12) { Text("Details").font(.headline).fontWidth(.expanded); AppKeyValueList(rows: rows); AppCopyTextButton(title: "Copy ID", text: record.id) }.padding(12).appContentSurface(cornerRadius: 12) }
}

private struct MemoryDraft { var title: String; var content: String; var reasoning: String; var kind: AgentMemoryKind; var scope: AgentMemoryScope; var tags: [String]; var weight: Double; var supersedes: String? }

private struct MemoryEditorSheet: View {
    let record: AgentMemoryRecord?
    let selectedProjectPath: String?
    let onSave: (MemoryDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var content: String
    @State private var reasoning: String
    @State private var kind: AgentMemoryKind
    @State private var scope: AgentMemoryScope
    @State private var tags: String
    @State private var weight: Double
    @State private var supersedes: String
    init(record: AgentMemoryRecord?, selectedProjectPath: String?, onSave: @escaping (MemoryDraft) -> Void) {
        self.record = record; self.selectedProjectPath = selectedProjectPath; self.onSave = onSave
        _title = State(initialValue: record?.title ?? ""); _content = State(initialValue: record?.summary ?? ""); _reasoning = State(initialValue: record?.writeReason ?? ""); _kind = State(initialValue: record?.kind ?? .insight); _scope = State(initialValue: record?.scope ?? .project); _tags = State(initialValue: record?.tags.joined(separator: ", ") ?? ""); _weight = State(initialValue: record?.weight ?? 0.6); _supersedes = State(initialValue: record?.supersedes ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(record == nil ? "New Memory" : "Edit Memory").font(.title2.weight(.bold)).fontWidth(.expanded)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow { Text("Title").foregroundStyle(AppTheme.mutedText); AppTextField(text: $title, placeholder: "Short descriptive title") }
                GridRow { Text("Type").foregroundStyle(AppTheme.mutedText); Picker("Type", selection: $kind) { ForEach(AgentMemoryKind.allCases) { Label($0.displayName, systemImage: $0.systemImage).tag($0) } }.labelsHidden().frame(maxWidth: 240) }
                GridRow { Text("Scope").foregroundStyle(AppTheme.mutedText); Picker("Scope", selection: $scope) { ForEach(AgentMemoryScope.allCases) { Label($0.displayName, systemImage: $0.systemImage).tag($0) } }.labelsHidden().frame(maxWidth: 240) }
                GridRow { Text("Weight").foregroundStyle(AppTheme.mutedText); Slider(value: $weight, in: 0.3...1.0); Text(String(format: "%.2f", weight)) }
                GridRow { Text("Tags").foregroundStyle(AppTheme.mutedText); AppTextField(text: $tags, placeholder: "Comma-separated tags") }
                GridRow { Text("Supersedes").foregroundStyle(AppTheme.mutedText); AppTextField(text: $supersedes, placeholder: "Optional memory id") }
            }
            VStack(alignment: .leading, spacing: 8) { Text("Reasoning").font(.headline).fontWidth(.expanded); TextEditor(text: $reasoning).frame(minHeight: 80).padding(6).appContentSurface(cornerRadius: 10) }
            VStack(alignment: .leading, spacing: 8) { Text("Content").font(.headline).fontWidth(.expanded); TextEditor(text: $content).font(.body.monospaced()).frame(minHeight: 220).padding(6).appContentSurface(cornerRadius: 10) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.appSecondaryButton(); Button("Save") { onSave(MemoryDraft(title: title.trimmedForMemory, content: content.trimmedForMemory, reasoning: reasoning.trimmedForMemory, kind: kind, scope: scope, tags: parsedTags, weight: weight, supersedes: supersedes.trimmedForMemory.nilIfBlank)); dismiss() }.buttonStyle(AppPrimaryButtonStyle()).disabled(title.trimmedForMemory.isEmpty || (scope == .project && selectedProjectPath == nil)) }
        }.padding(22).frame(width: 780, height: 720)
    }
    private var parsedTags: [String] { tags.split(separator: ",").map { String($0).trimmedForMemory }.filter { !$0.isEmpty } }
}

private struct DreamStatusPanel: View {
    var viewModel: AppViewModel

    private var result: PiMemoryDreamCycleResult? { viewModel.dreamMemoryResult }
    private var actionableProposals: [PiMemoryDreamProposal] {
        result?.proposals.filter { $0.action != .skip } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Label("Dream Memory", systemImage: "moon.stars")
                    .font(.headline)
                    .fontWidth(.expanded)
                if viewModel.isDreamMemoryRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Running in background")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.mutedText)
                } else if result != nil {
                    Label("Ready", systemImage: "checkmark.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
                Spacer()
                if !viewModel.isDreamMemoryRunning {
                    Button("Run Again") { viewModel.startDreamMemory() }
                        .appSecondaryButton()
                    Button("Clear") { viewModel.clearDreamMemoryResult() }
                        .appSecondaryButton()
                }
            }

            if let error = viewModel.dreamMemoryError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            if let progress = viewModel.dreamMemoryProgress {
                Text(progress)
                    .foregroundStyle(AppTheme.mutedText)
            }

            if let result {
                DreamSummaryRow(result: result)
                if actionableProposals.isEmpty {
                    ContentUnavailableView("No Proposals", systemImage: "moon", description: Text("Dream analyzed current memories and found no safe mutations to propose."))
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(PiMemoryDreamPhase.allCases) { phase in
                                let phaseProposals = actionableProposals.filter { $0.phase == phase }
                                if !phaseProposals.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(phase.displayName)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(AppTheme.mutedText)
                                        ForEach(phaseProposals) { proposal in
                                            DreamProposalToggle(
                                                proposal: proposal,
                                                isSelected: Binding(
                                                    get: { viewModel.dreamMemoryApprovedProposalIDs.contains(proposal.id) },
                                                    set: { viewModel.setDreamMemoryProposalApproved(id: proposal.id, isApproved: $0) }
                                                )
                                            )
                                            .padding(10)
                                            .appContentSurface(cornerRadius: 10)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 300)
                }
            }

            if result != nil {
                HStack {
                    Spacer()
                    Button("Apply Selected") {
                        let selected = viewModel.dreamMemoryApprovedProposalIDs
                        let proposals = actionableProposals.filter { selected.contains($0.id) }
                        viewModel.applyDreamMemoryProposals(proposals)
                    }
                    .buttonStyle(AppPrimaryButtonStyle())
                    .disabled(viewModel.dreamMemoryApprovedProposalIDs.isEmpty)
                }
            }
        }
        .padding(14)
        .appContentSurface(cornerRadius: 14)
    }
}

private struct DreamSummaryRow: View {
    let result: PiMemoryDreamCycleResult

    var body: some View {
        HStack(spacing: 8) {
            stat("Clusters", result.clustersReviewed)
            stat("Merged", result.memoriesMerged)
            stat("Created", result.schemasCreated + result.patternsDiscovered)
            stat("Weights", result.weightsAdjusted)
            stat("Flags", result.contradictionsFound)
        }
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(AppTheme.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct DreamProposalToggle: View {
    let proposal: PiMemoryDreamProposal
    @Binding var isSelected: Bool

    var body: some View {
        Toggle(isOn: $isSelected) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: proposal.action.systemImage)
                    .foregroundStyle(proposal.action.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("\(proposal.action.displayName): \(proposal.title)").font(.headline)
                        if proposal.action == .flagContradiction || proposal.action == .skip {
                            Text(proposal.action == .flagContradiction ? "Report-only" : "No-op")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(AppTheme.mutedText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(AppTheme.panelFill, in: Capsule())
                        }
                    }
                    Text(proposal.reasoning).foregroundStyle(AppTheme.mutedText)
                    if !proposal.content.isEmpty && proposal.content != proposal.reasoning {
                        Text(proposal.content).font(.caption).foregroundStyle(AppTheme.mutedText).lineLimit(3)
                    }
                    if !proposal.sourceMemoryIDs.isEmpty {
                        Text("Sources: \(proposal.sourceMemoryIDs.joined(separator: ", "))").font(.caption).foregroundStyle(AppTheme.mutedText)
                    }
                    if !proposal.weightChanges.isEmpty {
                        Text("Weights: " + proposal.weightChanges.sorted(by: { $0.key < $1.key }).map { "\($0.key) → \(String(format: "%.2f", $0.value))" }.joined(separator: ", ")).font(.caption).foregroundStyle(AppTheme.mutedText)
                    }
                }
            }
        }
    }
}

private extension PiMemoryDreamActionKind {
    var systemImage: String {
        switch self {
        case .merge: return "arrow.triangle.merge"
        case .synthesize: return "sparkles"
        case .reweight: return "slider.horizontal.3"
        case .flagContradiction: return "exclamationmark.triangle"
        case .discoverPattern: return "point.3.connected.trianglepath.dotted"
        case .skip: return "moon"
        }
    }

    var tint: Color {
        switch self {
        case .merge, .synthesize, .discoverPattern: return AppTheme.brandAccent
        case .reweight: return .blue
        case .flagContradiction: return .orange
        case .skip: return AppTheme.mutedText
        }
    }
}

struct PiAgentMemoryActivityCard: View {
    let event: AgentMemoryTranscriptEvent
    var body: some View { AppRowCard { HStack(alignment: .top, spacing: 12) { Image(systemName: event.event.systemImage).font(.title3.weight(.semibold)).foregroundStyle(event.event == .blocked ? .red : AppTheme.brandAccent).frame(width: 30, height: 30); VStack(alignment: .leading, spacing: 3) { Text(event.title).font(.headline); Text(event.summary).font(.callout).foregroundStyle(AppTheme.mutedText); if let titles = event.memoryTitles, !titles.isEmpty { ForEach(Array(zip(event.memoryIDs, titles).enumerated()), id: \.offset) { _, pair in injectedMemoryRow(id: pair.0, title: pair.1) } } else if !event.memoryIDs.isEmpty { Text("\(event.memoryIDs.count) memor\(event.memoryIDs.count == 1 ? "y" : "ies")").font(.caption.weight(.medium)).foregroundStyle(AppTheme.mutedText) } }; Spacer() } } }
    private func injectedMemoryRow(id: String, title: String) -> some View { Button { NotificationCenter.default.post(name: .agentDeckOpenMemoryRequested, object: nil, userInfo: ["id": id]) } label: { HStack(spacing: 6) { Text(title.isEmpty ? "Untitled Memory" : title).font(.caption.weight(.medium)).foregroundStyle(.primary).lineLimit(1); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(AppTheme.mutedText); Spacer(minLength: 0) }.contentShape(Rectangle()) }.buttonStyle(.plain) }
}

private extension AgentMemoryKind { var systemImage: String { switch self { case .fact: "checkmark.seal"; case .event: "calendar.badge.clock"; case .procedure: "list.bullet.rectangle"; case .insight: "lightbulb" } } }
private extension AgentMemoryScope { var systemImage: String { switch self { case .general: "globe"; case .project: "folder" } } }
private extension AgentMemoryStatus { var tint: Color { switch self { case .active: .green; case .stale: .yellow } } }
private extension String { var trimmedForMemory: String { trimmingCharacters(in: .whitespacesAndNewlines) }; var nilIfBlank: String? { trimmedForMemory.isEmpty ? nil : trimmedForMemory } }
