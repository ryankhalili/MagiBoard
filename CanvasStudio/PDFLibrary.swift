import Foundation
import SwiftUI
import PDFKit
import UIKit

struct LibraryPDF: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var pages: Int
    var url: URL
}
struct PDFSearchResult: Identifiable, Equatable, Sendable {
    var id: String { "\(documentID.uuidString)-\(page)" }
    var title: String
    /// Human-readable page number, starting at one.
    var page: Int
    var excerpt: String
    var documentID: UUID
}

@MainActor
final class PDFLibrary: ObservableObject {
    static let maximumFileBytes = 1_000_000_000
    @Published private(set) var documents: [LibraryPDF] = []
    @Published private(set) var isImporting = false
    @Published var status = ""
    private let directory: URL
    private let worker = PDFLibraryWorker()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ReferenceLibrary", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let indexURL = self.directory.appendingPathComponent("index.json")
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let saved = try decoder.decode([LibraryPDF].self, from: Data(contentsOf: indexURL))
                documents = saved.compactMap { item in
                    var resolved = item
                    resolved.url = self.directory.appendingPathComponent(item.id.uuidString).appendingPathExtension("pdf")
                    return FileManager.default.fileExists(atPath: resolved.url.path) ? resolved : nil
                }
            }
        } catch { status = "Could not open the PDF library: \(error.localizedDescription)" }
    }

    func importDocument(url: URL) async throws {
        guard !isImporting else { throw NotebookError.invalid("Another PDF is still importing.") }
        isImporting = true; status = "Copying PDF into your library…"
        defer { isImporting = false }
        let entry = try await worker.importDocument(url: url, directory: directory, maximumBytes: Self.maximumFileBytes)
        do {
            try Task.checkCancellation()
            let proposed = documents + [entry]
            try encoder.encode(proposed).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
            documents = proposed; status = "Added \(entry.title) · \(entry.pages) pages"
        } catch {
            try? FileManager.default.removeItem(at: entry.url)
            throw error
        }
    }

    func search(query: String, documents snapshot: [LibraryPDF]? = nil) async -> [PDFSearchResult] {
        (try? await worker.search(query: query, documents: snapshot ?? documents)) ?? []
    }

    /// Only bounded excerpts from the user's local library are sent as agent context.
    /// A caller can freeze the library list at the same time as its canvas snapshot.
    func textContext(query: String, documents snapshot: [LibraryPDF]? = nil) async -> String {
        let source = snapshot ?? documents
        guard !source.isEmpty else { return "" }
        let catalog = source.prefix(200).map { "\($0.title) [\($0.id.uuidString)], \($0.pages) pages" }.joined(separator: "\n")
        guard Self.shouldSearchReferences(query: query, documents: source) else {
            return String(("LOCAL PDF LIBRARY\nDOCUMENTS\n" + catalog).prefix(10_000))
        }
        let matches = (try? await worker.contextualExcerpts(query: query, documents: source)) ?? []
        guard !Task.isCancelled else { return "" }
        let excerpts = matches.prefix(8).map { "SOURCE: \($0.title), page \($0.page), documentID \($0.documentID.uuidString)\n\($0.excerpt)" }.joined(separator: "\n\n")
        return String(("LOCAL PDF LIBRARY\n" + excerpts + "\n\nDOCUMENTS\n" + catalog).prefix(10_000))
    }

    nonisolated static func shouldSearchReferences(query: String, documents: [LibraryPDF]) -> Bool {
        func words(_ value: String) -> Set<String> {
            Set(value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        }
        let queryWords = words(query)
        let references: Set<String> = ["pdf", "pdfs", "book", "books", "textbook", "textbooks", "document", "documents", "reference", "references", "question", "questions", "exercise", "exercises", "problem", "problems", "chapter", "chapters", "page", "pages", "printout", "printouts"]
        if !queryWords.isDisjoint(with: references) { return true }
        let genericTitles: Set<String> = ["the", "and", "with", "from", "book", "textbook", "notes", "introduction", "edition", "volume", "part", "original", "practice", "exercises", "reference", "document", "course", "lecture"]
        return documents.contains { document in
            let titleWords = words(document.title).filter { $0.count >= 4 && !genericTitles.contains($0) }
            return !queryWords.isDisjoint(with: titleWords)
        }
    }

    func pageObject(documentID: UUID, page: Int, at point: CGPoint) async -> CanvasObject? {
        guard let item = documents.first(where: { $0.id == documentID }), page >= 1, page <= item.pages else { return nil }
        return try? await worker.pageObject(item: item, page: page, at: point)
    }

    /// Resolve local document commands completely before the store applies any operation.
    /// Model output contains identities and page numbers, never a path or PDF bytes.
    func resolvingPDFInsertions(_ response: AgentResponse, documents: [LibraryPDF], reference: CanvasRect) async throws -> AgentResponse {
        let insertions = response.operations.filter { $0.type == "insertPDF" }
        guard insertions.count <= 4 else { throw NotebookError.invalid("Insert at most four PDF pages in one request.") }
        guard !insertions.isEmpty else { return response }
        var planned: [(index: Int, document: LibraryPDF, page: Int, point: CGPoint)] = []
        for (index, operation) in response.operations.enumerated() where operation.type == "insertPDF" {
            guard let id = operation.documentID, let item = documents.first(where: { $0.id == id }),
                  let page = operation.page, page >= 1, page <= item.pages else {
                throw NotebookError.invalid("The requested PDF or page is not in this task’s reference library.")
            }
            let x = operation.x ?? (reference.x + Double(planned.count) * 600), y = operation.y ?? reference.y
            guard x.isFinite, y.isFinite, abs(x) <= 10_000_000, abs(y) <= 10_000_000 else {
                throw NotebookError.invalid("The PDF page has an invalid canvas position.")
            }
            planned.append((index, item, page, CGPoint(x: x, y: y)))
        }
        var result = response
        for insertion in planned {
            try Task.checkCancellation()
            guard let object = try await worker.pageObject(item: insertion.document, page: insertion.page, at: insertion.point) else {
                throw NotebookError.invalid("Page \(insertion.page) of \(insertion.document.title) could not be rendered. No changes were applied.")
            }
            try NotebookValidation.validate(object)
            result.operations[insertion.index] = AgentOperation(type: "add", object: object)
        }
        try Task.checkCancellation()
        return result
    }
}

