import Foundation
import Testing

@testable import Stercorarius

@Suite final class SessionScannerTests {
    private let claude: URL
    private let codex: URL

    init() throws {
        claude = try makeTemporaryDirectory()
        codex = try makeTemporaryDirectory()
    }

    deinit {
        try? FileManager.default.removeItem(at: claude)
        try? FileManager.default.removeItem(at: codex)
    }

    @Test func reportsBusySessionsWhoseProcessIsAlive() throws {
        try writeFile(#"{"pid":10,"status":"busy","sessionId":"a"}"#, named: "10.json", in: claude)
        try writeFile(#"{"pid":11,"status":"idle"}"#, named: "11.json", in: claude)
        try writeFile(#"{"pid":12,"status":"waiting"}"#, named: "12.json", in: claude)
        try writeFile(#"{"pid":13,"status":"busy"}"#, named: "13.json", in: claude)
        try writeFile(#"{"pid":20,"status":"busy"}"#, named: "thread-1.json", in: codex)
        let scanner = SessionScanner(
            directories: [.claude: claude, .codex: codex],
            isAlive: { pid, _ in pid != 13 })

        #expect(
            scanner.busySessions() == [
                Session(agent: .claude, id: "10"),
                Session(agent: .codex, id: "thread-1"),
            ])
    }

    @Test func checksLivenessForTheRecordsAgent() throws {
        try writeFile(#"{"pid":20,"status":"busy"}"#, named: "thread-1.json", in: codex)
        let scanner = SessionScanner(
            directories: [.codex: codex], isAlive: { _, agent in agent == .claude })

        #expect(scanner.busySessions().isEmpty)
    }

    @Test func readsOnlyWellFormedJSONFiles() throws {
        try writeFile("not json", named: "1.json", in: claude)
        try writeFile(#"{"pid":2}"#, named: "2.json", in: claude)
        try writeFile(#"{"pid":3,"status":"busy"}"#, named: "3.key", in: claude)
        try writeFile(#"{"pid":4,"status":"busy"}"#, named: ".4.json.tmp", in: claude)
        try writeFile(#"{"pid":5,"status":"busy"}"#, named: "5.json", in: claude)

        #expect(SessionScanner.records(in: claude) == ["5": SessionRecord(pid: 5, status: "busy")])
    }

    @Test func missingDirectoryHasNoRecords() {
        let missing = claude.appending(path: "missing", directoryHint: .isDirectory)
        #expect(SessionScanner.records(in: missing).isEmpty)
    }
}
