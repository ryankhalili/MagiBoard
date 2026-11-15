import XCTest
import UIKit
import PDFKit
@testable import CanvasStudio

private final class PDFPageOperationProtocol: URLProtocol, @unchecked Sendable {
    static var response = Data()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "pdf-operation-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class PDFLibraryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PDFLibraryTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testFourHundredPageBookPreservesOriginalSearchesLatePageAndRendersBoundedImage() async throws {
        let root = try directory(), source = root.appendingPathComponent("Original quantum exercises.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: source) { context in
            for page in 1...400 {
                context.beginPage()
                let text = page == 350 ? "Question 350: Zeeman sapphire resonance" : "Practice page \(page)"
                (text as NSString).draw(at: CGPoint(x: 35, y: 50), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
        XCTAssertEqual(PDFDocument(url: source)?.pageCount, 400)
        let original = try Data(contentsOf: source)
        let library = PDFLibrary(directory: root.appendingPathComponent("Library"))
        try await library.importDocument(url: source)
        let document = try XCTUnwrap(library.documents.first)
        XCTAssertEqual(document.pages, 400)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: document.url), original)
        XCTAssertFalse(library.isImporting)

        let matches = await library.search(query: "Zeeman sapphire resonance")
        XCTAssertEqual(matches.first?.page, 350)
        XCTAssertEqual(matches.first?.documentID, document.id)
        let natural = await library.search(query: "Find question 350 from Original quantum exercises")
        XCTAssertEqual(natural.first?.page, 350)
        XCTAssertLessThanOrEqual(natural.count, 30)
        let context = await library.textContext(query: "Find the question about Zeeman sapphire resonance")
        XCTAssertTrue(context.contains("page 350")); XCTAssertTrue(context.contains("Zeeman sapphire resonance"))
        XCTAssertLessThanOrEqual(context.count, 10_000)
        XCTAssertFalse(PDFLibrary.shouldSearchReferences(query: "Make a green triangle", documents: [document]))
        XCTAssertFalse(PDFLibrary.shouldSearchReferences(query: "Generate an original coin image", documents: [document]))
        XCTAssertTrue(PDFLibrary.shouldSearchReferences(query: "Find question 350", documents: [document]))
        XCTAssertTrue(PDFLibrary.shouldSearchReferences(query: "Explain the quantum result", documents: [document]))
        let titleContext = await library.textContext(query: "Quantum Zeeman sapphire resonance")
        XCTAssertTrue(titleContext.contains("page 350")); XCTAssertTrue(titleContext.contains("Zeeman sapphire resonance"))
        let lightweight = await library.textContext(query: "Make a green triangle")
        XCTAssertTrue(lightweight.contains(document.title))
        XCTAssertFalse(lightweight.contains("SOURCE:")); XCTAssertFalse(lightweight.contains("Zeeman sapphire resonance"))

        let rendered = await library.pageObject(documentID: document.id, page: 350, at: CGPoint(x: -120, y: 240))
        let page = try XCTUnwrap(rendered), bytes = try XCTUnwrap(page.imageData)
        let image = try XCTUnwrap(UIImage(data: bytes))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 1600)
        XCTAssertTrue(page.text.contains("Question 350")); XCTAssertEqual(page.properties["page"], 350)
        XCTAssertEqual(page.x, -120); XCTAssertEqual(page.y, 240)
        XCTAssertNoThrow(try NotebookValidation.validate(page))
        let invalid = await library.pageObject(documentID: document.id, page: 401, at: .zero)
        XCTAssertNil(invalid)
        let reopened = PDFLibrary(directory: root.appendingPathComponent("Library"))
        XCTAssertEqual(reopened.documents, library.documents)
        let restoredMatches = await reopened.search(query: "Zeeman sapphire resonance")
        XCTAssertEqual(restoredMatches.first?.page, 350)

        // Exercise the actual client pipeline: an agent page command becomes a
        // local original-page image, then applies as one undoable canvas change.
        let store = NotebookStore(storageURL: root.appendingPathComponent("Notebook"), loadSaved: false)
        store.newNotebook(title: "PDF agent test")
        store.settings.bridgeURL = "https://pdf-operation-test.invalid"; store.settings.bridgeToken = "test-only"
        store.reference = CanvasRect(x: -500, y: 320, width: 20, height: 20)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PDFPageOperationProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = ConnectionClient(session: session)
        defer { client.cancel(); session.invalidateAndCancel() }
        PDFPageOperationProtocol.response = try JSONEncoder().encode(AgentResponse(message: "Inserted original page", operations: [AgentOperation(type: "insertPDF", documentID: document.id, page: 350)]))
        let inserted = expectation(description: "Page command resolves and applies")
        XCTAssertNotNil(client.send("Print question 350 from the quantum exercises", store: store, library: library) { _, failed in
            XCTAssertFalse(failed); inserted.fulfill()
        })
        await fulfillment(of: [inserted], timeout: 15)
        let insertedPage = try XCTUnwrap(store.notebook.objects.first)
        XCTAssertEqual(store.notebook.objects.count, 1); XCTAssertEqual(insertedPage.kind, "image")
        XCTAssertEqual(insertedPage.x, -500); XCTAssertEqual(insertedPage.y, 320)
        XCTAssertEqual(insertedPage.properties["page"], 350); XCTAssertTrue(insertedPage.text.contains("Question 350"))
        store.undo(); XCTAssertTrue(store.notebook.objects.isEmpty)

        PDFPageOperationProtocol.response = try JSONEncoder().encode(AgentResponse(message: "Must not partially apply", operations: [
            AgentOperation(type: "add", object: CanvasObject(title: "Never inserted")),
            AgentOperation(type: "insertPDF", documentID: UUID(), page: 350)]))
        let rejected = expectation(description: "Invalid document rejects complete batch")
        XCTAssertNotNil(client.send("Print question 350", store: store, library: library) { _, failed in
            XCTAssertTrue(failed); rejected.fulfill()
        })
        await fulfillment(of: [rejected], timeout: 15)
        XCTAssertTrue(store.notebook.objects.isEmpty)
        for invalidPage in [0, 401] {
            do {
                _ = try await library.resolvingPDFInsertions(AgentResponse(message: "Invalid page", operations: [AgentOperation(type: "insertPDF", documentID: document.id, page: invalidPage)]), documents: [document], reference: .init())
                XCTFail("Invalid PDF page was accepted")
            } catch { XCTAssertTrue(store.notebook.objects.isEmpty) }
        }
    }

    func testInvalidAndOverOneGigabyteImportsLeaveLibraryUnchanged() async throws {
        let root = try directory(), libraryURL = root.appendingPathComponent("Library")
        let library = PDFLibrary(directory: libraryURL)
        let malformed = root.appendingPathComponent("Invalid.pdf")
        try Data("This is not a PDF".utf8).write(to: malformed)
        do { try await library.importDocument(url: malformed); XCTFail("Malformed PDF was accepted") }
        catch { XCTAssertTrue(library.documents.isEmpty) }

        // A sparse file checks the pre-copy size guard without allocating a gigabyte.
        let oversized = root.appendingPathComponent("Oversized.pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(PDFLibrary.maximumFileBytes) + 1)
        try handle.close()
        do { try await library.importDocument(url: oversized); XCTFail("Oversized PDF was accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("1 GB")) }
        XCTAssertFalse(library.isImporting); XCTAssertTrue(library.documents.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: libraryURL, includingPropertiesForKeys: nil).isEmpty)
    }
}
