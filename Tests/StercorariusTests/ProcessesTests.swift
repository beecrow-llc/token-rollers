import Foundation
import Testing

@testable import Stercorarius

@Suite struct ProcessesTests {
    @Test func executablePathOfThisProcessIsAbsolute() throws {
        let path = try #require(Processes.executablePath(of: getpid()))
        #expect(path.hasPrefix("/"))
    }

    @Test func parentMatchesGetppid() {
        #expect(Processes.parent(of: getpid()) == getppid())
    }

    @Test func missingProcessHasNoPathOrParent() {
        #expect(Processes.executablePath(of: 99_999_999) == nil)
        #expect(Processes.parent(of: 99_999_999) == nil)
        #expect(!Processes.isAlive(99_999_999, agent: .codex))
    }

    @Test func ancestorMatchesExecutableNamePrefix() throws {
        let parentPath = try #require(Processes.executablePath(of: getppid()))
        let parentName = try #require(parentPath.split(separator: "/").last).lowercased()
        #expect(Processes.ancestor(of: getpid(), executablePrefix: parentName) == getppid())
        #expect(Processes.ancestor(of: getpid(), executablePrefix: "no-such-program-zz") == nil)
    }

    @Test func isAliveRequiresTheAgentNameInTheExecutablePath() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let codex = try launchSleeper(named: "codex-sleeper", in: directory)
        let plain = try launchSleeper(named: "plain-sleeper", in: directory)
        defer { plain.terminate() }

        #expect(Processes.isAlive(codex.processIdentifier, agent: .codex))
        #expect(!Processes.isAlive(plain.processIdentifier, agent: .codex))

        codex.terminate()
        codex.waitUntilExit()
        #expect(!Processes.isAlive(codex.processIdentifier, agent: .codex))
    }

    /// Runs a copy of /bin/sleep named `name`, so the test controls its executable path.
    private func launchSleeper(named name: String, in directory: URL) throws -> Process {
        let binary = directory.appending(path: name)
        try FileManager.default.copyItem(at: URL(filePath: "/bin/sleep"), to: binary)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["30"]
        try process.run()
        return process
    }
}
