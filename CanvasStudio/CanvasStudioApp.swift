import SwiftUI

@main
struct CanvasStudioApp: App {
    @StateObject private var store: NotebookStore
    @StateObject private var library: PDFLibrary
    private let testing: Bool
    init() {
        testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        if testing {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("CanvasStudioUITests-\(UUID().uuidString)")
            _store = StateObject(wrappedValue: NotebookStore(storageURL: root, loadSaved: false))
            _library = StateObject(wrappedValue: PDFLibrary(directory: root.appendingPathComponent("PDFs")))
        } else {
            _store = StateObject(wrappedValue: NotebookStore())
            _library = StateObject(wrappedValue: PDFLibrary())
        }
    }
    var body: some Scene {
        WindowGroup {
            StudioView(store: store, library: library)
                .preferredColorScheme(store.settings.darkMode ? .dark : .light)
                .onOpenURL { url in
                    if url.pathExtension == "canvaspair" { ConnectionClient.importPairing(url, into: store) }
                    else if url.pathExtension.lowercased() == "pdf" {
                        do { try library.importDocument(url: url); store.status = "Added PDF to your reference library" }
                        catch { store.status = error.localizedDescription }
                    } else { store.load(url: url) }
                }
                .task {
                    // A development install can deliver pairing as a separate private file.
                    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("pairing.canvaspair")
                    if !testing && FileManager.default.fileExists(atPath: url.path) {
                        ConnectionClient.importPairing(url, into: store)
                        try? FileManager.default.removeItem(at: url)
                    }
                }
        }
    }
}
