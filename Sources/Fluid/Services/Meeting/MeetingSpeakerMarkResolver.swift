import Foundation

nonisolated enum MeetingSpeakerMarkResolver {
    /// 3 s is a guess: how long after hearing a voice start someone presses Mark.
    static let lookbackSeconds: TimeInterval = 3

    /// Names the voice speaking on the marked track at each mark. Marks are applied in time order
    /// and the first name a voice receives wins. The same name on two voices names both, which is
    /// the cue to merge them in Edit speakers.
    static func apply(to session: inout MeetingSession) {
        guard let marks = session.speakerMarks, !marks.isEmpty else { return }
        let trackIDs = Set(session.audioTracks.filter { $0.kind == session.mode.markedTrackKind }.map(\.id))
        let turns = session.transcriptSegments.filter {
            trackIDs.contains($0.sourceTrackID) && $0.speakerID != nil && !$0.isEcho && $0.status == .final
        }
        var namedSpeakers: [SessionSpeakerID: String] = [:]
        var resolved = marks
        for index in resolved.indices.sorted(by: { marks[$0].pressedAtHostSeconds < marks[$1].pressedAtHostSeconds }) {
            let mark = marks[index]
            let pressedAt = mark.pressedAtMeetingSeconds(in: session)
            let turn = turns
                .filter { $0.start.seconds <= pressedAt && $0.end.seconds >= pressedAt - self.lookbackSeconds }
                .max { ($0.start.seconds, $0.end.seconds) < ($1.start.seconds, $1.end.seconds) }
            guard let speakerID = turn?.speakerID,
                  let speakerIndex = session.speakers.firstIndex(where: { $0.id == speakerID })
            else {
                resolved[index].resolution = .noSpeaker
                continue
            }
            if let existing = namedSpeakers[speakerID], existing != mark.name {
                resolved[index].resolution = .alreadyNamed(existing)
                continue
            }
            session.speakers[speakerIndex].displayName = mark.name
            namedSpeakers[speakerID] = mark.name
            resolved[index].resolution = .named(speakerID)
        }
        session.speakerMarks = resolved
    }
}
