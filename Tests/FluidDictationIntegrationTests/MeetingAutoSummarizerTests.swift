@testable import FluidVoice_Debug
import XCTest

final class MeetingAutoSummarizerTests: XCTestCase {
    func testAMeetingThatJustFinishedProcessingIsSummarized() {
        let id = UUID()

        let transcribed = MeetingAutoSummarizer.transcribedSessionID(from: .processing(id, .identifyingSpeakers), to: .completed(id))

        XCTAssertEqual(transcribed, id)
    }

    func testAMeetingRestoredAtLaunchIsNotSummarized() {
        let id = UUID()

        let transcribed = MeetingAutoSummarizer.transcribedSessionID(from: .idle, to: .completed(id))

        XCTAssertNil(transcribed)
    }

    func testTitlesLoseQuotesHeadingsAndExtraLines() {
        XCTAssertEqual(MeetingAutoSummarizer.cleanTitle("# \"Flag cleanup rollout with Mateusz\"\nMore text"), "Flag cleanup rollout with Mateusz")
    }

    func testAnEmptyTitleKeepsTheDefault() {
        XCTAssertNil(MeetingAutoSummarizer.cleanTitle("  \n"))
    }

    func testClaudeSummaryTextIsReadFromTheResult() throws {
        let data = Data(#"{"type":"result","is_error":false,"result":"Summary text"}"#.utf8)

        XCTAssertEqual(try MeetingSummaryClaudeCode.result(from: data), "Summary text")
    }

    func testAClaudeErrorFailsTheSummary() {
        let data = Data(#"{"type":"result","is_error":true,"result":"Not logged in"}"#.utf8)

        XCTAssertThrowsError(try MeetingSummaryClaudeCode.result(from: data))
    }

    func testTheOnlyRemoteVoiceInAOneToOneGatherChatIsNamed() {
        let remote = self.speaker("Speaker 2", on: .applicationAudio)

        let names = MeetingAutoSummarizer.speakerNames(for: [self.speaker("Jo", on: .microphone), remote], gatherParticipants: ["Alex"])

        XCTAssertEqual(names, [remote.id: "Alex"])
    }

    func testARemoteVoiceTheUserAlreadyNamedIsKept() {
        let names = MeetingAutoSummarizer.speakerNames(for: [self.speaker("Alex", on: .applicationAudio)], gatherParticipants: ["Kamala B"])

        XCTAssertNil(names)
    }

    func testAGroupConversationNamesNobody() {
        let speakers = [self.speaker("Speaker 2", on: .applicationAudio), self.speaker("Speaker 3", on: .applicationAudio)]

        XCTAssertNil(MeetingAutoSummarizer.speakerNames(for: speakers, gatherParticipants: ["Alex", "Sam"]))
    }

    func testGatherShowsTheUsersConversationPartners() {
        let sidebar = ["Floor 1", "Hallway conversations", "Sam Robin", "Sam", "Robin", "Alex Jo", "Alex", "Jo", "Online (11)", "Jo Jo Active"]

        XCTAssertEqual(GatherConversationReader.otherParticipants(in: sidebar, selfName: "Jo"), ["Alex"])
    }

    func testGatherWithoutAConversationShowsNobody() {
        XCTAssertEqual(GatherConversationReader.otherParticipants(in: ["Floor 1", "Online (11)"], selfName: "Jo"), [])
    }

    private func speaker(_ name: String, on track: MeetingAudioTrackKind) -> MeetingSessionSpeaker {
        MeetingSessionSpeaker(id: UUID(), displayName: name, diarizationClusterID: nil, trackKind: track, isLocalUser: false, identityCandidates: [])
    }
}
