import XCTest
import AVFoundation
@testable import CanvasStudio

final class RealtimeVoiceTests: XCTestCase {
    func testToolCallRunsOnceAndContinuationWaitsUntilResponseFinishes() {
        var state = RealtimeTurnState()
        state.created("response_1")
        XCTAssertTrue(state.claim(callID: "call_1", responseID: "response_1"))
        XCTAssertFalse(state.claim(callID: "call_1", responseID: "response_1"))
        state.toolOutputSent()
        XCTAssertFalse(state.takeContinuation(), "Never create a second response while the tool-bearing response is active")
        XCTAssertTrue(state.claim(callID: "call_2", responseID: "response_1"))
        state.toolOutputSent()
        state.finished("response_1", status: "completed")
        XCTAssertTrue(state.takeContinuation(), "One response acknowledges both immediate tool results")
        XCTAssertFalse(state.takeContinuation(), "Do not enqueue duplicate continuations before response.created")
        state.created("response_2")
        XCTAssertFalse(state.awaitingResponse)
        XCTAssertFalse(state.takeContinuation())
    }

    func testBargeInRejectsInterruptedToolsAndOldResponseCannotFinishNewTurn() {
        var state = RealtimeTurnState()
        state.created("old")
        XCTAssertTrue(state.claim(callID: "already_applied", responseID: "old"))
        state.toolOutputSent()
        state.speechStarted()
        XCTAssertFalse(state.acceptsOutput(responseID: "old"))
        XCTAssertFalse(state.claim(callID: "late_command", responseID: "old"))
        state.finished("old", status: "cancelled")
        XCTAssertFalse(state.takeContinuation(), "An old acknowledgement must not interrupt new user speech")
        state.speechStopped(); state.created("new")
        XCTAssertTrue(state.acceptsOutput(responseID: "new"))
        XCTAssertFalse(state.acceptsOutput(responseID: "old"))
        state.finished("old", status: "completed")
        XCTAssertEqual(state.responseID, "new")
        XCTAssertTrue(state.claim(callID: "new_command", responseID: "new"))
        XCTAssertFalse(state.claim(callID: "already_applied", responseID: "new"), "A replayed call ID never changes the canvas twice")
    }

    func testFailedResponseDoesNotStartUnboundedContinuationLoop() {
        var state = RealtimeTurnState()
        state.created("failed")
        XCTAssertTrue(state.claim(callID: "call", responseID: "failed"))
        state.toolOutputSent(); state.finished("failed", status: "failed")
        XCTAssertFalse(state.takeContinuation())
        XCTAssertFalse(state.claim(callID: "unknown", responseID: "never_created"))
    }

    func testPCMDecodesLittleEndianSignedAudioAndRejectsBrokenFrames() throws {
        let samples = try XCTUnwrap(RealtimePCM.decode(Data([0, 0, 255, 127, 0, 128, 0, 64, 0, 192])))
        XCTAssertEqual(samples.count, 5)
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[1], Float(32767) / 32768, accuracy: 0.00001)
        XCTAssertEqual(samples[2], -1)
        XCTAssertEqual(samples[3], 0.5)
        XCTAssertEqual(samples[4], -0.5)
        XCTAssertNil(RealtimePCM.decode(Data()))
        XCTAssertNil(RealtimePCM.decode(Data([0])))
        XCTAssertNil(RealtimePCM.decode(Data(count: 960_002)))
    }

    func testTruncationTracksHeardAudioAndNeverExceedsGeneratedDuration() {
        XCTAssertEqual(RealtimePCM.playedMilliseconds(currentFrame: 48_000, startFrame: 24_000, frameCount: 72_000), 1000)
        XCTAssertEqual(RealtimePCM.playedMilliseconds(currentFrame: 12_000, startFrame: 24_000, frameCount: 72_000), 0)
        XCTAssertEqual(RealtimePCM.playedMilliseconds(currentFrame: 200_000, startFrame: 24_000, frameCount: 72_000), 3000)
        XCTAssertEqual(RealtimePCM.playedMilliseconds(currentFrame: 200_000, startFrame: 0, frameCount: 0), 0)
    }

    func testNativeStereoMicrophoneBufferConvertsToMono24kPCMWithoutRecording() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        buffer.frameLength = 960
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for index in 0..<960 { channels[0][index] = 0.5; channels[1][index] = 0.5 }
        let converter = try XCTUnwrap(RealtimeInputConverter(input: format))
        let (bytes, level) = try XCTUnwrap(converter.convert(buffer))
        let samples = try XCTUnwrap(RealtimePCM.decode(bytes))
        XCTAssertGreaterThan(samples.count, 300)
        XCTAssertLessThanOrEqual(samples.count, 544)
        XCTAssertGreaterThan(samples.max() ?? 0, 0.45)
        XCTAssertLessThan(samples.max() ?? 0, 0.6)
        XCTAssertGreaterThan(level, 0.5)
        XCTAssertLessThanOrEqual(level, 1)
    }

    @MainActor func testIdleVoiceDoesNotActivateAudioAndStopCannotResumeIt() {
        let voice = RealtimeVoice()
        XCTAssertFalse(voice.active); XCTAssertFalse(voice.starting)
        voice.updateContext("referenceID=unstarted")
        voice.reportTaskCompletion(taskID: UUID(), message: "Old task completed", failed: false)
        voice.stop(); voice.clearError()
        XCTAssertFalse(voice.active); XCTAssertFalse(voice.starting)
        XCTAssertEqual(voice.level, 0); XCTAssertEqual(voice.stateLabel, "Voice off")
        XCTAssertTrue(voice.reply.isEmpty)
    }
}
