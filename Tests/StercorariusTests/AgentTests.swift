import Foundation
import Testing

@testable import Stercorarius

@Suite struct AgentTests {
    @Test func decodesClaudeRegistryRecordIgnoringOtherFields() throws {
        let json = #"{"pid":32789,"sessionId":"3f81","cwd":"/tmp","status":"busy","kind":"cli"}"#
        let record = try JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8))
        #expect(record == SessionRecord(pid: 32789, status: "busy"))
        #expect(record.isBusy)
    }

    @Test func idleAndWaitingAreNotBusy() {
        #expect(!SessionRecord(pid: 1, status: "idle").isBusy)
        #expect(!SessionRecord(pid: 1, status: "waiting").isBusy)
    }

    @Test func sessionDirectories() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        #expect(Agent.claude.sessionDirectory(home: home).path == "/Users/someone/.claude/sessions")
        #expect(
            Agent.codex.sessionDirectory(home: home).path == "/Users/someone/.stercorarius/codex")
    }

    @Test func spriteNamesMatchThePack() {
        #expect(Agent.claude.spriteName == "claude-code")
        #expect(Agent.codex.spriteName == "chatgpt-codex")
    }
}
