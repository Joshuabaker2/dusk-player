import SwiftUI

@MainActor
@Observable
final class SonarrSettingsViewModel {
    var serverURL = ""
    var apiKey = ""
    private(set) var isWorking = false
    private(set) var message: String?

    func load(_ service: SonarrService) {
        serverURL = service.connection?.baseURL.absoluteString ?? ""
        // Never prefill or expose a stored administrative key in the form.
        apiKey = ""
    }
    func connect(_ service: SonarrService) async {
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            if service.isConnected { try await service.testConnection() }
            else { try await service.connect(url: serverURL, apiKey: apiKey); apiKey = "" }
            message = "Connection verified."
        } catch { message = error.localizedDescription }
    }
    func disconnect(_ service: SonarrService) {
        service.disconnect()
        apiKey = ""
        message = nil
    }
}

#if !os(tvOS)
struct SonarrSettingsView: View {
    @Environment(SonarrService.self) private var service
    @State private var model = SonarrSettingsViewModel()

    var body: some View {
        List {
            Section {
                TextField("Server URL", text: $model.serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .disabled(service.isConnected || model.isWorking)
                if !service.isConnected {
                    SecureField("API key", text: $model.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(model.isWorking)
                }
                LabeledContent("Status", value: service.connectionSubtitle)
            } header: {
                Text("Sonarr Server")
            } footer: {
                Text("Use the instance API key from Sonarr Settings → General → Security, not an account password. This key gives Dusk access to your Sonarr instance. Use https:// for encryption, or explicitly enter http:// for a local unencrypted connection. Reverse-proxy subpaths are supported.")
            }
            .listRowBackground(Color.duskSurface)
            Section {
                Button {
                    Task { await model.connect(service) }
                } label: {
                    HStack {
                        Text(service.isConnected ? "Test Connection" : "Connect")
                        Spacer()
                        if model.isWorking { ProgressView().tint(Color.duskAccent) }
                    }
                }
                .disabled(model.isWorking || (!service.isConnected && (model.serverURL.isEmpty || model.apiKey.isEmpty)))
                if service.isConnected {
                    Button("Disconnect", role: .destructive) { model.disconnect(service) }
                        .disabled(model.isWorking)
                }
            } footer: {
                Text("Connects only this Plex user and server. Downloads go to your server through Sonarr; they are separate from media saved offline on this device.")
            }
            .listRowBackground(Color.duskSurface)
            if let message = model.message ?? service.lastConnectionError {
                Section { Text(message).foregroundStyle(Color.duskTextSecondary) }
                    .listRowBackground(Color.duskSurface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.duskBackground.ignoresSafeArea())
        .duskNavigationTitle("Sonarr")
        .task { model.load(service) }
    }
}
#endif
