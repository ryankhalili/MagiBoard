import Foundation
import SwiftUI

struct CloudCatalogStatus: Decodable {
    var configured: Bool
    var connected: Bool
    var provider: String?
    var message: String
}
struct CloudCatalogEntry: Decodable, Identifiable {
    var id: UUID
    var title: String
    var kind: String
    var createdAt: String
    var schemaVersion: Int
}
@MainActor
final class CloudObjectCatalog: ObservableObject {
    @Published var entries: [CloudCatalogEntry] = []
    @Published var status = "Connect your Mac companion to use the cloud catalog."
    @Published var available = false
    @Published var busy = false
    @Published var truncated = false
    func refresh(using agent: ConnectionClient, settings: StudioSettings) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let state: CloudCatalogStatus = try await agent.request("catalog/status", settings: settings)
            available = state.configured && state.connected; status = state.message
            guard available else { entries = []; truncated = false; return }
            struct List: Decodable { var objects: [CloudCatalogEntry]; var truncated: Bool? }
            let result: List = try await agent.request("catalog/objects", settings: settings)
            entries = result.objects; truncated = result.truncated ?? false
        } catch { available = false; entries = []; truncated = false; status = "Cloud catalog unavailable. Check your Mac companion and its Databricks connection." }
    }
    @discardableResult func save(_ object: CanvasObject, using agent: ConnectionClient, settings: StudioSettings) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            struct Upload: Encodable { var object: CanvasObject }
            struct Result: Decodable { var entry: CloudCatalogEntry }
            let result: Result = try await agent.request("catalog/objects", settings: settings, body: JSONEncoder().encode(Upload(object: object)))
            entries.insert(result.entry, at: 0); available = true; status = "Saved a new version of \(result.entry.title) to Databricks."
            return true
        } catch { status = "Could not save this object: \(error.localizedDescription)"; return false }
    }
    func load(_ entry: CloudCatalogEntry, using agent: ConnectionClient, store: NotebookStore) async -> Bool {
        guard !busy else { return false }
        busy = true; defer { busy = false }
        let notebookID = store.notebook.id
        do {
            struct Result: Decodable { var entry: CloudCatalogEntry; var object: CanvasObject }
            let result: Result = try await agent.request("catalog/objects/\(entry.id.uuidString.lowercased())", settings: store.settings)
            guard notebookID == store.notebook.id else { status = "The notebook changed. Load this object again."; return false }
            guard result.entry.id == entry.id, result.entry.schemaVersion == 1 else {
                throw NotebookError.invalid("The companion returned a different or unsupported object version.")
            }
            try NotebookValidation.validate(result.object)
            guard store.insertFromCatalog(result.object) else { status = store.status; return false }
            store.tool = .select
            status = "Loaded \(entry.title) from Databricks."
            return true
        } catch { status = "Could not load this object: \(error.localizedDescription)"; return false }
    }
}

struct ObjectPackage: Codable {
    var format = "magiboard.object"
    var schemaVersion = 1
    var object: CanvasObject
    func validate() throws {
        guard format == "magiboard.object", schemaVersion == 1 else { throw NotebookError.invalid("This object package is not supported by this version of MagiBoard.") }
        try NotebookValidation.validate(object)
    }
}
