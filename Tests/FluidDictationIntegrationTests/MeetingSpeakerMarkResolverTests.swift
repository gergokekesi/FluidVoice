@testable import FluidVoice_Debug
import Foundation
import XCTest

/// The fixture's presentation origin is 0, so a mark's host seconds equal its meeting seconds.
final class MeetingSpeakerMarkResolverTests: XCTestCase {
    private static let turnEnd: TimeInterval = 7
    private static let lookback = MeetingSpeakerMarkResolver.lookbackSeconds

    func testAMarkDuringATurnNamesThatVoice() {
        var session = Self.sessionWithFinalRemoteTurn()
        session.speakerMarks = [MeetingSpeakerMark(pressedAtHostSeconds: 5.5, name: "Alice")]

        MeetingSpeakerMarkResolver.apply(to: &session)

        XCTAssertEqual(session.speakers.map(\.displayName), ["Alice"])
        XCTAssertEqual(session.speakerMarks, [MeetingSpeakerMark(pressedAtHostSeconds: 5.5, name: "Alice", resolution: .named(MeetingModelFixture.speakerID))])
    }

    func testAMarkJustAfterATurnEndsNamesThatVoice() {
        var session = Self.sessionWithFinalRemoteTurn()
        session.speakerMarks = [MeetingSpeakerMark(pressedAtHostSeconds: Self.turnEnd + Self.lookback - 1, name: "Alice")]

        MeetingSpeakerMarkResolver.apply(to: &session)

        XCTAssertEqual(session.speakers.map(\.displayName), ["Alice"])
        XCTAssertEqual(session.speakerMarks?.map(\.resolution), [.named(MeetingModelFixture.speakerID)])
    }

    func testAMarkWithNobodySpeakingIsReported() {
        var session = Self.sessionWithFinalRemoteTurn()
        session.speakerMarks = [MeetingSpeakerMark(pressedAtHostSeconds: Self.turnEnd + Self.lookback + 1, name: "Alice")]

        MeetingSpeakerMarkResolver.apply(to: &session)

        XCTAssertEqual(session.speakers.map(\.displayName), ["Speaker 1"])
        XCTAssertEqual(session.speakerMarks?.map(\.resolution), [.noSpeaker])
    }

    func testAMarkOverOnlyAMicrophoneLineNamesNobodyOnACall() {
        var session = Self.sessionWithFinalRemoteTurn()
        session.transcriptSegments[0].sourceTrackID = MeetingModelFixture.microphoneTrackID
        session.speakerMarks = [MeetingSpeakerMark(pressedAtHostSeconds: 5.5, name: "Alice")]

        MeetingSpeakerMarkResolver.apply(to: &session)

        XCTAssertEqual(session.speakers.map(\.displayName), ["Speaker 1"])
        XCTAssertEqual(session.speakerMarks?.map(\.resolution), [.noSpeaker])
    }

    func testAMarkOverOnlyAProbableEchoLineNamesNobody() {
        var session = Self.sessionWithFinalRemoteTurn()
        session.transcriptSegments[0].isLikelyEcho = true
        session.speakerMarks = [MeetingSpeakerMark(pressedAtHostSeconds: 5.5, name: "Alice")]

        MeetingSpeakerMarkResolver.apply(to: &session)

        XCTAssertEqual(session.speakers.map(\.displayName), ["Speaker 1"])
        XCTAssertEqual(session.speakerMarks?.map(\.resolution), [.noSpeaker])
    }

    func testAVoiceKeepsItsEarliestMarkedName() {
        var session = Self.sessionWithFinalRemoteTurn()
        session.speakerMarks = [
            MeetingSpeakerMark(pressedAtHostSeconds: 6, name: "Bob"),
            MeetingSpeakerMark(pressedAtHostSeconds: 5, name: "Alice"),
        ]

        MeetingSpeakerMarkResolver.apply(to: &session)

        XCTAssertEqual(session.speakers.map(\.displayName), ["Alice"])
        XCTAssertEqual(session.speakerMarks?.map(\.resolution), [.alreadyNamed("Alice"), .named(MeetingModelFixture.speakerID)])
    }

    func testTheSameNameOnTwoVoicesNamesBoth() {
        var session = Self.sessionWithFinalRemoteTurn()
        let secondID = UUID()
        session.speakers.append(MeetingModelFixture.speaker(id: secondID, name: "Speaker 2"))
        var secondTurn = session.transcriptSegments[0]
        secondTurn.id = UUID()
        secondTurn.speakerID = secondID
        secondTurn.start = MeetingModelFixture.mediaTime(10)
        secondTurn.end = MeetingModelFixture.mediaTime(12)
        session.transcriptSegments.append(secondTurn)
        session.speakerMarks = [
            MeetingSpeakerMark(pressedAtHostSeconds: 5, name: "Alice"),
            MeetingSpeakerMark(pressedAtHostSeconds: 11, name: "Alice"),
        ]

        MeetingSpeakerMarkResolver.apply(to: &session)

        XCTAssertEqual(session.speakers.map(\.displayName), ["Alice", "Alice"])
        XCTAssertEqual(session.speakerMarks?.map(\.resolution), [.named(MeetingModelFixture.speakerID), .named(secondID)])
    }

    /// The fixture's meeting-audio turn runs from 4 s to `turnEnd` and is provisional; completed
    /// transcripts only hold final lines.
    private static func sessionWithFinalRemoteTurn() -> MeetingSession {
        var session = MeetingModelFixture.makeSession()
        session.transcriptSegments[0].status = .final
        return session
    }
}
