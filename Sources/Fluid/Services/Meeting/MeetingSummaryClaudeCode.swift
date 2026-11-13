import Foundation

/// Summaries through the Claude Code CLI, so they run on the user's Claude subscription instead of an API key.
nonisolated enum MeetingSummaryClaudeCode {
    static let providerID = "claude-code"
    static let providerName = "Claude subscription"
    static let defaultModel = "sonnet"
    private static let models: [(id: String, name: String)] = [
        ("sonnet", "Claude Sonnet"),
        ("opus", "Claude Opus"),
        ("haiku", "Claude Haiku"),
    ]
    private static let timeoutSeconds: TimeInterval = 300

    enum RunError: LocalizedError {
        case notInstalled
        case timedOut
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: "Claude Code is not installed. Install it and sign in with `claude` in Terminal."
            case .timedOut: "Claude did not finish the summary in time."
            case let .failed(detail): "Claude could not summarize this meeting: \(detail)"
            }
        }
    }

    /// A GUI app does not inherit the shell's PATH, so look where the installers put the binary.
    static var executableURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var options: [CommandModelOption] {
        guard self.executableURL != nil else { return [] }
        return self.models.map {
            CommandModelOption(providerID: self.providerID, providerName: self.providerName, modelID: $0.id, displayName: $0.name)
        }
    }

    static func route(model: String) -> MeetingSummaryRoute {
        MeetingSummaryRoute(
            providerID: self.providerID,
            providerName: self.providerName,
            modelID: model.isEmpty ? self.defaultModel : model,
            baseURL: "https://api.anthropic.com",
            apiKey: "",
            reasoning: nil,
            supportsTemperature: false
        )
    }

    /// Falls back to Claude when nothing is chosen, or when the chosen on-device model is not in this build.
    static func defaulted(_ selection: MeetingSummarySelection, hasOnDeviceModel: Bool) -> MeetingSummarySelection {
        let unusable = selection.providerID.isEmpty || (selection.providerID == MeetingSummaryOnDevice.providerID && !hasOnDeviceModel)
        guard unusable, self.executableURL != nil else { return selection }
        var selection = selection
        selection.providerID = self.providerID
        selection.modelsByProvider[ModelRepository.shared.providerKey(for: self.providerID)] = self.defaultModel
        return selection
    }

    /// No settings sources, tools or MCP servers, so the user's CLAUDE.md, memory and hooks stay out of the run.
    /// `--bare` would do the same but refuses subscription sign-in.
    static func arguments(model: String, systemPrompt: String) -> [String] {
        [
            "-p", "--model", model, "--effort", "high",
            "--setting-sources", "", "--strict-mcp-config", "--tools", "",
            "--no-session-persistence", "--output-format", "json",
            "--system-prompt", systemPrompt,
        ]
    }

    static func run(transcript: String, systemPrompt: String, model: String) async throws -> String {
        guard let executable = self.executableURL else { throw RunError.notInstalled }
        let workingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("fluidvoice-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let process = Process()
        process.executableURL = executable
        process.arguments = self.arguments(model: model, systemPrompt: systemPrompt)
        process.currentDirectoryURL = workingDirectory
        var environment = ProcessInfo.processInfo.environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"] {
            environment[key] = nil
        }
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        // A CLI that exits before reading the transcript must fail the summary, not SIGPIPE the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try Task.checkCancellation()
        try process.run()
        let data: Data = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data?.self) { group in
                group.addTask {
                    try? input.fileHandleForWriting.write(contentsOf: Data(transcript.utf8))
                    try? input.fileHandleForWriting.close()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    return data
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.timeoutSeconds * 1_000_000_000))
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                guard let first else {
                    self.stop(process)
                    throw RunError.timedOut
                }
                return first
            }
        } onCancel: {
            self.stop(process)
        }
        try Task.checkCancellation()
        return try self.result(from: data)
    }

    /// SIGTERM first; SIGKILL if the CLI is still alive after a short grace, so a hung run always settles.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    static func result(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RunError.failed(String(decoding: data.prefix(300), as: UTF8.self))
        }
        let text = object["result"] as? String ?? ""
        if object["is_error"] as? Bool == true { throw RunError.failed(text.isEmpty ? "unknown error" : text) }
        return text
    }
}
