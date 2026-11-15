import Foundation
import UIKit

@main
struct PDFLibraryChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PDFLibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Sakurai practice.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: source) { context in
            context.beginPage()
            ("Question 1: Find the ground state." as NSString).draw(at: CGPoint(x: 30, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            context.beginPage()
            ("Question 2: Calculate the commutator of position and momentum." as NSString).draw(at: CGPoint(x: 30, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        let original = try Data(contentsOf: source)
        let library = PDFLibrary(directory: root.appendingPathComponent("Library"))
        try await library.importDocument(url: source)
        precondition(library.documents.count == 1 && library.documents[0].pages == 2)
        let remainingSource = try Data(contentsOf: source)
        precondition(remainingSource == original)
        let copiedSource = try Data(contentsOf: library.documents[0].url)
        precondition(copiedSource == original)
        let results = await library.search(query: "Question 2")
        precondition(results.first?.page == 2)
        let natural = await library.search(query: "Hey find question 2 from Sakurai")
        precondition(natural.first?.page == 2)
        let page = await library.pageObject(documentID: library.documents[0].id, page: 2, at: CGPoint(x: 120, y: 150))!
        let image = UIImage(data: page.imageData!)!
        precondition(max(image.size.width, image.size.height) <= 1600)
        precondition(page.text.contains("Question 2") && page.x == 120 && page.y == 150)
        let invalidPage = await library.pageObject(documentID: library.documents[0].id, page: 0, at: .zero)
        precondition(invalidPage == nil)
        let reopened = PDFLibrary(directory: root.appendingPathComponent("Library"))
        precondition(reopened.documents == library.documents)
        let context = await library.textContext(query: "Question 2")
        precondition(context.count <= 10_000)
        print("8 PDF checks passed: original preservation, search, natural query, page raster, limits and persistence")
    }
}
