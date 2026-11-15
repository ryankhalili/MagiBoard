import SwiftUI
import UniformTypeIdentifiers

struct StudioSettingsView: View {
    @ObservedObject var store: NotebookStore
    @ObservedObject var agent: ConnectionClient
    @Environment(\.dismiss) private var dismiss
    @State private var category: SettingsCategory? = .account
    @State private var pairingImport = false
    @State private var checking = false
    @State private var signingIn = false
    @State private var connectionNote = ""
    @State private var backupURL: URL?
    @State private var advancedConnection = false
    @StateObject private var discovery = CompanionDiscovery()

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $category) { item in
                NavigationLink(value: item) {
                    Label {
                        Text(item.title)
                    } icon: {
                        Image(systemName: item.icon).font(.body)
                            .foregroundStyle(.white).frame(width: 29, height: 29)
                            .background(item.color, in: RoundedRectangle(cornerRadius: 7))
                    }.padding(.vertical, 4)
                }.tag(item).accessibilityIdentifier("settings_category_\(item.rawValue)")
            }
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 220, ideal: 245, max: 275)
        } detail: {
            NavigationStack {
                Form {
                    switch category ?? .account {
                    case .account: accountSettings
                    case .magic: magicSettings
                    case .canvas: canvasSettings
                    case .storage: storageSettings
                    case .about: aboutSettings
                    }
                }
                .navigationTitle((category ?? .account).title)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(.purple)
        .fileImporter(isPresented: $pairingImport, allowedContentTypes: [.data, .json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                ConnectionClient.importPairing(url, into: store)
                if store.status == "Mac companion paired" { checkConnection() }
                else { connectionNote = "That pairing file could not be opened. Export a new one from the Mac companion." }
            case .failure: connectionNote = "The pairing file could not be opened. Please try again."
            }
        }
        .task { if !store.settings.bridgeURL.isEmpty { await agent.check(store.settings) } }
        .onDisappear { discovery.stop() }
        .presentationDetents([.large])
    }

    @ViewBuilder private var accountSettings: some View {
        Section {
            HStack(spacing: 16) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 46)).foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 5) {
                    Text("ChatGPT subscription").font(.headline)
                    Label(agent.connected ? "Connected" : "Not connected", systemImage: agent.connected ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline).foregroundStyle(agent.connected ? .green : .secondary)
                }
                Spacer()
            }.padding(.vertical, 9)
            if agent.connected {
                Label("Mac companion", systemImage: "desktopcomputer")
                    .foregroundStyle(.secondary)
            } else {
                Button("Connect Mac companion", systemImage: "link") { pairingImport = true }
            }
        } footer: {
            Text("MagiBoard uses Codex on your Mac with your ChatGPT subscription. Keep the companion open while using AI on your iPad.")
        }
        if paired {
            Section {
                Button(checking ? "Checking connection…" : "Check connection", systemImage: "arrow.triangle.2.circlepath") { checkConnection() }
                    .disabled(checking)
                Button(signingIn ? "Opening sign-in…" : "Sign in with ChatGPT", systemImage: "person.crop.circle.badge.checkmark") {
                    signingIn = true; agent.login = nil; connectionNote = ""
                    Task {
                        await agent.signIn(store.settings); signingIn = false
                        if agent.login?.userCode == nil {
                            connectionNote = agent.connected ? "Your ChatGPT account is already connected." : "Sign-in could not start. Check the Mac companion and try again."
                        }
                    }
                }.disabled(signingIn)
                if let login = agent.login, let code = login.userCode {
                    VStack(alignment: .leading, spacing: 13) {
                        Text("Finish connecting your account").font(.headline)
                        Text("Enter this code on the secure sign-in page.").font(.subheadline).foregroundStyle(.secondary)
                        Text(code).font(.title2.monospaced().weight(.semibold)).textSelection(.enabled)
                        if let address = login.verificationUrl, let url = URL(string: address) {
                            Link("Open ChatGPT sign-in", destination: url).buttonStyle(.borderedProminent)
                        }
                        Button("I’ve finished signing in") { checkConnection() }
                    }.padding(.vertical, 9)
                }
                Button("Disconnect this iPad", role: .destructive) {
                    agent.disconnect(store); connectionNote = "This iPad has been disconnected."
                }
            } footer: { if !connectionNote.isEmpty { Text(connectionNote) } }
        } else if !connectionNote.isEmpty {
            Section { Text(connectionNote).font(.subheadline).foregroundStyle(.secondary) }
        }
        Section {
            DisclosureGroup("Advanced connection", isExpanded: $advancedConnection) {
                TextField("Mac companion address", text: $store.settings.bridgeURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("bridgeURL")
                SecureField("Pairing token", text: $store.settings.bridgeToken)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Import Mac pairing file…", systemImage: "square.and.arrow.down") { pairingImport = true }
                Button(discovery.searching ? "Looking for your Mac…" : "Find nearby Mac", systemImage: "antenna.radiowaves.left.and.right") { discovery.start() }
                    .disabled(discovery.searching)
                ForEach(discovery.companions) { companion in
                    Button {
                        store.settings.bridgeURL = companion.url
                        connectionNote = store.settings.bridgeToken.isEmpty
                            ? "Mac found. Import its pairing file to connect securely."
                            : "Mac selected. Check the connection to continue."
                    } label: { Label(companion.name, systemImage: "desktopcomputer") }
                }
                if !discovery.message.isEmpty { Text(discovery.message).font(.caption).foregroundStyle(.secondary) }
                Text("Your ChatGPT credentials remain on the Mac. This iPad’s pairing token is stored in Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var magicSettings: some View {
        Section {
            Toggle("Magic Pen & AI", isOn: $store.settings.aiEnabled)
        } footer: { Text("Tap or select an area to give Magic Pen a place to focus. Then ask it to create or change something.") }
        Section("Conversation") {
            Picker("When holding Magic Pen", selection: $store.settings.voiceMode) {
                Text("Open voice conversation").tag(true)
                Text("Open text input").tag(false)
            }
            Toggle("Speak replies aloud", isOn: $store.settings.spokenReplies)
            Picker("Speech language", selection: $store.settings.speechLocale) {
                Text("English (United States)").tag("en-US")
                Text("English (United Kingdom)").tag("en-GB")
                Text("Spanish").tag("es-ES")
                Text("French").tag("fr-FR")
                Text("German").tag("de-DE")
                Text("Chinese (Mandarin)").tag("zh-CN")
            }
        }
        Section {
            Label("Type quietly in a classroom", systemImage: "keyboard")
                .font(.subheadline)
            Text("You can switch between typing and speaking in Magic Pen. Speech uses Apple recognition, with an online fallback when on-device recognition is unavailable.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var canvasSettings: some View {
        Section("Appearance") {
            Toggle("Dark appearance", isOn: $store.settings.darkMode)
            Picker("Paper", selection: $store.settings.paperStyle) {
                Text("Blank").tag("blank")
                Text("Dots").tag("dots")
                Text("Ruled").tag("ruled")
                Text("Grid").tag("grid")
            }.onChange(of: store.settings.paperStyle) { _, style in store.settings.showGrid = style != "blank" }
            Toggle("Compact header", isOn: $store.settings.compactHeader)
        }
        Section {
            Toggle("Draw with a finger", isOn: $store.settings.drawWithFinger)
            Toggle("Recognize simple shapes", isOn: $store.settings.recognizeShapes)
        } header: { Text("Writing") } footer: {
            Text("When finger drawing is off, use Apple Pencil to write and your fingers to move the canvas. Shape recognition turns simple closed strokes into editable shapes.")
        }
    }

    @ViewBuilder private var storageSettings: some View {
        Section("On this iPad") {
            LabeledContent("Notebooks", value: String(store.notebooks.count))
            LabeledContent("Saved objects", value: String(store.catalog.count))
            Label("Changes save automatically", systemImage: "checkmark.circle")
        }
        Section {
            Button("Prepare notebook backup", systemImage: "square.and.arrow.up") { backupURL = store.exportNotebook() }
            if let backupURL {
                ShareLink(item: backupURL) { Label("Save or share backup", systemImage: "doc.badge.arrow.up") }
            }
        } header: { Text("Backup") } footer: {
            Text("An editable backup includes your handwriting and canvas objects. Save it to Files or share it with another iPad.")
        }
        Section("Privacy") {
            Label("No analytics or advertising", systemImage: "hand.raised")
            Text("Your notebooks stay on this iPad. AI requests share canvas context and relevant reference excerpts with your connected Mac companion.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var aboutSettings: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "pencil.and.outline").font(.system(size: 40)).foregroundStyle(.purple)
                Text("MagiBoard").font(.title.weight(.bold))
                Text("A notebook with room for anything.").font(.subheadline).foregroundStyle(.secondary)
                Text("Hackathon prototype").font(.caption).foregroundStyle(.tertiary)
            }.padding(.vertical, 12)
        }
        Section {
            Text("Created with original Swift code and Apple’s PencilKit, PDFKit and WebKit.")
            Text("Writing and canvas tools work offline. Connected Magic Pen uses Codex through your Mac companion. Offline Magic Pen supports a limited set of example commands.")
                .foregroundStyle(.secondary)
        }
    }
    private var paired: Bool { !store.settings.bridgeURL.isEmpty && !store.settings.bridgeToken.isEmpty }
    private func checkConnection() {
        checking = true; connectionNote = ""
        Task {
            await agent.check(store.settings); checking = false
            if agent.connected { connectionNote = "Your ChatGPT account is connected and ready." }
            else if agent.connectionLabel.contains("sign in") { connectionNote = "Your Mac is connected. Sign in with ChatGPT to continue." }
            else { connectionNote = "Couldn’t reach your Mac companion. Make sure it’s open and both devices are on the same Wi-Fi network." }
        }
    }
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case account, magic, canvas, storage, about
    var id: Self { self }
    var title: String {
        switch self {
        case .account: return "Account"
        case .magic: return "Voice & Magic"
        case .canvas: return "Canvas"
        case .storage: return "Storage"
        case .about: return "About"
        }
    }
    var icon: String {
        switch self {
        case .account: return "person.fill"
        case .magic: return "wand.and.stars"
        case .canvas: return "pencil.tip"
        case .storage: return "internaldrive.fill"
        case .about: return "info"
        }
    }
    var color: Color {
        switch self {
        case .account: return .purple
        case .magic: return .indigo
        case .canvas: return .orange
        case .storage: return .blue
        case .about: return .gray
        }
    }
}
