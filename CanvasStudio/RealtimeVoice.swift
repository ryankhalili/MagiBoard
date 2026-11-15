import Foundation
import SwiftUI
import AVFoundation
import UIKit

struct RealtimeSessionCredential: Decodable {
    var token: String
    var model: String
    var expiresAt: Double?
}

/// A small, deterministic gate for streamed responses and tool continuations.
/// No microphone or network is needed to exercise its interruption rules.
struct RealtimeTurnState {
    private(set) var responseID: String?
    private(set) var userSpeaking = false
    private(set) var awaitingResponse = false
    private(set) var pendingContinuation = false
    private(set) var handledCalls: Set<String> = []
    private(set) var interruptedResponses: Set<String> = []

    mutating func created(_ id: String) {
        responseID = id; awaitingResponse = false; pendingContinuation = false
    }
    mutating func speechStarted() {
        userSpeaking = true; pendingContinuation = false
        if let responseID { interruptedResponses.insert(responseID) }
    }
    mutating func speechStopped() { userSpeaking = false }
    mutating func claim(callID: String, responseID: String) -> Bool {
        guard !userSpeaking, self.responseID == responseID, !interruptedResponses.contains(responseID),
              handledCalls.count < 256, !handledCalls.contains(callID) else { return false }
        handledCalls.insert(callID)
        return true
    }
    mutating func toolOutputSent() { pendingContinuation = true }
    mutating func finished(_ id: String, status: String) {
        guard responseID == id else { return }
        responseID = nil
        if status != "completed" { pendingContinuation = false }
    }
    mutating func takeContinuation() -> Bool {
        guard pendingContinuation, responseID == nil, !userSpeaking, !awaitingResponse else { return false }
        pendingContinuation = false; awaitingResponse = true
        return true
    }
    func acceptsOutput(responseID: String) -> Bool {
        self.responseID == responseID && !userSpeaking && !interruptedResponses.contains(responseID)
    }
}

enum RealtimePCM {
    static let sampleRate: Double = 24_000
    static func decode(_ data: Data) -> [Float]? {
        guard !data.isEmpty, data.count.isMultiple(of: 2), data.count <= 960_000 else { return nil }
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return stride(from: 0, to: bytes.count, by: 2).map {
                let bits = UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8
                return Float(Int16(bitPattern: bits)) / 32768
            }
        }
    }
    static func playedMilliseconds(currentFrame: Int64, startFrame: Int64, frameCount: Int64) -> Int {
        let played = min(max(0, frameCount), max(0, currentFrame - startFrame))
        return Int(Double(played) * 1000 / sampleRate)
    }
}

/// Owned only by the audio tap. Conversion happens before the borrowed input
/// buffer is released; only copied PCM bytes cross onto the main actor.
final class RealtimeInputConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    init?(input: AVAudioFormat) {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: RealtimePCM.sampleRate,
                                        channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.converter = converter; format = output
    }
    func convert(_ input: AVAudioPCMBuffer) -> (Data, Double)? {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var failure: NSError?
        let result = converter.convert(to: output, error: &failure) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard failure == nil, result != .error, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return nil }
        let count = Int(output.frameLength)
        var energy = 0.0
        for index in 0..<count { let value = Double(samples[index]) / 32768; energy += value * value }
        return (Data(bytes: samples, count: count * MemoryLayout<Int16>.size), min(1, sqrt(energy / Double(count)) * 6))
    }
}

