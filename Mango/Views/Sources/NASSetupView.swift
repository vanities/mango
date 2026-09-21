import SwiftUI

/// Adding an SMB share. The password goes to the Keychain, never into the library JSON.
struct NASSetupView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var share = ""
    @State private var path = ""
    @State private var username = ""
    @State private var password = ""
    @State private var port = "445"
    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    private var canSave: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !share.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent("Name") { TextField("NAS", text: $name).multilineTextAlignment(.trailing) }
                    LabeledContent("Host") {
                        TextField("192.168.1.3", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Port") {
                        TextField("445", text: $port)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Section {
                    LabeledContent("Share") {
                        TextField("all", text: $share)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Folder") {
                        TextField("downloads/complete/manga", text: $path)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Library")
                } footer: {
                    Text("Folder is optional — the path inside the share to treat as the top of the library.")
                }
                Section("Credentials") {
                    LabeledContent("Username") {
                        TextField("guest", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Password") {
                        SecureField("", text: $password).multilineTextAlignment(.trailing)
                    }
                }
                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test connection")
                            Spacer()
                            if testing { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(!canSave || testing)
                    if let testResult {
                        Label(testResult, systemImage: testOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(testOK ? .green : .red)
                    }
                }
            }
            .navigationTitle("Add NAS Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }.disabled(!canSave)
                }
            }
        }
    }

    private func makeServer() -> NASServer {
        NASServer(
            id: UUID(),
            name: name.nilIfEmpty ?? host,
            host: host.trimmingCharacters(in: .whitespaces),
            port: Int(port) ?? 445,
            share: share.trimmingCharacters(in: .whitespaces),
            path: path.trimmingCharacters(in: CharacterSet(charactersIn: " /")),
            username: username.trimmingCharacters(in: .whitespaces),
            addedAt: Date()
        )
    }

    private func test() async {
        testing = true
        testResult = nil
        defer { testing = false }
        let server = makeServer()
        do {
            let client = try NASClient(server: server, password: password)
            let entries = try await client.list("")
            await client.disconnect()
            testOK = true
            testResult = "Connected — \(entries.count) items in \(server.path.isEmpty ? server.share : server.path)."
        } catch {
            testOK = false
            testResult = error.localizedDescription
        }
    }

    private func save() {
        library.addServer(makeServer(), password: password)
        dismiss()
    }
}
