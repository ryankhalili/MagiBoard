import Foundation
import SwiftUI
import PDFKit
import UIKit

struct LibraryPDF: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var pages: Int
    var url: URL
}
struct PDFSearchResult: Identifiable, Equatable {
    var id: String { "\(documentID.uuidString)-\(page)" }
    var title: String
    /// Human-readable page number, starting at one.
    var page: Int
    var excerpt: String
    var documentID: UUID
}

@MainActor
final class PDFLibrary: ObservableObject {
    @Published private(set) var documents: [LibraryPDF] = []
    @Published var status: String = ""
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ReferenceLibrary", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let indexURL = self.directory.appendingPathComponent("index.json")
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let saved = try decoder.decode([LibraryPDF].self, from: Data(contentsOf: indexURL))
                // Resolve filenames afresh: iOS may move an app's container between installations.
                documents = saved.compactMap { item in
                    var resolved = item
                    resolved.url = self.directory.appendingPathComponent(item.id.uuidString).appendingPathExtension("pdf")
                    return FileManager.default.fileExists(atPath: resolved.url.path) ? resolved : nil
                }
            }
        } catch { status = "Could not open the PDF library: \(error.localizedDescription)" }
    }

    func importDocument(url: URL) throws {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        let metadata = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (metadata.fileSize ?? 0) <= 40_000_000 else { throw NotebookError.invalid("Choose a PDF smaller than 40 MB.") }
        guard let pdf = PDFDocument(url: url) else { throw NotebookError.invalid("This file could not be read as a PDF.") }
        guard !pdf.isLocked else { throw NotebookError.invalid("Unlock this PDF before adding it to your library.") }
        guard pdf.pageCount > 0, pdf.pageCount <= 300 else { throw NotebookError.invalid("The prototype supports PDFs with 1–300 pages.") }
        let id = UUID()
        let destination = directory.appendingPathComponent(id.uuidString).appendingPathExtension("pdf")
        let title = String(url.deletingPathExtension().lastPathComponent.prefix(200))
        let entry = LibraryPDF(id: id, title: title, pages: pdf.pageCount, url: destination)
        try FileManager.default.copyItem(at: url, to: destination)
        do {
            let newDocuments = documents + [entry]
            try encoder.encode(newDocuments).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
            documents = newDocuments; status = "Added \(title)"
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func search(query: String) -> [PDFSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let stopWords: Set<String> = ["a", "an", "and", "are", "as", "at", "be", "can", "could", "do", "find", "for", "from", "go", "hey", "here", "i", "in", "is", "it", "me", "of", "on", "out", "please", "print", "put", "show", "that", "the", "this", "to", "want", "would", "you"]
        let terms = Array(Set(query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !stopWords.contains($0) })).sorted()
        guard !terms.isEmpty else { return [] }
        var ranked: [(score: Int, result: PDFSearchResult)] = []
        for item in documents {
            guard let pdf = PDFDocument(url: item.url) else { continue }
            let title = item.title.lowercased()
            for pageIndex in 0..<min(item.pages, pdf.pageCount) {
                let original = (pdf.page(at: pageIndex)?.string ?? "").replacingOccurrences(of: "\n", with: " ")
                let lower = original.lowercased()
                let pageTerms = terms.filter { lower.contains($0) }
                let matchedTerms = terms.filter { lower.contains($0) || title.contains($0) }
                let phraseHit = lower.contains(query.lowercased())
                guard phraseHit || matchedTerms.count >= min(terms.count, 2) else { continue }
                let score = (phraseHit ? 100 : 0) + pageTerms.count * 4 + matchedTerms.count
                let excerpt: String
                if let hit = original.range(of: query, options: .caseInsensitive) ?? pageTerms.compactMap({ original.range(of: $0, options: .caseInsensitive) }).first {
                    let start = original.index(hit.lowerBound, offsetBy: -100, limitedBy: original.startIndex) ?? original.startIndex
                    let end = original.index(start, offsetBy: 600, limitedBy: original.endIndex) ?? original.endIndex
                    excerpt = (start > original.startIndex ? "…" : "") + String(original[start..<end]) + (end < original.endIndex ? "…" : "")
                } else { excerpt = original.isEmpty ? "This page has no searchable text. Insert it on the canvas to inspect it visually." : String(original.prefix(600)) }
                ranked.append((score, PDFSearchResult(title: item.title, page: pageIndex + 1, excerpt: excerpt, documentID: item.id)))
            }
        }
        return ranked.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.result.title != b.result.title { return a.result.title < b.result.title }
            return a.result.page < b.result.page
        }.prefix(30).map(\.result)
    }

    /// Only bounded excerpts from the user's local library are sent as agent context.
    func textContext(query: String) -> String {
        let matches = search(query: query)
        let catalog = documents.map { "\($0.title) [\($0.id.uuidString)], \($0.pages) pages" }.joined(separator: "\n")
        let excerpts = matches.prefix(8).map { "SOURCE: \($0.title), page \($0.page), documentID \($0.documentID.uuidString)\n\($0.excerpt)" }.joined(separator: "\n\n")
        return String(("LOCAL PDF LIBRARY\n" + catalog + "\n\n" + excerpts).prefix(10_000))
    }

    func pageObject(documentID: UUID, page: Int, at point: CGPoint) -> CanvasObject? {
        guard let item = documents.first(where: { $0.id == documentID }), page >= 1, page <= item.pages,
              let pdf = PDFDocument(url: item.url), let pdfPage = pdf.page(at: page - 1) else { return nil }
        let bounds = pdfPage.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { return nil }
        let ratio = min(1600 / max(bounds.width, bounds.height), 2)
        let size = CGSize(width: max(1, bounds.width * ratio), height: max(1, bounds.height * ratio))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: ratio, y: -ratio)
            context.cgContext.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
            pdfPage.draw(with: .cropBox, to: context.cgContext)
        }
        guard let data = image.pngData() else { return nil }
        let displayWidth = min(560, bounds.width)
        return CanvasObject(kind: "image", title: "\(item.title) · p. \(page)", x: point.x, y: point.y,
                            width: displayWidth, height: displayWidth * bounds.height / bounds.width,
                            color: "#FFFFFF", text: String((pdfPage.string ?? "").prefix(60_000)),
                            properties: ["page": Double(page)], imageData: data)
    }
}
