import SwiftUI

struct MemoryScreen: View {
    var viewModel: AppViewModel
    @ObservedObject var memoryStore: AgentMemoryStore
    @Binding var searchText: String
    @State private var selectedKind: AgentMemoryKind?
    @State private var selectedScope: AgentMemoryScope?
    @State private var includeSuperseded = false
    @State private var sort: MemorySort = .newest
    @State private var selectedRecordID: String?
    @State private var isEditorPresented = false
    @State private var editingRecord: AgentMemoryRecord?
    @State private var dreamResult: PiMemoryDreamCycleResult?
    @State private var approvedDreamIDs: Set<String> = []
    @State private var dreamProgress: String?
    @State private var dreamError: String?
    @State private var isDreamSheetPresented = false

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
            startDream()
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
        .sheet(isPresented: $isDreamSheetPresented) {
            DreamProposalSheet(result: dreamResult, approvedIDs: $approvedDreamIDs, progress: dreamProgress, error: dreamError) { selected in
                let proposals = dreamResult?.proposals.filter { selected.contains($0.id) } ?? []
                viewModel.applyDreamMemoryProposals(proposals)
                isDreamSheetPresented = false
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
                                _ = try? memoryStore.reinforceMemory(id: selectedRecord.id)
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
            Toggle("History", isOn: $includeSuperseded).toggleStyle(.switch)
            Button("Clear") { searchText = ""; selectedKind = nil; selectedScope = nil; includeSuperseded = false; sort = .newest }
                .appSecondaryButton()
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
                        Button { _ = try? memoryStore.reinforceMemory(id: record.id) } label: { Label("Reinforce", systemImage: "plus.circle") }
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

    private func startDream() {
        isDreamSheetPresented = true
        dreamResult = nil
        dreamError = nil
        dreamProgress = "Starting dream cycle…"
        approvedDreamIDs = []
        let memories = scopedRecords
        Task {
            let result = await PiMemoryDreamService().propose(memories: memories) { message in
                dreamProgress = message
            }
            dreamResult = result
            approvedDreamIDs = Set(result.proposals.map(\.id))
            dreamProgress = result.proposals.isEmpty ? "No mutations proposed." : "Review proposed mutations before applying."
        }
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

private struct DreamProposalSheet: View {
    let result: PiMemoryDreamCycleResult?
    @Binding var approvedIDs: Set<String>
    let progress: String?
    let error: String?
    let onApply: (Set<String>) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label("Dream Memory", systemImage: "moon.stars").font(.title2.weight(.bold)); Spacer(); if result == nil { ProgressView().controlSize(.small) } }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            if let progress { Text(progress).foregroundStyle(AppTheme.mutedText) }
            if let result {
                if result.proposals.isEmpty { ContentUnavailableView("No Proposals", systemImage: "moon", description: Text("Dream analyzed current memories and found no safe mutations to propose.")) }
                else { List(result.proposals) { proposal in Toggle(isOn: Binding(get: { approvedIDs.contains(proposal.id) }, set: { isOn in if isOn { approvedIDs.insert(proposal.id) } else { approvedIDs.remove(proposal.id) } })) { VStack(alignment: .leading, spacing: 4) { Text("\(proposal.action.displayName): \(proposal.title)").font(.headline); Text(proposal.reasoning).foregroundStyle(AppTheme.mutedText); Text(proposal.sourceMemoryIDs.joined(separator: ", ")).font(.caption).foregroundStyle(AppTheme.mutedText) } } }.frame(minHeight: 340) }
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.appSecondaryButton(); Button("Apply Selected") { onApply(approvedIDs) }.buttonStyle(AppPrimaryButtonStyle()).disabled(result == nil || approvedIDs.isEmpty) }
        }.padding(22).frame(width: 760, height: 560)
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
