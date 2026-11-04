import Foundation
import Testing

@testable import Stercorarius

@Suite final class CodexHookTests {
    private let root: URL
    private let state: URL
    private let codexHome: URL

    init() throws {
        root = try makeTemporaryDirectory()
        state = root.appending(path: "state", directoryHint: .isDirectory)
        codexHome = root.appending(path: "codex-home", directoryHint: .isDirectory)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func hook(pid: Int32? = 4242, alive: @escaping (Int32) -> Bool = { _ in true })
        -> CodexHook
    {
        CodexHook(
            stateDirectory: state, codexHome: codexHome, findAgentPID: { pid }, isAlive: alive)
    }

    private func payload(
        session: String = "01a1-thread", cwd: String = "/work", agent: String? = nil
    ) throws -> Data {
        var object = ["session_id": session, "cwd": cwd, "hook_event_name": "UserPromptSubmit"]
        object["agent_id"] = agent
        return try JSONSerialization.data(withJSONObject: object)
    }

    private var records: [String: SessionRecord] { SessionScanner.records(in: state) }

    @Test func busyRecordsTheCodexProcess() throws {
        hook().run(.busy, input: try payload())
        #expect(records == ["01a1-thread": SessionRecord(pid: 4242, status: "busy")])
    }

    @Test func idleRemovesTheRecord() throws {
        hook().run(.busy, input: try payload())
        hook().run(.idle, input: try payload())
        #expect(records.isEmpty)
    }

    @Test func idleWithoutRecordIsHarmless() throws {
        hook().run(.idle, input: try payload())
        #expect(records.isEmpty)
    }

    @Test func ignoresSubagentTurns() throws {
        hook().run(.busy, input: try payload(agent: "worker-1"))
        #expect(records.isEmpty)
    }

    @Test func ignoresTheMemoryConsolidationSession() throws {
        let memories = codexHome.appending(path: "memories").path
        hook().run(.busy, input: try payload(cwd: memories))
        #expect(records.isEmpty)
    }

    @Test(arguments: ["", "../escape", "a/b", "sp ace", "ünï", String(repeating: "a", count: 129)])
    func rejectsUnsafeSessionIDs(id: String) throws {
        hook().run(.busy, input: try payload(session: id))
        #expect(records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "escape.json").path))
    }

    @Test func acceptsCodexThreadIDs() {
        #expect(CodexHook.isValidSessionID("01a1a6d6-537e-7b71-94d8-ee756679609e"))
        #expect(CodexHook.isValidSessionID("thread_1"))
    }

    @Test func malformedPayloadWritesNothing() {
        hook().run(.busy, input: Data("not json".utf8))
        #expect(records.isEmpty)
    }

    @Test func busyWithoutCodexAncestorWritesNothing() throws {
        hook(pid: nil).run(.busy, input: try payload())
        #expect(records.isEmpty)
    }

    @Test func removesRecordsOfDeadProcesses() throws {
        hook(pid: 1111).run(.busy, input: try payload(session: "dead"))
        hook(pid: 2222).run(.busy, input: try payload(session: "alive"))
        hook(alive: { $0 == 2222 }).run(.idle, input: try payload(session: "other"))
        #expect(Array(records.keys) == ["alive"])
    }

    @Test func usageErrorsStillExitZero() {
        #expect(CodexHook.execute(arguments: ["bogus"]) == 0)
        #expect(CodexHook.execute(arguments: []) == 0)
    }
}
