import SwiftUI

struct ChatMessageActionMenu: View {
    let context: MessageActionContext
    let listeningMessageID: String?
    let isViewingCachedData: Bool
    let hasActiveStream: Bool
    let isRegeneratingMessage: Bool
    let isEditingMessage: Bool
    let isForkingMessage: Bool
    let onToggleListening: (MessageActionContext) -> Void
    let onRegenerate: (MessageActionContext) -> Void
    let onEdit: (MessageActionContext) -> Void
    let onFork: (MessageActionContext) -> Void
    let onCopy: (MessageActionContext) -> Void

    var body: some View {
        if context.role == .assistant {
            Button {
                onToggleListening(context)
            } label: {
                Label(
                    isListening ? "Stop Listening" : "Listen",
                    systemImage: isListening ? "speaker.slash" : "speaker.wave.2"
                )
            }

            Button {
                onRegenerate(context)
            } label: {
                Label("Regenerate Response", systemImage: "arrow.clockwise")
            }
            .disabled(isViewingCachedData || hasActiveStream || isRegeneratingMessage)
        }

        if context.role == .user {
            Button {
                onEdit(context)
            } label: {
                Label("Edit Message", systemImage: "pencil")
            }
            .disabled(isViewingCachedData || hasActiveStream || isEditingMessage)
        }

        Button {
            onFork(context)
        } label: {
            Label("Fork From Here", systemImage: "arrow.triangle.branch")
        }
        .disabled(isViewingCachedData || hasActiveStream || isForkingMessage)

        Button {
            onCopy(context)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }

    private var isListening: Bool {
        listeningMessageID == context.messageID
    }
}

struct ChatMessageActionsButton<Actions: View>: View {
    let actions: Actions

    init(@ViewBuilder actions: () -> Actions) {
        self.actions = actions()
    }

    var body: some View {
        Menu {
            actions
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 28)
                .background(Color(.secondarySystemBackground), in: Capsule())
                .contentShape(Capsule())
                .chatMinimumHitTarget(in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Message actions")
        .accessibilityHint("Open actions for this message")
    }
}

struct EditMessageSheet: View {
    @Environment(\.dismiss) private var dismiss

    let originalText: String
    @Binding var editDraft: String
    let onSubmit: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $editDraft)
                    .font(.body)
                    .padding()
                    .scrollContentBackground(.hidden)
                    .background(Color(.systemGroupedBackground))
            }
            .navigationTitle("Edit Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        dismiss()
                        onSubmit()
                    }
                    .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .adaptiveFormPresentation()
    }
}
