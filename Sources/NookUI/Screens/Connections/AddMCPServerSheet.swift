import SwiftUI
import NookDesign
import NookCore

public struct AddMCPServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var url: String = ""
    @State private var authHeader: String = ""
    @State private var isConnecting = false
    @State private var errorText: String?

    public let onSave: (String, String, String) async throws -> Void

    public init(onSave: @escaping (String, String, String) async throws -> Void) {
        self.onSave = onSave
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("URL (https://…)", text: $url)
                        .autocorrectionDisabled()
                    SecureField("Auth header / Bearer token (optional)", text: $authHeader)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Nook connects over Streamable HTTP. Tokens stay on this device.")
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .foregroundColor(.red)
                            .font(NookTypography.meta)
                    }
                }
            }
            .navigationTitle("Add connection")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isConnecting {
                        ProgressView()
                    } else {
                        Button("Connect") {
                            Task { await save() }
                        }
                        .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
                    }
                }
            }
            .interactiveDismissDisabled(isConnecting)
        }
    }

    private func save() async {
        guard !isConnecting else { return }
        errorText = nil
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await onSave(name, url, authHeader)
            dismiss()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
