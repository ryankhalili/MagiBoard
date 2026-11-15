import XCTest
@testable import CanvasStudio

@MainActor
final class VoiceLifecycleTests: XCTestCase {
    func testPermissionResponseAfterStopCannotStartOrStopReplacementSession() {
        var gate = VoiceSessionGate()
        let old = gate.begin()
        gate.cancel()
        let current = gate.begin()
        XCTAssertFalse(gate.listen(old))
        XCTAssertFalse(gate.accept("stale callback", for: old))
        XCTAssertFalse(gate.end(old))
        XCTAssertTrue(gate.contains(current))
        XCTAssertTrue(gate.listen(current))
        XCTAssertEqual(gate.phase, .listening)
    }

    func testSilenceAndFinalResultDispatchOneUtterance() {
        var gate = VoiceSessionGate()
        let id = gate.begin()
        XCTAssertTrue(gate.listen(id))
        XCTAssertTrue(gate.accept("Make a green", for: id))
        XCTAssertTrue(gate.finish(id))
        XCTAssertFalse(gate.finish(id))
        // A final refinement may arrive during the bounded finishing grace period.
        XCTAssertTrue(gate.accept("Make a green triangle.", for: id))
        XCTAssertEqual(gate.claimUtterance(id), "Make a green triangle.")
        XCTAssertNil(gate.claimUtterance(id))
        XCTAssertFalse(gate.accept("Late duplicate", for: id))
        XCTAssertTrue(gate.end(id))
        XCTAssertNil(gate.claimUtterance(id))
    }

    func testBlankSpeechNeverBecomesAnAction() {
        var gate = VoiceSessionGate()
        let id = gate.begin()
        XCTAssertTrue(gate.listen(id))
        XCTAssertTrue(gate.accept(" \n  ", for: id))
        XCTAssertNil(gate.claimUtterance(id))
        var turn = ConversationTurnGate()
        let session = turn.begin()
        XCTAssertFalse(turn.submit("  \n", for: session))
        XCTAssertEqual(turn.phase, .starting)
    }

    func testConversationRejectsSpeakerFeedbackAndDuplicateCommands() {
        var gate = ConversationTurnGate()
        let id = gate.begin()
        XCTAssertTrue(gate.listening(id))
        XCTAssertTrue(gate.submit("Make a triangle", for: id))
        XCTAssertFalse(gate.submit("Duplicate recognizer callback", for: id))
        XCTAssertFalse(gate.prepareToListen(id), "The microphone must remain off while the agent works")
        XCTAssertTrue(gate.speaking(id))
        XCTAssertFalse(gate.submit("I made a triangle", for: id), "The spoken reply must not become a new command")
        XCTAssertFalse(gate.speaking(id), "Repeated reply updates must not speak twice")
        XCTAssertTrue(gate.prepareToListen(id))
        XCTAssertTrue(gate.listening(id))
        XCTAssertTrue(gate.submit("Make it green", for: id))
    }

    func testStoppingConversationInvalidatesPendingSpeechCompletion() {
        var gate = ConversationTurnGate()
        let old = gate.begin()
        XCTAssertTrue(gate.listening(old))
        XCTAssertTrue(gate.submit("Plot sine", for: old))
        XCTAssertTrue(gate.speaking(old))
        gate.stop()
        let current = gate.begin()
        XCTAssertFalse(gate.contains(old))
        XCTAssertFalse(gate.prepareToListen(old))
        XCTAssertFalse(gate.listening(old))
        XCTAssertFalse(gate.submit("old utterance", for: old))
        XCTAssertTrue(gate.contains(current))
        XCTAssertEqual(gate.phase, .starting)
    }

    func testConstructingAndStoppingControllersDoesNotActivateVoice() {
        let dictation = VoiceInput()
        XCTAssertFalse(dictation.listening)
        XCTAssertFalse(dictation.isStarting)
        XCTAssertEqual(dictation.transcript, "")
        dictation.stop()
        XCTAssertFalse(dictation.listening)
        let conversation = ConversationVoice()
        XCTAssertFalse(conversation.active)
        conversation.receiveReply("A reply without an explicit voice session must not speak.")
        XCTAssertFalse(conversation.active)
        XCTAssertEqual(conversation.stateLabel, "Voice off")
        conversation.stop()
        XCTAssertEqual(conversation.level, 0)
    }
}
