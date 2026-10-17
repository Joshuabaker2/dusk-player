import Foundation

struct SonarrConnection: Codable, Sendable {
    let baseURL: URL
    let apiKey: String
    let profileID: String
    let serverID: String
}

enum SonarrCredentialStore {
    private static let key = "SonarrConnections"
    static func load() -> [SonarrConnection] {
        guard let data = KeychainHelper.load(key: key) else { return [] }
        return (try? JSONDecoder().decode([SonarrConnection].self, from: data)) ?? []
    }
    static func save(_ connections: [SonarrConnection]) {
        guard !connections.isEmpty else { KeychainHelper.delete(key: key); return }
        guard let data = try? JSONEncoder().encode(connections) else { return }
        KeychainHelper.save(key: key, data: data)
    }
}

enum SonarrError: LocalizedError {
    case invalidURL, notConnected, contextChanged, invalidResponse, unauthorized, denied
    case server(Int), message(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid HTTP or HTTPS Sonarr server URL."
        case .notConnected: "Connect Sonarr for this Plex user and server in Settings."
        case .contextChanged: "The active Plex user or server changed."
        case .invalidResponse: "Sonarr returned an unexpected response."
        case .unauthorized: "Sonarr rejected the API key. Update the connection in Settings."
        case .denied: "Sonarr denied this request. Check server or reverse-proxy permissions."
        case .server(let code): "Sonarr returned HTTP \(code)."
        case .message(let message): message
        }
    }
}

/// Do not forward the instance's administrative key to a redirected host or downgrade HTTPS.
final class SonarrSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let next = request.url,
              original.scheme?.lowercased() == next.scheme?.lowercased(),
              original.host?.lowercased() == next.host?.lowercased(),
              original.port == next.port else { completionHandler(nil); return }
        completionHandler(request)
    }
}
