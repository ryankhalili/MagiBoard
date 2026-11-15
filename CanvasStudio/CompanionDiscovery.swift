import Foundation
import Combine

struct NearbyCompanion: Identifiable, Equatable {
    var id: String
    var name: String
    var url: String
}

/// Bonjour advertises only a companion's address and friendly name, never a pairing secret.
final class CompanionDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var companions: [NearbyCompanion] = []
    @Published private(set) var searching = false
    @Published private(set) var message = ""
    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []
    private var stopWork: DispatchWorkItem?

    override init() {
        super.init()
        browser.delegate = self
    }
    func start() {
        stop()
        companions = []; message = "Looking for a Mac nearby…"; searching = true
        browser.searchForServices(ofType: "_magiboard._tcp.", inDomain: "local.")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stop()
            self.message = self.companions.isEmpty ? "No Mac found. Open the MagiBoard companion on the same Wi-Fi network." : "Choose your Mac below."
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }
    func stop() {
        stopWork?.cancel(); stopWork = nil
        browser.stop()
        resolving.forEach { $0.stop() }
        resolving = []; searching = false
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        resolving.append(service); service.delegate = self
        service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        stop()
        message = "Nearby discovery is unavailable. Allow Local Network access in iPad Settings, or import your Mac pairing file."
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard var host = sender.hostName, sender.port > 0 else { return }
        if host.hasSuffix(".") { host.removeLast() }
        var components = URLComponents(); components.scheme = "http"; components.host = host; components.port = sender.port
        guard let url = components.url?.absoluteString else { return }
        let id = sender.domain + sender.type + sender.name
        let item = NearbyCompanion(id: id, name: sender.name, url: url)
        companions.removeAll { $0.id == id }; companions.append(item)
        companions.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        message = "Choose your Mac below."
    }
}
