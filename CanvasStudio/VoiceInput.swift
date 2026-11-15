import Foundation
import SwiftUI
import Speech
import AVFoundation
import Combine
import UIKit

/// A voice session may detach from its submitted jobs. The jobs still mutate the
/// canvas, while only the currently attached session can consume spoken replies.
@MainActor
final class VoiceTaskSession: ObservableObject {
    private var generation = UUID()
    private(set) var requestID: UUID?
    @discardableResult func begin() -> UUID { generation = UUID(); requestID = nil; return generation }
    func contains(_ id: UUID) -> Bool { generation == id }
    func detach() { generation = UUID(); requestID = nil }
    @discardableResult
    func send(_ command: String, agent: ConnectionClient, store: NotebookStore, library: PDFLibrary,
              completion: @escaping (String, Bool) -> Void) -> UUID? {
        let session = generation
        let id = agent.send(command, store: store, library: library) { [weak self] message, failed in
            guard let self, self.generation == session else { return }
            self.requestID = nil
            completion(message, failed)
        }
        requestID = id
        return id
    }
}

/// Session identities fence permission responses, final results and cancelled tasks.
struct VoiceSessionGate {
    enum Phase { case idle, starting, listening, finishing }
    private(set) var id: UUID?
    private(set) var phase: Phase = .idle
    private(set) var text = ""
    private var delivered = false
    mutating func begin() -> UUID {
        let next = UUID(); id = next; phase = .starting; text = ""; delivered = false; return next
    }
    func contains(_ candidate: UUID) -> Bool { id == candidate && phase != .idle }
    mutating func listen(_ candidate: UUID) -> Bool {
        guard contains(candidate), phase == .starting else { return false }; phase = .listening; return true
    }
    mutating func accept(_ value: String, for candidate: UUID) -> Bool {
        guard contains(candidate), !delivered else { return false }; text = value; return true
    }
    mutating func finish(_ candidate: UUID) -> Bool {
        guard contains(candidate), phase == .listening else { return false }; phase = .finishing; return true
    }
    mutating func claimUtterance(_ candidate: UUID) -> String? {
        guard contains(candidate), !delivered else { return nil }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        delivered = true; return clean
    }
    mutating func end(_ candidate: UUID) -> Bool {
        guard contains(candidate) else { return false }; cancel(); return true
    }
    mutating func cancel() { id = nil; phase = .idle; delivered = false }
}

struct ConversationTurnGate {
    enum Phase { case idle, starting, listening, thinking, speaking }
    private(set) var id: UUID?
    private(set) var phase: Phase = .idle
    mutating func begin() -> UUID { let next = UUID(); id = next; phase = .starting; return next }
    func contains(_ candidate: UUID) -> Bool { id == candidate && phase != .idle }
    mutating func prepareToListen(_ candidate: UUID) -> Bool {
        guard contains(candidate), phase == .starting || phase == .speaking else { return false }; phase = .starting; return true
    }
    mutating func listening(_ candidate: UUID) -> Bool {
        guard contains(candidate), phase == .starting else { return false }; phase = .listening; return true
    }
    mutating func submit(_ text: String, for candidate: UUID) -> Bool {
        guard contains(candidate), phase == .listening || phase == .starting,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        phase = .thinking; return true
    }
    mutating func speaking(_ candidate: UUID) -> Bool {
        guard contains(candidate), phase == .thinking else { return false }; phase = .speaking; return true
    }
    mutating func stop() { id = nil; phase = .idle }
}

