import SwiftUI

@MainActor
struct CompanionMemoryView: View {
    let service: any CompanionWorkspaceServing

    @State private var target = "memory"
    @State private var snapshot: CompanionMemorySnapshot?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var editor: MemoryEditorState?
    @State private var isConfirmingReset = false

    init(
        companionURL: URL,
        service: (any CompanionWorkspaceServing)? = nil
    ) {
        self.service = service
            ?? CompanionWorkspaceService(companionURL: companionURL)
    }

    var body: some View {
        List {
            Section {
                Picker("Memory file", selection: $target) {
                    Text("Agent Memory").tag("memory")
                    Text("User Profile").tag("user")
                }
                .pickerStyle(.segmented)
            }

            Section {
                ForEach(
                    Array((snapshot?.entries ?? []).enumerated()),
                    id: \.offset
                ) { index, entry in
                    Button {
                        editor = MemoryEditorState(
                            index: index,
                            original: entry,
                            content: entry
                        )
                    } label: {
                        Text(entry)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await remove(entry) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Entries")
                    Spacer()
                    if let snapshot,
                       let count = snapshot.charCount,
                       let limit = snapshot.charLimit {
                        Text("\(count)/\(limit)")
                            .font(.caption.monospacedDigit())
                    }
                }
            }
        }
        .overlay {
            if isLoading && snapshot == nil {
                ProgressView("Loading Memory...")
            } else if let errorMessage, snapshot == nil {
                ContentUnavailableView {
                    Label(
                        "Memory unavailable",
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else if snapshot?.entries?.isEmpty == true {
                ContentUnavailableView(
                    "No Memory entries",
                    systemImage: "brain"
                )
            }
        }
        .navigationTitle("Memory")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    editor = MemoryEditorState(
                        index: nil,
                        original: nil,
                        content: ""
                    )
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(snapshot == nil)
                .accessibilityLabel("Add Memory entry")

                Menu {
                    Button(role: .destructive) {
                        isConfirmingReset = true
                    } label: {
                        Label("Reset this file", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(snapshot == nil)
            }
        }
        .task(id: target) { await load() }
        .refreshable { await load() }
        .sheet(item: $editor) { state in
            CompanionMemoryEditor(
                state: state,
                onSave: { content in
                    await save(state: state, content: content)
                }
            )
        }
        .confirmationDialog(
            "Reset this built-in Memory file?",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                Task { await reset() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every entry from the selected file.")
        }
        .alert(
            "Memory action failed",
            isPresented: Binding(
                get: { errorMessage != nil && snapshot != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            snapshot = try await service.memory(target: target)
        } catch {
            guard !(error is CancellationError) else { return }
            snapshot = nil
            errorMessage = error.localizedDescription
        }
    }

    private func save(
        state: MemoryEditorState,
        content: String
    ) async -> Bool {
        guard let revision = snapshot?.revision?.nilIfEmpty else {
            return false
        }
        let operation = CompanionMemoryOperation(
            action: state.original == nil ? "add" : "replace",
            oldText: state.original,
            content: content
        )
        do {
            snapshot = try await service.mutateMemory(
                target: target,
                revision: revision,
                operations: [operation]
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func remove(_ entry: String) async {
        guard let revision = snapshot?.revision?.nilIfEmpty else { return }
        do {
            snapshot = try await service.mutateMemory(
                target: target,
                revision: revision,
                operations: [
                    CompanionMemoryOperation(
                        action: "remove",
                        oldText: entry,
                        content: nil
                    )
                ]
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reset() async {
        guard let revision = snapshot?.revision?.nilIfEmpty else { return }
        do {
            snapshot = try await service.resetMemory(
                target: target,
                revision: revision,
                confirmation: "RESET \(target.uppercased())"
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MemoryEditorState: Identifiable {
    let id = UUID()
    let index: Int?
    let original: String?
    let content: String
}

@MainActor
private struct CompanionMemoryEditor: View {
    let state: MemoryEditorState
    let onSave: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var content: String
    @State private var isSaving = false

    init(
        state: MemoryEditorState,
        onSave: @escaping (String) async -> Bool
    ) {
        self.state = state
        self.onSave = onSave
        _content = State(initialValue: state.content)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $content)
                .textSelection(.enabled)
                .padding()
                .navigationTitle(
                    state.original == nil ? "Add Entry" : "Edit Entry"
                )
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            isSaving = true
                            Task {
                                if await onSave(content) {
                                    dismiss()
                                }
                                isSaving = false
                            }
                        }
                        .disabled(
                            isSaving
                                || content.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ).isEmpty
                        )
                    }
                }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
