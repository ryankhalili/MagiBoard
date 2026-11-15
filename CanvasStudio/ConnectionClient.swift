import Foundation
import SwiftUI
import Speech
import AVFoundation

struct BridgeStatus: Decodable {
    var connected: Bool
    var provider: String?
    var plan: String?
}
struct DeviceLogin: Decodable {
    var verificationUrl: String?
    var userCode: String?
    var loginId: String?
}

@MainActor
final class ConnectionClient: ObservableObject {
    @Published var busy = false
    @Published var connected = false
    @Published var connectionLabel = "Not connected"
    @Published var reply = ""
    @Published var lastFailure = false
    var onCompletion: ((String, Bool) -> Void)?
    @Published var login: DeviceLogin?
    private var activeTask: Task<Void, Never>?
    private var activeRequestID: UUID?
    private var authEpoch: UInt64 = 0

    func request<T: Decodable>(_ path: String, settings: StudioSettings, body: Data? = nil, method: String? = nil) async throws -> T {
        guard let base = URL(string: settings.bridgeURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(base.scheme), base.host != nil, !settings.bridgeToken.isEmpty else {
            throw NotebookError.invalid("Connect your Mac companion in Settings first.")
        }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.timeoutInterval = 240
        req.httpMethod = method ?? (body == nil ? "GET" : "POST")
        req.setValue("Bearer \(settings.bridgeToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw NotebookError.invalid(error?["error"] as? String ?? "The companion could not complete this request.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func check(_ settings: StudioSettings) async {
        authEpoch &+= 1
        let epoch = authEpoch
        do {
            let state: BridgeStatus = try await request("status", settings: settings)
            guard authEpoch == epoch, !Task.isCancelled else { return }
            connected = state.connected
            if connected { login = nil }
            connectionLabel = connected ? "ChatGPT connected\(state.plan.map { " · \($0.capitalized)" } ?? "")" : "Companion ready · sign in"
        } catch {
            guard authEpoch == epoch, !Task.isCancelled else { return }
            connected = false; connectionLabel = error.localizedDescription
        }
    }
    func signIn(_ settings: StudioSettings) async {
        authEpoch &+= 1
        let epoch = authEpoch
        do {
            let result: DeviceLogin = try await request("auth/start", settings: settings, body: Data("{}".utf8))
            guard authEpoch == epoch, !Task.isCancelled else { return }
            login = result; connectionLabel = "Complete sign-in in your browser"
        } catch {
            guard authEpoch == epoch, !Task.isCancelled else { return }
            connectionLabel = error.localizedDescription
        }
    }
    func disconnect(_ store: NotebookStore) {
        authEpoch &+= 1
        let epoch = authEpoch
        cancel()
        let previous = store.settings
        store.settings.bridgeToken = ""; store.settings.bridgeURL = ""
        connected = false; login = nil; connectionLabel = "Disconnected from this iPad"
        Task {
            struct Ack: Decodable {}
            do {
                let _: Ack = try await request("disconnect", settings: previous, body: Data("{}".utf8))
            } catch {
                guard authEpoch == epoch else { return }
                if store.settings.bridgeToken.isEmpty { connectionLabel = "Connection removed · companion unreachable" }
            }
        }
    }
    func cancel() { activeRequestID = nil; activeTask?.cancel(); activeTask = nil; busy = false; reply = "Request cancelled" }

    func send(_ prompt: String, store: NotebookStore, library: PDFLibrary) {
        guard !busy, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, store.settings.aiEnabled else { return }
        busy = true; lastFailure = false; reply = "Working on your canvas…"
        let requestID = UUID(); activeRequestID = requestID
        let original = store.notebook
        let ids = store.selectedIDs
        let reference = store.reference ?? store.viewport
        activeTask = Task {
            defer {
                if activeRequestID == requestID {
                    busy = false; activeTask = nil; activeRequestID = nil
                    onCompletion?(reply, lastFailure)
                }
            }
            do {
                let response: AgentResponse
                if store.settings.bridgeURL.isEmpty {
                    response = LocalAssistant.respond(prompt: prompt, objects: original.objects, reference: reference, selectedIDs: ids)
                } else {
                    struct Payload: Encodable {
                        var prompt: String
                        var objects: [CanvasObject]
                        var selectedIDs: [UUID]
                        var reference: CanvasRect
                        var imageBase64: String?
                        var documentText: String
                    }
                    var contextObjects = original.objects
                    // Raster content travels once as a bounded visual context; keep structured objects lean.
                    for index in contextObjects.indices { contextObjects[index].imageData = nil }
                    let crop = reference.width < 2 || reference.height < 2
                        ? CGRect(x: reference.x - 350, y: reference.y - 250, width: 700, height: 500)
                        : reference.cgRect
                    let snapshot = CanvasExporter.snapshot(store: store, rect: crop)
                    let visual = snapshot?.jpegData(compressionQuality: 0.65)?.base64EncodedString()
                    let payload = Payload(prompt: prompt, objects: contextObjects, selectedIDs: Array(ids), reference: reference,
                                          imageBase64: visual, documentText: library.textContext(query: prompt))
                    response = try await request("generate", settings: store.settings, body: JSONEncoder().encode(payload))
                }
                try Task.checkCancellation()
                guard activeRequestID == requestID else { return }
                guard store.notebook == original else {
                    lastFailure = true; reply = "The canvas changed while I was working. Send again to use the latest version."; return
                }
                // An agent changing metadata must not discard an existing image's bytes.
                var result = response
                for i in result.operations.indices where result.operations[i].type == "update" {
                    if var item = result.operations[i].object, item.imageData == nil,
                       let old = original.objects.first(where: { $0.id == (result.operations[i].id ?? item.id) }) {
                        item.imageData = old.imageData; result.operations[i].object = item
                    }
                }
                try store.apply(result)
                reply = result.message
                if !result.operations.isEmpty { store.tool = .select }
            } catch is CancellationError { if activeRequestID == requestID { lastFailure = true; reply = "Request cancelled" } }
            catch { if activeRequestID == requestID { lastFailure = true; reply = error.localizedDescription } }
        }
    }
    static func importPairing(_ url: URL, into store: NotebookStore) {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            struct Pair: Decodable { var url: String; var token: String }
            let data = try Data(contentsOf: url)
            guard data.count < 16_384 else { throw NotebookError.invalid("Invalid pairing file.") }
            let pair = try JSONDecoder().decode(Pair.self, from: data)
            guard let address = URL(string: pair.url), ["http", "https"].contains(address.scheme), address.host != nil,
                  pair.token.count >= 16, pair.token.count <= 512 else { throw NotebookError.invalid("Invalid pairing file.") }
            store.settings.bridgeURL = pair.url; store.settings.bridgeToken = pair.token
            store.status = "Mac companion paired"
        } catch { store.status = error.localizedDescription }
    }
}