/// PDFKit documents stay on this worker's executor. Import copies files directly;
/// search visits one page at a time and retains only bounded text and result caches.
private actor PDFLibraryWorker {
    private let textCache = NSCache<NSString, NSString>()
    init() { textCache.totalCostLimit = 16 * 1024 * 1024; textCache.countLimit = 512 }

    func importDocument(url: URL, directory: URL, maximumBytes: Int) throws -> LibraryPDF {
        try Task.checkCancellation()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let metadata = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard metadata.isRegularFile == true, let bytes = metadata.fileSize, bytes <= maximumBytes else {
            throw NotebookError.invalid("Choose a PDF up to 1 GB. Larger files need to be split before importing.")
        }
        let id = UUID(), destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        // Use the library identity as its filename, including after iOS moves the container.
        let finalURL = directory.appendingPathComponent(id.uuidString).appendingPathExtension("pdf")
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            try Task.checkCancellation()
            let copiedBytes = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard copiedBytes <= maximumBytes else { throw NotebookError.invalid("This PDF exceeds the 1 GB import limit.") }
            guard let pdf = PDFDocument(url: destination) else { throw NotebookError.invalid("This file could not be read as a PDF.") }
            guard !pdf.isLocked else { throw NotebookError.invalid("Unlock this PDF before adding it to your library.") }
            guard pdf.pageCount > 0 else { throw NotebookError.invalid("This PDF does not contain any pages.") }
            let pages = pdf.pageCount
            try FileManager.default.moveItem(at: destination, to: finalURL)
            return LibraryPDF(id: id, title: String(url.deletingPathExtension().lastPathComponent.prefix(200)), pages: pages, url: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: finalURL)
            throw error
        }
    }

    func contextualExcerpts(query: String, documents: [LibraryPDF]) throws -> [PDFSearchResult] {
        func number(_ pattern: String, in text: String) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[range])
        }
        guard let chapter = number(#"\b(?:chapter|ch\.?)\s*(\d+)\b"#, in: query),
              let problem = number(#"\b(?:question|problem|exercise)\s*(?:number\s*|no\.?\s*|#\s*)?(\d+)\b"#, in: query) else {
            return try search(query: query, documents: documents)
        }
        let queryWords = Set(query.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let named = documents.filter { item in
            item.title.lowercased().split(whereSeparator: { !$0.isLetter }).contains { $0.count >= 4 && queryWords.contains(String($0)) && !["book", "chapter", "exercises", "problems"].contains(String($0)) }
        }
        for item in named.isEmpty ? documents : named {
            try Task.checkCancellation()
            guard let pdf = PDFDocument(url: item.url), !pdf.isLocked else { continue }
            var outline: [(label: String, page: Int)] = []
            func visit(_ node: PDFOutline, depth: Int) {
                guard depth < 8, outline.count < 2000 else { return }
                if let page = node.destination?.page {
                    let index = pdf.index(for: page)
                    if index != NSNotFound { outline.append((node.label ?? "", index)) }
                }
                for index in 0..<node.numberOfChildren { if let child = node.child(at: index) { visit(child, depth: depth + 1) } }
            }
            if let root = pdf.outlineRoot { visit(root, depth: 0) }
            var chapters = outline.compactMap { entry -> (number: Int, page: Int)? in
                guard let value = number(#"^\s*(?:chapter\s+)?(\d+)(?:\s*[-:–—]\s*|\s+)(?!\d)"#, in: entry.label) else { return nil }
                return (value, entry.page)
            }
            var evidence = "PDF outline"
            if !chapters.contains(where: { $0.number == chapter }) {
                evidence = "chapter heading text"
                for page in 0..<pdf.pageCount {
                    try Task.checkCancellation()
                    let heading = String(text(of: pdf, item: item, pageIndex: page).prefix(500))
                    guard !heading.lowercased().contains("contents"),
                          let value = number(#"(?m)^\s*chapter\s+(\d+)\b"#, in: heading) else { continue }
                    if !chapters.contains(where: { $0.number == value }) { chapters.append((value, page)) }
                }
            }
            guard let start = chapters.filter({ $0.number == chapter }).map(\.page).min() else { continue }
            let end = chapters.filter { $0.number > chapter && $0.page > start }.map(\.page).min() ?? pdf.pageCount
            let sectionPattern = #"(?im)^\s*(?:problems|exercises|questions)\b"#
            var problemStart = outline.filter { $0.page >= start && $0.page < end && $0.label.range(of: #"(?i)\b(?:problems|exercises|questions)\b"#, options: .regularExpression) != nil }.map(\.page).min()
            if problemStart == nil {
                for page in start..<end {
                    try Task.checkCancellation()
                    if text(of: pdf, item: item, pageIndex: page).range(of: sectionPattern, options: .regularExpression) != nil { problemStart = page; break }
                }
            }
            let first = problemStart ?? start
            let labelPattern = "(?im)(?<![0-9.])\(chapter)\\.\(problem)(?![0-9.])|^\\s*(?:(?:problem|question|exercise)\\s+)?\(problem)[.)：:]\\s"
            var target: Int?
            for page in first..<end {
                try Task.checkCancellation()
                if text(of: pdf, item: item, pageIndex: page).range(of: labelPattern, options: .regularExpression) != nil { target = page; break }
            }
            guard let primary = target ?? problemStart else { continue }
            var pages = [primary]
            if primary + 1 < end { pages.append(primary + 1) }
            if primary > first { pages.append(primary - 1) }
            if !pages.contains(start) { pages.append(start) }
            return pages.enumerated().map { order, page in
                let original = text(of: pdf, item: item, pageIndex: page)
                let hit = page == primary ? original.range(of: labelPattern, options: .regularExpression)?.lowerBound : nil
                let beginning = hit.map { original.index($0, offsetBy: -180, limitedBy: original.startIndex) ?? original.startIndex } ?? original.startIndex
                let limit = order == 0 ? 2800 : (page == start ? 600 : 1800)
                let ending = original.index(beginning, offsetBy: limit, limitedBy: original.endIndex) ?? original.endIndex
                let note = "RETRIEVAL CONTEXT: Chapter \(chapter) spans PDF pages \(start + 1)–\(end) according to \(evidence). "
                    + (problemStart.map { "Its Problems/Exercises section starts on PDF page \($0 + 1). " } ?? "The exercise section was not separately identified. ")
                    + "Requested exercise \(problem) may be labeled \(chapter).\(problem) or \(problem).; use the source text below to verify.\n"
                return PDFSearchResult(title: item.title, page: page + 1, excerpt: note + String(original[beginning..<ending]), documentID: item.id)
            }
        }
        return try search(query: query, documents: documents)
    }

    func search(query: String, documents: [LibraryPDF]) throws -> [PDFSearchResult] {
        try Task.checkCancellation()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let stopWords: Set<String> = ["a", "an", "and", "are", "as", "at", "be", "can", "could", "do", "find", "for", "from", "go", "hey", "here", "i", "in", "is", "it", "me", "of", "on", "out", "please", "print", "put", "show", "that", "the", "this", "to", "want", "would", "you"]
        let terms = Array(Set(query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !stopWords.contains($0) })).sorted()
        guard !terms.isEmpty else { return [] }
        typealias Ranked = (score: Int, result: PDFSearchResult)
        func ranksBefore(_ a: Ranked, _ b: Ranked) -> Bool {
            if a.score != b.score { return a.score > b.score }
            if a.result.title != b.result.title { return a.result.title < b.result.title }
            return a.result.page < b.result.page
        }
        var ranked: [Ranked] = []
        for item in documents {
            try Task.checkCancellation()
            guard let pdf = PDFDocument(url: item.url), !pdf.isLocked else { continue }
            for pageIndex in 0..<pdf.pageCount {
                try Task.checkCancellation()
                let result: Ranked? = autoreleasepool {
                    let original = text(of: pdf, item: item, pageIndex: pageIndex).replacingOccurrences(of: "\n", with: " ")
                    let lower = original.lowercased(), title = item.title.lowercased()
                    let pageTerms = terms.filter { lower.contains($0) }
                    let matchedTerms = terms.filter { lower.contains($0) || title.contains($0) }
                    let phraseHit = lower.contains(query.lowercased())
                    guard phraseHit || matchedTerms.count >= min(terms.count, 2) else { return nil }
                    let score = (phraseHit ? 100 : 0) + pageTerms.count * 4 + matchedTerms.count
                    let excerpt: String
                    if let hit = original.range(of: query, options: .caseInsensitive) ?? pageTerms.compactMap({ original.range(of: $0, options: .caseInsensitive) }).first {
                        let start = original.index(hit.lowerBound, offsetBy: -100, limitedBy: original.startIndex) ?? original.startIndex
                        let end = original.index(start, offsetBy: 600, limitedBy: original.endIndex) ?? original.endIndex
                        excerpt = (start > original.startIndex ? "…" : "") + String(original[start..<end]) + (end < original.endIndex ? "…" : "")
                    } else { excerpt = original.isEmpty ? "This page has no searchable text. Insert it on the canvas to inspect it visually." : String(original.prefix(600)) }
                    return (score, PDFSearchResult(title: item.title, page: pageIndex + 1, excerpt: excerpt, documentID: item.id))
                }
                if let result {
                    ranked.append(result); ranked.sort(by: ranksBefore)
                    if ranked.count > 30 { ranked.removeLast() }
                }
            }
        }
        return ranked.map(\.result)
    }

    private func text(of pdf: PDFDocument, item: LibraryPDF, pageIndex: Int) -> String {
        let key = "\(item.id.uuidString):\(pageIndex)" as NSString
        if let cached = textCache.object(forKey: key) { return cached as String }
        let text = pdf.page(at: pageIndex)?.string ?? ""
        let cost = text.utf16.count * 2
        if cost <= 256 * 1024 { textCache.setObject(text as NSString, forKey: key, cost: cost) }
        return text
    }

    func pageObject(item: LibraryPDF, page: Int, at point: CGPoint) throws -> CanvasObject? {
        try Task.checkCancellation()
        guard let pdf = PDFDocument(url: item.url), let pdfPage = pdf.page(at: page - 1) else { return nil }
        let bounds = pdfPage.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0,
              [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite) else { return nil }
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
        try Task.checkCancellation()
        guard let data = image.pngData() else { return nil }
        let displayScale = min(560 / bounds.width, 900 / bounds.height, 1)
        return CanvasObject(kind: "image", title: "\(item.title) · p. \(page)", x: point.x, y: point.y,
                            width: max(1, bounds.width * displayScale), height: max(1, bounds.height * displayScale),
                            color: "#FFFFFF", text: String((pdfPage.string ?? "").prefix(60_000)),
                            properties: ["page": Double(page)], imageData: data)
    }
}