@MainActor
final class VoiceInput: NSObject, ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var isStarting = false
    @Published private(set) var transcript = ""
    @Published private(set) var error = ""
    @Published private(set) var level: Double = 0
    @Published private(set) var status = ""
    var localeIdentifier = "en-US"
    var onUtterance: ((String) -> Void)?

    private var gate = VoiceSessionGate()
    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var ownsAudioSession = false
    private var monitorTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var continuous = false
    private var canFallback = false
    private var startedAt: TimeInterval = 0
    private var lastTextAt: TimeInterval = 0
    private var lastSpeechAt: TimeInterval = 0
    private var lastLevelAt: TimeInterval = 0

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(audioConfigurationChanged(_:)), name: .AVAudioEngineConfigurationChange, object: nil)
    }

    func start(continuous: Bool = false) async {
        guard !listening, !isStarting else { return }
        stop()
        let id = gate.begin()
        self.continuous = continuous
        isStarting = true; error = ""; transcript = ""; status = "Preparing microphone…"
        let authorization = await speechAuthorization()
        guard mayContinue(id) else { return }
        guard authorization == .authorized else {
            fail(id, message: authorization == .restricted ? "Speech recognition is restricted on this iPad." : "Allow Speech Recognition for MagiBoard in Settings, then try again.")
            return
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard mayContinue(id) else { return }
        guard microphone else { fail(id, message: "Allow Microphone access for MagiBoard in Settings, then try again."); return }
        // Permission sheets temporarily make the scene inactive. Wait for their dismissal.
        for _ in 0..<25 {
            guard mayContinue(id) else { return }
            if UIApplication.shared.applicationState == .active { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard mayContinue(id) else { return }
        guard UIApplication.shared.applicationState != .background else { stop(); return }
        beginCapture(id: id, preferOnDevice: true)
    }

    private func mayContinue(_ id: UUID) -> Bool {
        guard gate.contains(id) else { return false }
        if Task.isCancelled { stop(); return false }
        return true
    }

    private func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let existing = SFSpeechRecognizer.authorizationStatus()
        if existing != .notDetermined { return existing }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { result in continuation.resume(returning: result) }
        }
    }

    private func beginCapture(id: UUID, preferOnDevice: Bool) {
        guard gate.contains(id) else { return }
        guard let speech = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            fail(id, message: "Speech recognition is not available for this language. Choose another language in Settings."); return
        }
        guard speech.isAvailable else {
            fail(id, message: "Apple speech recognition is unavailable. Check your connection and try the microphone again."); return
        }
        recognizer = speech
        let local = preferOnDevice && speech.supportsOnDeviceRecognition
        canFallback = local
        do {
            let audio = AVAudioSession.sharedInstance()
            // .record cannot be combined with .duckOthers. Play-and-record also supports headset microphones.
            try audio.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audio.setActive(true)
            ownsAudioSession = true
            let nextEngine = AVAudioEngine()
            let input = nextEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw VoiceError.message("No microphone input is available. Reconnect your microphone or use the iPad microphone.")
            }
            let nextRequest = SFSpeechAudioBufferRecognitionRequest()
            nextRequest.shouldReportPartialResults = true
            nextRequest.taskHint = .dictation
            nextRequest.addsPunctuation = true
            nextRequest.requiresOnDeviceRecognition = local
            nextRequest.contextualStrings = ["Magic Pen", "LaTeX", "triangle", "y intercept", "sine", "cosine", "amplitude", "Sakurai"]
            engine = nextEngine; request = nextRequest
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                nextRequest.append(buffer)
                let measured = Self.audioLevel(buffer)
                Task { @MainActor [weak self] in self?.receivedLevel(measured, id: id) }
            }
            tapInstalled = true
            recognition = speech.recognitionTask(with: nextRequest) { [weak self] result, failure in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                let reason = failure.map { ($0 as NSError).localizedDescription }
                Task { @MainActor [weak self] in self?.received(text: text, final: final, failure: reason, id: id) }
            }
            nextEngine.prepare()
            try nextEngine.start()
            guard gate.listen(id) else { stop(); return }
            startedAt = ProcessInfo.processInfo.systemUptime
            lastTextAt = startedAt; lastSpeechAt = startedAt; lastLevelAt = 0
            isStarting = false; listening = true
            status = local ? "Listening on this iPad" : "Listening with Apple speech recognition"
            startMonitor(id)
        } catch {
            fail(id, message: "Could not start the microphone: \(error.localizedDescription)")
        }
    }

    private nonisolated static func audioLevel(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?.pointee, buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        let count = Int(buffer.frameLength)
        for index in stride(from: 0, to: count, by: 4) { let value = channel[index]; sum += value * value }
        let rms = sqrt(Double(sum) / Double(max(1, (count + 3) / 4)))
        return min(1, max(0, (20 * log10(max(rms, 0.000001)) + 55) / 45))
    }
    private func receivedLevel(_ value: Double, id: UUID) {
        guard gate.contains(id), gate.phase == .listening else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if value > 0.18 { lastSpeechAt = now }
        if now - lastLevelAt >= 0.08 { level = value; lastLevelAt = now }
    }
    private func received(text: String?, final: Bool, failure: String?, id: UUID) {
        guard gate.contains(id) else { return }
        if let text, gate.accept(text, for: id) {
            if text != transcript { lastTextAt = ProcessInfo.processInfo.systemUptime }
            transcript = text
        }
        if final {
            complete(id, emit: continuous)
        } else if let failure {
            if gate.phase == .finishing { complete(id, emit: continuous) }
            else if canFallback && transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fallbackFromLocalRecognition(id)
            } else {
                fail(id, message: "Speech recognition stopped: \(failure) Tap the microphone to try again.")
            }
        }
    }
    private func fallbackFromLocalRecognition(_ id: UUID) {
        guard gate.contains(id), canFallback else { return }
        gate.cancel()
        releaseCapture(deactivate: true)
        let replacement = gate.begin()
        isStarting = true; listening = false
        status = "Trying Apple speech recognition…"
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.gate.contains(replacement) else { return }
            self.beginCapture(id: replacement, preferOnDevice: false)
        }
    }
    private func startMonitor(_ id: UUID) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, self.gate.contains(id), self.gate.phase == .listening else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let hasWords = !self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if self.continuous && hasWords && now - max(self.lastTextAt, self.lastSpeechAt) >= 1.3 {
                    self.finishUtterance(id); return
                }
                if now - self.startedAt > 55 {
                    if hasWords { self.finishUtterance(id) }
                    else { self.fail(id, message: "I didn’t hear any words. Tap the microphone and try again.") }
                    return
                }
            }
        }
    }
    private func finishUtterance(_ id: UUID) {
        guard gate.finish(id) else { return }
        listening = false; level = 0; status = "Finishing your sentence…"
        haltAudioInput()
        request?.endAudio()
        recognition?.finish()
        finalizationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, self.gate.contains(id) else { return }
            self.complete(id, emit: self.continuous)
        }
    }
    private func complete(_ id: UUID, emit: Bool) {
        guard gate.contains(id) else { return }
        let utterance = emit ? gate.claimUtterance(id) : nil
        _ = gate.end(id)
        releaseCapture(deactivate: true)
        isStarting = false; listening = false; level = 0
        status = transcript.isEmpty ? "No speech captured" : "Captured"
        if emit && utterance == nil {
            error = "I didn’t catch any words. Tap the microphone and try again."
        }
        if let utterance { onUtterance?(utterance) }
    }
    private func fail(_ id: UUID, message: String) {
        guard gate.end(id) else { return }
        releaseCapture(deactivate: true)
        isStarting = false; listening = false; level = 0; status = "Microphone stopped"
        error = message
    }
    func clearError() { error = "" }
    func stop() {
        gate.cancel()
        releaseCapture(deactivate: true)
        isStarting = false; listening = false; level = 0; status = "Microphone off"
    }
    private func haltAudioInput() {
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
    }
    private func releaseCapture(deactivate: Bool) {
        monitorTask?.cancel(); monitorTask = nil
        finalizationTask?.cancel(); finalizationTask = nil
        restartTask?.cancel(); restartTask = nil
        haltAudioInput()
        request?.endAudio()
        recognition?.cancel()
        recognition = nil; request = nil; recognizer = nil; engine = nil
        if deactivate && ownsAudioSession {
            ownsAudioSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    @objc private func backgrounded() { stop() }
    @objc nonisolated private func audioInterrupted(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        Task { @MainActor [weak self] in
            guard let self, self.ownsAudioSession, let id = self.gate.id else { return }
            self.fail(id, message: "The microphone was interrupted by another audio session. Tap it to resume.")
        }
    }
    @objc nonisolated private func audioConfigurationChanged(_ notification: Notification) {
        guard let changed = notification.object as? AVAudioEngine else { return }
        Task { @MainActor [weak self, weak changed] in
            guard let self, let changed, changed === self.engine,
                  self.listening, !changed.isRunning, let id = self.gate.id else { return }
            self.fail(id, message: "The microphone connection changed. Tap the microphone to resume.")
        }
    }
}

private enum VoiceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

@MainActor
final class ConversationVoice: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var active = false
    @Published private(set) var stateLabel = "Voice off"
    @Published private(set) var transcript = ""
    @Published private(set) var error = ""
    @Published private(set) var level: Double = 0
    var localeIdentifier = "en-US"
    var spokenReplies = true
    var canStartNewReference: Bool { gate.phase == .thinking || gate.phase == .speaking }

    private let input = VoiceInput()
    private let speaker = AVSpeechSynthesizer()
    private var gate = ConversationTurnGate()
    private var command: ((String) -> Void)?
    private var subscriptions = Set<AnyCancellable>()
    private var resumeTask: Task<Void, Never>?
    private var speakingUtterance: AVSpeechUtterance?
    private var speakingSession: UUID?
    private var ownsPlaybackSession = false
    private var speechTimeout: Task<Void, Never>?

    override init() {
        super.init()
        speaker.delegate = self
        input.$transcript.sink { [weak self] in self?.transcript = $0 }.store(in: &subscriptions)
        input.$level.sink { [weak self] in self?.level = $0 }.store(in: &subscriptions)
        input.$status.sink { [weak self] text in
            guard let self, self.active, self.gate.phase == .starting || self.gate.phase == .listening else { return }
            if !text.isEmpty { self.stateLabel = text }
        }.store(in: &subscriptions)
        input.$error.sink { [weak self] message in
            guard let self, self.active, !message.isEmpty else { return }
            self.pauseWithError(message)
        }.store(in: &subscriptions)
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
    }
    func start(onCommand: @escaping (String) -> Void) async {
        stop()
        let id = gate.begin()
        command = onCommand; active = true; error = ""; transcript = ""; stateLabel = "Preparing microphone…"
        await listen(id)
    }
    private func listen(_ id: UUID) async {
        guard gate.contains(id), active, gate.prepareToListen(id) else { return }
        input.localeIdentifier = localeIdentifier
        input.onUtterance = { [weak self] text in
            guard let self, self.active, self.gate.submit(text, for: id) else { return }
            self.level = 0; self.stateLabel = "Working on your canvas…"
            self.command?(text)
        }
        await input.start(continuous: true)
        guard gate.contains(id), active else { return }
        if input.listening {
            _ = gate.listening(id)
            stateLabel = input.status
        } else if !input.error.isEmpty { pauseWithError(input.error) }
    }
    func receiveReply(_ text: String) {
        guard active, let id = gate.id, gate.speaking(id) else { return }
        input.stop()
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !spokenReplies || clean.isEmpty { scheduleListening(id); return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            ownsPlaybackSession = true
            let utterance = AVSpeechUtterance(string: String(clean.prefix(900)))
            utterance.voice = AVSpeechSynthesisVoice(language: localeIdentifier)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            speakingUtterance = utterance; speakingSession = id
            stateLabel = "Speaking"
            speaker.speak(utterance)
            speechTimeout?.cancel()
            speechTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(min(120, max(15, Double(utterance.speechString.count) / 10 + 12))))
                guard !Task.isCancelled, let self, self.active, self.speakingUtterance === utterance, self.gate.contains(id) else { return }
                self.pauseWithError("The spoken reply did not finish. Start voice again to continue, or turn off spoken replies in Settings.")
            }
        } catch { pauseWithError("Could not play the spoken reply: \(error.localizedDescription)") }
    }
    func receiveFailure(_ message: String) {
        guard active else { return }
        pauseWithError(message.isEmpty ? "The canvas request failed. Start voice again to retry." : message)
    }
    private func scheduleListening(_ id: UUID) {
        guard gate.contains(id), active else { return }
        stateLabel = "Listening again…"
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            // Leave a short gap so the speaker's last syllable is not recognized as a command.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, self.gate.contains(id), self.active else { return }
            self.releasePlaybackSession()
            await self.listen(id)
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.speakingUtterance === utterance, let id = self.speakingSession,
                  self.active, self.gate.contains(id) else { return }
            self.speechTimeout?.cancel(); self.speechTimeout = nil
            self.speakingUtterance = nil; self.speakingSession = nil
            self.scheduleListening(id)
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.speakingUtterance === utterance, self.active else { return }
            self.pauseWithError("The spoken reply was interrupted. Start voice again to continue.")
        }
    }
    private func pauseWithError(_ message: String) {
        stop()
        error = message; stateLabel = "Voice paused"
    }
    func clearError() { error = "" }
    func stop() {
        gate.stop(); active = false
        resumeTask?.cancel(); resumeTask = nil
        speechTimeout?.cancel(); speechTimeout = nil
        input.onUtterance = nil; input.stop()
        speakingUtterance = nil; speakingSession = nil
        speaker.stopSpeaking(at: .immediate)
        command = nil; level = 0; stateLabel = "Voice off"
        releasePlaybackSession()
    }
    private func releasePlaybackSession() {
        if ownsPlaybackSession {
            ownsPlaybackSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    @objc private func backgrounded() { stop() }
    @objc nonisolated private func audioInterrupted(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        Task { @MainActor [weak self] in
            guard let self, self.active, self.ownsPlaybackSession || self.input.listening else { return }
            self.pauseWithError("Voice was interrupted by another audio session. Start it again to continue.")
        }
    }
}
