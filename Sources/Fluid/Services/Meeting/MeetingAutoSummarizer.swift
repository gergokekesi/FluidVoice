import Foundation

/// Once a recording is transcribed, names it after what was discussed and writes an executive summary
/// with the summary model chosen in Meet Summary.
@MainActor
final class MeetingAutoSummarizer {
    static let shared = MeetingAutoSummarizer()

    static let titleInstructions = """
    Write a title for this meeting: at most eight words, naming the main topic and, when the transcript makes it clear, \
    who the user spoke with. No quotes, no Markdown, no date. Return only the title.
    """

    private static let gatherReadIntervalNanoseconds: UInt64 = 20_000_000_000

    private var running: Set<MeetingSessionID> = []
    /// Everyone seen in the user's Gather conversation while it was being recorded.
    private var gatherParticipants: [MeetingSessionID: [String]] = [:]
    /// Kept until their summary finishes; the controller runs its work in a task it owns.
    private var controllers: [MeetingSessionID: MeetingSummaryController] = [:]

    private init() {}

    /// The state that follows processing is a freshly transcribed meeting; any other route to `.completed`
    /// (a restore at launch, an edit) is not.
    nonisolated static func transcribedSessionID(from previous: MeetingCoordinatorState?, to current: MeetingCoordinatorState) -> MeetingSessionID? {
        guard case let .completed(id) = current, case let .processing(processingID, _)? = previous, processingID == id else { return nil }
        return id
    }

    /// Reads the Gather conversation while recording, since the names are gone once the call ends.
    func recordingStarted(_ session: MeetingSession, coordinator: MeetingSessionCoordinator) {
        guard session.capturedApplication?.bundleIdentifier == GatherConversationReader.bundleIdentifier,
              self.gatherParticipants[session.id] == nil
        else { return }
        self.gatherParticipants[session.id] = []
        Task { @MainActor in
            while coordinator.activeSession?.id == session.id {
                let names = await Task.detached(priority: .utility) { GatherConversationReader.otherParticipants() }.value
                for name in names where self.gatherParticipants[session.id]?.contains(name) == false {
                    self.gatherParticipants[session.id]?.append(name)
                }
                try? await Task.sleep(nanoseconds: Self.gatherReadIntervalNanoseconds)
            }
        }
    }

    func recordingTranscribed(_ session: MeetingSession, coordinator: MeetingSessionCoordinator) {
        guard session.transcriptSegments.contains(where: { !$0.isEcho && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              self.running.insert(session.id).inserted
        else { return }
        let selection = MeetingSummaryClaudeCode.defaulted(
            MeetingSummaryPreferences().selection,
            hasOnDeviceModel: MeetingSummaryController().model != nil
        )
        guard let route = try? MeetingSummaryRoute.resolve(selection, settings: .shared) else {
            DebugLogger.shared.log("auto-summary-skipped reason=no-route", source: "MeetingAutoSummarizer")
            self.running.remove(session.id)
            return
        }
        let participants = self.gatherParticipants.removeValue(forKey: session.id) ?? []
        Task { @MainActor in
            var session = session
            if let names = Self.speakerNames(for: session.activeSpeakers, gatherParticipants: participants) {
                do {
                    session = try await coordinator.renameSpeakers(sessionID: session.id, names: names)
                } catch {
                    DebugLogger.shared.log("auto-speaker-name-failed error=\(error)", source: "MeetingAutoSummarizer")
                }
            }
            // Re-read after the model call: the user may have renamed the meeting meanwhile.
            if session.defaultTitleBase != nil, let title = await self.title(for: session, route: route, participants: participants),
               coordinator.latestCompletedSession.map({ $0.id != session.id || $0.defaultTitleBase != nil }) ?? true {
                do {
                    session = try await coordinator.renameSession(sessionID: session.id, to: title)
                } catch {
                    DebugLogger.shared.log("auto-title-failed error=\(error)", source: "MeetingAutoSummarizer")
                }
            }
            let controller = MeetingSummaryController()
            self.controllers[session.id] = controller
            await controller.refresh(session: session, kind: .executive)
            if controller.output.isEmpty {
                controller.summarize(session: session, kind: .executive, route: route)
                if !controller.generating {
                    DebugLogger.shared.log("auto-summary-skipped reason=summary-busy", source: "MeetingAutoSummarizer")
                }
            }
            while controller.generating {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if let error = controller.error {
                DebugLogger.shared.log("auto-summary-failed error=\(error)", source: "MeetingAutoSummarizer")
            }
            self.controllers[session.id] = nil
            self.running.remove(session.id)
        }
    }

    /// In a one-to-one Gather conversation the one voice on the meeting-audio track is the one other
    /// person Gather showed, unless the user already named them.
    nonisolated static func speakerNames(for speakers: [MeetingSessionSpeaker], gatherParticipants: [String]) -> [SessionSpeakerID: String]? {
        guard gatherParticipants.count == 1 else { return nil }
        let remote = speakers.filter { $0.trackKind == .applicationAudio }
        guard remote.count == 1, let other = remote.first, other.displayName.hasPrefix("Speaker ") else { return nil }
        return [other.id: gatherParticipants[0]]
    }

    private func title(for session: MeetingSession, route: MeetingSummaryRoute, participants: [String]) async -> String? {
        do {
            let text = try await MeetingSummaryRemoteService.shared.generate(
                transcript: MeetingSummaryInput.transcript(for: session),
                kind: .custom,
                route: route,
                customInstructions: participants.isEmpty
                    ? Self.titleInstructions
                    : Self.titleInstructions + "\nThe user spoke in Gather with: \(participants.joined(separator: ", "))."
            )
            return Self.cleanTitle(text)
        } catch {
            DebugLogger.shared.log("auto-title-failed error=\(error)", source: "MeetingAutoSummarizer")
            return nil
        }
    }

    /// Models sometimes wrap a title in quotes or a heading; keep the first line's words only.
    nonisolated static func cleanTitle(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let title = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*\"'“”` ").union(.whitespaces))
        return title.isEmpty ? nil : String(title.prefix(100))
    }
}
