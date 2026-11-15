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

/// A numeric exercise identity, independent of physical/printed page numbering.
struct PDFExerciseRequest: Equatable, Sendable {
    var chapter: Int?
    var number: Int
    var label: String { chapter.map { "\($0).\(number)" } ?? String(number) }

    init(chapter: Int?, question: String) throws {
        let value = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 32, chapter.map({ (1...999).contains($0) }) ?? true,
              let regex = try? NSRegularExpression(pattern: #"^(\d{1,4})(?:\.(\d{1,4}))?\.?$"#),
              let hit = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let firstRange = Range(hit.range(at: 1), in: value), let first = Int(value[firstRange]), first > 0 else {
            throw NotebookError.invalid("Use a numeric question label such as 2 or 2.2. Subparts are included with the complete question.")
        }
        if let secondRange = Range(hit.range(at: 2), in: value), let second = Int(value[secondRange]) {
            guard first <= 999, second > 0, chapter == nil || chapter == first else {
                throw NotebookError.invalid("The chapter and question numbers do not agree.")
            }
            self.chapter = first; number = second
        } else { self.chapter = chapter; number = first }
    }

    static func from(query: String) -> PDFExerciseRequest? {
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let hit = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
                  let range = Range(hit.range(at: 1), in: query) else { return nil }
            return String(query[range])
        }
        let chapter = capture(#"\b(?:chapter|ch\.?)\s*(\d+)\b"#).flatMap(Int.init)
        guard let question = capture(#"\b(?:questions?|problems?|exercises?)\s*(?:number\s*|no\.?\s*|#\s*)?(\d+(?:\.\d+)?)\b"#) else { return nil }
        return try? PDFExerciseRequest(chapter: chapter, question: question)
    }
}

struct PDFExerciseRegion: Equatable, Sendable {
    var page: Int // One based, never a printed page label.
    var bounds: CGRect // PDF coordinates, preserving the source graphics.
}

/// Original geometric lookup. Text order is not reading order in many textbooks:
/// margin labels may all precede their paragraphs. PDFKit character selections
/// give their actual positions, so neither label offsets nor an AI guess crop ink.
enum PDFExerciseLocator {
    struct Scope {
        var start: Int
        var end: Int
        var problems: Int?
        var evidence: String
    }
    struct Label {
        var chapter: Int?
        var number: Int
        var bounds: CGRect
    }

    static func scope(in pdf: PDFDocument, chapter: Int?) throws -> Scope {
        guard let chapter else { return Scope(start: 0, end: pdf.pageCount, problems: nil, evidence: "document") }
        var entries: [(String, Int)] = []
        func visit(_ node: PDFOutline, depth: Int) {
            guard depth < 8, entries.count < 2000 else { return }
            if let page = node.destination?.page {
                let index = pdf.index(for: page)
                if index != NSNotFound { entries.append((node.label ?? "", index)) }
            }
            for index in 0..<node.numberOfChildren { if let child = node.child(at: index) { visit(child, depth: depth + 1) } }
        }
        if let root = pdf.outlineRoot { visit(root, depth: 0) }
        func chapterNumber(_ text: String, pattern: String) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let hit = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(hit.range(at: 1), in: text) else { return nil }
            return Int(text[range])
        }
        var chapters = entries.compactMap { entry -> (Int, Int)? in
            chapterNumber(entry.0, pattern: #"^\s*(?:chapter\s+)?(\d+)(?:\s*[-:–—]\s*|\s+)(?!\d)"#).map { ($0, entry.1) }
        }
        var evidence = "PDF outline"
        if !chapters.contains(where: { $0.0 == chapter }) {
            evidence = "chapter heading text"
            for index in 0..<pdf.pageCount {
                try Task.checkCancellation()
                let heading = String((pdf.page(at: index)?.string ?? "").prefix(700))
                guard !heading.lowercased().contains("contents"),
                      let number = chapterNumber(heading, pattern: #"(?m)^\s*chapter\s+(\d+)\b"#) else { continue }
                if !chapters.contains(where: { $0.0 == number }) { chapters.append((number, index)) }
            }
        }
        guard let start = chapters.filter({ $0.0 == chapter }).map(\.1).min() else {
            // Qualified exercise labels still work in an unbookmarked document.
            return Scope(start: 0, end: pdf.pageCount, problems: nil, evidence: "qualified question labels")
        }
        let end = chapters.filter { $0.0 > chapter && $0.1 > start }.map(\.1).min() ?? pdf.pageCount
        var problems = entries.filter { $0.1 >= start && $0.1 < end && $0.0.range(of: #"(?i)\b(?:problems|exercises|questions)\b"#, options: .regularExpression) != nil }.map(\.1).min()
        if problems == nil {
            for index in start..<end {
                try Task.checkCancellation()
                if (pdf.page(at: index)?.string ?? "").range(of: #"(?im)^\s*(?:problems|exercises|questions)\s*$"#, options: .regularExpression) != nil {
                    problems = index; break
                }
            }
        }
        return Scope(start: start, end: end, problems: problems, evidence: evidence)
    }

    static func labels(on page: PDFPage) -> [Label] {
        guard page.rotation % 360 == 0, let string = page.string, !string.isEmpty,
              string.utf16.count < 250_000,
              let regex = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}.])(?:(?:[Pp]roblem|[Qq]uestion|[Ee]xercise)\s+)?(\d{1,3})(?:\.(\d{1,4}))?([.)]?)(?![\p{L}\p{N}.])"#) else { return [] }
        let box = page.bounds(for: .cropBox), ns = string as NSString
        // Character geometry also detects preceding text when PDF extraction has
        // emitted a margin-number column separately from the body paragraphs.
        let glyphs: [(Int, CGRect)] = (0..<min(page.numberOfCharacters, ns.length)).compactMap { index in
            guard !CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: index)) ?? " ") else { return nil }
            let bounds = page.characterBounds(at: index)
            return bounds.isNull || bounds.isEmpty ? nil : (index, bounds)
        }
        return regex.matches(in: string, range: NSRange(location: 0, length: ns.length)).prefix(2000).compactMap { hit in
            let first = Int(ns.substring(with: hit.range(at: 1))) ?? 0
            let second = hit.range(at: 2).location == NSNotFound ? nil : Int(ns.substring(with: hit.range(at: 2)))
            let matched = ns.substring(with: hit.range)
            guard first > 0, (second ?? first) > 0,
                  second != nil || hit.range(at: 3).length > 0 || matched.first?.isLetter == true,
                  let selected = page.selection(for: hit.range) else { return nil }
            let bounds = selected.bounds(for: page)
            guard bounds.width > 1, bounds.height > 2, bounds.height < box.height * 0.08,
                  bounds.minX < box.minX + box.width * 0.45,
                  bounds.minY > box.minY + box.height * 0.035,
                  bounds.maxY < box.maxY - box.height * 0.035 else { return nil }
            let preceded = glyphs.contains { index, glyph in
                !NSLocationInRange(index, hit.range) && glyph.maxX < bounds.minX - 1.5 &&
                glyph.midY > bounds.minY && glyph.midY < bounds.maxY && glyph.width > 0.1
            }
            guard !preceded else { return nil }
            return Label(chapter: second == nil ? nil : first, number: second ?? first, bounds: bounds)
        }.sorted { $0.bounds.midY > $1.bounds.midY }
    }

    static func regions(in pdf: PDFDocument, request: PDFExerciseRequest, pageHint: Int?) throws -> [PDFExerciseRegion] {
        let scope = try scope(in: pdf, chapter: request.chapter)
        let first = scope.problems ?? scope.start
        var matches: [(Int, Label)] = []
        var labelCache: [Int: [Label]] = [:]
        func pageLabels(_ index: Int) -> [Label] {
            if let cached = labelCache[index] { return cached }
            let values = pdf.page(at: index).map(labels(on:)) ?? []
            labelCache[index] = values; return values
        }
        for index in first..<scope.end {
            try Task.checkCancellation()
            for label in pageLabels(index) where label.number == request.number {
                if let chapter = request.chapter, let actual = label.chapter, actual != chapter { continue }
                if scope.evidence == "qualified question labels", label.chapter != request.chapter { continue }
                matches.append((index, label))
            }
        }
        // A page hint may disambiguate a repeated bare number, but never forces a
        // wrong page when the chapter + exercise identity uniquely locates it.
        if matches.count > 1, let pageHint {
            let hinted = matches.filter { $0.0 == pageHint - 1 }
            if hinted.count == 1 { matches = hinted }
        }
        guard matches.count == 1, let (startPage, target) = matches.first else {
            throw NotebookError.invalid(matches.isEmpty
                ? "Could not locate question \(request.label) reliably in the PDF text. Specify its chapter, or request an explicit full page. Scanned pages need a text layer."
                : "Question \(request.label) occurs in several places. Include its chapter or PDF page; no crop was inserted.")
        }
        guard let initial = pdf.page(at: startPage) else { throw NotebookError.invalid("The question page is unavailable.") }
        let columnTolerance = max(18, initial.bounds(for: .cropBox).width * 0.045)
        var ending: (Int, Label)?
        for index in startPage..<min(scope.end, startPage + 4) {
            try Task.checkCancellation()
            let candidates = pageLabels(index).filter { label in
                let sameSeries = label.chapter == target.chapter || (label.chapter == nil && target.chapter == nil)
                return sameSeries && label.number > target.number && abs(label.bounds.minX - target.bounds.minX) < columnTolerance &&
                    (index > startPage || label.bounds.maxY < target.bounds.minY - 2)
            }
            if let next = candidates.first { ending = (index, next); break }
        }
        guard let ending, ending.1.number == request.number + 1 else {
            throw NotebookError.invalid("Found question \(request.label), but its ending is not clear enough to crop safely. Request PDF page \(startPage + 1) for the full original page.")
        }
        var regions: [PDFExerciseRegion] = []
        for index in startPage...ending.0 {
            guard let page = pdf.page(at: index), page.rotation % 360 == 0 else {
                throw NotebookError.invalid("This page layout requires an explicit full-page insertion.")
            }
            let box = page.bounds(for: .cropBox)
            let top = index == startPage ? min(box.maxY, target.bounds.maxY + max(7, target.bounds.height * 0.7)) : box.maxY - box.height * 0.075
            let bottom = index == ending.0 ? ending.1.bounds.maxY + max(4, ending.1.bounds.height * 0.45) : box.minY + box.height * 0.055
            // A next exercise at the top of the following page needs no empty
            // continuation slice. Full width retains equations and diagrams.
            if top - bottom > 14 {
                regions.append(PDFExerciseRegion(page: index + 1, bounds: CGRect(x: box.minX, y: bottom, width: box.width, height: top - bottom)))
            }
        }
        guard !regions.isEmpty, regions.count <= 3 else {
            throw NotebookError.invalid("This question spans too many or ambiguous page regions. Insert the original pages explicitly.")
        }
        return regions
    }
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
        var planned: [(index: Int, document: LibraryPDF, page: Int?, exercise: PDFExerciseRequest?, point: CGPoint)] = []
        for (index, operation) in response.operations.enumerated() where operation.type == "insertPDF" {
            guard let id = operation.documentID, let item = documents.first(where: { $0.id == id }),
                  operation.page.map({ $0 >= 1 && $0 <= item.pages }) ?? true else {
                throw NotebookError.invalid("The requested PDF or page is not in this task’s reference library.")
            }
            let exercise = try operation.question.map { try PDFExerciseRequest(chapter: operation.chapter, question: $0) }
            guard operation.chapter.map({ (1...999).contains($0) }) ?? true,
                  exercise != nil || operation.page != nil else {
                throw NotebookError.invalid("Specify a question number or an explicit PDF page.")
            }
            let x = operation.x ?? (reference.x + Double(planned.count) * 600), y = operation.y ?? reference.y
            guard x.isFinite, y.isFinite, abs(x) <= 10_000_000, abs(y) <= 10_000_000 else {
                throw NotebookError.invalid("The PDF page has an invalid canvas position.")
            }
            planned.append((index, item, operation.page, exercise, CGPoint(x: x, y: y)))
        }
        var result = response
        for insertion in planned {
            try Task.checkCancellation()
            let resolved: CanvasObject?
            if let exercise = insertion.exercise {
                resolved = try await worker.questionObject(item: insertion.document, request: exercise, pageHint: insertion.page, at: insertion.point)
            } else {
                resolved = try await worker.pageObject(item: insertion.document, page: insertion.page!, at: insertion.point)
            }
            guard let object = resolved else {
                throw NotebookError.invalid("The requested part of \(insertion.document.title) could not be rendered. No changes were applied.")
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
        if let request = PDFExerciseRequest.from(query: query) {
            let words = Set(query.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
            let named = documents.filter { item in
                item.title.lowercased().split(whereSeparator: { !$0.isLetter }).contains {
                    $0.count >= 4 && words.contains(String($0)) && !["book", "chapter", "exercises", "problems", "original"].contains(String($0))
                }
            }
            var precise: [PDFSearchResult] = []
            for item in named.isEmpty ? documents : named {
                try Task.checkCancellation()
                guard let pdf = PDFDocument(url: item.url), !pdf.isLocked,
                      let regions = try? PDFExerciseLocator.regions(in: pdf, request: request, pageHint: nil) else { continue }
                for region in regions {
                    guard let page = pdf.page(at: region.page - 1) else { continue }
                    let excerpt = page.selection(for: region.bounds)?.string ?? ""
                    precise.append(PDFSearchResult(title: item.title, page: region.page,
                        excerpt: "VERIFIED EXERCISE: Question \(request.label), located by its printed label and the next exercise boundary. Request insertPDF with documentID, question=\"\(request.label)\" and page=\(region.page) to insert its original cropped graphics. Do not substitute a neighboring exercise.\n" + String(excerpt.prefix(5000)), documentID: item.id))
                }
            }
            if !precise.isEmpty { return Array(precise.prefix(6)) }
        }
        func number(_ pattern: String, in text: String) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[range])
        }
        guard let request = PDFExerciseRequest.from(query: query), let chapter = request.chapter else {
            return try search(query: query, documents: documents)
        }
        let problem = request.number
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

    func questionObject(item: LibraryPDF, request: PDFExerciseRequest, pageHint: Int?, at point: CGPoint) throws -> CanvasObject? {
        try Task.checkCancellation()
        guard let pdf = PDFDocument(url: item.url), !pdf.isLocked else { return nil }
        let regions = try PDFExerciseLocator.regions(in: pdf, request: request, pageHint: pageHint)
        let width = regions.map(\.bounds.width).max() ?? 0
        let gap: CGFloat = 12
        let height = regions.reduce(CGFloat.zero) { $0 + $1.bounds.height } + gap * CGFloat(max(0, regions.count - 1))
        guard width > 0, height > 0, width.isFinite, height.isFinite else { return nil }
        let ratio = min(1600 / max(width, height), 2)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        // Fill complete integer pixels. A fractional opaque renderer height can
        // leave a black edge row, which would falsely look like full-width ink.
        let rasterSize = CGSize(width: ceil(width * ratio), height: ceil(height * ratio))
        let rendered = UIGraphicsImageRenderer(size: rasterSize, format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(origin: .zero, size: rasterSize))
            let context = renderer.cgContext
            context.scaleBy(x: ratio, y: ratio)
            var y: CGFloat = 0
            for region in regions {
                guard let page = pdf.page(at: region.page - 1) else { continue }
                context.saveGState()
                context.clip(to: CGRect(x: 0, y: y, width: region.bounds.width, height: region.bounds.height))
                context.translateBy(x: 0, y: y + region.bounds.height)
                context.scaleBy(x: 1, y: -1)
                context.translateBy(x: -region.bounds.minX, y: -region.bounds.minY)
                page.draw(with: .cropBox, to: context)
                context.restoreGState()
                y += region.bounds.height + gap
            }
        }
        try Task.checkCancellation()
        // Remove only blank outer paper after rendering. Keeping full PDF width
        // until this point preserves diagrams that extend beyond the text column.
        let image = Self.trimmingBlankPaper(rendered)
        guard let bytes = image.pngData(), let first = regions.first,
              let page = pdf.page(at: first.page - 1) else { return nil }
        let box = page.bounds(for: .cropBox)
        let display = min(560 / image.size.width, 900 / image.size.height, 1 / ratio)
        var properties = ["page": Double(first.page), "questionNumber": Double(request.number),
                          "pdfPageCount": Double(regions.count),
                          "pdfCropX": Double((first.bounds.minX - box.minX) / box.width),
                          "pdfCropY": Double((first.bounds.minY - box.minY) / box.height),
                          "pdfCropWidth": Double(first.bounds.width / box.width),
                          "pdfCropHeight": Double(first.bounds.height / box.height)]
        if let chapter = request.chapter { properties["chapter"] = Double(chapter) }
        let excerpts = regions.compactMap { region in pdf.page(at: region.page - 1)?.selection(for: region.bounds)?.string }
        return CanvasObject(kind: "image", title: "\(item.title) · Question \(request.label)", x: point.x, y: point.y,
                            width: max(1, image.size.width * display), height: max(1, image.size.height * display),
                            color: "#FFFFFF", text: String(excerpts.joined(separator: "\n").prefix(60_000)),
                            properties: properties, imageData: bytes)
    }

    private static func trimmingBlankPaper(_ image: UIImage) -> UIImage {
        guard let source = image.cgImage else { return image }
        let width = source.width, height = source.height
        guard width > 0, height > 0, width * height <= 3_000_000 else { return image }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            var left = width, right = -1, top = height, bottom = -1
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    if buffer[offset] < 250 || buffer[offset + 1] < 250 || buffer[offset + 2] < 250 {
                        left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                    }
                }
            }
            guard right >= left, bottom >= top else { return image }
            let padding = 12
            left = max(0, left - padding); right = min(width - 1, right + padding)
            top = max(0, top - padding); bottom = min(height - 1, bottom + padding)
            guard let trimmed = context.makeImage()?.cropping(to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)) else { return image }
            return UIImage(cgImage: trimmed)
        }
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
