import Foundation

/// `Stercorarius codex-hook busy|idle`, registered as a Codex hook. Keeps one record per working
/// Codex session in `~/.stercorarius/codex/<session_id>.json`.
///
/// Contract with Codex: print nothing to stdout, because Codex adds `UserPromptSubmit` stdout to
/// the model context, and always exit 0, because exit code 2 would block the user's prompt.
/// Problems are reported on stderr.
struct CodexHook {
    enum Action: String {
        case busy
        case idle
    }

    /// The hook input fields Stercorarius uses: `session_id`, `cwd` and `agent_id`.
    struct Payload: Decodable {
        let sessionId: String
        let cwd: String?
        let agentId: String?
    }

    let stateDirectory: URL
    let codexHome: URL
    var findAgentPID: () -> Int32? = {
        Processes.ancestor(of: getpid(), executablePrefix: Agent.codex.rawValue)
    }
    var isAlive: (Int32) -> Bool = { Processes.isAlive($0, agent: .codex) }

    /// Entry point for `Stercorarius codex-hook <action>`; returns the exit status, always 0.
    static func execute(arguments: [String]) -> Int32 {
        guard let action = arguments.first.flatMap(Action.init(rawValue:)) else {
            report("usage: Stercorarius codex-hook busy|idle")
            return 0
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome =
            ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? home.appending(path: ".codex", directoryHint: .isDirectory)
        let hook = CodexHook(
            stateDirectory: Agent.codex.sessionDirectory(home: home), codexHome: codexHome)
        hook.run(action, input: (try? FileHandle.standardInput.readToEnd()) ?? Data())
        return 0
    }

    /// Records `action` for the session described by the hook JSON in `input`.
    func run(_ action: Action, input: Data) {
        removeDeadRecords()
        let payload: Payload
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            payload = try decoder.decode(Payload.self, from: input)
        } catch {
            Self.report("unreadable hook input: \(error.localizedDescription)")
            return
        }
        guard payload.agentId == nil, !isMemoryConsolidation(cwd: payload.cwd),
            Self.isValidSessionID(payload.sessionId)
        else { return }
        let record = stateDirectory.appending(path: "\(payload.sessionId).json")
        switch action {
        case .busy: markBusy(record)
        case .idle: remove(record)
        }
    }

    /// Session IDs become file names, so only `[A-Za-z0-9_-]{1,128}` is accepted.
    static func isValidSessionID(_ id: String) -> Bool {
        (1...128).contains(id.count) && id.allSatisfy(isSessionIDCharacter)
    }

    private static func isSessionIDCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "-_".contains(character))
    }

    /// Codex's memory-consolidation session runs in `$CODEX_HOME/memories` and never fires `Stop`.
    private func isMemoryConsolidation(cwd: String?) -> Bool {
        guard let cwd else { return false }
        let memories = codexHome.appending(path: "memories").standardizedFileURL.path
        return URL(filePath: cwd).standardizedFileURL.path == memories
    }

    private func markBusy(_ record: URL) {
        guard let pid = findAgentPID() else {
            Self.report("no codex process among the hook's ancestors")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: stateDirectory, withIntermediateDirectories: true)
            let busy = SessionRecord(pid: pid, status: SessionRecord.busyStatus)
            try JSONEncoder().encode(busy).write(to: record, options: .atomic)
        } catch {
            Self.report("cannot write \(record.path): \(error.localizedDescription)")
        }
    }

    /// Drops records whose Codex process is gone (killed or crashed without firing a hook).
    private func removeDeadRecords() {
        for (id, record) in SessionScanner.records(in: stateDirectory) where !isAlive(record.pid) {
            remove(stateDirectory.appending(path: "\(id).json"))
        }
    }

    private func remove(_ record: URL) {
        do {
            try FileManager.default.removeItem(at: record)
        } catch CocoaError.fileNoSuchFile {
            // Already gone.
        } catch {
            Self.report("cannot delete \(record.path): \(error.localizedDescription)")
        }
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data("stercorarius codex-hook: \(message)\n".utf8))
    }
}
