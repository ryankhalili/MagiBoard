import XCTest
import UIKit
import PencilKit
import ImageIO
import UniformTypeIdentifiers
@testable import CanvasStudio

/// A private session transport lets tests finish requests in any order, without
/// network credentials, microphone access, real service calls or timer races.
private final class AgentTransportFixture: @unchecked Sendable {
    let host = UUID().uuidString.lowercased() + ".agent-test.invalid"
    let session: URLSession
    private let lock = NSLock()
    private var requests: [String: ControlledAgentURLProtocol] = [:]
    private var payloads: [String: [String: Any]] = [:]
    var onRequest: ((String) -> Void)?
    var url: String { "https://" + host }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlledAgentURLProtocol.self]
        session = URLSession(configuration: configuration)
        ControlledAgentURLProtocol.register(self)
    }
    func close() { session.invalidateAndCancel(); ControlledAgentURLProtocol.unregister(host) }
    fileprivate func receive(_ transport: ControlledAgentURLProtocol) {
        let payload = Self.body(of: transport.request)
        let prompt = payload["prompt"] as? String ?? ""
        lock.lock(); requests[prompt] = transport; payloads[prompt] = payload; let callback = onRequest; lock.unlock()
        callback?(prompt)
    }
    func payload(_ prompt: String) -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return payloads[prompt] }
    @discardableResult
    func finish(_ prompt: String, with response: AgentResponse) throws -> Bool {
        lock.lock(); let transport = requests.removeValue(forKey: prompt); lock.unlock()
        guard let transport else { throw NotebookError.invalid("Test did not receive request: \(prompt)") }
        return transport.finish(try JSONEncoder().encode(response))
    }
    private static func body(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

private final class ControlledAgentURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var fixtures: [String: AgentTransportFixture] = [:]
    private let stateLock = NSLock()
    private var stopped = false
    static func register(_ fixture: AgentTransportFixture) { registryLock.lock(); fixtures[fixture.host] = fixture; registryLock.unlock() }
    static func unregister(_ host: String) { registryLock.lock(); fixtures.removeValue(forKey: host); registryLock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".agent-test.invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.registryLock.lock(); let fixture = Self.fixtures[request.url?.host ?? ""]; Self.registryLock.unlock()
        guard let fixture else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        fixture.receive(self)
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
    func finish(_ data: Data) -> Bool {
        stateLock.lock(); let canFinish = !stopped; stopped = true; stateLock.unlock()
        guard canFinish, let url = request.url else { return false }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
        return true
    }
}

@MainActor
final class AgentTaskTests: XCTestCase {
    private func environment() throws -> (NotebookStore, PDFLibrary, AgentTransportFixture, ConnectionClient) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentTaskTests-\(UUID())")
        let store = NotebookStore(storageURL: directory, loadSaved: false)
        store.newNotebook(title: "Independent tasks")
        let fixture = AgentTransportFixture()
        store.settings.bridgeURL = fixture.url; store.settings.bridgeToken = "test-transport-only"
        store.reference = CanvasRect(x: -100, y: -80, width: 180, height: 140)
        store.tool = .magic
        let library = PDFLibrary(directory: directory.appendingPathComponent("References"))
        let client = ConnectionClient(session: fixture.session)
        addTeardownBlock { fixture.close(); try? FileManager.default.removeItem(at: directory) }
        return (store, library, fixture, client)
    }
    private func drawingData() -> Data {
        let points = [CGPoint(x: -80, y: -50), CGPoint(x: 40, y: 25)].enumerated().map {
            PKStrokePoint(location: $0.element, timeOffset: Double($0.offset) * 0.1, size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))]).dataRepresentation()
    }
    private func started(_ fixture: AgentTransportFixture, count: Int = 2) -> XCTestExpectation {
        let received = expectation(description: "All independent requests reached the private transport")
        received.expectedFulfillmentCount = count
        received.assertForOverFulfill = true
        fixture.onRequest = { _ in received.fulfill() }
        return received
    }

    func testConcurrentCompletionsMergeOutOfOrderAndPreserveInkToolAndNewReference() async throws {
        let (store, library, transport, client) = try environment()
        let received = started(transport)
        let first = expectation(description: "First request completes once")
        let second = expectation(description: "Second request completes once")
        first.assertForOverFulfill = true; second.assertForOverFulfill = true
        var callbackCount = 0
        client.onCompletion = { _, failed in XCTAssertFalse(failed); callbackCount += 1 }
        defer { client.onCompletion = nil; client.cancel() }
        let firstRegion = try XCTUnwrap(store.reference)
        store.settings.reasoningEffort = "high"
        let firstID = try XCTUnwrap(client.send("first region", store: store, library: library) { _, failed in
            XCTAssertFalse(failed); XCTAssertFalse(client.busy); first.fulfill()
        })
        let secondRegion = CanvasRect(x: 300, y: 400, width: 220, height: 160)
        store.reference = secondRegion
        store.settings.reasoningEffort = "low"
        let secondID = try XCTUnwrap(client.send("second region", store: store, library: library) { _, failed in
            XCTAssertFalse(failed); XCTAssertTrue(client.busy, "The first task must remain active"); second.fulfill()
        })
        store.settings.reasoningEffort = "medium"
        XCTAssertEqual(Set(store.pendingTasks.map(\.id)), [firstID, secondID])
        await fulfillment(of: [received], timeout: 3)
        XCTAssertEqual((transport.payload("first region")?["reference"] as? [String: Double])?["x"], firstRegion.x)
        XCTAssertEqual((transport.payload("second region")?["reference"] as? [String: Double])?["x"], secondRegion.x)
        XCTAssertEqual(transport.payload("first region")?["reasoningEffort"] as? String, "high")
        XCTAssertEqual(transport.payload("second region")?["reasoningEffort"] as? String, "low")
        let freshReference = CanvasRect(x: 900, y: -500, width: 80, height: 90)
        store.reference = freshReference; store.tool = .pen
        let ink = drawingData(); store.setDrawing(ink)
        let a = CanvasObject(title: "First result", x: firstRegion.x, y: firstRegion.y)
        let b = CanvasObject(title: "Second result", x: secondRegion.x, y: secondRegion.y)
        try transport.finish("second region", with: AgentResponse(message: "Second done", operations: [AgentOperation(type: "add", object: b)]))
        await fulfillment(of: [second], timeout: 3)
        XCTAssertEqual(store.notebook.objects, [b])
        XCTAssertEqual(store.pendingTasks.map(\.id), [firstID])
        try transport.finish("first region", with: AgentResponse(message: "First done", operations: [AgentOperation(type: "add", object: a)]))
        await fulfillment(of: [first], timeout: 3)
        XCTAssertEqual(Set(store.notebook.objects.map(\.id)), [a.id, b.id])
        XCTAssertEqual(callbackCount, 2)
        XCTAssertTrue(client.jobs.allSatisfy { $0.state == .completed })
        XCTAssertTrue(store.pendingTasks.isEmpty); XCTAssertFalse(client.busy)
        XCTAssertEqual(store.notebook.drawingData, ink)
        XCTAssertEqual(store.reference, freshReference); XCTAssertEqual(store.tool, .pen)
        XCTAssertTrue(store.selectedIDs.isEmpty)
        store.undo(); store.undo()
        XCTAssertTrue(store.notebook.objects.isEmpty)
        XCTAssertEqual(store.notebook.drawingData, ink, "Undoing AI additions must preserve handwriting made while they ran")
    }

    func testConflictingConcurrentUpdateRejectsEntireBatchWithoutLosingInk() async throws {
        let (store, library, transport, client) = try environment()
        let source = CanvasObject(title: "Shared triangle", shape: "triangle")
        store.notebook.objects = [source]
        let received = started(transport)
        let winner = expectation(description: "First update succeeds")
        let conflict = expectation(description: "Stale update reports one conflict")
        winner.assertForOverFulfill = true; conflict.assertForOverFulfill = true
        var callbacks = 0
        client.onCompletion = { _, _ in callbacks += 1 }
        defer { client.onCompletion = nil; client.cancel() }
        client.send("winner", store: store, library: library) { _, failed in XCTAssertFalse(failed); winner.fulfill() }
        client.send("stale batch", store: store, library: library) { message, failed in
            XCTAssertTrue(failed); XCTAssertTrue(message.contains("edited")); conflict.fulfill()
        }
        await fulfillment(of: [received], timeout: 3)
        let ink = drawingData(); store.setDrawing(ink)
        var green = source; green.color = "#16A34A"
        var red = source; red.color = "#EF4444"
        let shouldNotAppear = CanvasObject(title: "Must not partially apply")
        try transport.finish("winner", with: AgentResponse(message: "Green", operations: [AgentOperation(type: "update", id: source.id, object: green)]))
        await fulfillment(of: [winner], timeout: 3)
        try transport.finish("stale batch", with: AgentResponse(message: "Stale", operations: [
            AgentOperation(type: "add", object: shouldNotAppear), AgentOperation(type: "update", id: source.id, object: red)
        ]))
        await fulfillment(of: [conflict], timeout: 3)
        XCTAssertEqual(store.notebook.objects, [green])
        XCTAssertEqual(store.notebook.drawingData, ink)
        XCTAssertEqual(callbacks, 2)
        XCTAssertEqual(client.jobs.filter { $0.state == .failed }.count, 1)
        XCTAssertFalse(client.busy); XCTAssertTrue(store.pendingTasks.isEmpty)
        store.undo()
        XCTAssertEqual(store.notebook.objects, [source], "Rejected batch must not add an undo step")
        XCTAssertEqual(store.notebook.drawingData, ink)
    }

    func testCancellingOneTaskDoesNotCancelOtherOrDeliverLateCallback() async throws {
        let (store, library, transport, client) = try environment()
        let received = started(transport)
        let cancelledCallback = expectation(description: "Cancelled task never returns a stale spoken reply")
        cancelledCallback.isInverted = true
        let completed = expectation(description: "Independent task completes exactly once")
        completed.assertForOverFulfill = true
        var callbackCount = 0
        client.onCompletion = { _, _ in callbackCount += 1 }
        defer { client.onCompletion = nil; client.cancel() }
        let cancelledID = try XCTUnwrap(client.send("cancel me", store: store, library: library) { _, _ in cancelledCallback.fulfill() })
        let activeID = try XCTUnwrap(client.send("keep me", store: store, library: library) { _, failed in XCTAssertFalse(failed); completed.fulfill() })
        await fulfillment(of: [received], timeout: 3)
        client.cancel(cancelledID)
        XCTAssertTrue(client.busy)
        XCTAssertEqual(store.pendingTasks.map(\.id), [activeID])
        XCTAssertEqual(client.jobs.first { $0.id == cancelledID }?.state, .cancelled)
        try transport.finish("cancel me", with: AgentResponse(message: "Too late", operations: [AgentOperation(type: "add", object: CanvasObject(title: "Discard me"))]))
        let result = CanvasObject(title: "Kept result")
        try transport.finish("keep me", with: AgentResponse(message: "Kept", operations: [AgentOperation(type: "add", object: result)]))
        await fulfillment(of: [completed], timeout: 3)
        await fulfillment(of: [cancelledCallback], timeout: 0.2)
        XCTAssertEqual(store.notebook.objects, [result])
        XCTAssertEqual(callbackCount, 1)
        XCTAssertFalse(client.busy); XCTAssertTrue(store.pendingTasks.isEmpty)
        client.cancel(activeID)
        await Task.yield()
        XCTAssertEqual(callbackCount, 1)
    }

    func testAgentCompletionSeparatesUndoFromInProgressInkGesture() throws {
        let (store, _, _, client) = try environment()
        defer { client.cancel() }
        let baseline = store.notebook
        let firstInk = drawingData()
        let drawing = try PKDrawing(data: firstInk)
        let secondStroke = drawing.transformed(using: CGAffineTransform(translationX: 100, y: 80))
        let laterInk = PKDrawing(strokes: drawing.strokes + secondStroke.strokes).dataRepresentation()
        store.checkpoint()
        store.setDrawing(firstInk)
        let result = CanvasObject(title: "Arrived while writing")
        try store.applyAgentResponse(AgentResponse(message: "Added", operations: [AgentOperation(type: "add", object: result)]), basedOn: baseline)
        store.setDrawing(laterInk)
        store.commit()
        store.undo()
        XCTAssertEqual(store.notebook.objects, [result], "Undoing subsequent handwriting must preserve the AI result")
        XCTAssertEqual(store.notebook.drawingData, firstInk)
        store.undo()
        XCTAssertTrue(store.notebook.objects.isEmpty)
        XCTAssertEqual(store.notebook.drawingData, firstInk, "Undoing the AI change must preserve ink drawn before it arrived")
        store.undo()
        XCTAssertTrue(store.notebook.drawingData.isEmpty)
    }

    func testDetachedVoiceTasksKeepWorkingAndCannotReplyIntoTheNewVoiceSession() async throws {
        let (store, library, transport, client) = try environment()
        let received = started(transport)
        let oldApplied = expectation(description: "Detached voice task still changes the canvas")
        let newReply = expectation(description: "New reference receives its own spoken reply")
        let routing = VoiceTaskSession()
        var staleReplies = 0
        client.onCompletion = { message, failed in
            XCTAssertFalse(failed)
            if message == "First canvas job" { oldApplied.fulfill() }
        }
        defer { client.onCompletion = nil; client.cancel() }
        routing.begin()
        let oldID = try XCTUnwrap(routing.send("first voice area", agent: client, store: store, library: library) { _, _ in staleReplies += 1 })
        routing.detach()
        XCTAssertEqual(client.jobs.first { $0.id == oldID }?.state, .running)
        store.tool = .pen
        store.reference = CanvasRect(x: 800, y: -300, width: 100, height: 120)
        routing.begin()
        let newID = try XCTUnwrap(routing.send("second voice area", agent: client, store: store, library: library) { message, failed in
            XCTAssertFalse(failed); XCTAssertEqual(message, "Second canvas job"); newReply.fulfill()
        })
        await fulfillment(of: [received], timeout: 3)
        let first = CanvasObject(title: "First voice result"), second = CanvasObject(title: "Second voice result")
        try transport.finish("first voice area", with: AgentResponse(message: "First canvas job", operations: [AgentOperation(type: "add", object: first)]))
        await fulfillment(of: [oldApplied], timeout: 3)
        XCTAssertEqual(staleReplies, 0)
        XCTAssertEqual(routing.requestID, newID, "An old result must not clear the new voice request")
        XCTAssertEqual(store.notebook.objects, [first])
        XCTAssertEqual(store.tool, .pen)
        try transport.finish("second voice area", with: AgentResponse(message: "Second canvas job", operations: [AgentOperation(type: "add", object: second)]))
        await fulfillment(of: [newReply], timeout: 3)
        XCTAssertEqual(Set(store.notebook.objects.map(\.id)), [first.id, second.id])
        XCTAssertNil(routing.requestID)
        XCTAssertEqual(staleReplies, 0)
    }

    func testThinkingLevelMigratesOldSettingsAndPersistsSupportedChoices() throws {
        XCTAssertEqual(try JSONDecoder().decode(StudioSettings.self, from: Data("{}".utf8)).reasoningEffort, "low")
        XCTAssertEqual(try JSONDecoder().decode(StudioSettings.self, from: Data(#"{"reasoningEffort":"unknown"}"#.utf8)).reasoningEffort, "low")
        for effort in ["low", "medium", "high", "xhigh"] {
            var settings = StudioSettings(); settings.reasoningEffort = effort
            XCTAssertEqual(try JSONDecoder().decode(StudioSettings.self, from: JSONEncoder().encode(settings)).reasoningEffort, effort)
        }
    }

    func testThreeQueuedVoiceTasksUseCapturedReferencesAndFinishIndependently() async throws {
        let (store, library, transport, client) = try environment()
        let received = started(transport, count: 3)
        let completed = expectation(description: "All three detached voice tasks complete")
        completed.expectedFulfillmentCount = 3
        for index in 0..<3 {
            let ref = CanvasRect(x: Double(index * 400), y: Double(index * -200), width: 160, height: 90)
            XCTAssertNotNil(client.send("Voice task \(index)", store: store, library: library, referenceOverride: ref, selectedIDsOverride: []) { _, failed in
                XCTAssertFalse(failed); completed.fulfill()
            })
        }
        store.reference = CanvasRect(x: -8000, y: 6000); store.tool = .pen
        await fulfillment(of: [received], timeout: 5)
        for index in [2, 0, 1] {
            let payload = try XCTUnwrap(transport.payload("Voice task \(index)"))
            let reference = try XCTUnwrap(payload["reference"] as? [String: Double])
            XCTAssertEqual(reference["x"], Double(index * 400))
            XCTAssertEqual(reference["y"], Double(index * -200))
            try transport.finish("Voice task \(index)", with: AgentResponse(message: "Done", operations: [AgentOperation(type: "add", object: CanvasObject(x: Double(index * 400)))]))
        }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(client.jobs.filter { $0.state == .completed }.count, 3)
        XCTAssertEqual(store.notebook.objects.count, 3)
        XCTAssertEqual(store.tool, .pen); XCTAssertEqual(store.reference?.x, -8000)
    }

    func testImageImportAppliesOrientationDownsamplesAndProducesPersistableObject() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 3200, height: 1600), format: {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
        }())
        let image = renderer.image { context in UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3200, height: 1600)) }
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let viewport = CanvasRect(x: -500, y: -200, width: 1000, height: 800)
        let object = try CanvasImageImport.object(from: encoded as Data, title: "Rotated camera photo", viewport: viewport)
        XCTAssertEqual(object.kind, "image"); XCTAssertEqual(object.x, -400); XCTAssertEqual(object.y, -20)
        let restored = try XCTUnwrap(UIImage(data: try XCTUnwrap(object.imageData)))
        XCTAssertLessThanOrEqual(max(restored.size.width, restored.size.height), 2400)
        XCTAssertEqual(restored.size.height / restored.size.width, 2, accuracy: 0.01)
        XCTAssertEqual(object.height / object.width, 2, accuracy: 0.01)
        XCTAssertNoThrow(try NotebookValidation.validate(object))
        XCTAssertThrowsError(try CanvasImageImport.object(from: Data(), title: "Empty", viewport: viewport))
        XCTAssertThrowsError(try CanvasImageImport.object(from: Data("not an image".utf8), title: "Invalid", viewport: viewport))
    }
}
