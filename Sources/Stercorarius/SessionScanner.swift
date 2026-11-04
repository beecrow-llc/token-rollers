import Foundation
import os

private let logger = Logger(subsystem: "com.jamg.Stercorarius", category: "sessions")

/// Reports which agent sessions are working right now, from their session records.
struct SessionScanner {
    let directories: [Agent: URL]
    var isAlive: (Int32, Agent) -> Bool = Processes.isAlive

    /// Sessions whose record says `busy` and whose process is still the agent.
    func busySessions() -> Set<Session> {
        var sessions = Set<Session>()
        for (agent, directory) in directories {
            for (id, record) in Self.records(in: directory)
            where record.isBusy && isAlive(record.pid, agent) {
                sessions.insert(Session(agent: agent, id: id))
            }
        }
        return sessions
    }

    /// The `*.json` records in `directory`, keyed by file name without the extension.
    /// A missing directory has no records; unreadable files are logged and skipped.
    static func records(in directory: URL) -> [String: SessionRecord] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        } catch {
            logger.error(
                "Cannot list \(directory.path, privacy: .public): \(error.localizedDescription)")
            return [:]
        }
        var records: [String: SessionRecord] = [:]
        for file in files where file.pathExtension == "json" {
            records[file.deletingPathExtension().lastPathComponent] = record(at: file)
        }
        return records
    }

    /// The record in `file`, or nil (logged) when it is missing or malformed.
    static func record(at file: URL) -> SessionRecord? {
        do {
            return try JSONDecoder().decode(SessionRecord.self, from: Data(contentsOf: file))
        } catch {
            logger.debug("Skipping \(file.path, privacy: .public): \(error.localizedDescription)")
            return nil
        }
    }
}
