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

struct CanvasAgentJob: Identifiable, Equatable {
    enum State: String { case running, completed, failed, cancelled }
    var id: UUID
    var notebookID: UUID
    var prompt: String
    var reference: CanvasRect
    var state: State = .running
    var message = "Working…"
    var resultIDs: Set<UUID> = []
    var startedAt = Date()
    var progressLabel: String { prompt.localizedCaseInsensitiveContains("image") ? "Creating image…" : "Working…" }
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
    @Published private(set) var jobs: [CanvasAgentJob] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var taskStores: [UUID: NotebookStore] = [:]
    private var authEpoch: UInt64 = 0
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func request<T: Decodable>(_ path: String, settings: StudioSettings, body: Data? = nil, method: String? = nil) async throws -> T {
        guard let base = URL(string: settings.bridgeURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(base.scheme), base.host != nil, !settings.bridgeToken.isEmpty else {
            throw NotebookError.invalid("Connect your Mac companion in Settings first.")
        }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.timeoutInterval = 420
        req.httpMethod = method ?? (body == nil ? "GET" : "POST")
        req.setValue("Bearer \(settings.bridgeToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, response) = try await session.data(for: req)
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
    func cancel(_ id: UUID? = nil) {
        let ids = id.map { [$0] } ?? Array(tasks.keys)
        for id in ids {
            tasks.removeValue(forKey: id)?.cancel()
            taskStores.removeValue(forKey: id)?.pendingTasks.removeAll { $0.id == id }
            if let index = jobs.firstIndex(where: { $0.id == id && $0.state == .running }) {
                jobs[index].state = .cancelled; jobs[index].message = "Cancelled"
            }
        }
        busy = !tasks.isEmpty
        if !ids.isEmpty { reply = "Request cancelled" }
    }
    func dismissFinishedJobs() { jobs.removeAll { $0.state != .running } }
    func focus(_ job: CanvasAgentJob, store: NotebookStore) {
        guard job.notebookID == store.notebook.id else { return }
        if let id = job.resultIDs.first, store.notebook.objects.contains(where: { $0.id == id }) {
            store.clearSelection()
            store.tool = .select; store.selectedIDs = job.resultIDs
            NotificationCenter.default.post(name: .canvasFocusObject, object: id)
        }
    }

    @discardableResult
    func send(_ prompt: String, store: NotebookStore, library: PDFLibrary,
              completion: ((String, Bool) -> Void)? = nil) -> UUID? {
        let clean = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, store.settings.aiEnabled else { return nil }
        guard tasks.count < 4 else { reply = "Four tasks are already running. Wait for one to finish."; return nil }
        let requestID = UUID(), original = store.notebook, ids = store.selectedIDs
        let reference = store.reference ?? store.viewport
        let settings = store.settings
        let job = CanvasAgentJob(id: requestID, notebookID: original.id, prompt: clean, reference: reference)
        jobs.append(job)
        if jobs.count > 30, let old = jobs.firstIndex(where: { $0.state != .running }) { jobs.remove(at: old) }
        store.pendingTasks.append(CanvasTaskRegion(id: requestID, rect: reference, label: job.progressLabel))
        taskStores[requestID] = store
        busy = true; lastFailure = false; reply = "Working on your canvas…"
        // Capture all context before allowing the next reference or drawing gesture.
        let crop = reference.width < 2 || reference.height < 2
            ? CGRect(x: reference.x - 350, y: reference.y - 250, width: 700, height: 500) : reference.cgRect
        let visual = settings.bridgeURL.isEmpty ? nil : CanvasExporter.snapshot(store: store, rect: crop)?.jpegData(compressionQuality: 0.65)?.base64EncodedString()
        let referenceDocuments = library.documents
        tasks[requestID] = Task {
            var message = "", failed = false, resultIDs = Set<UUID>()
            defer {
                if tasks[requestID] != nil {
                    tasks[requestID] = nil; taskStores[requestID] = nil
                    store.pendingTasks.removeAll { $0.id == requestID }
                    busy = !tasks.isEmpty; reply = message; lastFailure = failed
                    if let i = jobs.firstIndex(where: { $0.id == requestID }) {
                        jobs[i].state = failed ? .failed : .completed
                        jobs[i].message = message; jobs[i].resultIDs = resultIDs
                    }
                    completion?(message, failed)
                    onCompletion?(message, failed)
                }
            }
            do {
                let response: AgentResponse
                if settings.bridgeURL.isEmpty {
                    response = LocalAssistant.respond(prompt: clean, objects: original.objects, reference: reference, selectedIDs: ids)
                } else {
                    let documentText = await library.textContext(query: clean, documents: referenceDocuments)
                    try Task.checkCancellation()
                    struct Payload: Encodable {
                        struct Document: Encodable { var id: UUID; var title: String; var pages: Int }
                        var prompt: String
                        var reasoningEffort: String
                        var objects: [CanvasObject]
                        var selectedIDs: [UUID]
                        var reference: CanvasRect
                        var imageBase64: String?
                        var documentText: String
                        var documents: [Document]
                    }
                    var contextObjects = original.objects
                    for index in contextObjects.indices { contextObjects[index].imageData = nil }
                    let payload = Payload(prompt: clean, reasoningEffort: settings.reasoningEffort, objects: contextObjects, selectedIDs: Array(ids), reference: reference,
                                          imageBase64: visual, documentText: documentText,
                                          documents: referenceDocuments.map { Payload.Document(id: $0.id, title: $0.title, pages: $0.pages) })
                    response = try await request("generate", settings: settings, body: JSONEncoder().encode(payload))
                }
                try Task.checkCancellation()
                guard tasks[requestID] != nil else { return }
                var result = try await library.resolvingPDFInsertions(response, documents: referenceDocuments, reference: reference)
                try Task.checkCancellation()
                guard tasks[requestID] != nil else { return }
                for i in result.operations.indices where result.operations[i].type == "update" {
                    if var item = result.operations[i].object, item.imageData == nil,
                       let old = original.objects.first(where: { $0.id == (result.operations[i].id ?? item.id) }) {
                        item.imageData = old.imageData; result.operations[i].object = item
                    }
                }
                try store.applyAgentResponse(result, basedOn: original)
                message = result.message
                resultIDs = Set(result.operations.compactMap { $0.type == "delete" ? nil : ($0.id ?? $0.object?.id) })
                // Completing background work never changes the user's current tool or draft focus.
            } catch is CancellationError { message = "Request cancelled"; failed = true }
            catch { message = error.localizedDescription; failed = true }
        }
        return requestID
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