@MainActor
final class RealtimeVoice: NSObject, ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var starting = false
    @Published private(set) var transcript = ""
    @Published private(set) var reply = ""
    @Published private(set) var stateLabel = "Voice off"
    @Published private(set) var error = ""
    @Published private(set) var level = 0.0
    var onResponseCreated: ((String) -> Void)?

    private var generation: UUID?
    private var socket: URLSessionWebSocketTask?
    private var socketSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var bootstrapTask: Task<RealtimeSessionCredential, Error>?
    private var outbox: [String] = []
    private var queuedBytes = 0
    private var turn = RealtimeTurnState()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var tapInstalled = false
    private var ownsAudioSession = false
    private var playbackEpoch = UUID()
    private var scheduledEndFrame: Int64 = 0
    private var playbackItems: [PlaybackItem] = []
    private var pendingAudioBuffers = 0
    private var spokenReplies = true
    private var context = ""
    private var sentContext = ""
    private var contextItemIDs: [String] = []
    private var queuedTaskIDs: Set<UUID> = []
    private var beganAt = Date()
    private var lastActivity = Date()
    private var lastLevelUpdate = Date.distantPast
    private var currentUserItemID: String?
    private var speechStart: (() -> Void)?
    private var toolCall: ((String, [String: Any], String, String) -> [String: Any])?
    private struct PlaybackItem {
        var id: String
        var contentIndex: Int
        var startFrame: Int64
        var frames: Int64
    }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(audioChanged(_:)), name: .AVAudioEngineConfigurationChange, object: nil)
    }

    func start(agent: ConnectionClient, settings: StudioSettings, initialContext: String,
               onSpeechStart: @escaping () -> Void,
               onToolCall: @escaping (String, [String: Any], String, String) -> [String: Any]) async {
        guard !active, !starting else { return }
        guard settings.aiEnabled else { error = "Enable AI in Settings before starting realtime voice."; return }
        stop()
        let id = UUID(); generation = id
        starting = true; error = ""; transcript = ""; reply = ""; stateLabel = "Preparing realtime voice…"
        speechStart = onSpeechStart; toolCall = onToolCall
        spokenReplies = settings.spokenReplies
        context = String(initialContext.prefix(16_000))
        beganAt = Date(); lastActivity = beganAt
        startMonitor(id)
        guard await AVAudioApplication.requestRecordPermission() else {
            fail(id, "Allow Microphone access for MagiBoard in Settings, then try again."); return
        }
        guard isCurrent(id) else { return }
        for _ in 0..<25 {
            if UIApplication.shared.applicationState == .active { break }
            try? await Task.sleep(for: .milliseconds(100))
            guard isCurrent(id) else { return }
        }
        guard UIApplication.shared.applicationState != .background else { stop(); return }
        do {
            stateLabel = "Connecting realtime voice…"
            let task = Task<RealtimeSessionCredential, Error> {
                try await agent.request("realtime/session", settings: settings, body: Data("{}".utf8))
            }
            bootstrapTask = task
            let credential = try await task.value
            guard isCurrent(id) else { return }
            bootstrapTask = nil
            guard !credential.token.isEmpty, credential.token.count < 16_384,
                  credential.expiresAt.map({ $0 > Date().timeIntervalSince1970 }) ?? true else {
                throw NotebookError.invalid("The realtime connection expired. Tap Voice to request a new session.")
            }
            var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
            components.queryItems = [URLQueryItem(name: "model", value: credential.model)]
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 30
            request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 660
            let session = URLSession(configuration: configuration)
            let taskSocket = session.webSocketTask(with: request)
            taskSocket.maximumMessageSize = 2_000_000
            socketSession = session; socket = taskSocket
            taskSocket.resume()
            receiveTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await taskSocket.receive()
                        guard let self, self.generation == id else { return }
                        let data: Data
                        switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                        guard data.count <= 2_000_000,
                              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                        self.receive(event, id: id)
                    }
                } catch { self?.fail(id, "Realtime voice disconnected. \(Self.safeMessage(error.localizedDescription)) Tap Voice to reconnect.") }
            }
        } catch {
            guard generation == id else { return }
            fail(id, Self.safeMessage(error.localizedDescription))
        }
    }

    func updateContext(_ value: String) {
        context = String(value.prefix(16_000))
        guard active, context != sentContext else { return }
        lastActivity = Date()
        appendContext(context)
        sentContext = context
    }

    func reportTaskCompletion(taskID: UUID, message: String, failed: Bool) {
        guard active, queuedTaskIDs.remove(taskID) != nil else { return }
        let status = failed ? "failed" : "completed"
        appendContext("Canvas task \(taskID.uuidString) \(status): \(String(message.prefix(1_500))). This is background task status, not a new user request. Do not interrupt the user or start a response solely for this update.")
    }

    func clearError() { error = "" }
    func stop() {
        generation = nil
        bootstrapTask?.cancel(); bootstrapTask = nil
        receiveTask?.cancel(); receiveTask = nil
        sendTask?.cancel(); sendTask = nil
        monitorTask?.cancel(); monitorTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        socketSession?.invalidateAndCancel(); socketSession = nil
        outbox.removeAll(); queuedBytes = 0
        haltPlayback()
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine = nil; player = nil
        if ownsAudioSession {
            ownsAudioSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        active = false; starting = false; level = 0; stateLabel = "Voice off"
        turn = RealtimeTurnState(); sentContext = ""; contextItemIDs = []; queuedTaskIDs = []
        speechStart = nil; toolCall = nil; currentUserItemID = nil
    }

    private func isCurrent(_ id: UUID) -> Bool {
        guard generation == id else { return false }
        if Task.isCancelled { stop(); return false }
        return true
    }
    private func fail(_ id: UUID, _ message: String) {
        guard generation == id else { return }
        stop(); error = Self.safeMessage(message); stateLabel = "Voice stopped"
    }
    private static func safeMessage(_ message: String) -> String {
        String(message.prefix(1_200)).replacingOccurrences(of: #"\b(?:sk-|ek_)[A-Za-z0-9_-]+"#, with: "[redacted]", options: .regularExpression)
    }
    private func startMonitor(_ id: UUID) {
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.generation == id, !Task.isCancelled else { return }
                let now = Date()
                if self.starting && now.timeIntervalSince(self.beganAt) > 35 {
                    self.fail(id, "Realtime voice took too long to connect. Check the companion and try Voice again."); return
                }
                if now.timeIntervalSince(self.beganAt) >= 600 {
                    self.fail(id, "This ten-minute voice session has ended. Tap Voice to start another."); return
                }
                if self.active && now.timeIntervalSince(self.lastActivity) >= 90 {
                    self.fail(id, "Voice stopped after 90 seconds of inactivity. Tap Voice to resume."); return
                }
            }
        }
    }

    private func enqueue(_ event: [String: Any]) {
        guard let id = generation, socket != nil,
              let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        guard outbox.count < 180, queuedBytes + data.count < 1_000_000 else {
            fail(id, "The voice connection cannot keep up with the microphone. Check your network and reconnect."); return
        }
        outbox.append(text); queuedBytes += data.count
        guard sendTask == nil, let socket else { return }
        sendTask = Task { [weak self] in
            do {
                while let self, self.generation == id, !Task.isCancelled, !self.outbox.isEmpty {
                    let text = self.outbox.removeFirst(); self.queuedBytes -= text.utf8.count
                    try await socket.send(.string(text))
                }
                if self?.generation == id { self?.sendTask = nil }
            } catch { self?.fail(id, "Realtime audio could not be sent. Check your connection and tap Voice again.") }
        }
    }
    private func appendContext(_ text: String) {
        guard !text.isEmpty else { return }
        let itemID = "ctx_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)
        enqueue(["type": "conversation.item.create", "item": ["id": itemID, "type": "message", "role": "system",
                 "content": [["type": "input_text", "text": text]]]])
        contextItemIDs.append(itemID)
        if contextItemIDs.count > 24 {
            let oldest = contextItemIDs.removeFirst()
            enqueue(["type": "conversation.item.delete", "item_id": oldest])
        }
    }

    private func receive(_ event: [String: Any], id: UUID) {
        guard generation == id, let type = event["type"] as? String else { return }
        switch type {
        case "session.created":
            guard starting else { return }
            enqueue(["type": "session.update", "session": ["type": "realtime", "output_modalities": [spokenReplies ? "audio" : "text"]]])
            appendContext(context); sentContext = context
            do {
                try startAudio(id)
                starting = false; active = true; stateLabel = "Listening"; lastActivity = Date()
            } catch { fail(id, "Could not start realtime audio. \(Self.safeMessage(error.localizedDescription))") }
        case "input_audio_buffer.speech_started":
            turn.speechStarted(); transcript = ""; lastActivity = Date(); stateLabel = "Listening to you…"
            currentUserItemID = event["item_id"] as? String
            interruptPlayback()
            speechStart?()
        case "input_audio_buffer.speech_stopped":
            turn.speechStopped(); lastActivity = Date(); stateLabel = "Thinking…"
        case "conversation.item.input_audio_transcription.delta":
            if currentUserItemID == nil || currentUserItemID == event["item_id"] as? String {
                transcript = String((transcript + (event["delta"] as? String ?? "")).suffix(6_000))
            }
        case "conversation.item.input_audio_transcription.completed":
            if currentUserItemID == nil || currentUserItemID == event["item_id"] as? String {
                transcript = String((event["transcript"] as? String ?? "").prefix(6_000))
            }
        case "response.created":
            guard let response = event["response"] as? [String: Any], let responseID = response["id"] as? String else { return }
            turn.created(responseID); reply = ""; lastActivity = Date(); stateLabel = "Thinking…"
            onResponseCreated?(responseID)
        case "response.output_audio.delta":
            guard spokenReplies, let responseID = event["response_id"] as? String, turn.acceptsOutput(responseID: responseID),
                  let value = event["delta"] as? String, let data = Data(base64Encoded: value),
                  let itemID = event["item_id"] as? String else { return }
            play(data, itemID: itemID, contentIndex: event["content_index"] as? Int ?? 0, id: id)
        case "response.output_audio_transcript.delta", "response.output_text.delta":
            guard let responseID = event["response_id"] as? String, turn.acceptsOutput(responseID: responseID) else { return }
            reply = String((reply + (event["delta"] as? String ?? "")).suffix(8_000))
        case "response.function_call_arguments.done":
            handleTool(event)
        case "response.done":
            guard let response = event["response"] as? [String: Any], let responseID = response["id"] as? String else { return }
            let status = response["status"] as? String ?? "completed"
            turn.finished(responseID, status: status)
            if status == "failed" {
                let details = response["status_details"] as? [String: Any]
                let failure = details?["error"] as? [String: Any]
                error = Self.safeMessage(failure?["message"] as? String ?? "The voice response failed. You can try again.")
            }
            if pendingAudioBuffers == 0 && !turn.userSpeaking { stateLabel = "Listening" }
            flushContinuation()
        case "error":
            let detail = event["error"] as? [String: Any]
            let code = detail?["code"] as? String ?? ""
            // VAD may already cancel the response before our explicit cancellation arrives.
            if ["response_cancel_not_active", "conversation_already_has_active_response"].contains(code) { return }
            fail(id, detail?["message"] as? String ?? "The realtime session reported an error. Tap Voice to reconnect.")
        default: break
        }
    }

    private func handleTool(_ event: [String: Any]) {
        guard let callID = event["call_id"] as? String, let responseID = event["response_id"] as? String,
              let name = event["name"] as? String, callID.count <= 128, responseID.count <= 128, name.count <= 80,
              turn.claim(callID: callID, responseID: responseID) else { return }
        let raw = event["arguments"] as? String ?? ""
        let result: [String: Any]
        if raw.utf8.count <= 128_000, let data = raw.data(using: .utf8),
           let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            result = toolCall?(name, arguments, callID, responseID) ?? ["status": "failed", "message": "Canvas tools are unavailable."]
        } else { result = ["status": "failed", "message": "The tool arguments were incomplete or too large. Please try a simpler instruction."] }
        var output = JSONSerialization.isValidJSONObject(result)
            ? (try? JSONSerialization.data(withJSONObject: result)).flatMap { String(data: $0, encoding: .utf8) } : nil
        if output == nil || output!.utf8.count > 32_000 { output = "{\"status\":\"failed\",\"message\":\"The tool result could not be serialized.\"}" }
        if let value = result["taskID"] as? String ?? result["task_id"] as? String, let taskID = UUID(uuidString: value) {
            queuedTaskIDs.insert(taskID)
        }
        enqueue(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": callID, "output": output!]])
        turn.toolOutputSent(); lastActivity = Date()
        flushContinuation()
    }
    private func flushContinuation() {
        if turn.takeContinuation() { enqueue(["type": "response.create"]) }
    }

    private func startAudio(_ id: UUID) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true); ownsAudioSession = true
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        self.engine = engine; self.player = player
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = RealtimeInputConverter(input: inputFormat),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: RealtimePCM.sampleRate, channels: 1) else {
            throw NotebookError.invalid("No compatible microphone is available. Reconnect it and try again.")
        }
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        input.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { [weak self] input, _ in
            guard let (data, measured) = converter.convert(input) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == id, self.active else { return }
                self.enqueue(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
                if Date().timeIntervalSince(self.lastLevelUpdate) > 0.08 {
                    self.level = measured; self.lastLevelUpdate = Date()
                }
            }
        }
        tapInstalled = true
        engine.prepare(); try engine.start(); player.play()
    }
    private func playbackFrame() -> Int64 {
        guard let player, let render = player.lastRenderTime, let time = player.playerTime(forNodeTime: render) else { return 0 }
        return max(0, time.sampleTime)
    }
    private func play(_ data: Data, itemID: String, contentIndex: Int, id: UUID) {
        guard let samples = RealtimePCM.decode(data), let player,
              let format = AVAudioFormat(standardFormatWithSampleRate: RealtimePCM.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = buffer.floatChannelData?[0] else { return }
        guard pendingAudioBuffers < 512 else { fail(id, "Voice playback could not keep up. Tap Voice to reconnect."); return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { destination.update(from: $0.baseAddress!, count: $0.count) }
        let current = playbackFrame(), start = max(current, scheduledEndFrame)
        if let index = playbackItems.firstIndex(where: { $0.id == itemID }) { playbackItems[index].frames += Int64(samples.count) }
        else { playbackItems.append(PlaybackItem(id: itemID, contentIndex: contentIndex, startFrame: start, frames: Int64(samples.count))) }
        scheduledEndFrame = start + Int64(samples.count)
        playbackItems.removeAll { $0.id != itemID && $0.startFrame + $0.frames <= current }
        pendingAudioBuffers += 1; lastActivity = Date(); stateLabel = "Speaking…"
        let epoch = playbackEpoch
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == id, self.playbackEpoch == epoch else { return }
                self.pendingAudioBuffers = max(0, self.pendingAudioBuffers - 1)
                if self.pendingAudioBuffers == 0 && self.turn.responseID == nil && !self.turn.userSpeaking { self.stateLabel = "Listening" }
            }
        }
        if !player.isPlaying { player.play() }
    }
    private func interruptPlayback() {
        let current = playbackFrame()
        for item in playbackItems {
            let heard = RealtimePCM.playedMilliseconds(currentFrame: current, startFrame: item.startFrame, frameCount: item.frames)
            let duration = Int(Double(item.frames) * 1000 / RealtimePCM.sampleRate)
            if heard < duration {
                enqueue(["type": "conversation.item.truncate", "item_id": item.id, "content_index": item.contentIndex, "audio_end_ms": heard])
            }
        }
        if let responseID = turn.responseID { enqueue(["type": "response.cancel", "response_id": responseID]) }
        haltPlayback()
        player?.play()
    }
    private func haltPlayback() {
        playbackEpoch = UUID(); player?.stop()
        scheduledEndFrame = 0; playbackItems = []; pendingAudioBuffers = 0
    }
    @objc private func backgrounded() { stop() }
    @objc nonisolated private func interrupted(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        Task { @MainActor [weak self] in
            guard let self, let id = self.generation else { return }
            self.fail(id, "Voice was interrupted by another audio session. Tap Voice to resume.")
        }
    }
    @objc nonisolated private func audioChanged(_ notification: Notification) {
        guard let changed = notification.object as? AVAudioEngine else { return }
        Task { @MainActor [weak self, weak changed] in
            guard let self, let changed, changed === self.engine, self.active, !changed.isRunning, let id = self.generation else { return }
            self.fail(id, "The audio route changed. Tap Voice to reconnect your microphone.")
        }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}
