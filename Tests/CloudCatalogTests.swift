import XCTest
@testable import CanvasStudio

private final class CatalogURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Reply = (URLRequest) throws -> (Int, Data)
    private static let lock = NSLock()
    private static var replies: [String: Reply] = [:]
    static func set(_ reply: Reply?, host: String) {
        lock.lock(); defer { lock.unlock() }; replies[host] = reply
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".catalog-test.invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let reply = Self.replies[request.url?.host ?? ""]; Self.lock.unlock()
        do {
            guard let reply, let url = request.url else { throw URLError(.badURL) }
            let (status, data) = try reply(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class CloudCatalogTests: XCTestCase {
    private func environment(reply: @escaping CatalogURLProtocol.Reply) -> (NotebookStore, ConnectionClient) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudCatalogTests-\(UUID())")
        let store = NotebookStore(storageURL: directory, loadSaved: false)
        store.newNotebook(title: "Cloud test")
        let host = UUID().uuidString.lowercased() + ".catalog-test.invalid"
        CatalogURLProtocol.set(reply, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocol.self]
        let session = URLSession(configuration: configuration)
        store.settings.bridgeURL = "https://" + host
        store.settings.bridgeToken = "test-catalog-only"
        addTeardownBlock {
            session.invalidateAndCancel(); CatalogURLProtocol.set(nil, host: host)
            try? FileManager.default.removeItem(at: directory)
        }
        return (store, ConnectionClient(session: session))
    }
    private func entry(_ id: UUID = UUID()) -> CloudCatalogEntry {
        CloudCatalogEntry(id: id, title: "Interactive coin", kind: "widget", createdAt: "2026-01-01T00:00:00Z", schemaVersion: 1)
    }
    private func metadata(_ entry: CloudCatalogEntry) -> [String: Any] {
        ["id": entry.id.uuidString, "title": entry.title, "kind": entry.kind, "createdAt": entry.createdAt, "schemaVersion": entry.schemaVersion]
    }
    private func response(_ entry: CloudCatalogEntry, object: CanvasObject) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["entry": metadata(entry), "object": JSONSerialization.jsonObject(with: JSONEncoder().encode(object))])
    }
    private func object() -> CanvasObject {
        CanvasObject(kind: "widget", title: "Interactive coin", x: -400, y: -250, color: "#2563EB80",
            properties: ["count": 2], code: "<button onclick=\"canvasHost.duplicate(canvasObject.id)\">Coin</button>",
            imageData: Data([137, 80, 78, 71, 13, 10, 26, 10]),
            propertySpecs: [ObjectPropertySpec(key: "count", label: "Count", control: "slider", min: 1, max: 10, step: 1)])
    }

    func testRefreshUsesAuthenticatedReadsAndReportsTruncatedVersions() async throws {
        let saved = entry()
        let list = try JSONSerialization.data(withJSONObject: ["objects": [metadata(saved)], "truncated": true])
        let (store, client) = environment { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-catalog-only")
            if request.url?.path == "/catalog/status" {
                return (200, Data(#"{"configured":true,"connected":true,"provider":"Databricks","message":"Ready"}"#.utf8))
            }
            XCTAssertEqual(request.url?.path, "/catalog/objects")
            return (200, list)
        }
        let cloud = CloudObjectCatalog()
        await cloud.refresh(using: client, settings: store.settings)
        XCTAssertTrue(cloud.available); XCTAssertTrue(cloud.truncated)
        XCTAssertEqual(cloud.entries.map(\.id), [saved.id])
        XCTAssertTrue(store.catalog.isEmpty)
    }

    func testCloudLoadAndFileSharingPreserveContentWithFreshLocalIdentity() async throws {
        let saved = entry(), original = object()
        let data = try response(saved, object: original)
        let (store, client) = environment { request in
            XCTAssertEqual(request.url?.path, "/catalog/objects/" + saved.id.uuidString.lowercased())
            return (200, data)
        }
        store.viewport.x = -900; store.viewport.y = -600
        let cloud = CloudObjectCatalog(), count = store.notebook.objects.count
        let loaded = await cloud.load(saved, using: client, store: store)
        XCTAssertTrue(loaded)
        let inserted = try XCTUnwrap(store.notebook.objects.last)
        XCTAssertNotEqual(inserted.id, original.id)
        var expected = original; expected.id = inserted.id; expected.x = -780; expected.y = -420
        XCTAssertEqual(inserted, expected)
        XCTAssertTrue(store.canUndo)
        let packageURL = try XCTUnwrap(store.exportObject(inserted))
        defer { try? FileManager.default.removeItem(at: packageURL) }
        let package = try JSONDecoder().decode(ObjectPackage.self, from: Data(contentsOf: packageURL))
        try package.validate(); XCTAssertEqual(package.object, inserted)
        XCTAssertTrue(store.importObjectPackage(packageURL))
        let catalogCopy = try XCTUnwrap(store.catalog.last)
        XCTAssertNotEqual(catalogCopy.id, inserted.id)
        expected.id = catalogCopy.id; expected.x = 0; expected.y = 0
        XCTAssertEqual(catalogCopy, expected)
        store.undo(); XCTAssertEqual(store.notebook.objects.count, count)
    }

    func testCloudLoadAtObjectLimitReportsFailureWithoutChangingToolOrNotebook() async throws {
        let saved = entry()
        let actualData = try response(saved, object: object())
        let (store, client) = environment { _ in (200, actualData) }
        store.notebook.objects = (0..<2000).map { _ in CanvasObject() }
        store.tool = .pen
        let ids = store.notebook.objects.map(\.id), cloud = CloudObjectCatalog()
        let loaded = await cloud.load(saved, using: client, store: store)
        XCTAssertFalse(loaded); XCTAssertEqual(store.notebook.objects.map(\.id), ids)
        XCTAssertEqual(store.tool, .pen); XCTAssertEqual(cloud.status, store.status)
        XCTAssertFalse(cloud.status.hasPrefix("Loaded "))
    }

    func testWrongVersionAndFailedUploadNeverReportSuccess() async throws {
        let saved = entry(), wrongVersion = try response(entry(), object: object())
        let (store, client) = environment { request in
            request.httpMethod == "POST" ? (503, Data(#"{"error":"Cloud storage unavailable"}"#.utf8)) : (200, wrongVersion)
        }
        let cloud = CloudObjectCatalog(), ids = store.notebook.objects.map(\.id)
        let loaded = await cloud.load(saved, using: client, store: store)
        XCTAssertFalse(loaded); XCTAssertEqual(store.notebook.objects.map(\.id), ids)
        XCTAssertTrue(cloud.status.contains("different or unsupported"))
        let uploaded = await cloud.save(object(), using: client, settings: store.settings)
        XCTAssertFalse(uploaded); XCTAssertTrue(cloud.entries.isEmpty)
        XCTAssertTrue(cloud.status.hasPrefix("Could not save")); XCTAssertFalse(cloud.busy)
    }
}
